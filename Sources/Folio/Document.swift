import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// A PDF open in a window. Every edit goes through `change`, so it can be undone and marks the document edited.
@Observable
final class FolioDocument: ReferenceFileDocument, @unchecked Sendable {
    static let readableContentTypes: [UTType] = [.pdf]

    var pdf: PDFDocument
    /// Goes up on every change, for the views that show what PDFKit changes without telling.
    var revision = 0
    /// The password that unlocked the file.
    var password: String?
    /// The password the file opens with once it's saved, when one was set here. Without one, it's saved as `pdf` is.
    var newPassword: String?
    /// What the file allows without its permissions password once it's saved, when that was set here.
    var newRestrictions: Restrictions?
    @ObservationIgnored weak var undo: UndoManager?

    init() {
        pdf = PDFDocument()
        pdf.insert(Self.blankPage(), at: 0)
    }

    init(pdf: PDFDocument) {
        self.pdf = pdf
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents, let pdf = PDFDocument(data: data) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.pdf = pdf
    }

    /// The system's paper size. iOS has none: Letter where the region measures in US units, A4 elsewhere.
    static var paper: CGSize {
        #if os(macOS)
        NSPrintInfo.shared.paperSize
        #else
        Locale.current.measurementSystem == .us ? CGSize(width: 612, height: 792) : CGSize(width: 595, height: 842)
        #endif
    }

    static func blankPage() -> PDFPage {
        let page = PDFPage()
        page.setBounds(CGRect(origin: .zero, size: paper), for: .mediaBox)
        return page
    }

    func snapshot(contentType: UTType) throws -> Data {
        var options: [PDFDocumentWriteOption: Any] = [:]
        if let newPassword {
            options[.userPasswordOption] = newPassword
            options[.ownerPasswordOption] = newPassword
        }
        if let newRestrictions {
            options[.ownerPasswordOption] = newRestrictions.password
            options[.accessPermissionsOption] = newRestrictions.permissions
        }
        guard !pdf.isLocked, let data = pdf.dataRepresentation(options: options) else { throw CocoaError(.fileWriteUnknown) }
        // PDFKit writes a file it can't protect, as with a password not in ASCII, unprotected, and says nothing: the file must
        // open only with its password, and keep to its restrictions until their password is given, or it isn't saved.
        if !options.isEmpty, PDFDocument(data: data).map(isProtected) != true { throw CocoaError(.fileWriteUnknown) }
        return data
    }

    /// Whether the file as saved opens only with the new password, and allows only what the new restrictions do until
    /// their password is given.
    private func isProtected(_ file: PDFDocument) -> Bool {
        guard file.isEncrypted, file.isLocked == (newPassword != nil), newPassword.map(file.unlock(withPassword:)) ?? true else { return false }
        guard let restrictions = newRestrictions else { return true }
        let changes = [file.allowsDocumentChanges, file.allowsDocumentAssembly, file.allowsCommenting, file.allowsFormFieldEntry]
        return file.permissionsStatus == .user && file.allowsPrinting == restrictions.printing && file.allowsCopying == restrictions.copying
            && changes.allSatisfy { $0 == restrictions.changes } && file.unlock(withPassword: restrictions.password)
            && file.permissionsStatus == .owner
    }

    func fileWrapper(snapshot: Data, configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: snapshot)
    }

    func unlock(_ password: String) -> Bool {
        guard pdf.unlock(withPassword: password) else { return false }
        self.password = password
        revision += 1
        return true
    }

    /// False while the file is locked, or restricted by its author and opened without the permissions password.
    var canEdit: Bool {
        _ = revision // an unlock changes the answer, and bumps this
        return !pdf.isLocked && (!pdf.isEncrypted || pdf.permissionsStatus == .owner
            || pdf.allowsDocumentChanges && pdf.allowsDocumentAssembly && pdf.allowsCommenting && pdf.allowsFormFieldEntry)
    }

    /// Runs `redo` and registers `revert` under `name`, in English, which Edit › Undo shows in the language Folio shows.
    /// Undoing registers the pair the other way round, so redo works.
    func change(_ name: String, do redo: @escaping () -> Void, undo revert: @escaping () -> Void) {
        redo()
        revision += 1
        undo?.registerUndo(withTarget: self) { $0.change(name, do: revert, undo: redo) }
        undo?.setActionName(NSLocalizedString(name, comment: ""))
    }

    /// What a file allows without its permissions password. Changes are changing, assembling, commenting and filling in
    /// forms together, as Folio's own editing needs them all.
    struct Restrictions: Equatable {
        var password: String
        var printing = false, copying = false, changes = false

        /// PDFKit's permission bits, which the Mac's PDFKit has as a plain enum, not a set. Screen readers may always read.
        var permissions: UInt {
            var allowed: [PDFAccessPermissions] = [.allowsContentAccessibility]
            if printing { allowed += [.allowsLowQualityPrinting, .allowsHighQualityPrinting] }
            if copying { allowed.append(.allowsContentCopying) }
            if changes { allowed += [.allowsDocumentChanges, .allowsDocumentAssembly, .allowsCommenting, .allowsFormFieldEntry] }
            return allowed.reduce(UInt(0)) { $0 | $1.rawValue }
        }
    }

    /// Sets the password that opens the file once it's saved, and what it allows without its permissions password, taking
    /// off each that's nil. PDFKit saves a protected file with its own protection, whatever it's asked, so the pages of one
    /// move into a document without any, with its bookmarks, title and other attributes.
    func setPassword(_ new: String?, restrictions: Restrictions?) {
        let (old, plain) = ((pdf: pdf, password: newPassword, restrictions: newRestrictions), pdf.isEncrypted ? PDFDocument() : pdf)
        if plain !== old.pdf {
            // The bookmarks are copied before the pages move, while they still find them.
            plain.outlineRoot = pdf.outlineRoot.map(Self.copied)
            plain.documentAttributes = pdf.documentAttributes
        }
        change(new == nil && restrictions == nil ? "Remove Password" : "Set Password", do: {
            if plain !== old.pdf {
                self.pin()
                Self.move(from: old.pdf, to: plain)
            }
            (self.pdf, self.newPassword, self.newRestrictions) = (plain, new, restrictions)
        }, undo: {
            if plain !== old.pdf { Self.move(from: plain, to: old.pdf) }
            (self.pdf, self.newPassword, self.newRestrictions) = old
        })
    }

    /// What the file says about itself, which other apps and searches show, in Properties…' order.
    static let propertyKeys: [PDFDocumentAttribute] = [.titleAttribute, .authorAttribute, .subjectAttribute, .keywordsAttribute]

    /// Each of the file's properties as typed: its keywords, which PDFKit keeps as a list, separated by commas.
    var properties: [String] { Self.typed(pdf.documentAttributes ?? [:]) }

    /// Sets the properties, in `propertyKeys`' order, taking off each one left empty.
    func setProperties(_ values: [String]) {
        let old = pdf.documentAttributes
        var new = old ?? [:]
        for (key, value) in zip(Self.propertyKeys, values) {
            let value = value.trimmingCharacters(in: .whitespacesAndNewlines), words = Self.words(value)
            new[key] = key == .keywordsAttribute ? (words.isEmpty ? nil : words) : (value.isEmpty ? nil : value)
        }
        guard Self.typed(new) != properties else { return }
        change("Change Properties", do: { self.pdf.documentAttributes = new }, undo: { self.pdf.documentAttributes = old })
    }

    private static func typed(_ attributes: [AnyHashable: Any]) -> [String] {
        propertyKeys.map { key in
            let value = attributes[key] as? [String] ?? (attributes[key] as? String).map { [$0] } ?? []
            return key == .keywordsAttribute ? words(value.joined(separator: ",")).joined(separator: ", ") : value.joined()
        }
    }

    private static func words(_ keywords: String) -> [String] {
        keywords.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    /// Moves every page from one document to the other.
    private static func move(from: PDFDocument, to: PDFDocument) {
        while from.pageCount > 0, let page = from.page(at: 0) {
            from.removePage(at: 0)
            to.insert(page, at: to.pageCount)
        }
    }

    /// A copy of the bookmarks, each to the same page. A file's own bookmark finds its page through the file, so loses it
    /// once the page leaves; the copy holds the page.
    private static func copied(_ outline: PDFOutline) -> PDFOutline {
        let copy = PDFOutline()
        (copy.label, copy.isOpen) = (outline.label, outline.isOpen)
        if let to = outline.destination ?? (outline.action as? PDFActionGoTo)?.destination, let page = to.page {
            copy.destination = PDFDestination(page: page, at: to.point)
        } else {
            copy.action = outline.action
        }
        for i in 0..<outline.numberOfChildren { outline.child(at: i).map { copy.insertChild(copied($0), at: copy.numberOfChildren) } }
        return copy
    }

    // MARK: Pages

    var pages: [PDFPage] { (0..<pdf.pageCount).compactMap { pdf.page(at: $0) } }

    /// Puts these pages in the document, in this order, and a bookmark to a page in `replacing` on the page that replaces it.
    /// Undo puts the same page objects back as they were, and the bookmarks with them.
    func setPages(_ new: [PDFPage], name: String, replacing: [PDFPage: PDFPage] = [:]) {
        let old = pages, back = Dictionary(uniqueKeysWithValues: replacing.map { ($1, $0) })
        change(name, do: { self.fill(new, replacing: replacing) }, undo: { self.fill(old, replacing: back) })
    }

    private func fill(_ list: [PDFPage], replacing: [PDFPage: PDFPage]) {
        pin(replacing)
        while pdf.pageCount > 0 { pdf.removePage(at: pdf.pageCount - 1) }
        for page in list { pdf.insert(page, at: pdf.pageCount) }
    }

    /// Points each bookmark, and each link to a page, at the page itself, or at the page that replaces it, as the pages are
    /// about to leave: one the file came with finds its page through the file, so would lose it, and open the first page
    /// once saved.
    private func pin(_ replacing: [PDFPage: PDFPage] = [:]) {
        func pinned(_ to: PDFDestination?) -> PDFDestination? {
            guard let to, let page = to.page else { return nil }
            return PDFDestination(page: replacing[page] ?? page, at: to.point)
        }
        func walk(_ item: PDFOutline) {
            if let to = pinned(item.destination) {
                item.destination = to
            } else if let to = pinned((item.action as? PDFActionGoTo)?.destination) {
                item.action = PDFActionGoTo(destination: to)
            }
            for i in 0..<item.numberOfChildren { item.child(at: i).map(walk) }
        }
        pdf.outlineRoot.map(walk)
        for link in (pages + replacing.values).flatMap(\.annotations) where link.type == "Link" {
            if let to = pinned(link.destination) {
                link.destination = to
            } else if let to = pinned((link.action as? PDFActionGoTo)?.destination) {
                link.action = PDFActionGoTo(destination: to)
            }
        }
    }

    func rotate(_ chosen: [PDFPage], by degrees: Int) {
        let turn = { (by: Int) in chosen.forEach { $0.rotation = ($0.rotation + by + 360) % 360 } }
        change("Rotate", do: { turn(degrees) }, undo: { turn(-degrees) })
    }

    func delete(_ doomed: [PDFPage]) {
        setPages(pages.filter { !doomed.contains($0) }, name: "Delete Pages")
    }

    func insert(_ new: [PDFPage], at index: Int) {
        var list = pages
        list.insert(contentsOf: new, at: min(index, list.count))
        setPages(list, name: "Insert Pages")
    }

    /// Moves the pages, in their document order, to `index`: a slot in the list as it is before they leave it.
    func move(_ moving: [PDFPage], to index: Int) {
        let list = pages, index = min(index, list.count)
        var rest = list.filter { !moving.contains($0) }
        rest.insert(contentsOf: list.filter { moving.contains($0) }, at: index - list[..<index].filter { moving.contains($0) }.count)
        setPages(rest, name: "Move Pages")
    }

    /// Copies of these pages, in document order, in a new document.
    func extract(_ chosen: [PDFPage]) -> PDFDocument {
        let out = PDFDocument()
        for page in pages where chosen.contains(page) { out.insert(page.copy() as! PDFPage, at: out.pageCount) }
        return out
    }

    /// The password a file made from this one's pages opens with: the one set here, or the one this one opened with.
    var keptPassword: String? { newPassword ?? (pdf.isEncrypted ? password : nil) }

    /// Writes the pages into files of `count` pages each, in `folder`: "<name> 1.pdf", "<name> 2.pdf" and so on, each with
    /// the kept password and the restrictions set here. It writes over no file: when one of the names is taken, it throws
    /// before writing any. When a file can't be written, it takes back those it wrote, so trying again finds the names free.
    func split(every count: Int, into folder: URL, name: String) throws -> [URL] {
        let all = pages, starts = Array(stride(from: 0, to: all.count, by: count))
        let urls = starts.indices.map { folder.appendingPathComponent("\(name) \($0 + 1).pdf") }
        if let taken = urls.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: taken.path])
        }
        var written: [URL] = []
        do {
            for (start, url) in zip(starts, urls) {
                let piece = FolioDocument(pdf: extract(Array(all[start..<min(start + count, all.count)])))
                (piece.newPassword, piece.newRestrictions) = (keptPassword, newRestrictions)
                try piece.snapshot(contentType: .pdf).write(to: url, options: .withoutOverwriting)
                written.append(url)
            }
        } catch {
            written.forEach { try? FileManager.default.removeItem(at: $0) }
            throw error
        }
        return urls
    }

    /// Pages from files. Each file is read whole at once, while a file chosen in a panel may still be read.
    static func pages(from urls: [URL]) -> [PDFPage] {
        urls.flatMap { url in
            (try? Data(contentsOf: url)).map { pages(from: $0, isPDF: UTType(filenameExtension: url.pathExtension)?.conforms(to: .pdf) == true) } ?? []
        }
    }

    /// Copies of a PDF's pages, or a picture on a page of its own.
    static func pages(from data: Data, isPDF: Bool) -> [PDFPage] {
        if isPDF {
            guard let pdf = PDFDocument(data: data), pdf.hasFullRights else { return [] }
            return (0..<pdf.pageCount).compactMap { pdf.page(at: $0)?.copy() as? PDFPage }
        }
        return NSImage(data: data).flatMap(page(from:)).map { [$0] } ?? []
    }

    /// A picture fitted to a page of the system's paper size, turned landscape for a wide picture.
    static func page(from image: NSImage) -> PDFPage? {
        let size = image.size.width > image.size.height ? CGSize(width: paper.height, height: paper.width) : paper
        return PDFPage(image: image, options: [.mediaBox: CGRect(origin: .zero, size: size)])
    }
}

extension PDFDocument {
    /// False for a file its author restricted, open without the permissions password: pages or a file made from it, or a
    /// new password, would go without what the author forbids.
    var hasFullRights: Bool {
        !isLocked && (permissionsStatus == .owner || allowsPrinting && allowsCopying && allowsContentAccessibility
            && allowsDocumentChanges && allowsDocumentAssembly && allowsCommenting && allowsFormFieldEntry)
    }
}
