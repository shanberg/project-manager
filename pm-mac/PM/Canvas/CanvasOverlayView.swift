import AppKit
import PmLib

/// Everything drawn *over* the cards: the ghost a drag is being offered, selection grips, connection
/// dots, the sweep rectangle, and the line being dragged out of a card.
///
/// Not the tile handlebars, which are the one piece of board chrome that belongs *under* the cards —
/// see `CanvasTileHandleView`.
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

    /// Where the cards being placed would land if the match on offer were taken, and which cards the
    /// offer is being made against. One rectangle per moving card — see `CanvasGhost`, which owns the
    /// argument for all of this.
    struct Ghost: Equatable {
        var frames: [CanvasRect]
        var sources: [CanvasRect]
    }

    /// The offer in front of you, or nil for "nothing is on offer".
    ///
    /// Setting this fades the outline in or out rather than switching it — see `CanvasFade`. The last
    /// non-nil value is held in `drawnGhost` so that clearing this on mouse-up leaves something to fade
    /// *out*; an outline that vanished on the frame the button came up would be the flicker the fade
    /// exists to remove.
    var ghost: Ghost? {
        didSet {
            guard ghost != oldValue else { return }
            if let ghost { drawnGhost = ghost }
            ghostFade.set(ghost != nil)
            needsDisplay = true
        }
    }
    private var drawnGhost: Ghost?
    private lazy var ghostFade = CanvasFade(rise: 0.1, fall: 0.16) { [weak self] in
        self?.needsDisplay = true
    }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirty: NSRect) {
        guard let board else { return }
        let scale = board.liveScale

        // First, so everything else in here sits over it. The ghost is the only mark in this view that
        // is about a card's *future*, and a grip you are dragging should not be interrupted by it.
        drawGhost(board, scale)
        drawConnectionAnchors(board, scale)
        drawSelectionBounds(board, scale)
        drawGrips(board, scale)
        drawConnectionInFlight(board, scale)
        drawSwapInFlight(board, scale)
        drawMarquee(board, scale)
    }

    /// The outline of where the cards being placed would land.
    ///
    /// **One thing governs how present it is: the fade.** There used to be a second, a `nearness` the
    /// alpha was multiplied by, so that the outline grew as the card approached its match. It read as
    /// an argument and drew as a smear — over most of the approach it put the mark at a fraction of an
    /// alpha chosen to be quiet at full strength, which is a mark that is not there. So the offer is
    /// either up or not, and the fade is what keeps that from being a blink: appearing and withdrawing
    /// are both dissolves, and crossing the radius is the only event either of them reports.
    ///
    /// Standing off the frame rather than drawn on it, at the same distance and radius rule the
    /// selection band uses, so the board's transient marks are visibly one family. The standoff earns
    /// its place twice over: at the moment the snap fires the outline is a ring *around* the card
    /// rather than a stroke merged into its border, so the landing is still visible — and when you are
    /// sizing a card *down*, the offered frame is inside the card's current bounds, where a mark on the
    /// border would have nothing to stand on at all.
    ///
    /// **The cards being agreed with glow instead.** They were a thinner copy of the same offset band,
    /// on the argument that one shape twice was one vocabulary — but the two marks are not saying the
    /// same kind of thing, and drawing them alike made the board look like it was offering two slots.
    /// A band stands *off* a frame, which is what makes it read as a place a card is going. A glow sits
    /// *on* the card, hugging its own edge with no gap to cross, and that is the whole difference: this
    /// card is not moving, it is the reason. Softness does the work the reduced weight used to do —
    /// there is no line to compete with the outline, only a card that has been lit.
    ///
    /// They rise and fall on the same fade as the ghost, so the attribution arrives with the offer
    /// rather than with the snap. That is the whole difference between this and the bands it replaced:
    /// those were drawn once the match was made, when there was nothing left to decide.
    private func drawGhost(_ board: CanvasBoardView, _ scale: Double) {
        guard ghostFade.isVisible, let drawnGhost else { return }
        let presence = ghostFade.presence
        guard presence > 0.001 else { return }

        let standoff = Self.ghostStandoff / scale
        // Concentric with the card inside it: a curve offset from another curve keeps an even gap only
        // when its radius grows by the offset. Left at the card's own radius the outline would pinch
        // tight at the corners and bulge along the sides.
        func band(around slot: CanvasRect, width: Double, alpha: Double) {
            let rect = board.viewRect(slot).insetBy(dx: -standoff, dy: -standoff)
            let radius = CanvasNodeView.cornerRadius(for: slot) + standoff
            let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
            path.lineWidth = width / scale
            CanvasPalette.guide(alpha * presence).setStroke()
            path.stroke()
        }

        // A halo hugging the card's own frame, spilling outward only: the fill that casts it is
        // clipped away, so what is left is the shadow's spill and the card's face is untouched. Drawn
        // from the card's own corner radius, since the glow starts where the card ends.
        func glow(on card: CanvasRect) {
            guard let context = NSGraphicsContext.current else { return }
            context.saveGraphicsState()
            defer { context.restoreGraphicsState() }

            let rect = board.viewRect(card)
            let corner = CanvasNodeView.cornerRadius(for: card)
            let shape = NSBezierPath(roundedRect: rect, xRadius: corner, yRadius: corner)

            let spread = Self.sourceGlow / scale
            let outside = NSBezierPath(rect: rect.insetBy(dx: -spread * 3, dy: -spread * 3))
            outside.append(shape)
            outside.windingRule = .evenOdd
            outside.setClip()

            let halo = NSShadow()
            halo.shadowBlurRadius = spread
            halo.shadowOffset = .zero
            halo.shadowColor = CanvasPalette.guide(Self.sourceAlpha * presence)
            halo.set()
            // Opaque, because the alpha that matters is the shadow colour's — this fill is only the
            // shape the blur is taken from, and it never survives the clip.
            CanvasPalette.guide(1).setFill()
            shape.fill()
        }

        // Sources first, so that a ghost landing on top of one of them — which is what a gap being
        // closed looks like — is the mark that survives the overlap.
        for card in drawnGhost.sources {
            glow(on: card)
        }
        for slot in drawnGhost.frames {
            band(around: slot, width: Self.ghostWidth, alpha: 0.30)
        }
    }

    /// How far the outline stands off the frame it is offering, and how thick it is — both in **view
    /// points over the zoom**, so it is the same weight and the same distance to the eye at 30% as at
    /// 200%. Measured in canvas units it would be a smear when zoomed in and invisible when zoomed out,
    /// which is exactly backwards for something whose whole job is to be noticed without being looked
    /// at.
    private static let ghostStandoff: Double = 5
    private static let ghostWidth: Double = 5

    /// The glow on a card the offer is being made against: **8 view points** of spread, over the zoom
    /// like everything else here.
    ///
    /// Its alpha is not comparable to a stroke's and is not derived from one. A blur spreads the same
    /// ink across the whole 8 points, so the brightest part of the halo — right against the card's
    /// edge — is already a fraction of the number below, and it falls off to nothing from there. The
    /// figure that makes a 2.5pt line quietly present makes a glow that is not there at all. Quiet is
    /// still the target: this answers a question you only sometimes ask, and it is up during every drag
    /// that catches on anything.
    private static let sourceGlow: Double = 8
    private static let sourceAlpha: Double = 0.38

    /// The two tiles a drop would exchange, while a tiled view is being rearranged.
    ///
    /// Both of them, and that is the point: a swap is symmetric, and highlighting only the tile under
    /// the pointer would say "this one is the target" when what is about to happen is that these two
    /// change places. Drawn as a filled wash rather than a ring, because at tile size a ring reads as a
    /// selection and this is a preview of an action.
    private func drawSwapInFlight(_ board: CanvasBoardView, _ scale: Double) {
        guard case .swap(let from, let over)? = board.gesture, let over,
              let a = board.layout.frames[from], let b = board.layout.frames[over] else { return }
        for (id, rect) in [(from, a), (over, b)] {
            let standoff = 2 / scale
            // The tile's own corners plus the standoff, which is what keeps an offset curve parallel to
            // the one it is offset from. See `drawSelectionBounds`, which owns the argument.
            //
            // The *tile's*, not the card's: this is the one ring drawn while a tiling is up, and traced
            // at a card's single radius it would be visibly rounder than the two tiles underneath it.
            let corners = board.tileCorners(id)?.radii(inner: CanvasTiling.innerRadius,
                                                       outer: CanvasTiling.outerRadius)
                ?? .uniform(CanvasNodeView.cornerRadius(for: rect))
            let path = CanvasNodeView.path(in: board.viewRect(rect).insetBy(dx: -standoff,
                                                                           dy: -standoff),
                                           radii: corners.grown(by: standoff))
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
            //
            // **Both marks take the card's own corner, and neither divides it by the zoom.** They used
            // to be fixed 11 and 9 around a card whose radius grows with it (`CanvasNodeView`
            // `cornerRadius(for:)`), so a ring was rounder than a small card and squarer than a large
            // one — two curves meant to read as one line and its outline. Dividing by the zoom is right
            // for a hairline, which should hold its weight as you zoom, and wrong for a corner, which
            // is part of the shape and has to zoom with it.
            let corner = CanvasNodeView.cornerRadius(for: board.layout.frame(of: node))
            if board.nodeViews[id]?.isEngaged == true {
                let standoff = 3.5 / scale
                let halo = NSBezierPath(roundedRect: rect.insetBy(dx: -standoff, dy: -standoff),
                                        xRadius: corner + standoff, yRadius: corner + standoff)
                halo.lineWidth = 5 / scale
                NSColor.controlAccentColor.withAlphaComponent(0.3).setStroke()
                halo.stroke()
            }

            let standoff = 1 / scale
            let ring = NSBezierPath(roundedRect: rect.insetBy(dx: -standoff, dy: -standoff),
                                    xRadius: corner + standoff, yRadius: corner + standoff)
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
    /// the neutral, rather than an accent hairline — the same argument as `drawGhost`, and the same
    /// standoff, so the two marks are visibly the same family. Thinner because they are not doing the
    /// same job: the ghost is transient and has one instant to be noticed, and this is persistent for
    /// as long as the selection is, which is the other end of the same trade.
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
