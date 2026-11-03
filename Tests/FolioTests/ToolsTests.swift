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
    func testRecognizeTextPutsTheWordsUnderTheScan() async throws {
        let doc = FolioDocument(pdf: scannedPDF([["Invoice 2026-117", "Cement 50 bags"], ["Delivered to Lubumbashi"]])), undo = manualUndo(doc)
        // The page keeps its marks, turn and crop.
        let page = doc.pages[0], look = ink(try XCTUnwrap(render(page, dpi: 72)))
        page.addAnnotation(shape(.rect, from: CGPoint(x: 400, y: 100), to: CGPoint(x: 450, y: 150), color: .red))
        page.rotation = 90
        page.setBounds(CGRect(x: 0, y: 50, width: 612, height: 742), for: .cropBox)
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
        let new = doc.pages[0]
        XCTAssertEqual(new.rotation, 90)
        XCTAssertEqual(new.bounds(for: .cropBox), CGRect(x: 0, y: 50, width: 612, height: 742))
        XCTAssertEqual(new.annotations.map(\.type), ["Square"])
        // It looks as it did, and its words are where they show, so a selection lands on them.
        XCTAssertEqual(Double(ink(try XCTUnwrap(render(new, dpi: 72)))), Double(look), accuracy: Double(look) / 100)
        let cement = try XCTUnwrap(doc.pdf.findString("Cement", withOptions: []).first).bounds(for: new)
        XCTAssertEqual(cement.minX, 72, accuracy: 6)
        XCTAssertEqual(cement.midY, 650, accuracy: 8)
        // One step, which puts the old pages back.
        XCTAssertEqual(undo.undoActionName, "Recognize Text")
        undo.undo()
        XCTAssertTrue(doc.pages[0] === page)
        XCTAssertEqual(texts(doc.pdf), ["", ""])
    }

    func testRecognizeTextReadsFrenchAndChinese() async {
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

    /// A page made from a photo has no page of a file to draw: it's read too, but not the marks on it.
    func testRecognizeTextReadsAPhotoPageButNotItsMarks() async throws {
        let scan = try XCTUnwrap(scannedPDF([["Received with thanks"]]).page(at: 0)).thumbnail(of: CGSize(width: 1224, height: 1584), for: .mediaBox)
        let page = try XCTUnwrap(PDFPage(image: scan)), note = textBox(at: CGPoint(x: 100, y: 300), on: page)
        note.contents = "Paid in full"
        page.addAnnotation(note)
        let doc = FolioDocument(pdf: PDFDocument())
        doc.pdf.insert(page, at: 0)
        let result = await doc.recognizeText { _, _ in }
        XCTAssertEqual(result.read, 1)
        let words = texts(doc.pdf)[0]
        XCTAssertTrue(words.contains("Received"), words)
        XCTAssertFalse(words.contains("Paid"), words)
        XCTAssertEqual(doc.pages[0].annotations.map(\.contents), ["Paid in full"])
    }

    func testReduceFileSizeShrinksPhotosAndKeepsTheMarks() async throws {
        let doc = FolioDocument(pdf: photoPDF()), undo = manualUndo(doc), original = doc.pdf
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

    /// A page holding a 3840 by 2160 photo.
    private func photoPDF() -> PDFDocument {
        let pdf = PDFDocument()
        pdf.insert(FolioDocument.pages(from: [URL(fileURLWithPath: "/System/Library/Wallpapers/.default/DefaultAerial.jpg")])[0], at: 0)
        return pdf
    }

    /// How many of the grey picture's pixels are darker than mid grey.
    private func ink(_ picture: CGImage) -> Int {
        let bytes = picture.dataProvider!.data! as Data
        return (0..<picture.height).reduce(0) { sum, row in
            sum + bytes[row * picture.bytesPerRow..<row * picture.bytesPerRow + picture.width].filter { $0 < 128 }.count
        }
    }
}
