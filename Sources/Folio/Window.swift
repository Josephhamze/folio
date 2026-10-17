import PDFKit
import SwiftUI

/// A window's state: its document, its page view and what the window shows.
@Observable
final class Viewer {
    enum Pane: String, CaseIterable, Identifiable {
        case thumbnails = "Thumbnails", bookmarks = "Bookmarks", comments = "Comments"

        var id: Self { self }
        var symbol: String { self == .thumbnails ? "rectangle.grid.1x2" : self == .bookmarks ? "bookmark" : "text.bubble" }
    }

    enum Sheet: Hashable, Identifiable {
        /// The pad for the sign tool's signature, or the initial tool's initials.
        case signature(Tool)
        case protect, properties, split

        var id: Self { self }
    }

    let doc: FolioDocument
    @ObservationIgnored lazy var canvas = Canvas(viewer: self)
    var pane = Pane.thumbnails
    var organizing = false
    var selection: Set<PDFPage> = []
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
    var tool = Tool.select
    var color = NSColor.systemYellow
    /// A note just added, whose comment field takes the keys.
    var focusNote: PDFAnnotation?
    var query = ""
    private(set) var matches: [PDFSelection] = []
    private(set) var match = 0

    init(doc: FolioDocument) {
        self.doc = doc
    }

    func find() {
        matches = query.isEmpty ? [] : doc.pdf.findString(query, withOptions: .caseInsensitive)
        matches.forEach { $0.color = .findHighlightColor }
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

    var matchLabel: String { query.isEmpty ? "" : matches.isEmpty ? "No matches" : "\(match + 1) of \(matches.count)" }

    /// The pages that page commands act on: the selected ones while organizing, otherwise the one in view.
    var targetPages: [PDFPage] {
        organizing ? doc.pages.filter(selection.contains) : [canvas.currentPage].compactMap { $0 }
    }

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

    /// Moves the selection, or only the dragged page when it isn't selected, in front of `target`, or to the end.
    func drop(_ dragged: PDFPage, before target: PDFPage?) {
        let moving = selection.contains(dragged) ? Array(selection) : [dragged]
        if let target, moving.contains(target) { return }
        doc.move(moving, to: target.flatMap { doc.pages.firstIndex(of: $0) } ?? doc.pdf.pageCount)
    }

    /// Puts pages after the last target page.
    func insert(_ pages: [PDFPage]) {
        guard !pages.isEmpty else { return }
        doc.insert(pages, at: (targetPages.last.flatMap { doc.pages.firstIndex(of: $0) } ?? doc.pdf.pageCount - 1) + 1)
    }

    /// A PDF can't be saved without a page, so the last ones stay.
    var canDelete: Bool { doc.canEdit && !targetPages.isEmpty && targetPages.count < doc.pdf.pageCount }

    func deletePages() {
        doc.delete(targetPages)
        selection = []
    }
}

struct DocumentView: View {
    @State var viewer: Viewer
    @State private var columns = NavigationSplitViewVisibility.all
    @FocusState private var searching: Bool
    @Environment(\.undoManager) private var undoManager

    init(doc: FolioDocument) {
        _viewer = State(initialValue: Viewer(doc: doc))
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            Sidebar(viewer: viewer)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        } detail: {
            PageView(viewer: viewer)
                .overlay(alignment: .top) { Bars(viewer: viewer) }
                .safeAreaInset(edge: .top, spacing: 0) { if !viewer.readMode { ToolBar(viewer: viewer) } }
        }
        .toolbar { ToolbarItem { Text(viewer.matchLabel).foregroundStyle(.secondary).monospacedDigit() } }
        .toolbar(viewer.readMode ? .hidden : .visible, for: .windowToolbar)
        .searchable(text: $viewer.query, placement: .toolbar, prompt: "Find")
        .searchFocused($searching)
        .onChange(of: viewer.query) { viewer.find() }
        .onSubmit(of: .search) { viewer.step(1) }
        .onChange(of: viewer.readMode) {
            columns = viewer.readMode ? .detailOnly : .all
            if let window = viewer.canvas.window, window.styleMask.contains(.fullScreen) != viewer.readMode {
                window.toggleFullScreen(nil)
            }
        }
        .onChange(of: viewer.tool) { viewer.canvas.selected = nil }
        .onChange(of: viewer.doc.revision) {
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
        }
        .onExitCommand { viewer.readMode = false }
        // Esc, the green button or ⌃⌘F can end full screen without SwiftUI seeing it.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) {
            if $0.object as? NSWindow === viewer.canvas.window { viewer.readMode = false }
        }
        .focusedSceneValue(\.viewer, viewer)
        .focusedSceneValue(\.searchFocus, $searching)
        .frame(minWidth: 700, minHeight: 500)
        .onAppear { viewer.doc.undo = undoManager }
        .onChange(of: undoManager) { viewer.doc.undo = undoManager }
    }
}

/// The tools and the colour, in a bar across the top of the pages.
struct ToolBar: View {
    @Bindable var viewer: Viewer

    var body: some View {
        HStack {
            Picker("Tool", selection: $viewer.tool) {
                ForEach(Tool.allCases) { Label($0.name, systemImage: $0.symbol).help($0.name) }
            }
            .pickerStyle(.segmented)
            .labelStyle(.iconOnly)
            .labelsHidden()
            .fixedSize()
            ColorPicker("Colour", selection: Binding(get: { viewer.color.cgColor }, set: { viewer.color = NSColor(cgColor: $0) ?? .black }))
                .labelsHidden()
        }
        .disabled(!viewer.doc.canEdit)
        .padding(6)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }
}

struct PageView: NSViewRepresentable {
    let viewer: Viewer

    func makeNSView(context: Context) -> Canvas { viewer.canvas }

    func updateNSView(_ canvas: Canvas, context: Context) {
        let _ = viewer.doc.revision
        // A locked file stays out of the page view, which would ask for its password a second time.
        let pdf = viewer.doc.pdf.isLocked ? nil : viewer.doc.pdf
        if canvas.document !== pdf { canvas.document = pdf }
    }
}

struct Sidebar: View {
    let viewer: Viewer

    var body: some View {
        @Bindable var viewer = viewer
        VStack(spacing: 0) {
            Picker("Show", selection: $viewer.pane) {
                ForEach(Viewer.Pane.allCases) { Label($0.rawValue, systemImage: $0.symbol).help($0.rawValue) }
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
                    .onTapGesture { if let destination = item.destination { viewer.canvas.go(to: destination) } }
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
                .foregroundStyle(Color(nsColor: annotation.type == "FreeText" ? annotation.fontColor ?? .labelColor : annotation.color))
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
        .onChange(of: editing) { if !editing { commit() } }
        .task(id: viewer.focusNote) { if viewer.focusNote === annotation { editing = true } }
    }

    private func commit() {
        if text != annotation.contents ?? "" { viewer.doc.set(\.contents, of: annotation, to: text, name: "Edit Comment") }
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
                HStack {
                    Image(systemName: "lock.fill")
                    Text(doc.pdf.isLocked ? "This document is protected." : "Editing is restricted by the author.")
                    SecureField(doc.pdf.isLocked ? "Password" : "Permissions password", text: $password)
                        .frame(width: 180)
                        .onSubmit(unlock)
                    Button("Unlock", action: unlock)
                    if wrong { Text("Wrong password").foregroundStyle(.red) }
                }
                .pill()
            }
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
