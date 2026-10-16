import SwiftUI

@main
struct FolioApp: App {
    var body: some Scene {
        DocumentGroup(newDocument: { FolioDocument() }) { DocumentView(doc: $0.document) }
    }
}
