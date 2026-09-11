import AppKit
import WebKit

/// A web card's page, which takes a drop only where the page has somewhere to put it.
///
/// **WebKit's answer to a dragged link is to go to it.** A browser treats a link dropped on a page as a
/// place to visit, and left to itself a card did the same — drag a link out of a page onto the board,
/// let go a little early, and the card you dragged it out of had navigated away. A card is not that
/// kind of browser. So a drop over a text field, a textarea or anything contenteditable is the page's,
/// exactly as it would be in Safari, and a drop anywhere else on the page is `dropFallback`'s — the
/// board, which makes a card of it. That is the rule every other card already follows: a text card
/// takes a drop while its editor is open, because then there is somewhere to put it, and not otherwise.
///
/// **What is under the pointer is the page's to say, and it says so asynchronously** — the page is in
/// another process. So the answer trails the pointer by one round trip, a few milliseconds, and AppKit
/// asks again on a timer while a drag holds still over a view, which is what lets the answer catch up
/// without the pointer moving. Until the page has said yes the drag is the fallback's: a drop made
/// before the first answer arrives makes a card, which is the outcome that can't lose anything.
///
/// The two sides are told about the drag as it crosses between them — the one it leaves hears
/// `draggingExited`, the one it reaches hears `draggingEntered` — so each sees an ordinary drag that
/// happens to start and end in the middle of the view.
@MainActor
final class CanvasPageView: WKWebView {
    /// Where a drop goes when the page has nowhere to put it. Nil leaves every drop to the page.
    weak var dropFallback: NSView?

    /// Which side is holding the drag right now.
    private enum Holder { case page, fallback }
    private var holder: Holder?

    /// The page's latest answer to "is there somewhere to type under the pointer", and whether a
    /// question is still out. One at a time: a drag produces updates far faster than a page answers
    /// them, and a queue of stale questions would only delay the answer to the current one.
    private var editableUnderPointer = false
    private var asking = false

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        holder = nil
        editableUnderPointer = false
        ask(about: sender)
        return route(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        ask(about: sender)
        return route(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        switch holder {
        case .page: super.draggingExited(sender)
        case .fallback: dropFallback?.draggingExited(sender)
        case nil: break
        }
        holder = nil
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        switch holder {
        case .page: return super.prepareForDragOperation(sender)
        case .fallback: return dropFallback?.prepareForDragOperation(sender) ?? false
        case nil: return false
        }
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        switch holder {
        case .page: return super.performDragOperation(sender)
        case .fallback: return dropFallback?.performDragOperation(sender) ?? false
        case nil: return false
        }
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        switch holder {
        case .page: super.concludeDragOperation(sender)
        case .fallback: dropFallback?.concludeDragOperation(sender)
        case nil: break
        }
        holder = nil
    }

    /// AppKit asks the destination for new images once a drop there looks likely. The page has none of
    /// its own to give — a field takes a link as the link it is — so this is the board's question while
    /// the board is holding the drag, and nobody's while the page is.
    override func updateDraggingItemsForDrag(_ sender: NSDraggingInfo?) {
        guard holder == .fallback else { return }
        (dropFallback as NSDraggingDestination?)?.updateDraggingItemsForDrag?(sender)
    }

    /// Hand the drag to whichever side the page's latest answer says, telling each about the crossing.
    private func route(_ sender: NSDraggingInfo) -> NSDragOperation {
        let wanted: Holder = editableUnderPointer || dropFallback == nil ? .page : .fallback
        if holder == wanted {
            return wanted == .page ? super.draggingUpdated(sender)
                                   : dropFallback?.draggingUpdated(sender) ?? []
        }
        switch holder {
        case .page: super.draggingExited(sender)
        case .fallback: dropFallback?.draggingExited(sender)
        case nil: break
        }
        holder = wanted
        return wanted == .page ? super.draggingEntered(sender)
                               : dropFallback?.draggingEntered(sender) ?? []
    }

    private func ask(about sender: NSDraggingInfo) {
        guard !asking, dropFallback != nil else { return }
        asking = true
        let point = convert(sender.draggingLocation, from: nil)
        Task { [weak self] in
            guard let self else { return }
            editableUnderPointer = await acceptsTyping(at: point)
            asking = false
        }
    }

    /// Whether the page has somewhere to type at `point`, in this view's coordinates.
    ///
    /// Asked in the app's own script world, so the page can neither see the question nor answer it in
    /// place of the browser. Into open shadow roots, because a component's text field is a text field;
    /// not into frames, whose documents may belong to another site and would answer nothing — a drop
    /// over an embedded frame makes a card. A field that is disabled or read-only is not somewhere to
    /// type, and neither is a checkbox, which is an `<input>` too.
    func acceptsTyping(at point: NSPoint) async -> Bool {
        // CSS pixels: the page is drawn at `pageZoom`, and the card's own magnification scales it again.
        let scale = pageZoom * magnification
        guard scale > 0 else { return false }
        let y = isFlipped ? point.y : bounds.height - point.y
        let answer = try? await callAsyncJavaScript(Self.typingScript,
                                                    arguments: ["x": point.x / scale, "y": y / scale],
                                                    in: nil, contentWorld: .defaultClient)
        return answer as? Bool ?? false
    }

    private static let typingScript = """
        let el = document.elementFromPoint(x, y);
        while (el && el.shadowRoot) {
            const inner = el.shadowRoot.elementFromPoint(x, y);
            if (!inner || inner === el) break;
            el = inner;
        }
        if (!el) return false;
        if (el.isContentEditable) return true;
        if (el.disabled || el.readOnly) return false;
        if (el.tagName === 'TEXTAREA') return true;
        if (el.tagName !== 'INPUT') return false;
        return ['text', 'search', 'url', 'email', 'tel', 'password'].includes(el.type);
        """
}
