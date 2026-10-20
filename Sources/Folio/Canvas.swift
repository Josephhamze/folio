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
            // So the Fonts panel shows, and changes, the selected text box's font.
            if selected?.type == "FreeText", let font = selected?.font { NSFontManager.shared.setSelectedFont(font, isMultiple: false) }
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
    /// The field over a text box being typed into. A box `adding` names isn't on its page yet.
    private(set) var editor: (field: NSTextField, box: PDFAnnotation, page: PDFPage, adding: String?)?
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
        NotificationCenter.default.addObserver(self, selector: #selector(textChanged), name: NSControl.textDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(pageChanged), name: .PDFViewPageChanged, object: self)
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
                if event.clickCount == 2, hit.type == "FreeText" { edit(hit, on: page) }
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
            // Placing is one-shot, so the click that ends the typing selects rather than starting another box.
            viewer.tool = .select
            edit(textBox(at: at, on: page), on: page, adding: "Add Text")
        case .editText:
            guard let cover = coverLine(at: at, on: page) else { return }
            if !Self.warned {
                Self.warned = true
                viewer.message = "The original text stays underneath in the file."
            }
            edit(cover, on: page, adding: "Edit Text")
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

    @objc private func pageChanged() {
        viewer.pageIndex = currentPage.flatMap { document?.index(for: $0) } ?? 0
    }

    /// With a mark selected, the arrows nudge it a point, or ten with Shift, and Delete deletes it. Esc puts down the mark
    /// or the tool; with neither it falls through, to leave Read Mode. A letter picks its tool.
    override func keyDown(with event: NSEvent) {
        guard viewer.doc.canEdit else { return super.keyDown(with: event) }
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        let nudges: [UInt16: CGVector] = [123: CGVector(dx: -step, dy: 0), 124: CGVector(dx: step, dy: 0),
                                          125: CGVector(dx: 0, dy: -step), 126: CGVector(dx: 0, dy: step)]
        if let selected, let by = nudges[event.keyCode] {
            let from = selected.bounds, to = from.offsetBy(dx: by.dx, dy: by.dy)
            viewer.doc.change("Move", do: { selected.bounds = to }, undo: { selected.bounds = from })
        } else if let selected, [51, 117].contains(event.keyCode) {
            viewer.doc.remove(selected)
            self.selected = nil
        } else if event.keyCode == 53, selected != nil || viewer.tool != .select {
            selected = nil
            viewer.tool = .select
        } else if event.modifierFlags.isDisjoint(with: [.command, .option, .control]),
                  let tool = event.charactersIgnoringModifiers.flatMap({ Tool(key: $0.lowercased()) }) {
            viewer.tool = tool
        } else {
            super.keyDown(with: event)
        }
    }

    /// Puts the outline around the selected annotation, or takes it away when there is none on a page.
    @objc func outlineSelection() {
        guard let selected, let page = selected.page, let documentView else { return outline.removeFromSuperview() }
        outline.frame = convert(convert(selected.bounds, from: page), to: documentView).insetBy(dx: -3, dy: -3)
        if outline.superview !== documentView { documentView.addSubview(outline) }
    }

    /// Puts a text field over the text box, at the page's zoom, to edit its words. A box `adding` names isn't on the page yet:
    /// it joins it under that name when the typing ends.
    func edit(_ box: PDFAnnotation, on page: PDFPage, adding name: String? = nil) {
        guard let documentView else { return }
        let font = box.font ?? .systemFont(ofSize: 14)
        let field = NSTextField(string: box.contents ?? "")
        field.font = font.withSize(font.pointSize * scaleFactor)
        field.textColor = box.fontColor ?? .black
        // A cover's white hides the line it replaces; a text box shows the page through.
        field.backgroundColor = box.color
        field.isBezeled = false
        field.focusRingType = .none
        field.wantsLayer = true
        field.layer?.borderColor = NSColor.controlAccentColor.cgColor
        field.layer?.borderWidth = 1
        field.frame = convert(convert(box.bounds, from: page), to: documentView)
        field.frame.size.width = max(field.frame.width, field.cell?.cellSize.width ?? 0)
        documentView.addSubview(field)
        window?.makeFirstResponder(field)
        editor = (field, box, page, name)
    }

    /// Widens the field to its words as they're typed.
    @objc private func textChanged(_ note: Notification) {
        guard let field = editor?.field, note.object as? NSTextField === field, let font = field.font else { return }
        let width = ((field.currentEditor()?.string ?? "") as NSString).size(withAttributes: [.font: font]).width + 12
        field.frame.size.width = max(field.frame.width, width)
    }

    @objc private func endedEditing(_ note: Notification) {
        guard let view = note.object as? NSView, view.isDescendant(of: self) else { return }
        if view === editor?.field { finishEditing() } else { commitFields() }
    }

    /// Writes the edited words into the text box as one change, and grows the box to fit them. A box not on its page yet joins
    /// it only if its words changed: a text box left empty is never added, and an emptied cover blanks out its line.
    func finishEditing() {
        guard let (field, box, page, adding) = editor else { return }
        editor = nil
        field.removeFromSuperview()
        let text = field.stringValue, oldText = box.contents, oldBounds = box.bounds
        let bounds = fit(oldBounds, around: text, in: box.font ?? .systemFont(ofSize: 14))
        if let adding {
            guard text != oldText ?? "" else { return }
            (box.contents, box.bounds) = (text, bounds)
            return viewer.doc.add(box, to: page, name: adding)
        }
        guard text != oldText || bounds != oldBounds else { return }
        viewer.doc.change("Edit Text", do: { box.contents = text; box.bounds = bounds }, undo: { box.contents = oldText; box.bounds = oldBounds })
    }

    /// The Fonts panel's choice, for the selected text box.
    @objc func changeFont(_ sender: NSFontManager?) {
        guard let sender, let box = selected, box.type == "FreeText", viewer.doc.canEdit else { return }
        viewer.doc.setFont(sender.convert(box.font ?? NSFont(name: "Helvetica", size: 12)!), of: box)
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
