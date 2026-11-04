import PDFKit
import SwiftUI
#if os(iOS)
import VisionKit
#endif

/// The pages as a grid, over the page view while organizing. A click selects a page, and ⌘ and ⇧ clicks select more; on
/// iOS a tap selects or deselects one. Dragged pages move in front of the page they're dropped on, or to the end.
struct Organizer: View {
    let viewer: Viewer

    var body: some View {
        let pages = viewer.doc.pages, revision = viewer.doc.revision
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 172), spacing: 12)], spacing: 16) {
                ForEach(Array(pages.enumerated()), id: \.element) { index, page in
                    PageCell(page: page, number: index + 1, selected: viewer.selection.contains(page), revision: revision)
                        .onTapGesture {
                            #if os(macOS)
                            viewer.click(page, modifiers: NSEvent.modifierFlags)
                            #else
                            viewer.selection.formSymmetricDifference([page])
                            #endif
                        }
                        .draggable(viewer.dragged(page))
                        .dropDestination(for: String.self) { items, _ in
                            guard let item = items.first else { return false }
                            return viewer.drop(item, before: page)
                        }
                }
            }
            .padding()
        }
        .dropDestination(for: String.self) { items, _ in
            guard let item = items.first else { return false }
            return viewer.drop(item, before: nil)
        }
        .background(.background)
    }
}

/// A page in the organizer, as it shows, with its number under it, and tinted when selected.
private struct PageCell: View {
    let page: PDFPage
    let number: Int
    let selected: Bool
    /// The document's revision, to draw the page again when it changes.
    let revision: Int
    @State private var image: CGImage?

    var body: some View {
        VStack(spacing: 6) {
            Group {
                if let image { Image(decorative: image, scale: 2).resizable().scaledToFit().shadow(radius: 2) } else { Color.clear }
            }
            .frame(width: 160, height: 160)
            .padding(6)
            .background(selected ? Color.accentColor.opacity(0.25) : .clear, in: .rect(cornerRadius: 8))
            Text("\(number)").monospacedDigit().foregroundStyle(selected ? Color.accentColor : Color.secondary)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Page \(number)")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .task(id: revision) {
            let size = page.bounds(for: .cropBox).size
            image = shown(page, dpi: 72 * 320 / max(size.width, size.height, 1))
        }
    }
}

/// What acts on pages: the selected ones while organizing, otherwise the one in view. They make the Pages menu, and the bar
/// across the pages while organizing.
struct PageActions: View {
    let viewer: Viewer?

    var body: some View {
        let _ = viewer?.doc.revision
        let idle = viewer?.isIdle ?? false, chosen = idle && viewer?.targetPages.isEmpty == false
        Button("Rotate Left", systemImage: "rotate.left") { if let viewer { viewer.doc.rotate(viewer.targetPages, by: -90) } }
            .keyboardShortcut("l")
            .help("Rotate Left")
            .disabled(!chosen)
        Button("Rotate Right", systemImage: "rotate.right") { if let viewer { viewer.doc.rotate(viewer.targetPages, by: 90) } }
            .keyboardShortcut("r")
            .help("Rotate Right")
            .disabled(!chosen)
        Button("Insert Blank Page", systemImage: "doc.badge.plus") { viewer?.insert([FolioDocument.blankPage()]) }
            .help("Insert Blank Page")
            .disabled(!idle)
        Button("Insert from File…", systemImage: "folder.badge.plus") { viewer?.choosingPages = true }
            .help("Insert from File…")
            .disabled(!idle)
        #if os(iOS)
        if VNDocumentCameraViewController.isSupported {
            Button("Scan Pages…", systemImage: "doc.viewfinder") { viewer?.scanning = true }
                .help("Scan Pages…")
                .disabled(!idle)
        }
        #endif
        Button("Extract Pages…", systemImage: "square.and.arrow.up") { viewer?.extract() }
            .help("Extract Pages…")
            .disabled(!chosen || viewer?.doc.pdf.hasFullRights != true)
        Button("Split…", systemImage: "scissors") {
            viewer?.settle()
            viewer?.sheet = .split
        }
        .help("Split…")
        .disabled(!idle || viewer?.doc.pdf.hasFullRights != true || (viewer?.doc.pdf.pageCount ?? 0) < 2)
        Button("Delete Pages", systemImage: "trash", role: .destructive) { viewer?.deletePages() }
            .help("Delete Pages")
            .disabled(!idle || viewer?.canDelete != true)
    }
}

#if os(iOS)
/// The system's document scanner, which hands back the pages it scanned, or none when cancelled.
struct PageScanner: UIViewControllerRepresentable {
    let done: ([UIImage]) -> Void

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let scanner = VNDocumentCameraViewController()
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: VNDocumentCameraViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(done: done) }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let done: ([UIImage]) -> Void

        init(done: @escaping ([UIImage]) -> Void) { self.done = done }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            done((0..<scan.pageCount).map(scan.imageOfPage(at:)))
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) { done([]) }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) { done([]) }
    }
}
#endif
