import AppKit
import PmLib
import QuartzCore

/// The scroller a board sits in, and everything about zoom.
///
/// `NSScrollView` already does the hard parts — momentum panning, pinch magnification anchored at the
/// pointer, live resize — so this adds only what it doesn't: telling the board when the zoom or the
/// visible region changed, so cards can be built and dropped and screen-sized details redrawn.
///
/// Scrolling is *not* the same as zooming here, and both gestures are wanted. A plain two-finger
/// scroll pans, which is what a trackpad does everywhere else on a Mac; ⌘-scroll and pinch zoom. That
/// split is AppKit's default behaviour and is left alone deliberately — a canvas that zoomed on a bare
/// scroll would be a canvas you cannot pan.
@MainActor
final class CanvasScrollView: NSScrollView {
    private(set) var board: CanvasBoardView!

    /// How far in and out a board goes. The bottom is where a large board fits on a screen; the top is
    /// where you are reading one card and nothing else.
    static let minimumZoom: CGFloat = 0.08
    static let maximumZoom: CGFloat = 3

    init(store: CanvasDocumentStore) {
        super.init(frame: .zero)
        board = CanvasBoardView(store: store, scrollView: self)

        // Before anything reads `contentView` below, and before the board goes in: replacing the clip
        // resets the scroll position, so it has to be the first thing that happens.
        contentView = CanvasClipView()
        documentView = board
        hasVerticalScroller = true
        hasHorizontalScroller = true
        autohidesScrollers = true
        allowsMagnification = true
        minMagnification = Self.minimumZoom
        maxMagnification = Self.maximumZoom
        // The board paints its own ground, including the region beyond the content, so the scroll
        // view must not paint underneath it — an elastic overscroll would otherwise flash the window
        // background at the edges of a board.
        drawsBackground = true
        backgroundColor = CanvasPalette.board
        // The board runs under the titlebar, because the window has a full-size content view and its
        // chrome floats over the board rather than sitting above it. Left on, AppKit would inset the
        // content by the titlebar's height to keep it clear — which is the right default for a document
        // you scroll and exactly wrong for one the window is deliberately laid over.
        automaticallyAdjustsContentInsets = false
        contentView.postsBoundsChangedNotifications = true

        contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(visibleRegionChanged),
            name: NSView.boundsDidChangeNotification, object: contentView)
        NotificationCenter.default.addObserver(
            self, selector: #selector(clipResized),
            name: NSView.frameDidChangeNotification, object: contentView)
        NotificationCenter.default.addObserver(
            self, selector: #selector(zoomChanged),
            name: NSScrollView.didEndLiveMagnifyNotification, object: self)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// The window changed size. A tiled view has to be laid out again for the shape it is now filling —
    /// see `CanvasBoardView.retileForWindowSize`.
    @objc private func clipResized() {
        guard board.isTiled else { return }
        board.retileForWindowSize()
    }

    /// A tiled view is a fixed view of a fixed set of cards, so the board underneath it does not move.
    ///
    /// Panning or zooming would slide the tiles out of the window they were laid out to fill, and the
    /// only way back would be to leave and come in again. Every tiling window manager takes the same
    /// position: while windows are tiled, the desktop is not something you scroll. Swallowed here rather
    /// than by turning scrolling off, so a wheel over a card's own content still reaches it — an engaged
    /// card takes the event long before this view is asked, and an unengaged one is handed it by the
    /// board on the way past (`CanvasBoardView.scrollWheel`). Tiled or not, a card scrolls.
    override func scrollWheel(with event: NSEvent) {
        // Picking cards on the board is the board, and scrolls like it — see `CanvasBoardView.showsTiles`.
        guard !board.showsTiles else { return }
        guard !event.modifierFlags.contains(.command) else { return zoom(with: event) }
        super.scrollWheel(with: event)
    }

    /// ⌘ and the wheel zooms, about the pointer.
    ///
    /// Written out rather than inherited: `allowsMagnification` buys the pinch and the double-tap and
    /// nothing else, so on a mouse there was no way to zoom a board at all short of the menu. Every
    /// canvas a person arrives here from — Obsidian's, Figma's, a browser's PDF view — puts it on
    /// ⌘-wheel, and the board already swallows the modifier so no card takes it first.
    ///
    /// About the pointer, not the middle of the window, which is the whole difference between zooming
    /// and zooming *in on something*: the card you are pointing at stays under the pointer, so you can
    /// go from the whole board to one card in a single gesture without chasing it back into the window.
    private func zoom(with event: NSEvent) {
        // A notch of a wheel is a step; a trackpad reports a distance, and about a finger's width of it
        // is worth the same step. Multiplied rather than added, because zoom is a ratio — 10% of the
        // way in from 20% and from 200% have to feel like the same gesture.
        let steps = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 40 : event.scrollingDeltaY
        guard steps != 0 else { return }
        let wanted = min(max(magnification * pow(1.15, steps), Self.minimumZoom), Self.maximumZoom)
        guard wanted != magnification else { return }
        setMagnification(wanted, centeredAt: board.convert(event.locationInWindow, from: nil))
        settleZoom()
    }

    private var zoomSettle: DispatchWorkItem?

    /// Re-render the cards for the zoom you stopped at.
    ///
    /// Deferred for the same reason AppKit defers it during a pinch — and this is the one place the
    /// difference matters, because a wheel has no "end of gesture" to hang it on. Magnification alone
    /// is free: the cards are subviews of the board, so the scroll view scales them where they stand.
    /// What costs is deciding which of them are worth building and how much detail each should draw,
    /// and that is a question about the zoom you settled on rather than every one you passed through.
    private func settleZoom() {
        zoomSettle?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            board.magnificationChanged()
            board.settlePageBudget()
        }
        zoomSettle = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    override func magnify(with event: NSEvent) {
        guard !board.showsTiles else { return }
        super.magnify(with: event)
    }

    /// Whether the scrollers exist at all — off while tiled.
    ///
    /// `autohidesScrollers` is not enough, because it answers "does the content fit", and the board
    /// under a tiling is still the whole board: several screens wide, with the tiles laid over the part
    /// of it you happen to be at. So by that test the content does *not* fit and the scrollers are
    /// entitled to appear — and overlay scrollers flash themselves whenever the clip view resizes,
    /// which is to say on every frame of a window drag.
    ///
    /// What they flash is doubly wrong. They are the controls for a gesture that is deliberately
    /// swallowed here (see `scrollWheel`), so they mark a range you cannot move through; and they mark
    /// it against the board's extent rather than the tiling's, which has no extent — the tiles are
    /// exactly the window. Removing them says the true thing: while tiled, there is nowhere else.
    func showsScrollers(_ shows: Bool) {
        hasVerticalScroller = shows
        hasHorizontalScroller = shows
    }

    @objc private func visibleRegionChanged() {
        // Build what has come into reach; place nothing. Scrolling moves the board, not the cards on
        // it — see `CanvasBoardView.refreshVisibleCards`.
        board.refreshVisibleCards()
        // Which pages are worth running is a question about where you stopped, not about every frame
        // of the scroll that got you there.
        board.settlePageBudget()
    }

    @objc private func zoomChanged() {
        board.magnificationChanged()
        board.settlePageBudget()
    }

    // MARK: Zooming on purpose

    /// Zoom by a step, about the middle of what you can see — which is what a menu item or a keyboard
    /// shortcut means by zoom, as opposed to a pinch, which is about the fingers.
    func zoom(by factor: CGFloat) {
        let centre = NSPoint(x: documentVisibleRect.midX, y: documentVisibleRect.midY)
        setMagnification(min(max(magnification * factor, Self.minimumZoom), Self.maximumZoom),
                         centeredAt: centre)
        board.magnificationChanged()
    }

    /// Fit a particular region in the window — a frame you have stepped to, rather than the whole board.
    func zoom(toFit rect: CanvasRect) {
        guard rect.width > 0, rect.height > 0 else { return }
        let available = contentView.bounds.size
        let wanted = min(Self.maximumZoom,
                         max(Self.minimumZoom,
                             min(available.width / rect.width, available.height / rect.height)))
        magnification = wanted
        board.magnificationChanged()
        centre(on: CanvasPoint(x: rect.midX, y: rect.midY))
    }

    /// `zoom(toFit:)` as a journey: ease to the zoom that fits `rect` in the window — never past 100% —
    /// centred on it. How a workspace zooms out to the board to pick its cards.
    func fly(toFit rect: CanvasRect, animated: Bool) {
        let available = contentView.frame.size
        guard rect.width > 0, rect.height > 0, available.width > 0, available.height > 0 else { return }
        let zoom = min(1, available.width / rect.width, available.height / rect.height)
        fly(to: max(zoom, Self.minimumZoom), centre: CanvasPoint(x: rect.midX, y: rect.midY),
            animated: animated)
    }

    func zoomToActualSize() { setZoom(1) }

    /// Go to a particular zoom, about the middle of what you can see.
    ///
    /// Public because a tiled view sets it: tiles are laid out to fill the window, and a board at 40%
    /// would fill it with cards whose text is at 40% — a fullscreen card you still cannot read. Entering
    /// a tiling puts the board at 100% and leaving puts it back; see `CanvasBoardView.tile`.
    func setZoom(_ zoom: CGFloat) {
        let centre = NSPoint(x: documentVisibleRect.midX, y: documentVisibleRect.midY)
        setMagnification(min(max(zoom, Self.minimumZoom), Self.maximumZoom), centeredAt: centre)
        board.magnificationChanged()
    }

    /// Ease to a zoom *and* a place at once, which is what crossing into or out of a workspace is.
    ///
    /// **Both, together, on one clock.** Entering a workspace puts the board at 100% and leaving hands
    /// back the zoom you were at — a change the board used to make in the frame the key was pressed, on
    /// the honest grounds that the alternative was two animations disagreeing. See
    /// `CanvasBoardView.leaveTiling`, whose "the view first, then the cards" note is about exactly that
    /// hazard. What made it safe is that the two are set here in the same step of the same timer, so
    /// there is one answer per frame to where the board is and how big it is drawn.
    ///
    /// **The zoom travels as a ratio**, not as a distance: 40% to 100% and 100% to 250% are the same
    /// gesture, and interpolating linearly makes the first half of a zoom-in crawl and the second half
    /// lurch. This is the same argument `zoom(with:)` makes about a wheel notch.
    ///
    /// The cards are flying at the same time, on Core Animation's clock rather than this one — see
    /// `CanvasBoardView.settleIntoLayout`. Two clocks, and safely: this one decides how the board is
    /// scaled and where it is, that one decides where each card is *on* the board, and neither is
    /// trying to answer the other's question. What must never be split across the two is a single
    /// number, which is what `HeaderChromeMotionTests` is about at the other end of the window.
    func fly(to zoom: CGFloat, centre point: CanvasPoint, animated: Bool) {
        ticker.stop()
        flight = nil
        let wanted = min(max(zoom, Self.minimumZoom), Self.maximumZoom)
        let seconds = animated ? Motion.duration(0.3) : 0
        let from = magnification
        let at = board.canvasPoint(NSPoint(x: documentVisibleRect.midX, y: documentVisibleRect.midY))
        // **On the display's clock**, rather than a `Timer` at 1/60, and read from it rather than
        // counted up: this runs at the same moment as `CanvasFade`'s crossing and as the cards' own
        // Core Animation group, and three animations describing one movement have to agree about what
        // time it is or the zoom arrives from a slightly different instant than the cards do. See
        // `DisplayTicker`.
        //
        // A view with no screen to tick against has nothing to animate in front of, and arrives
        // outright down the same path Reduce Motion and a zero distance take — and so, under
        // `CrossingTuning`, does a run measuring what the zoom flight costs.
        let flies = !CrossingTuning.current.contains(.skipZoomFlight)
        if flies, seconds > 0, from != wanted || at != point, board.layer != nil,
           CrossingTuning.current.contains(.zoomAsTransform) {
            return flyByTransform(from: from, at: at, to: wanted, centre: point, seconds: seconds)
        }
        guard flies, seconds > 0, from != wanted || at != point, ticker.start(on: self) else {
            magnification = wanted
            centre(on: point)
            board.magnificationChanged()
            return
        }
        flight = Flight(from: from, to: wanted, at: at, centre: point,
                        startedAt: CACurrentMediaTime(), seconds: seconds)
    }

    /// The crossing currently under way, if one is. Held so a second one takes over cleanly rather than
    /// fighting the first for the magnification.
    private var flight: Flight?

    private struct Flight {
        var from: CGFloat
        var to: CGFloat
        /// Where the board is looking now, and where it is going.
        var at: CanvasPoint
        var centre: CanvasPoint
        var startedAt: CFTimeInterval
        var seconds: Double
    }

    private lazy var ticker = DisplayTicker { [weak self] now in self?.stepFlight(at: now) }

    private func stepFlight(at now: CFTimeInterval) {
        guard let flight else { return ticker.stop() }
        let fraction = min(1, max(0, (now - flight.startedAt) / flight.seconds))
        // Ease out, matching the curve the cards are flying on closely enough that the two read as one
        // movement. Not the spring: the board overshooting its zoom would show as the whole window
        // breathing, which is a much larger claim than a card landing.
        let eased = 1 - pow(1 - fraction, 3)
        magnification = flight.from * pow(flight.to / flight.from, CGFloat(eased))
        centre(on: CanvasPoint(x: flight.at.x + (flight.centre.x - flight.at.x) * eased,
                               y: flight.at.y + (flight.centre.y - flight.at.y) * eased))
        guard fraction >= 1 else { return }
        ticker.stop()
        self.flight = nil
        // Once, at the end. Deciding which cards are worth building and how much detail each draws is
        // a question about the zoom you arrived at — the same reason `settleZoom` defers it after a
        // wheel.
        board.magnificationChanged()
        board.settlePageBudget()
    }

    /// The flight as a layer transform — `CrossingTuning.zoomAsTransform`.
    ///
    /// **Arrive first, then pretend you haven't.** The magnification is set once, which is one rescale
    /// of everything under the clip rather than one per frame, and the board is then drawn with a
    /// counter-transform that makes it look exactly as it did before — the old region at the old zoom —
    /// which Core Animation eases back to identity on the render server. Nothing re-renders to travel;
    /// the pages are rescaled once, at the destination, and the page budget and the card building are
    /// asked their question once rather than twenty-two times.
    ///
    /// **The transform is written about the layer's anchor**, which is where a first version went
    /// wrong: a transform is applied around the anchor point, so one composed in view coordinates lands
    /// offset by it unless it is conjugated as it is here.
    private func flyByTransform(from: CGFloat, at: CanvasPoint, to wanted: CGFloat,
                                centre point: CanvasPoint, seconds: Double) {
        ticker.stop()
        flight = nil
        magnification = wanted
        centre(on: point)
        board.magnificationChanged()
        board.settlePageBudget()
        guard let layer = board.layer else { return }

        // Where the board is looking now, and where it was looking, in the board's own points — which
        // do not change with the zoom (`CanvasBoardView.viewRect`), so both are measurable after the
        // jump.
        let source = board.viewPoint(at)
        let destination = board.viewPoint(point)
        let scale = from / wanted
        let asItWas = CGAffineTransform(translationX: -source.x, y: -source.y)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: destination.x, y: destination.y))
        let anchor = CGPoint(x: layer.anchorPoint.x * layer.bounds.width,
                             y: layer.anchorPoint.y * layer.bounds.height)
        let start = CGAffineTransform(translationX: anchor.x, y: anchor.y)
            .concatenating(asItWas)
            .concatenating(CGAffineTransform(translationX: -anchor.x, y: -anchor.y))

        transformingUntil = CACurrentMediaTime() + seconds
        let travel = CABasicAnimation(keyPath: "transform")
        travel.fromValue = CATransform3DMakeAffineTransform(start)
        travel.toValue = CATransform3DIdentity
        travel.duration = seconds
        // The same ease-out the ticked flight uses, so the two configurations are the same movement
        // measured two ways rather than two movements.
        travel.timingFunction = CAMediaTimingFunction(name: .easeOut)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.setAffineTransform(.identity)
        layer.add(travel, forKey: "canvasFlight")
        CATransaction.commit()
    }

    /// When a transform flight is due to land, so `isFlying` can answer for it as well. Left set
    /// afterwards rather than cleared on a timer: it is a time in the past, which answers false.
    private var transformingUntil: CFTimeInterval?

    /// Whether the board is mid-crossing. Nothing may re-lay a tiling out while it is — see
    /// `CanvasBoardView.retileForWindowSize`.
    var isFlying: Bool {
        if flight != nil { return true }
        guard let transformingUntil else { return false }
        return CACurrentMediaTime() < transformingUntil
    }

    /// Fit the whole board in the window — ⌘0, and what a window does when it opens.
    ///
    /// Never magnifies past 1: a board with three cards on it fitted to a large window would draw them
    /// at 400%, which is not "fit", it's "fill". Fit means you can see everything, and seeing
    /// everything at its true size is better than seeing it enormous.
    ///
    /// **Answers whether it fitted**, because it cannot always: asked before the pane has been laid
    /// out there is no window to fit anything to, and there is no honest answer to give — the old one
    /// was to return quietly, which reads at the call site as a fit that happened. It did not, and the
    /// board was left at the origin of its own frame: 1600pt of margin above and left of every card,
    /// which is canvas-backlog item 1's "opens panned into a corner" exactly. See
    /// `CanvasPaneController.fitWhenThereIsAWindowToFitTo`, which now waits for a true.
    @discardableResult
    func zoomToFit() -> Bool {
        let visible = contentView.frame.size
        guard visible.width > 0, visible.height > 0 else { return false }
        // Nothing to fit is not a failure — but a board of no cards still has a middle, and starting
        // at the corner of 1600pt of blank is no better here than anywhere else.
        guard let bounds = board.document.bounds else {
            setZoom(1)
            centre(on: CanvasPoint(x: board.content.midX, y: board.content.midY))
            return true
        }
        let padded = bounds.inset(by: 60)
        guard padded.width > 0, padded.height > 0 else { return false }

        let scale = min(visible.width / padded.width, visible.height / padded.height, 1)
        magnification = max(scale, Self.minimumZoom)
        centre(on: CanvasPoint(x: padded.midX, y: padded.midY))
        board.magnificationChanged()
        return true
    }

    /// Put a point on the board in the middle of the window — how ⌘F frames what it found.
    func centre(on point: CanvasPoint) {
        let at = board.viewPoint(point)
        let visible = documentVisibleRect.size
        board.scroll(NSPoint(x: at.x - visible.width / 2, y: at.y - visible.height / 2))
        reflectScrolledClipView(contentView)
        // No refresh here: moving the clip posts a bounds change, and `visibleRegionChanged` answers
        // it. Asking as well meant every frame of a flight rebuilt and re-laid the board twice.
    }

    /// Frame a card: centred, and zoomed in if it was too small to read.
    func reveal(_ id: String) {
        guard let node = board.document.node(id: id) else { return }
        if magnification < 0.5 {
            magnification = 0.75
            board.magnificationChanged()
        }
        centre(on: CanvasPoint(x: node.frame.midX, y: node.frame.midY))
    }
}

/// The clip a board scrolls inside, for the one thing `NSClipView` will not do by itself: let you pan
/// a board that fits.
///
/// The rule itself is `CanvasPanBounds`, which is arithmetic on two rectangles and is tested as such.
/// All this does is decide which two, and take `NSClipView`'s own answer when the rule has no opinion.
@MainActor
final class CanvasClipView: NSClipView {
    override func constrainBoundsRect(_ proposed: NSRect) -> NSRect {
        guard let held, let constrained = CanvasPanBounds.constrain(proposed, holding: held)
        else { return super.constrainBoundsRect(proposed) }
        return constrained
    }

    /// What has to stay in the window, in the board's own coordinates: **the cards, not the board.**
    ///
    /// The two are a long way apart. A board's frame is its cards' extent grown by
    /// `CanvasBoardView.margin` on every side, so the frame rule was satisfied by a window of blank
    /// paper 1600pt from anything — you were still "on the board", and there was nothing on screen to
    /// tell you which way the board was. Holding a card instead means a pan always leaves you
    /// something to steer by, and costs nothing you wanted: a sliver of card at one edge still leaves
    /// the rest of the window empty to spread into.
    ///
    /// A tiled view is exempt. Its position is not panned, it is *laid out* — the tiles were fitted to
    /// the window and the wheel is swallowed rather than obeyed (`CanvasScrollView.scrollWheel`), so
    /// the one thing the rule must not do there is move the clip out from under them.
    private var held: NSRect? {
        guard let board = documentView as? CanvasBoardView else { return documentView?.frame }
        guard !board.showsTiles, let cards = board.document.bounds else { return board.frame }
        return board.viewRect(cards)
    }
}
