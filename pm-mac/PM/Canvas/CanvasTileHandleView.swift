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

    // MARK: The strips, carved out of the window drag (canvas-backlog.md 22)

    /// One invisible view over each tab strip, and they exist for a single property.
    ///
    /// The project window runs the board under a transparent titlebar, and an empty unified toolbar
    /// makes that band **66pt** deep (measured, `WindowDragBandTests`). Tiles begin at 46 —
    /// `headerClearance` plus `CanvasTiling.edgeGap` — so 20 of a strip's 28 points lie inside the
    /// band, and a press on almost all of a top-row tab is AppKit's to interpret before it is
    /// anybody's to handle.
    ///
    /// It interprets one by building a region out of the view tree **in z-order**: a view answering
    /// `mouseDownCanMoveWindow` with no carves its frame out of the window drag, and any view in front
    /// of it answering yes puts that frame straight back. Not by hit-testing, which is the reading that
    /// looks right and says the header's own excluders could never work either. The board answers yes
    /// by saying nothing — `NSView`'s default is true — so without these, dragging a tab moved the
    /// window.
    ///
    /// **Only the strips, and that is the decision rather than the cheap way out.** One line on
    /// `CanvasBoardView` would have carved out the entire board, and taken the whole band with it: the
    /// empty top of a board is somewhere to grab the window, which is worth keeping in a window whose
    /// titlebar is otherwise invisible. These carve out the part of that band that is a control.
    ///
    /// **They only reach as far as the board does.** `CanvasEdgeView` is a sibling in front of the
    /// whole scroll view and answers the drag with true, so nothing in here can carve out anything
    /// above it. It ends at 46 and the tiles start at 46 — the same line, which is why this works; a
    /// strip that ever sat higher would need the answer to move out to the pane.
    ///
    /// They take no clicks, like everything else in this view. A press on a tab still reaches the
    /// board's own `mouseDown` and `tabChip(at:)`; all these change is what AppKit does with a press
    /// *before* anyone's `mouseDown` is called.
    private var stripExcluders: [Excluder] = []

    final class Excluder: NSView {
        override var mouseDownCanMoveWindow: Bool { false }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    /// Put one over each strip. Driven from `layoutNodeViews`, because where a strip is is a fact about
    /// the layout — not about the pointer, which is what the handlebars follow.
    ///
    /// The views are moved rather than rebuilt: this runs on every layout pass, including every frame
    /// of a tile being dragged, and a strip that has not moved should cost a frame comparison.
    func refreshStripExcluders() {
        // The same two conditions `drawTabStrips` draws under: no tiling and no strips, and while the
        // board is picking there are none on screen to carve out.
        var bands: [NSRect] = []
        if let board, !board.isPicking, let session = board.tiling {
            bands = session.tabStrips.map { board.viewRect($0.band) }
        }
        while stripExcluders.count < bands.count {
            let view = Excluder(frame: .zero)
            addSubview(view)
            stripExcluders.append(view)
        }
        while stripExcluders.count > bands.count {
            stripExcluders.removeLast().removeFromSuperview()
        }
        for (view, band) in zip(stripExcluders, bands) where view.frame != band { view.frame = band }
    }

    override func draw(_ dirty: NSRect) {
        guard let board else { return }
        drawTabStrips(board, board.liveScale)
        drawTileHandles(board, board.liveScale)
    }

    /// The tabs across the top of a tile holding more than one card (docs/canvas-workspaces.md §7k).
    ///
    /// **Here, under the cards**, for the reason the handlebars are: the band is the tile's own — the
    /// room the layout leaves above the card that is showing — and the only thing that should ever
    /// pass over it is a tile being carried across. Drawn a little way down under the card as well, so
    /// the card's own top corners round off into the strip rather than onto the ground behind it.
    private func drawTabStrips(_ board: CanvasBoardView, _ scale: Double) {
        guard let session = board.tiling, !board.isPicking else { return }
        let space = CanvasTiling.space(of: session.area)
        for strip in session.tabStrips {
            let outer = CanvasTiling.corners(of: strip.band, in: space)
            var radii = CanvasTiling.Corners(topLeft: outer.topLeft, topRight: outer.topRight,
                                             bottomRight: false, bottomLeft: false)
                .radii(inner: CanvasTiling.innerRadius, outer: CanvasTiling.outerRadius)
            radii.bottomLeft = 0
            radii.bottomRight = 0
            var band = board.viewRect(strip.band)
            band.size.height += CanvasTiling.outerRadius
            CanvasPalette.card.setFill()
            CanvasNodeView.path(in: band, radii: radii).fill()

            let chips = CanvasTiling.tabs(in: strip.band, count: strip.cards.count)
            for (index, (card, chip)) in zip(strip.cards, chips).enumerated() {
                drawTab(card, in: board.viewRect(chip), showing: index == strip.showing, board, scale)
            }
        }
    }

    /// One tab: the card's icon and name, as the zoomed-out board and Add Card from Canvas call it, so a
    /// card is recognisable by the same two things wherever it is listed.
    private func drawTab(_ card: String, in rect: NSRect, showing: Bool,
                         _ board: CanvasBoardView, _ scale: Double) {
        if showing {
            NSColor.labelColor.withAlphaComponent(0.08).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 6 / scale, yRadius: 6 / scale).fill()
        }
        guard let described = board.document.node(id: card).flatMap(CanvasExistingCards.card) else { return }
        let side = 14 / scale
        var textLeft = rect.minX + 8 / scale
        if let icon = CanvasBoardView.menuIcon(for: described.kind) {
            icon.draw(in: NSRect(x: textLeft, y: rect.midY - side / 2, width: side, height: side),
                      from: .zero, operation: .sourceOver, fraction: showing ? 1 : 0.6,
                      respectFlipped: true, hints: nil)
            textLeft += side + 6 / scale
        }
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let font = NSFont.systemFont(ofSize: 12 / scale, weight: showing ? .semibold : .regular)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: showing ? NSColor.labelColor : NSColor.secondaryLabelColor,
            .paragraphStyle: style,
        ]
        let height = font.boundingRectForFont.height
        let text = NSRect(x: textLeft, y: rect.midY - height / 2,
                          width: max(0, rect.maxX - textLeft - 8 / scale), height: height)
        (described.name as NSString).draw(with: text, options: [.usesLineFragmentOrigin,
                                                                 .truncatesLastVisibleLine],
                                          attributes: attributes)
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
