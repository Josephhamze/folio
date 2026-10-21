import XCTest

/// Needs Quarterly Brief.pdf, from this folder, in Folio's Documents folder on the simulator.
final class ScreenshotTests: XCTestCase {
    func testScreenshots() {
        let app = XCUIApplication()
        app.launch()
        app.buttons["Browse"].firstMatch.tap()   // the tab, or the back button to it
        // Browse opens where it was left: at its locations, in On My iPhone, or in Folio's folder.
        for place in [app.staticTexts["On My iPhone"], app.cells["Folio, Container"]] where place.waitForExistence(timeout: 2) {
            place.tap()
        }
        let sample = app.cells["Quarterly Brief, pdf"]
        XCTAssert(sample.waitForExistence(timeout: 10))
        sample.tap()
        XCTAssert(app.buttons["Select"].waitForExistence(timeout: 10))
        shot("open")
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
