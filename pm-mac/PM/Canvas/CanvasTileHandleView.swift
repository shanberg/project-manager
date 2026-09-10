import AppKit
import PmLib

/// The tile handlebars — and nothing else, because of where they have to sit.
///
/// Its own view rather than more drawing in the overlay, and the reason is the z-order. The overlay is
/// above the cards, which is right for grips and dots and a sweep rectangle: those are things you are
/// about to grab, and a card lying over one would be a control you cannot reach. A handlebar is the
/// opposite kind of thing. It belongs to a tile, it is drawn in the gap beside it, and while a tile is
/// being dragged it leaves its slot and passes over its neighbours — a grip that stayed on top of the
/// card sliding over it would be the one mark on the board floating free of what it belongs to. So this
/// goes at the bottom of the board's subviews: above the board's own drawing — the ground, the grid,
/// the frames and the lines — and below every card.
///
/// It is also the cheaper arrangement, which is a happy accident rather than the argument. A handlebar
/// dissolving over ten frames redraws only this, instead of forcing the board to repaint its
/// background, its grid, every frame and every line, ten times, for a change to something none of
/// them are involved in.
///
/// **The alignment guides used to live here too, and the same argument put them here** — a mark about
/// where a card is *going*, drawn between cards, that a card sliding over should cover. What replaced
/// them is a target rather than an explanation, and a target is a thing the card lands on *top* of:
/// below the cards it would be hidden at the very moment it is confirming the match, and it has to be
/// legible across a card's own face when you are sizing one down. So it went up into the overlay. See
/// `CanvasGhost` and `CanvasOverlayView.drawGhost`.
///
/// Like the overlay, it never takes a click.
@MainActor
final class CanvasTileHandleView: NSView {
    weak var board: CanvasBoardView?

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
        // Quicker in than out: appearing has to keep up with a pointer, and leaving is allowed to take
        // its time because nothing is waiting on it.
        let fade = CanvasFade(rise: 0.11, fall: 0.18, on: self) { [weak self] in
            self?.needsDisplay = true
        }
        handleFades[id] = fade
        return fade
    }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirty: NSRect) {
        guard let board else { return }
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
}
