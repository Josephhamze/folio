import XCTest

/// Needs the PDFs from this folder in Folio's Documents folder on the simulator, which `./build.sh ios-test` puts there.
final class ScreenshotTests: XCTestCase {
    private let app = XCUIApplication()

    /// The App Store's screenshots, which `./build.sh screenshots` takes: a sample highlighted, noted and signed, the
    /// signature pad, and the panes.
    func testScreenshots() {
        openSample("Garden Brief")
        // A point on the first page, in its 612 by 792 points from the top left.
        let page = app.textViews.firstMatch.children(matching: .other).firstMatch
        let at = { (x: CGFloat, y: CGFloat) in page.coordinate(withNormalizedOffset: CGVector(dx: x / 612, dy: y / 792)) }

        choose("highlighter")
        drag(at(76, 357), at(404, 357))   // the first goal
        choose("textformat")
        at(360, 379).tap()   // beside the second
        app.typeText("Love this!")
        at(580, 300).tap()   // in the margin
        choose("signature")
        at(450, 675).tap()   // under the budget
        if app.buttons["Type"].waitForExistence(timeout: 2) {
            app.buttons["Type"].tap()
            app.textFields["Your name"].tap()
            app.typeText("Maria Santos")
            shot("2 Sign")
            app.buttons["Save"].tap()
            at(450, 675).tap()
        }
        shot("1 Mark up")

        showPanes()
        shot("3 Pages")
    }

    /// Marks up the sample by touch, as a person would, with a screenshot after each step.
    func testMarkUpByTouch() {
        openSample()
        let undo = app.buttons["Undo"], line = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Section 1.'")).firstMatch.frame
        let blank = point(line.maxX - 60, line.minY - 30)

        choose("highlighter")
        drag(point(line.minX + 2, line.minY + 5), point(line.maxX - 2, line.minY + 5))
        XCTAssertTrue(undo.isEnabled)
        // From where the finger went down: the line's first letters are marked.
        XCTAssertGreaterThan(yellow(in: CGRect(x: line.minX, y: line.minY + 1, width: 8, height: 7)), 0.3)
        shot("highlight")

        choose("rectangle")
        drag(point(line.maxX - 120, line.minY - 45), point(line.maxX - 10, line.minY - 15))
        shot("rectangle")

        choose("textformat")
        point(line.minX + 10, line.maxY + 140).tap()
        app.typeText("Typed on a phone")
        shot("typing")
        blank.tap()
        shot("text box")

        choose("signature")
        point(line.midX, line.maxY + 60).tap()
        if app.buttons["Type"].waitForExistence(timeout: 2) {
            app.buttons["Type"].tap()
            app.textFields["Your name"].tap()
            app.typeText("Joseph Hamze")
            shot("signature pad")
            app.buttons["Save"].tap()
            point(line.midX, line.maxY + 60).tap()
        }
        shot("signature")

        undo.tap()
        shot("undone")
        choose("cursorarrow")
        point(line.maxX - 65, line.minY - 30).tap()
        XCTAssertTrue(app.buttons["Delete"].waitForExistence(timeout: 5))
        shot("selected")
        app.buttons["Delete"].tap()
        shot("deleted")

        showPanes()
        for pane in ["Thumbnails", "Bookmarks", "Comments"] {
            app.buttons[pane].firstMatch.tap()
            shot(pane)
        }
        closePanes()

        app.searchFields["Find"].tap()
        app.typeText("Folio")
        XCTAssertTrue(app.staticTexts["1 of 42"].waitForExistence(timeout: 5))
        shot("find")
        app.buttons["Next"].tap()
        XCTAssertTrue(app.staticTexts["2 of 42"].exists)
        shot("find next")
        app.buttons[pad ? "Clear text" : "close"].tap()

        barButton("Share")
        XCTAssertTrue(app.descendants(matching: .any)["Copy"].waitForExistence(timeout: 10))
        shot("share")
        point(200, 700).tap()   // below the sheet

        // Words being typed are kept when the app goes to the background.
        choose("textformat")
        point(line.minX + 10, line.maxY + 330).tap()
        app.typeText("Kept after Home")
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10))
        app.activate()
        showPanes()
        app.buttons["Comments"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "value == 'Kept after Home'")).firstMatch.waitForExistence(timeout: 5))
        shot("kept")
        closePanes()

        // Two fingers zoom, and draw nothing, with the pen.
        choose("pencil.tip")
        app.textViews.firstMatch.pinch(withScale: 2, velocity: 1)
        shot("pen pinch")
    }

    /// iPad's menu bar and its keys act on the document in front, ⌘Z included.
    func testMenuBarActsOnTheDocument() throws {
        try XCTSkipUnless(pad, "The menu bar is iPad's.")
        openSample()
        XCTAssertTrue(app.buttons["rectangle.fill"].isHittable)   // the last tool: the bar fits
        let line = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Section 1.'")).firstMatch.frame
        app.typeKey("f", modifierFlags: .command)
        XCTAssertEqual(app.searchFields["Find"].value(forKey: "hasKeyboardFocus") as? Bool, true)
        app.typeText("Folio")
        app.typeKey("g", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["2 of 42"].waitForExistence(timeout: 5))
        // Off the search field nothing is first responder, and the keys still find.
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
        choose("rectangle")
        drag(point(line.minX + 20, line.minY - 40), point(line.minX + 120, line.minY - 10))
        XCTAssertTrue(app.buttons["Undo"].isEnabled)
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(app.buttons["Redo"].waitForExistence(timeout: 2) && app.buttons["Redo"].isEnabled)
        shot("undone by key")
    }

    private var pad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    /// Shows the panes, unless they show already. A tap as the app comes back on screen can be lost, so where they don't
    /// show, it's made again.
    private func showPanes() {
        let shown = app.buttons["Thumbnails"]
        if !shown.exists { barButton("Panes") }
        if !shown.waitForExistence(timeout: 3) { barButton("Panes") }
    }

    /// Closes the panes: a column on iPad, a sheet on iPhone, put away by a tap above it.
    private func closePanes() {
        guard app.buttons["Thumbnails"].exists else { return }
        if pad { barButton("Panes") } else { point(200, 140).tap() }
    }

    /// Launches Folio and opens a sample from its folder in the document browser.
    private func openSample(_ name: String = "Quarterly Brief") {
        app.launch()
        app.buttons["Browse"].firstMatch.tap()   // the tab, or the back button to it
        // Browse opens where it was left: at its locations, in On My iPhone or iPad, or in Folio's folder.
        for place in [app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'On My i'")).firstMatch, app.cells["Folio, Container"]]
        where place.waitForExistence(timeout: 2) {
            // On a fresh iPad the locations are a sidebar over the folder, put away by a tap beside it.
            if !place.isHittable { point(app.frame.maxX - 40, app.frame.midY).tap() }
            place.tap()
        }
        let sample = app.cells["\(name), pdf"]
        XCTAssert(sample.waitForExistence(timeout: 10))
        sample.tap()
        XCTAssert(app.buttons["highlighter"].waitForExistence(timeout: 10))
    }

    private func point(_ x: CGFloat, _ y: CGFloat) -> XCUICoordinate {
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: y))
    }

    private func drag(_ from: XCUICoordinate, _ to: XCUICoordinate) {
        from.press(forDuration: 0.1, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.1)
    }

    /// Picks a tool, first scrolling the bar to it where it's out of sight.
    private func choose(_ tool: String) {
        let button = app.buttons[tool], bar = app.scrollViews.containing(.button, identifier: "cursorarrow").firstMatch
        if !button.isHittable {
            let middle = bar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            drag(middle, middle.withOffset(CGVector(dx: bar.frame.midX - button.frame.midX, dy: 0)))
        }
        button.tap()
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
