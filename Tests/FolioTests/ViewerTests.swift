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

    func testNewTextBoxJoinsTheDocumentOnlyWithWords() {
        let viewer = Viewer(doc: FolioDocument(pdf: makePDF([["Name:"]]))), page = viewer.doc.pages[0], undo = manualUndo(viewer.doc)
        viewer.canvas.document = viewer.doc.pdf
        let words = { page.annotations.map { $0.contents ?? "" } }
        viewer.canvas.edit(textBox(at: CGPoint(x: 300, y: 725), on: page), on: page, adding: "Add Text")
        viewer.canvas.editor!.field.stringValue = "Jo"
        act(undo) { viewer.canvas.finishEditing() }
        XCTAssertEqual(words(), ["Jo"])
        XCTAssertEqual(undo.undoActionName, "Add Text")
        undo.undo()
        XCTAssertEqual(words(), [])
        // Left empty, a box is never added.
        viewer.canvas.edit(textBox(at: CGPoint(x: 300, y: 725), on: page), on: page, adding: "Add Text")
        act(undo) { viewer.canvas.finishEditing() }
        XCTAssertEqual(words(), [])
        // An emptied cover blanks out its line.
        viewer.canvas.edit(coverLine(at: CGPoint(x: 90, y: 725), on: page)!, on: page, adding: "Edit Text")
        viewer.canvas.editor!.field.stringValue = ""
        act(undo) { viewer.canvas.finishEditing() }
        XCTAssertEqual(words(), [""])
        XCTAssertEqual(undo.undoActionName, "Edit Text")
    }

    func testKeysPickToolsNudgeAndDeselect() {
        let viewer = Viewer(doc: FolioDocument(pdf: makePDF([["A"]]))), page = viewer.doc.pages[0], undo = manualUndo(viewer.doc)
        viewer.canvas.document = viewer.doc.pdf
        press("t", 17, on: viewer)
        XCTAssertEqual(viewer.tool, .text)
        press("v", 9, on: viewer)
        XCTAssertEqual(viewer.tool, .select)
        let box = shape(.rect, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 150, y: 150), color: .red)
        page.addAnnotation(box)
        viewer.canvas.selected = box
        act(undo) { press("\u{F703}", 124, on: viewer) }   // →
        XCTAssertEqual(box.bounds.minX, 101)
        act(undo) { press("\u{F700}", 126, [.shift], on: viewer) }   // ⇧↑
        XCTAssertEqual(box.bounds.minY, 110)
        undo.undo()
        XCTAssertEqual(box.bounds.minY, 100)
        press("\u{F703}", 124, [.command], on: viewer)   // ⌘→ is the page view's, not a nudge
        XCTAssertEqual(box.bounds.minX, 101)
        viewer.tool = .pen
        press("\u{1B}", 53, on: viewer)
        XCTAssertNil(viewer.canvas.selected)
        XCTAssertEqual(viewer.tool, .select)
        press("t", 17, [.command], on: viewer)
        XCTAssertEqual(viewer.tool, .select)
        // Read Mode has no tools.
        viewer.readMode = true
        press("h", 4, on: viewer)
        XCTAssertEqual(viewer.tool, .select)
        // A locked file can't be marked up, so its keys pick nothing.
        let data = makePDF([["A"]]).dataRepresentation(options: [PDFDocumentWriteOption.userPasswordOption: "pw", .ownerPasswordOption: "pw"])!
        let locked = Viewer(doc: FolioDocument(pdf: PDFDocument(data: data)!))
        press("t", 17, on: locked)
        XCTAssertEqual(locked.tool, .select)
    }

    private func press(_ key: String, _ code: UInt16, _ flags: NSEvent.ModifierFlags = [], on viewer: Viewer) {
        viewer.canvas.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                                                     context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: code)!)
    }

    func testFontsPanelSetsTheBoxBeingTyped() {
        let viewer = Viewer(doc: FolioDocument(pdf: makePDF([["Name:"]]))), page = viewer.doc.pages[0], undo = manualUndo(viewer.doc)
        viewer.canvas.document = viewer.doc.pdf
        let box = textBox(at: CGPoint(x: 300, y: 725), on: page)
        viewer.canvas.edit(box, on: page, adding: "Add Text")
        viewer.canvas.editor!.field.stringValue = "Jo"
        // Format › Font › Bigger, which the Fonts panel's size works through too.
        let bigger = NSMenuItem()
        bigger.tag = Int(NSFontAction.sizeUpFontAction.rawValue)
        act(undo) { NSFontManager.shared.modifyFont(bigger) }
        XCTAssertEqual(page.annotations.map { $0.contents ?? "" }, ["Jo"])
        XCTAssertEqual(box.font?.pointSize, 19)
        XCTAssertTrue(viewer.canvas.selected === box)
        XCTAssertNil(NSFontManager.shared.target)
    }

    func testClosingKeepsTheWordsBeingTyped() throws {
        let viewer = Viewer(doc: FolioDocument(pdf: makePDF([["Name:"]]))), page = viewer.doc.pages[0]
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("typing.pdf")
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let document = try Autosaving(contentsOf: file, ofType: "com.adobe.pdf")
        let window = NSWindow(contentRect: CGRect(x: -4000, y: -4000, width: 600, height: 400), styleMask: .borderless, backing: .buffered, defer: false)
        document.addWindowController(NSWindowController(window: window))
        window.contentView = viewer.canvas
        viewer.canvas.document = viewer.doc.pdf
        viewer.doc.undo = document.undoManager
        viewer.canvas.edit(textBox(at: CGPoint(x: 300, y: 725), on: page), on: page, adding: "Add Text")
        let typing = try XCTUnwrap(viewer.canvas.editor?.field.currentEditor() as? NSTextView)
        typing.insertText("Jo", replacementRange: NSRange(location: NSNotFound, length: 0))
        // As the close button, ⌘W and ⌘Q do.
        document.canClose(withDelegate: self, shouldClose: #selector(document(_:shouldClose:contextInfo:)), contextInfo: nil)
        for _ in 0..<20 where closes == nil { RunLoop.main.run(until: Date() + 0.05) }
        XCTAssertEqual(closes, true)
        XCTAssertEqual(page.annotations.map { $0.contents ?? "" }, ["Jo"])
        XCTAssertTrue(document.saved)
    }

    private var closes: Bool?
    @objc private func document(_ document: NSDocument, shouldClose: Bool, contextInfo: UnsafeMutableRawPointer?) { closes = shouldClose }

    private final class Autosaving: NSDocument {
        var saved = false
        override class var autosavesInPlace: Bool { true }
        override func read(from data: Data, ofType typeName: String) throws {}
        override func data(ofType typeName: String) throws -> Data {
            saved = true
            return Data()
        }
    }

    func testALockedFileOpensAtItsLastPageOnceUnlocked() {
        let data = makePDF([["A"], ["B"], ["C"]]).dataRepresentation(options: [PDFDocumentWriteOption.userPasswordOption: "pw", .ownerPasswordOption: "pw"])!
        let viewer = Viewer(doc: FolioDocument(pdf: PDFDocument(data: data)!))
        viewer.resume = 2
        viewer.showPages()
        XCTAssertNil(viewer.canvas.document)
        XCTAssertTrue(viewer.doc.unlock("pw"))
        viewer.showPages()
        for _ in 0..<20 where viewer.pageIndex != 2 { RunLoop.main.run(until: Date() + 0.05) }
        XCTAssertEqual(viewer.canvas.currentPage, viewer.doc.pages[2])
        XCTAssertEqual(viewer.pageIndex, 2)
    }

    func testPageBoxGoesAndClamps() {
        let viewer = Viewer(doc: FolioDocument(pdf: makePDF([["A"], ["B"], ["C"]]))), p = viewer.doc.pages
        viewer.canvas.document = viewer.doc.pdf
        viewer.go(toPage: 2)
        XCTAssertEqual(viewer.canvas.currentPage, p[1])
        XCTAssertEqual(viewer.pageIndex, 1)
        viewer.go(toPage: 99)
        XCTAssertEqual(viewer.canvas.currentPage, p[2])
        viewer.go(toPage: 0)
        XCTAssertEqual(viewer.canvas.currentPage, p[0])
        XCTAssertEqual(viewer.pageIndex, 0)
    }

    func testLastPageKeepsOnlyRecentFiles() {
        defer { UserDefaults.standard.removeObject(forKey: "pages") }
        let a = URL(fileURLWithPath: "/tmp/a.pdf"), b = URL(fileURLWithPath: "/tmp/b.pdf")
        Viewer.remember(page: 3, of: a)
        Viewer.remember(page: 5, of: b)
        // The test runner has no recent files, so only the file just remembered keeps its page.
        XCTAssertNil(Viewer.lastPage(of: a))
        XCTAssertEqual(Viewer.lastPage(of: b), 5)
    }

    func testClickSelectsTogglesAndExtends() {
        let viewer = Viewer(doc: FolioDocument(pdf: makePDF([["A"], ["B"], ["C"], ["D"]]))), p = viewer.doc.pages
        viewer.click(p[1], modifiers: [])
        XCTAssertEqual(viewer.selection, [p[1]])
        viewer.click(p[3], modifiers: .command)
        XCTAssertEqual(viewer.selection, [p[1], p[3]])
        viewer.click(p[1], modifiers: .command)
        XCTAssertEqual(viewer.selection, [p[3]])
        viewer.click(p[0], modifiers: [])
        viewer.click(p[2], modifiers: .shift)
        XCTAssertEqual(viewer.selection, [p[0], p[1], p[2]])
    }

    func testDropMovesTheSelection() {
        let viewer = Viewer(doc: FolioDocument(pdf: makePDF([["A"], ["B"], ["C"], ["D"]]))), p = viewer.doc.pages
        _ = manualUndo(viewer.doc)
        viewer.doc.undo?.beginUndoGrouping()
        viewer.selection = [p[0], p[1]]
        viewer.drop(p[0], before: p[3])
        XCTAssertEqual(texts(viewer.doc.pdf), ["C", "A", "B", "D"])
        viewer.drop(p[3], before: p[2])
        XCTAssertEqual(texts(viewer.doc.pdf), ["D", "C", "A", "B"])
        viewer.drop(p[3], before: nil)
        XCTAssertEqual(texts(viewer.doc.pdf), ["C", "A", "B", "D"])
        viewer.doc.undo?.endUndoGrouping()
    }

    func testAnnotationsAreDrawnAtTheScreensPixels() {
        let viewer = Viewer(doc: FolioDocument(pdf: makePDF([[]]))), page = viewer.doc.pages[0]
        page.addAnnotation(Signature.typed("Jo").annotation(in: CGRect(x: 100, y: 600, width: 100, height: 50)))
        // Off the screen, so the test shows nothing.
        let window = NSWindow(contentRect: CGRect(x: -4000, y: -4000, width: 600, height: 400), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = viewer.canvas
        viewer.canvas.document = viewer.doc.pdf
        viewer.canvas.scaleFactor = 3
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        // The layer PDFKit draws each annotation into, at a pixel a point unless Folio redraws it.
        let layers = {
            var found: [CALayer] = []
            func walk(_ layer: CALayer) {
                if NSStringFromClass(type(of: layer)) == "PDFPageLayerAnnotationEffect" { found.append(layer) }
                layer.sublayers?.forEach(walk)
            }
            walk(viewer.canvas.layer!)
            return found
        }
        let sharp = { (count: Int) in layers().count == count && layers().allSatisfy { $0.contentsScale == 3 * window.backingScaleFactor } }
        for _ in 0..<100 where !sharp(1) { RunLoop.main.run(until: Date() + 0.05) }
        XCTAssertTrue(sharp(1), "\(layers().map(\.contentsScale))")
        // One added later, as each change is.
        page.addAnnotation(Signature.typed("JH").annotation(in: CGRect(x: 100, y: 500, width: 100, height: 50)))
        viewer.canvas.sharpenAnnotations()
        for _ in 0..<100 where !sharp(2) { RunLoop.main.run(until: Date() + 0.05) }
        XCTAssertTrue(sharp(2), "\(layers().map(\.contentsScale))")
    }
}
