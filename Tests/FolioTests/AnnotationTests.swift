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
        let drawn = Signature.drawn([[CGPoint(x: 0, y: 0), CGPoint(x: 40, y: 10)]]).annotation(in: rect)
        XCTAssertEqual(drawn.type, "Ink")
        XCTAssertTrue(rect.insetBy(dx: -3, dy: -3).contains(drawn.bounds))
        let typed = Signature.typed("Jo Hamze").annotation(in: rect)
        XCTAssertEqual(typed.type, "FreeText")
        XCTAssertEqual(typed.font?.fontName, "SnellRoundhand")
        XCTAssertEqual(typed.contents, "Jo Hamze")
        XCTAssertTrue(rect.contains(typed.bounds))
        // Short initials keep their shape in the middle of a wide box, rather than starting at its left.
        let initials = Signature.typed("JH").annotation(in: rect)
        XCTAssertLessThan(initials.bounds.width, rect.width)
        XCTAssertEqual(initials.bounds.midX, rect.midX, accuracy: 0.01)
        Signature.saved = .typed("X")
        XCTAssertEqual(Signature.saved, .typed("X"))
        Signature.saved = nil
        XCTAssertNil(Signature.saved)
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
