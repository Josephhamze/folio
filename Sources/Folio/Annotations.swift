import PDFKit

enum Tool: String, CaseIterable, Identifiable {
    case select, highlight, underline, strike, note, text, rect, oval, line, arrow, pen, sign, initial, editText, redact

    var id: Self { self }

    var name: String {
        switch self {
        case .select: "Select"
        case .highlight: "Highlight"
        case .underline: "Underline"
        case .strike: "Strike Through"
        case .note: "Note"
        case .text: "Text Box"
        case .rect: "Rectangle"
        case .oval: "Oval"
        case .line: "Line"
        case .arrow: "Arrow"
        case .pen: "Pen"
        case .sign: "Sign"
        case .initial: "Initial"
        case .editText: "Edit Text"
        case .redact: "Redact"
        }
    }

    var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .highlight: "highlighter"
        case .underline: "underline"
        case .strike: "strikethrough"
        case .note: "note.text"
        case .text: "textformat"
        case .rect: "rectangle"
        case .oval: "circle"
        case .line: "line.diagonal"
        case .arrow: "arrow.up.right"
        case .pen: "pencil.tip"
        case .sign: "signature"
        case .initial: "pencil.and.scribble"
        case .editText: "character.cursor.ibeam"
        case .redact: "rectangle.fill"
        }
    }

    /// The key that picks the tool while the page has the keyboard.
    var key: String {
        switch self {
        case .select: "v"
        case .highlight: "h"
        case .underline: "u"
        case .strike: "k"
        case .note: "n"
        case .text: "t"
        case .rect: "r"
        case .oval: "o"
        case .line: "l"
        case .arrow: "a"
        case .pen: "p"
        case .sign: "s"
        case .initial: "i"
        case .editText: "e"
        case .redact: "x"
        }
    }

    init?(key: String) {
        guard let tool = Self.allCases.first(where: { $0.key == key }) else { return nil }
        self = tool
    }
}

/// One highlight, underline or strike-through for each line of the selection.
func markups(_ selection: PDFSelection, type: PDFAnnotationSubtype, color: NSColor) -> [(page: PDFPage, annotation: PDFAnnotation)] {
    selection.selectionsByLine().flatMap { line in
        line.pages.compactMap { page -> (page: PDFPage, annotation: PDFAnnotation)? in
            let bounds = line.bounds(for: page)
            guard !bounds.isEmpty else { return nil }
            let mark = PDFAnnotation(bounds: bounds, forType: type, withProperties: nil)
            mark.color = color
            // Other apps draw text markup from its quadrilateral, top left, top right, bottom left, bottom right.
            mark.quadrilateralPoints = [CGPoint(x: 0, y: bounds.height), CGPoint(x: bounds.width, y: bounds.height),
                                        .zero, CGPoint(x: bounds.width, y: 0)].map { $0 as NSValue }
            return (page, mark)
        }
    }
}

/// A rectangle, oval, line or arrow, or a redaction mark, dragged from `start` to `end` in page space.
func shape(_ tool: Tool, from start: CGPoint, to end: CGPoint, color: NSColor) -> PDFAnnotation {
    let box = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
    let type: PDFAnnotationSubtype = tool == .oval ? .circle : tool == .line || tool == .arrow ? .line : .square
    let a = PDFAnnotation(bounds: type == .line ? box.insetBy(dx: -10, dy: -10) : box, forType: type, withProperties: nil)
    a.border = PDFBorder()
    a.border?.lineWidth = 2
    a.color = color
    if type == .line {
        a.startPoint = CGPoint(x: start.x - a.bounds.minX, y: start.y - a.bounds.minY)
        a.endPoint = CGPoint(x: end.x - a.bounds.minX, y: end.y - a.bounds.minY)
        if tool == .arrow { a.endLineStyle = .openArrow }
    }
    if tool == .redact {
        a.color = .systemRed
        a.interiorColor = NSColor.systemRed.withAlphaComponent(0.25)
        a.setValue("folio-redaction", forAnnotationKey: .name)
    }
    return a
}

/// Strokes in page space, as one ink annotation. Its paths are relative to its bounds.
func ink(_ strokes: [[CGPoint]], color: NSColor, width: CGFloat) -> PDFAnnotation {
    let bounds = extent(strokes).insetBy(dx: -width, dy: -width)
    let a = PDFAnnotation(bounds: bounds, forType: .ink, withProperties: nil)
    a.color = color
    a.border = PDFBorder()
    a.border?.lineWidth = width
    for stroke in strokes {
        let line = CGMutablePath()
        line.addLines(between: stroke.map { CGPoint(x: $0.x - bounds.minX, y: $0.y - bounds.minY) })
        let path = NSBezierPath(cgPath: line)
        path.lineWidth = width
        a.add(path)
    }
    return a
}

/// The box around every point of the strokes.
private func extent(_ strokes: [[CGPoint]]) -> CGRect {
    strokes.joined().reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }
}

/// A white text box over the line of text at `point`, holding the same words in the same font and size, to be edited.
func coverLine(at point: CGPoint, on page: PDFPage) -> PDFAnnotation? {
    guard let line = page.selectionForLine(at: point), let words = line.string?.trimmingCharacters(in: .whitespacesAndNewlines),
          !words.isEmpty else { return nil }
    let bounds = line.bounds(for: page).insetBy(dx: -2, dy: -2)
    guard bounds.contains(point) else { return nil }
    let a = PDFAnnotation(bounds: bounds, forType: .freeText, withProperties: nil)
    a.contents = words
    a.font = line.attributedString?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont ?? .systemFont(ofSize: bounds.height * 0.75)
    a.fontColor = .black
    a.color = .white
    a.border = PDFBorder()
    a.border?.lineWidth = 0
    return a
}

/// An empty text box at `point` in the font, size and colour of the nearest text on the page, so what is typed matches it.
/// At the height of a line it takes that line's nearest text and puts the words on its baseline; elsewhere it is centred on
/// the point. A page with no text gets Helvetica 12 in black, a font every PDF app has.
func textBox(at point: CGPoint, on page: PDFPage) -> PDFAnnotation {
    // Each run of one font and colour on the page, with its line's bounds.
    var runs: [(bounds: CGRect, line: CGRect, style: [NSAttributedString.Key: Any])] = []
    for line in page.selection(for: page.bounds(for: .mediaBox))?.selectionsByLine() ?? [] {
        guard let text = line.attributedString else { continue }
        let start = line.range(at: 0, on: page).location, bounds = line.bounds(for: page)
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { style, range, _ in
            let run = page.selection(for: NSRange(location: start + range.location, length: range.length))?.bounds(for: page) ?? .zero
            if !run.isEmpty { runs.append((run, bounds, style)) }
        }
    }
    let distance = { (r: CGRect) in hypot(max(r.minX - point.x, 0, point.x - r.maxX), max(r.minY - point.y, 0, point.y - r.maxY)) }
    let beside = runs.filter { $0.line.minY...$0.line.maxY ~= point.y }
    let near = (beside.isEmpty ? runs : beside).min { distance($0.bounds) < distance($1.bounds) }
    // PDFKit draws a text box's words 2 pt in from its left and about 3.5 pt down from its top, so a box 2 pt under the line's
    // descent and 3.5 pt over its ascent puts them on the line's baseline.
    let font = near?.style[.font] as? NSFont ?? NSFont(name: "Helvetica", size: 12)!, height = font.ascender - font.descender + 5.5
    let y = beside.isEmpty ? point.y - height / 2 : near!.line.minY - 2
    let box = PDFAnnotation(bounds: CGRect(x: point.x - 2, y: y, width: font.pointSize, height: height), forType: .freeText, withProperties: nil)
    box.font = font
    box.fontColor = near?.style[.foregroundColor] as? NSColor ?? .black
    box.color = .clear
    box.border = PDFBorder()
    box.border?.lineWidth = 0
    return box
}

/// `bounds` grown to hold `text` in `font`, from the same top left corner. Never shrunk: an Edit Text cover that shrank would
/// uncover the line beneath it.
func fit(_ bounds: CGRect, around text: String, in font: NSFont) -> CGRect {
    let size = (text as NSString).size(withAttributes: [.font: font])
    let width = max(bounds.width, size.width + 8), height = max(bounds.height, size.height + 4)
    return CGRect(x: bounds.minX, y: bounds.maxY - height, width: width, height: height)
}

extension PDFAnnotation {
    var isRedaction: Bool { value(forAnnotationKey: .name) as? String == "folio-redaction" }

    /// What the Select tool picks: any annotation but a form field, a link or a note's popup.
    var isMark: Bool { !["Widget", "Link", "Popup"].contains(type ?? "") }

    var isComment: Bool {
        !isRedaction && ["Text", "FreeText", "Highlight", "Underline", "StrikeOut", "Square", "Circle", "Line", "Ink"].contains(type ?? "")
    }
}

/// The user's signature or initials: strokes drawn on the pad, y up, or typed and shown in a script font.
enum Signature: Codable, Equatable {
    case drawn([[CGPoint]])
    case typed(String)

    /// The signature the sign tool places, or the initials for the initial tool.
    static subscript(tool: Tool) -> Signature? {
        get { UserDefaults.standard.data(forKey: tool.rawValue).flatMap { try? JSONDecoder().decode(Signature.self, from: $0) } }
        set { UserDefaults.standard.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: tool.rawValue) }
    }

    /// Its outline, to fill, y up: the strokes in ink, or the name's letters with no line finer than a pen's.
    var path: CGPath {
        switch self {
        case .drawn(let strokes):
            let path = CGMutablePath()
            strokes.forEach { path.addPath(inked($0)) }
            return path
        case .typed(let name):
            let letters = CGMutablePath()
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: name, attributes: [.font: NSFont(name: "SnellRoundhand", size: 100)!]))
            for run in CTLineGetGlyphRuns(line) as! [CTRun] {
                let font = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as! CTFont, count = CTRunGetGlyphCount(run)
                var glyphs = [CGGlyph](repeating: 0, count: count), positions = [CGPoint](repeating: .zero, count: count)
                CTRunGetGlyphs(run, CFRange(), &glyphs)
                CTRunGetPositions(run, CFRange(), &positions)
                for (glyph, position) in zip(glyphs, positions) {
                    var at = CGAffineTransform(translationX: position.x, y: position.y)
                    // The script's hairlines are finer than any pen's, and vanish when the name is small. Letter by letter
                    // is seven times quicker than the whole name, which matters while a drag redraws it.
                    CTFontCreatePathForGlyph(font, glyph, &at).map {
                        letters.addPath($0.union($0.copy(strokingWithWidth: 1.5, lineCap: .round, lineJoin: .round, miterLimit: 1)))
                    }
                }
            }
            return letters
        }
    }

    /// Its outline fitted into `rect`, keeping its shape, in the middle.
    func path(in rect: CGRect) -> CGPath {
        let path = path
        guard !path.isEmpty else { return path }   // a name not typed yet, or only spaces: nothing to fit
        let box = path.boundingBoxOfPath, scale = min(rect.width / box.width, rect.height / box.height)
        var fit = CGAffineTransform(translationX: rect.midX - box.width * scale / 2, y: rect.midY - box.height * scale / 2)
            .scaledBy(x: scale, y: scale).translatedBy(x: -box.minX, y: -box.minY)
        return path.copy(using: &fit)!
    }

    /// The signature fitted into `rect`, keeping its shape.
    func annotation(in rect: CGRect, type: PDFAnnotationSubtype = .stamp) -> PDFAnnotation {
        let path = path(in: rect)
        let a = SignatureAnnotation(bounds: path.boundingBoxOfPath, forType: type, withProperties: nil)
        var origin = CGAffineTransform(translationX: -a.bounds.minX, y: -a.bounds.minY)
        a.outline = path.copy(using: &origin)!
        a.color = .black
        return a
    }
}

/// A placed signature: its outline, from the bounds' corner, filled in its colour. PDFKit writes this drawing into the file
/// as the annotation's appearance, so it is the same sharp picture at any size and zoom, here and in other apps.
final class SignatureAnnotation: PDFAnnotation {
    var outline: CGPath = CGMutablePath()

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        context.saveGState()
        context.translateBy(x: bounds.minX, y: bounds.minY)
        context.addPath(outline)
        context.setFillColor(color.cgColor)
        context.fillPath()
        context.restoreGState()
    }

    /// PDFKit copies a page's annotations this way, for Extract and Split, and would leave the outline behind.
    override func copy(with zone: NSZone? = nil) -> Any {
        let copy = super.copy(with: zone) as! SignatureAnnotation
        copy.outline = outline
        return copy
    }
}

/// A stroke of the pen as ink, an outline to fill: smoothed into curves between the midpoints of its points, and thinner
/// where the pen moved faster. The points come at a steady rate, so the gap between two is the speed.
private func inked(_ stroke: [CGPoint]) -> CGPath {
    var points: [SIMD3<Double>] = []   // x, y and the speed there, then the width
    for p in stroke where points.last.map({ hypot(p.x - $0.x, p.y - $0.y) >= 1 }) ?? true {
        let gap = points.last.map { hypot(p.x - $0.x, p.y - $0.y) } ?? 0, speed = 0.7 * gap + 0.3 * (points.last?.z ?? 0)
        points.append(SIMD3(p.x, p.y, speed))
    }
    points = points.map { SIMD3($0.x, $0.y, max(3.5 / (1 + $0.z / 10), 1)) }
    guard points.count > 1 else {
        return CGPath(ellipseIn: CGRect(x: stroke[0].x - 1.75, y: stroke[0].y - 1.75, width: 3.5, height: 3.5), transform: nil)
    }
    // Each point is the control of a quadratic curve from the midpoint before it to the one after; the ends are the ends.
    let ends = [points[0]] + zip(points, points.dropFirst()).map { ($0 + $1) / 2 } + [points[points.count - 1]]
    var samples = [points[0]]
    for (i, c) in points.enumerated() {
        let a = ends[i], b = ends[i + 1], steps = max(1, Int((hypot(c.x - a.x, c.y - a.y) + hypot(b.x - c.x, b.y - c.y)) / 4))
        for step in 1...steps {
            let t = Double(step) / Double(steps)
            samples.append((1 - t) * (1 - t) * a + 2 * (1 - t) * t * c + t * t * b)
        }
    }
    // Half the width out to the left of each sample, round the end, back along the right and round the start.
    let normals = samples.indices.map { i in
        let d = samples[min(i + 1, samples.count - 1)] - samples[max(i - 1, 0)]
        return atan2(d.y, d.x) + .pi / 2
    }
    let edge = { (i: Int, angle: Double) in
        CGPoint(x: samples[i].x + samples[i].z / 2 * cos(angle), y: samples[i].y + samples[i].z / 2 * sin(angle))
    }
    let last = samples.count - 1, cap = (1..<8).map { Double.pi * Double($0) / 8 }
    let outline = samples.indices.map { edge($0, normals[$0]) } + cap.map { edge(last, normals[last] - $0) }
        + samples.indices.reversed().map { edge($0, normals[$0] + .pi) } + cap.map { edge(0, normals[0] + .pi - $0) }
    // Through the midpoints of the outline too, so it stays a curve however far it is zoomed.
    let path = CGMutablePath(), mid = { (i: Int) in
        let a = outline[i], b = outline[(i + 1) % outline.count]
        return CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
    }
    path.move(to: mid(outline.count - 1))
    for i in outline.indices { path.addQuadCurve(to: mid(i), control: outline[i]) }
    path.closeSubpath()
    return path
}

extension PDFPage {
    /// Takes the annotation off the page. iOS's PDFKit leaves a stamp's picture on the screen once it's off, unless it was
    /// hidden as it went; it's shown again after, for when it comes back.
    func drop(_ a: PDFAnnotation) {
        let shown = a.shouldDisplay
        a.shouldDisplay = false
        removeAnnotation(a)
        a.shouldDisplay = shown
    }
}

extension FolioDocument {
    func add(_ a: PDFAnnotation, to page: PDFPage, name: String) {
        change(name, do: { page.addAnnotation(a) }, undo: { page.drop(a) })
    }

    func remove(_ a: PDFAnnotation) {
        guard let page = a.page else { return }
        change("Delete", do: { page.drop(a) }, undo: { page.addAnnotation(a) })
    }

    func set<V>(_ key: ReferenceWritableKeyPath<PDFAnnotation, V>, of a: PDFAnnotation, to value: V, name: String) {
        let old = a[keyPath: key]
        change(name, do: { a[keyPath: key] = value }, undo: { a[keyPath: key] = old })
    }

    /// Puts the text box in `font`, grown to hold its words in it.
    func setFont(_ font: NSFont, of box: PDFAnnotation) {
        let old = (font: box.font, bounds: box.bounds), bounds = fit(box.bounds, around: box.contents ?? "", in: font)
        change("Change Font", do: { box.font = font; box.bounds = bounds }, undo: { box.font = old.font; box.bounds = old.bounds })
    }

    /// Every comment, page by page.
    var comments: [(page: PDFPage, annotation: PDFAnnotation)] {
        pages.flatMap { page in page.annotations.filter(\.isComment).map { (page, $0) } }
    }

    var hasRedactions: Bool { pages.contains { $0.annotations.contains(where: \.isRedaction) } }
}
