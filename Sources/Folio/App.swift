import SwiftUI

@main
struct FolioApp: App {
    var body: some Scene {
        DocumentGroup(newDocument: { FolioDocument() }) { DocumentView(doc: $0.document, url: $0.fileURL) }
            .commands { FolioCommands() }
            // The home window opens at launch, not the Open panel.
            .defaultLaunchBehavior(.suppressed)
        Window("Home", id: "home") { Home() }
            .defaultLaunchBehavior(.presented)
            .restorationBehavior(.disabled)
            .windowStyle(.hiddenTitleBar)
            .defaultSize(width: 760, height: 520)
    }
}

extension FocusedValues {
    @Entry var viewer: Viewer?
    @Entry var searchFocus: FocusState<Bool>.Binding?
}

struct FolioCommands: Commands {
    @FocusedValue(\.viewer) private var viewer
    @FocusedValue(\.searchFocus) private var searchFocus

    var body: some Commands {
        // SwiftUI shows Save As only while Option is held, in Duplicate's place.
        CommandGroup(after: .saveItem) {
            Button("Save As…") { NSApp.sendAction(#selector(NSDocument.saveAs(_:)), to: nil, from: nil) }
                .keyboardShortcut("s", modifiers: [.command, .shift, .option])
                .disabled(viewer == nil)
        }
        CommandGroup(replacing: .printItem) {
            Button("Print…") { viewer?.canvas.print(with: .shared, autoRotate: true, pageScaling: .pageScaleToFit) }
                .keyboardShortcut("p")
                .disabled(viewer?.doc.pdf.isLocked ?? true)
        }
        CommandGroup(after: .textEditing) {
            Button("Find…") { searchFocus?.wrappedValue = true }.keyboardShortcut("f")
            Button("Find Next") { viewer?.step(1) }.keyboardShortcut("g")
            Button("Find Previous") { viewer?.step(-1) }.keyboardShortcut("g", modifiers: [.command, .shift])
        }
        CommandGroup(after: .toolbar) {
            Button("Single Page") { viewer?.canvas.displayMode = .singlePage }
            Button("Continuous") { viewer?.canvas.displayMode = .singlePageContinuous }
            Button("Two Pages") { viewer?.canvas.displayMode = .twoUpContinuous }
            Divider()
            Button("Zoom In") { viewer?.canvas.zoomIn(nil) }.keyboardShortcut("+")
            Button("Zoom Out") { viewer?.canvas.zoomOut(nil) }.keyboardShortcut("-")
            Button("Actual Size") { viewer?.canvas.scaleFactor = 1 }.keyboardShortcut("0")
            Button("Zoom to Fit") { viewer?.canvas.autoScales = true }.keyboardShortcut("9")
            Divider()
            Button("Thumbnails") { viewer?.pane = .thumbnails }.keyboardShortcut("1", modifiers: [.command, .option])
            Button("Bookmarks") { viewer?.pane = .bookmarks }.keyboardShortcut("2", modifiers: [.command, .option])
            Button("Comments") { viewer?.pane = .comments }.keyboardShortcut("3", modifiers: [.command, .option])
            Button(viewer?.readMode == true ? "Leave Read Mode" : "Read Mode") { viewer?.readMode.toggle() }
                .keyboardShortcut("r", modifiers: [.command, .option])
            Divider()
        }
        CommandMenu("Tools") {
            Button("Edit Signature…") { viewer?.sheet = .signature(.sign) }.disabled(viewer == nil)
            Button("Edit Initials…") { viewer?.sheet = .signature(.initial) }.disabled(viewer == nil)
            Divider()
            Button("Show Fonts") { NSFontManager.shared.orderFrontFontPanel(nil) }.keyboardShortcut("t").disabled(viewer == nil)
        }
    }
}
