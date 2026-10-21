#if os(macOS)
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

/// The window Folio opens on: the files opened lately, a click from opening again, and a button for any other.
struct Home: View {
    @Environment(\.openDocument) private var openDocument
    @State private var recents: [URL] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
                Text("Folio").font(.largeTitle.bold())
                Spacer()
                Button("Open…") { NSDocumentController.shared.openDocument(nil) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
            if recents.isEmpty {
                ContentUnavailableView("No Recent Files", systemImage: "doc.richtext",
                                       description: Text("PDFs you open show up here. You can also drop one on this window."))
            } else {
                Text("Recent").font(.headline).foregroundStyle(.secondary)
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                        ForEach(recents, id: \.self) { url in RecentFile(url: url) { open(url) } }
                    }
                }
            }
        }
        .padding(24)
        .frame(minWidth: 560, minHeight: 400)
        .dropDestination(for: URL.self) { urls, _ in
            let pdfs = urls.filter { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .pdf) == true }
            pdfs.forEach(open)
            return !pdfs.isEmpty
        }
        .onAppear { recents = NSDocumentController.shared.recentDocumentURLs.filter { FileManager.default.fileExists(atPath: $0.path) } }
    }

    private func open(_ url: URL) {
        Task {
            do { try await openDocument(at: url) } catch { NSApp.presentError(error) }
        }
    }
}

/// A recent file: its first page, its name and its folder. A click opens it.
struct RecentFile: View {
    let url: URL
    let open: () -> Void
    @State private var thumbnail: NSImage?
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            VStack(spacing: 6) {
                Image(nsImage: thumbnail ?? NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 120, height: 150)
                    .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
                Text(url.deletingPathExtension().lastPathComponent)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                Text(url.deletingLastPathComponent().lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(10)
            .frame(maxWidth: .infinity)
            .background(hovering ? Color.primary.opacity(0.07) : .clear, in: .rect(cornerRadius: 10))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(url.path)
        .contextMenu { Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
        .task {
            let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 120, height: 150), scale: 2, representationTypes: .thumbnail)
            thumbnail = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
        }
    }
}
#endif
