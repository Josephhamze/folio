import PDFKit
import SwiftUI
import UniformTypeIdentifiers

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
        DocumentGroup(newDocument: {
            #if os(iOS)
            if #available(iOS 27, *) { Self.noteWhichButton() }
            #endif
            return FolioDocument()
        }) { DocumentView(doc: $0.document, url: $0.fileURL) }
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
                                                                           startPoint: .top, endPoint: .bottom)) {
            // Two buttons show, and any more fold into More…, so where there's a camera, Scan Document takes the place of
            // Create Document, which the Create Document tile among the files still does. The simulator has no camera.
            if Scanner.isAvailable {
                if #available(iOS 27, *) {
                    // iOS 27 runs no button's closure, and tells this button from Create from Photos by its content type: see
                    // noteWhichButton.
                    NewDocumentButton("Scan Document", contentType: .pdf)
                } else {
                    // The pages scanned, their words read; Cancel makes no document.
                    NewDocumentButton("Scan Document", for: FolioDocument.self) { try Self.document(of: await Scanner.scan()) }
                }
            } else {
                NewDocumentButton()
            }
            // A page for each photo, in the order chosen; Cancel makes no document. iOS 27 never runs this, making a blank
            // document instead: see noteWhichButton.
            NewDocumentButton("Create from Photos", for: FolioDocument.self) { try Self.document(of: await FolioDocument.pagesOfChosenPhotos()) }
        }
        #endif
    }
}

#if os(iOS)
extension FolioApp {
    /// A new document of these pages, or none for Cancel, which gave none.
    private static func document(of pages: [PDFPage]) throws -> FolioDocument {
        guard !pages.isEmpty else { throw CancellationError() }
        let pdf = PDFDocument()
        for page in pages { pdf.insert(page, at: pdf.pageCount) }
        return FolioDocument(pdf: pdf)
    }

    /// Notes whether the document being made is for Create from Photos or Scan Document, for its view to show Photos' picker
    /// or the scanner. iOS 27 makes it as for Create Document, never running the closure given to either button, but the
    /// document browser knows which button it was. SwiftUI makes it off the main thread, where UIKit can't be asked, and
    /// makes another as it opens the file, with no button being made then. iOS 26 runs the closures instead, and gives every
    /// button a name made up as it launches.
    private static func noteWhichButton() {
        let note = {
            MainActor.assumeIsolated {
                for scene in UIApplication.shared.connectedScenes {
                    var controllers = (scene as? UIWindowScene)?.windows.compactMap(\.rootViewController) ?? []
                    while let controller = controllers.popLast() {
                        if let intent = (controller as? UIDocumentBrowserViewController)?.activeDocumentCreationIntent {
                            // Such as "SwiftUIcom.adobe.pdf-0" for Scan Document and "SwiftUIFolio.FolioDocument-1" for Create from
                            // Photos, numbered by their place.
                            return DocumentView.making = intent == .default ? nil : intent.rawValue.contains(UTType.pdf.identifier) ? .scan : .photos
                        }
                        controllers += controller.children + [controller.presentedViewController].compactMap { $0 }
                    }
                }
            }
        }
        Thread.isMainThread ? note() : DispatchQueue.main.sync(execute: note)
    }
}
#endif

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

/// The end of the responder chain, where iPad's own Edit › Find lands, from the menu or its keys, with or without a first
/// responder. It takes Find, Find Next and Find Previous before Folio's commands can. Find ends Markup and Organize Pages, whose
/// tools take the find field's place, and shows the field, which takes the keys as it shows, or at once if it shows already.
final class AppDelegate: UIResponder, UIApplicationDelegate {
    override func find(_ sender: Any?) {
        Front.shared.document?.viewer.backToReading()
        Front.shared.document?.viewer.finding = true
        Front.shared.document?.searchFocus.wrappedValue = true
    }
    override func findNext(_ sender: Any?) { Front.shared.document?.viewer.step(1) }
    override func findPrevious(_ sender: Any?) { Front.shared.document?.viewer.step(-1) }
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
        Button("Properties…") { viewer?.sheet = .properties }.disabled(!idle)
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
