#if os(iOS)
import PDFKit

/// Touch and the Pencil. One finger drags what the tool drags; anything else is PDFKit's: scrolling, zooming, links, form
/// fields and text selection.
extension Canvas {
    /// Whether a one-finger drag from `point`, in view coordinates, is the tool's rather than a scroll: a markup, shape, pen
    /// or redaction, a saved signature dragged to size, or the selected mark moved.
    func pans(at point: CGPoint) -> Bool {
        guard viewer.doc.canEdit, let page = page(for: point, nearest: false) else { return false }
        switch viewer.tool {
        case .select: return selected?.page == page && selected?.bounds.contains(convert(point, to: page)) == true
        case .sign, .initial: return Signature[viewer.tool] != nil
        case .note, .text, .editText: return false
        case .highlight, .underline, .strike, .rect, .oval, .line, .arrow, .pen, .redact: return true
        }
    }

    /// A tap at `point`, in view coordinates. It ends the typing, then edits the selected text box's words when it lands on
    /// them, or does what the tool does there. The page takes the keys, for iPad's Edit menu to send Undo, Redo and Copy to,
    /// unless a form field there takes them from PDFKit.
    func tapped(at point: CGPoint) {
        finishEditing()
        commitFields()
        guard let page = page(for: point, nearest: false) else { return }
        let at = convert(point, to: page)
        if page.annotation(at: at)?.type != "Widget" { documentView?.becomeFirstResponder() }
        if viewer.tool == .select, viewer.doc.canEdit, let selected, selected.type == "FreeText", selected.page == page, selected.bounds.contains(at) {
            return edit(selected, on: page)
        }
        _ = begin(at: at, on: page)
        end(at: at)
    }

    /// A one-finger drag at `point`, in view coordinates. A markup tool selects the text from where it began to here, and marks
    /// it up when it ends; any other carries the tool's press on, in the space of the page it began on. The page takes the
    /// keys, as for a tap.
    func panned(_ state: UIGestureRecognizer.State, at point: CGPoint) {
        if state == .began {
            finishEditing()
            commitFields()
            documentView?.becomeFirstResponder()
            guard let page = page(for: point, nearest: false) else { return }
            _ = begin(at: convert(point, to: page), on: page)
        }
        guard let (from, first) = start else { return }
        let markup = [.highlight, .underline, .strike].contains(viewer.tool)
        if markup, let page = page(for: point, nearest: true) {
            currentSelection = document?.selection(from: first, at: from, to: page, at: convert(point, to: page))
        } else if state != .began {
            _ = extend(to: convert(point, to: first))
        }
        guard state == .ended || state == .cancelled else { return }
        if markup, let selection = currentSelection {
            markUp(selection)
            clearSelection()
        }
        end(at: convert(point, to: first))
    }

}

/// Decides when the canvas's pan and tap take a touch. Not the canvas itself: a PDFView is the delegate of PDFKit's own
/// gestures, by methods of its own these would replace.
final class Gestures: NSObject, UIGestureRecognizerDelegate {
    unowned let canvas: Canvas
    /// Where the pan's finger went down. The pan begins once it has moved a little, and its translation counts from there.
    private var down = CGPoint.zero

    init(canvas: Canvas) {
        self.canvas = canvas
    }

    @objc func dragged(_ pan: UIPanGestureRecognizer) {
        if pan.state == .began { canvas.panned(.began, at: down) }
        canvas.panned(pan.state == .began ? .changed : pan.state, at: pan.location(in: canvas))
    }

    @objc func touched(_ tap: UITapGestureRecognizer) {
        canvas.tapped(at: tap.location(in: canvas))
    }

    /// A finger landing on the navigation bar ends the typing before what it touched acts: Back closes the document before the
    /// words would otherwise become a change, and saves it without them. Only there: the navigation bar stays put as the
    /// keyboard goes, but the tool bar goes with it, out from under the finger, so its buttons end the typing as they act.
    @objc func landed(_ press: UILongPressGestureRecognizer) {
        if press.state == .began { canvas.viewer.settle() }
    }

    func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        recognizer !== canvas.pan || canvas.pans(at: down)
    }

    /// The page scrolls only once the tool has passed on the drag.
    func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        recognizer === canvas.pan && other === (other.view as? UIScrollView)?.panGestureRecognizer
    }

    /// The tap goes with PDFKit's own, which follow links and fill form fields, and the press with everything.
    func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        recognizer !== canvas.pan
    }

    /// Touches on the words being typed are the text field's. Any other first has its page's form fields remembered, so a fill
    /// PDFKit makes from it can be undone.
    func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if recognizer === canvas.press {
            return touch.view.map { sequence(first: $0, next: \.superview).contains { $0 is UINavigationBar } } ?? false
        }
        if let field = canvas.editor?.field, field.bounds.contains(touch.location(in: field)) { return false }
        let at = touch.location(in: canvas)
        if recognizer === canvas.pan, recognizer.numberOfTouches == 0 { down = at }
        if canvas.viewer.doc.canEdit, let page = canvas.page(for: at, nearest: false) { canvas.snapshotFields(on: page) }
        return true
    }
}
#endif
