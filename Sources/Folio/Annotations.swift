import PDFKit

enum Tool: String, CaseIterable, Identifiable {
    case select, highlight, underline, strike, note, text, rect, oval, line, arrow, pen, sign, editText, redact

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
        case .editText: "character.cursor.ibeam"
        case .redact: "rectangle.fill"
        }
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
                                        .zero, CGPoint(x: bounds.width, y: 0)].map { NSValue(point: $0) }
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
        let path = NSBezierPath()
        path.lineWidth = width
        for (index, point) in stroke.enumerated() {
            let local = CGPoint(x: point.x - bounds.minX, y: point.y - bounds.minY)
            if index == 0 { path.move(to: local) } else { path.line(to: local) }
        }
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

extension PDFAnnotation {
    var isRedaction: Bool { value(forAnnotationKey: .name) as? String == "folio-redaction" }

    var isComment: Bool {
        !isRedaction && ["Text", "FreeText", "Highlight", "Underline", "StrikeOut", "Square", "Circle", "Line", "Ink"].contains(type ?? "")
    }
}

/// The user's signature: strokes drawn on the pad, y up, or a name typed and shown in a script font.
enum Signature: Codable, Equatable {
    case drawn([[CGPoint]])
    case typed(String)

    static var saved: Signature? {
        get { UserDefaults.standard.data(forKey: "signature").flatMap { try? JSONDecoder().decode(Signature.self, from: $0) } }
        set { UserDefaults.standard.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: "signature") }
    }

    /// Width over height.
    var aspect: CGFloat {
        guard case .drawn(let strokes) = self, extent(strokes).height > 0 else { return 4 }
        return extent(strokes).width / extent(strokes).height
    }

    /// The signature fitted into `rect`, keeping its shape.
    func annotation(in rect: CGRect) -> PDFAnnotation {
        switch self {
        case .drawn(let strokes):
            let box = extent(strokes), scale = min(rect.width / max(box.width, 1), rect.height / max(box.height, 1))
            let origin = CGPoint(x: rect.midX - box.width * scale / 2, y: rect.midY - box.height * scale / 2)
            return ink(strokes.map { $0.map { CGPoint(x: origin.x + ($0.x - box.minX) * scale, y: origin.y + ($0.y - box.minY) * scale) } },
                       color: .black, width: 2)
        case .typed(let name):
            let font = NSFont(name: "SnellRoundhand", size: 70)!
            // Width over height, with the font at 0.7 of the height, plus room for the flourishes and PDFKit's inset, without
            // which the name wraps.
            let aspect = name.size(withAttributes: [.font: font]).width / 100 + 0.5
            let height = min(rect.height, rect.width / aspect)
            let a = PDFAnnotation(bounds: CGRect(x: rect.midX - height * aspect / 2, y: rect.midY - height / 2, width: height * aspect, height: height),
                                  forType: .freeText, withProperties: nil)
            a.contents = name
            a.font = font.withSize(height * 0.7)
            a.alignment = .center
            a.fontColor = .black
            a.color = .clear
            a.border = PDFBorder()
            a.border?.lineWidth = 0
            return a
        }
    }
}

extension FolioDocument {
    func add(_ a: PDFAnnotation, to page: PDFPage, name: String) {
        change(name, do: { page.addAnnotation(a) }, undo: { page.removeAnnotation(a) })
    }

    func remove(_ a: PDFAnnotation) {
        guard let page = a.page else { return }
        change("Delete", do: { page.removeAnnotation(a) }, undo: { page.addAnnotation(a) })
    }

    func set<V>(_ key: ReferenceWritableKeyPath<PDFAnnotation, V>, of a: PDFAnnotation, to value: V, name: String) {
        let old = a[keyPath: key]
        change(name, do: { a[keyPath: key] = value }, undo: { a[keyPath: key] = old })
    }

    /// Every comment, page by page.
    var comments: [(page: PDFPage, annotation: PDFAnnotation)] {
        pages.flatMap { page in page.annotations.filter(\.isComment).map { (page, $0) } }
    }

    var hasRedactions: Bool { pages.contains { $0.annotations.contains(where: \.isRedaction) } }
}
