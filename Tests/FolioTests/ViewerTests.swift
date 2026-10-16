import PDFKit
import XCTest
@testable import Folio

final class ViewerTests: XCTestCase {
    func testFindStepsWrapsAndClears() {
        let viewer = Viewer(doc: FolioDocument(pdf: makePDF([["apple pie", "apple tart"], ["green apple"]])))
        viewer.canvas.document = viewer.doc.pdf
        viewer.query = "Apple"
        viewer.find()
        XCTAssertEqual(viewer.matchLabel, "1 of 3")
        viewer.step(1)
        viewer.step(1)
        viewer.step(1)
        XCTAssertEqual(viewer.matchLabel, "1 of 3")
        viewer.step(-1)
        XCTAssertEqual(viewer.matchLabel, "3 of 3")
        viewer.query = "pear"
        viewer.find()
        XCTAssertEqual(viewer.matchLabel, "No matches")
        XCTAssertNil(viewer.canvas.currentSelection)
        viewer.step(1)
        viewer.query = ""
        viewer.find()
        XCTAssertEqual(viewer.matchLabel, "")
        XCTAssertTrue(viewer.canvas.highlightedSelections?.isEmpty ?? true)
    }

    func testTargetPagesFollowTheMode() {
        let viewer = Viewer(doc: FolioDocument(pdf: makePDF([["A"], ["B"], ["C"]])))
        viewer.canvas.document = viewer.doc.pdf
        let p = viewer.doc.pages
        viewer.canvas.go(to: p[1])
        XCTAssertEqual(viewer.targetPages, [p[1]])
        viewer.organizing = true
        viewer.selection = [p[2], p[0]]
        XCTAssertEqual(viewer.targetPages, [p[0], p[2]])
    }

    func testFilledFieldIsOneUndoableChange() {
        let pdf = makePDF([["Name:"]]), page = pdf.page(at: 0)!
        let field = PDFAnnotation(bounds: CGRect(x: 150, y: 700, width: 200, height: 24), forType: .widget, withProperties: nil)
        field.widgetFieldType = .text
        page.addAnnotation(field)
        let viewer = Viewer(doc: FolioDocument(pdf: pdf)), undo = manualUndo(viewer.doc)
        viewer.canvas.snapshotFields(on: page)
        field.widgetStringValue = "Joseph"
        act(undo) { viewer.canvas.commitFields() }
        XCTAssertEqual(undo.undoActionName, "Fill Form")
        undo.undo()
        XCTAssertEqual(field.widgetStringValue ?? "", "")
        let revision = viewer.doc.revision
        act(undo) { viewer.canvas.commitFields() }
        XCTAssertEqual(viewer.doc.revision, revision)   // nothing new since the last commit
    }
}
