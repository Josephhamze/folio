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
    @ObservationIgnored var undo: UndoManager?

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
}
