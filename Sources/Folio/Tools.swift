import PDFKit
import Vision
#if os(macOS)
import Quartz
#endif

/// The page's own drawing, without its annotations, in grey on white at `dpi`, as the file has it: the whole media box,
/// unturned. A page so big it would pass 4,000 pixels a side gets fewer dots, to fit a phone's memory.
func render(_ page: PDFPage, dpi: CGFloat) -> CGImage? {
    let box = page.bounds(for: .mediaBox), scale = min(dpi / 72, 4000 / max(box.width, box.height, 1))
    guard let context = CGContext(data: nil, width: Int(box.width * scale), height: Int(box.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
    context.setFillColor(gray: 1, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))
    context.scaleBy(x: scale, y: scale)
    context.translateBy(x: -box.minX, y: -box.minY)
    drawContent(of: page, in: context)
    return context.makeImage()
}

/// Draws the page's own content, not its annotations, in the page's space.
private func drawContent(of page: PDFPage, in context: CGContext) {
    if let ref = page.pageRef { return context.drawPDFPage(ref) }
    // A page made in memory, such as one from a picture, has no page of a file to draw.
    let shown = page.displaysAnnotations
    page.displaysAnnotations = false
    page.draw(with: .mediaBox, to: context)
    page.displaysAnnotations = shown
}

/// The lines of text Vision reads in the picture, each with its box as a share of the picture, from the bottom left. It
/// finds the language itself, among those it reads, which include English, French and Chinese.
func recognize(_ image: CGImage) async throws -> [(text: String, box: CGRect)] {
    var request = RecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.automaticallyDetectsLanguage = true
    return try await request.perform(on: image).compactMap { line in line.topCandidates(1).first.map { (text: $0.string, box: line.boundingBox.cgRect) } }
}

/// The page drawn again with these lines of text under its drawing, invisible, each fitted to its box, so the words can be
/// found, selected and copied where they show. The new page keeps the page's turn, crop box and annotations, but popups.
/// shortcut: a bookmark to the page still points at the old one, so loses its page. Point bookmarks at the new page if
/// scans with bookmarks turn up.
func rebuilt(_ page: PDFPage, text: [(text: String, box: CGRect)]) -> PDFPage? {
    var media = page.bounds(for: .mediaBox)
    let data = NSMutableData()
    guard let consumer = CGDataConsumer(data: data as CFMutableData), let context = CGContext(consumer: consumer, mediaBox: &media, nil) else { return nil }
    context.beginPDFPage(nil)
    drawContent(of: page, in: context)
    context.setTextDrawingMode(.invisible)
    for (words, share) in text {
        let box = CGRect(x: media.minX + share.minX * media.width, y: media.minY + share.minY * media.height,
                         width: share.width * media.width, height: share.height * media.height)
        // Helvetica, or for other scripts the font Core Text finds, at the line's height and stretched to its width, on
        // a baseline above the descenders.
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: words, attributes: [.font: CTFontCreateWithName("Helvetica" as CFString, box.height * 0.8, nil)]))
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        guard width > 0 else { continue }
        context.textMatrix = CGAffineTransform(scaleX: box.width / width, y: 1)
        context.textPosition = CGPoint(x: box.minX, y: box.minY + box.height * 0.2)
        CTLineDraw(line, context)
    }
    context.endPDFPage()
    context.closePDF()
    guard let new = PDFDocument(data: data as Data)?.page(at: 0)?.copy() as? PDFPage else { return nil }
    new.rotation = page.rotation
    new.setBounds(page.bounds(for: .cropBox), for: .cropBox)
    for a in page.annotations where a.type != "Popup" { new.addAnnotation(a.copy() as! PDFAnnotation) }
    return new
}

extension FolioDocument {
    /// Reads the words on each page that has no text, such as a scan, and puts them under the page as invisible text, as one
    /// change. `progress` hears as each page begins: how many are done, of how many. It returns how many pages it read, of
    /// how many had no text.
    @MainActor func recognizeText(progress: (Int, Int) -> Void) async -> (read: Int, of: Int) {
        let scans = pages.filter { ($0.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        var found: [(page: PDFPage, text: [(text: String, box: CGRect)])] = []
        for (done, page) in scans.enumerated() {
            progress(done, scans.count)
            guard let image = render(page, dpi: 300), let text = try? await recognize(image), !text.isEmpty else { continue }
            found.append((page, text))
        }
        // Rebuilt only now, so each keeps its page's marks as they are at the end.
        let new = Dictionary(uniqueKeysWithValues: found.compactMap { page, text in rebuilt(page, text: text).map { (page, $0) } })
        if !new.isEmpty { setPages(pages.map { new[$0] ?? $0 }, name: "Recognize Text") }
        return (new.count, scans.count)
    }

    #if os(macOS)
    /// Rewrites the document through macOS's Reduce File Size filter, which keeps pictures as JPEG at 144 dpi, and keeps
    /// the result as one change when it's smaller: a file of text and lines can grow. It works on a copy, away from the
    /// window, and returns the sizes before and after, or nil when it changed nothing. A change made meanwhile, such as an
    /// undo, would be lost to the copy, so then it changes nothing either. (PDFKit's own write options for pictures shrink
    /// only those it made from photos, not those of a file it read, so iOS has no way to do this.)
    @MainActor func reduceFileSize() async -> (before: Int, after: Int)? {
        guard let before = pdf.dataRepresentation() else { return nil }
        let password = password, encrypted = pdf.isEncrypted, start = revision
        let after = await Task.detached { () -> Data? in
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).pdf")
            defer { try? FileManager.default.removeItem(at: file) }
            let filter: QuartzFilter? = QuartzFilter(url: URL(fileURLWithPath: "/System/Library/Filters/Reduce File Size.qfilter"))
            guard let filter, let copy = PDFDocument(data: before), !copy.isLocked || password.map({ copy.unlock(withPassword: $0) }) == true,
                  copy.write(to: file, withOptions: [PDFDocumentWriteOption(rawValue: "QuartzFilter"): filter]) else { return nil }
            return try? Data(contentsOf: file)
        }.value
        // Never at the cost of the file's password.
        guard revision == start, let after, after.count < before.count, let smaller = PDFDocument(data: after), smaller.isEncrypted == encrypted,
              !smaller.isLocked || password.map({ smaller.unlock(withPassword: $0) }) == true else { return nil }
        let old = pdf
        change("Reduce File Size", do: { self.pdf = smaller }, undo: { self.pdf = old })
        return (before.count, after.count)
    }
    #endif
}
