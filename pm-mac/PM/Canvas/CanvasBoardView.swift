import AppKit
import PmLib

/// The board: an infinite plane of cards, drawn and driven.
///
/// Flipped, so that canvas coordinates — where y grows downward, in the file and in Obsidian — are the
/// view's coordinates too, offset by wherever the content happens to start. Every conversion in here is
/// a subtraction rather than a matrix, and a card's frame in the file is legible in the debugger as a
/// frame on screen.
///
/// **Zoom belongs to the scroll view, not to this.** `NSScrollView.magnification` scales the whole
/// document view, so nothing here multiplies by a zoom factor: a card is laid out at its true size
/// once and the scroll view draws it smaller. That is what keeps text crisp at any zoom — the text is
/// rendered at the scaled size by the layer, not rasterised at 1× and shrunk — and it is why the hit
/// tester takes a `scale` but the layout doesn't.
///
/// Cards are **built only when they come into view**. A board of 117 cards is ordinary and a card can
/// be an embedded web page; building all of them on open would be a hundred renderers for the dozen
/// you can see. See `refreshNodeViews`.
@MainActor
final class CanvasBoardView: NSView {
    // Internal rather than private throughout: the mouse and keyboard live in
    // `CanvasBoardView+Input.swift`, and Swift's `private` doesn't reach across files even for an
    // extension of the same type. The split is worth that — drawing and driving are different jobs,
    // and one file holding both was the length where neither could be read.
    let store: CanvasDocumentStore
    weak var scrollView: NSScrollView?

    /// The board's extent in canvas coordinates: everything on it, plus room to drag things outside it.
    /// The view's own size, and the origin every conversion subtracts.
    private(set) var content: CanvasRect = CanvasRect(x: 0, y: 0, width: 1, height: 1)
    private static let margin: Double = 1600

    var mode: CanvasMode = .view {
        didSet {
            guard mode != oldValue else { return }
            overlay.needsDisplay = true
            // The two vocabularies swap: rings and grips in edit, height in view.
            for view in nodeViews.values { view.refreshElevation() }
            onModeChanged?()
            refreshCursor()
        }
    }
    var selection: Set<String> = [] { didSet { selectionChanged(from: oldValue) } }
    var hovered: String?

    /// What the pointer is currently doing. Nil between gestures.
    var gesture: Gesture?
    enum Gesture {
        case move(from: CanvasPoint, frames: [String: CanvasRect])
        case resize(String, CanvasHandle, original: CanvasRect)
        case marquee(from: CanvasPoint, additive: Bool, base: Set<String>)
        case connect(from: String, side: CanvasSide, to: CanvasPoint)
    }

    var nodeViews: [String: CanvasNodeView] = [:]
    let overlay = CanvasOverlayView()
    var trackingArea: NSTrackingArea?
    /// Where the right-click that opened the context menu landed. Held because the menu is long
    /// dismissed by the time an item fires, and "Paste" from that menu means *there*.
    var menuPoint: CanvasPoint?
    /// Which match ⌘G steps to next.
    var findCursor = 0
    /// The line under the pointer, so it can say it is clickable before it is clicked.
    var hoveredEdge: String?

    /// The web card you have stepped into, if any. What the window's page controls act on — a board
    /// engages one card at a time, so there is never a question of which.
    var engagedPageCard: CanvasNodeView? {
        nodeViews.values.first { $0.isEngaged && $0.isPageCard }
    }

    /// Told when a page is stepped into or out of, or navigates — so the window can offer the controls
    /// for it, and only then.
    var onPageStateChanged: (() -> Void)?
    func pageStateChanged() { onPageStateChanged?() }

    /// Told when the mode changes, so the selection bar can drop the controls that only edit mode has.
    var onModeChanged: (() -> Void)?

    /// Told when the selection changes, so the floating bar can follow it.
    var onSelectionChanged: ((Set<String>) -> Void)?

    init(store: CanvasDocumentStore, scrollView: NSScrollView) {
        self.store = store
        self.scrollView = scrollView
        super.init(frame: .zero)
        wantsLayer = true
        overlay.board = self
        addSubview(overlay)
        recomputeContent()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var document: CanvasDocument { store.document }
    /// The zoom the hit tester and every screen-sized measurement work in.
    var liveScale: Double { Double(scrollView?.magnification ?? 1) }

    // MARK: Coordinates

    func viewPoint(_ p: CanvasPoint) -> NSPoint {
        NSPoint(x: p.x - content.minX, y: p.y - content.minY)
    }

    func viewRect(_ r: CanvasRect) -> NSRect {
        NSRect(x: r.minX - content.minX, y: r.minY - content.minY, width: r.width, height: r.height)
    }

    func canvasPoint(_ p: NSPoint) -> CanvasPoint {
        CanvasPoint(x: Double(p.x) + content.minX, y: Double(p.y) + content.minY)
    }

    func canvasRect(_ r: NSRect) -> CanvasRect {
        CanvasRect(x: Double(r.minX) + content.minX, y: Double(r.minY) + content.minY,
                   width: Double(r.width), height: Double(r.height))
    }

    /// Resize the board to hold what's on it, keeping what you're looking at where it is.
    ///
    /// The origin moves whenever a card is dragged out past the current extent, and every view
    /// coordinate is relative to that origin — so without compensating the scroll position, dragging a
    /// card off the left edge would yank the whole board sideways under the pointer.
    func recomputeContent() {
        let bounds = document.bounds ?? CanvasRect(x: 0, y: 0, width: 800, height: 600)
        let next = bounds.inset(by: Self.margin)
        guard next != content else { return }

        let shift = NSPoint(x: content.minX - next.minX, y: content.minY - next.minY)
        content = next
        setFrameSize(NSSize(width: next.width, height: next.height))
        overlay.frame = NSRect(origin: .zero, size: frame.size)

        if let clip = scrollView?.contentView, shift != .zero {
            clip.setBoundsOrigin(NSPoint(x: clip.bounds.origin.x + shift.x,
                                         y: clip.bounds.origin.y + shift.y))
        }
        layoutNodeViews()
    }

    // MARK: Reacting to the document

    /// The document changed — rebuild what's on screen.
    ///
    /// A drag reports a change on every mouse-moved event, and the full rebuild is far more than those
    /// need: nothing has been added or removed, so there are no card views to build or throw away and
    /// no selection to prune. Mid-gesture it does the two things that actually changed — where the
    /// cards are, and what's drawn behind them — and leaves the rest alone.
    func documentChanged() {
        recomputeContent()
        if !store.isInteracting {
            selection = selection.filter { document.node(id: $0) != nil }
            refreshNodeViews()
        }
        layoutNodeViews()
        needsDisplay = true
        overlay.needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshNodeViews()
    }

    /// Build and drop card views as the visible region moves.
    ///
    /// The keep-alive region is the visible rectangle grown by a screenful, so a card is ready before
    /// it is scrolled to rather than popping in at the edge — and a card scrolled just off screen isn't
    /// thrown away only to be rebuilt when you scroll back a little.
    func refreshNodeViews() {
        guard window != nil else { return }
        let visible = canvasRect(visibleRect)
        let keep = visible.inset(by: max(visible.width, visible.height) * 0.5)

        var wanted: Set<String> = []
        for node in document.nodes where !node.isGroup && node.frame.intersects(keep) {
            wanted.insert(node.id)
            if let existing = nodeViews[node.id] {
                existing.update(node: node, scale: liveScale)
            } else {
                let view = CanvasNodeView.make(node: node, board: self, scale: liveScale)
                nodeViews[node.id] = view
                addSubview(view, positioned: .below, relativeTo: overlay)
                view.update(node: node, scale: liveScale)
            }
        }
        for (id, view) in nodeViews where !wanted.contains(id) {
            view.prepareForRemoval()
            view.removeFromSuperview()
            nodeViews.removeValue(forKey: id)
        }
        layoutNodeViews()
    }

    private func layoutNodeViews() {
        for (id, view) in nodeViews {
            guard let node = document.node(id: id) else { continue }
            view.frame = viewRect(node.frame)
        }
        overlay.frame = NSRect(origin: .zero, size: frame.size)
    }

    /// Zoom changed: cards that render differently at different sizes get told.
    func magnificationChanged() {
        for (id, view) in nodeViews {
            guard let node = document.node(id: id) else { continue }
            view.update(node: node, scale: liveScale)
        }
        overlay.needsDisplay = true
        needsDisplay = true
        refreshNodeViews()
    }

    // MARK: The page budget

    /// Set while a budget review is already queued, so a pass of `refreshNodeViews` in which eight
    /// cards each decide they would like to run a page is one decision rather than eight.
    private var budgetReviewQueued = false
    /// Cancelled and replaced on every scroll and zoom — see `settlePageBudget`.
    private var settleWork: DispatchWorkItem?

    /// Decide again which pages are live, at the end of the current run loop pass.
    func reviewPageBudget() {
        guard !budgetReviewQueued else { return }
        budgetReviewQueued = true
        DispatchQueue.main.async { [weak self] in
            self?.budgetReviewQueued = false
            self?.applyPageBudget()
        }
    }

    /// Decide again once the view has stopped moving.
    ///
    /// Scrolling across a board sweeps cards through the window at speed, and a budget applied on
    /// every frame of that would start and kill renderers the whole way — the most expensive possible
    /// response to a gesture that has not finished saying what it wants. So a scroll or a zoom only
    /// schedules the decision, and each new one pushes it back; the board acts on where you *stopped*.
    func settlePageBudget() {
        settleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.applyPageBudget() }
        settleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75, execute: work)
    }

    private func applyPageBudget() {
        settleWork?.cancel()
        settleWork = nil
        guard window != nil else { return }
        let visible = canvasRect(visibleRect)
        let centre = CanvasPoint(x: visible.midX, y: visible.midY)

        let now = Date()
        var candidates: [CanvasPageBudget.Candidate] = []
        for (id, view) in nodeViews where view.isPageCard {
            guard let node = document.node(id: id) else { continue }
            let onScreen = node.frame.intersects(visible)
            if onScreen { view.lastVisibleAt = now }
            candidates.append(.init(id: id,
                                    wantsPage: view.wantsPage,
                                    isVisible: onScreen,
                                    isEngaged: view.isEngaged,
                                    distanceFromCentre: hypot(node.frame.midX - centre.x,
                                                              node.frame.midY - centre.y),
                                    secondsSinceVisible: now.timeIntervalSince(view.lastVisibleAt)))
        }
        let live = CanvasPageBudget.live(among: candidates)
        if live != pagesLive {
            Log.write("canvas pages live: \(live.count) of \(candidates.count)")
            pagesLive = live
        }
        for (id, view) in nodeViews where view.isPageCard {
            view.setPageLive(live.contains(id))
            view.timePassed()
        }
        keepWatchingPages(live.isEmpty)
    }

    /// A slow tick, running only while the board has something live.
    ///
    /// Two things need it, and neither is caused by anything the board could be told about: a page's
    /// grace period runs out while you sit perfectly still looking at something else on the board, and
    /// the "as of" on a card gets older whether or not anyone touches it.
    private var heartbeat: Timer?
    private static let heartbeatInterval: TimeInterval = 20

    private func keepWatchingPages(_ stop: Bool) {
        if stop {
            heartbeat?.invalidate()
            heartbeat = nil
        } else if heartbeat == nil {
            heartbeat = Timer.scheduledTimer(withTimeInterval: Self.heartbeatInterval,
                                             repeats: true) { _ in
                Task { @MainActor [weak self] in self?.applyPageBudget() }
            }
        }
    }

    /// Only so a change can be logged once rather than on every settle.
    private var pagesLive: Set<String> = []

    /// Freeze every page on this board — the window has stopped being looked at.
    func pauseAllPages() {
        settleWork?.cancel()
        settleWork = nil
        if !pagesLive.isEmpty { Log.write("canvas pages paused: \(pagesLive.count)") }
        pagesLive = []
        keepWatchingPages(true)
        for view in nodeViews.values where view.isPageCard { view.setPageLive(false) }
    }

    // MARK: Drawing what isn't a card

    override func draw(_ dirty: NSRect) {
        CanvasPalette.board.setFill()
        dirty.fill()
        drawGrid(in: dirty)
        drawGroups(in: dirty)
        drawEdges(in: dirty)
    }

    /// The dot grid. It exists because a canvas has no edges and no content of its own: panning across
    /// an empty region with nothing moving looks like a window that has stopped responding.
    ///
    /// The spacing steps up as you zoom out so the dots stay roughly the same distance apart on screen
    /// — at 20% a 20pt grid is a 4pt grid, which is a texture rather than a grid — and below a point
    /// it's dropped entirely, because a dot per few pixels is just noise.
    private func drawGrid(in dirty: NSRect) {
        var spacing: Double = 20
        while spacing * liveScale < 14 { spacing *= 4 }
        guard spacing * liveScale >= 14, spacing < 4000 else { return }

        let radius = min(1.2, 1.0 / liveScale)
        CanvasPalette.grid.setFill()
        let path = NSBezierPath()
        var y = (Double(dirty.minY) / spacing).rounded(.down) * spacing
        while y <= Double(dirty.maxY) {
            var x = (Double(dirty.minX) / spacing).rounded(.down) * spacing
            while x <= Double(dirty.maxX) {
                path.appendOval(in: NSRect(x: x - radius, y: y - radius,
                                           width: radius * 2, height: radius * 2))
                x += spacing
            }
            y += spacing
        }
        path.fill()
    }

    /// Frames, drawn behind everything else — a frame is a background that says "these belong
    /// together", so it is painted rather than built as a view. Nothing about it is interactive except
    /// where it is clicked, and that lives in the hit tester.
    private func drawGroups(in dirty: NSRect) {
        for node in document.nodes where node.isGroup {
            let rect = viewRect(node.frame)
            guard rect.intersects(dirty.insetBy(dx: -40, dy: -40)) else { continue }
            let path = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
            (CanvasPalette.color(node.color)?.withAlphaComponent(0.07) ?? CanvasPalette.groupFill).setFill()
            path.fill()
            (CanvasPalette.color(node.color) ?? CanvasPalette.groupStroke).setStroke()
            path.lineWidth = selection.contains(node.id) ? 3 / liveScale : 1.5 / liveScale
            if selection.contains(node.id) { NSColor.controlAccentColor.setStroke() }
            path.stroke()

            if case .group(let label, _, _) = node.content, let label, !label.isEmpty {
                let size = max(11, min(17, 15 / liveScale))
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: size, weight: .semibold),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]
                let text = label as NSString
                let measured = text.size(withAttributes: attributes)
                text.draw(at: NSPoint(x: rect.minX + 2, y: rect.minY - measured.height - 3),
                          withAttributes: attributes)
            }
        }
    }

    private func drawEdges(in dirty: NSRect) {
        let region = canvasRect(dirty.insetBy(dx: -80, dy: -80))
        for edge in document.edges {
            guard let curve = canvasRoute(for: edge, in: document),
                  curve.bounds.inset(by: 40).intersects(region) else { continue }
            let selected = selection.contains(edge.id)
            let under = hoveredEdge == edge.id
            let color = selected ? NSColor.controlAccentColor
                : (under ? CanvasPalette.edge(edge.color).blended(withFraction: 0.35, of: .labelColor)
                        ?? CanvasPalette.edge(edge.color)
                   : CanvasPalette.edge(edge.color))
            drawCurve(curve, color: color, width: (selected ? 3.5 : under ? 3.0 : 2.2) / liveScale,
                      startEnd: edge.resolvedFromEnd, endEnd: edge.resolvedToEnd, label: edge.label)
        }
    }

    func drawCurve(_ curve: CanvasCurve,
                   color: NSColor,
                   width: Double,
                   startEnd: CanvasEnd,
                   endEnd: CanvasEnd,
                   label: String?,
                   dashed: Bool = false) {
        let path = NSBezierPath()
        path.move(to: viewPoint(curve.start))
        path.curve(to: viewPoint(curve.end),
                   controlPoint1: viewPoint(curve.control1),
                   controlPoint2: viewPoint(curve.control2))
        path.lineWidth = width
        path.lineCapStyle = .round
        if dashed { path.setLineDash([6 / liveScale, 5 / liveScale], count: 2, phase: 0) }
        color.setStroke()
        path.stroke()

        if endEnd == .arrow { drawArrowhead(at: 1, on: curve, color: color) }
        if startEnd == .arrow { drawArrowhead(at: 0, on: curve, color: color) }

        if let label, !label.isEmpty { drawEdgeLabel(label, on: curve, color: color) }
    }

    /// The arrowhead, pointed along the curve's own tangent rather than along the straight line between
    /// the ends — on a bowed line those differ by enough to look like a mistake.
    private func drawArrowhead(at t: Double, on curve: CanvasCurve, color: NSColor) {
        let tip = viewPoint(curve.point(at: t))
        var direction = curve.direction(at: t)
        if t == 0 { direction = CanvasPoint(x: -direction.x, y: -direction.y) }

        let size = 9.5 / liveScale
        let angle = atan2(direction.y, direction.x)
        let spread = 0.42
        let path = NSBezierPath()
        path.move(to: tip)
        path.line(to: NSPoint(x: tip.x - cos(angle - spread) * size, y: tip.y - sin(angle - spread) * size))
        path.line(to: NSPoint(x: tip.x - cos(angle + spread) * size, y: tip.y - sin(angle + spread) * size))
        path.close()
        color.setFill()
        path.fill()
    }

    private func drawEdgeLabel(_ label: String, on curve: CanvasCurve, color: NSColor) {
        let size = max(9, min(13, 12 / liveScale))
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size),
            .foregroundColor: NSColor.labelColor,
        ]
        let text = label as NSString
        let measured = text.size(withAttributes: attributes)
        let mid = viewPoint(curve.point(at: 0.5))
        let box = NSRect(x: mid.x - measured.width / 2 - 5 / liveScale,
                         y: mid.y - measured.height / 2 - 2 / liveScale,
                         width: measured.width + 10 / liveScale, height: measured.height + 4 / liveScale)
        CanvasPalette.board.setFill()
        NSBezierPath(roundedRect: box, xRadius: 4 / liveScale, yRadius: 4 / liveScale).fill()
        text.draw(at: NSPoint(x: mid.x - measured.width / 2, y: mid.y - measured.height / 2),
                  withAttributes: attributes)
    }
}
