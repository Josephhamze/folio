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

    static func blankPage() -> PDFPage {
        let page = PDFPage()
        page.setBounds(CGRect(origin: .zero, size: NSPrintInfo.shared.paperSize), for: .mediaBox)
        return page
    }

    func snapshot(contentType: UTType) throws -> Data {
        guard !pdf.isLocked, let data = pdf.dataRepresentation() else { throw CocoaError(.fileWriteUnknown) }
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
        !pdf.isLocked && (!pdf.isEncrypted || pdf.permissionsStatus == .owner
            || pdf.allowsDocumentChanges && pdf.allowsDocumentAssembly && pdf.allowsCommenting && pdf.allowsFormFieldEntry)
    }

    /// Runs `redo` and registers `revert` under `name`. Undoing registers the pair the other way round, so redo works.
    func change(_ name: String, do redo: @escaping () -> Void, undo revert: @escaping () -> Void) {
        redo()
        revision += 1
        undo?.registerUndo(withTarget: self) { $0.change(name, do: revert, undo: redo) }
        undo?.setActionName(name)
    }

    // MARK: Pages

    var pages: [PDFPage] { (0..<pdf.pageCount).compactMap { pdf.page(at: $0) } }

    /// Puts these pages in the document, in this order. Undo puts the same page objects back as they were.
    func setPages(_ new: [PDFPage], name: String) {
        let old = pages
        change(name, do: { self.fill(new) }, undo: { self.fill(old) })
    }

    private func fill(_ list: [PDFPage]) {
        while pdf.pageCount > 0 { pdf.removePage(at: pdf.pageCount - 1) }
        for page in list { pdf.insert(page, at: pdf.pageCount) }
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

    func split(every count: Int, into folder: URL, name: String) throws -> [URL] {
        let all = pages
        return try stride(from: 0, to: all.count, by: count).enumerated().map { part, start in
            let url = folder.appendingPathComponent("\(name) \(part + 1).pdf")
            guard extract(Array(all[start..<min(start + count, all.count)])).write(to: url) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
            }
            return url
        }
    }

    /// Pages from files: copies of a PDF's pages, or an image fitted to a page of the system's paper size, turned
    /// landscape for a wide image.
    static func pages(from urls: [URL]) -> [PDFPage] {
        urls.flatMap { url -> [PDFPage] in
            if let pdf = PDFDocument(url: url) {
                return pdf.isLocked ? [] : (0..<pdf.pageCount).compactMap { pdf.page(at: $0)?.copy() as? PDFPage }
            }
            guard let image = NSImage(contentsOf: url) else { return [] }
            let paper = NSPrintInfo.shared.paperSize
            let size = image.size.width > image.size.height ? CGSize(width: paper.height, height: paper.width) : paper
            return PDFPage(image: image, options: [.mediaBox: NSValue(rect: CGRect(origin: .zero, size: size))]).map { [$0] } ?? []
        }
    }
}
