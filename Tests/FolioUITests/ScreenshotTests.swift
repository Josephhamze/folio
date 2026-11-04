import XCTest

/// Needs the PDFs from this folder in Folio's Documents folder on the simulator, which `./build.sh ios-test` puts there.
final class ScreenshotTests: XCTestCase {
    private let app = XCUIApplication()

    /// The App Store's screenshots, which `./build.sh screenshots` takes: a sample marked up and signed, the signature pad,
    /// the panes, the password sheet and the organizer.
    func testScreenshots() {
        openSample("Garden Brief")
        // A point on the first page, in its 612 by 792 points from the top left.
        let page = app.textViews.firstMatch.children(matching: .other).firstMatch
        let at = { (x: CGFloat, y: CGFloat) in page.coordinate(withNormalizedOffset: CGVector(dx: x / 612, dy: y / 792)) }

        choose("Highlight")
        drag(at(76, 357), at(404, 357))   // the first goal
        choose("Text Box")
        at(360, 379).tap()   // beside the second
        app.typeText("Love this!")
        at(580, 300).tap()   // in the margin
        choose("Sign")
        // The pad, unless an earlier test saved a signature.
        if app.buttons["Type"].waitForExistence(timeout: 2) {
            app.buttons["Type"].tap()
            app.textFields["Your name"].tap()
            app.typeText("Maria Santos")
            shot("2 Sign")
            app.buttons["Save"].tap()
        }
        at(450, 675).tap()   // under the budget
        at(580, 300).tap()   // in the margin, to put down the signature, which is selected once placed
        waitUntilGone("Tap where")
        shot("1 Mark up")

        done()
        waitUntilGone("Folio saves")
        showPanes()
        shot("3 Pages")

        closePanes()
        tools("Password…")
        let restrict = app.switches["Restrict printing, copying and changes"]
        XCTAssertTrue(restrict.waitForExistence(timeout: 5))
        // A switch turns where its knob is, not where its words are.
        restrict.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        shot("5 Protect")
        app.buttons["Cancel"].tap()

        // Last, since organizing leaves the page out of reach.
        tools("Organize Pages")
        let second = app.buttons["Page 2"]
        XCTAssertTrue(second.waitForExistence(timeout: 5))
        second.tap()
        shot("4 Organize")
    }

    /// Marks up the sample by touch, as a person would, with a screenshot after each step.
    func testMarkUpByTouch() {
        openSample()
        choose("Highlight")
        let line = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Section 1.'")).firstMatch.frame
        let blank = point(line.maxX - 60, line.minY - 30)
        drag(point(line.minX + 2, line.minY + 5), point(line.maxX - 2, line.minY + 5))
        XCTAssertTrue(undo.isEnabled)
        // From where the finger went down: the line's first letters are marked.
        XCTAssertGreaterThan(yellow(in: CGRect(x: line.minX, y: line.minY + 1, width: 8, height: 7)), 0.3)
        shot("highlight")

        choose("Rectangle")
        drag(point(line.maxX - 120, line.minY - 45), point(line.maxX - 10, line.minY - 15))
        shot("rectangle")

        choose("Text Box")
        point(line.minX + 10, line.maxY + 140).tap()
        app.typeText("Typed on a phone")
        shot("typing")
        blank.tap()
        shot("text box")

        choose("Sign")
        if app.buttons["Type"].waitForExistence(timeout: 2) {
            app.buttons["Type"].tap()
            app.textFields["Your name"].tap()
            app.typeText("Joseph Hamze")
            shot("signature pad")
            app.buttons["Save"].tap()
        }
        point(line.midX, line.maxY + 60).tap()
        shot("signature")

        // What acts on a mark shows while one is selected.
        let delete = app.buttons["Delete"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5))   // the signature, selected once placed
        undo.tap()
        shot("undone")
        XCTAssertTrue(delete.waitForNonExistence(timeout: 5))
        choose("Select")
        point(line.maxX - 65, line.minY - 30).tap()
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        shot("selected")
        delete.tap()
        shot("deleted")
        XCTAssertTrue(delete.waitForNonExistence(timeout: 5))

        done()
        showPanes()
        for pane in ["Thumbnails", "Bookmarks", "Comments"] {
            app.buttons[pane].firstMatch.tap()
            shot(pane)
        }
        closePanes()

        find("Folio")
        XCTAssertTrue(app.staticTexts["1 of 42"].waitForExistence(timeout: 5))
        shot("find")
        app.buttons["Next"].tap()
        XCTAssertTrue(app.staticTexts["2 of 42"].exists)
        shot("find next")
        app.buttons["Cancel"].tap()

        barButton("Share")
        XCTAssertTrue(app.descendants(matching: .any)["Copy"].waitForExistence(timeout: 10))
        shot("share")
        point(200, 700).tap()   // below the sheet

        // Words being typed are kept when the app goes to the background.
        choose("Text Box")
        point(line.minX + 10, line.maxY + 330).tap()
        app.typeText("Kept after Home")
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10))
        app.activate()
        // Going ended the typing, so no keyboard waits for more, and Done has nothing left to put in.
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        done()
        showPanes()
        app.buttons["Comments"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "value == 'Kept after Home'")).firstMatch.waitForExistence(timeout: 5))
        shot("kept")
        closePanes()

        // Two fingers zoom, and draw nothing, with the pen.
        choose("Pen")
        app.textViews.firstMatch.pinch(withScale: 2, velocity: 1)
        shot("pen pinch")
    }

    /// A finger held still before it drags sizes the signature, rather than selecting the text under it; with Select, a long
    /// press still selects text.
    func testHeldDragSizesTheSignature() {
        openSample()
        choose("Sign")   // none saved yet: the pad, at once
        XCTAssertTrue(app.buttons["Type"].waitForExistence(timeout: 5))
        app.buttons["Type"].tap()
        app.textFields["Your name"].tap()
        app.typeText("Joseph Hamze")
        app.buttons["Save"].tap()
        let line = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Section 3.'")).firstMatch.frame
        point(line.minX + 20, line.minY + 10).press(forDuration: 1, thenDragTo: point(line.minX + 250, line.maxY + 60), withVelocity: .slow,
                                                     thenHoldForDuration: 0.1)
        shot("held drag")
        XCTAssertTrue(undo.isEnabled)
        XCTAssertFalse(app.menuItems["Copy"].exists)
        point(line.minX + 20, line.minY + 10).press(forDuration: 1)
        XCTAssertTrue(app.menuItems["Copy"].waitForExistence(timeout: 3))
        shot("long press")
    }

    /// iPad's menu bar and its keys act on the document in front, ⌘Z included.
    func testMenuBarActsOnTheDocument() throws {
        try XCTSkipUnless(pad, "The menu bar is iPad's.")
        openSample()
        let line = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Section 1.'")).firstMatch.frame
        app.typeKey("f", modifierFlags: .command)
        let field = app.textFields["Find"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        expectation(for: NSPredicate(format: "hasKeyboardFocus == true"), evaluatedWith: field)
        waitForExpectations(timeout: 5)
        app.typeText("Folio")
        app.typeKey("g", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["2 of 42"].waitForExistence(timeout: 5))
        // Off the find field nothing is first responder, and the keys still find.
        point(line.midX, line.minY - 30).tap()
        app.typeKey("g", modifierFlags: [.command, .shift])
        XCTAssertTrue(app.staticTexts["1 of 42"].waitForExistence(timeout: 5))
        app.typeKey("3", modifierFlags: [.command, .option])
        XCTAssertTrue(app.buttons["Comments"].waitForExistence(timeout: 5))
        app.typeKey("+", modifierFlags: .command)
        shot("menu keys")
        app.typeKey("p", modifierFlags: .command)
        let options = app.navigationBars["Options"]   // the print sheet
        XCTAssertTrue(options.waitForExistence(timeout: 5))
        shot("print")
        options.buttons["Close"].tap()
        app.buttons["Cancel"].tap()   // Find, for the reading bar's Markup
        choose("Rectangle")
        drag(point(line.minX + 20, line.minY - 40), point(line.minX + 120, line.minY - 10))
        XCTAssertTrue(undo.isEnabled)
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(redo.waitForExistence(timeout: 2) && redo.isEnabled)
        shot("undone by key")
    }

    /// The date tool's date, put on every page from what acts on the selected mark, the Tools menu's stamp pad, which takes a
    /// picture of the company's stamp, and its Properties… and Password… sheets, the latter restricting printing, copying and
    /// changes.
    func testDateOnEveryPageAndTheStampPad() {
        openSample()
        choose("Date")
        let line = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Section 1.'")).firstMatch.frame
        point(line.maxX - 80, line.minY - 30).tap()
        let every = app.buttons["Add to Every Page"].firstMatch
        XCTAssertTrue(every.waitForExistence(timeout: 5))
        XCTAssertTrue(every.isEnabled)
        every.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Added to'")).firstMatch.waitForExistence(timeout: 3))
        shot("date on every page")
        done()
        tools("Edit Stamp…")
        XCTAssertTrue(app.buttons["Photos…"].waitForExistence(timeout: 5))
        shot("stamp pad")
        app.buttons["Cancel"].tap()
        tools("Properties…")
        XCTAssertTrue(app.textFields["Title"].waitForExistence(timeout: 5))
        shot("properties")
        app.buttons["Cancel"].tap()
        tools("Password…")
        let restrict = app.switches["Restrict printing, copying and changes"]
        XCTAssertTrue(restrict.waitForExistence(timeout: 5))
        // A switch turns where its knob is, not where its words are.
        restrict.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        shot("password and restrictions")
        app.buttons["Cancel"].tap()
    }

    /// Organizing the pages: a tap selects one, the bar deletes it, Undo puts it back, and Split… asks how to split them.
    /// Pages are named by their place, so with one of the sample's three gone, the last name goes.
    func testOrganizePages() {
        openSample()
        tools("Organize Pages")
        let second = app.buttons["Page 2"], third = app.buttons["Page 3"]
        XCTAssertTrue(third.waitForExistence(timeout: 5))
        second.tap()
        XCTAssertTrue(second.isSelected)
        shot("organize")
        app.buttons["Delete Pages"].tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: third)
        waitForExpectations(timeout: 5)
        XCTAssertFalse(second.isSelected)
        undo.tap()
        XCTAssertTrue(third.waitForExistence(timeout: 5))
        app.buttons["Split…"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Makes 3 files'")).firstMatch.waitForExistence(timeout: 5))
        shot("split")
        app.buttons["Cancel"].tap()
    }

    /// Undo while typing takes back the typing, not the change before it.
    func testUndoWhileTyping() {
        openSample()
        choose("Rectangle")
        let line = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Section 1.'")).firstMatch.frame
        drag(point(line.minX + 20, line.maxY + 200), point(line.minX + 120, line.maxY + 240))
        choose("Text Box")
        point(line.minX + 10, line.maxY + 100).tap()
        app.typeText("Never mind")
        undo.tap()   // the navigation bar's, not the keyboard's
        XCTAssertTrue(redo.isEnabled)
        XCTAssertTrue(undo.isEnabled)   // the rectangle's still there to undo
        XCTAssertFalse(app.textFields.matching(NSPredicate(format: "value == 'Never mind'")).firstMatch.exists)
    }

    /// Words being typed are kept when the document closes, and the field stays in sight above the keyboard.
    func testTypingKeptWhenTheDocumentCloses() {
        openSample()
        choose("Text Box")
        point(app.frame.midX, app.frame.maxY * 0.72).tap()
        app.typeText("Kept after closing")
        let field = app.textFields.matching(NSPredicate(format: "value == 'Kept after closing'")).firstMatch, back = app.navigationBars.buttons["BackButton"]
        // In sight: under the navigation bar, and over Markup's tools, which ride on the keyboard. Told by its frame:
        // isHittable has said no while the field showed whole, just over the bar.
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(field.frame.minY, back.frame.maxY)
        XCTAssertLessThanOrEqual(field.frame.maxY, app.buttons["Select"].frame.minY)
        back.tap()
        let sample = app.cells["Quarterly Brief, pdf"]
        XCTAssert(sample.waitForExistence(timeout: 10))
        sample.tap()
        XCTAssert(app.buttons["Markup"].waitForExistence(timeout: 10))
        showPanes()
        app.buttons["Comments"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "value == 'Kept after closing'")).firstMatch.waitForExistence(timeout: 5))
    }

    /// A note's comment being typed is kept when the document closes. On iPad the panes leave Back in reach.
    func testCommentKeptWhenTheDocumentCloses() throws {
        try XCTSkipUnless(pad, "On iPhone the comments cover Back.")
        openSample()
        choose("Note")
        let line = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Section 1.'")).firstMatch.frame
        point(line.minX + 40, line.maxY + 250).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        app.typeText("Noted before closing")
        app.navigationBars.buttons["BackButton"].tap()
        let sample = app.cells["Quarterly Brief, pdf"]
        XCTAssert(sample.waitForExistence(timeout: 10))
        sample.tap()
        XCTAssert(app.buttons["Markup"].waitForExistence(timeout: 10))
        showPanes()
        app.buttons["Comments"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "value == 'Noted before closing'")).firstMatch.waitForExistence(timeout: 5))
    }

    /// A note's comment being typed is kept when the app goes, as if the field had been left.
    func testCommentKeptWhenTheAppGoes() throws {
        try XCTSkipUnless(pad, "On iPhone the comments cover the tools.")
        openSample()
        choose("Note")
        let line = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Section 1.'")).firstMatch.frame
        point(line.minX + 10, line.maxY + 250).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        app.typeText("Noted")
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10))
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        undo.tap()
        XCTAssertTrue(redo.isEnabled)
        XCTAssertTrue(undo.isEnabled)   // the comment was taken back, and the note's still there
    }

    private var pad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    /// The navigation bar's Undo and Redo, in Markup and while organizing: the keyboard has its own.
    private var undo: XCUIElement { app.navigationBars.buttons["Undo"] }
    private var redo: XCUIElement { app.navigationBars.buttons["Redo"] }

    /// Shows the panes, unless they show already. A tap as the app comes back on screen can be lost, so where they don't
    /// show, it's made again.
    private func showPanes() {
        let shown = app.buttons["Thumbnails"]
        if !shown.exists { app.buttons["Pages"].tap() }
        if !shown.waitForExistence(timeout: 3) { app.buttons["Pages"].tap() }
    }

    /// Closes the panes: a column on iPad, a sheet on iPhone, put away by a tap above it.
    private func closePanes() {
        guard app.buttons["Thumbnails"].exists else { return }
        if pad { app.buttons["Pages"].tap() } else { point(200, 140).tap() }
    }

    /// Picks a Markup tool, starting Markup first, from the More Tools menu when it isn't in reach.
    private func choose(_ tool: String) {
        let markup = app.buttons["Markup"], button = app.buttons[tool].firstMatch   // the reading bar's Sign does as Markup's
        if markup.exists { markup.tap() }
        if !button.waitForExistence(timeout: 2) { app.buttons["More Tools"].tap() }
        XCTAssertTrue(button.waitForExistence(timeout: 5), app.debugDescription)
        button.tap()
    }

    /// Ends Markup or organizing.
    private func done() {
        app.navigationBars.buttons["Done"].tap()
    }

    /// Picks an item of the navigation bar's Tools menu.
    private func tools(_ item: String) {
        barButton("Tools")
        let button = app.buttons[item]
        XCTAssertTrue(button.waitForExistence(timeout: 5), app.debugDescription)
        button.tap()
    }

    /// Opens Find and types `text` in it.
    private func find(_ text: String) {
        app.buttons["Find"].tap()
        let field = app.textFields["Find"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), app.debugDescription)
        if field.value(forKey: "hasKeyboardFocus") as? Bool != true { field.tap() }
        app.typeText(text)
    }

    /// Waits for the line over the pages that starts with `text` to go, for a screenshot without it.
    private func waitUntilGone(_ text: String) {
        let line = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", text)).firstMatch
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: line)
        waitForExpectations(timeout: 10)
    }

    /// Launches Folio and opens a sample from its folder in the document browser.
    /// Opens a sample from Folio's folder. Browse opens where it was left: at its locations, in On My iPhone or iPad, or in
    /// Folio's folder. A slow Mac, such as GitHub's, can take a while to show a folder, and let a tap go while the folder
    /// slides in, so it takes whichever step shows until the document opens. A simulator just started there also leaves a
    /// tapped document unopened for the first ten minutes or so, so Folio launches again each minute until it opens.
    private func openSample(_ name: String = "Quarterly Brief") {
        let sample = app.cells["\(name), pdf"], opened = app.buttons["Markup"]
        let steps = [sample, app.cells["Folio, Container"], app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'On My i'")).firstMatch]
        let deadline = Date.now + 900
        repeat {
            app.launch()
            let browse = app.buttons["Browse"].firstMatch   // the tab, or the back button to it
            if browse.waitForExistence(timeout: 30) { browse.tap() }
            let launch = Date.now + 60
            while !opened.waitForExistence(timeout: 1), Date.now < launch {
                guard let step = steps.first(where: \.exists) else { continue }
                // On a fresh iPad the locations are a sidebar over the folder, put away by a tap beside it.
                if !step.isHittable { point(app.frame.maxX - 40, app.frame.midY).tap() }
                step.tap()
                // A document takes a while to open, and a second tap on the way could open it twice.
                if step === sample { _ = opened.waitForExistence(timeout: 20) }
            }
        } while !opened.exists && Date.now < deadline
        XCTAssert(opened.exists)
    }

    private func point(_ x: CGFloat, _ y: CGFloat) -> XCUICoordinate {
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: y))
    }

    private func drag(_ from: XCUICoordinate, _ to: XCUICoordinate) {
        from.press(forDuration: 0.1, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.1)
    }

    /// Taps a button of the navigation bar, from its More menu where it doesn't fit.
    private func barButton(_ name: String) {
        let named = NSPredicate(format: "label BEGINSWITH %@", name)   // Share is "Share…"
        let button = app.navigationBars.buttons.matching(named).firstMatch
        if button.exists, button.isHittable { return button.tap() }
        app.navigationBars.buttons["More"].tap()
        let item = app.buttons.matching(named).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        item.tap()
    }

    /// The share of the screen's pixels in `rect` that are a highlighter's yellow.
    private func yellow(in rect: CGRect) -> Double {
        let image = XCUIScreen.main.screenshot().image, scale = image.scale
        let crop = image.cgImage!.cropping(to: CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale))!
        var pixels = [UInt8](repeating: 0, count: crop.width * crop.height * 4)
        let context = CGContext(data: &pixels, width: crop.width, height: crop.height, bitsPerComponent: 8, bytesPerRow: crop.width * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        let yellows = stride(from: 0, to: pixels.count, by: 4).filter { pixels[$0] > 200 && pixels[$0 + 1] > 150 && pixels[$0 + 2] < 120 }
        return Double(yellows.count) / Double(crop.width * crop.height)
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
