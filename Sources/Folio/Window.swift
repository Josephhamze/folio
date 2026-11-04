import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// A window's state: its document, its page view and what the window shows.
@Observable
final class Viewer {
    enum Pane: String, CaseIterable, Identifiable {
        case thumbnails = "Thumbnails", bookmarks = "Bookmarks", comments = "Comments"

        var id: Self { self }
        var symbol: String { self == .thumbnails ? "rectangle.grid.1x2" : self == .bookmarks ? "bookmark" : "text.bubble" }
    }

    enum Sheet: Hashable, Identifiable {
        /// The pad for the sign tool's signature, the initial tool's initials, or the stamp tool's stamp.
        case signature(Tool)
        case protect, properties, split

        var id: Self { self }
    }

    let doc: FolioDocument
    @ObservationIgnored lazy var canvas = Canvas(viewer: self)
    var pane = Pane.thumbnails
    /// Whether the panes show, on iOS, where they're an inspector.
    var showsPanes = false
    var organizing = false
    var selection: Set<PDFPage> = []
    /// Whether Insert from File… is choosing its files.
    var choosingPages = false
    #if os(iOS)
    var scanning = false
    #endif
    /// The pages Extract Pages… copied out, while the window saves them.
    var extracted: FolioDocument?
    var readMode = false
    var sheet: Sheet?
    var busy: String?
    /// A line shown over the pages for four seconds.
    var message: String? {
        didSet {
            guard let message else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(4))
                if self.message == message { self.message = nil }
            }
        }
    }
    /// Picking a tool puts down the selected mark: at once, so a tool that places a mark can then select it.
    var tool = Tool.select { didSet { canvas.selected = nil } }
    /// The mark the select tool picked, for the views: the page view's `selected`.
    var mark: PDFAnnotation?
    var color = NSColor.systemYellow
    /// The index of the page in view.
    var pageIndex = 0
    /// A note just added, whose comment field takes the keys.
    var focusNote: PDFAnnotation?
    /// The note whose comment is being typed, and what commits the words.
    @ObservationIgnored var comment: (note: PDFAnnotation, commit: () -> Void)?
    var query = ""
    private(set) var matches: [PDFSelection] = []
    private(set) var match = 0

    init(doc: FolioDocument) {
        self.doc = doc
    }

    func find() {
        matches = query.isEmpty ? [] : doc.pdf.findString(query, withOptions: .caseInsensitive)
        #if os(macOS)
        matches.forEach { $0.color = .findHighlightColor }
        #else
        matches.forEach { $0.color = .systemYellow }
        #endif
        canvas.highlightedSelections = matches
        match = 0
        showMatch()
    }

    func step(_ by: Int) {
        guard !matches.isEmpty else { return }
        match = (match + by + matches.count) % matches.count
        showMatch()
    }

    private func showMatch() {
        guard matches.indices.contains(match) else { return canvas.clearSelection() }
        canvas.setCurrentSelection(matches[match], animate: true)
        canvas.go(to: matches[match])
    }

    /// Goes to the page with this number, counting from 1; past either end, to that end.
    func go(toPage number: Int) {
        let count = doc.pdf.pageCount
        guard count > 0, let page = doc.pdf.page(at: min(max(number, 1), count) - 1) else { return }
        canvas.go(to: page)
    }

    /// The page to open at when the pages first show: where the file was left last time.
    @ObservationIgnored var resume: Int?

    /// Puts the pages in the page view, unless the file is locked: PDFKit would ask for its password a second time.
    func showPages() {
        let pdf = doc.pdf.isLocked ? nil : doc.pdf
        guard canvas.document !== pdf else { return }
        canvas.document = pdf
        guard pdf != nil, let resume else { return }
        self.resume = nil
        // Once PDFKit has laid the pages out, which would put the first back in view.
        DispatchQueue.main.async { self.go(toPage: resume + 1) }
    }

    /// The page this file was left on.
    static func lastPage(of url: URL) -> Int? {
        (UserDefaults.standard.dictionary(forKey: "pages") as? [String: Int])?[url.path]
    }

    /// Remembers the page this file was left on, to reopen it there. On the Mac only recent files keep theirs, so the list
    /// never outgrows File › Open Recent.
    /// shortcut: iOS has no recent files, and its sandbox can't see a closed file in another app's storage to tell whether it's
    /// gone, so there every file keeps its page, a short line each. Prune by count if that ever matters.
    static func remember(page index: Int, of url: URL) {
        var pages = UserDefaults.standard.dictionary(forKey: "pages") as? [String: Int] ?? [:]
        #if os(macOS)
        let recent = Set(NSDocumentController.shared.recentDocumentURLs.map(\.path))
        pages = pages.filter { recent.contains($0.key) }
        #endif
        pages[url.path] = index
        UserDefaults.standard.set(pages, forKey: "pages")
    }

    /// Shows this pane, in the inspector on iOS.
    func show(_ pane: Pane) {
        self.pane = pane
        showsPanes = true
    }

    /// Ends the typing, commits the comment being typed and records the form fills, for when the document closes or the app
    /// leaves the screen.
    func settle() {
        canvas.finishEditing()
        canvas.commitFields()
        comment?.commit()
    }

    var matchLabel: String {
        query.isEmpty ? "" : matches.isEmpty ? String(localized: "No matches") : String(localized: "\(match + 1) of \(matches.count)")
    }

    /// The pages that page commands act on: the selected ones while organizing, otherwise the one in view.
    var targetPages: [PDFPage] {
        organizing ? doc.pages.filter(selection.contains) : [canvas.currentPage].compactMap { $0 }
    }

    #if os(macOS)
    /// Where a ⇧ click's range starts: the page of the last plain or ⌘ click.
    @ObservationIgnored private var anchor: PDFPage?

    func click(_ page: PDFPage, modifiers: NSEvent.ModifierFlags) {
        let pages = doc.pages
        if modifiers.contains(.shift), let anchor, let from = pages.firstIndex(of: anchor), let to = pages.firstIndex(of: page) {
            selection = Set(pages[min(from, to)...max(from, to)])
            return
        }
        if modifiers.contains(.command) { selection.formSymmetricDifference([page]) } else { selection = [page] }
        anchor = page
    }
    #endif

    /// Moves the selection, or only the dragged page when it isn't selected, in front of `target`, or to the end.
    func drop(_ dragged: PDFPage, before target: PDFPage?) {
        let moving = selection.contains(dragged) ? Array(selection) : [dragged]
        if let target, moving.contains(target) { return }
        doc.move(moving, to: target.flatMap { doc.pages.firstIndex(of: $0) } ?? doc.pdf.pageCount)
    }

    /// What a page carries when it's dragged in the organizer: the document it's in, and its place there.
    func dragged(_ page: PDFPage) -> String { "\(UInt(bitPattern: ObjectIdentifier(doc))) \(doc.pdf.index(for: page))" }

    /// Moves the page `item` names, dragged in this window's organizer, as a dragged page moves. Other text dropped there, or
    /// a page from another window, moves nothing.
    func drop(_ item: String, before target: PDFPage?) -> Bool {
        let parts = item.split(separator: " "), pages = doc.pages
        guard isIdle, parts.count == 2, parts[0] == "\(UInt(bitPattern: ObjectIdentifier(doc)))", let index = Int(parts[1]),
              pages.indices.contains(index) else { return false }
        drop(pages[index], before: target)
        return true
    }

    /// Starts organizing, with no page selected, or ends it showing the first selected page.
    func organize() {
        settle()
        canvas.selected = nil   // out of sight, it would still take the Delete key
        if organizing, let first = targetPages.first { canvas.go(to: first) }
        selection = []
        organizing.toggle()
    }

    /// Puts pages after the last target page, selected while organizing.
    func insert(_ pages: [PDFPage]) {
        guard !pages.isEmpty else { return }
        doc.insert(pages, at: (targetPages.last.flatMap { doc.pages.firstIndex(of: $0) } ?? doc.pdf.pageCount - 1) + 1)
        if organizing { selection = Set(pages) }
    }

    /// Puts the scanned pages, each a picture on a page of the system's paper size, after the target pages, and says how to
    /// make them searchable.
    func insertScanned(_ images: [NSImage]) {
        let pages = images.compactMap(FolioDocument.page(from:))
        guard !pages.isEmpty else { return }
        insert(pages)
        message = pages.count == 1 ? String(localized: "Scanned 1 page. Tools › Recognize Text makes it searchable")
            : String(localized: "Scanned \(pages.count) pages. Tools › Recognize Text makes them searchable")
    }

    /// Puts the pages of PDFs and pictures another device hands over, such as a scan from an iPhone by Continuity Camera,
    /// after the target pages, in their order. False when the document takes no changes now.
    func importItems(_ providers: [NSItemProvider]) -> Bool {
        guard isIdle else { return false }
        Task { @MainActor in
            var pages: [PDFPage] = []
            for provider in providers {
                guard let type = provider.registeredContentTypes.first(where: { $0.conforms(to: .pdf) || $0.conforms(to: .image) }) else { continue }
                let data = await withCheckedContinuation { (done: CheckedContinuation<Data?, Never>) in
                    _ = provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in done.resume(returning: data) }
                }
                pages += data.map { FolioDocument.pages(from: $0, isPDF: type.conforms(to: .pdf)) } ?? []
            }
            if pages.isEmpty { message = String(localized: "Found no pages to insert: a PDF with a password or restrictions gives none") } else { insert(pages) }
        }
        return true
    }

    /// Copies the target pages into a document of their own, for the window to save. Pages of a protected file stay
    /// protected: by its new password and restrictions, or the password that opened it.
    func extract() {
        settle()
        let pages = FolioDocument(pdf: doc.extract(targetPages))
        (pages.newPassword, pages.newRestrictions) = (doc.keptPassword, doc.newRestrictions)
        extracted = pages
    }

    /// A PDF can't be saved without a page, so the last ones stay.
    var canDelete: Bool { doc.canEdit && !targetPages.isEmpty && targetPages.count < doc.pdf.pageCount }

    func deletePages() {
        doc.delete(targetPages)
        selection = []
    }

    /// Whether the document takes changes now: it can be edited, and nothing is working on it.
    var isIdle: Bool { doc.canEdit && busy == nil }

    /// Whether Add to Every Page has a mark to copy, and pages to copy it to.
    var canAddToEveryPage: Bool {
        _ = doc.revision   // pages come and go without telling
        return isIdle && mark != nil && doc.pdf.pageCount > 1
    }

    /// Copies the selected mark onto every other page, once the words being typed are in, and says onto how many.
    func addToEveryPage() {
        settle()
        guard let mark = canvas.selected else { return }
        let count = doc.addToEveryPage(mark)
        message = count == 1 ? String(localized: "Added to 1 more page") : String(localized: "Added to \(count) more pages")
    }

    /// Reads the words on the pages that have no text, showing how far it's got, then says how it went. It stays on the page:
    /// the pages it puts back would show the first.
    func recognizeText() {
        settle()
        busy = String(localized: "Recognizing text…")
        let at = pageIndex
        Task { @MainActor in
            let (read, of) = await doc.recognizeText { done, count in self.busy = String(localized: "Recognizing text… \(done + 1) of \(count)") }
            busy = nil
            go(toPage: at + 1)
            message = of == 0 ? String(localized: "Every page has its text already") : read == 0 ? String(localized: "Found no text to recognize")
                : read == 1 ? String(localized: "Recognized the text on 1 page") : String(localized: "Recognized the text on \(read) pages")
        }
    }

    /// Burns in the redaction marks, showing it's at work, then says how it went, staying on the page.
    func applyRedactions() {
        settle()
        busy = String(localized: "Applying redactions…")
        let at = pageIndex
        Task { @MainActor in
            let count = await doc.applyRedactions()
            busy = nil
            go(toPage: at + 1)
            message = count.map { $0 == 1 ? String(localized: "Redacted 1 page") : String(localized: "Redacted \($0) pages") }
                ?? String(localized: "Couldn't apply the redactions")
        }
    }

    #if os(macOS)
    /// Rewrites the document smaller, staying on its page, and says by how much, or that it can't be.
    func reduceFileSize() {
        settle()
        busy = String(localized: "Reducing file size…")
        Task { @MainActor in
            resume = pageIndex
            let sizes = await doc.reduceFileSize()
            busy = nil
            guard let sizes else {
                resume = nil
                message = String(localized: "Already as small as it gets")
                return
            }
            let size = { (bytes: Int) in ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) }
            message = "\(size(sizes.before)) → \(size(sizes.after))"
        }
    }
    #endif
}

struct DocumentView: View {
    @State var viewer: Viewer
    /// Where the document is saved, if it is.
    let url: URL?
    /// What files made from the document are named after.
    private var name: String { url?.deletingPathExtension().lastPathComponent ?? String(localized: "Untitled") }
    @FocusState private var searching: Bool
    @Environment(\.undoManager) private var undoManager
    #if os(macOS)
    @State private var columns = NavigationSplitViewVisibility.all
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    #else
    @Environment(\.scenePhase) private var scenePhase
    #endif

    init(doc: FolioDocument, url: URL?) {
        let viewer = Viewer(doc: doc)
        viewer.resume = url.flatMap(Viewer.lastPage)
        _viewer = State(initialValue: viewer)
        self.url = url
    }

    var body: some View {
        layout
            .onChange(of: viewer.query) { viewer.find() }
            .onSubmit(of: .search) { viewer.step(1) }
            .onChange(of: viewer.pageIndex) { if let url { Viewer.remember(page: viewer.pageIndex, of: url) } }
            .onChange(of: viewer.doc.revision) {
                // An undo can take the selected mark off its page, and recognizing text or reducing the size puts in new
                // pages.
                if let mark = viewer.canvas.selected, mark.page?.document !== viewer.doc.pdf { viewer.canvas.selected = nil }
                viewer.canvas.outlineSelection()
                viewer.canvas.sharpenAnnotations()
            }
            .onChange(of: viewer.color) {
                guard let a = viewer.canvas.selected else { return }
                if a.type == "FreeText" {
                    viewer.doc.set(\.fontColor, of: a, to: viewer.color, name: "Change Colour")
                } else {
                    viewer.doc.set(\.color, of: a, to: viewer.color, name: "Change Colour")
                }
            }
            .sheet(item: $viewer.sheet) { sheet in
                if case .signature(let tool) = sheet { SignatureSheet(viewer: viewer, tool: tool) }
                if sheet == .protect { PasswordSheet(viewer: viewer) }
                if sheet == .properties { PropertiesSheet(viewer: viewer) }
                if sheet == .split { SplitSheet(viewer: viewer, name: name) }
            }
            .fileImporter(isPresented: $viewer.choosingPages, allowedContentTypes: [.pdf, .image], allowsMultipleSelection: true) { result in
                guard let urls = try? result.get().sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }),
                      !urls.isEmpty else { return }
                let opened = urls.map { $0.startAccessingSecurityScopedResource() }
                let pages = FolioDocument.pages(from: urls)
                for (url, isOpen) in zip(urls, opened) where isOpen { url.stopAccessingSecurityScopedResource() }
                if pages.isEmpty { viewer.message = String(localized: "Found no pages to insert: a PDF with a password or restrictions gives none") } else { viewer.insert(pages) }
            }
            // On a view of its own: a second file dialog on the same view never shows.
            .background {
                Color.clear.fileExporter(isPresented: Binding { viewer.extracted != nil } set: { if !$0 { viewer.extracted = nil } },
                                         document: viewer.extracted, contentType: .pdf,
                                         defaultFilename: String(localized: "\(name) pages")) { result in
                    if case .success(let saved) = result { viewer.message = String(localized: "Saved \(saved.lastPathComponent)") }
                }
            }
            #if os(macOS)
            .focusedSceneValue(\.viewer, viewer)
            .focusedSceneValue(\.searchFocus, $searching)
            // File › Import from iPhone or iPad.
            .importsItemProviders([.pdf, .image]) { viewer.importItems($0) }
            #else
            .fullScreenCover(isPresented: $viewer.scanning) {
                PageScanner { images in
                    viewer.scanning = false
                    viewer.insertScanned(images)
                }
                .ignoresSafeArea()
            }
            #endif
            .onAppear { viewer.doc.undo = undoManager }
            .onChange(of: undoManager) { viewer.doc.undo = undoManager }
    }

    /// Starts organizing the pages, and ends it.
    private var organizeButton: some View {
        Button("Organize Pages", systemImage: viewer.organizing ? "square.grid.2x2.fill" : "square.grid.2x2") { viewer.organize() }
            .help("Organize Pages")
            .disabled(viewer.doc.pdf.isLocked)
    }

    /// The page in view, as a number to type over, and the count.
    @ViewBuilder private var pageBox: some View {
        if !viewer.doc.pdf.isLocked {
            HStack(spacing: 4) {
                TextField("Page", value: Binding(get: { viewer.pageIndex + 1 }, set: { viewer.go(toPage: $0) }), format: .number)
                    .frame(width: 40)
                    .multilineTextAlignment(.trailing)
                    #if os(iOS)
                    .keyboardType(.numbersAndPunctuation)
                    #endif
                Text("of \(viewer.doc.pdf.pageCount)").foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }

    #if os(macOS)
    private var layout: some View {
        NavigationSplitView(columnVisibility: $columns) {
            Sidebar(viewer: viewer)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        } detail: {
            PageView(viewer: viewer)
                .overlay { if viewer.organizing { Organizer(viewer: viewer) } }
                .overlay(alignment: .top) { Bars(viewer: viewer) }
                .safeAreaInset(edge: .top, spacing: 0) { if !viewer.readMode { ToolBar(viewer: viewer) } }
        }
        .toolbar {
            ToolbarItem { organizeButton }
            ToolbarItem { pageBox }
            ToolbarItem { Text(viewer.matchLabel).foregroundStyle(.secondary).monospacedDigit() }
        }
        .toolbar(viewer.readMode ? .hidden : .visible, for: .windowToolbar)
        .searchable(text: $viewer.query, placement: .toolbar, prompt: "Find")
        .searchFocused($searching)
        .onChange(of: viewer.readMode) {
            columns = viewer.readMode ? .detailOnly : .all
            if let window = viewer.canvas.window, window.styleMask.contains(.fullScreen) != viewer.readMode {
                window.toggleFullScreen(nil)
            }
        }
        .onExitCommand { viewer.readMode = false }
        // Esc, the green button or ⌃⌘F can end full screen without SwiftUI seeing it.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) {
            if $0.object as? NSWindow === viewer.canvas.window { viewer.readMode = false }
        }
        .frame(minWidth: 700, minHeight: 500)
        .onAppear { dismissWindow(id: "home") }
        // With no document left, Folio goes back to its home window rather than sit with none, once this one is gone.
        .onDisappear { DispatchQueue.main.async { if NSDocumentController.shared.documents.isEmpty { openWindow(id: "home") } } }
    }
    #else
    private var layout: some View {
        PageView(viewer: viewer)
            .overlay { if viewer.organizing { Organizer(viewer: viewer) } }
            .overlay(alignment: .top) { Bars(viewer: viewer) }
            .safeAreaInset(edge: .bottom, spacing: 0) { ToolBar(viewer: viewer) }
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    pageBox
                    Button("Panes", systemImage: "sidebar.right") { viewer.showsPanes.toggle() }
                    organizeButton
                    // iPhone has no menu bar for the Tools menu.
                    Menu("Tools", systemImage: "ellipsis.circle") { ToolsMenu(viewer: viewer) }
                    ShareButton(viewer: viewer, name: name)
                }
            }
            .searchable(text: $viewer.query, prompt: "Find")
            .searchFocused($searching)
            // The inspector only ever closes the panes: once in a while, as a document opened, it set them shown without
            // showing them, and the next tap on Panes hid them.
            .inspector(isPresented: Binding { viewer.showsPanes } set: { if !$0 { viewer.showsPanes = false } }) {
                Sidebar(viewer: viewer).presentationDetents([.medium, .large])
            }
            // Words being typed, and form fills, are kept when the app or the document goes.
            .onChange(of: scenePhase) { if scenePhase != .active { viewer.settle() } }
            .onDisappear {
                viewer.settle()
                if Front.shared.document?.viewer === viewer { Front.shared.document = nil }
            }
            // The menu bar acts on the document in the key window, which the one it opens in is.
            .onAppear { Front.shared.document = (viewer, $searching) }
            .onReceive(NotificationCenter.default.publisher(for: UIWindow.didBecomeKeyNotification)) {
                if $0.object as? UIWindow === viewer.canvas.window { Front.shared.document = (viewer, $searching) }
            }
    }
    #endif
}

#if os(iOS)
/// Shares the document, with its first page for a preview. The preview is drawn again when the document changes, not each
/// time the window's bar is.
struct ShareButton: View {
    let viewer: Viewer
    let name: String

    var body: some View {
        let _ = viewer.doc.revision
        ShareLink(item: SharedPDF(viewer: viewer, name: name), preview: SharePreview(name, image: Image(uiImage:
            viewer.doc.pdf.page(at: 0)?.thumbnail(of: CGSize(width: 240, height: 240), for: .mediaBox) ?? UIImage())))
            .disabled(viewer.doc.pdf.isLocked)
    }
}

/// The document as it is now, the words being typed included, as a PDF file named after it, for the share sheet.
struct SharedPDF: Transferable {
    let viewer: Viewer
    let name: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .pdf) { shared in
            let data = try await MainActor.run {
                shared.viewer.settle()
                return try shared.viewer.doc.snapshot(contentType: .pdf)
            }
            let url = URL.temporaryDirectory.appending(path: shared.name + ".pdf")
            try data.write(to: url)
            return SentTransferredFile(url)
        }
    }
}
#endif

/// The tools, the colour, and Add to Every Page and Delete for the selected mark, in a bar across the top of the pages, or
/// what acts on pages while organizing. On iOS it's at the bottom, the tools scroll where they don't fit, and it has Undo
/// and Redo.
struct ToolBar: View {
    @Bindable var viewer: Viewer
    #if os(iOS)
    @Environment(\.undoManager) private var undoManager
    #endif

    var body: some View {
        HStack {
            if viewer.organizing {
                PageActions(viewer: viewer)
                Spacer()
            } else {
                #if os(macOS)
                tools
                #else
                ScrollView(.horizontal) { tools }.scrollIndicators(.hidden)
                #endif
                ColorPicker("Colour", selection: Binding(get: { viewer.color.cgColor }, set: {
                    #if os(macOS)
                    viewer.color = NSColor(cgColor: $0) ?? .black
                    #else
                    viewer.color = NSColor(cgColor: $0)
                    #endif
                }))
                    .labelsHidden()
            }
            #if os(iOS)
            // The undo manager says nothing when it changes; each change bumps the revision.
            let _ = viewer.doc.revision
            // A tap here leaves the words being typed in their field, so they become a change of their own first.
            Button("Undo", systemImage: "arrow.uturn.backward") {
                viewer.settle()
                undoManager?.undo()
            }
            .disabled(undoManager?.canUndo != true)
            Button("Redo", systemImage: "arrow.uturn.forward") {
                viewer.settle()
                undoManager?.redo()
            }
            .disabled(undoManager?.canRedo != true)
            #endif
            if !viewer.organizing {
                Button("Add to Every Page", systemImage: "rectangle.portrait.on.rectangle.portrait") { viewer.addToEveryPage() }
                    .help("Add to Every Page")
                    .disabled(!viewer.canAddToEveryPage)
                Button("Delete", systemImage: "trash", role: .destructive) { viewer.canvas.deleteMark() }
                    .help("Delete")
                    .disabled(viewer.mark == nil)
            }
        }
        .labelStyle(.iconOnly)
        .disabled(!viewer.isIdle)
        .padding(6)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    private var tools: some View {
        Picker("Tool", selection: $viewer.tool) {
            ForEach(Tool.allCases) { Label($0.name, systemImage: $0.symbol).help("\($0.name) (\($0.key.uppercased()))") }
        }
        .pickerStyle(.segmented)
        .labelStyle(.iconOnly)
        .labelsHidden()
        .fixedSize()
    }
}

#if os(macOS)
struct PageView: NSViewRepresentable {
    let viewer: Viewer

    func makeNSView(context: Context) -> Canvas { viewer.canvas }

    func updateNSView(_ canvas: Canvas, context: Context) {
        let _ = viewer.doc.revision
        viewer.showPages()
    }
}
#else
struct PageView: UIViewRepresentable {
    let viewer: Viewer

    func makeUIView(context: Context) -> Canvas { viewer.canvas }

    func updateUIView(_ canvas: Canvas, context: Context) {
        let _ = viewer.doc.revision
        viewer.showPages()
    }
}
#endif

struct Sidebar: View {
    let viewer: Viewer

    var body: some View {
        @Bindable var viewer = viewer
        VStack(spacing: 0) {
            Picker("Show", selection: $viewer.pane) {
                ForEach(Viewer.Pane.allCases) { Label(LocalizedStringKey($0.rawValue), systemImage: $0.symbol).help(LocalizedStringKey($0.rawValue)) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .labelStyle(.iconOnly)
            .padding(8)
            switch viewer.pane {
            case .thumbnails: Thumbnails(canvas: viewer.canvas)
            case .bookmarks: Bookmarks(viewer: viewer)
            case .comments: Comments(viewer: viewer)
            }
        }
    }
}

#if os(macOS)
struct Thumbnails: NSViewRepresentable {
    let canvas: Canvas

    func makeNSView(context: Context) -> PDFThumbnailView {
        let view = PDFThumbnailView()
        view.pdfView = canvas
        view.thumbnailSize = CGSize(width: 120, height: 160)
        view.backgroundColor = .clear
        return view
    }

    func updateNSView(_ view: PDFThumbnailView, context: Context) {}
}
#else
struct Thumbnails: UIViewRepresentable {
    let canvas: Canvas

    func makeUIView(context: Context) -> PDFThumbnailView {
        let view = PDFThumbnailView()
        view.pdfView = canvas
        view.layoutMode = .vertical
        view.thumbnailSize = CGSize(width: 120, height: 160)
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ view: PDFThumbnailView, context: Context) {}
}
#endif

extension PDFOutline: @retroactive Identifiable {
    /// The children, or nil for a leaf, as `List` wants them.
    var kids: [PDFOutline]? { numberOfChildren == 0 ? nil : (0..<numberOfChildren).compactMap { child(at: $0) } }
}

struct Bookmarks: View {
    let viewer: Viewer

    var body: some View {
        let _ = viewer.doc.revision
        if let items = viewer.doc.pdf.outlineRoot?.kids {
            List(items, children: \.kids) { item in
                Text(item.label ?? "")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    // A bookmark goes to its page by a destination or by a go-to action, which has none.
                    .onTapGesture {
                        if let destination = item.destination ?? (item.action as? PDFActionGoTo)?.destination { viewer.canvas.go(to: destination) }
                    }
            }
        } else {
            ContentUnavailableView("No Bookmarks", systemImage: "bookmark")
        }
    }
}

struct Comments: View {
    let viewer: Viewer

    var body: some View {
        let _ = viewer.doc.revision
        let comments = viewer.doc.comments.map(\.annotation)
        if comments.isEmpty {
            ContentUnavailableView("No Comments", systemImage: "text.bubble")
        } else {
            List(comments, id: \.self) { CommentRow(viewer: viewer, annotation: $0) }
        }
    }
}

struct CommentRow: View {
    let viewer: Viewer
    let annotation: PDFAnnotation
    @State private var text = ""
    @FocusState private var editing: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: Self.symbols[annotation.type ?? ""] ?? "questionmark")
                .foregroundStyle(annotation.type == "FreeText" ? annotation.fontColor.map { Color(cgColor: $0.cgColor) } ?? .primary
                                                               : Color(cgColor: annotation.color.cgColor))
            VStack(alignment: .leading, spacing: 2) {
                Text("Page \((annotation.page.map { viewer.doc.pdf.index(for: $0) } ?? 0) + 1)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Comment", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .focused($editing)
                    .onSubmit(commit)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if let page = annotation.page { viewer.canvas.go(to: annotation.bounds, on: page) } }
        .onChange(of: viewer.doc.revision, initial: true) { if !editing { text = annotation.contents ?? "" } }
        // While the words are typed, settling the document commits them too.
        .onChange(of: editing) { if editing { viewer.comment = (annotation, commit) } else { stop() } }
        .onDisappear(perform: stop)
        .task(id: viewer.focusNote) { if viewer.focusNote === annotation { editing = true } }
    }

    private func commit() {
        if text != annotation.contents ?? "" { viewer.doc.set(\.contents, of: annotation, to: text, name: "Edit Comment") }
    }

    /// Commits the words as the typing ends or the row goes, and leaves settling to the next comment typed.
    private func stop() {
        commit()
        if viewer.comment?.note === annotation { viewer.comment = nil }
    }

    static let symbols = ["Text": "note.text", "FreeText": "textformat", "Highlight": "highlighter", "Underline": "underline",
                          "StrikeOut": "strikethrough", "Square": "rectangle", "Circle": "circle", "Line": "line.diagonal",
                          "Ink": "pencil.tip"]
}

/// What the window says over the pages: the password a file needs, work in progress, and short messages.
struct Bars: View {
    let viewer: Viewer
    @State private var password = ""
    @State private var wrong = false

    var body: some View {
        let doc = viewer.doc, _ = viewer.doc.revision
        VStack(spacing: 8) {
            if !doc.canEdit {
                let lock = HStack {
                    Image(systemName: "lock.fill")
                    Text(doc.pdf.isLocked ? "This document is protected." : "Editing is restricted by the author.")
                }
                let field = HStack {
                    SecureField(doc.pdf.isLocked ? "Password" : "Permissions password", text: $password)
                        .frame(width: 180)
                        .onSubmit(unlock)
                    Button("Unlock", action: unlock)
                    if wrong { Text("Wrong password").foregroundStyle(.red) }
                }
                // On one line where it fits, as on the Mac; on two on a phone.
                ViewThatFits(in: .horizontal) {
                    HStack { lock; field }
                    VStack { lock; field }
                }
                .pill()
            }
            #if os(iOS)
            if !viewer.query.isEmpty {
                HStack(spacing: 16) {
                    Button("Previous", systemImage: "chevron.left") { viewer.step(-1) }
                    Text(viewer.matchLabel).monospacedDigit()
                    Button("Next", systemImage: "chevron.right") { viewer.step(1) }
                }
                .labelStyle(.iconOnly)
                .pill()
            }
            #endif
            if let busy = viewer.busy {
                HStack { ProgressView().controlSize(.small); Text(busy) }.pill()
            }
            if let message = viewer.message { Text(message).pill() }
        }
        .padding(.top, 12)
    }

    private func unlock() {
        wrong = !viewer.doc.unlock(password)
        if !wrong { password = "" }
    }
}

private extension View {
    func pill() -> some View {
        padding(.horizontal, 14).padding(.vertical, 8).background(.regularMaterial, in: .capsule).shadow(radius: 2)
    }
}
