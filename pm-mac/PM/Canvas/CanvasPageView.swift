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

/// A `dropFallback` that takes some drags before the page is asked about them — the board, for a tile's
/// edges and tab strip (`CanvasBoardView.tilingTakesDrop`).
@MainActor
protocol CanvasPageDropClaim: AnyObject {
    func claimsDrop(_ sender: NSDraggingInfo) -> Bool
}

@MainActor
final class CanvasPageView: WKWebView {
    /// Where a drop goes when the page has nowhere to put it. Nil leaves every drop to the page.
    weak var dropFallback: NSView?

    /// The card this page is in, for the two gestures WebKit has no opinion about. Nil leaves the
    /// page's own menu and the middle button exactly as WebKit made them.
    weak var linkHost: CanvasPageLinkHost?

    override init(frame: NSRect, configuration: WKWebViewConfiguration) {
        super.init(frame: frame, configuration: configuration)
        // **No under-page colour, so a dark page has no white hairline at its sides.** WebKit keeps an
        // "overhang areas" layer the size of the page directly under it, filled with this colour —
        // which it takes from the page's background, and for a page that sets none (Figma) is white.
        // A tile's width is rarely a whole number of device pixels, so its left and right edges land
        // mid-pixel and both layers are antialiased there: the white one bleeds through the page's
        // edge as a fine light line, in dark appearance only. Clear leaves the web view's own
        // background behind it, which follows the appearance. Measured on WebKit's layer tree, 2026-11-05.
        //
        // The same colour fills a rubber-band overscroll, so a white page with no background, in dark
        // appearance, now bounces against dark rather than white. Brief, and only while bouncing.
        underPageBackgroundColor = .clear
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Playing audio

    /// Whether the page is making sound now, as WebKit itself says it — the flag Safari's tab speaker
    /// reads (`_isPlayingAudio`), told the moment it changes rather than asked on a heartbeat. On the
    /// page rather than the card because a running page moves between panes (`CanvasPageHandover`).
    /// docs/spaces.md: the speaker in the sidebar, the switcher and the dock.
    private(set) var isPlayingAudio = false

    /// Posted with the page as the object when `isPlayingAudio` changes.
    static let audioChanged = Notification.Name("PMCanvasPageAudioChanged")

    private static let audioKey = "_isPlayingAudio"
    private var watchingAudio = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard !watchingAudio, responds(to: NSSelectorFromString(Self.audioKey)) else { return }
        watchingAudio = true
        addObserver(self, forKeyPath: Self.audioKey, options: [.initial, .new], context: nil)
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                               change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        guard keyPath == Self.audioKey else {
            return super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
        }
        let playing = (value(forKey: Self.audioKey) as? Bool) ?? false
        MainActor.assumeIsolated {
            guard playing != isPlayingAudio else { return }
            isPlayingAudio = playing
            NotificationCenter.default.post(name: Self.audioChanged, object: self)
        }
    }

    deinit {
        if watchingAudio { removeObserver(self, forKeyPath: Self.audioKey) }
    }

    // MARK: Dead space moves the window

    /// Arc's dead space (docs/spaces.md § The frame): in a space's layout, a press near the top of the
    /// page on nothing you can use — a header's blank background — moves the window, as a title bar
    /// does. Asked of the card, which knows whether it is a tile (or the card filling the window).
    var dragsWindowFromDeadSpace: () -> Bool = { false }

    /// How far down from the page's top a press can be and still count: where a site's header sits.
    /// 96pt: Apple Music's blank header beside its "Home" heading is 60–80pt down (2026-11-05); 56pt
    /// caught Google's and not that.
    static let deadSpaceBand: CGFloat = 96

    /// Whether WebKit last reported something usable under the pointer: a link, an image, media, or a
    /// field to type in. Set by the card from its hover callback (`mouseDidMoveOverElement`).
    var hoverIsInteractive = false

    /// Whether the last hover report was over media. Kept apart from `hoverIsInteractive` because the
    /// two mean different things to a press: a link or a field is the page's, a video is the page's
    /// only if it turns out to be a click (`Press.video`).
    var hoverIsMedia = false

    /// The rule, alone so it can be tested: nothing usable under the pointer, and the plain arrow —
    /// which is what WebKit shows over dead space; a hand over anything clickable (`cursor: pointer`),
    /// an I-beam over text you could select.
    static func isDeadSpace(cursor: NSCursor?, interactive: Bool) -> Bool {
        !interactive && cursor == NSCursor.arrow
    }

    /// Whether `point` (in this view) is within the band at the page's top.
    func isInDeadSpaceBand(_ point: NSPoint) -> Bool {
        let fromTop = isFlipped ? point.y : bounds.height - point.y
        return fromTop >= 0 && fromTop <= Self.deadSpaceBand && bounds.contains(point)
    }

    /// What the page said about the element under the pointer: whether it is the page's to press
    /// (`pageUses(at:)`), and for which hover report. Asked on each of WebKit's hover reports, because
    /// the answer comes from the page's process and a press has to be decided the moment it lands.
    ///
    /// **Driven by the hover report, not by `mouseMoved`.** WebKit takes the window's moves before an
    /// override here, or a tracking area of this view's own, hears them: built on those, no point was
    /// ever asked about and no header moved the window. The hover report is what `hoverIsInteractive`
    /// already rode on. The answer depends only on the element and its ancestors, so it holds until
    /// the next report, wherever the pointer is within that element.
    private var pageAnswer: (hover: Int, press: Press)?
    private var pageQuestion: (hover: Int, point: NSPoint)?
    private var askingPage = false
    private var hoverReports = 0

    /// WebKit reported the pointer over something new, at `point` in this view. Called by the card.
    func hoverMoved(at point: NSPoint) {
        hoverReports += 1
        // Anywhere on the page, not only in the band: one element can reach into the band from below
        // (an app's root), and moving up within it brings no new report to ask on.
        guard dragsWindowFromDeadSpace() else { return }
        pageQuestion = (hoverReports, point)
        guard !askingPage else { return }
        askingPage = true
        Task { @MainActor [weak self] in
            while let self, let next = self.pageQuestion {
                self.pageQuestion = nil
                let press = await self.press(at: next.point)
                self.pageAnswer = (next.hover, press)
            }
            self?.askingPage = false
        }
    }

    /// Whether the page's answer, for the latest hover report, leaves a press dead space. **No answer
    /// for it is the page's**: a press that came before the page could say goes to the page, because a
    /// window that moves when you meant a button is worse than a header that didn't grab.
    func pageLeavesDeadSpace() -> Bool {
        guard let answer = pageAnswer, answer.hover == hoverReports else { return false }
        return answer.press == .dead
    }

    /// Whether the page's answer, for the latest hover report, is that the pointer is on the picture of
    /// a video. Like `pageLeavesDeadSpace`, no answer means no.
    func pageIsOnVideo() -> Bool {
        guard let answer = pageAnswer, answer.hover == hoverReports else { return false }
        return answer.press == .video
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        pendingVideoPress = nil
        if dragsWindowFromDeadSpace(), let window,
           isInDeadSpaceBand(point),
           Self.isDeadSpace(cursor: NSCursor.current, interactive: hoverIsInteractive || hoverIsMedia),
           pageLeavesDeadSpace() {
            if event.clickCount == 2 { return WindowDragView.titleBarDoubleClick(window) }
            Log.write("window drag from page dead space: \(url?.host() ?? "?")")
            return window.performDrag(with: event)
        }
        // The picture of a video: the window's if it is dragged, the page's if it is clicked. Held until
        // one or the other, because a player pauses on a click and goes full screen on a double-click,
        // and handing the press to the window now would take both away. The page hears nothing meanwhile.
        if dragsWindowFromDeadSpace(), window != nil,
           Self.isDeadSpace(cursor: NSCursor.current, interactive: hoverIsInteractive),
           pageIsOnVideo() {
            pendingVideoPress = event
            return
        }
        if dragsWindowFromDeadSpace(), isInDeadSpaceBand(point),
           Self.isDeadSpace(cursor: NSCursor.current, interactive: hoverIsInteractive || hoverIsMedia) {
            Log.write("page kept a press in the band: \(url?.host() ?? "?"), "
                + (pageAnswer?.hover == hoverReports ? "it uses it" : "no answer yet"))
        }
        super.mouseDown(with: event)
    }

    /// A press on a video's picture that has not yet said what it is. See `mouseDown`.
    private var pendingVideoPress: NSEvent?

    /// How far the pointer has to move, in points, before a press on a video is a drag. Past a click's
    /// natural wobble and under the distance anyone drags a window on purpose.
    static let videoDragSlop: CGFloat = 4

    override func mouseDragged(with event: NSEvent) {
        guard let press = pendingVideoPress else { return super.mouseDragged(with: event) }
        let a = press.locationInWindow, b = event.locationInWindow
        guard hypot(b.x - a.x, b.y - a.y) >= Self.videoDragSlop, let window else { return }
        pendingVideoPress = nil
        Log.write("window drag from a video: \(url?.host() ?? "?")")
        window.performDrag(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        // Never moved: it was a click, so the page gets it now, down and up together.
        guard let press = pendingVideoPress else { return super.mouseUp(with: event) }
        pendingVideoPress = nil
        super.mouseDown(with: press)
        super.mouseUp(with: event)
    }

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
    /// card beside it. Except on a tile's edges and tab strip, which are the tiling's
    /// (`CanvasPageDropClaim`): a note dropped there goes up beside the page.
    ///
    /// Only the board is crossed in and out of here. The page is entered once and kept entered for as
    /// long as the drag is over this view, because it has to go on being asked: the pointer moves onto
    /// a drop target and off it again, and a page that had been told the drag left would answer for a
    /// drag it no longer believes in. Answering `.copy` and then `.none` on the way to the real answer
    /// is also why the board can be given a drag, lose it and be given it back within a few frames —
    /// each of those is a real crossing, and it is told about all of them.
    private func route(_ sender: NSDraggingInfo) -> NSDragOperation {
        // A row from a frame's sidebar is about the tiles, never the page: it would otherwise be offered
        // to the page as the link it carries.
        if dropFallback != nil, SpaceRowDrag.isRow(sender) {
            leavePage(sender)
            let crossing = holder != .fallback
            holder = .fallback
            return (crossing ? dropFallback?.draggingEntered(sender) : dropFallback?.draggingUpdated(sender)) ?? []
        }
        // ⌥ with a file the page can show: the file becomes the page. Decided before the page is asked
        // anything, since the answer is ours whatever the page would have said.
        if linkHost != nil, NSEvent.modifierFlags.contains(.option), Self.loadableFile(in: sender) != nil {
            if holder == .fallback { dropFallback?.draggingExited(sender) }
            leavePage(sender)
            holder = .load
            return .link
        }
        // **A tile's edges and tab strip are the tiling's**, so a note dragged there goes up beside the
        // page or into its tabs rather than into it — the middle is still the page's, files and all.
        // Not a drag the page started: its own reorders and text drags reach its edges too.
        if let fallback = dropFallback, (sender.draggingSource as AnyObject?) !== self,
           (fallback as? CanvasPageDropClaim)?.claimsDrop(sender) == true {
            leavePage(sender)
            let crossing = holder != .fallback
            holder = .fallback
            return crossing ? fallback.draggingEntered(sender) : fallback.draggingUpdated(sender)
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

    // MARK: Frame rate

    /// Whether the page draws at the display's full rate — 120 Hz on ProMotion — rather than WebKit's
    /// default of about 60. On for the card you have stepped into, off for the rest.
    ///
    /// - WebKit's `PreferPageRenderingUpdatesNear60FPSEnabled` feature is on by default in a `WKWebView`,
    ///   as in Safari. Figma in a card ran at 60 fps; its desktop app and Chrome run at 120.
    /// - Measured 2026-09-30 on an M1 Max at 120 Hz: an animating page at 60 fps cost 8% GPU process
    ///   and 7% web process; at 120, 15% and 12%. Pages that aren't animating draw nothing either way.
    /// - Private API (`WKPreferences._features`, `_setEnabled:forFeature:`). Checked with
    ///   `responds(to:)`; missing, pages stay at 60.
    /// - The setter takes a `BOOL`. `perform(_:with:with:)` passes an `NSNumber` pointer, which reads
    ///   as true whatever its value — hence the typed call.
    static func setFullFrameRate(_ on: Bool, in preferences: WKPreferences) {
        guard let feature = near60Feature else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool, AnyObject) -> Void
        let setter = unsafeBitCast(preferences.method(for: setEnabled), to: Setter.self)
        setter(preferences, setEnabled, !on, feature)
    }

    private static let setEnabled = NSSelectorFromString("_setEnabled:forFeature:")

    private static let near60Feature: NSObject? = {
        let list = NSSelectorFromString("_features")
        guard WKPreferences.responds(to: list), WKPreferences.instancesRespond(to: setEnabled),
              let features = (WKPreferences.self as AnyObject).perform(list)?.takeUnretainedValue()
                as? [NSObject]
        else { return nil }
        return features.first { ($0.value(forKey: "key") as? String) == "PreferPageRenderingUpdatesNear60FPSEnabled" }
    }()

    /// Change the frame rate of the page already running.
    ///
    /// - A running page ignores the preference until its throttling is recomputed, which on macOS
    ///   means a visibility change. A resize, a reparent, a screen-change notification or
    ///   `_suspendPage:` doesn't do it.
    /// - Really hiding the view does, but takes first responder: the page gets `blur`, so a Figma
    ///   text edit you had just clicked into would end.
    /// - So the view says it is hidden (`isHiddenOrHasHiddenAncestor`) and tells WebKit, for one
    ///   frame. Nothing is hidden: first responder, focus and the layers are untouched. The page sees
    ///   `visibilitychange` to hidden and back, as on a Safari tab switch.
    /// - Measured: 60.6 → 120.6 fps and back, and the focused `<input>` kept focus.
    func setFullFrameRate(_ on: Bool) {
        guard on != fullFrameRate else { return }
        fullFrameRate = on
        Self.setFullFrameRate(on, in: configuration.preferences)
        pulseWhenReleased()
    }

    /// The frame of "hidden" that makes WebKit read the new rate — but never under a held button.
    ///
    /// Stepping into a tile happens on the press (`CanvasBoardView.tileClicked`, which listens before
    /// the press is delivered), so a pulse then hid the page for exactly the frame the press arrived
    /// in, and WebKit dropped it: the first click on a tile in a layout did nothing but focus it. The
    /// rate itself is set at once; the pulse waits for the button to come up.
    ///
    /// **And then for the page to have heard it come up.** The button being up is the hardware; the
    /// release is still in WebKit's queue until the page has answered the press, and a page slow to
    /// answer (Figma, picking up a layer) was hidden before the release reached it. The page dropped
    /// the release and went on holding the layer: a drag nobody was making, deaf to Escape, until the
    /// next click put it down (2026-11-10).
    private func pulseWhenReleased() {
        pulseWait?.invalidate()
        pulseWait = nil
        pulseTicket += 1
        guard Self.buttonHeld() else { return pulseOnceInputIsHandled() }
        let wait = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard !Self.buttonHeld() else { return }
                timer.invalidate()
                self?.pulseWait = nil
                self?.pulseOnceInputIsHandled()
            }
        }
        RunLoop.main.add(wait, forMode: .common)
        pulseWait = wait
    }

    /// Pulse once WebKit has no mouse event left to hand the page. A press that started meanwhile
    /// sends it back to waiting for the button.
    private func pulseOnceInputIsHandled() {
        let ticket = pulseTicket
        Self.afterPendingMouseEvents(self) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, ticket == self.pulseTicket else { return }
                if Self.buttonHeld() { return self.pulseWhenReleased() }
                self.pulse()
            }
        }
    }

    /// Bumped by each request, so only the latest one's wait ends in a pulse.
    private var pulseTicket = 0

    private var pulseWait: Timer?

    /// Whether the left button is down. Read from the hardware, so tests stand in for it.
    static var buttonHeld: () -> Bool = { NSEvent.pressedMouseButtons & 0x1 != 0 }

    /// Run `then` once the page has handled every mouse event WebKit is holding for it.
    /// - WebKit's `_doAfterProcessingAllPendingMouseEvents:` (private; Safari's tests use it).
    /// - Missing: the next turn of the run loop, which is what the pulse had before.
    /// - Tests stand in for it.
    static var afterPendingMouseEvents: (WKWebView, @escaping () -> Void) -> Void = { view, then in
        let selector = NSSelectorFromString("_doAfterProcessingAllPendingMouseEvents:")
        guard view.responds(to: selector) else { return DispatchQueue.main.async(execute: then) }
        typealias Call = @convention(c) (AnyObject, Selector, @escaping @convention(block) () -> Void) -> Void
        unsafeBitCast(view.method(for: selector), to: Call.self)(view, selector, then)
    }

    private func pulse() {
        guard window != nil, !super.isHiddenOrHasHiddenAncestor, !reportsHidden else { return }
        reportsHidden = true
        viewDidHide()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) { [weak self] in
            guard let self, reportsHidden else { return }
            reportsHidden = false
            viewDidUnhide()
        }
    }

    /// Whether the page is at full frame rate: what it was built with, then what `setFullFrameRate`
    /// last set. Whoever builds the view with `setFullFrameRate(_:in:)` records it here.
    var fullFrameRate = false

    /// True for the frame `setFullFrameRate` spends telling WebKit the page is hidden.
    private var reportsHidden = false

    override var isHiddenOrHasHiddenAncestor: Bool { reportsHidden || super.isHiddenOrHasHiddenAncestor }

    // MARK: Pointer lock

    /// Whether the page has the pointer — a game or a 3D view that asked for raw mouse movement. Kept by
    /// the card as WebKit grants and ends it; see `CanvasLinkNodeView`'s pointer-lock delegate methods.
    var holdsPointer = false

    /// Whether the Escape now walking up the responder chain is WebKit's: the one that took the pointer
    /// back, or the one that took a video out of full screen.
    private var escapeWasWebKits = false

    /// Note an Escape that is about to end a pointer lock or full screen, before WebKit ends it.
    ///
    /// Asked here because it can't be asked afterwards: WebKit releases the pointer inside this call,
    /// synchronously, so by the time the key comes back up the chain the lock is already gone. Set on
    /// every key rather than only on Escape, so a page that swallows its Escape can't leave the flag
    /// standing for the next one.
    override func keyDown(with event: NSEvent) {
        escapeWasWebKits = (holdsPointer || fullscreenState != .notInFullscreen) && event.keyCode == 53
        super.keyDown(with: event)
    }

    /// **Escape out of a pointer lock, or out of a full-screen video, does that and nothing more.** The page hands the key back as it
    /// hands back any Escape it didn't want, and walked on up it steps out of the card, or out of the
    /// tile — two things at once for one press, and the second one is what nobody meant. Every browser
    /// stops at the first. The Escape after that is the card's as it always was.
    ///
    /// Passed on rather than `super`: `NSView` doesn't implement `cancelOperation:` — see
    /// `CanvasNodeView.cancelOperation`.
    override func cancelOperation(_ sender: Any?) {
        guard !escapeWasWebKits else {
            escapeWasWebKits = false
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

    /// Whether the press at `point`, in this view's coordinates, is the page's — so not dead space,
    /// whatever the cursor. What WebKit's cursor and hover report miss:
    ///
    /// - **Controls that keep the arrow.** Figma's toolbar buttons don't set `cursor: pointer`, and the
    ///   hover report only knows links, images, media and fields. So: a `button`, form control,
    ///   `summary`, `label`, an ARIA widget role, a `tabindex` of 0 or more (-1 is what apps put on
    ///   whole layout containers), `draggable`, `contenteditable`, or an inline `onclick`, on the
    ///   element or any ancestor.
    /// - **Surfaces the page draws its own UI on**: `canvas` (Figma's board), `iframe`, `video`,
    ///   `embed`, `object`.
    /// - **A box floating over the page.** Figma's Variables panel is dragged by a header that is
    ///   blank, arrow-cursored and near the top: a `dialog`, `role=dialog`/`alertdialog`, `aria-modal`,
    ///   or a fixed or absolute box with a gap to the viewport on its left, its right and its top. A
    ///   site's header touches at least one of those, as Apple Music's does beside its sidebar.
    ///
    /// The same world and shadow-root walk as `link(at:)`. A page that can't answer (no document yet)
    /// says it uses the press.
    func pageUses(at point: NSPoint) async -> Bool {
        await press(at: point) != .dead
    }

    /// What a press at `point` lands on: the page's own control, nothing, or the picture of a video.
    ///
    /// **A video is neither of the first two.** Its picture is blank in the sense dead space means — no
    /// button, nothing to select — but a click on it is how a player pauses, and a double-click how it
    /// goes full screen, so a press cannot be given to the window outright. See `mouseDown`, which
    /// holds a press on one until it is known whether it is a click or the start of a drag.
    ///
    /// A video counts only above the strip along its foot where players put their controls
    /// (`deadSpaceBand`, as at the top of a page), and an ancestor that merely holds the video — a
    /// player's `tabindex=0` wrapper, which is how it takes the space bar — is not a control.
    enum Press: String { case page, dead, video }

    func press(at point: NSPoint) async -> Press {
        let scale = pageZoom * magnification
        guard scale > 0 else { return .page }
        let y = isFlipped ? point.y : bounds.height - point.y
        let answer = try? await callAsyncJavaScript(Self.usesScript,
                                                    arguments: ["x": point.x / scale, "y": y / scale,
                                                                "band": Self.deadSpaceBand],
                                                    in: nil, contentWorld: .defaultClient)
        return (answer as? String).flatMap(Press.init(rawValue:)) ?? .page
    }

    private static let usesScript = """
        let el = document.elementFromPoint(x, y);
        if (!el) return 'page';
        while (el.shadowRoot) {
            const inner = el.shadowRoot.elementFromPoint(x, y);
            if (!inner || inner === el) break;
            el = inner;
        }
        const used = 'button, input, select, textarea, summary, label, a[href], canvas, iframe, '
            + 'embed, object, [tabindex]:not([tabindex^="-"]), [draggable="true"], [contenteditable=""], '
            + '[contenteditable="true"], [onclick], [role="button"], [role="link"], [role="menuitem"], '
            + '[role="menuitemcheckbox"], [role="menuitemradio"], [role="tab"], [role="checkbox"], '
            + '[role="radio"], [role="switch"], [role="option"], [role="slider"], [role="combobox"], '
            + '[role="textbox"], [role="spinbutton"], [role="treeitem"], [role="gridcell"]';
        const floating = 'dialog, [role="dialog"], [role="alertdialog"], [aria-modal="true"]';
        const width = document.documentElement.clientWidth;
        // The video under the point, above the strip along its foot where a player keeps its controls.
        const video = [...document.querySelectorAll('video')].find(v => {
            const r = v.getBoundingClientRect();
            return r.width >= 200 && r.height >= 100 && x >= r.left && x <= r.right
                && y >= r.top && y <= r.bottom - band;
        });
        const holds = n => video && (n === video || n.contains(video));
        for (let n = el; n; n = n.parentElement || (n.getRootNode().host ?? null)) {
            if (n === document.documentElement || n === document.body) break;
            if (n.matches('video')) { if (video) continue; return 'page'; }
            if (n.matches(used) && !holds(n)) return 'page';
            if (n.matches(floating)) return 'page';
            const position = getComputedStyle(n).position;
            if ((position === 'fixed' || position === 'absolute') && !holds(n)) {
                const r = n.getBoundingClientRect();
                const v = video && video.getBoundingClientRect();
                // A layer laid over the whole picture is the player's, not a panel floating on a page.
                const coversVideo = v && r.left <= v.left + 1 && r.right >= v.right - 1
                    && r.top <= v.top + 1 && r.bottom >= v.bottom - 1;
                if (!coversVideo && r.left > 1 && r.right < width - 1 && r.top > 1) return 'page';
            }
        }
        return video ? 'video' : 'dead';
        """

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
