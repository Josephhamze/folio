import PDFKit
import XCTest
@testable import Folio

/// Pages holding these lines in Georgia 18: the first 72 pt from the top, then one every 40 pt, starting 72 pt from the left.
func makePDF(_ pages: [[String]], size: CGSize = CGSize(width: 612, height: 792)) -> PDFDocument {
    let data = NSMutableData()
    var box = CGRect(origin: .zero, size: size)
    let context = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil)!
    for lines in pages {
        context.beginPDFPage(nil)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        for (row, line) in lines.enumerated() {
            (line as NSString).draw(at: CGPoint(x: 72, y: size.height - 72 - CGFloat(row) * 40),
                                    withAttributes: [.font: NSFont(name: "Georgia", size: 18)!])
        }
        context.endPDFPage()
    }
    NSGraphicsContext.current = nil
    context.closePDF()
    return PDFDocument(data: data as Data)!
}

/// Each page's text, trimmed.
func texts(_ pdf: PDFDocument) -> [String] {
    (0..<pdf.pageCount).map { pdf.page(at: $0)!.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
}

/// An undo manager that groups only when told, so tests can undo without a run loop.
func manualUndo(_ doc: FolioDocument) -> UndoManager {
    let undo = UndoManager()
    undo.groupsByEvent = false
    doc.undo = undo
    return undo
}

func act(_ undo: UndoManager, _ change: () -> Void) {
    undo.beginUndoGrouping()
    change()
    undo.endUndoGrouping()
}

final class DocumentTests: XCTestCase {
    func testBlankDocumentIsOnePaperSizedPage() {
        let doc = FolioDocument()
        XCTAssertEqual(doc.pdf.pageCount, 1)
        XCTAssertEqual(doc.pdf.page(at: 0)!.bounds(for: .mediaBox).size, NSPrintInfo.shared.paperSize)
        XCTAssertNotNil(PDFDocument(data: try! doc.snapshot(contentType: .pdf)))
    }

    func testSnapshotRoundTrips() {
        let doc = FolioDocument(pdf: makePDF([["One"], ["Two"]]))
        XCTAssertEqual(texts(PDFDocument(data: try! doc.snapshot(contentType: .pdf))!), ["One", "Two"])
    }

    func testEncryptedFileUnlocksAndStaysEncrypted() {
        let data = makePDF([["Secret"]]).dataRepresentation(options: [PDFDocumentWriteOption.userPasswordOption: "pw",
                                                                       .ownerPasswordOption: "pw"])!
        let doc = FolioDocument(pdf: PDFDocument(data: data)!)
        XCTAssertTrue(doc.pdf.isLocked)
        XCTAssertFalse(doc.canEdit)
        XCTAssertThrowsError(try doc.snapshot(contentType: .pdf))
        XCTAssertFalse(doc.unlock("nope"))
        XCTAssertTrue(doc.unlock("pw"))
        XCTAssertEqual(doc.password, "pw")
        XCTAssertTrue(PDFDocument(data: try! doc.snapshot(contentType: .pdf))!.isEncrypted)
    }

    func testChangeUndoesAndRedoes() {
        let doc = FolioDocument(), undo = manualUndo(doc)
        var value = 1
        act(undo) { doc.change("Set Value", do: { value = 2 }, undo: { value = 1 }) }
        XCTAssertEqual(value, 2)
        XCTAssertEqual(doc.revision, 1)
        XCTAssertEqual(undo.undoActionName, "Set Value")
        undo.undo()
        XCTAssertEqual(value, 1)
        undo.redo()
        XCTAssertEqual(value, 2)
    }
}
