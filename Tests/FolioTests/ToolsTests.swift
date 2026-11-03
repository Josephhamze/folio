import ImageIO
import PDFKit
import XCTest
@testable import Folio

/// Pages that are pictures of these lines, as a scanner makes them: letter pages holding only a 200 dpi picture of the lines
/// in Helvetica 24, the first 100 points from the top, then one every 50.
func scannedPDF(_ pages: [[String]]) -> PDFDocument {
    let scale: CGFloat = 200 / 72, data = NSMutableData()
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    let pdf = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil)!
    for lines in pages {
        let scan = CGContext(data: nil, width: Int(box.width * scale), height: Int(box.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
                             space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        scan.setFillColor(gray: 1, alpha: 1)
        scan.fill(CGRect(x: 0, y: 0, width: scan.width, height: scan.height))
        scan.scaleBy(x: scale, y: scale)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: scan, flipped: false)
        for (row, line) in lines.enumerated() {
            NSAttributedString(string: line, attributes: [.font: NSFont(name: "Helvetica", size: 24)!])
                .draw(at: CGPoint(x: 72, y: box.height - 100 - CGFloat(row) * 50))
        }
        NSGraphicsContext.current = nil
        pdf.beginPDFPage(nil)
        pdf.draw(scan.makeImage()!, in: box)
        pdf.endPDFPage()
    }
    pdf.closePDF()
    return PDFDocument(data: data as Data)!
}

@MainActor
final class ToolsTests: XCTestCase {
    /// A page drawn again with lines of text, at their boxes as Vision gives them, holds those words where they show, and
    /// looks as it did, with its marks, turn and crop.
    func testRebuiltPageHasTheWordsWhereTheyShow() throws {
        let page = try XCTUnwrap(scannedPDF([["Invoice 2026-117", "Cement 50 bags"]]).page(at: 0)), look = ink(try XCTUnwrap(render(page, dpi: 72)))
        page.addAnnotation(shape(.rect, from: CGPoint(x: 400, y: 100), to: CGPoint(x: 450, y: 150), color: .red))
        page.rotation = 90
        page.setBounds(CGRect(x: 0, y: 50, width: 612, height: 742), for: .cropBox)
        // The second line's box, as a share of the page from the bottom left: its baseline is 642 points up, and Helvetica
        // 24 reaches 5 below it and 19 above.
        let font = NSFont(name: "Helvetica", size: 24)!, width = { (words: String) in NSAttributedString(string: words, attributes: [.font: font]).size().width }
        let line = CGRect(x: 72 / 612, y: 637 / 792, width: width("Cement 50 bags") / 612, height: 24 / 792)
        let new = try XCTUnwrap(rebuilt(page, text: [(text: "Cement 50 bags", box: line), (text: "水泥五十袋", box: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.03))]))
        let doc = PDFDocument()
        doc.insert(new, at: 0)
        let words = new.string ?? ""
        XCTAssertTrue(words.contains("Cement 50 bags"), words)
        XCTAssertTrue(words.contains("水泥五十袋"), words)
        let cement = try XCTUnwrap(doc.findString("Cement", withOptions: []).first).bounds(for: new)
        XCTAssertEqual(cement.minX, 72, accuracy: 3)
        XCTAssertEqual(cement.maxX, 72 + width("Cement"), accuracy: 3)
        XCTAssertEqual(cement.midY, 650, accuracy: 8)
        XCTAssertEqual(Double(ink(try XCTUnwrap(render(new, dpi: 72)))), Double(look), accuracy: Double(look) / 100)
        XCTAssertEqual(new.rotation, 90)
        XCTAssertEqual(new.bounds(for: .cropBox), CGRect(x: 0, y: 50, width: 612, height: 742))
        XCTAssertEqual(new.annotations.map(\.type), ["Square"])
    }

    /// Only the page's own drawing is read, not its marks, whether the page is a file's or one made from a photo; and a
    /// photo's page drawn again keeps its picture.
    func testRenderLeavesOutTheMarks() throws {
        let scan = try XCTUnwrap(scannedPDF([["Received with thanks"]]).page(at: 0))
        let photo = try XCTUnwrap(PDFPage(image: scan.thumbnail(of: CGSize(width: 612, height: 792), for: .mediaBox)))
        for page in [scan, photo] {
            let before = ink(try XCTUnwrap(render(page, dpi: 72)))
            XCTAssertGreaterThan(before, 100)
            page.addAnnotation(shape(.rect, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 500, y: 300), color: .black))
            XCTAssertEqual(ink(try XCTUnwrap(render(page, dpi: 72))), before)
        }
        let again = try XCTUnwrap(rebuilt(photo, text: [])), shown = Double(ink(try XCTUnwrap(render(photo, dpi: 72))))
        XCTAssertEqual(Double(ink(try XCTUnwrap(render(again, dpi: 72)))), shown, accuracy: shown / 100)
        // Turned, it's still read upright, all of it.
        photo.rotation = 90
        XCTAssertEqual(Double(ink(try XCTUnwrap(render(photo, dpi: 72)))), shown, accuracy: shown / 100)
    }

    func testRecognizeTextPutsTheWordsUnderTheScan() async throws {
        try await requireTextRecognition()
        let doc = FolioDocument(pdf: scannedPDF([["Invoice 2026-117", "Cement 50 bags"], ["Delivered to Lubumbashi"]])), undo = manualUndo(doc)
        let page = doc.pages[0]
        XCTAssertEqual(texts(doc.pdf), ["", ""])
        var heard: [Int] = []
        undo.beginUndoGrouping()
        let result = await doc.recognizeText { done, _ in heard.append(done) }
        undo.endUndoGrouping()
        XCTAssertEqual(result.read, 2)
        XCTAssertEqual(result.of, 2)
        XCTAssertEqual(heard, [0, 1])
        let words = texts(doc.pdf)
        for word in ["Invoice", "2026-117", "Cement", "bags"] { XCTAssertTrue(words[0].contains(word), words[0]) }
        XCTAssertTrue(words[1].contains("Lubumbashi"), words[1])
        // One step, which puts the old pages back.
        XCTAssertEqual(undo.undoActionName, "Recognize Text")
        undo.undo()
        XCTAssertTrue(doc.pages[0] === page)
        XCTAssertEqual(texts(doc.pdf), ["", ""])
    }

    func testRecognizeTextReadsFrenchAndChinese() async throws {
        try await requireTextRecognition()
        let doc = FolioDocument(pdf: scannedPDF([["Facture réglée à Kinshasa"], ["水泥五十袋已交付"]]))
        let result = await doc.recognizeText { _, _ in }
        XCTAssertEqual(result.read, 2)
        let words = texts(doc.pdf)
        XCTAssertTrue(words[0].contains("réglée"), words[0])
        XCTAssertTrue(words[1].contains("水泥"), words[1])
    }

    func testRecognizeTextLeavesPagesWithText() async {
        let doc = FolioDocument(pdf: makePDF([["Typed"]])), page = doc.pages[0]
        let result = await doc.recognizeText { _, _ in XCTFail("No page to read") }
        XCTAssertEqual(result.read, 0)
        XCTAssertEqual(result.of, 0)
        XCTAssertTrue(doc.pages[0] === page)
        XCTAssertEqual(doc.revision, 0)
    }

    /// Skips where Vision's accurate model doesn't run, as on GitHub's virtual Macs.
    private func requireTextRecognition() async throws {
        let blank = try XCTUnwrap(render(FolioDocument.blankPage(), dpi: 72))
        let runs = (try? await recognize(blank)) != nil
        try XCTSkipUnless(runs, "Text recognition's model doesn't run on this Mac, as on GitHub's virtual ones")
    }

    /// A file of photos, as read from a file, shrinks.
    func testReduceFileSizeShrinksPhotosAndKeepsTheMarks() async throws {
        let doc = FolioDocument(pdf: PDFDocument(data: photoPDF().dataRepresentation()!)!), undo = manualUndo(doc), original = doc.pdf
        doc.pages[0].addAnnotation(shape(.rect, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 200, y: 200), color: .red))
        undo.beginUndoGrouping()
        let reduced = await doc.reduceFileSize()
        undo.endUndoGrouping()
        let sizes = try XCTUnwrap(reduced)
        print("Reduce File Size: \(sizes.before) → \(sizes.after)")
        XCTAssertLessThan(sizes.after, sizes.before / 2)
        // Saved, it stays that small, and keeps its marks.
        let saved = try doc.snapshot(contentType: .pdf)
        XCTAssertLessThan(saved.count, sizes.before / 2)
        XCTAssertEqual(PDFDocument(data: saved)!.page(at: 0)!.annotations.map(\.type), ["Square"])
        XCTAssertEqual(undo.undoActionName, "Reduce File Size")
        undo.undo()
        XCTAssertTrue(doc.pdf === original)
        // A file of text, already small, is left as it is.
        let text = FolioDocument(pdf: makePDF([["Words"]])), pdf = text.pdf
        let unchanged = await text.reduceFileSize()
        XCTAssertNil(unchanged)
        XCTAssertTrue(text.pdf === pdf)
        XCTAssertEqual(text.revision, 0)
    }

    func testReduceFileSizeNeverDropsThePassword() async throws {
        let data = photoPDF().dataRepresentation(options: [PDFDocumentWriteOption.userPasswordOption: "pw", .ownerPasswordOption: "pw"])!
        let doc = FolioDocument(pdf: PDFDocument(data: data)!)
        XCTAssertTrue(doc.unlock("pw"))
        let sizes = await doc.reduceFileSize()
        print("Reduce File Size, encrypted: \(sizes.map { "\($0.before) → \($0.after)" } ?? "left as it was")")
        XCTAssertTrue(PDFDocument(data: try doc.snapshot(contentType: .pdf))!.isEncrypted)
    }

    /// A page sent as a picture is as it shows: cropped, turned and marked, at two pixels a point.
    /// Applying redactions leaves no trace of the words under the marks, in the window or the saved file, and blacks them
    /// out. It keeps the rest, drops marks that overlap a redaction, keeps the page's turn, and undoes.
    func testApplyRedactionsTakesOutWhatsUnderTheMarks() async throws {
        let doc = FolioDocument(pdf: makePDF([["Delivery note 2026-41", "Bank account 99-1234"], ["Page two"]])), undo = manualUndo(doc)
        let page = doc.pages[0], secret = try XCTUnwrap(doc.pdf.findString("Bank account 99-1234", withOptions: []).first).bounds(for: page)
        let mark = secret.insetBy(dx: -2, dy: -2)
        page.addAnnotation(shape(.redact, from: mark.origin, to: CGPoint(x: mark.maxX, y: mark.maxY), color: .red))
        page.addAnnotation(shape(.rect, from: secret.origin, to: CGPoint(x: secret.minX + 20, y: secret.minY + 5), color: .blue))   // overlaps: goes
        page.addAnnotation(shape(.rect, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 30, y: 30), color: .blue))   // clear: stays
        page.rotation = 90
        undo.beginUndoGrouping()
        let redacted = await doc.applyRedactions()
        undo.endUndoGrouping()
        XCTAssertEqual(redacted, 1)
        let saved = try XCTUnwrap(PDFDocument(data: try XCTUnwrap(doc.pdf.dataRepresentation())))
        for pdf in [doc.pdf, saved] {
            XCTAssertTrue(pdf.findString("99-1234", withOptions: []).isEmpty)
            XCTAssertTrue(pdf.findString("Bank", withOptions: []).isEmpty)
            XCTAssertEqual(pdf.findString("Page two", withOptions: []).count, 1)
        }
        XCTAssertFalse(doc.hasRedactions)
        XCTAssertEqual(doc.pages[0].annotations.count, 1)
        XCTAssertEqual(doc.pages[0].rotation, 90)
        // The words' box is black: the picture's rows run down from the top.
        let image = try XCTUnwrap(render(doc.pages[0], dpi: 72))
        let x = Int(secret.minX) + 2..<Int(secret.maxX) - 2, y = 792 - Int(secret.maxY) + 2..<792 - Int(secret.minY) - 2
        XCTAssertGreaterThan(Double(count(image, x: x, y: y) { $0 < 64 && $1 < 64 && $2 < 64 }), 0.98 * Double(x.count * y.count))
        undo.undo()
        XCTAssertEqual(doc.pdf.findString("99-1234", withOptions: []).count, 1)
        XCTAssertTrue(doc.hasRedactions)
    }

    /// A redacted page is kept as a JPEG: drawn as it is, a page-sized photo would weigh over 20 MB.
    func testRedactedPhotoStaysAJPEG() async throws {
        let doc = FolioDocument(pdf: photoPDF())
        doc.pages[0].addAnnotation(shape(.redact, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 200, y: 150), color: .red))
        let redacted = await doc.applyRedactions()
        XCTAssertEqual(redacted, 1)
        XCTAssertLessThan(try XCTUnwrap(doc.pdf.dataRepresentation()).count, 10_000_000)
    }

    func testPictureOfAPageIsAsItShows() throws {
        let page = try XCTUnwrap(makePDF([["Top line"]]).page(at: 0))
        page.setBounds(CGRect(x: 0, y: 392, width: 612, height: 400), for: .cropBox)
        page.rotation = 90
        page.addAnnotation(shape(.rect, from: CGPoint(x: 400, y: 500), to: CGPoint(x: 500, y: 600), color: .red))
        let image = try XCTUnwrap(picture(of: page).flatMap { CGImageSourceCreateWithData($0 as CFData, nil) }.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        // Turned a quarter clockwise, the crop's 612 by 400 points show 400 wide and 612 tall.
        XCTAssertEqual([image.width, image.height], [800, 1224])
        // So the line at the crop's top left runs down its top right, the box is a little left of the middle, 400 points
        // down, and the crop's bottom left is blank paper.
        XCTAssertGreaterThan(count(image, x: 630..<700, y: 130..<300) { r, g, b in r < 100 && g < 100 && b < 100 }, 50)
        XCTAssertGreaterThan(count(image, x: 200..<430, y: 790..<1010) { r, g, b in r > 150 && g < 100 && b < 100 }, 100)
        XCTAssertEqual(count(image, x: 0..<200, y: 0..<700) { r, g, _ in r < 200 || g < 200 }, 0)
    }

    /// How many of the picture's pixels, in these columns and rows from the top left, are of this kind.
    private func count(_ image: CGImage, x: Range<Int>, y: Range<Int>, where kind: (UInt8, UInt8, UInt8) -> Bool) -> Int {
        let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
        return y.flatMap { row in x.map { col in bytes + (row * image.width + col) * 4 } }.filter { kind($0[0], $0[1], $0[2]) }.count
    }

    /// A page holding a 3840 by 2160 photo.
    private func photoPDF() -> PDFDocument {
        let pdf = PDFDocument()
        pdf.insert(FolioDocument.pages(from: [URL(fileURLWithPath: "/System/Library/Wallpapers/.default/DefaultAerial.jpg")])[0], at: 0)
        return pdf
    }

    /// How many of the grey picture's pixels are darker than mid grey.
    /// How many of the picture's pixels are dark.
    private func ink(_ picture: CGImage) -> Int {
        count(picture, x: 0..<picture.width, y: 0..<picture.height) { Int($0) + Int($1) + Int($2) < 3 * 128 }
    }
}
