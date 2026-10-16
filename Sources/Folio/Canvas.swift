import PDFKit

/// The page view, where the tools draw.
final class Canvas: PDFView {
    unowned let viewer: Viewer

    init(viewer: Viewer) {
        self.viewer = viewer
        super.init(frame: .zero)
        autoScales = true
        displayMode = .singlePageContinuous
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.tabbingMode = .preferred
    }
}
