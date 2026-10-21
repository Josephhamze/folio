import PDFKit

/// The page view, where the tools draw.
final class Canvas: PDFView {
    typealias Field = (value: String?, state: PDFWidgetCellState)
    #if os(macOS)
    typealias Input = NSTextField
    #else
    typealias Input = UITextField
    #endif

    unowned let viewer: Viewer
    /// The annotation the select tool picked, shown highlighted.
    var selected: PDFAnnotation? {
        didSet {
            oldValue?.isHighlighted = false
            selected?.isHighlighted = true
            outlineSelection()
            viewer.mark = selected
            #if os(macOS)
            // So the Fonts panel shows, and changes, the selected text box's font.
            if selected?.type == "FreeText", let font = selected?.font { NSFontManager.shared.setSelectedFont(font, isMultiple: false) }
            #endif
        }
    }
    // A frame around the selection: PDFKit draws `isHighlighted` only on form fields.
    #if os(macOS)
    private let outline: NSView = {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.borderColor = NSColor.controlAccentColor.cgColor
        view.layer?.borderWidth = 1.5
        return view
    }()
    #else
    private let outline: UIView = {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.layer.borderColor = UIColor.tintColor.cgColor
        view.layer.borderWidth = 1.5
        return view
    }()
    #endif
    /// Where the drag began, in its page's space.
    private(set) var start: (point: CGPoint, page: PDFPage)?
    /// The selected annotation's bounds when the drag began.
    private var origin: CGRect?
    /// The pen's points so far, and what the drag would add, shown without undo until the mouse goes up.
    private var stroke: [CGPoint] = []
    private var draft: PDFAnnotation?
    /// Each form field's text and state when last committed.
    private var fields: [PDFAnnotation: Field] = [:]
    /// The field over a text box being typed into. A box `adding` names isn't on its page yet.
    private(set) var editor: (field: Input, box: PDFAnnotation, page: PDFPage, adding: String?)?
    #if os(macOS)
    /// The window's document, which has the typing committed before it saves, duplicates or closes.
    private weak var editing: NSDocument?
    #endif
    private static var warned = false
    #if os(iOS)
    /// The one-finger drag the tools take, and the tap: see Touch.swift.
    let pan = UIPanGestureRecognizer(), tap = UITapGestureRecognizer()
    private lazy var gestures = Gestures(canvas: self)
    #endif

    init(viewer: Viewer) {
        self.viewer = viewer
        super.init(frame: .zero)
        autoScales = true
        displayMode = .singlePageContinuous
        #if os(macOS)
        backgroundColor = .underPageBackgroundColor
        for name in [NSControl.textDidEndEditingNotification, NSText.didEndEditingNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(endedEditing), name: name, object: nil)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(textChanged), name: NSControl.textDidChangeNotification, object: nil)
        #else
        backgroundColor = .secondarySystemBackground
        pan.maximumNumberOfTouches = 1
        pan.addTarget(self, action: #selector(dragged))
        tap.addTarget(self, action: #selector(touched))
        for recognizer in [pan, tap] {
            recognizer.delegate = gestures
            addGestureRecognizer(recognizer)
        }
        for name in [UITextField.textDidEndEditingNotification, UITextView.textDidEndEditingNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(endedEditing), name: name, object: nil)
        }
        #endif
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
            #if os(macOS)
            let screen = window.backingScaleFactor
            #else
            let screen = window.traitCollection.displayScale
            #endif
            func sharpen(_ layer: CALayer) {
                // PDFKit's own class: if it is ever renamed, annotations are only as blurry as before.
                if NSStringFromClass(type(of: layer)) == "PDFPageLayerAnnotationEffect" {
                    let scale = min(scaleFactor * screen, 4096 / max(layer.bounds.width, layer.bounds.height, 1))
                    if layer.contentsScale != scale {
                        layer.contentsScale = scale
                        layer.setNeedsDisplay()
                    }
                }
                layer.sublayers?.forEach(sharpen)
            }
            #if os(macOS)
            layer.map(sharpen)
            #else
            sharpen(layer)
            #endif
        }
    }

    /// What the tool does where a press lands, at `point` in the page's space. False when the press is PDFKit's: on a file
    /// that can't be edited, with a markup tool, whose drag selects text, and with Select on no mark.
    func begin(at point: CGPoint, on page: PDFPage) -> Bool {
        guard viewer.doc.canEdit else { return false }
        start = (point, page)
        stroke = [point]
        switch viewer.tool {
        case .select:
            let hit = page.annotation(at: point)
            if let hit, !["Widget", "Link", "Popup"].contains(hit.type ?? "") {
                selected = hit
                origin = hit.bounds
                return true
            }
            selected = nil
            if hit?.type == "Widget" { snapshotFields(on: page) }
            return false
        case .highlight, .underline, .strike:
            return false
        case .note:
            let note = PDFAnnotation(bounds: CGRect(x: point.x - 12, y: point.y - 12, width: 24, height: 24), forType: .text, withProperties: nil)
            note.color = viewer.color
            viewer.doc.add(note, to: page, name: "Add Note")
            viewer.pane = .comments
            viewer.showsPanes = true
            viewer.focusNote = note
            viewer.tool = .select
        case .text:
            // Placing is one-shot, so the press that ends the typing selects rather than starting another box.
            viewer.tool = .select
            edit(textBox(at: point, on: page), on: page, adding: "Add Text")
        case .editText:
            guard let cover = coverLine(at: point, on: page) else { return true }
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
        return true
    }

    /// Carries the press on to `point`, in its page's space: moves the picked mark, or redraws what the drag draws. False when
    /// the tool drags nothing.
    func extend(to point: CGPoint) -> Bool {
        guard let (from, page) = start else { return false }
        switch viewer.tool {
        case .select:
            guard let selected, let origin else { return false }
            selected.bounds = origin.offsetBy(dx: point.x - from.x, dy: point.y - from.y)
            outlineSelection()
        case .rect, .oval, .line, .arrow, .redact, .pen, .sign, .initial:
            stroke.append(point)
            draft.map(page.removeAnnotation)
            draft = switch viewer.tool {
            case .pen: ink([stroke], color: viewer.color, width: 2)
            case .sign, .initial: Signature[viewer.tool]?.annotation(in: CGRect(origin: from, size: .zero).union(CGRect(origin: point, size: .zero)))
            default: shape(viewer.tool, from: from, to: point, color: viewer.color)
            }
            draft.map(page.addAnnotation)
            sharpenAnnotations()
        default:
            return false
        }
        return true
    }

    /// Ends the press at `point`, in its page's space: a moved mark, a drawn shape or a placed signature becomes one change.
    /// A signature placed without a drag gets the usual size.
    func end(at point: CGPoint) {
        defer { (start, origin, draft) = (nil, nil, nil) }
        guard let (_, page) = start else { return }
        switch viewer.tool {
        case .select:
            guard let selected, let origin, selected.bounds != origin else { return }
            let moved = selected.bounds
            viewer.doc.change("Move", do: { selected.bounds = moved }, undo: { selected.bounds = origin })
        case .rect, .oval, .line, .arrow, .redact, .pen:
            guard let draft else { return }
            page.removeAnnotation(draft)
            viewer.doc.add(draft, to: page, name: viewer.tool == .pen ? "Draw" : viewer.tool == .redact ? "Mark for Redaction" : "Add Shape")
        case .sign, .initial:
            guard let signature = Signature[viewer.tool] else { return }
            draft.map(page.removeAnnotation)
            viewer.doc.add(draft ?? signature.annotation(in: CGRect(x: point.x - 90, y: point.y - 22.5, width: 180, height: 45)), to: page, name: viewer.tool.name)
            viewer.tool = .select
        default:
            break
        }
    }

    /// One highlight, underline or strike-through for each line of the selection, in the tool's colour, as one change.
    func markUp(_ selection: PDFSelection) {
        let type: PDFAnnotationSubtype = viewer.tool == .highlight ? .highlight : viewer.tool == .underline ? .underline : .strikeOut
        let marks = markups(selection, type: type, color: viewer.color)
        guard !marks.isEmpty else { return }
        viewer.doc.change(viewer.tool.name, do: { marks.forEach { $0.page.addAnnotation($0.annotation) } },
                          undo: { marks.forEach { $0.page.removeAnnotation($0.annotation) } })
    }

    #if os(macOS)
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
        let tool = viewer.tool, point = convert(event.locationInWindow, from: nil)
        guard let page = page(for: point, nearest: false), begin(at: convert(point, to: page), on: page) else {
            super.mouseDown(with: event)
            return commitFields()
        }
        if event.clickCount == 2, tool == .select, let selected, selected.type == "FreeText" { edit(selected, on: page) }
    }

    override func mouseDragged(with event: NSEvent) {
        if let page = start?.page, extend(to: convert(convert(event.locationInWindow, from: nil), to: page)) { return }
        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        guard let page = start?.page else { return super.mouseUp(with: event) }
        if [.highlight, .underline, .strike].contains(viewer.tool) {
            super.mouseUp(with: event)
            if let selection = currentSelection {
                markUp(selection)
                clearSelection()
            }
        } else if viewer.tool == .select, selected == nil || origin == nil {
            super.mouseUp(with: event)
            commitFields()
        }
        end(at: convert(convert(event.locationInWindow, from: nil), to: page))
    }
    #endif

    @objc private func pageChanged() {
        viewer.pageIndex = currentPage.flatMap { document?.index(for: $0) } ?? 0
    }

    #if os(macOS)
    /// With a mark selected, the arrows nudge it a point, or ten with Shift, and Delete deletes it. Esc puts down the mark
    /// or the tool; with neither it falls through, to leave Read Mode. A letter picks its tool.
    override func keyDown(with event: NSEvent) {
        guard viewer.doc.canEdit, !viewer.readMode, event.modifierFlags.isDisjoint(with: [.command, .option, .control]) else {
            return super.keyDown(with: event)
        }
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
        } else if let tool = event.charactersIgnoringModifiers.flatMap({ Tool(key: $0.lowercased()) }) {
            viewer.tool = tool
        } else {
            super.keyDown(with: event)
        }
    }
    #endif

    /// Puts the outline around the selected annotation, or takes it away when there is none on a page.
    @objc func outlineSelection() {
        guard let selected, let page = selected.page, let documentView else { return outline.removeFromSuperview() }
        outline.frame = convert(convert(selected.bounds, from: page), to: documentView).insetBy(dx: -3, dy: -3)
        #if os(iOS)
        // The page view zooms what's in it, so the frame is drawn thinner by the same amount, to stay one width.
        outline.layer.borderWidth = 1.5 / scaleFactor
        #endif
        if outline.superview !== documentView { documentView.addSubview(outline) }
    }

    /// Puts a text field over the text box, at the page's zoom, to edit its words. A box `adding` names isn't on the page yet:
    /// it joins it under that name when the typing ends.
    func edit(_ box: PDFAnnotation, on page: PDFPage, adding name: String? = nil) {
        guard let documentView else { return }
        let font = box.font ?? .systemFont(ofSize: 14)
        #if os(macOS)
        let field = NSTextField(string: box.contents ?? "")
        field.isBezeled = false
        field.focusRingType = .none
        field.wantsLayer = true
        field.layer?.borderColor = NSColor.controlAccentColor.cgColor
        field.layer?.borderWidth = 1
        field.font = font.withSize(font.pointSize * scaleFactor)
        #else
        let field = UITextField()
        field.text = box.contents
        field.layer.borderColor = UIColor.tintColor.cgColor
        // The page view zooms what's in it: the words take the page's size, and the frame stays one width.
        field.layer.borderWidth = 1 / scaleFactor
        field.font = font
        field.addTarget(self, action: #selector(finishEditing), for: .editingDidEndOnExit)
        field.addTarget(self, action: #selector(widen), for: .editingChanged)
        #endif
        field.textColor = box.fontColor ?? .black
        // A cover's white hides the line it replaces; a text box shows the page through.
        field.backgroundColor = box.color
        field.frame = convert(convert(box.bounds, from: page), to: documentView)
        documentView.addSubview(field)
        #if os(macOS)
        field.frame.size.width = max(field.frame.width, field.cell?.cellSize.width ?? 0)
        window?.makeFirstResponder(field)
        editing = window?.windowController?.document as? NSDocument
        editing?.objectDidBeginEditing(self)
        // The field editor would take the Fonts panel's choice for itself.
        NSFontManager.shared.target = self
        #else
        widen(field)
        field.becomeFirstResponder()
        #endif
        editor = (field, box, page, name)
    }

    #if os(macOS)
    /// Widens the field to its words as they're typed.
    @objc private func textChanged(_ note: Notification) {
        guard let field = editor?.field, note.object as? NSTextField === field, let font = field.font else { return }
        let width = ((field.currentEditor()?.string ?? "") as NSString).size(withAttributes: [.font: font]).width + 12
        field.frame.size.width = max(field.frame.width, width)
    }
    #else
    /// Widens the field to its words as they're typed.
    @objc private func widen(_ field: UITextField) {
        field.frame.size.width = max(field.frame.width, field.intrinsicContentSize.width + 12)
    }
    #endif

    @objc private func endedEditing(_ note: Notification) {
        guard let view = note.object as? NSView, view.isDescendant(of: self) else { return }
        if view === editor?.field { finishEditing() } else { commitFields() }
    }

    /// Writes the edited words into the text box as one change, and grows the box to fit them. A box not on its page yet joins
    /// it only if its words changed: a text box left empty is never added, and an emptied cover blanks out its line. With the
    /// Select tool the box is then selected, for the Fonts panel.
    @objc func finishEditing() {
        guard let (field, box, page, adding) = editor else { return }
        editor = nil
        #if os(macOS)
        editing?.objectDidEndEditing(self)
        NSFontManager.shared.target = nil
        // Ending the field's editing puts the words still in its field editor into it.
        if field.currentEditor() != nil { window?.makeFirstResponder(self) }
        let text = field.stringValue
        #else
        let text = field.text ?? ""
        #endif
        field.removeFromSuperview()
        let oldText = box.contents, oldBounds = box.bounds
        let bounds = fit(oldBounds, around: text, in: box.font ?? .systemFont(ofSize: 14))
        defer { if box.page != nil, viewer.tool == .select { selected = box } }
        if let adding {
            guard text != oldText ?? "" else { return }
            (box.contents, box.bounds) = (text, bounds)
            return viewer.doc.add(box, to: page, name: adding)
        }
        guard text != oldText || bounds != oldBounds else { return }
        viewer.doc.change("Edit Text", do: { box.contents = text; box.bounds = bounds }, undo: { box.contents = oldText; box.bounds = oldBounds })
    }

    #if os(macOS)
    /// The Fonts panel's choice, for the selected text box, or the one being typed once its words are in.
    @objc func changeFont(_ sender: NSFontManager?) {
        finishEditing()
        guard let sender, let box = selected, box.type == "FreeText", viewer.doc.canEdit else { return }
        viewer.doc.setFont(sender.convert(box.font ?? NSFont(name: "Helvetica", size: 12)!), of: box)
    }
    #endif

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

#if os(macOS)
/// NSDocument has the editors registered with it commit before it saves, duplicates or closes, by any route: the close
/// button, the menus or quitting.
extension Canvas: NSEditor {
    func commitEditing() -> Bool {
        finishEditing()
        return true
    }

    func commitEditingWithoutPresentingError() throws { finishEditing() }

    func discardEditing() { finishEditing() }

    func commitEditing(withDelegate delegate: Any?, didCommit selector: Selector?, contextInfo: UnsafeMutableRawPointer?) {
        finishEditing()
        guard let delegate = delegate as? NSObject, let selector else { return }
        typealias DidCommit = @convention(c) (NSObject, Selector, AnyObject, ObjCBool, UnsafeMutableRawPointer?) -> Void
        unsafeBitCast(delegate.method(for: selector), to: DidCommit.self)(delegate, selector, self, true, contextInfo)
    }
}
#endif
