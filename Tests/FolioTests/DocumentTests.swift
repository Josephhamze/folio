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

/// Two blank pages and a bookmark, "Second", to the second, written out by hand: PDFKit saves the bookmarks of a file it
/// read as the file had them, not ones added to it.
func outlinedPDF() -> Data {
    let objects = [
        "<< /Type /Catalog /Pages 2 0 R /Outlines 5 0 R >>",
        "<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>",
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>",
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>",
        "<< /Type /Outlines /First 6 0 R /Last 6 0 R /Count 1 >>",
        "<< /Title (Second) /Parent 5 0 R /Dest [4 0 R /XYZ 0 792 0] >>",
    ]
    var pdf = "%PDF-1.4\n", offsets: [Int] = []
    for (i, object) in objects.enumerated() {
        offsets.append(pdf.utf8.count)
        pdf += "\(i + 1) 0 obj\n\(object)\nendobj\n"
    }
    let xref = pdf.utf8.count
    pdf += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n" + offsets.map { String(format: "%010d 00000 n \n", $0) }.joined()
    pdf += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
    return Data(pdf.utf8)
}

/// A photo of a company's stamp: a blue ring 200 pixels across, its line 12 thick, on grey paper in poor light, as a JPEG.
func stampPhoto(ring: Bool = true) -> Data {
    let context = CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.setFillColor(CGColor(red: 0.8, green: 0.78, blue: 0.75, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
    if ring {
        context.setStrokeColor(CGColor(red: 0.1, green: 0.2, blue: 0.7, alpha: 1))
        context.setLineWidth(12)
        context.strokeEllipse(in: CGRect(x: 100, y: 50, width: 200, height: 200))
    }
    let data = NSMutableData(), file = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil)!
    CGImageDestinationAddImage(file, context.makeImage()!, nil)
    CGImageDestinationFinalize(file)
    return data as Data
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

    /// A file its author kept from being copied or printed, open without the permissions password, takes marks but gives no
    /// pages to another file, which would go without what the author forbids. The permissions password lifts that.
    func testRestrictedFileGivesNoPages() throws {
        // The Mac's PDFKit has these as a plain enum, not a set.
        let editable = [PDFAccessPermissions.allowsDocumentChanges, .allowsDocumentAssembly, .allowsCommenting, .allowsFormFieldEntry].reduce(UInt(0)) { $0 | $1.rawValue }
        let data = makePDF([["A"]]).dataRepresentation(options: [PDFDocumentWriteOption.ownerPasswordOption: "pw", .accessPermissionsOption: editable])!
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).pdf")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(FolioDocument.pages(from: [url]), [])
        let doc = FolioDocument(pdf: PDFDocument(data: data)!)
        XCTAssertTrue(doc.canEdit)
        XCTAssertFalse(doc.pdf.hasFullRights)
        XCTAssertTrue(doc.unlock("pw"))
        XCTAssertTrue(doc.pdf.hasFullRights)
    }

    func testPasswordToOpenGoesOnWhenSavedAndUndoes() throws {
        let doc = FolioDocument(pdf: makePDF([["A"]])), undo = manualUndo(doc)
        act(undo) { doc.setPassword("pw") }
        let file = try reopened(doc)
        XCTAssertTrue(file.isLocked)
        XCTAssertFalse(file.unlock(withPassword: "nope"))
        XCTAssertTrue(file.unlock(withPassword: "pw"))
        XCTAssertEqual(texts(file), ["A"])
        undo.undo()
        XCTAssertFalse(try reopened(doc).isEncrypted)
    }

    func testNewPasswordReplacesTheFilesOwn() throws {
        let data = makePDF([["A"]]).dataRepresentation(options: [PDFDocumentWriteOption.userPasswordOption: "a", .ownerPasswordOption: "a"])!
        let doc = FolioDocument(pdf: PDFDocument(data: data)!)
        XCTAssertTrue(doc.unlock("a"))
        doc.setPassword("b")
        let file = try reopened(doc)
        XCTAssertFalse(file.unlock(withPassword: "a"))
        XCTAssertTrue(file.unlock(withPassword: "b"))
        XCTAssertEqual(texts(file), ["A"])
    }

    /// Taking off a file's password keeps its pages, marks, title and bookmarks, each to its page, and undoes.
    func testRemovePasswordKeepsWhatsInTheFileAndUndoes() throws {
        let pdf = try XCTUnwrap(PDFDocument(data: outlinedPDF()))
        pdf.documentAttributes = [PDFDocumentAttribute.titleAttribute: "Q3"]
        pdf.page(at: 1)!.addAnnotation(shape(.rect, from: .zero, to: CGPoint(x: 20, y: 20), color: .red))
        let data = try XCTUnwrap(pdf.dataRepresentation(options: [PDFDocumentWriteOption.userPasswordOption: "a", .ownerPasswordOption: "a"]))
        let doc = FolioDocument(pdf: try XCTUnwrap(PDFDocument(data: data))), undo = manualUndo(doc)
        XCTAssertTrue(doc.unlock("a"))
        act(undo) { doc.setPassword(nil) }
        let file = try reopened(doc)
        XCTAssertFalse(file.isEncrypted)
        XCTAssertEqual(file.pageCount, 2)
        XCTAssertEqual(file.page(at: 1)?.annotations.count, 1)
        XCTAssertEqual(file.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String, "Q3")
        XCTAssertEqual(file.outlineRoot?.child(at: 0)?.label, "Second")
        XCTAssertEqual(file.outlineRoot?.child(at: 0)?.destination?.page.map(file.index(for:)), 1)
        undo.undo()
        let back = try reopened(doc)
        XCTAssertTrue(back.isLocked)
        XCTAssertTrue(back.unlock(withPassword: "a"))
        XCTAssertEqual(back.outlineRoot?.child(at: 0)?.destination?.page.map(back.index(for:)), 1)
        XCTAssertEqual(doc.pdf.pageCount, 2)
    }

    /// PDFKit saves a file whose password isn't all ASCII unprotected, without a word, so then the save fails instead.
    func testPasswordPDFKitCantUseFailsTheSave() throws {
        let doc = FolioDocument(pdf: makePDF([["A"]]))
        doc.setPassword("密码")
        XCTAssertThrowsError(try doc.snapshot(contentType: .pdf))
        doc.setPassword("mima")
        XCTAssertTrue(try reopened(doc).isEncrypted)
    }

    /// The document as its file would be read back.
    private func reopened(_ doc: FolioDocument) throws -> PDFDocument {
        try XCTUnwrap(PDFDocument(data: try doc.snapshot(contentType: .pdf)))
    }

    func testUnlockRedrawsWhatReadCanEdit() {
        let data = makePDF([["Secret"]]).dataRepresentation(options: [PDFDocumentWriteOption.userPasswordOption: "pw"])!
        let doc = FolioDocument(pdf: PDFDocument(data: data)!)
        let told = expectation(description: "told")
        withObservationTracking { _ = doc.canEdit } onChange: { told.fulfill() }
        XCTAssertTrue(doc.unlock("pw"))
        wait(for: [told], timeout: 0)
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
