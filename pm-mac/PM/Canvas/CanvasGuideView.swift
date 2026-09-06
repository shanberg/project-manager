import AppKit
import PmLib

/// The alignment guides — and nothing else, because of where they have to sit.
///
/// Its own view rather than more drawing in the overlay, and the reason is the z-order. The overlay is
/// above the cards, which is right for grips and dots and a sweep rectangle: those are things you are
/// about to grab, and a card lying over one would be a control you cannot reach. A guide is the
/// opposite kind of thing. It is a mark on the board about where a card is *going*, it is drawn in the
/// space between cards, and a card sliding over it should cover it the way a card covers anything else
/// on the board. So this goes at the bottom of the board's subviews: above the board's own drawing —
/// the ground, the grid, the frames and the lines — and below every card.
///
/// It is also the cheaper arrangement, which is a happy accident rather than the argument. A guide
/// dissolving over ten frames redraws only this, instead of forcing the board to repaint its
/// background, its grid, every frame and every line, ten times, for a change to something none of
/// them are involved in.
///
/// Like the overlay, it never takes a click.
@MainActor
final class CanvasGuideView: NSView {
    weak var board: CanvasBoardView?

    /// The alignment and size agreements found by the drag in progress.
    ///
    /// Setting this fades the ghosts in or out rather than switching them — see `CanvasFade`. The last
    /// non-empty set is held in `drawnGuides` so that clearing this on mouse-up leaves something to
    /// fade *out*; a guide that vanished on the frame the button came up would be the flicker the fade
    /// exists to remove.
    var guides: [CanvasGuide] = [] {
        didSet {
            guard guides != oldValue else { return }
            if !guides.isEmpty { drawnGuides = guides }
            guideFade.set(!guides.isEmpty)
            needsDisplay = true
        }
    }
    private var drawnGuides: [CanvasGuide] = []

    /// Which tiles are showing their handlebar. Set by the board — see `refreshTileHandles`.
    ///
    /// Faded rather than switched, and one fade per tile rather than one for the lot. Moving the
    /// pointer from one tile to the next is two things happening at once — a mark leaving where it was
    /// and arriving where you are — and a single fade could only say one of them, which is a bar that
    /// blinks out here and blinks in there. Two crossing fades read as the same mark following you.
    var shownTileHandles: Set<String> = [] {
        didSet {
            guard shownTileHandles != oldValue else { return }
            for id in shownTileHandles.union(oldValue) {
                handleFade(id).set(shownTileHandles.contains(id))
            }
            needsDisplay = true
        }
    }
    private var handleFades: [String: CanvasFade] = [:]

    private func handleFade(_ id: String) -> CanvasFade {
        if let existing = handleFades[id] { return existing }
        // Quicker in than out, like the guides: appearing has to keep up with a pointer, and leaving is
        // allowed to take its time because nothing is waiting on it.
        let fade = CanvasFade(rise: 0.11, fall: 0.18) { [weak self] in self?.needsDisplay = true }
        handleFades[id] = fade
        return fade
    }
    private lazy var guideFade = CanvasFade(rise: 0.1, fall: 0.16) { [weak self] in
        self?.needsDisplay = true
    }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirty: NSRect) {
        guard let board else { return }
        drawGuides(board, board.liveScale)
        drawTileHandles(board, board.liveScale)
    }

    /// The bar that says a tile can be moved, and is what you take hold of to move it.
    ///
    /// **Something has to say so.** A tiled view is the one place on this board where dragging a card
    /// does not move it, and there was nothing on screen to suggest that tiles had an order at all. A
    /// grip is how every list that can be reordered says it is one.
    ///
    /// **Only on the tile you are on.** Drawn for every tile at once it was a row of marks around the
    /// edge of everything, permanently, for a gesture you use occasionally — a tiled view is for
    /// reading the cards, and six grips is six things that are not what you are reading. On hover or on
    /// the selection it is exactly as much chrome as the moment needs, and it fades rather than
    /// switching: see `shownTileHandles`.
    ///
    /// **Here rather than in the overlay**, which is to say under the cards: while a tile is being
    /// dragged it leaves its slot and passes over its neighbours, and a grip that stayed on top of the
    /// card sliding over it would be the one mark on the board floating free of what it belongs to.
    /// Its position is `CanvasBoardView.tileHandle`, which the hit test uses too, so the mark and the
    /// band that catches it cannot drift apart.
    private func drawTileHandles(_ board: CanvasBoardView, _ scale: Double) {
        guard let tiling = board.tiling, tiling.ids.count > 1 else { return }
        for id in tiling.ids {
            guard let fade = handleFades[id], fade.isVisible,
                  let handle = board.tileHandle(id) else { continue }
            let presence = fade.presence
            let rect = board.viewRect(handle.bar)
            let radius = min(rect.width, rect.height) / 2
            let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
            // A pinned tile says so on its own grip. The grip is already the one mark on a tile that is
            // about how it is laid out, and a pin is a fact about exactly that.
            if board.isTilePinned(id) {
                NSColor.controlAccentColor.withAlphaComponent(0.85 * presence).setFill()
            } else {
                CanvasPalette.guide(0.55 * presence).setFill()
            }
            path.fill()
        }
    }

    /// What says why a card stopped where it did.
    ///
    /// **A slot outlined on the canvas.** Not a line ruled across the board at the coordinate two
    /// cards agreed on, and not a glow traced along the cards' own borders either. Both of those draw
    /// on the subject — they make the cards look different — and a card that changes appearance while
    /// you are placing it is a card you have to re-read at the moment you are trying to position it.
    ///
    /// What the desktop does instead, and what this now does, is draw in the space *between* things: a
    /// band standing off the slot it is describing, on the board, touching nothing. The card is
    /// untouched and still exactly as legible as it was, and the outline is unmistakably about
    /// position because position is the only thing it occupies.
    ///
    /// One band per slot — the moving set's own, and each card it lined up with — and nothing else.
    /// No connector between them and no brighter stroke along the edge that matched: those were the
    /// last of the line-drawing idea, and a second mark competing with the band is the thing that
    /// stopped the band reading as a band.
    ///
    /// Neutral rather than accent, and dissolved rather than switched: see `CanvasPalette.guide` and
    /// `CanvasFade`, which each own half of the argument.
    private func drawGuides(_ board: CanvasBoardView, _ scale: Double) {
        guard guideFade.isVisible, !drawnGuides.isEmpty else { return }
        let presence = guideFade.presence

        // Every slot in any agreement, once. A drag that matched on both axes names the same card in
        // two guides, and outlining it twice would draw it at double weight for no reason the eye can
        // read.
        var slots: [CanvasRect] = []
        for guide in drawnGuides {
            guard case .alignment(_, _, let cards) = guide else { continue }
            for card in cards where !slots.contains(card) { slots.append(card) }
        }
        for slot in slots { drawSlot(slot, board: board, scale: scale, presence: presence) }

        for guide in drawnGuides {
            guard case .sameSize(let axis, let moving, let matched) = guide else { continue }
            CanvasPalette.guide(0.32 * presence).setStroke()
            for rect in [moving, matched] { drawMeasure(rect, axis: axis, board: board, scale: scale) }
        }
    }

    /// How far the band stands off the slot, and how thick it is — both in **view points over the
    /// zoom**, so the outline is the same weight and the same distance to the eye at 30% as at 200%.
    /// Measured in canvas units it would be a smear when zoomed in and invisible when zoomed out,
    /// which is exactly backwards for something whose whole job is to be noticed without being looked
    /// at.
    private static let slotStandoff: Double = 5
    private static let slotWidth: Double = 5

    /// One slot: a band on the board around it, not on it.
    private func drawSlot(_ slot: CanvasRect, board: CanvasBoardView,
                          scale: Double, presence: Double) {
        let standoff = Self.slotStandoff / scale
        let rect = board.viewRect(slot).insetBy(dx: -standoff, dy: -standoff)
        // Concentric with the card it stands off from: a curve offset from another curve keeps an even
        // gap only when its radius grows by the offset. Left at the card's own radius the band would
        // pinch tight at the corners and bulge along the sides.
        let radius = CanvasNodeView.cornerRadius(for: slot) + standoff
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        path.lineWidth = Self.slotWidth / scale
        CanvasPalette.guide(0.30 * presence).setStroke()
        path.stroke()
    }

    /// "These two are the same width" — a bar the length of the dimension that matched, with a tick at
    /// each end, drawn just outside each card.
    ///
    /// A bar rather than a line through the cards, because the claim being made is about *length*, and
    /// two bars of visibly equal length beside two cards is the only way to draw that so it can be
    /// checked at a glance. A line at a coordinate would say "these edges agree", which is the other
    /// guide's job and a different fact.
    private func drawMeasure(_ rect: CanvasRect, axis: CanvasGuide.Axis,
                             board: CanvasBoardView, scale: Double) {
        let offset = 7 / scale
        let tick = 4 / scale
        let path = NSBezierPath()

        if axis == .horizontal {
            let y = board.viewPoint(CanvasPoint(x: rect.minX, y: rect.maxY)).y + offset
            let left = board.viewPoint(CanvasPoint(x: rect.minX, y: 0)).x
            let right = board.viewPoint(CanvasPoint(x: rect.maxX, y: 0)).x
            path.move(to: NSPoint(x: left, y: y))
            path.line(to: NSPoint(x: right, y: y))
            for x in [left, right] {
                path.move(to: NSPoint(x: x, y: y - tick))
                path.line(to: NSPoint(x: x, y: y + tick))
            }
        } else {
            let x = board.viewPoint(CanvasPoint(x: rect.maxX, y: rect.minY)).x + offset
            let top = board.viewPoint(CanvasPoint(x: 0, y: rect.minY)).y
            let bottom = board.viewPoint(CanvasPoint(x: 0, y: rect.maxY)).y
            path.move(to: NSPoint(x: x, y: top))
            path.line(to: NSPoint(x: x, y: bottom))
            for y in [top, bottom] {
                path.move(to: NSPoint(x: x - tick, y: y))
                path.line(to: NSPoint(x: x + tick, y: y))
            }
        }
        path.lineWidth = 1.5 / scale
        path.stroke()
    }

}
