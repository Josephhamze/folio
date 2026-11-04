import PDFKit
import SwiftUI

@main
struct FolioApp: App {
    #if os(iOS)
    @UIApplicationDelegateAdaptor private var delegate: AppDelegate
    #else
    /// SwiftUI's documents save themselves as they change, with no switch to stop it. Folio's wait for ⌘S, so closing or
    /// quitting with changes asks whether to save them.
    /// shortcut: this replaces the answer of SwiftUI's document class, found by its name; were it renamed, Folio would save as
    /// it goes again. Give Folio an NSDocument of its own if that happens.
    init() {
        guard let documents = NSClassFromString("SwiftUI.PlatformDocument") else { return }
        let never: @convention(block) (AnyClass) -> Bool = { _ in false }
        class_replaceMethod(object_getClass(documents), #selector(getter: NSDocument.autosavesInPlace), imp_implementationWithBlock(never), "B@:")
    }
    #endif

    var body: some Scene {
        DocumentGroup(newDocument: { FolioDocument() }) { DocumentView(doc: $0.document, url: $0.fileURL) }
            .commands { FolioCommands() }
            #if os(macOS)
            // The home window opens at launch, not the Open panel.
            .defaultLaunchBehavior(.suppressed)
            #endif
        #if os(macOS)
        Window("Home", id: "home") { Home() }
            .defaultLaunchBehavior(.presented)
            .restorationBehavior(.disabled)
            .windowStyle(.hiddenTitleBar)
            .defaultSize(width: 760, height: 520)
        #else
        DocumentGroupLaunchScene("Folio", backgroundStyle: LinearGradient(colors: [Color(red: 0xE5 / 255, green: 0x48 / 255, blue: 0x4D / 255),
                                                                                    Color(red: 0x9E / 255, green: 0x1B / 255, blue: 0x25 / 255)],
                                                                           startPoint: .top, endPoint: .bottom))
        #endif
    }
}

#if os(macOS)
extension FocusedValues {
    @Entry var viewer: Viewer?
    @Entry var searchFocus: FocusState<Bool>.Binding?
}
#else
/// The document in the key window, for the menu bar: iPad's commands don't see a document's focused values.
@Observable final class Front {
    static let shared = Front()
    var document: (viewer: Viewer, searchFocus: FocusState<Bool>.Binding)?
}

/// The end of the responder chain, where iPad's own Edit › Find lands with or without a first responder. It takes Find, Find
/// Next and Find Previous before Folio's commands can.
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let app: AnyClass = type(of: application)
        if let theirs = class_getInstanceMethod(app, #selector(UIApplication.sendEvent(_:))),
           let mine = class_getInstanceMethod(app, #selector(UIApplication.findKeysFirst(_:))) {
            method_exchangeImplementations(theirs, mine)
        }
        return true
    }

    override func find(_ sender: Any?) { Front.shared.document?.searchFocus.wrappedValue = true }
    override func findNext(_ sender: Any?) { Front.shared.document?.viewer.step(1) }
    override func findPrevious(_ sender: Any?) { Front.shared.document?.viewer.step(-1) }
}

extension UIApplication {
    /// Edit › Find's keys, ⌘F, ⌘G and ⇧⌘G, as they arrive: on iPadOS 26 the page and the search field, whichever has the
    /// keys, keep those three to themselves, so the menu never hears them.
    /// shortcut: this stands in for sendEvent(_:), swapped in at launch, as nothing in UIKit or SwiftUI sees a key before what
    /// has the keys does. Drop it once Folio needs an iPadOS whose page and search field let those keys by.
    @objc fileprivate func findKeysFirst(_ event: UIEvent) {
        guard let presses = event as? UIPressesEvent, let document = Front.shared.document,
              let press = presses.allPresses.first(where: { $0.key.map(Self.findsWith) ?? false }), let key = press.key else {
            return findKeysFirst(event)   // swapped: UIKit's own sendEvent(_:)
        }
        guard press.phase == .began else { return }
        if key.charactersIgnoringModifiers.lowercased() == "f" {
            document.searchFocus.wrappedValue = true
        } else {
            document.viewer.step(key.modifierFlags.contains(.shift) ? -1 : 1)
        }
    }

    private static func findsWith(_ key: UIKey) -> Bool {
        let modifiers = key.modifierFlags.intersection([.command, .shift, .alternate, .control])
        switch key.charactersIgnoringModifiers.lowercased() {
        case "f": return modifiers == .command
        case "g": return modifiers == .command || modifiers == [.command, .shift]
        default: return false
        }
    }
}
#endif

struct FolioCommands: Commands {
    #if os(macOS)
    @FocusedValue(\.viewer) private var viewer
    @FocusedValue(\.searchFocus) private var searchFocus
    #else
    private var viewer: Viewer? { Front.shared.document?.viewer }
    #endif

    var body: some Commands {
        #if os(macOS)
        // SwiftUI shows Save As only while Option is held, in Duplicate's place.
        CommandGroup(after: .saveItem) {
            Button("Save As…") { NSApp.sendAction(#selector(NSDocument.saveAs(_:)), to: nil, from: nil) }
                .keyboardShortcut("s", modifiers: [.command, .shift, .option])
                .disabled(viewer == nil)
        }
        // iPad's Edit menu has these: see AppDelegate.
        CommandGroup(after: .textEditing) {
            Button("Find…") { searchFocus?.wrappedValue = true }.keyboardShortcut("f")
            Button("Find Next") { viewer?.step(1) }.keyboardShortcut("g")
            Button("Find Previous") { viewer?.step(-1) }.keyboardShortcut("g", modifiers: [.command, .shift])
        }
        #endif
        CommandGroup(replacing: .printItem) {
            Button("Print…") {
                #if os(macOS)
                viewer?.canvas.print(with: .shared, autoRotate: true, pageScaling: .pageScaleToFit)
                #else
                guard let viewer else { return }
                viewer.settle()
                UIPrintInteractionController.shared.printingItem = try? viewer.doc.snapshot(contentType: .pdf)
                UIPrintInteractionController.shared.present(animated: true)
                #endif
            }
            .keyboardShortcut("p")
            .disabled(viewer?.doc.pdf.isLocked ?? true)
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
            Button("Thumbnails") { viewer?.show(.thumbnails) }.keyboardShortcut("1", modifiers: [.command, .option])
            Button("Bookmarks") { viewer?.show(.bookmarks) }.keyboardShortcut("2", modifiers: [.command, .option])
            Button("Comments") { viewer?.show(.comments) }.keyboardShortcut("3", modifiers: [.command, .option])
            #if os(macOS)
            Button(viewer?.readMode == true ? "Leave Read Mode" : "Read Mode") { viewer?.readMode.toggle() }
                .keyboardShortcut("r", modifiers: [.command, .option])
            #endif
            Divider()
        }
        CommandMenu("Pages") {
            Button(viewer?.organizing == true ? "Stop Organizing" : "Organize Pages") { viewer?.organize() }
                .keyboardShortcut("o", modifiers: [.command, .option])
                .disabled(viewer?.doc.pdf.isLocked ?? true)
            Divider()
            PageActions(viewer: viewer)
        }
        CommandMenu("Tools") { ToolsMenu(viewer: viewer) }
        #if os(macOS)
        ImportFromDevicesCommands()
        #endif
    }
}

/// The page in view, the words being typed included, as a picture named after its number, for the share sheet.
struct PagePicture: Transferable {
    let viewer: Viewer

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .jpeg) { shared in
            try await MainActor.run {
                shared.viewer.settle()
                guard let page = shared.viewer.doc.pdf.page(at: shared.viewer.pageIndex), let data = picture(of: page) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                return data
            }
        }
        .suggestedFileName { String(localized: "Page \($0.viewer.pageIndex + 1)") }
    }
}

/// The Tools menu: the menu bar's, and on iOS the navigation bar's too, as iPhone has no menu bar.
struct ToolsMenu: View {
    let viewer: Viewer?

    var body: some View {
        let idle = viewer?.isIdle ?? false
        Button("Recognize Text") { viewer?.recognizeText() }.disabled(!idle)
        Button("Apply Redactions") { viewer?.applyRedactions() }.disabled(!idle || viewer?.doc.hasRedactions != true)
        #if os(macOS)
        Button("Reduce File Size") { viewer?.reduceFileSize() }.disabled(!idle)
        #endif
        Button("Password…") { viewer?.sheet = .protect }.disabled(!idle || viewer?.doc.pdf.hasFullRights != true)
        Button("Add to Every Page") { viewer?.addToEveryPage() }.disabled(viewer?.canAddToEveryPage != true)
        if let viewer, !viewer.doc.pdf.isLocked, viewer.doc.pdf.permissionsStatus == .owner || viewer.doc.pdf.allowsCopying {
            ShareLink("Send Page as Picture", item: PagePicture(viewer: viewer), preview: SharePreview("Page \(viewer.pageIndex + 1)"))
        } else {
            Button("Send Page as Picture") {}.disabled(true)
        }
        Divider()
        Button("Edit Signature…") { viewer?.sheet = .signature(.sign) }.disabled(viewer == nil)
        Button("Edit Initials…") { viewer?.sheet = .signature(.initial) }.disabled(viewer == nil)
        Button("Edit Stamp…") { viewer?.sheet = .signature(.stamp) }.disabled(viewer == nil)
        #if os(macOS)
        Divider()
        Button("Show Fonts") { NSFontManager.shared.orderFrontFontPanel(nil) }.keyboardShortcut("t").disabled(viewer == nil)
        #endif
    }
}
