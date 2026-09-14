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
/// A link on a page, and what the page calls it.
///
/// The name is the anchor's own text, which is the best label anybody is going to get for free: it is
/// what a person reading the page would have copied, it is already in the page's language, and it costs
/// no request. A link with only an icon in it falls back to what it tells a screen reader.
struct PageLink {
    var url: URL
    var name: String?
}

/// What a page asks of the card it is in, when a link is clicked with something other than the left
/// button.
@MainActor
protocol CanvasPageLinkHost: AnyObject {
    /// Items to put above the page's own context menu. `link` is nil when the click was on the page
    /// rather than on a link.
    func pageMenuItems(for link: PageLink?) -> [NSMenuItem]
    /// A link middle-clicked, which every browser answers with a tab and a board answers with a card.
    func openInNewCard(_ link: PageLink)
    /// Whether files dragged over the page are the page's to take, wherever they land on it.
    ///
    /// True where the page is what you are working in — a tile, or a card you have stepped into — so a
    /// file dropped on Figma goes into Figma rather than becoming a card beside it. Everywhere else a
    /// dropped file is the board's, as it always was, unless there is a field under it.
    var pageTakesFiles: Bool { get }
}

@MainActor
final class CanvasPageView: WKWebView {
    /// Where a drop goes when the page has nowhere to put it. Nil leaves every drop to the page.
    weak var dropFallback: NSView?

    /// The card this page is in, for the two gestures WebKit has no opinion about. Nil leaves the
    /// page's own menu and the middle button exactly as WebKit made them.
    weak var linkHost: CanvasPageLinkHost?

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
        let wanted: Holder = editableUnderPointer || dropFallback == nil || carriesFilesForPage(sender)
            ? .page : .fallback
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

    /// Files, over a page that is where you are working. See `CanvasPageLinkHost.pageTakesFiles`.
    private func carriesFilesForPage(_ sender: NSDraggingInfo) -> Bool {
        linkHost?.pageTakesFiles == true
            && sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self],
                                                       options: [.urlReadingFileURLsOnly: true])
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

    // MARK: The other two buttons

    /// What was under the pointer when the menu was asked for, since the menu itself cannot be asked.
    private var linkUnderPointer: PageLink?
    /// Where the middle button went down, so a middle *drag* — which is how the board is panned — is
    /// not mistaken for a click on whatever the pointer finished over.
    private var middleDown: NSPoint?

    /// Find the link before letting WebKit build its menu.
    ///
    /// **The wait has to be on this side of the menu.** What is under the pointer is the page's to say
    /// and it says so asynchronously, exactly as it does for a drag — but a drag can be told the answer
    /// late, because AppKit keeps asking, and a menu is built once. WebKit's own menu also arrives from
    /// the web process, so the two are races of the same length and the answer would sometimes be
    /// there; a menu whose items depend on which round trip won is worse than one that waits.
    ///
    /// Deferring the event costs nothing visible: the menu was always going to appear a round trip
    /// after the press, and this is the same round trip made twice rather than once.
    override func rightMouseDown(with event: NSEvent) {
        guard linkHost != nil else { return super.rightMouseDown(with: event) }
        let point = convert(event.locationInWindow, from: nil)
        Task { [weak self] in
            guard let self else { return }
            linkUnderPointer = await link(at: point)
            passRightMouseDown(event)
        }
    }

    /// `super` is not reachable from inside a closure, which is the only reason this is a method.
    private func passRightMouseDown(_ event: NSEvent) { super.rightMouseDown(with: event) }

    /// Put the card's items above WebKit's own.
    ///
    /// Above rather than below: they are what this menu is *for* on a board — the stock items are a
    /// browser's and stay because a page is still a page — and a menu whose first item is the one you
    /// opened it to use is the difference between a feature and a feature you have to find.
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        let items = linkHost?.pageMenuItems(for: linkUnderPointer) ?? []
        guard !items.isEmpty else { return }
        for (offset, item) in items.enumerated() { menu.insertItem(item, at: offset) }
        menu.insertItem(.separator(), at: items.count)
    }

    override func didCloseMenu(_ menu: NSMenu, with event: NSEvent?) {
        super.didCloseMenu(menu, with: event)
        linkUnderPointer = nil
    }

    /// Which way a mouse's side buttons walk the history: −1 for Back, +1 for Forward, nil for any other
    /// button. AppKit counts from zero, so these are buttons 3 and 4 — the fourth and fifth, to people.
    static func historyStep(_ event: NSEvent) -> Int? {
        switch event.buttonNumber {
        case 3: return -1
        case 4: return 1
        default: return nil
        }
    }

    /// Back and Forward on the side buttons, which WebKit leaves to the browser around it — here, the
    /// card. A card that isn't taking clicks never sees these; the board hands them on instead.
    override func otherMouseDown(with event: NSEvent) {
        if let step = Self.historyStep(event) {
            middleDown = nil
            if step < 0 { goBack() } else { goForward() }
            return
        }
        middleDown = event.buttonNumber == 2 ? convert(event.locationInWindow, from: nil) : nil
        super.otherMouseDown(with: event)
    }

    /// Middle-click a link and it becomes a card, which is the gesture's one meaning in every browser.
    ///
    /// Only a click: middle-*drag* over a page pans the board underneath it, and a pan that happened to
    /// end over a link must not also leave a card behind. Anything that moved is the board's.
    override func otherMouseUp(with event: NSEvent) {
        let from = middleDown
        middleDown = nil
        let to = convert(event.locationInWindow, from: nil)
        guard event.buttonNumber == 2, let host = linkHost, let from,
              abs(from.x - to.x) < 3, abs(from.y - to.y) < 3 else {
            return super.otherMouseUp(with: event)
        }
        super.otherMouseUp(with: event)
        Task { [weak self] in
            guard let link = await self?.link(at: to) else { return }
            host.openInNewCard(link)
        }
    }

    /// The link under `point`, in this view's coordinates.
    ///
    /// The same hit test `acceptsTyping` makes, for the same reasons and with the same limits: the
    /// app's own script world so the page can neither see the question nor answer it; into open shadow
    /// roots, because a component's link is a link; not into frames, whose documents may belong to
    /// somebody else. `closest` then walks out to the anchor, which is what makes clicking the image
    /// inside a link the same as clicking the link.
    ///
    /// Only `http` and `https` come back. The rest of what an `href` can be — `mailto:`, `javascript:`,
    /// a fragment on this very page — are not things to put a card on, and a card is what every caller
    /// here is about to make.
    func link(at point: NSPoint) async -> PageLink? {
        let scale = pageZoom * magnification
        guard scale > 0 else { return nil }
        let y = isFlipped ? point.y : bounds.height - point.y
        let answer = try? await callAsyncJavaScript(Self.linkScript,
                                                    arguments: ["x": point.x / scale, "y": y / scale],
                                                    in: nil, contentWorld: .defaultClient)
        guard let found = answer as? [String: Any], let href = found["href"] as? String,
              let url = URL(string: href),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        let name = (found["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return PageLink(url: url, name: name?.isEmpty == false ? name : nil)
    }

    private static let linkScript = """
        let el = document.elementFromPoint(x, y);
        while (el && el.shadowRoot) {
            const inner = el.shadowRoot.elementFromPoint(x, y);
            if (!inner || inner === el) break;
            el = inner;
        }
        const a = el && el.closest ? el.closest('a[href]') : null;
        if (!a) return null;
        const image = a.querySelector('img');
        const name = (a.textContent || '').trim() || a.getAttribute('aria-label')
            || a.getAttribute('title') || (image ? image.alt : '') || '';
        return { href: a.href, name: name.replace(/\\s+/g, ' ').slice(0, 200) };
        """

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
