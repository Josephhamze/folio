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
        let options = newPassword.map { [PDFDocumentWriteOption.userPasswordOption: $0, .ownerPasswordOption: $0] } ?? [:]
        guard !pdf.isLocked, let data = pdf.dataRepresentation(options: options) else { throw CocoaError(.fileWriteUnknown) }
        // PDFKit writes a file it can't protect, as with a password not in ASCII, unprotected, and says nothing: the file must
        // open with the password, or it isn't saved.
        if let newPassword, PDFDocument(data: data).map({ $0.isEncrypted && $0.unlock(withPassword: newPassword) }) != true {
            throw CocoaError(.fileWriteUnknown)
        }
        return data
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

    /// Sets the password that opens the file once it's saved, or with nil takes the file's password off. PDFKit saves a
    /// protected file with its own protection, whatever it's asked, so the pages of one move into a document without any,
    /// with its bookmarks, title and other attributes.
    func setPassword(_ new: String?) {
        let (old, plain) = ((pdf: pdf, password: newPassword), pdf.isEncrypted ? PDFDocument() : pdf)
        if plain !== old.pdf {
            // The bookmarks are copied before the pages move, while they still find them.
            plain.outlineRoot = pdf.outlineRoot.map(Self.copied)
            plain.documentAttributes = pdf.documentAttributes
        }
        change(new == nil ? "Remove Password" : "Set Password", do: {
            if plain !== old.pdf { Self.move(from: old.pdf, to: plain) }
            (self.pdf, self.newPassword) = (plain, new)
        }, undo: {
            if plain !== old.pdf { Self.move(from: plain, to: old.pdf) }
            (self.pdf, self.newPassword) = old
        })
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
        pdf.outlineRoot.map { Self.repoint($0, replacing) }
        while pdf.pageCount > 0 { pdf.removePage(at: pdf.pageCount - 1) }
        for page in list { pdf.insert(page, at: pdf.pageCount) }
    }

    /// Points each bookmark at its page itself, or at the page that replaces it, as the pages are about to leave: a file's
    /// own bookmark finds its page through the file, so would lose it, and open the first page once saved.
    private static func repoint(_ outline: PDFOutline, _ replacing: [PDFPage: PDFPage]) {
        if let to = outline.destination, let page = to.page {
            outline.destination = PDFDestination(page: replacing[page] ?? page, at: to.point)
        } else if let to = (outline.action as? PDFActionGoTo)?.destination, let page = to.page {
            outline.action = PDFActionGoTo(destination: PDFDestination(page: replacing[page] ?? page, at: to.point))
        }
        for i in 0..<outline.numberOfChildren { outline.child(at: i).map { repoint($0, replacing) } }
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
    /// the kept password. It writes over no file: when one of the names is taken, it throws before writing any.
    func split(every count: Int, into folder: URL, name: String) throws -> [URL] {
        let all = pages, starts = Array(stride(from: 0, to: all.count, by: count))
        let urls = starts.indices.map { folder.appendingPathComponent("\(name) \($0 + 1).pdf") }
        if let taken = urls.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: taken.path])
        }
        for (start, url) in zip(starts, urls) {
            let piece = FolioDocument(pdf: extract(Array(all[start..<min(start + count, all.count)])))
            piece.newPassword = keptPassword
            try piece.snapshot(contentType: .pdf).write(to: url, options: .withoutOverwriting)
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
