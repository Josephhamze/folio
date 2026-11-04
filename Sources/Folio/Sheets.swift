import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// The pad for the sign tool's signature, the initial tool's initials or the stamp tool's stamp: draw it, type it, or choose
/// a photo or scan of it on paper, then save it for its tool.
struct SignatureSheet: View {
    enum Way { case draw, type, image }

    let viewer: Viewer
    let tool: Tool
    @Environment(\.dismiss) private var dismiss
    @State private var way: Way
    @State private var strokes: [[CGPoint]] = []
    @State private var drawing = false
    @State private var name = ""
    /// The picture chosen, as a PNG of its ink lifted off the paper, and where it's chosen from.
    @State private var picture: Data?
    @State private var noInk = false
    @State private var photo: PhotosPickerItem?
    @State private var choosingFile = false
    #if os(macOS)
    private let pad = CGSize(width: 480, height: 160)
    #else
    private let pad = CGSize(width: 340, height: 120)
    #endif

    init(viewer: Viewer, tool: Tool) {
        self.viewer = viewer
        self.tool = tool
        // A company's stamp is a picture of what its rubber stamp prints.
        _way = State(initialValue: tool == .stamp ? .image : .draw)
    }

    var body: some View {
        VStack(spacing: 16) {
            Text(tool == .sign ? "Signature" : tool == .initial ? "Initials" : "Stamp").font(.headline)
            Picker("Signature", selection: $way) {
                Text("Draw").tag(Way.draw)
                Text("Type").tag(Way.type)
                Text("Image").tag(Way.image)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Group {
                switch way {
                case .draw:
                    SwiftUI.Canvas { context, _ in context.fill(Path(Signature.drawn(strokes).path), with: .color(.black)) }
                        .background(.white)
                        .gesture(DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                if !drawing { strokes.append([]) }
                                drawing = true
                                strokes[strokes.count - 1].append(value.location)
                            }
                            .onEnded { _ in drawing = false })
                case .type:
                    VStack {
                        TextField(tool == .sign ? "Your name" : "Your initials", text: $name)
                        // As it will be placed, y up, so turned over for the view, whose y runs down.
                        SwiftUI.Canvas { context, size in
                            let path = Signature.typed(name).path(in: CGRect(x: 20, y: size.height / 2 - 30, width: size.width - 40, height: 60))
                            context.fill(Path(path).applying(CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: size.height)), with: .foreground)
                        }
                    }
                case .image:
                    // The ink on white, as it will look on a page.
                    Group {
                        if let image = picture.flatMap(Signature.picture) {
                            Image(decorative: image, scale: 1).resizable().scaledToFit().padding(8)
                        } else {
                            Text(noInk ? "There's no ink in that picture. Try one of it on white paper." : "A photo or scan of it on white paper")
                                .multilineTextAlignment(.center)
                                .foregroundStyle(.gray)
                                .padding()
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.white)
                }
            }
            .frame(width: pad.width, height: pad.height)
            HStack {
                switch way {
                case .draw: Button("Clear") { strokes = [] }.disabled(strokes.isEmpty)
                case .type: EmptyView()
                case .image:
                    PhotosPicker("Photos…", selection: $photo, matching: .images)
                    Button("Files…") { choosingFile = true }
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save") {
                    // The pad's y runs down; a page's runs up.
                    Signature[tool] = switch way {
                    case .draw: .drawn(strokes.map { $0.map { CGPoint(x: $0.x, y: pad.height - $0.y) } })
                    case .type: .typed(name)
                    case .image: picture.map(Signature.image)
                    }
                    viewer.pick(tool)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(way == .draw ? strokes.isEmpty : way == .type ? name.trimmingCharacters(in: .whitespaces).isEmpty : picture == nil)
            }
        }
        .padding(20)
        .onChange(of: photo) {
            Task { show(try? await photo?.loadTransferable(type: Data.self)) }
        }
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.image]) { result in
            guard let url = try? result.get() else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            show(try? Data(contentsOf: url))
        }
    }

    /// Shows the picture's ink lifted off its paper, or says it has none.
    private func show(_ data: Data?) {
        guard let data else { return }
        picture = Signature.lifted(from: data)
        noInk = picture == nil
    }
}

/// Sets the password the file opens with once it's saved, and what it allows without a second, permissions password, or
/// takes them off.
struct PasswordSheet: View {
    let viewer: Viewer
    @Environment(\.dismiss) private var dismiss
    @State private var password: String
    @State private var again: String
    @State private var restricts: Bool
    @State private var restrictions: FolioDocument.Restrictions
    @State private var permissionsAgain: String

    init(viewer: Viewer) {
        self.viewer = viewer
        // As a file made from it would be saved: a protected file keeps its own password and restrictions, unless they're
        // changed here.
        let kept = viewer.doc.keptPassword ?? "", restrictions = viewer.doc.keptRestrictions
        (_password, _again) = (State(initialValue: kept), State(initialValue: kept))
        _restricts = State(initialValue: restrictions != nil)
        _restrictions = State(initialValue: restrictions ?? FolioDocument.Restrictions(password: ""))
        _permissionsAgain = State(initialValue: restrictions?.password ?? "")
    }

    var body: some View {
        // PDFKit can't protect a file with any other character, and saves it unprotected.
        let ascii = (password + (restricts ? restrictions.password : "")).allSatisfy(\.isASCII)
        // The password that opens the file would lift its restrictions too.
        let same = restricts && !password.isEmpty && restrictions.password == password
        VStack(spacing: 16) {
            Text("Password").font(.headline)
            Text("Once saved, the file asks for this password to open it.").foregroundStyle(.secondary)
            SecureField("Password", text: $password)
            SecureField("Again", text: $again)
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Restrict printing, copying and changes", isOn: $restricts)
                if restricts {
                    SecureField("Permissions password", text: $restrictions.password)
                    SecureField("Again", text: $permissionsAgain)
                    Toggle("Allow printing", isOn: $restrictions.printing)
                    Toggle("Allow copying", isOn: $restrictions.copying)
                    Toggle("Allow changes", isOn: $restrictions.changes)
                    Text("Apps that respect restrictions ask for this password first, but not every app does.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if viewer.doc.pdf.isEncrypted { Text("This replaces the file's own password and restrictions.").foregroundStyle(.secondary) }
            if !ascii { Text("Use only English letters, digits and symbols.").foregroundStyle(.red) }
            if same { Text("Use a permissions password other than the one that opens the file.").foregroundStyle(.red) }
            HStack {
                if viewer.doc.newPassword != nil || viewer.doc.newRestrictions != nil || viewer.doc.pdf.isEncrypted {
                    Button("Remove Password") { set(nil, nil) }
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Set Password") { set(password.isEmpty ? nil : password, restricts ? restrictions : nil) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!ascii || same || password != again || password.isEmpty && !restricts
                              || restricts && (restrictions.password.isEmpty || restrictions.password != permissionsAgain))
            }
        }
        .frame(width: 340)
        .padding(20)
    }

    private func set(_ new: String?, _ restrictions: FolioDocument.Restrictions?) {
        // A protected file's pages move to a new document, which would show its first page.
        if viewer.doc.pdf.isEncrypted { viewer.resume = viewer.pageIndex }
        viewer.doc.setPassword(new, restrictions: restrictions)
        viewer.message = new == nil && restrictions == nil ? String(localized: "The password comes off once the file is saved")
            : String(localized: "The password goes on once the file is saved")
        dismiss()
    }
}

/// The title, author, subject and keywords the file keeps about itself, which other apps and searches show.
struct PropertiesSheet: View {
    let viewer: Viewer
    @Environment(\.dismiss) private var dismiss
    @State private var values: [String]

    init(viewer: Viewer) {
        self.viewer = viewer
        _values = State(initialValue: viewer.doc.properties)
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Properties").font(.headline)
            Grid(alignment: .leading) {
                GridRow { Text("Title").gridColumnAlignment(.trailing); TextField("Title", text: $values[0]) }
                GridRow { Text("Author"); TextField("Author", text: $values[1]) }
                GridRow { Text("Subject"); TextField("Subject", text: $values[2]) }
                GridRow { Text("Keywords"); TextField("Keywords", text: $values[3], prompt: Text("Separated by commas")) }
            }
            .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save") {
                    viewer.doc.setProperties(values)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .frame(width: 340)
        .padding(20)
    }
}

/// Splits the document into files of a few pages each, in a folder chosen next, named after the document and numbered.
struct SplitSheet: View {
    let viewer: Viewer
    let name: String
    @Environment(\.dismiss) private var dismiss
    @State private var every = 1
    @State private var choosing = false
    @State private var splitting = false
    @State private var problem: String?

    var body: some View {
        let count = viewer.doc.pdf.pageCount
        VStack(spacing: 16) {
            Text("Split into Files").font(.headline)
            Stepper("Pages in each file: \(every)", value: $every, in: 1...max(1, count - 1))
            Text("Makes \((count + every - 1) / every) files, named “\(name) 1”, “\(name) 2” and so on.").foregroundStyle(.secondary)
            if let problem { Text(problem).foregroundStyle(.red) }
            HStack {
                if splitting { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Choose Folder…") { choosing = true }.keyboardShortcut(.defaultAction).disabled(splitting)
            }
        }
        .frame(width: 340)
        .padding(20)
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder]) { result in
            guard case .success(let folder) = result else { return }
            splitting = true
            Task {
                let open = folder.startAccessingSecurityScopedResource()
                defer {
                    if open { folder.stopAccessingSecurityScopedResource() }
                    splitting = false
                }
                do {
                    let urls = try await viewer.doc.split(every: every, into: folder, name: name)
                    viewer.message = String(localized: "Saved \(urls.count) files in \(folder.lastPathComponent)")
                    dismiss()
                } catch let error as CocoaError where error.code == .fileWriteFileExists {
                    let taken = (error.userInfo[NSFilePathErrorKey] as? String).map { URL(fileURLWithPath: $0).lastPathComponent } ?? name
                    problem = String(localized: "“\(taken)” is already in \(folder.lastPathComponent). Choose another folder.")
                } catch {
                    problem = String(localized: "Couldn't save the files in \(folder.lastPathComponent).")
                }
            }
        }
    }
}
