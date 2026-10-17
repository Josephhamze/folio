import PDFKit

/// The page view, where the tools draw.
final class Canvas: PDFView {
    typealias Field = (value: String?, state: PDFWidgetCellState)

    unowned let viewer: Viewer
    /// The annotation the select tool picked, shown highlighted.
    var selected: PDFAnnotation? {
        didSet {
            oldValue?.isHighlighted = false
            selected?.isHighlighted = true
            outlineSelection()
        }
    }
    /// A frame around the selection: PDFKit draws `isHighlighted` only on form fields.
    private let outline: NSView = {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.borderColor = NSColor.controlAccentColor.cgColor
        view.layer?.borderWidth = 1.5
        return view
    }()
    /// Where the drag began, in its page's space.
    private var start: (point: CGPoint, page: PDFPage)?
    /// The selected annotation's bounds when the drag began.
    private var origin: CGRect?
    /// The pen's points so far, and what the drag would add, shown without undo until the mouse goes up.
    private var stroke: [CGPoint] = []
    private var draft: PDFAnnotation?
    /// Each form field's text and state when last committed.
    private var fields: [PDFAnnotation: Field] = [:]
    private var editor: (field: NSTextField, box: PDFAnnotation)?
    private static var warned = false

    init(viewer: Viewer) {
        self.viewer = viewer
        super.init(frame: .zero)
        autoScales = true
        displayMode = .singlePageContinuous
        backgroundColor = .underPageBackgroundColor
        for name in [NSControl.textDidEndEditingNotification, NSText.didEndEditingNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(endedEditing), name: name, object: nil)
        }
        for name in [Notification.Name.PDFViewScaleChanged, .PDFViewDisplayModeChanged] {
            NotificationCenter.default.addObserver(self, selector: #selector(outlineSelection), name: name, object: self)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// PDFKit registers its own undo for each form field it changes, which would sit beside "Fill Form".
    override var undoManager: UndoManager? { nil }

    /// A page's tiles are drawn at the zoom once its annotations have their layers: the moment to sharpen those.
    override func draw(_ page: PDFPage, to context: CGContext) {
        super.draw(page, to: context)
        sharpenAnnotations()
    }

    /// PDFKit draws each annotation into a layer of its own at one pixel a point, and stretches it with the zoom, so on a Retina
    /// screen annotations look pixelated. This redraws those layers at the pixels they cover, a turn of the run loop from now,
    /// when an annotation just added has its layer. Never past 4096 pixels a side, so a page-sized box at 20× still fits in memory.
    func sharpenAnnotations() {
        DispatchQueue.main.async { [self] in
            guard let window else { return }
            func sharpen(_ layer: CALayer) {
                // PDFKit's own class: if it is ever renamed, annotations are only as blurry as before.
                if NSStringFromClass(type(of: layer)) == "PDFPageLayerAnnotationEffect" {
                    let scale = min(scaleFactor * window.backingScaleFactor, 4096 / max(layer.bounds.width, layer.bounds.height, 1))
                    if layer.contentsScale != scale {
                        layer.contentsScale = scale
                        layer.setNeedsDisplay()
                    }
                }
                layer.sublayers?.forEach(sharpen)
            }
            layer.map(sharpen)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.tabbingMode = .preferred
    }

    override func mouseDown(with event: NSEvent) {
        // PDFView takes the keys only in its own mouseDown, which the tools often skip.
        window?.makeFirstResponder(self)
        finishEditing()
        commitFields()
        start = nil
        let point = convert(event.locationInWindow, from: nil)
        guard viewer.doc.canEdit, let page = page(for: point, nearest: false) else { return super.mouseDown(with: event) }
        let at = convert(point, to: page)
        start = (at, page)
        stroke = [at]
        switch viewer.tool {
        case .select:
            let hit = page.annotation(at: at)
            if let hit, !["Widget", "Link", "Popup"].contains(hit.type ?? "") {
                selected = hit
                origin = hit.bounds
                if event.clickCount == 2, hit.type == "FreeText" { edit(hit) }
                return
            }
            selected = nil
            if hit?.type == "Widget" { snapshotFields(on: page) }
            super.mouseDown(with: event)
            commitFields()
        case .highlight, .underline, .strike:
            super.mouseDown(with: event)
        case .note:
            let note = PDFAnnotation(bounds: CGRect(x: at.x - 12, y: at.y - 12, width: 24, height: 24), forType: .text, withProperties: nil)
            note.color = viewer.color
            viewer.doc.add(note, to: page, name: "Add Note")
            viewer.pane = .comments
            viewer.focusNote = note
            viewer.tool = .select
        case .text:
            let box = PDFAnnotation(bounds: CGRect(x: at.x, y: at.y - 12, width: 120, height: 24), forType: .freeText, withProperties: nil)
            box.contents = "Text"
            box.font = .systemFont(ofSize: 14)
            box.fontColor = viewer.color
            box.color = .clear
            box.border = PDFBorder()
            box.border?.lineWidth = 0
            viewer.doc.add(box, to: page, name: "Add Text")
            // Placing is one-shot, so the click that ends the edit selects rather than adding another box.
            viewer.tool = .select
            edit(box)
        case .editText:
            guard let cover = coverLine(at: at, on: page) else { return }
            viewer.doc.add(cover, to: page, name: "Edit Text")
            if !Self.warned {
                Self.warned = true
                viewer.message = "The original text stays underneath in the file."
            }
            edit(cover)
        case .sign, .initial:
            if Signature[viewer.tool] == nil {
                start = nil
                viewer.sheet = .signature(viewer.tool)
            }
        case .rect, .oval, .line, .arrow, .pen, .redact:
            break
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let (from, page) = start else { return super.mouseDragged(with: event) }
        let at = convert(convert(event.locationInWindow, from: nil), to: page)
        switch viewer.tool {
        case .select:
            guard let selected, let origin else { return super.mouseDragged(with: event) }
            selected.bounds = origin.offsetBy(dx: at.x - from.x, dy: at.y - from.y)
            outlineSelection()
        case .rect, .oval, .line, .arrow, .redact, .pen, .sign, .initial:
            stroke.append(at)
            draft.map(page.removeAnnotation)
            draft = switch viewer.tool {
            case .pen: ink([stroke], color: viewer.color, width: 2)
            case .sign, .initial: Signature[viewer.tool]?.annotation(in: CGRect(origin: from, size: .zero).union(CGRect(origin: at, size: .zero)))
            default: shape(viewer.tool, from: from, to: at, color: viewer.color)
            }
            draft.map(page.addAnnotation)
            sharpenAnnotations()
        default:
            super.mouseDragged(with: event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer { (start, origin, draft) = (nil, nil, nil) }
        guard let (_, page) = start else { return super.mouseUp(with: event) }
        let at = convert(convert(event.locationInWindow, from: nil), to: page)
        switch viewer.tool {
        case .select:
            if let selected, let origin {
                let moved = selected.bounds
                if moved != origin { viewer.doc.change("Move", do: { selected.bounds = moved }, undo: { selected.bounds = origin }) }
            } else {
                super.mouseUp(with: event)
                commitFields()
            }
        case .highlight, .underline, .strike:
            super.mouseUp(with: event)
            guard let selection = currentSelection else { return }
            let type: PDFAnnotationSubtype = viewer.tool == .highlight ? .highlight : viewer.tool == .underline ? .underline : .strikeOut
            let marks = markups(selection, type: type, color: viewer.color)
            if !marks.isEmpty {
                viewer.doc.change(viewer.tool.name, do: { marks.forEach { $0.page.addAnnotation($0.annotation) } },
                                  undo: { marks.forEach { $0.page.removeAnnotation($0.annotation) } })
            }
            clearSelection()
        case .rect, .oval, .line, .arrow, .redact, .pen:
            guard let draft else { return }
            page.removeAnnotation(draft)
            viewer.doc.add(draft, to: page, name: viewer.tool == .pen ? "Draw" : viewer.tool == .redact ? "Mark for Redaction" : "Add Shape")
        case .sign, .initial:
            guard let signature = Signature[viewer.tool] else { return }
            draft.map(page.removeAnnotation)
            viewer.doc.add(draft ?? signature.annotation(in: CGRect(x: at.x - 90, y: at.y - 22.5, width: 180, height: 45)), to: page, name: viewer.tool.name)
            viewer.tool = .select
        default:
            break
        }
    }

    override func keyDown(with event: NSEvent) {
        guard let selected, viewer.doc.canEdit, [51, 117].contains(event.keyCode) else { return super.keyDown(with: event) }
        viewer.doc.remove(selected)
        self.selected = nil
    }

    /// Puts the outline around the selected annotation, or takes it away when there is none on a page.
    @objc func outlineSelection() {
        guard let selected, let page = selected.page, let documentView else { return outline.removeFromSuperview() }
        outline.frame = convert(convert(selected.bounds, from: page), to: documentView).insetBy(dx: -3, dy: -3)
        if outline.superview !== documentView { documentView.addSubview(outline) }
    }

    /// Puts a text field over the text box, at the page's zoom, to edit its words.
    func edit(_ box: PDFAnnotation) {
        guard let page = box.page, let documentView else { return }
        let font = box.font ?? .systemFont(ofSize: 14)
        let field = NSTextField(string: box.contents ?? "")
        field.font = font.withSize(font.pointSize * scaleFactor)
        field.textColor = box.fontColor ?? .black
        field.backgroundColor = .white
        field.isBezeled = false
        field.focusRingType = .none
        field.frame = convert(convert(box.bounds, from: page), to: documentView)
        field.frame.size.width = max(field.frame.width, field.cell?.cellSize.width ?? 0)
        documentView.addSubview(field)
        window?.makeFirstResponder(field)
        editor = (field, box)
    }

    @objc private func endedEditing(_ note: Notification) {
        guard let view = note.object as? NSView, view.isDescendant(of: self) else { return }
        if view === editor?.field { finishEditing() } else { commitFields() }
    }

    /// Writes the edited words into the text box as one change, and grows the box to fit them.
    private func finishEditing() {
        guard let (field, box) = editor else { return }
        editor = nil
        field.removeFromSuperview()
        let text = field.stringValue, oldText = box.contents, oldBounds = box.bounds
        let size = (text as NSString).size(withAttributes: [.font: box.font ?? NSFont.systemFont(ofSize: 14)])
        // Only grow: an Edit Text cover that shrank would uncover the line beneath it.
        let width = max(oldBounds.width, size.width + 8), height = max(oldBounds.height, size.height + 4)
        let bounds = CGRect(x: oldBounds.minX, y: oldBounds.maxY - height, width: width, height: height)
        guard text != oldText || bounds != oldBounds else { return }
        viewer.doc.change("Edit Text", do: { box.contents = text; box.bounds = bounds }, undo: { box.contents = oldText; box.bounds = oldBounds })
    }

    /// Remembers the page's form fields, so the fill that follows can be undone as one change.
    func snapshotFields(on page: PDFPage) {
        for field in page.annotations where field.type == "Widget" && fields[field] == nil {
            fields[field] = (field.widgetStringValue, field.buttonWidgetState)
        }
    }

    /// Records what the remembered form fields gained since, as one "Fill Form" change.
    func commitFields() {
        let old = fields
        let new = Dictionary(uniqueKeysWithValues: old.keys.map { ($0, Field($0.widgetStringValue, $0.buttonWidgetState)) })
        guard new.contains(where: { $0.value != old[$0.key]! }) else { return }
        let fill = { (values: [PDFAnnotation: Field]) in
            for (field, value) in values {
                if field.widgetStringValue != value.value { field.widgetStringValue = value.value }
                if field.buttonWidgetState != value.state { field.buttonWidgetState = value.state }
            }
            self.fields = values
        }
        viewer.doc.change("Fill Form", do: { fill(new) }, undo: { fill(old) })
    }
}
