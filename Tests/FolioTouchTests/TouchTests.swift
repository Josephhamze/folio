import ImageIO
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

    /// The app carries Folio's French and Chinese, and the camera's reason in both.
    func testAppSpeaksFrenchAndChinese() throws {
        for (language, organize, camera) in [("fr", "Organiser les pages", "Folio numérise"), ("zh-Hans", "整理页面", "Folio 使用相机")] {
            let bundle = try XCTUnwrap(Bundle.main.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:)))
            XCTAssertEqual(bundle.localizedString(forKey: "Organize Pages", value: nil, table: nil), organize)
            XCTAssertTrue(bundle.localizedString(forKey: "NSCameraUsageDescription", value: nil, table: "InfoPlist").hasPrefix(camera))
        }
    }

    /// A phone's photo, kept on its side with a note to turn it, goes on its page as it's seen: here red over blue.
    func testPhotoGoesOnItsPageUpright() throws {
        // Kept 1600 by 800, bigger than a page, red left and blue right, with the note an iPhone puts on a photo taken upright:
        // turn it right. A picture smaller than a page sits in its middle, as it is.
        let kept = CGContext(data: nil, width: 1600, height: 800, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        kept.setFillColor(UIColor.red.cgColor)
        kept.fill(CGRect(x: 0, y: 0, width: 800, height: 800))
        kept.setFillColor(UIColor.blue.cgColor)
        kept.fill(CGRect(x: 800, y: 0, width: 800, height: 800))
        let photo = NSMutableData(), file = CGImageDestinationCreateWithData(photo, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(file, kept.makeImage()!, [kCGImagePropertyOrientation: 6] as CFDictionary)
        CGImageDestinationFinalize(file)

        let page = try XCTUnwrap(FolioDocument.pages(from: photo as Data, isPDF: false).first)
        let box = page.bounds(for: .mediaBox)
        XCTAssertLessThan(box.width, box.height)
        let seen = try XCTUnwrap(page.thumbnail(of: CGSize(width: box.width / 10, height: box.height / 10), for: .mediaBox).cgImage)
        let (width, height) = (seen.width, seen.height)
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(seen, in: CGRect(x: 0, y: 0, width: width, height: height))
        // Row by row from the top: red and blue down the middle of the page, a third of the way down, and two thirds.
        let pixels = UnsafeBufferPointer(start: context.data!.assumingMemoryBound(to: UInt8.self), count: width * height * 4)
        let colour = { (down: Double) in (red: pixels[(Int(Double(height) * down) * width + width / 2) * 4],
                                          blue: pixels[(Int(Double(height) * down) * width + width / 2) * 4 + 2]) }
        XCTAssertGreaterThan(colour(1 / 3).red, colour(1 / 3).blue)
        XCTAssertGreaterThan(colour(2 / 3).blue, colour(2 / 3).red)
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

    /// Reading, a tap leaves a mark unpicked; in Markup it picks it, and a drag on it moves it while others scroll.
    func testSelectedMarkDragsAndOthersScroll() throws {
        let (viewer, undo) = host(makePDF([["Hi"]]))
        let canvas = viewer.canvas, page = viewer.doc.pages[0], at = { (point: CGPoint) in canvas.convert(point, from: page) }
        let square = shape(.rect, from: CGPoint(x: 100, y: 300), to: CGPoint(x: 200, y: 360), color: .red)
        page.addAnnotation(square)
        canvas.tapped(at: at(CGPoint(x: 150, y: 330)))
        XCTAssertNil(canvas.selected)
        viewer.markingUp = true
        canvas.tapped(at: at(CGPoint(x: 150, y: 330)))
        XCTAssertTrue(canvas.selected === square)
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

    /// A tool ends Find, and one Done ends Markup with Organize Pages started over it.
    func testToolEndsFindAndDoneEndsEveryMode() {
        let (viewer, _) = host(makePDF([["Hi"]]))
        viewer.finding = true
        viewer.query = "Hi"
        viewer.tool = .pen
        XCTAssertTrue(viewer.markingUp)
        XCTAssertFalse(viewer.finding)
        XCTAssertEqual(viewer.query, "")
        viewer.organize()
        viewer.backToReading()
        XCTAssertFalse(viewer.organizing)
        XCTAssertFalse(viewer.markingUp)
        XCTAssertEqual(viewer.tool, .select)
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

    /// A tap places the stamp at its usual size, selected, so the tool bar's Add to Every Page puts it on the other pages;
    /// the date tool's tap places today's date, and its drag scrolls.
    func testTapsPlaceAStampOnEveryPageAndTheDate() throws {
        let saved = Signature[.stamp]
        defer { Signature[.stamp] = saved }
        Signature[.stamp] = .typed("ACME SARL")
        let (viewer, undo) = host(makePDF([["Date:"], ["Page two"]]))
        let canvas = viewer.canvas, page = viewer.doc.pages[0], at = { (point: CGPoint) in canvas.convert(point, from: page) }
        viewer.tool = .stamp
        act(undo) { canvas.tapped(at: at(CGPoint(x: 300, y: 300))) }
        let stamp = try XCTUnwrap(page.annotations.first)
        XCTAssertEqual(stamp.bounds.midX, 300, accuracy: 0.5)
        XCTAssertEqual(max(stamp.bounds.width, stamp.bounds.height), 120, accuracy: 0.5)
        XCTAssertTrue(canvas.selected === stamp)
        XCTAssertTrue(viewer.canAddToEveryPage)
        act(undo) { viewer.addToEveryPage() }
        XCTAssertEqual(viewer.doc.pages[1].annotations.map(\.type), ["Stamp"])
        XCTAssertEqual(undo.undoActionName, "Add to Every Page")
        viewer.tool = .date
        XCTAssertFalse(canvas.pans(at: at(CGPoint(x: 300, y: 500))))
        act(undo) { canvas.tapped(at: at(CGPoint(x: 300, y: 500))) }
        let date = try XCTUnwrap(page.annotations.last)
        XCTAssertEqual(date.type, "FreeText")
        XCTAssertEqual(date.contents, Date.now.formatted(date: .numeric, time: .omitted))
        XCTAssertTrue(canvas.selected === date)
        XCTAssertEqual(undo.undoActionName, "Add Date")
    }

    /// A page sent as a picture is the page at two pixels a point.
    func testPageSentAsAPicture() throws {
        let page = try XCTUnwrap(makePDF([["Hi"]]).page(at: 0))
        let image = try XCTUnwrap(picture(of: page).flatMap { CGImageSourceCreateWithData($0 as CFData, nil) }.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        XCTAssertEqual([image.width, image.height], [1224, 1584])
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
