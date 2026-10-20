import Observation
import PDFKit
import XCTest
@testable import Folio

/// Pages holding these lines in Georgia 18: the first 72 pt from the top, then one every 40 pt, starting 72 pt from the left.
func makePDF(_ pages: [[String]], size: CGSize = CGSize(width: 612, height: 792)) -> PDFDocument {
    makePDF(styled: pages.map { $0.map { NSAttributedString(string: $0, attributes: [.font: NSFont(name: "Georgia", size: 18)!]) } }, size: size)
}

/// Pages holding these lines in their own styles, placed as above.
func makePDF(styled pages: [[NSAttributedString]], size: CGSize = CGSize(width: 612, height: 792)) -> PDFDocument {
    let data = NSMutableData()
    var box = CGRect(origin: .zero, size: size)
    let context = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil)!
    for lines in pages {
        context.beginPDFPage(nil)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        for (row, line) in lines.enumerated() { line.draw(at: CGPoint(x: 72, y: size.height - 72 - CGFloat(row) * 40)) }
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

    func testUnlockRedrawsWhatReadCanEdit() {
        let data = makePDF([["Secret"]]).dataRepresentation(options: [PDFDocumentWriteOption.userPasswordOption: "pw"])!
        let doc = FolioDocument(pdf: PDFDocument(data: data)!)
        var told = false
        withObservationTracking { _ = doc.canEdit } onChange: { told = true }
        XCTAssertTrue(doc.unlock("pw"))
        XCTAssertTrue(told)
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

    func testPageOperationsUndo() {
        let doc = FolioDocument(pdf: makePDF([["A"], ["B"], ["C"], ["D"]])), undo = manualUndo(doc)
        let p = doc.pages
        act(undo) { doc.rotate([p[0]], by: 90) }
        XCTAssertEqual(p[0].rotation, 90)
        undo.undo()
        XCTAssertEqual(p[0].rotation, 0)

        act(undo) { doc.delete([p[1], p[2]]) }
        XCTAssertEqual(texts(doc.pdf), ["A", "D"])
        undo.undo()
        XCTAssertEqual(texts(doc.pdf), ["A", "B", "C", "D"])

        act(undo) { doc.insert([FolioDocument.blankPage()], at: 1) }
        XCTAssertEqual(doc.pdf.pageCount, 5)
        undo.undo()
        XCTAssertEqual(doc.pdf.pageCount, 4)

        act(undo) { doc.move([p[3]], to: 0) }
        XCTAssertEqual(texts(doc.pdf), ["D", "A", "B", "C"])
        undo.undo()
        XCTAssertEqual(texts(doc.pdf), ["A", "B", "C", "D"])
        undo.redo()
        XCTAssertEqual(texts(doc.pdf), ["D", "A", "B", "C"])

        act(undo) { doc.move([p[3], p[0]], to: 4) }
        XCTAssertEqual(texts(doc.pdf), ["B", "C", "D", "A"])
    }

    func testExtractKeepsDocumentOrder() {
        let doc = FolioDocument(pdf: makePDF([["A"], ["B"], ["C"]]))
        XCTAssertEqual(texts(doc.extract([doc.pages[2], doc.pages[0]])), ["A", "C"])
        XCTAssertEqual(doc.pdf.pageCount, 3)
    }

    func testSplitEveryTwo() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Folio Split \(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let urls = try FolioDocument(pdf: makePDF([["1"], ["2"], ["3"], ["4"], ["5"]])).split(every: 2, into: folder, name: "Report")
        XCTAssertEqual(urls.map(\.lastPathComponent), ["Report 1.pdf", "Report 2.pdf", "Report 3.pdf"])
        XCTAssertEqual(urls.map { PDFDocument(url: $0)!.pageCount }, [2, 2, 1])
        XCTAssertEqual(texts(PDFDocument(url: urls[2])!), ["5"])
    }

    func testSplitNeverOverwrites() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let mine = folder.appendingPathComponent("Doc 2.pdf")
        try Data("keep".utf8).write(to: mine)
        let doc = FolioDocument(pdf: makePDF([["1"], ["2"]]))
        XCTAssertThrowsError(try doc.split(every: 1, into: folder, name: "Doc"))
        XCTAssertEqual(try Data(contentsOf: mine), Data("keep".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Doc 1.pdf").path))
    }

    func testPagesFromFilesFitPhotosToPaper() {
        let pdfURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).pdf")
        makePDF([["One"], ["Two"]]).write(to: pdfURL)
        let photo = URL(fileURLWithPath: "/System/Library/Wallpapers/.default/DefaultAerial.jpg")   // 3840×2160
        let pages = FolioDocument.pages(from: [pdfURL, photo])
        XCTAssertEqual(pages.count, 3)
        let paper = NSPrintInfo.shared.paperSize
        XCTAssertEqual(pages[2].bounds(for: .mediaBox).size, CGSize(width: paper.height, height: paper.width))
        XCTAssertEqual(pages[0].string?.trimmingCharacters(in: .whitespacesAndNewlines), "One")
    }
}
