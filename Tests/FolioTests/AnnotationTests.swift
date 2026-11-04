import PDFKit
import XCTest
@testable import Folio

final class AnnotationTests: XCTestCase {
    func testMarkupsCoverEachLine() {
        let pdf = makePDF([["First line here", "Second line here"]]), page = pdf.page(at: 0)!
        let marks = markups(page.selection(for: page.bounds(for: .mediaBox))!, type: .highlight, color: .yellow)
        XCTAssertEqual(marks.count, 2)
        XCTAssertEqual(marks.map { $0.annotation.type }, ["Highlight", "Highlight"])
        // Other apps read the quadrilateral from the file.
        let b = marks[0].annotation.bounds
        page.addAnnotation(marks[0].annotation)
        let saved = PDFDocument(data: pdf.dataRepresentation()!)!.page(at: 0)!.annotations[0]
        let points = saved.quadrilateralPoints?.map(\.pointValue) ?? []
        XCTAssertEqual(points.count, 4)
        for (p, q) in zip(points, [CGPoint(x: 0, y: b.height), CGPoint(x: b.width, y: b.height), .zero, CGPoint(x: b.width, y: 0)]) {
            XCTAssertEqual(hypot(p.x - q.x, p.y - q.y), 0, accuracy: 0.01)   // the file keeps four decimals
        }
    }

    func testShapes() {
        XCTAssertEqual(shape(.rect, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 110, y: 60), color: .red).bounds,
                       CGRect(x: 10, y: 10, width: 100, height: 50))
        let arrow = shape(.arrow, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 10, y: 10), color: .red)
        XCTAssertEqual(arrow.type, "Line")
        XCTAssertEqual(arrow.endLineStyle, .openArrow)
        XCTAssertEqual(CGPoint(x: arrow.startPoint.x + arrow.bounds.minX, y: arrow.startPoint.y + arrow.bounds.minY), CGPoint(x: 100, y: 100))
        let redaction = shape(.redact, from: .zero, to: CGPoint(x: 50, y: 50), color: .red)
        XCTAssertTrue(redaction.isRedaction)
        XCTAssertFalse(redaction.isComment)
    }

    func testInkKeepsEveryStroke() {
        let a = ink([[CGPoint(x: 10, y: 10), CGPoint(x: 50, y: 40)], [CGPoint(x: 60, y: 10), CGPoint(x: 70, y: 20)]], color: .blue, width: 2)
        XCTAssertEqual(a.type, "Ink")
        XCTAssertEqual(a.paths?.count, 2)
        XCTAssertTrue(a.bounds.contains(CGPoint(x: 10, y: 10)) && a.bounds.contains(CGPoint(x: 70, y: 40)))
    }

    func testCoverLineMatchesWordsAndSize() {
        let page = makePDF([["Total due: R 1 250,00"]]).page(at: 0)!
        let cover = coverLine(at: CGPoint(x: 90, y: 725), on: page)!
        XCTAssertEqual(cover.type, "FreeText")
        XCTAssertEqual(cover.contents, "Total due: R 1 250,00")
        XCTAssertEqual(cover.font?.pointSize, 18)
        XCTAssertEqual(cover.color, .white)
        XCTAssertTrue(cover.bounds.contains(page.selectionForLine(at: CGPoint(x: 90, y: 725))!.bounds(for: page)))
        XCTAssertNil(coverLine(at: CGPoint(x: 300, y: 300), on: page))
    }

    func testTextBoxSitsOnTheLineItIsBeside() {
        let page = makePDF([["Name:"]]).page(at: 0)!, line = page.selectionForLine(at: CGPoint(x: 90, y: 725))!.bounds(for: page)
        let box = textBox(at: CGPoint(x: 300, y: 725), on: page), font = box.font!
        XCTAssertEqual(box.type, "FreeText")
        XCTAssertEqual([font.fontName, "\(font.pointSize)"], ["Georgia", "18.0"])
        XCTAssertEqual(rgb(box.fontColor), [0, 0, 0])
        XCTAssertEqual(box.bounds.minY, line.minY - 2, accuracy: 0.01)
        XCTAssertEqual(box.bounds.height, font.ascender - font.descender + 5.5, accuracy: 0.01)
        XCTAssertEqual(box.bounds.minX, 298)
        XCTAssertEqual(box.contents ?? "", "")
    }

    func testTextBoxTakesTheNearestRunAndItsColour() {
        let page = makePDF(styled: [[NSAttributedString(string: "Heading", attributes: [.font: NSFont(name: "Georgia", size: 18)!]),
                                     NSAttributedString(string: "Small print", attributes: [.font: NSFont(name: "Helvetica-Bold", size: 11)!, .foregroundColor: NSColor.red])]]).page(at: 0)!
        // Far to the right of the small print, at its height: the heading is nearer, but the box goes on this line.
        let small = textBox(at: CGPoint(x: 300, y: 682), on: page)
        XCTAssertEqual([small.font!.fontName, "\(small.font!.pointSize)"], ["Helvetica-Bold", "11.0"])
        XCTAssertEqual(rgb(small.fontColor), [1, 0, 0])
        XCTAssertEqual(textBox(at: CGPoint(x: 300, y: 728), on: page).font?.fontName, "Georgia")
        // Between the lines, nearer the small print's top (y 691) than the heading's foot (y 720).
        XCTAssertEqual(textBox(at: CGPoint(x: 100, y: 703), on: page).font?.fontName, "Helvetica-Bold")
    }

    func testTextBoxTakesTheRunNearestTheClickWithinALine() {
        let line = NSMutableAttributedString(string: "Total due: ", attributes: [.font: NSFont(name: "Georgia", size: 14)!])
        line.append(NSAttributedString(string: "R 1 250,00", attributes: [.font: NSFont(name: "Helvetica-Bold", size: 14)!]))
        let page = makePDF(styled: [[line]]).page(at: 0)!
        XCTAssertEqual(textBox(at: CGPoint(x: 400, y: 725), on: page).font?.fontName, "Helvetica-Bold")
        XCTAssertEqual(textBox(at: CGPoint(x: 60, y: 725), on: page).font?.fontName, "Georgia")
    }

    func testTextBoxWordsSitOnTheLinesBaseline() {
        let page = makePDF([["Name:"]]).page(at: 0)!, box = textBox(at: CGPoint(x: 300, y: 725), on: page)
        box.contents = "HHHH"
        box.bounds = fit(box.bounds, around: "HHHH", in: box.font!)
        page.addAnnotation(box)
        // Neither "Name:" nor "HHHH" reaches below the baseline.
        XCTAssertEqual(inkBottom(page, in: CGRect(x: 290, y: 700, width: 150, height: 60)),
                       inkBottom(page, in: CGRect(x: 60, y: 700, width: 150, height: 60)), accuracy: 0.5)
    }

    func testTextBoxOnAPageWithNoText() {
        let box = textBox(at: CGPoint(x: 100, y: 100), on: makePDF([[]]).page(at: 0)!)
        XCTAssertEqual([box.font!.fontName, "\(box.font!.pointSize)"], ["Helvetica", "12.0"])
        XCTAssertEqual(rgb(box.fontColor), [0, 0, 0])
        XCTAssertEqual(box.bounds.midY, 100, accuracy: 0.01)
    }

    /// A colour's red, green and blue, rounded to tenths, in Generic RGB: PDFKit keeps an annotation's colour as bare
    /// components and hands them back in that space.
    private func rgb(_ color: NSColor?) -> [Double] {
        let c = color!.usingColorSpace(.genericRGB)!
        return [c.redComponent, c.greenComponent, c.blueComponent].map { (Double($0) * 10).rounded() / 10 }
    }

    func testFitOnlyGrowsFromTheTopLeft() {
        let bounds = CGRect(x: 10, y: 100, width: 300, height: 40), font = NSFont(name: "Helvetica", size: 12)!
        XCTAssertEqual(fit(bounds, around: "Hi", in: font), bounds)
        let long = fit(bounds, around: "A line of words far longer than three hundred points of page can hold", in: font)
        XCTAssertGreaterThan(long.width, 300)
        XCTAssertEqual(long.minX, 10)
        XCTAssertEqual(long.maxY, 140)
    }

    func testSetFontIsOneUndoableChange() {
        let doc = FolioDocument(pdf: makePDF([[]])), undo = manualUndo(doc)
        let box = textBox(at: CGPoint(x: 100, y: 100), on: doc.pages[0]), old = box.bounds
        box.contents = "Hello"
        act(undo) { doc.setFont(NSFont(name: "Helvetica", size: 30)!, of: box) }
        XCTAssertEqual(box.font?.pointSize, 30)
        XCTAssertGreaterThan(box.bounds.height, old.height)
        XCTAssertEqual(box.bounds.maxY, old.maxY, accuracy: 0.01)
        XCTAssertEqual(undo.undoActionName, "Change Font")
        undo.undo()
        XCTAssertEqual(box.font?.pointSize, 12)
        XCTAssertEqual(box.bounds, old)
    }

    func testSignatures() {
        let rect = CGRect(x: 0, y: 0, width: 200, height: 100)
        // Each fills the box one way and sits in its middle, keeping its shape: a stamp, not a text box or a comment.
        for signature in [Signature.drawn([[CGPoint(x: 0, y: 0), CGPoint(x: 40, y: 10)], [CGPoint(x: 20, y: 30)]]), .typed("Jo Hamze"), .typed("JH")] {
            let a = signature.annotation(in: rect)
            XCTAssertEqual(a.type, "Stamp")
            XCTAssertEqual(max(a.bounds.width / rect.width, a.bounds.height / rect.height), 1, accuracy: 0.001)
            XCTAssertEqual(a.bounds.midX, rect.midX, accuracy: 0.01)
            XCTAssertEqual(a.bounds.midY, rect.midY, accuracy: 0.01)
        }
        Signature[.sign] = .typed("X")
        Signature[.initial] = .typed("Y")
        XCTAssertEqual(Signature[.sign], .typed("X"))
        XCTAssertEqual(Signature[.initial], .typed("Y"))
        Signature[.sign] = nil
        Signature[.initial] = nil
        XCTAssertNil(Signature[.sign])
        XCTAssertNil(Signature[.initial])
    }

    func testSignatureIsOnePictureAtAnySizeAndInTheFile() {
        let doc = FolioDocument(pdf: makePDF([[]])), page = doc.pages[0]
        let scribble = Signature.drawn([(0..<40).map { CGPoint(x: Double($0) * 9, y: $0 % 2 == 0 ? 0 : 60 + Double($0)) }])
        let small = CGRect(x: 50, y: 600, width: 100, height: 40), large = CGRect(x: 50, y: 200, width: 300, height: 120)
        for rect in [small, large] { page.addAnnotation(scribble.annotation(in: rect)) }
        // Three times the size holds nine times the ink: its lines grow with it.
        XCTAssertEqual(Double(darkPixels(page, in: large)) / Double(darkPixels(page, in: small)), 9, accuracy: 0.5)
        // It is drawn into the saved file, and into the pages Extract and Split copy.
        let saved = PDFDocument(data: try! doc.snapshot(contentType: .pdf))!.page(at: 0)!
        XCTAssertEqual(Double(darkPixels(saved, in: large)), Double(darkPixels(page, in: large)), accuracy: 50)
        XCTAssertEqual(darkPixels(doc.extract([page]).page(at: 0)!, in: large), darkPixels(page, in: large))
    }

    func testStampLiftsOffItsPaper() throws {
        let picture = try XCTUnwrap(Signature.lifted(from: stampPhoto()).flatMap(Signature.picture))
        // Cropped to the ring, 212 pixels across, with two to spare each side.
        XCTAssertEqual(Double(picture.width), 216, accuracy: 4)
        XCTAssertEqual(Double(picture.height), 216, accuracy: 4)
        // The paper inside and around it is clear, and its line solid and as blue as the ink.
        let pixels = rgba(picture), at = { (x: Int, y: Int) in pixels[(y * picture.width + x) * 4..<(y * picture.width + x) * 4 + 4].map { $0 } }
        XCTAssertEqual(at(picture.width / 2, picture.height / 2)[3], 0)
        XCTAssertEqual(at(0, 0)[3], 0)
        let line = at(8, picture.height / 2)
        XCTAssertEqual(line[3], 255)
        XCTAssertGreaterThan(line[2], 200)
        XCTAssertLessThan(line[0], 60)
        // Plain paper, or a file that isn't a picture, has no ink.
        XCTAssertNil(Signature.lifted(from: stampPhoto(ring: false)))
        XCTAssertNil(Signature.lifted(from: Data("not a picture".utf8)))
    }

    /// The saved stamp and its picture are decoded once while they stay the same, as through a drag, and afresh once changed.
    func testSignatureIsReadAfreshOnceChanged() throws {
        let saved = Signature[.stamp]
        defer { Signature[.stamp] = saved }
        let png = try XCTUnwrap(Signature.lifted(from: stampPhoto()))
        Signature[.stamp] = .typed("ACME")
        XCTAssertEqual(Signature[.stamp], .typed("ACME"))
        Signature[.stamp] = .image(png)
        XCTAssertEqual(Signature[.stamp], .image(png))
        Signature[.stamp] = nil
        XCTAssertNil(Signature[.stamp])
        let picture = try XCTUnwrap(Signature.picture(png))
        XCTAssertTrue(Signature.picture(png) === picture)
        XCTAssertNil(Signature.picture(Data("not a picture".utf8)))
        XCTAssertEqual(Signature.picture(png)?.width, picture.width)
    }

    /// The picture's pixels as red, green, blue and alpha, premultiplied, row by row from the top.
    private func rgba(_ picture: CGImage) -> [UInt8] {
        let context = CGContext(data: nil, width: picture.width, height: picture.height, bitsPerComponent: 8, bytesPerRow: picture.width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(picture, in: CGRect(x: 0, y: 0, width: picture.width, height: picture.height))
        return Array(UnsafeBufferPointer(start: context.data!.assumingMemoryBound(to: UInt8.self), count: picture.width * picture.height * 4))
    }

    func testPictureStampKeepsItsShapeAndIsInTheFile() throws {
        let png = try XCTUnwrap(Signature.lifted(from: stampPhoto()))
        let doc = FolioDocument(pdf: makePDF([[]])), page = doc.pages[0]
        let stamp = Signature.image(png).annotation(in: CGRect(x: 100, y: 300, width: 300, height: 100))
        // Round, as the ring is, as tall as the box, in its middle.
        XCTAssertEqual(stamp.type, "Stamp")
        XCTAssertEqual(stamp.bounds.height, 100, accuracy: 0.01)
        XCTAssertEqual(stamp.bounds.width, 100, accuracy: 2)
        XCTAssertEqual(stamp.bounds.midX, 250, accuracy: 0.01)
        XCTAssertEqual(stamp.bounds.midY, 350, accuracy: 0.01)
        page.addAnnotation(stamp)
        let shown = darkPixels(page, in: stamp.bounds)
        XCTAssertGreaterThan(shown, 5000)
        // It is drawn into the saved file, and into the pages Extract and Split copy.
        let saved = PDFDocument(data: try doc.snapshot(contentType: .pdf))!.page(at: 0)!
        XCTAssertEqual(Double(darkPixels(saved, in: stamp.bounds)), Double(shown), accuracy: Double(shown) / 20)
        XCTAssertEqual(darkPixels(doc.extract([page]).page(at: 0)!, in: stamp.bounds), shown)
    }

    func testAddToEveryPagePutsACopyAtTheSamePlace() {
        let doc = FolioDocument(pdf: makePDF([["1"], ["2"]])), undo = manualUndo(doc)
        // On a page half the size, the copy keeps its size, and sits as far across and up.
        doc.pdf.insert(makePDF([["3"]], size: CGSize(width: 306, height: 396)).page(at: 0)!.copy() as! PDFPage, at: 2)
        let mark = Signature.typed("JH").annotation(in: CGRect(x: 500, y: 40, width: 80, height: 30))
        doc.pages[0].addAnnotation(mark)
        act(undo) { XCTAssertEqual(doc.addToEveryPage(mark), 2) }
        XCTAssertEqual(undo.undoActionName, "Add to Every Page")
        let marks = doc.pages.map(\.annotations)
        XCTAssertEqual(marks.map(\.count), [1, 1, 1])
        let same = marks[1][0].bounds, half = marks[2][0].bounds
        XCTAssertTrue(marks[1][0] is SignatureAnnotation && marks[1][0] !== mark)
        XCTAssertEqual(hypot(same.minX - mark.bounds.minX, same.minY - mark.bounds.minY), 0, accuracy: 0.01)
        XCTAssertEqual(half.size, mark.bounds.size)
        XCTAssertEqual(half.midX, mark.bounds.midX / 2, accuracy: 0.01)
        XCTAssertEqual(half.midY, mark.bounds.midY / 2, accuracy: 0.01)
        // The copies are drawn as the mark is.
        XCTAssertEqual(darkPixels(doc.pages[1], in: same), darkPixels(doc.pages[0], in: mark.bounds))
        undo.undo()
        XCTAssertEqual(doc.pages.map(\.annotations.count), [1, 0, 0])
        // A document of one page has no others.
        let single = FolioDocument(pdf: makePDF([["1"]])), alone = shape(.rect, from: .zero, to: CGPoint(x: 9, y: 9), color: .red)
        single.pages[0].addAnnotation(alone)
        XCTAssertEqual(single.addToEveryPage(alone), 0)
        XCTAssertEqual(single.revision, 0)
    }

    /// A file opened again has PDFKit's own stamp, with the picture in the file, and a text box: those copy too.
    func testAddToEveryPageCopiesMarksReadFromAFile() throws {
        let first = FolioDocument(pdf: makePDF([["1"], ["2"]]))
        let stamp = Signature.image(try XCTUnwrap(Signature.lifted(from: stampPhoto()))).annotation(in: CGRect(x: 400, y: 50, width: 120, height: 120))
        let date = textBox(at: CGPoint(x: 100, y: 100), on: first.pages[0])
        date.contents = "03/11/2026"
        first.pages[0].addAnnotation(stamp)
        first.pages[0].addAnnotation(date)
        let doc = FolioDocument(pdf: PDFDocument(data: try first.snapshot(contentType: .pdf))!)
        let marks = doc.pages[0].annotations
        XCTAssertEqual(marks.map(\.type), ["Stamp", "FreeText"])
        marks.forEach { doc.addToEveryPage($0) }
        let copies = doc.pages[1].annotations
        XCTAssertEqual(copies.map(\.type), ["Stamp", "FreeText"])
        XCTAssertEqual(copies.last?.contents, "03/11/2026")
        let ink = Double(darkPixels(doc.pages[0], in: marks[0].bounds))
        XCTAssertGreaterThan(ink, 5000)
        XCTAssertEqual(Double(darkPixels(doc.pages[1], in: marks[0].bounds)), ink, accuracy: ink / 20)
    }

    /// The pixels of `rect` on the page, at four a point, that are darker than mid grey.
    private func darkPixels(_ page: PDFPage, in rect: CGRect) -> Int {
        gray(page, in: rect, scale: 4).joined().filter { $0 < 128 }.count
    }

    /// The lowest inked point in `rect` on the page, to a tenth of a point.
    private func inkBottom(_ page: PDFPage, in rect: CGRect) -> CGFloat {
        let rows = gray(page, in: rect, scale: 10)
        return rect.minY + CGFloat(rows.count - 1 - rows.lastIndex { $0.contains { $0 < 128 } }!) / 10
    }

    /// `rect` on the page drawn in grey at `scale` pixels a point, as rows of pixels from the top.
    private func gray(_ page: PDFPage, in rect: CGRect, scale: CGFloat) -> [[UInt8]] {
        let width = Int(rect.width * scale), height = Int(rect.height * scale)
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -rect.minX, y: -rect.minY)
        page.draw(with: .mediaBox, to: context)
        let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
        return (0..<height).map { row in (0..<width).map { pixels[row * context.bytesPerRow + $0] } }
    }

    func testAddRemoveAndRecolourUndo() {
        let doc = FolioDocument(pdf: makePDF([["A"]])), undo = manualUndo(doc), page = doc.pages[0]
        let box = shape(.rect, from: .zero, to: CGPoint(x: 50, y: 50), color: .red)
        act(undo) { doc.add(box, to: page, name: "Add Rectangle") }
        XCTAssertEqual(doc.comments.count, 1)
        undo.undo()
        XCTAssertTrue(page.annotations.isEmpty)
        undo.redo()
        XCTAssertEqual(page.annotations.count, 1)
        act(undo) { doc.set(\.color, of: box, to: .blue, name: "Change Colour") }
        undo.undo()
        XCTAssertEqual(box.color, .red)
        act(undo) { doc.remove(box) }
        XCTAssertTrue(page.annotations.isEmpty)
        undo.undo()
        XCTAssertEqual(page.annotations.count, 1)
    }
}
