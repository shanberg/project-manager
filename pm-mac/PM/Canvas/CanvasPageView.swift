import AppKit
import WebKit

/// A web card's page, which is offered every drag before the board is.
///
/// **The page decides first, and the board takes what the page declines.** While the pointer is inside
/// a page, a drop is the page's business — and the page has a way of saying so that predates all of
/// this: an element claims a drop by preventing the default on `dragover`. WebKit answers a drag with
/// that decision, so asking it is asking the page.
///
/// **This was the other way round, and it cost a whole class of gesture.** The board held every drag
/// except one over somewhere to type, which meant a page's own drag — reordering a list, which is HTML5
/// drag-and-drop and therefore a real dragging session — was taken from the page that started it.
/// Where the board could make nothing of the payload it declined, and the drag was then refused by both:
/// the page never saw a `dragover` and nothing happened at all. Figma's layer list could not be
/// reordered inside a card, silently, and so could nothing else that reorders by dragging.
///
/// **Nothing is lost by asking first**, which is the part that had to be measured rather than assumed
/// (`CanvasPageDragOriginTests`). WebKit answers `.none` over ordinary page and `.move` over an element
/// that claimed the drop — for a link, a string and a page's own custom data alike — so a link let go
/// over a page still falls through to the board and still becomes a card, or a tile beside the others.
/// The hazard this file was built around, a card navigating to a link dropped on it, does not
/// reproduce: a real `NSURL` dropped on a page with nothing to fall back on left it where it was.
///
/// It is **not** a faster answer. WebKit's first reply to a drag is an optimistic `.copy`, given before
/// the web process has been consulted; its second is `.none`; only the third says what the page decided
/// — measured for every payload in `CanvasPageDragOriginTests`. So this trails the pointer by a round
/// trip exactly as the JavaScript question it replaces did, and for the same reason: the page is in
/// another process. AppKit re-asks on a timer while a drag holds still, which is what lets the answer
/// catch up without the pointer moving, and until it has, the board holds the drag — the outcome that
/// can lose nothing, since it makes a card. See `route`.
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
    /// A file dropped with ⌥ held, to be shown in the page in place of what it is showing. The card
    /// navigates like a followed link would, so Back returns to the page it was on.
    func loadDroppedFile(_ url: URL)
}

extension CanvasPageLinkHost {
    func loadDroppedFile(_ url: URL) {}
}

@MainActor
final class CanvasPageView: WKWebView {
    /// Where a drop goes when the page has nowhere to put it. Nil leaves every drop to the page.
    weak var dropFallback: NSView?

    /// The card this page is in, for the two gestures WebKit has no opinion about. Nil leaves the
    /// page's own menu and the middle button exactly as WebKit made them.
    weak var linkHost: CanvasPageLinkHost?

    /// Which side is holding the drag right now.
    private enum Holder { case page, fallback, load }
    private var holder: Holder?

    /// Whether WebKit has been told this drag arrived.
    ///
    /// Every drag is offered to the page, including the ones the board ends up holding, because the
    /// page's answer is what decides between them and a destination that was never entered has no
    /// answer to give. Kept so that the enter/update/exit sequence WebKit is owed stays well formed.
    private var pageEntered = false

    /// How many times WebKit has been asked about this drag. **The first answer is not an answer**: it
    /// is `.copy` for everything, given before the page has been consulted, and taken at face value it
    /// hands the page every drag that has only just arrived. See `route`.
    private var pageAsks = 0

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        holder = nil
        pageEntered = false
        pageAsks = 0
        return route(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        route(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        if holder == .fallback { dropFallback?.draggingExited(sender) }
        leavePage(sender)
        holder = nil
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        switch holder {
        case .page: return super.prepareForDragOperation(sender)
        case .fallback:
            // The board is about to take this one, so the page is told the drag has gone rather than
            // left mid-drag with an indicator up for a drop that will never arrive.
            leavePage(sender)
            return dropFallback?.prepareForDragOperation(sender) ?? false
        case .load:
            leavePage(sender)
            return true
        case nil: return false
        }
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        switch holder {
        case .page: return super.performDragOperation(sender)
        case .fallback: return dropFallback?.performDragOperation(sender) ?? false
        case .load:
            guard let file = Self.loadableFile(in: sender) else { return false }
            linkHost?.loadDroppedFile(file)
            return true
        case nil: return false
        }
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        switch holder {
        case .page: super.concludeDragOperation(sender)
        case .fallback: dropFallback?.concludeDragOperation(sender)
        case .load, nil: break
        }
        holder = nil
        pageEntered = false
        pageAsks = 0
    }

    /// AppKit asks the destination for new images once a drop there looks likely. The page has none of
    /// its own to give — a field takes a link as the link it is — so this is the board's question while
    /// the board is holding the drag, and nobody's while the page is.
    override func updateDraggingItemsForDrag(_ sender: NSDraggingInfo?) {
        guard holder == .fallback else { return }
        (dropFallback as NSDraggingDestination?)?.updateDraggingItemsForDrag?(sender)
    }

    /// Who holds the drag: **the page, wherever the page claims it; the board everywhere else.**
    ///
    /// The page is asked by being told. There is no way to read "does anything here want this drop"
    /// out of a page without handing the drag to it — the answer *is* what its `dragover` handlers do
    /// — so WebKit is given every drag and its answer is the vote. An empty answer means nothing under
    /// the pointer claimed the drop, and the board takes it from there.
    ///
    /// Two cases are the page's whatever WebKit says. **A page with no board behind it** holds
    /// everything, since there is nowhere else for a drop to go. And **files on a page you are working
    /// in** are the page's wherever they land — `pageTakesFiles` is a rule about the card, not about
    /// what is under the pointer, so a file dropped on Figma goes into Figma rather than becoming a
    /// card beside it.
    ///
    /// Only the board is crossed in and out of here. The page is entered once and kept entered for as
    /// long as the drag is over this view, because it has to go on being asked: the pointer moves onto
    /// a drop target and off it again, and a page that had been told the drag left would answer for a
    /// drag it no longer believes in. Answering `.copy` and then `.none` on the way to the real answer
    /// is also why the board can be given a drag, lose it and be given it back within a few frames —
    /// each of those is a real crossing, and it is told about all of them.
    private func route(_ sender: NSDraggingInfo) -> NSDragOperation {
        // ⌥ with a file the page can show: the file becomes the page. Decided before the page is asked
        // anything, since the answer is ours whatever the page would have said.
        if linkHost != nil, NSEvent.modifierFlags.contains(.option), Self.loadableFile(in: sender) != nil {
            if holder == .fallback { dropFallback?.draggingExited(sender) }
            leavePage(sender)
            holder = .load
            return .link
        }
        let answer = pageEntered ? super.draggingUpdated(sender) : enterPage(sender)
        pageAsks += 1
        // The first reply is `.copy` whatever is under the pointer and whatever the drag carries, since
        // the page has not been asked at that point. Routing on it would give the page every drag for
        // the first moment of its life, including every one it is about to decline.
        let pageWants = pageAsks > 1 ? answer : []
        let wanted: Holder = !pageWants.isEmpty || dropFallback == nil || carriesFilesForPage(sender)
            ? .page : .fallback
        if wanted == .page {
            if holder == .fallback { dropFallback?.draggingExited(sender) }
            holder = .page
            // WebKit's own answer, not the filtered one: what the first reply is held back from is the
            // decision about who holds the drag, not what AppKit is told about it. A page holding a
            // drag because there is nowhere else for it to go still answers for itself.
            return answer
        }
        let crossing = holder != .fallback
        holder = .fallback
        return (crossing ? dropFallback?.draggingEntered(sender)
                         : dropFallback?.draggingUpdated(sender)) ?? []
    }

    /// The one file a drag carries, when it is something a page can show. Several files, or one of a
    /// kind WebKit would only offer to download, are not — those stay the board's.
    private static func loadableFile(in sender: NSDraggingInfo) -> URL? {
        let files = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        guard let files, files.count == 1, let file = files.first,
              ["html", "htm", "xhtml", "pdf", "png", "jpg", "jpeg", "gif", "webp", "svg", "txt"]
                  .contains(file.pathExtension.lowercased())
        else { return nil }
        return file
    }

    /// Tell WebKit the drag has arrived, once per drag.
    private func enterPage(_ sender: NSDraggingInfo) -> NSDragOperation {
        pageEntered = true
        return super.draggingEntered(sender)
    }

    /// Tell WebKit the drag has gone, if it was ever told it arrived.
    private func leavePage(_ sender: NSDraggingInfo?) {
        guard pageEntered else { return }
        pageEntered = false
        super.draggingExited(sender)
    }

    /// Files, over a page that is where you are working. See `CanvasPageLinkHost.pageTakesFiles`.
    private func carriesFilesForPage(_ sender: NSDraggingInfo) -> Bool {
        linkHost?.pageTakesFiles == true
            && sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self],
                                                       options: [.urlReadingFileURLsOnly: true])
    }

    /// Whether the page has somewhere to type at `point`, in this view's coordinates.
    ///
    /// **Nothing routes on this any more.** It was how a drop decided between the page and the board,
    /// and WebKit's own answer to a drag says the same thing better and synchronously — see `route`.
    /// Kept because the question is a real one and is asked again by backlog 23, where a top band with
    /// nothing interactive under it is what makes a page's header somewhere to grab the window.
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

    // MARK: Pointer lock

    /// Whether the page has the pointer — a game or a 3D view that asked for raw mouse movement. Kept by
    /// the card as WebKit grants and ends it; see `CanvasLinkNodeView`'s pointer-lock delegate methods.
    var holdsPointer = false

    /// Whether the Escape now walking up the responder chain is the one that took the pointer back.
    private var escapeReleasedPointer = false

    /// Note an Escape that is about to end a pointer lock, before WebKit ends it.
    ///
    /// Asked here because it can't be asked afterwards: WebKit releases the pointer inside this call,
    /// synchronously, so by the time the key comes back up the chain the lock is already gone. Set on
    /// every key rather than only on Escape, so a page that swallows its Escape can't leave the flag
    /// standing for the next one.
    override func keyDown(with event: NSEvent) {
        escapeReleasedPointer = holdsPointer && event.keyCode == 53
        super.keyDown(with: event)
    }

    /// **Escape out of a pointer lock does that and nothing more.** The page hands the key back as it
    /// hands back any Escape it didn't want, and walked on up it steps out of the card, or out of the
    /// tile — two things at once for one press, and the second one is what nobody meant. Every browser
    /// stops at the first. The Escape after that is the card's as it always was.
    ///
    /// Passed on rather than `super`: `NSView` doesn't implement `cancelOperation:` — see
    /// `CanvasNodeView.cancelOperation`.
    override func cancelOperation(_ sender: Any?) {
        guard !escapeReleasedPointer else {
            escapeReleasedPointer = false
            return
        }
        nextResponder?.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
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
