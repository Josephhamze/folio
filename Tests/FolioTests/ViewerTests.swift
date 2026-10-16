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
}
