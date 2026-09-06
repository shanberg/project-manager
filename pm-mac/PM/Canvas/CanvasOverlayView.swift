import AppKit
import PmLib

/// Everything drawn *over* the cards: selection grips, connection dots, the sweep rectangle, and the
/// line being dragged out of a card.
///
/// Not the alignment guides, which are the one piece of board chrome that belongs *under* the cards —
/// see `CanvasGuideView`.
///
/// A view of its own rather than more drawing in the board, because these have to sit above the cards
/// and the cards are real subviews — a board that drew its grips in `draw(_:)` would draw them
/// underneath every card it had just built.
///
/// It never takes a click. `hitTest` returns nil unconditionally, so the pointer reaches the board
/// beneath and the board keeps being the single place a click is interpreted. The grips are drawn
/// here and *hit* there, which sounds like a split until you notice it is the only arrangement where
/// hit-testing can be tested without a window.
@MainActor
final class CanvasOverlayView: NSView {
    weak var board: CanvasBoardView?
    /// The sweep in progress, in canvas coordinates.
    var marquee: CanvasRect?
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirty: NSRect) {
        guard let board else { return }
        let scale = board.liveScale

        drawConnectionAnchors(board, scale)
        drawSelectionBounds(board, scale)
        drawGrips(board, scale)
        drawConnectionInFlight(board, scale)
        drawSwapInFlight(board, scale)
        drawMarquee(board, scale)
    }

    /// The two tiles a drop would exchange, while a tiled view is being rearranged.
    ///
    /// Both of them, and that is the point: a swap is symmetric, and highlighting only the tile under
    /// the pointer would say "this one is the target" when what is about to happen is that these two
    /// change places. Drawn as a filled wash rather than a ring, because at tile size a ring reads as a
    /// selection and this is a preview of an action.
    private func drawSwapInFlight(_ board: CanvasBoardView, _ scale: Double) {
        guard case .swap(let from, let over)? = board.gesture, let over,
              let a = board.layout.frames[from], let b = board.layout.frames[over] else { return }
        for rect in [a, b] {
            let path = NSBezierPath(roundedRect: board.viewRect(rect).insetBy(dx: -2 / scale,
                                                                             dy: -2 / scale),
                                    xRadius: 12 / scale, yRadius: 12 / scale)
            NSColor.controlAccentColor.withAlphaComponent(0.16).setFill()
            path.fill()
            NSColor.controlAccentColor.withAlphaComponent(0.7).setStroke()
            path.lineWidth = 2 / scale
            path.stroke()
        }
    }

    /// The four dots a line is dragged from. Only in connect mode — that is the whole point of the mode:
    /// a board you are reading is cards and lines and nothing else.
    private func drawConnectionAnchors(_ board: CanvasBoardView, _ scale: Double) {
        // Nothing to wire together in a tiled view: the lines are hidden, and a dot that started a line
        // you could not see land would be an offer the mode cannot keep.
        guard board.mode.showsConnectionAnchors, !board.isTiled else { return }
        var ids = board.selection
        if let hovered = board.hovered { ids.insert(hovered) }

        let tester = board.hitTester
        for id in ids {
            guard let node = board.document.node(id: id), !node.isGroup else { continue }
            for side in CanvasSide.allCases {
                let centre = board.viewPoint(tester.anchorPoint(board.layout.frame(of: node), side))
                let radius = 4.5 / scale
                let dot = NSBezierPath(ovalIn: NSRect(x: centre.x - radius, y: centre.y - radius,
                                                     width: radius * 2, height: radius * 2))
                NSColor.controlAccentColor.setFill()
                dot.fill()
                NSColor.windowBackgroundColor.setStroke()
                dot.lineWidth = 1.5 / scale
                dot.stroke()
            }
        }
    }

    /// The eight grips on a selected card. Groups get none: a frame is resized by its own edges, and
    /// eight squares around a 1700pt frame would be eight squares in the middle of nowhere.
    ///
    /// **Quiet.** These used to be drawn at the weight of a thing you are about to act on — a 2.5pt
    /// accent ring and eight filled squares in a 1.5pt accent stroke — which is the weight they have in
    /// a drawing tool, where shaping is the job. Here it isn't: a card is resized by its edge in either
    /// mode now, and the grips only say which card the arrow keys and the eight points belong to. So
    /// the ring is a hairline at half strength and the squares are smaller and thinner. They are still
    /// the loudest thing on a board that has them, which is why they are still a mode.
    private func drawGrips(_ board: CanvasBoardView, _ scale: Double) {
        // A tile's size is the arrangement's to decide, not yours — you resize the split instead. So no
        // grips, and no ring either: in a tiled view the tiles *are* what you are looking at, and a
        // selection ring around one of six is noise.
        guard !board.isTiled else { return }
        // In view mode a selected card answers with a shadow and nothing else — see `CanvasMode` and
        // `CanvasNodeView.refreshElevation`. It is still resizable there; a Mac window has no grips
        // either. Drawing a ring here as well would be the second answer to a question that only
        // wanted one.
        guard board.mode.showsResizeGrips else { return }
        // Nil unless several things are selected, in which case it is what the grips sit on. Asked of
        // the hit tester rather than measured here, so what is drawn and what is clickable are one
        // number.
        let box = board.hitTester.selectionBox
        for id in board.selection {
            guard let node = board.document.node(id: id), board.layout.shows(id) else { continue }
            let rect = board.viewRect(board.layout.frame(of: node))

            // A card you have stepped into gets a halo as well as a ring. The distinction it draws is
            // one you need before you click, not after: on a selected card the next click belongs to
            // the board, and on an engaged one it belongs to whatever is inside the card. A focus
            // glow is the Mac's own way of saying "this is what your input is going to".
            // The halo keeps its weight. It isn't about shaping — it says where your typing is going,
            // which is the one thing on this board worth being emphatic about.
            if board.nodeViews[id]?.isEngaged == true {
                let halo = NSBezierPath(roundedRect: rect.insetBy(dx: -3.5 / scale, dy: -3.5 / scale),
                                        xRadius: 11 / scale, yRadius: 11 / scale)
                halo.lineWidth = 5 / scale
                NSColor.controlAccentColor.withAlphaComponent(0.3).setStroke()
                halo.stroke()
            }

            let ring = NSBezierPath(roundedRect: rect.insetBy(dx: -1 / scale, dy: -1 / scale),
                                    xRadius: 9 / scale, yRadius: 9 / scale)
            ring.lineWidth = 1.25 / scale
            NSColor.controlAccentColor.withAlphaComponent(0.55).setStroke()
            ring.stroke()

            // With several selected the grips move out to the box around them — see below — so a card
            // keeps only its ring, which is now saying "and this one" rather than "grab me here".
            guard !node.isGroup, box == nil else { continue }
            drawHandles(on: board.layout.frame(of: node), board: board, scale: scale)
        }

        // On the box itself, not on the band drawn outside it — the hit tester answers for the box,
        // and grips drawn 5 points out from where they are caught is exactly the kind of near miss
        // that makes a corner feel unreliable.
        if let box { drawHandles(on: box, board: board, scale: scale) }
    }

    /// The box several selected cards are resized by.
    ///
    /// **Out of `drawGrips`, which is why it is here at all.** It used to be drawn inside that pass,
    /// which returns early in view mode — so in view mode a multiple selection had no bounds drawn
    /// around it whatsoever, while still being resizable by exactly those bounds. You could grab an
    /// edge that was never shown to you.
    ///
    /// **The ghost's treatment, at half the weight.** A band standing off the thing it describes, in
    /// the neutral, rather than an accent hairline — the same argument as `CanvasGuideView.drawSlot`,
    /// and the same numbers, so the two marks are visibly the same family. Thinner because they are
    /// not doing the same job: a guide is transient and has one instant to be noticed, and this is
    /// persistent for as long as the selection is, which is the other end of the same trade.
    ///
    /// **Above the cards, where the guide is below them.** A guide marks where a card is *going* and a
    /// card sliding over it should cover it. This marks what you have *got*, including the edge you
    /// are about to grab, and a card lying over that would be hiding a control.
    private func drawSelectionBounds(_ board: CanvasBoardView, _ scale: Double) {
        // Nothing in a tiled view: a tile's bounds are the arrangement's, not yours, and a bracket
        // around three of six tiles is a second grid drawn over the first.
        guard !board.isTiled, let box = board.hitTester.selectionBox else { return }
        let standoff = Self.boundsStandoff / scale
        let rect = board.viewRect(box).insetBy(dx: -standoff, dy: -standoff)
        // Concentric, by the same rule the ghost uses: a curve offset from another curve keeps an even
        // gap only when its radius grows by the offset. On the common case — a box hugging two cards —
        // this lands the band exactly parallel to the corner card's own curve.
        let radius = CanvasNodeView.cornerRadius(for: box) + standoff
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        path.lineWidth = Self.boundsWidth / scale
        CanvasPalette.guide(0.28).setStroke()
        path.stroke()
    }

    /// How far the band stands off the selection, and how thick it is — in view points over the zoom,
    /// so it is the same weight to the eye at 30% as at 200%. The standoff matches the ghost's exactly
    /// and the width is half of it; see `drawSelectionBounds`.
    private static let boundsStandoff: Double = 5
    private static let boundsWidth: Double = 2.5

    /// The eight squares, wherever they belong — on a card, or on the box around a selection.
    private func drawHandles(on frame: CanvasRect, board: CanvasBoardView, scale: Double) {
        let size = 5.5 / scale
        for handle in CanvasHandle.allCases {
            let at = board.viewPoint(handle.point(in: frame))
            let box = NSRect(x: at.x - size / 2, y: at.y - size / 2, width: size, height: size)
            let path = NSBezierPath(ovalIn: box)
            NSColor.windowBackgroundColor.setFill()
            path.fill()
            NSColor.controlAccentColor.withAlphaComponent(0.7).setStroke()
            path.lineWidth = 1 / scale
            path.stroke()
        }
    }

    /// The line being dragged out of a card, before it has anywhere to land.
    ///
    /// Dashed, and routed by the same function that routes a real one, so what you are dragging looks
    /// like what you will get. The target is a zero-sized rectangle at the pointer — a degenerate card
    /// — which lets `canvasRoute` do the work rather than this having a second, nearly-identical curve
    /// of its own.
    private func drawConnectionInFlight(_ board: CanvasBoardView, _ scale: Double) {
        guard case .connect(let id, let side, let to)? = board.gesture,
              let from = board.document.node(id: id) else { return }
        let curve = canvasRoute(from: from.frame, fromSide: side,
                                to: CanvasRect(x: to.x, y: to.y, width: 0, height: 0), toSide: nil)
        board.drawCurve(curve, color: NSColor.controlAccentColor, width: 2.2 / scale,
                        startEnd: .none, endEnd: .arrow, label: nil, dashed: true)
    }

    private func drawMarquee(_ board: CanvasBoardView, _ scale: Double) {
        guard let marquee else { return }
        let rect = board.viewRect(marquee)
        NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
        rect.fill()
        NSColor.controlAccentColor.withAlphaComponent(0.8).setStroke()
        let path = NSBezierPath(rect: rect)
        path.lineWidth = 1 / scale
        path.stroke()
    }
}
