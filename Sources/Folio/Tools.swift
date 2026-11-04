import ImageIO
import PDFKit
import Vision
#if os(macOS)
import Quartz
#endif

/// The page's own drawing, without its annotations, on white at `dpi`, as the file has it: the whole media box, unturned,
/// with the areas `blacked`, in page space, filled black. A page so big it would pass 4,000 pixels a side gets fewer dots,
/// to fit a phone's memory.
func render(_ page: PDFPage, dpi: CGFloat, blacking blacked: [CGRect] = []) -> CGImage? {
    let box = page.bounds(for: .mediaBox), scale = min(dpi / 72, 4000 / max(box.width, box.height, 1))
    guard let context = CGContext(data: nil, width: Int(box.width * scale), height: Int(box.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))
    context.scaleBy(x: scale, y: scale)
    context.translateBy(x: -box.minX, y: -box.minY)
    drawContent(of: page, in: context)
    context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
    context.fill(blacked)
    return context.makeImage()
}

/// Draws the page's own content, not its annotations, unturned, in the page's space.
private func drawContent(of page: PDFPage, in context: CGContext) {
    if let ref = page.pageRef { return context.drawPDFPage(ref) }
    // A page made in memory, such as one from a picture, has no page of a file to draw, and PDFKit draws it turned.
    let (shown, turn) = (page.displaysAnnotations, page.rotation)
    (page.displaysAnnotations, page.rotation) = (false, 0)
    page.draw(with: .mediaBox, to: context)
    (page.displaysAnnotations, page.rotation) = (shown, turn)
}

/// The lines of text Vision reads in the picture, each with its box as a share of the picture, from the bottom left. It
/// finds the language itself, among those it reads, which include English, French and Chinese.
func recognize(_ image: CGImage) async throws -> [(text: String, box: CGRect)] {
    var request = RecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.automaticallyDetectsLanguage = true
    return try await request.perform(on: image).compactMap { line in line.topCandidates(1).first.map { (text: $0.string, box: line.boundingBox.cgRect) } }
}

/// The page drawn again, or `picture` in its place, filling its media box, with these lines of text under it, invisible,
/// each fitted to its box, so the words can be found, selected and copied where they show. The new page keeps the page's
/// turn, crop box and annotations, but popups.
func rebuilt(_ page: PDFPage, text: [(text: String, box: CGRect)], over picture: CGImage? = nil) -> PDFPage? {
    var media = page.bounds(for: .mediaBox)
    let data = NSMutableData()
    guard let consumer = CGDataConsumer(data: data as CFMutableData), let context = CGContext(consumer: consumer, mediaBox: &media, nil) else { return nil }
    context.beginPDFPage(nil)
    if let picture { context.draw(picture, in: media) } else { drawContent(of: page, in: context) }
    context.setTextDrawingMode(.invisible)
    for (words, share) in text {
        let box = CGRect(x: media.minX + share.minX * media.width, y: media.minY + share.minY * media.height,
                         width: share.width * media.width, height: share.height * media.height)
        // Helvetica, or for other scripts the font Core Text finds, at the line's height and stretched to its width, on
        // a baseline above the descenders.
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: words, attributes: [.font: CTFontCreateWithName("Helvetica" as CFString, box.height * 0.8, nil)]))
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        guard width > 0 else { continue }
        // Stretched by the context, not the text matrix, which Core Text sets for itself as it draws.
        context.saveGState()
        context.translateBy(x: box.minX, y: box.minY + box.height * 0.2)
        context.scaleBy(x: box.width / width, y: 1)
        context.textPosition = .zero
        CTLineDraw(line, context)
        context.restoreGState()
    }
    context.endPDFPage()
    context.closePDF()
    guard let new = PDFDocument(data: data as Data)?.page(at: 0)?.copy() as? PDFPage else { return nil }
    new.rotation = page.rotation
    new.setBounds(page.bounds(for: .cropBox), for: .cropBox)
    for a in page.annotations where a.type != "Popup" { new.addAnnotation(a.copy() as! PDFAnnotation) }
    return new
}

/// The page as it shows, its crop, turn and marks included, on white at `dpi`.
func shown(_ page: PDFPage, dpi: CGFloat) -> CGImage? {
    let box = page.bounds(for: .cropBox), scale = dpi / 72, turned = page.rotation % 180 != 0
    let width = Int((turned ? box.height : box.width) * scale), height = Int((turned ? box.width : box.height) * scale)
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.scaleBy(x: scale, y: scale)
    page.draw(with: .cropBox, to: context)   // turned and cropped as it shows
    return context.makeImage()
}

/// The page as it shows, as a JPEG at `dpi`: to send in a chat app, where a picture shows at once and a PDF is a file to
/// download.
func picture(of page: PDFPage, dpi: CGFloat = 144) -> Data? { shown(page, dpi: dpi).flatMap(jpeg) }

/// The picture as a JPEG, at a quality that keeps text sharp.
func jpeg(_ image: CGImage) -> Data? {
    let data = NSMutableData()
    guard let file = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(file, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
    return CGImageDestinationFinalize(file) ? data as Data : nil
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
        if !new.isEmpty { setPages(pages.map { new[$0] ?? $0 }, name: "Recognize Text", replacing: new) }
        return (new.count, scans.count)
    }

    /// Burns in the redaction marks, as one change. Each page with marks becomes a picture of itself at 300 dpi with the
    /// marked areas black, so what was under them is gone from the file. It gets back the words read from the picture, so
    /// the rest can still be found, and its marks but those that overlap a redaction, which could tell what it hid. It
    /// returns how many pages it redacted, or nil, having changed nothing, when a page couldn't be, or the document changed
    /// meanwhile: a mark moved would leave black where it was, and the words where it is.
    @MainActor func applyRedactions() async -> Int? {
        let start = revision
        var new: [PDFPage: PDFPage] = [:]
        for page in pages {
            let marks = page.annotations.filter(\.isRedaction).map(\.bounds)
            guard !marks.isEmpty else { continue }
            // Kept as a JPEG, which the file holds as it is: a page-sized picture kept as drawn would weigh megabytes.
            guard let image = render(page, dpi: 300, blacking: marks), let data = jpeg(image), let provider = CGDataProvider(data: data as CFData),
                  let picture = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent),
                  let redacted = rebuilt(page, text: (try? await recognize(image)) ?? [], over: picture) else { return nil }
            for a in redacted.annotations where a.isRedaction || marks.contains(where: a.bounds.intersects) { redacted.removeAnnotation(a) }
            new[page] = redacted
        }
        guard revision == start else { return nil }
        if !new.isEmpty { setPages(pages.map { new[$0] ?? $0 }, name: "Apply Redactions", replacing: new) }
        return new.count
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
