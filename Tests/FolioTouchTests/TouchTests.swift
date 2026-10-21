import PDFKit
import UIKit
import XCTest
@testable import Folio

final class TouchTests: XCTestCase {
    func testAppLaunchesWithAPageView() {
        let viewer = Viewer(doc: FolioDocument())
        let window = UIWindow(windowScene: UIApplication.shared.connectedScenes.first as! UIWindowScene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        viewer.canvas.frame = window.bounds
        window.addSubview(viewer.canvas)
        window.isHidden = false
        viewer.showPages()
        XCTAssertNotNil(viewer.canvas.document)
    }
}
