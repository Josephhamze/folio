import PDFKit
import UIKit
import XCTest
@testable import Folio

/// Letter pages holding these lines in Georgia 18, 72 points from the left and 25 apart from 60 below the top.
private func makePDF(_ pages: [[String]]) -> PDFDocument {
    PDFDocument(data: UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792)).pdfData { context in
        for lines in pages {
            context.beginPage()
            for (row, line) in lines.enumerated() {
                line.draw(at: CGPoint(x: 72, y: 60 + CGFloat(row) * 25), withAttributes: [.font: UIFont(name: "Georgia", size: 18)!])
            }
        }
    })!
}

private func act(_ undo: UndoManager, _ change: () -> Void) {
    undo.beginUndoGrouping()
    change()
    undo.endUndoGrouping()
}

/// A one-finger drag between view points, as the pan reports it.
private func drag(_ canvas: Canvas, _ from: CGPoint, _ to: CGPoint) {
    canvas.panned(.began, at: from)
    canvas.panned(.changed, at: to)
    canvas.panned(.ended, at: to)
}

/// The view points just inside the ends of a page's line.
private func ends(ofLine row: Int, on page: PDFPage, in canvas: Canvas) -> (start: CGPoint, end: CGPoint) {
    let line = page.selection(for: page.bounds(for: .mediaBox))!.selectionsByLine()[row].bounds(for: page)
    return (canvas.convert(CGPoint(x: line.minX + 1, y: line.midY), from: page), canvas.convert(CGPoint(x: line.maxX - 1, y: line.midY), from: page))
}

/// How many marks show once PDFKit has drawn: it draws each in a layer of its own.
private func shownMarks(_ canvas: Canvas) -> Int {
    RunLoop.main.run(until: Date() + 0.3)
    var count = 0
    func walk(_ layer: CALayer) {
        if NSStringFromClass(type(of: layer)) == "PDFPageLayerAnnotationEffect", !layer.isHidden { count += 1 }
        layer.sublayers?.forEach(walk)
    }
    walk(canvas.layer)
    return count
}

final class TouchTests: XCTestCase {
    /// The page view lays its pages out only in a window, kept for the test.
    private var window: UIWindow?

    /// A viewer of `pdf` with its page view in a phone-sized window, and an undo manager that groups only when told.
    private func host(_ pdf: PDFDocument) -> (Viewer, UndoManager) {
        let viewer = Viewer(doc: FolioDocument(pdf: pdf)), undo = UndoManager()
        undo.groupsByEvent = false
        viewer.doc.undo = undo
        let window = UIWindow(windowScene: UIApplication.shared.connectedScenes.first as! UIWindowScene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        viewer.canvas.frame = window.bounds
        window.addSubview(viewer.canvas)
        window.isHidden = false
        viewer.showPages()
        viewer.canvas.layoutIfNeeded()
        self.window = window
        return (viewer, undo)
    }

    func testAppLaunchesWithAPageView() {
        XCTAssertNotNil(host(FolioDocument().pdf).0.canvas.document)
    }

    func testDragAcrossTextHighlightsIt() {
        let (viewer, undo) = host(makePDF([["Highlight this line"]]))
        let canvas = viewer.canvas, page = viewer.doc.pages[0], line = ends(ofLine: 0, on: page, in: canvas)
        viewer.tool = .highlight
        act(undo) { drag(canvas, line.start, line.end) }
        XCTAssertEqual(page.annotations.map(\.type), ["Highlight"])
        XCTAssertEqual(undo.undoActionName, "Highlight")
    }

    func testHighlightAcrossAPageBreakMarksBothPages() {
        let (viewer, undo) = host(makePDF([["First page", "Its last line"], ["Second page"]]))
        let canvas = viewer.canvas, pages = viewer.doc.pages
        viewer.tool = .highlight
        act(undo) { drag(canvas, ends(ofLine: 1, on: pages[0], in: canvas).start, ends(ofLine: 0, on: pages[1], in: canvas).end) }
        let highlights = { pages.map { $0.annotations.filter { $0.type == "Highlight" }.count } }
        XCTAssertEqual(highlights(), [1, 1])
        undo.undo()
        XCTAssertEqual(highlights(), [0, 0])
    }

    func testDragDrawsAShapeAsOneStep() {
        let (viewer, undo) = host(makePDF([["Hi"]]))
        let canvas = viewer.canvas, page = viewer.doc.pages[0]
        viewer.tool = .oval
        act(undo) { drag(canvas, canvas.convert(CGPoint(x: 100, y: 300), from: page), canvas.convert(CGPoint(x: 200, y: 360), from: page)) }
        XCTAssertEqual(page.annotations.map(\.type), ["Circle"])
        XCTAssertEqual(undo.undoActionName, "Add Shape")
    }

    func testTapAddsANoteWhereTapped() throws {
        let (viewer, _) = host(makePDF([["Hi"]]))
        let canvas = viewer.canvas, page = viewer.doc.pages[0]
        canvas.scaleFactor = 2
        canvas.go(to: CGRect(x: 150, y: 450, width: 100, height: 100), on: page)
        viewer.tool = .note
        canvas.tapped(at: canvas.convert(CGPoint(x: 200, y: 500), from: page))
        let note = try XCTUnwrap(page.annotations.first)
        XCTAssertEqual(note.type, "Text")
        XCTAssertEqual(note.bounds.midX, 200, accuracy: 0.5)
        XCTAssertEqual(note.bounds.midY, 500, accuracy: 0.5)
        XCTAssertTrue(viewer.showsPanes)
        XCTAssertEqual(viewer.tool, .select)
        XCTAssertTrue(canvas.selected === note)
    }

    func testTextBoxJoinsOnlyWithWords() throws {
        let (viewer, undo) = host(makePDF([["Name:"]]))
        let canvas = viewer.canvas, page = viewer.doc.pages[0], point = canvas.convert(CGPoint(x: 300, y: 600), from: page)
        viewer.tool = .text
        canvas.tapped(at: point)
        try XCTUnwrap(canvas.editor).field.text = ""
        act(undo) { viewer.settle() }
        XCTAssertEqual(page.annotations.count, 0)
        viewer.tool = .text
        canvas.tapped(at: point)
        try XCTUnwrap(canvas.editor).field.text = "Jo"
        act(undo) { viewer.settle() }
        XCTAssertEqual(page.annotations.map(\.contents), ["Jo"])
        XCTAssertEqual(undo.undoActionName, "Add Text")
    }

    func testEditorSitsOverTheBoxAtThePagesZoom() throws {
        let (viewer, _) = host(makePDF([["Name:"]]))
        let canvas = viewer.canvas, page = viewer.doc.pages[0]
        canvas.scaleFactor = 2
        canvas.go(to: CGRect(x: 250, y: 650, width: 100, height: 100), on: page)
        viewer.tool = .text
        canvas.tapped(at: canvas.convert(CGPoint(x: 300, y: 700), from: page))
        let editor = try XCTUnwrap(canvas.editor)
        let shown = editor.field.convert(editor.field.bounds, to: canvas), box = canvas.convert(editor.box.bounds, from: page)
        XCTAssertEqual(shown.minX, box.minX, accuracy: 0.5)
        XCTAssertEqual(shown.minY, box.minY, accuracy: 0.5)
        XCTAssertEqual(shown.height, box.height, accuracy: 0.5)
        // The words show at the box's size times the zoom.
        let onScreen = editor.field.font!.pointSize * editor.field.convert(CGRect(x: 0, y: 0, width: 1, height: 1), to: canvas).height
        XCTAssertEqual(onScreen, editor.box.font!.pointSize * 2, accuracy: 0.01)
    }

    func testSelectedMarkDragsAndOthersScroll() throws {
        let (viewer, undo) = host(makePDF([["Hi"]]))
        let canvas = viewer.canvas, page = viewer.doc.pages[0], at = { (point: CGPoint) in canvas.convert(point, from: page) }
        let square = shape(.rect, from: CGPoint(x: 100, y: 300), to: CGPoint(x: 200, y: 360), color: .red)
        page.addAnnotation(square)
        canvas.selected = square
        XCTAssertTrue(canvas.pans(at: at(CGPoint(x: 150, y: 330))))
        XCTAssertFalse(canvas.pans(at: at(CGPoint(x: 300, y: 500))))
        XCTAssertEqual(canvas.pan.maximumNumberOfTouches, 1)
        let scroll = try XCTUnwrap(canvas.documentView?.superview as? UIScrollView)
        XCTAssertEqual(canvas.pan.delegate?.gestureRecognizer?(canvas.pan, shouldBeRequiredToFailBy: scroll.panGestureRecognizer), true)
        act(undo) { drag(canvas, at(CGPoint(x: 150, y: 330)), at(CGPoint(x: 170, y: 340))) }
        XCTAssertEqual(square.bounds.minX, 120, accuracy: 0.5)
        XCTAssertEqual(square.bounds.minY, 310, accuracy: 0.5)
        XCTAssertEqual(undo.undoActionName, "Move")
    }

    /// A placed signature is selected, so a drag moves it straight away, rather than scrolling the page.
    func testPlacedSignatureDragsStraightAway() throws {
        let saved = Signature[.sign]
        defer { Signature[.sign] = saved }
        Signature[.sign] = .typed("Jo")
        let (viewer, undo) = host(makePDF([["Hi"]]))
        let canvas = viewer.canvas, page = viewer.doc.pages[0], at = { (point: CGPoint) in canvas.convert(point, from: page) }
        viewer.tool = .sign
        act(undo) { canvas.tapped(at: at(CGPoint(x: 300, y: 300))) }
        let signature = try XCTUnwrap(page.annotations.first)
        XCTAssertTrue(canvas.pans(at: at(CGPoint(x: 300, y: 300))))
        act(undo) { drag(canvas, at(CGPoint(x: 300, y: 300)), at(CGPoint(x: 320, y: 280))) }
        XCTAssertEqual(signature.bounds.midX, 320, accuracy: 0.5)
        XCTAssertEqual(signature.bounds.midY, 280, accuracy: 0.5)
        XCTAssertEqual(undo.undoActionName, "Move")
        act(undo) { canvas.deleteMark() }
        XCTAssertTrue(page.annotations.isEmpty)
        XCTAssertNil(viewer.mark)
    }

    /// A tap that slips a little, as a finger's does, places the usual signature, not one the size of the slip.
    func testSlippedTapPlacesTheUsualSignature() {
        let saved = Signature[.sign]
        defer { Signature[.sign] = saved }
        Signature[.sign] = .typed("Jo")
        let (viewer, undo) = host(makePDF([["Hi"]]))
        let canvas = viewer.canvas, page = viewer.doc.pages[0], at = { (point: CGPoint) in canvas.convert(point, from: page) }
        viewer.tool = .sign
        act(undo) { canvas.tapped(at: at(CGPoint(x: 300, y: 300))) }
        viewer.tool = .sign
        act(undo) { drag(canvas, at(CGPoint(x: 300, y: 500)), at(CGPoint(x: 308, y: 509))) }
        XCTAssertEqual(page.annotations.map(\.bounds.size), [page.annotations[0].bounds.size, page.annotations[0].bounds.size])
    }

    func testSignatureLeavesNothingBehindOnTheScreen() {
        let saved = Signature[.sign]
        defer { Signature[.sign] = saved }
        Signature[.sign] = .typed("Jo")
        let (viewer, undo) = host(makePDF([["Hi"]]))
        let canvas = viewer.canvas, page = viewer.doc.pages[0], at = { (point: CGPoint) in canvas.convert(point, from: page) }
        viewer.tool = .sign
        // Dragged to size, the screen drawn between moves as it is under a finger.
        act(undo) {
            canvas.panned(.began, at: at(CGPoint(x: 100, y: 300)))
            for x: CGFloat in [200, 250, 300] {
                canvas.panned(.changed, at: at(CGPoint(x: x, y: 380)))
                XCTAssertEqual(shownMarks(canvas), 1)
            }
            canvas.panned(.ended, at: at(CGPoint(x: 300, y: 380)))
        }
        XCTAssertEqual(page.annotations.map(\.type), ["Stamp"])
        XCTAssertEqual(shownMarks(canvas), 1)
        undo.undo()
        XCTAssertEqual(shownMarks(canvas), 0)
        undo.redo()
        XCTAssertEqual(shownMarks(canvas), 1)
        act(undo) { viewer.doc.remove(page.annotations[0]) }
        XCTAssertEqual(shownMarks(canvas), 0)
    }

    /// Return, a tap or a drag leaves the keys with the page, where iPad's Edit menu sends Undo, Redo and Copy, but not a tap
    /// on a form field, which PDFKit gives them to.
    func testPageTakesTheKeys() throws {
        let (viewer, _) = host(makePDF([["Hi"]]))
        let canvas = viewer.canvas, page = viewer.doc.pages[0], pages = try XCTUnwrap(canvas.documentView)
        let at = { (point: CGPoint) in canvas.convert(point, from: page) }
        viewer.tool = .text
        canvas.tapped(at: at(CGPoint(x: 300, y: 600)))
        let field = try XCTUnwrap(canvas.editor).field
        XCTAssertTrue(field.isFirstResponder)
        field.sendActions(for: .editingDidEndOnExit)   // Return
        XCTAssertTrue(pages.isFirstResponder)
        pages.resignFirstResponder()
        canvas.tapped(at: at(CGPoint(x: 300, y: 500)))
        XCTAssertTrue(pages.isFirstResponder)
        pages.resignFirstResponder()
        viewer.tool = .rect
        drag(canvas, at(CGPoint(x: 100, y: 300)), at(CGPoint(x: 200, y: 360)))
        XCTAssertTrue(pages.isFirstResponder)
        pages.resignFirstResponder()
        let widget = PDFAnnotation(bounds: CGRect(x: 100, y: 100, width: 200, height: 30), forType: .widget, withProperties: nil)
        widget.widgetFieldType = .text
        page.addAnnotation(widget)
        canvas.tapped(at: at(CGPoint(x: 150, y: 115)))
        XCTAssertFalse(pages.isFirstResponder)
    }

    /// Restricted by its author, the file shows its pages, which take no marks. A locked file shows none to touch.
    func testRestrictedFileTakesNoTouch() {
        let data = makePDF([["A"]]).dataRepresentation(options: [PDFDocumentWriteOption.ownerPasswordOption: "pw",
                                                                 PDFDocumentWriteOption.accessPermissionsOption: PDFAccessPermissions.allowsLowQualityPrinting.rawValue])!
        let (viewer, _) = host(PDFDocument(data: data)!)
        let canvas = viewer.canvas, page = viewer.doc.pages[0], point = canvas.convert(CGPoint(x: 100, y: 300), from: page)
        XCTAssertNotNil(canvas.document)
        viewer.tool = .pen
        XCTAssertFalse(canvas.pans(at: point))
        viewer.tool = .note
        canvas.tapped(at: point)
        XCTAssertTrue(page.annotations.isEmpty)
    }
}
