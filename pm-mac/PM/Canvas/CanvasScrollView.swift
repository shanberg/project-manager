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

    var onZoomChanged: ((CGFloat) -> Void)?

    init(store: CanvasDocumentStore) {
        super.init(frame: .zero)
        board = CanvasBoardView(store: store, scrollView: self)

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
        contentView.postsBoundsChangedNotifications = true

        NotificationCenter.default.addObserver(
            self, selector: #selector(visibleRegionChanged),
            name: NSView.boundsDidChangeNotification, object: contentView)
        NotificationCenter.default.addObserver(
            self, selector: #selector(zoomChanged),
            name: NSScrollView.didEndLiveMagnifyNotification, object: self)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func visibleRegionChanged() {
        board.refreshNodeViews()
        // Which pages are worth running is a question about where you stopped, not about every frame
        // of the scroll that got you there.
        board.settlePageBudget()
    }

    @objc private func zoomChanged() {
        board.magnificationChanged()
        board.settlePageBudget()
        onZoomChanged?(magnification)
    }

    // MARK: Zooming on purpose

    /// Zoom by a step, about the middle of what you can see — which is what a menu item or a keyboard
    /// shortcut means by zoom, as opposed to a pinch, which is about the fingers.
    func zoom(by factor: CGFloat) {
        let centre = NSPoint(x: documentVisibleRect.midX, y: documentVisibleRect.midY)
        setMagnification(min(max(magnification * factor, Self.minimumZoom), Self.maximumZoom),
                         centeredAt: centre)
        board.magnificationChanged()
        onZoomChanged?(magnification)
    }

    func zoomToActualSize() {
        let centre = NSPoint(x: documentVisibleRect.midX, y: documentVisibleRect.midY)
        setMagnification(1, centeredAt: centre)
        board.magnificationChanged()
        onZoomChanged?(magnification)
    }

    /// Fit the whole board in the window — ⌘0, and what a window does when it opens.
    ///
    /// Never magnifies past 1: a board with three cards on it fitted to a large window would draw them
    /// at 400%, which is not "fit", it's "fill". Fit means you can see everything, and seeing
    /// everything at its true size is better than seeing it enormous.
    func zoomToFit() {
        guard let bounds = board.document.bounds else { return zoomToActualSize() }
        let padded = bounds.inset(by: 60)
        let visible = contentView.frame.size
        guard padded.width > 0, padded.height > 0, visible.width > 0, visible.height > 0 else { return }

        let scale = min(visible.width / padded.width, visible.height / padded.height, 1)
        magnification = max(scale, Self.minimumZoom)
        centre(on: CanvasPoint(x: padded.midX, y: padded.midY))
        board.magnificationChanged()
        onZoomChanged?(magnification)
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
            onZoomChanged?(magnification)
        }
        centre(on: CanvasPoint(x: node.frame.midX, y: node.frame.midY))
    }
}
