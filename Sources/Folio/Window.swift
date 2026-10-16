import PDFKit
import SwiftUI

/// A window's state: its document, its page view and what the window shows.
@Observable
final class Viewer {
    let doc: FolioDocument
    @ObservationIgnored lazy var canvas = Canvas(viewer: self)

    init(doc: FolioDocument) {
        self.doc = doc
    }
}

struct DocumentView: View {
    @State var viewer: Viewer
    @Environment(\.undoManager) private var undoManager

    init(doc: FolioDocument) {
        _viewer = State(initialValue: Viewer(doc: doc))
    }

    var body: some View {
        PageView(viewer: viewer)
            .frame(minWidth: 600, minHeight: 500)
            .onAppear { viewer.doc.undo = undoManager }
            .onChange(of: undoManager) { viewer.doc.undo = undoManager }
    }
}

struct PageView: NSViewRepresentable {
    let viewer: Viewer

    func makeNSView(context: Context) -> Canvas { viewer.canvas }

    func updateNSView(_ canvas: Canvas, context: Context) {
        if canvas.document !== viewer.doc.pdf { canvas.document = viewer.doc.pdf }
    }
}
