import AppKit
import PmLib

/// Everything drawn *over* the cards: selection grips, connection dots, the sweep rectangle, and the
/// line being dragged out of a card.
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
    /// The alignment and size agreements found by the drag in progress.
    var guides: [CanvasGuide] = []

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirty: NSRect) {
        guard let board else { return }
        let scale = board.liveScale

        drawConnectionAnchors(board, scale)
        drawGrips(board, scale)
        drawConnectionInFlight(board, scale)
        drawGuides(board, scale)
        drawMarquee(board, scale)
    }

    /// The lines that say why a card stopped where it did.
    ///
    /// Pink rather than the accent colour, and deliberately: the accent already means "selected" on
    /// this board — the ring, the grips, the connection dots — and a guide drawn in it would read as
    /// another piece of the selection rather than as a passing hint about two cards agreeing. It is
    /// the one colour on the board that means only this.
    private func drawGuides(_ board: CanvasBoardView, _ scale: Double) {
        guard !guides.isEmpty else { return }
        let tint = NSColor.systemPink
        tint.setStroke()
        tint.setFill()

        for guide in guides {
            switch guide {
            case .alignment(let axis, let position, let from, let to):
                let path = NSBezierPath()
                let start = axis == .vertical
                    ? board.viewPoint(CanvasPoint(x: position, y: from))
                    : board.viewPoint(CanvasPoint(x: from, y: position))
                let end = axis == .vertical
                    ? board.viewPoint(CanvasPoint(x: position, y: to))
                    : board.viewPoint(CanvasPoint(x: to, y: position))
                path.move(to: start)
                path.line(to: end)
                path.lineWidth = 1 / scale
                path.stroke()

            case .sameSize(let axis, let moving, let matched):
                for rect in [moving, matched] { drawMeasure(rect, axis: axis, board: board, scale: scale) }
            }
        }
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

    /// The four dots a line is dragged from. Only in edit mode — that is the whole point of the mode:
    /// a board you are reading is cards and lines and nothing else.
    private func drawConnectionAnchors(_ board: CanvasBoardView, _ scale: Double) {
        guard board.mode.showsConnectionAnchors else { return }
        var ids = board.selection
        if let hovered = board.hovered { ids.insert(hovered) }

        let tester = board.hitTester
        for id in ids {
            guard let node = board.document.node(id: id), !node.isGroup else { continue }
            for side in CanvasSide.allCases {
                let centre = board.viewPoint(tester.anchorPoint(node.frame, side))
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
    private func drawGrips(_ board: CanvasBoardView, _ scale: Double) {
        // In view mode a selected card answers with a shadow and nothing else — see `CanvasMode` and
        // `CanvasNodeView.refreshElevation`. Drawing a ring here as well would be the second answer to
        // a question that only wanted one.
        guard board.mode.showsResizeGrips else { return }
        for id in board.selection {
            guard let node = board.document.node(id: id) else { continue }
            let rect = board.viewRect(node.frame)

            // A card you have stepped into gets a halo as well as a ring. The distinction it draws is
            // one you need before you click, not after: on a selected card the next click belongs to
            // the board, and on an engaged one it belongs to whatever is inside the card. A focus
            // glow is the Mac's own way of saying "this is what your input is going to".
            if board.nodeViews[id]?.isEngaged == true {
                let halo = NSBezierPath(roundedRect: rect.insetBy(dx: -3.5 / scale, dy: -3.5 / scale),
                                        xRadius: 11 / scale, yRadius: 11 / scale)
                halo.lineWidth = 5 / scale
                NSColor.controlAccentColor.withAlphaComponent(0.3).setStroke()
                halo.stroke()
            }

            let ring = NSBezierPath(roundedRect: rect.insetBy(dx: -1.5 / scale, dy: -1.5 / scale),
                                    xRadius: 9 / scale, yRadius: 9 / scale)
            ring.lineWidth = 2.5 / scale
            NSColor.controlAccentColor.setStroke()
            ring.stroke()

            guard !node.isGroup else { continue }
            let size = 7.0 / scale
            for handle in CanvasHandle.allCases {
                let p = handle.point(in: node.frame)
                let at = board.viewPoint(p)
                let box = NSRect(x: at.x - size / 2, y: at.y - size / 2, width: size, height: size)
                let path = NSBezierPath(roundedRect: box, xRadius: 1.5 / scale, yRadius: 1.5 / scale)
                NSColor.windowBackgroundColor.setFill()
                path.fill()
                NSColor.controlAccentColor.setStroke()
                path.lineWidth = 1.5 / scale
                path.stroke()
            }
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
