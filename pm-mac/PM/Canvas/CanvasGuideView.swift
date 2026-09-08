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
    /// **A band on the canvas.** Not a line ruled across the board at the coordinate two cards agreed
    /// on, and not a glow traced along the cards' own borders either. Both of those draw on the
    /// subject — they make the cards look different — and a card that changes appearance while you are
    /// placing it is a card you have to re-read at the moment you are trying to position it. What the
    /// desktop does instead, and what this does, is draw in the space *between* things: a band standing
    /// off the slot it is describing, on the board, touching nothing.
    ///
    /// **One mark, and how much of it is drawn is the claim.** The band is a loop concentric with the
    /// card; a claim about one dimension is that loop with the runs that don't span it left out, and a
    /// grid landing is the loop's four corners and nothing else. So the marks are the same breadth, the
    /// same weight and the same neutral tone wherever they appear, and what tells them apart is shape —
    /// which the eye reads without being asked to compare anything.
    ///
    /// - a **closed loop** round every card in the agreement: they line up, or — round exactly two —
    ///   they are the same size in both dimensions and so the same shape. The strongest mark, for the
    ///   two strongest claims, and when it is congruence the two loops are congruent, which *is* the
    ///   proof.
    /// - **two runs**, top and bottom or left and right: the same width, or the same height. What
    ///   survives is the pair of runs that span the dimension being claimed, so two cards of equal
    ///   width wear two pairs of equal bars.
    /// - **four corners**: the lattice, which is the weakest claim and used to be no claim at all. A
    ///   card clicking to a 10pt grid nobody had mentioned looked like a card refusing to go where you
    ///   put it.
    ///
    /// This replaced a ruled bar with a tick at each end for the size cases — a hairline measurement
    /// drawing, in a different visual language from everything else the board draws, saying its fact in
    /// a way you had to stop and read rather than see.
    ///
    /// Neutral rather than accent, and dissolved rather than switched: see `CanvasPalette.guide` and
    /// `CanvasFade`, which each own half of the argument.
    private func drawGuides(_ board: CanvasBoardView, _ scale: Double) {
        guard guideFade.isVisible, !drawnGuides.isEmpty else { return }
        let presence = guideFade.presence
        for mark in marks(of: drawnGuides) {
            draw(mark.slot, showing: mark.band, board: board, scale: scale, presence: presence)
        }
    }

    /// How much of the band to draw.
    private enum Band: Equatable {
        case loop
        /// The two runs spanning `axis` — `.horizontal` being the top and bottom, which are the ones
        /// that carry a width.
        case runs(CanvasGuide.Axis)
        case corners

        /// Which mark wins when a card is in more than one agreement at once. A card that is both
        /// lined up with something and the same width as something else gets the loop: it is the
        /// larger claim, and stroking both would draw the same band at double weight for a reason
        /// nobody could see.
        var weight: Int {
            switch self {
            case .loop: return 2
            case .runs: return 1
            case .corners: return 0
            }
        }
    }

    /// Every slot to mark and what to draw round it — each slot once, at its strongest claim.
    ///
    /// A drag that matched on both axes names the same card in two guides, and outlining it twice
    /// would draw it at double weight for no reason the eye can read.
    private func marks(of guides: [CanvasGuide]) -> [(slot: CanvasRect, band: Band)] {
        var marks: [(slot: CanvasRect, band: Band)] = []
        func note(_ slot: CanvasRect, _ band: Band) {
            guard let index = marks.firstIndex(where: { $0.slot == slot }) else {
                return marks.append((slot, band))
            }
            if band.weight > marks[index].band.weight { marks[index].band = band }
        }
        for guide in guides {
            switch guide {
            case .alignment(_, _, let cards):
                for card in cards { note(card, .loop) }
            case .sameSize(let axes, let cards):
                // Both dimensions is the whole shape, and the whole loop says so.
                let band: Band = axes.count > 1 ? .loop : .runs(axes[0])
                for card in cards { note(card, band) }
            case .grid(let card):
                note(card, .corners)
            }
        }
        return marks
    }

    /// How far the band stands off the slot, and how thick it is — both in **view points over the
    /// zoom**, so the outline is the same weight and the same distance to the eye at 30% as at 200%.
    /// Measured in canvas units it would be a smear when zoomed in and invisible when zoomed out,
    /// which is exactly backwards for something whose whole job is to be noticed without being looked
    /// at.
    private static let slotStandoff: Double = 5
    private static let slotWidth: Double = 5

    /// One slot: a band on the board around it, not on it — or as much of that band as the claim is
    /// entitled to.
    ///
    /// **The partial bands are the whole band, clipped**, rather than paths of their own. It is the one
    /// construction that cannot drift: a run and a corner are literally arcs of the loop the card would
    /// have worn, at the same standoff and the same radius, so a board showing all three kinds at once
    /// shows one family of marks rather than three drawings that were meant to match.
    private func draw(_ slot: CanvasRect, showing band: Band, board: CanvasBoardView,
                      scale: Double, presence: Double) {
        let standoff = Self.slotStandoff / scale
        let rect = board.viewRect(slot).insetBy(dx: -standoff, dy: -standoff)
        // Concentric with the card it stands off from: a curve offset from another curve keeps an even
        // gap only when its radius grows by the offset. Left at the card's own radius the band would
        // pinch tight at the corners and bulge along the sides.
        let radius = CanvasNodeView.cornerRadius(for: slot) + standoff
        let width = Self.slotWidth / scale
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        path.lineWidth = width
        CanvasPalette.guide(0.30 * presence).setStroke()

        // How deep a window has to be to hold a corner: the arc plus the half-stroke that overhangs it.
        let corner = radius + width
        let windows: [NSRect]
        switch band {
        case .loop:
            return path.stroke()
        case .runs(.horizontal):
            // The top and bottom of the loop, each cut where its corners stop turning. What is left
            // spans the card's width, which is the dimension being claimed.
            windows = [NSRect(x: rect.minX - width, y: rect.minY - width,
                              width: rect.width + width * 2, height: corner),
                       NSRect(x: rect.minX - width, y: rect.maxY - radius,
                              width: rect.width + width * 2, height: corner)]
        case .runs(.vertical):
            windows = [NSRect(x: rect.minX - width, y: rect.minY - width,
                              width: corner, height: rect.height + width * 2),
                       NSRect(x: rect.maxX - radius, y: rect.minY - width,
                              width: corner, height: rect.height + width * 2)]
        case .corners:
            windows = [NSRect(x: rect.minX - width, y: rect.minY - width,
                              width: corner, height: corner),
                       NSRect(x: rect.maxX - radius, y: rect.minY - width,
                              width: corner, height: corner),
                       NSRect(x: rect.minX - width, y: rect.maxY - radius,
                              width: corner, height: corner),
                       NSRect(x: rect.maxX - radius, y: rect.maxY - radius,
                              width: corner, height: corner)]
        }
        for window in windows {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: window).setClip()
            path.stroke()
            NSGraphicsContext.restoreGraphicsState()
        }
    }
}
