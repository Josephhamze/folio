import PDFKit
import XCTest
@testable import Folio

final class AnnotationTests: XCTestCase {
    func testMarkupsCoverEachLine() {
        let pdf = makePDF([["First line here", "Second line here"]]), page = pdf.page(at: 0)!
        let marks = markups(page.selection(for: page.bounds(for: .mediaBox))!, type: .highlight, color: .yellow)
        XCTAssertEqual(marks.count, 2)
        XCTAssertEqual(marks.map { $0.annotation.type }, ["Highlight", "Highlight"])
        XCTAssertEqual(marks[0].annotation.quadrilateralPoints?.count, 4)
    }

    func testShapes() {
        XCTAssertEqual(shape(.rect, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 110, y: 60), color: .red).bounds,
                       CGRect(x: 10, y: 10, width: 100, height: 50))
        let arrow = shape(.arrow, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 10, y: 10), color: .red)
        XCTAssertEqual(arrow.type, "Line")
        XCTAssertEqual(arrow.endLineStyle, .openArrow)
        XCTAssertEqual(CGPoint(x: arrow.startPoint.x + arrow.bounds.minX, y: arrow.startPoint.y + arrow.bounds.minY), CGPoint(x: 100, y: 100))
        let redaction = shape(.redact, from: .zero, to: CGPoint(x: 50, y: 50), color: .red)
        XCTAssertTrue(redaction.isRedaction)
        XCTAssertFalse(redaction.isComment)
    }

    func testInkKeepsEveryStroke() {
        let a = ink([[CGPoint(x: 10, y: 10), CGPoint(x: 50, y: 40)], [CGPoint(x: 60, y: 10), CGPoint(x: 70, y: 20)]], color: .blue, width: 2)
        XCTAssertEqual(a.type, "Ink")
        XCTAssertEqual(a.paths?.count, 2)
        XCTAssertTrue(a.bounds.contains(CGPoint(x: 10, y: 10)) && a.bounds.contains(CGPoint(x: 70, y: 40)))
    }

    func testCoverLineMatchesWordsAndSize() {
        let page = makePDF([["Total due: R 1 250,00"]]).page(at: 0)!
        let cover = coverLine(at: CGPoint(x: 90, y: 725), on: page)!
        XCTAssertEqual(cover.type, "FreeText")
        XCTAssertEqual(cover.contents, "Total due: R 1 250,00")
        XCTAssertEqual(cover.font?.pointSize, 18)
        XCTAssertEqual(cover.color, .white)
        XCTAssertTrue(cover.bounds.contains(page.selectionForLine(at: CGPoint(x: 90, y: 725))!.bounds(for: page)))
        XCTAssertNil(coverLine(at: CGPoint(x: 300, y: 300), on: page))
    }

    func testSignatures() {
        let rect = CGRect(x: 0, y: 0, width: 200, height: 100)
        // Each fills the box one way and sits in its middle, keeping its shape: a stamp, not a text box or a comment.
        for signature in [Signature.drawn([[CGPoint(x: 0, y: 0), CGPoint(x: 40, y: 10)], [CGPoint(x: 20, y: 30)]]), .typed("Jo Hamze"), .typed("JH")] {
            let a = signature.annotation(in: rect)
            XCTAssertEqual(a.type, "Stamp")
            XCTAssertEqual(max(a.bounds.width / rect.width, a.bounds.height / rect.height), 1, accuracy: 0.001)
            XCTAssertEqual(a.bounds.midX, rect.midX, accuracy: 0.01)
            XCTAssertEqual(a.bounds.midY, rect.midY, accuracy: 0.01)
        }
        Signature[.sign] = .typed("X")
        Signature[.initial] = .typed("Y")
        XCTAssertEqual(Signature[.sign], .typed("X"))
        XCTAssertEqual(Signature[.initial], .typed("Y"))
        Signature[.sign] = nil
        Signature[.initial] = nil
        XCTAssertNil(Signature[.sign])
        XCTAssertNil(Signature[.initial])
    }

    func testSignatureIsOnePictureAtAnySizeAndInTheFile() {
        let doc = FolioDocument(pdf: makePDF([[]])), page = doc.pages[0]
        let scribble = Signature.drawn([(0..<40).map { CGPoint(x: Double($0) * 9, y: $0 % 2 == 0 ? 0 : 60 + Double($0)) }])
        let small = CGRect(x: 50, y: 600, width: 100, height: 40), large = CGRect(x: 50, y: 200, width: 300, height: 120)
        for rect in [small, large] { page.addAnnotation(scribble.annotation(in: rect)) }
        // Three times the size holds nine times the ink: its lines grow with it.
        XCTAssertEqual(Double(darkPixels(page, in: large)) / Double(darkPixels(page, in: small)), 9, accuracy: 0.5)
        // It is drawn into the saved file, and into the pages Extract and Split copy.
        let saved = PDFDocument(data: try! doc.snapshot(contentType: .pdf))!.page(at: 0)!
        XCTAssertEqual(Double(darkPixels(saved, in: large)), Double(darkPixels(page, in: large)), accuracy: 50)
        XCTAssertEqual(darkPixels(doc.extract([page]).page(at: 0)!, in: large), darkPixels(page, in: large))
    }

    /// The pixels of `rect` on the page, at four a point, that are darker than mid grey.
    private func darkPixels(_ page: PDFPage, in rect: CGRect) -> Int {
        let width = Int(rect.width) * 4, height = Int(rect.height) * 4
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: 4, y: 4)
        context.translateBy(x: -rect.minX, y: -rect.minY)
        page.draw(with: .mediaBox, to: context)
        let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
        return (0..<width * height).filter { pixels[$0] < 128 }.count
    }

    func testAddRemoveAndRecolourUndo() {
        let doc = FolioDocument(pdf: makePDF([["A"]])), undo = manualUndo(doc), page = doc.pages[0]
        let box = shape(.rect, from: .zero, to: CGPoint(x: 50, y: 50), color: .red)
        act(undo) { doc.add(box, to: page, name: "Add Rectangle") }
        XCTAssertEqual(doc.comments.count, 1)
        undo.undo()
        XCTAssertTrue(page.annotations.isEmpty)
        undo.redo()
        XCTAssertEqual(page.annotations.count, 1)
        act(undo) { doc.set(\.color, of: box, to: .blue, name: "Change Colour") }
        undo.undo()
        XCTAssertEqual(box.color, .red)
        act(undo) { doc.remove(box) }
        XCTAssertTrue(page.annotations.isEmpty)
        undo.undo()
        XCTAssertEqual(page.annotations.count, 1)
    }
}
