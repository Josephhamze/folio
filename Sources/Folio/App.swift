import PDFKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

@main
struct FolioApp: App {
    #if os(iOS)
    @UIApplicationDelegateAdaptor private var delegate: AppDelegate
    /// Create from Photos, waiting for its PDF while Photos chooses the photos for it.
    @State private var making: CheckedContinuation<URL?, any Error>?
    @State private var choosingPhotos = false
    @State private var photos: [PhotosPickerItem] = []
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
                                                                           startPoint: .top, endPoint: .bottom)) {
            NewDocumentButton()
            // A page for each photo, in the order chosen; Cancel makes no document.
            NewDocumentButton("Create from Photos", contentType: .pdf) { @MainActor in
                try await withCheckedThrowingContinuation { making = $0; choosingPhotos = true }
            }
            .photosPicker(isPresented: $choosingPhotos, selection: $photos, selectionBehavior: .ordered, matching: .images)
            // Add sets the photos as Photos goes, and Cancel sets none, in an order that isn't said: so this waits a turn.
            .onChange(of: choosingPhotos) { if !choosingPhotos { DispatchQueue.main.async(execute: chosePhotos) } }
        }
        #endif
    }
}

#if os(iOS)
extension FolioApp {
    /// Hands Create from Photos the PDF of the photos chosen, or calls it off when there are none.
    private func chosePhotos() {
        guard let request = making else { return }
        let chosen = photos
        (making, photos) = (nil, [])
        guard !chosen.isEmpty else { return request.resume(throwing: CancellationError()) }
        Task {
            do { request.resume(returning: try await Self.pdf(of: chosen)) } catch { request.resume(throwing: error) }
        }
    }

    /// A PDF of the photos, a page each, named for the day, in a folder of its own for the new document to be made from.
    private static func pdf(of photos: [PhotosPickerItem]) async throws -> URL {
        let pdf = PDFDocument()
        for page in await FolioDocument.pages(from: photos) { pdf.insert(page, at: pdf.pageCount) }
        guard pdf.pageCount > 0 else { throw CocoaError(.fileReadCorruptFile) }
        let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let day = Date.now.formatted(.iso8601.year().month().day())
        let file = folder.appending(path: String(localized: "Photos \(day)") + ".pdf")
        guard pdf.write(to: file) else { throw CocoaError(.fileWriteUnknown) }
        return file
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
