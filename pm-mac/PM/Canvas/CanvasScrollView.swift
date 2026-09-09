import AppKit
import PmLib

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

    deinit { NotificationCenter.default.removeObserver(self) }

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
        guard !board.isTiled else { return }
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
        guard !board.isTiled else { return }
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
        board.refreshNodeViews()
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
        board.refreshNodeViews()
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
        guard !board.isTiled, let cards = board.document.bounds else { return board.frame }
        return board.viewRect(cards)
    }
}
