import CoreImage
import ImageIO
import PDFKit
import Vision
import XCTest
@testable import Folio

/// Pages that are pictures of these lines, as a scanner makes them: letter pages holding only a 200 dpi picture of the lines
/// in Helvetica 24, the first 100 points from the top, then one every 50.
func scannedPDF(_ pages: [[String]]) -> PDFDocument {
    let scale: CGFloat = 200 / 72, data = NSMutableData()
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    let pdf = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil)!
    for lines in pages {
        let scan = CGContext(data: nil, width: Int(box.width * scale), height: Int(box.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
                             space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        scan.setFillColor(gray: 1, alpha: 1)
        scan.fill(CGRect(x: 0, y: 0, width: scan.width, height: scan.height))
        scan.scaleBy(x: scale, y: scale)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: scan, flipped: false)
        for (row, line) in lines.enumerated() {
            NSAttributedString(string: line, attributes: [.font: NSFont(name: "Helvetica", size: 24)!])
                .draw(at: CGPoint(x: 72, y: box.height - 100 - CGFloat(row) * 50))
        }
        NSGraphicsContext.current = nil
        pdf.beginPDFPage(nil)
        pdf.draw(scan.makeImage()!, in: box)
        pdf.endPDFPage()
    }
    pdf.closePDF()
    return PDFDocument(data: data as Data)!
}

@MainActor
final class ToolsTests: XCTestCase {
    /// A page drawn again with lines of text, at their boxes as Vision gives them, holds those words where they show, and
    /// looks as it did, with its marks, turn and crop.
    func testRebuiltPageHasTheWordsWhereTheyShow() throws {
        let page = try XCTUnwrap(scannedPDF([["Invoice 2026-117", "Cement 50 bags"]]).page(at: 0)), look = ink(try XCTUnwrap(render(page, dpi: 72)))
        page.addAnnotation(shape(.rect, from: CGPoint(x: 400, y: 100), to: CGPoint(x: 450, y: 150), color: .red))
        page.rotation = 90
        page.setBounds(CGRect(x: 0, y: 50, width: 612, height: 742), for: .cropBox)
        // The second line's box, as a share of the page from the bottom left: its baseline is 642 points up, and Helvetica
        // 24 reaches 5 below it and 19 above.
        let font = NSFont(name: "Helvetica", size: 24)!, width = { (words: String) in NSAttributedString(string: words, attributes: [.font: font]).size().width }
        let line = CGRect(x: 72 / 612, y: 637 / 792, width: width("Cement 50 bags") / 612, height: 24 / 792)
        let new = try XCTUnwrap(rebuilt(page, text: [(text: "Cement 50 bags", box: line), (text: "水泥五十袋", box: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.03))]))
        let doc = PDFDocument()
        doc.insert(new, at: 0)
        let words = new.string ?? ""
        XCTAssertTrue(words.contains("Cement 50 bags"), words)
        XCTAssertTrue(words.contains("水泥五十袋"), words)
        let cement = try XCTUnwrap(doc.findString("Cement", withOptions: []).first).bounds(for: new)
        XCTAssertEqual(cement.minX, 72, accuracy: 3)
        XCTAssertEqual(cement.maxX, 72 + width("Cement"), accuracy: 3)
        XCTAssertEqual(cement.midY, 650, accuracy: 8)
        XCTAssertEqual(Double(ink(try XCTUnwrap(render(new, dpi: 72)))), Double(look), accuracy: Double(look) / 100)
        XCTAssertEqual(new.rotation, 90)
        XCTAssertEqual(new.bounds(for: .cropBox), CGRect(x: 0, y: 50, width: 612, height: 742))
        XCTAssertEqual(new.annotations.map(\.type), ["Square"])
    }

    /// Only the page's own drawing is read, not its marks, whether the page is a file's or one made from a photo; and a
    /// photo's page drawn again keeps its picture.
    func testRenderLeavesOutTheMarks() throws {
        let scan = try XCTUnwrap(scannedPDF([["Received with thanks"]]).page(at: 0))
        let photo = try XCTUnwrap(PDFPage(image: scan.thumbnail(of: CGSize(width: 612, height: 792), for: .mediaBox)))
        for page in [scan, photo] {
            let before = ink(try XCTUnwrap(render(page, dpi: 72)))
            XCTAssertGreaterThan(before, 100)
            page.addAnnotation(shape(.rect, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 500, y: 300), color: .black))
            XCTAssertEqual(ink(try XCTUnwrap(render(page, dpi: 72))), before)
        }
        let again = try XCTUnwrap(rebuilt(photo, text: [])), shown = Double(ink(try XCTUnwrap(render(photo, dpi: 72))))
        XCTAssertEqual(Double(ink(try XCTUnwrap(render(again, dpi: 72)))), shown, accuracy: shown / 100)
        // Turned, it's still read upright, all of it.
        photo.rotation = 90
        XCTAssertEqual(Double(ink(try XCTUnwrap(render(photo, dpi: 72)))), shown, accuracy: shown / 100)
    }

    func testRecognizeTextPutsTheWordsUnderTheScan() async throws {
        try await requireTextRecognition()
        let doc = FolioDocument(pdf: scannedPDF([["Invoice 2026-117", "Cement 50 bags"], ["Delivered to Lubumbashi"]])), undo = manualUndo(doc)
        let page = doc.pages[0]
        XCTAssertEqual(texts(doc.pdf), ["", ""])
        var heard: [Int] = []
        undo.beginUndoGrouping()
        let result = await doc.recognizeText { done, _ in heard.append(done) }
        undo.endUndoGrouping()
        XCTAssertEqual(result.read, 2)
        XCTAssertEqual(result.of, 2)
        XCTAssertEqual(heard, [0, 1])
        let words = texts(doc.pdf)
        for word in ["Invoice", "2026-117", "Cement", "bags"] { XCTAssertTrue(words[0].contains(word), words[0]) }
        XCTAssertTrue(words[1].contains("Lubumbashi"), words[1])
        // One step, which puts the old pages back.
        XCTAssertEqual(undo.undoActionName, "Recognize Text")
        undo.undo()
        XCTAssertTrue(doc.pages[0] === page)
        XCTAssertEqual(texts(doc.pdf), ["", ""])
    }

    func testRecognizeTextReadsFrenchAndChinese() async throws {
        try await requireTextRecognition()
        let doc = FolioDocument(pdf: scannedPDF([["Facture réglée à Kinshasa"], ["水泥五十袋已交付"]]))
        let result = await doc.recognizeText { _, _ in }
        XCTAssertEqual(result.read, 2)
        let words = texts(doc.pdf)
        XCTAssertTrue(words[0].contains("réglée"), words[0])
        XCTAssertTrue(words[1].contains("水泥"), words[1])
    }

    func testRecognizeTextLeavesPagesWithText() async {
        let doc = FolioDocument(pdf: makePDF([["Typed"]])), page = doc.pages[0]
        let result = await doc.recognizeText { _, _ in XCTFail("No page to read") }
        XCTAssertEqual(result.read, 0)
        XCTAssertEqual(result.of, 0)
        XCTAssertTrue(doc.pages[0] === page)
        XCTAssertEqual(doc.revision, 0)
    }

    /// A scan is the paper itself, so its page is its shape, the biggest that fits the paper, filled to the edges: a wide one
    /// lies on its side. It goes in after the page in view with its words under it, as one step, saying it read them, or
    /// for a document made for it in place of every page.
    func testScanGoesInFilledAndSearchable() async throws {
        try await requireTextRecognition()
        // A receipt three times as tall as it's wide, on grey paper.
        let scan = CGContext(data: nil, width: 800, height: 2400, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
                             bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        scan.setFillColor(gray: 0.85, alpha: 1)
        scan.fill(CGRect(x: 0, y: 0, width: 800, height: 2400))
        NSGraphicsContext.current = NSGraphicsContext(cgContext: scan, flipped: false)
        NSAttributedString(string: "Delivered to Lubumbashi", attributes: [.font: NSFont(name: "Helvetica", size: 56)!]).draw(at: CGPoint(x: 40, y: 2200))
        NSGraphicsContext.current = nil
        let receipt = try XCTUnwrap(FolioDocument.page(scanned: scan.makeImage()!, text: []))
        let paper = FolioDocument.paper, box = receipt.bounds(for: .mediaBox)
        XCTAssertEqual(box.height, paper.height, accuracy: 0.5)
        XCTAssertEqual(box.width, paper.height / 3, accuracy: 0.5)
        let shown = try XCTUnwrap(render(receipt, dpi: 72))
        XCTAssertEqual(count(shown, x: 0..<shown.width, y: 0..<3) { r, _, _ in r > 240 }, 0)
        let wide = CGContext(data: nil, width: 1600, height: 1000, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
                             bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        let card = try XCTUnwrap(FolioDocument.page(scanned: wide.makeImage()!, text: [])).bounds(for: .mediaBox)
        XCTAssertEqual(card.width, paper.height, accuracy: 0.5)
        XCTAssertEqual(card.height, paper.height / 1.6, accuracy: 0.5)

        let viewer = Viewer(doc: FolioDocument(pdf: makePDF([["A"], ["B"]]))), undo = manualUndo(viewer.doc)
        viewer.canvas.document = viewer.doc.pdf
        undo.beginUndoGrouping()
        await viewer.insertScanned([receipt])
        undo.endUndoGrouping()
        XCTAssertNil(viewer.busy)
        let words = texts(viewer.doc.pdf)
        XCTAssertEqual(words.count, 3)
        XCTAssertTrue(words[1].contains("Lubumbashi"), words[1])
        XCTAssertEqual(viewer.doc.pages[1].bounds(for: .mediaBox), box)
        XCTAssertEqual(viewer.message, "Recognized the text on 1 page")
        XCTAssertEqual(undo.undoActionName, "Insert Pages")
        undo.undo()
        XCTAssertEqual(texts(viewer.doc.pdf), ["A", "B"])

        let made = Viewer(doc: FolioDocument()), madeUndo = manualUndo(made.doc)
        madeUndo.beginUndoGrouping()
        await made.insertScanned([receipt], replacingAll: true)
        madeUndo.endUndoGrouping()
        XCTAssertEqual(made.doc.pdf.pageCount, 1)
        XCTAssertTrue(texts(made.doc.pdf)[0].contains("Lubumbashi"))
        XCTAssertEqual(madeUndo.undoActionName, "Scan Document")
    }

    /// The scanner finds the page in a photo taken at a slant, in shadow at one side, and makes it a page of its own
    /// shape: white paper, dark print, the signature still blue and a black box still black; or in black and white; or as
    /// the camera saw it. Turned, it lies on its side, and the page made of it can be searched.
    func testScannerStraightensAndCleansUpThePage() async throws {
        let (photo, corners) = photoOfAPage()
        try requireDocumentDetection(photo)
        let shot = ScanShot(photo: photo)
        for (found, real) in zip(shot.corners, corners) {
            XCTAssertLessThan(hypot(found.x - real.x, found.y - real.y), 40, "found \(found), at \(real)")
        }
        let colour = try rendered(shot, .colour)
        XCTAssertEqual(CGFloat(colour.width) / CGFloat(colour.height), 210 / 297, accuracy: 0.015)
        // Blank paper in the shadow is white, the print dark, the signature blue and the box black.
        let margin = (x: 0.01..<0.06, y: 0.15..<0.7), print = (x: 0.08..<0.6, y: 0.14..<0.6)
        XCTAssertEqual(count(colour, margin) { r, g, b in min(r, g, b) < 235 }, 0)
        XCTAssertGreaterThan(count(colour, print) { r, g, b in max(r, g, b) < 90 }, area(colour, print) / 50)
        XCTAssertGreaterThan(count(colour, (x: 0.08..<0.4, y: 0.655..<0.668)) { r, _, b in Int(b) > Int(r) + 80 }, 500)
        let box = (x: 0.6..<0.85, y: 0.74..<0.86)
        XCTAssertGreaterThan(count(colour, box) { r, g, b in max(r, g, b) < 110 }, area(colour, box) * 9 / 10)
        // A hand's hard shadow over the right of the page, cutting the light there to 0.4, leaves the paper white too, and
        // its edge, across blank paper, no dark stripe in black and white. It's straightened at the corners found without
        // it: Vision takes so sharp and straight a shadow's edge for the paper's.
        let dim = CIColor(red: 0.4, green: 0.4, blue: 0.4, colorSpace: CGColorSpace(name: CGColorSpace.linearSRGB)!)!
        let shadow = CIImage(color: dim).cropped(to: CGRect(x: 1700, y: 0, width: 1324, height: 4032))
            .composited(over: CIImage(color: .white)).applyingGaussianBlur(sigma: 6)
        var shaded = ScanShot(photo: photo.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: shadow]).cropped(to: photo.extent))
        shaded.corners = shot.corners
        XCTAssertEqual(count(try rendered(shaded, .colour), (x: 0.75..<0.97, y: 0.15..<0.6)) { r, g, b in min(r, g, b) < 235 }, 0)
        XCTAssertEqual(count(try rendered(shaded, .blackAndWhite), (x: 0.45..<0.97, y: 0.625..<0.645)) { r, _, _ in r < 160 }, 0)

        let black = try rendered(shot, .blackAndWhite)
        XCTAssertGreaterThan(count(black, print) { r, _, _ in r < 40 || r > 215 }, area(black, print) * 9 / 10)
        XCTAssertEqual(count(black, (x: 0.08..<0.4, y: 0.655..<0.668)) { r, g, b in r != g || g != b }, 0)
        let seen = try rendered(shot, .photo)
        XCTAssertGreaterThan(count(seen, margin) { r, g, b in max(r, g, b) < 225 }, area(seen, margin) / 2)

        var turned = shot
        turned.turns = 1
        let side = try rendered(turned, .colour)
        XCTAssertEqual(CGFloat(side.width) / CGFloat(side.height), 297 / 210, accuracy: 0.03)
        // The heading, at the top left, is at the top right.
        XCTAssertGreaterThan(count(side, (x: 0.9..<0.945, y: 0.08..<0.45)) { r, g, b in max(r, g, b) < 90 }, 1000)

        let made = await shot.made(.colour)
        let page = try XCTUnwrap(made?.page).bounds(for: .mediaBox)
        XCTAssertEqual(page.width / page.height, 210 / 297, accuracy: 0.015)
        if (try? await recognize(colour)) != nil { XCTAssertTrue(made?.page.string?.contains("INVOICE 2041") == true, made?.page.string ?? "") }
    }

    /// The scanner takes the paper once it's held still for a moment, and not again until it moves to another page or out
    /// of view.
    func testScannerTakesThePaperHeldStill() {
        var steadiness = Steadiness()
        let start = Date.now
        let at = { (seconds: TimeInterval) in start + seconds }
        let paper = [CGPoint(x: 0.2, y: 0.8), CGPoint(x: 0.8, y: 0.8), CGPoint(x: 0.8, y: 0.2), CGPoint(x: 0.2, y: 0.2)]
        let moved = { (by: CGFloat) in paper.map { CGPoint(x: $0.x + by, y: $0.y) } }
        XCTAssertFalse(steadiness.see(nil, at: at(0)))
        XCTAssertFalse(steadiness.see(paper, at: at(0.1)))
        XCTAssertFalse(steadiness.see(moved(0.01), at: at(0.5)))
        // Moving starts the wait again.
        XCTAssertFalse(steadiness.see(moved(0.05), at: at(0.7)))
        XCTAssertFalse(steadiness.see(moved(0.05), at: at(1.4)))
        XCTAssertTrue(steadiness.see(moved(0.055), at: at(1.6)))
        // The same page isn't taken again, however long it's held.
        XCTAssertFalse(steadiness.see(moved(0.06), at: at(2.5)))
        XCTAssertFalse(steadiness.see(moved(0.06), at: at(3.5)))
        // Out of view and back, it is.
        XCTAssertFalse(steadiness.see(nil, at: at(3.6)))
        XCTAssertFalse(steadiness.see(moved(0.06), at: at(3.7)))
        XCTAssertTrue(steadiness.see(moved(0.06), at: at(4.6)))
        // Moved on to another page, too.
        XCTAssertFalse(steadiness.see(moved(0.3), at: at(4.7)))
        XCTAssertTrue(steadiness.see(moved(0.3), at: at(5.6)))
    }

    /// The scan's picture in this look, rendered.
    private func rendered(_ shot: ScanShot, _ look: ScanLook) throws -> CGImage {
        let image = shot.picture(look)
        return try XCTUnwrap(ScanShot.context.createCGImage(image, from: image.extent))
    }

    /// A phone's photo of an A4 page on a desk, 3024 by 4032, tilted back 25° and turned 10° as by a camera at the
    /// main lens's focal length, lit from the bottom right, a little soft and grainy; and where the page's top left, top
    /// right, bottom right and bottom left corners are in it, from its bottom left. The page has a heading, lines of print,
    /// a blue signature and a black box.
    private func photoOfAPage() -> (CIImage, [CGPoint]) {
        let page = NSImage(size: NSSize(width: 1240, height: 1754), flipped: true) { rect in
            NSColor.white.setFill()
            rect.fill()
            NSAttributedString(string: "INVOICE 2041", attributes: [.font: NSFont.boldSystemFont(ofSize: 64)]).draw(at: CGPoint(x: 100, y: 100))
            for row in 0..<20 {
                NSAttributedString(string: "Lubumbashi harvest report, line \(row): maize delivered on time.", attributes: [.font: NSFont.systemFont(ofSize: 26)])
                    .draw(at: CGPoint(x: 100, y: 240 + CGFloat(row) * 42))
            }
            NSColor(red: 0.1, green: 0.25, blue: 0.8, alpha: 1).setFill()
            NSRect(x: 100, y: 1150, width: 400, height: 20).fill()
            NSColor.black.setFill()
            NSRect(x: 700, y: 1250, width: 400, height: 300).fill()
            return true
        }
        // The page's corners, in millimetres from its centre, tilted and turned, 330 from the lens, and seen through it.
        let (tilt, turn, focal, centre) = (25 * Double.pi / 180, 10 * Double.pi / 180, 0.72 * 4032, CGPoint(x: 1512, y: 2016))
        let corners = [(-105.0, 148.5), (105.0, 148.5), (105.0, -148.5), (-105.0, -148.5)].map { x, y in
            let (x1, z1) = (x * cos(turn), -x * sin(turn))
            let (y2, z2) = (y * cos(tilt) - z1 * sin(tilt), y * sin(tilt) + z1 * cos(tilt))
            return CGPoint(x: centre.x + focal * x1 / (330 + z2), y: centre.y + focal * y2 / (330 + z2))
        }
        let box = CGRect(x: 0, y: 0, width: 3024, height: 4032)
        let flat = CIImage(cgImage: page.cgImage(forProposedRect: nil, context: nil, hints: nil)!)
        let seen = flat.applyingFilter("CIPerspectiveTransform", parameters: ["inputTopLeft": CIVector(cgPoint: corners[0]), "inputTopRight": CIVector(cgPoint: corners[1]),
                                                                              "inputBottomRight": CIVector(cgPoint: corners[2]), "inputBottomLeft": CIVector(cgPoint: corners[3])])
        let light = CIFilter(name: "CILinearGradient", parameters: ["inputPoint0": CIVector(x: 0, y: 4032), "inputColor0": CIColor(red: 0.55, green: 0.52, blue: 0.45),
                                                                    "inputPoint1": CIVector(x: 3024, y: 0), "inputColor1": CIColor(red: 1, green: 0.97, blue: 0.9)])!.outputImage!
        let grain = CIFilter(name: "CIRandomGenerator")!.outputImage!.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0.04, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 0.04, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0.04, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: -0.02, y: -0.02, z: -0.02, w: 0)])
        let photo = seen.composited(over: CIImage(color: CIColor(red: 0.36, green: 0.25, blue: 0.16)))
            .applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: light])
            .applyingGaussianBlur(sigma: 1.5)
            .applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: grain])
            .cropped(to: box)
        // Kept as a photo is, so it's taken once, not again for each look.
        return (CIImage(cgImage: ScanShot.context.createCGImage(photo, from: box)!), corners)
    }

    /// Skips where Vision's model for finding a page doesn't run, as on GitHub's virtual Macs.
    private func requireDocumentDetection(_ photo: CIImage) throws {
        let runs = (try? VNImageRequestHandler(ciImage: photo).perform([VNDetectDocumentSegmentationRequest()])) != nil
        try XCTSkipUnless(runs, "Vision's model for finding a page doesn't run on this Mac, as on GitHub's virtual ones")
    }

    /// How many of the picture's pixels are of this kind, in these shares of its width and height from its top left.
    private func count(_ image: CGImage, _ part: (x: Range<Double>, y: Range<Double>), where kind: (UInt8, UInt8, UInt8) -> Bool) -> Int {
        let (x, y) = pixels(image, part)
        return count(image, x: x, y: y, where: kind)
    }

    private func area(_ image: CGImage, _ part: (x: Range<Double>, y: Range<Double>)) -> Int {
        let (x, y) = pixels(image, part)
        return x.count * y.count
    }

    private func pixels(_ image: CGImage, _ part: (x: Range<Double>, y: Range<Double>)) -> (Range<Int>, Range<Int>) {
        let (w, h) = (Double(image.width), Double(image.height))
        return (Int(part.x.lowerBound * w)..<Int(part.x.upperBound * w), Int(part.y.lowerBound * h)..<Int(part.y.upperBound * h))
    }

    /// Skips where Vision's accurate model doesn't run, as on GitHub's virtual Macs.
    private func requireTextRecognition() async throws {
        let blank = try XCTUnwrap(render(FolioDocument.blankPage(), dpi: 72))
        let runs = (try? await recognize(blank)) != nil
        try XCTSkipUnless(runs, "Text recognition's model doesn't run on this Mac, as on GitHub's virtual ones")
    }

    /// A file of photos, as read from a file, shrinks.
    func testReduceFileSizeShrinksPhotosAndKeepsTheMarks() async throws {
        let doc = FolioDocument(pdf: PDFDocument(data: photoPDF().dataRepresentation()!)!), undo = manualUndo(doc), original = doc.pdf
        doc.pages[0].addAnnotation(shape(.rect, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 200, y: 200), color: .red))
        undo.beginUndoGrouping()
        let reduced = await doc.reduceFileSize()
        undo.endUndoGrouping()
        let sizes = try XCTUnwrap(reduced)
        print("Reduce File Size: \(sizes.before) → \(sizes.after)")
        XCTAssertLessThan(sizes.after, sizes.before / 2)
        // Saved, it stays that small, and keeps its marks.
        let saved = try doc.snapshot(contentType: .pdf)
        XCTAssertLessThan(saved.count, sizes.before / 2)
        XCTAssertEqual(PDFDocument(data: saved)!.page(at: 0)!.annotations.map(\.type), ["Square"])
        XCTAssertEqual(undo.undoActionName, "Reduce File Size")
        undo.undo()
        XCTAssertTrue(doc.pdf === original)
        // A file of text, already small, is left as it is.
        let text = FolioDocument(pdf: makePDF([["Words"]])), pdf = text.pdf
        let unchanged = await text.reduceFileSize()
        XCTAssertNil(unchanged)
        XCTAssertTrue(text.pdf === pdf)
        XCTAssertEqual(text.revision, 0)
    }

    func testReduceFileSizeNeverDropsThePassword() async throws {
        let data = photoPDF().dataRepresentation(options: [PDFDocumentWriteOption.userPasswordOption: "pw", .ownerPasswordOption: "pw"])!
        let doc = FolioDocument(pdf: PDFDocument(data: data)!)
        XCTAssertTrue(doc.unlock("pw"))
        let sizes = await doc.reduceFileSize()
        print("Reduce File Size, encrypted: \(sizes.map { "\($0.before) → \($0.after)" } ?? "left as it was")")
        XCTAssertTrue(PDFDocument(data: try doc.snapshot(contentType: .pdf))!.isEncrypted)
    }

    /// A page sent as a picture is as it shows: cropped, turned and marked, at two pixels a point.
    /// Applying redactions leaves no trace of the words under the marks, in the window or the saved file, and blacks them
    /// out. It keeps the rest, drops marks that overlap a redaction, keeps the page's turn, and undoes.
    func testApplyRedactionsTakesOutWhatsUnderTheMarks() async throws {
        // As some files have it: the page's box away from the origin, and cropped.
        let file = makePDF([["Delivery note 2026-41", "Bank account 99-1234"], ["Page two"]])
        file.page(at: 0)!.setBounds(CGRect(x: -100, y: -50, width: 712, height: 842), for: .mediaBox)
        file.page(at: 0)!.setBounds(CGRect(x: 0, y: 0, width: 612, height: 792), for: .cropBox)
        let doc = FolioDocument(pdf: try XCTUnwrap(file.dataRepresentation().flatMap(PDFDocument.init(data:)))), undo = manualUndo(doc)
        let page = doc.pages[0], secret = try XCTUnwrap(doc.pdf.findString("Bank account 99-1234", withOptions: []).first).bounds(for: page)
        let kept = try XCTUnwrap(doc.pdf.findString("Delivery note 2026-41", withOptions: []).first).bounds(for: page)
        let mark = secret.insetBy(dx: -2, dy: -2)
        page.addAnnotation(shape(.redact, from: mark.origin, to: CGPoint(x: mark.maxX, y: mark.maxY), color: .red))
        page.addAnnotation(shape(.rect, from: secret.origin, to: CGPoint(x: secret.minX + 20, y: secret.minY + 5), color: .blue))   // overlaps: goes
        page.addAnnotation(shape(.rect, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 30, y: 30), color: .blue))   // clear: stays
        page.rotation = 90
        undo.beginUndoGrouping()
        let redacted = await doc.applyRedactions()
        undo.endUndoGrouping()
        XCTAssertEqual(redacted, 1)
        let saved = try XCTUnwrap(PDFDocument(data: try XCTUnwrap(doc.pdf.dataRepresentation())))
        for pdf in [doc.pdf, saved] {
            XCTAssertTrue(pdf.findString("99-1234", withOptions: []).isEmpty)
            XCTAssertTrue(pdf.findString("Bank", withOptions: []).isEmpty)
            XCTAssertEqual(pdf.findString("Page two", withOptions: []).count, 1)
        }
        XCTAssertFalse(doc.hasRedactions)
        XCTAssertEqual(doc.pages[0].annotations.count, 1)
        XCTAssertEqual(doc.pages[0].rotation, 90)
        // The words' box is black: the picture is of the page's box, its rows running down from the top.
        let image = try XCTUnwrap(render(doc.pages[0], dpi: 72)), box = doc.pages[0].bounds(for: .mediaBox)
        // Its size: macOS 26 moves the box to the origin as it saves, and the page's content with it.
        XCTAssertEqual(box.size, CGSize(width: 712, height: 842))
        let x = Int(secret.minX - box.minX) + 2..<Int(secret.maxX - box.minX) - 2, y = Int(box.maxY - secret.maxY) + 2..<Int(box.maxY - secret.minY) - 2
        XCTAssertGreaterThan(Double(count(image, x: x, y: y) { $0 < 64 && $1 < 64 && $2 < 64 }), 0.98 * Double(x.count * y.count))
        // And the words left show.
        let keptX = Int(kept.minX - box.minX)..<Int(kept.maxX - box.minX), keptY = Int(box.maxY - kept.maxY)..<Int(box.maxY - kept.minY)
        XCTAssertGreaterThan(Double(count(image, x: keptX, y: keptY) { $0 < 128 && $1 < 128 && $2 < 128 }), 0.05 * Double(keptX.count * keptY.count))
        undo.undo()
        XCTAssertEqual(doc.pdf.findString("99-1234", withOptions: []).count, 1)
        XCTAssertTrue(doc.hasRedactions)
    }

    /// A bookmark to a redacted page goes to the page that replaces it, and back with undo.
    func testBookmarkFollowsItsRedactedPage() async throws {
        let doc = FolioDocument(pdf: try XCTUnwrap(PDFDocument(data: outlinedPDF()))), undo = manualUndo(doc)
        let page = doc.pages[1]
        page.addAnnotation(shape(.redact, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 200, y: 150), color: .red))
        undo.beginUndoGrouping()
        let redacted = await doc.applyRedactions()
        undo.endUndoGrouping()
        XCTAssertEqual(redacted, 1)
        XCTAssertIdentical(doc.pdf.outlineRoot?.child(at: 0)?.destination?.page, doc.pages[1])
        let saved = try XCTUnwrap(PDFDocument(data: try doc.snapshot(contentType: .pdf)))
        XCTAssertEqual(saved.outlineRoot?.child(at: 0)?.destination?.page.map(saved.index(for:)), 1)
        undo.undo()
        XCTAssertIdentical(doc.pdf.outlineRoot?.child(at: 0)?.destination?.page, page)
    }

    /// A redacted page is kept as a JPEG: drawn as it is, a page-sized photo would weigh over 20 MB.
    func testRedactedPhotoStaysAJPEG() async throws {
        let doc = FolioDocument(pdf: photoPDF())
        doc.pages[0].addAnnotation(shape(.redact, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 200, y: 150), color: .red))
        let redacted = await doc.applyRedactions()
        XCTAssertEqual(redacted, 1)
        XCTAssertLessThan(try XCTUnwrap(doc.pdf.dataRepresentation()).count, 10_000_000)
    }

    func testPictureOfAPageIsAsItShows() throws {
        let page = try XCTUnwrap(makePDF([["Top line"]]).page(at: 0))
        page.setBounds(CGRect(x: 0, y: 392, width: 612, height: 400), for: .cropBox)
        page.rotation = 90
        page.addAnnotation(shape(.rect, from: CGPoint(x: 400, y: 500), to: CGPoint(x: 500, y: 600), color: .red))
        let image = try XCTUnwrap(picture(of: page).flatMap { CGImageSourceCreateWithData($0 as CFData, nil) }.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        // Turned a quarter clockwise, the crop's 612 by 400 points show 400 wide and 612 tall.
        XCTAssertEqual([image.width, image.height], [800, 1224])
        // So the line at the crop's top left runs down its top right, the box is a little left of the middle, 400 points
        // down, and the crop's bottom left is blank paper.
        XCTAssertGreaterThan(count(image, x: 630..<700, y: 130..<300) { r, g, b in r < 100 && g < 100 && b < 100 }, 50)
        XCTAssertGreaterThan(count(image, x: 200..<430, y: 790..<1010) { r, g, b in r > 150 && g < 100 && b < 100 }, 100)
        XCTAssertEqual(count(image, x: 0..<200, y: 0..<700) { r, g, _ in r < 200 || g < 200 }, 0)
    }

    /// How many of the picture's pixels, in these columns and rows from the top left, are of this kind.
    private func count(_ image: CGImage, x: Range<Int>, y: Range<Int>, where kind: (UInt8, UInt8, UInt8) -> Bool) -> Int {
        let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
        return y.flatMap { row in x.map { col in bytes + (row * image.width + col) * 4 } }.filter { kind($0[0], $0[1], $0[2]) }.count
    }

    /// A page holding a 3840 by 2160 photo.
    private func photoPDF() -> PDFDocument {
        let pdf = PDFDocument()
        pdf.insert(FolioDocument.pages(from: [URL(fileURLWithPath: "/System/Library/Wallpapers/.default/DefaultAerial.jpg")])[0], at: 0)
        return pdf
    }

    /// How many of the picture's pixels are dark.
    private func ink(_ picture: CGImage) -> Int {
        count(picture, x: 0..<picture.width, y: 0..<picture.height) { Int($0) + Int($1) + Int($2) < 3 * 128 }
    }
}
