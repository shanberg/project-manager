import AppKit
import PmLib

/// Whether the board is being read or being changed.
///
/// A canvas is read far more often than it is edited — it's a board you come back to look at — and the
/// affordances editing needs are exactly the ones that get in the way of looking. The four connection
/// dots on a card's sides are the clearest case: useful when you're wiring cards together, and visual
/// noise on every card you mouse past when you're not.
///
/// So they are a mode rather than a hover state. In `.view` the board is cards and lines and nothing
/// else; in `.edit` the affordances appear.
///
/// **Selecting and moving work in both; shaping a card does not.** A selected card in view mode says
/// so with a shadow and nothing else — no ring and no eight grips — because on a dashboard
/// selection is a step on the way to *using* a card, not to redrawing it, and a board that answered
/// every click with a full set of editing controls would be a board permanently mid-edit. Nudging a
/// card, on the other hand, is not editing in the sense anyone means, so dragging stays.
enum CanvasMode: String {
    case view, edit

    var showsConnectionAnchors: Bool { self == .edit }

    /// Whether a selected card offers its eight grips — and whether it can be resized at all. The two
    /// are one question: a grip you can drag but cannot see is worse than no grip.
    var showsResizeGrips: Bool { self == .edit }

}

/// One of the eight grips on a selected card.
enum CanvasHandle: CaseIterable {
    case topLeft, top, topRight, left, right, bottomLeft, bottom, bottomRight

    /// Where this grip sits on a card, as a fraction of its frame.
    var unit: (x: Double, y: Double) {
        switch self {
        case .topLeft: return (0, 0)
        case .top: return (0.5, 0)
        case .topRight: return (1, 0)
        case .left: return (0, 0.5)
        case .right: return (1, 0.5)
        case .bottomLeft: return (0, 1)
        case .bottom: return (0.5, 1)
        case .bottomRight: return (1, 1)
        }
    }

    /// Where this grip sits, in the terms the system's own resize cursors are named in.
    var resizePosition: NSCursor.FrameResizePosition {
        switch self {
        case .topLeft: return .topLeft
        case .top: return .top
        case .topRight: return .topRight
        case .left: return .left
        case .right: return .right
        case .bottomLeft: return .bottomLeft
        case .bottom: return .bottom
        case .bottomRight: return .bottomRight
        }
    }

    func point(in frame: CanvasRect) -> CanvasPoint {
        CanvasPoint(x: frame.minX + unit.x * frame.width, y: frame.minY + unit.y * frame.height)
    }

    /// The frame this grip produces when dragged to `point`.
    ///
    /// Each grip moves only the edges it touches, and a card dragged through itself comes back the
    /// right way up rather than inverting — `CanvasRect` is normalised through `minX`/`minY`, but the
    /// stored `width` would go negative and Obsidian would draw nothing.
    func resize(_ frame: CanvasRect, to point: CanvasPoint, minimum: Double = 40) -> CanvasRect {
        var left = frame.minX, top = frame.minY, right = frame.maxX, bottom = frame.maxY
        if unit.x == 0 { left = min(point.x, right - minimum) }
        if unit.x == 1 { right = max(point.x, left + minimum) }
        if unit.y == 0 { top = min(point.y, bottom - minimum) }
        if unit.y == 1 { bottom = max(point.y, top + minimum) }
        return CanvasRect(x: left, y: top, width: right - left, height: bottom - top)
    }
}

/// What lies under a point on the board.
enum CanvasHit: Equatable {
    /// The card itself — a click selects it, a drag moves it.
    case node(String)
    /// A grip on a selected card.
    case handle(String, CanvasHandle)
    /// A connection dot. Only ever returned in `.edit`.
    case anchor(String, CanvasSide)
    /// A line, within a few points of its curve.
    case edge(String)
    /// The board, which is where a marquee starts and a click clears the selection.
    case board
}

/// Reading a point on the board, in the order the eye would.
///
/// Every tolerance here is given in **view points and divided by the zoom**, so a grip is the same
/// physical size to the pointer at 30% as it is at 200%. Hit areas expressed in canvas units would
/// shrink to nothing as you zoom out, which is exactly when a board has the most cards on it.
struct CanvasHitTester {
    var document: CanvasDocument
    /// The scroll view's magnification. 1 is 100%.
    var scale: Double
    var mode: CanvasMode
    var selection: Set<String>
    /// The card the pointer is over, which offers connection dots in `.edit` even when not selected.
    var hovered: String?

    /// Half the side of a grip's hit square, in view points.
    static let handleReach: Double = 7
    /// How near a line has to be clicked, in view points.
    static let edgeReach: Double = 6
    /// How near a group's frame counts as the frame rather than the space inside it.
    static let groupBorderReach: Double = 8
    /// How far out from a card its connection dots sit.
    static let anchorOffset: Double = 11
    static let anchorReach: Double = 8

    func hit(_ point: CanvasPoint) -> CanvasHit {
        // 1. Grips and dots, which sit *on and outside* a card's edge and would otherwise be
        //    unreachable — the card behind them would take every click.
        if mode.showsResizeGrips {
            for id in interactive where selection.contains(id) {
                guard let node = document.node(id: id) else { continue }
                for handle in CanvasHandle.allCases
                where near(handle.point(in: node.frame), point, Self.handleReach) {
                    return .handle(id, handle)
                }
            }
        }
        if mode.showsConnectionAnchors {
            for id in anchorCandidates {
                guard let node = document.node(id: id) else { continue }
                for side in CanvasSide.allCases
                where near(anchorPoint(node.frame, side), point, Self.anchorReach) {
                    return .anchor(id, side)
                }
            }
        }

        // 2. Cards, front to back. Groups are drawn behind everything and are handled below, so a card
        //    inside a frame is always reachable.
        for id in interactive.reversed() {
            guard let node = document.node(id: id), node.frame.contains(x: point.x, y: point.y)
            else { continue }
            return .node(id)
        }

        // 3. Lines. After cards, because a line that passes under a card belongs to the card there.
        for edge in document.edges.reversed() {
            guard let curve = canvasRoute(for: edge, in: document) else { continue }
            if distance(from: point, to: curve) <= Self.edgeReach / scale { return .edge(edge.id) }
        }

        // 4. Groups, on their frame and their label only.
        //
        //    Not their interior: a frame is drawn *around* other cards and usually has a lot of empty
        //    board inside it, and a group that swallowed clicks there would make the space inside a
        //    frame the one place you couldn't start a marquee or clear a selection.
        for node in document.nodes.reversed() where node.isGroup {
            if onFrame(node.frame, point) || inLabel(node, point) { return .node(node.id) }
        }

        return .board
    }

    /// Where a connection dot sits: just outside the middle of a side, so it doesn't cover the card.
    func anchorPoint(_ frame: CanvasRect, _ side: CanvasSide) -> CanvasPoint {
        let base = anchor(of: frame, on: side)
        let out = Self.anchorOffset / scale
        switch side {
        case .top: return CanvasPoint(x: base.x, y: base.y - out)
        case .bottom: return CanvasPoint(x: base.x, y: base.y + out)
        case .left: return CanvasPoint(x: base.x - out, y: base.y)
        case .right: return CanvasPoint(x: base.x + out, y: base.y)
        }
    }

    /// Cards that take a click on their face — everything except groups, in document order.
    private var interactive: [String] {
        document.nodes.filter { !$0.isGroup }.map(\.id)
    }

    /// Which cards hand their edge over to a resize.
    ///
    /// In view mode, any of them — a Mac window does not need selecting before you can grab its edge,
    /// and that is the whole idiom being borrowed. In edit mode, only the selection: the grips are drawn
    /// there, an unselected card is a thing you are about to select, and a band on every card would
    /// make clicking one to select it a coin toss.
    private var resizableByEdge: [String] {
        mode.showsResizeGrips ? interactive.filter(selection.contains) : interactive
    }

    /// Which part of a card's edge a point is on, or nil for its inside — or for a card with no inside
    /// left to speak of.
    ///
    /// The band straddles the edge, `reach` to either side, so it can be grabbed from just outside the
    /// card as well as just in. A corner wins over the two edges that meet at it, because a corner is
    /// the harder thing to aim at and the more useful thing to hit.
    ///
    /// **A card too small to spare its edges keeps all of them.** `reach` is a pointer's width on
    /// screen and so grows in card points as you zoom out; at 8% the band alone is 88 points a side,
    /// which on a small card is the whole card. Resizing it there would cost you moving it and — for a
    /// web card — stepping into it, a far worse trade than not resizing something at a zoom where you
    /// cannot see it. The eight grips still answer for a selected card in edit mode, so nothing becomes
    /// unresizable. It is the same bargain `canvasBoardKeeps` strikes, for the same reason.
    static func edgeHandle(_ frame: CanvasRect, at point: CanvasPoint, reach: Double) -> CanvasHandle? {
        // `inset(by:)` grows, so this is the card plus the band, and `inner` is the card minus it.
        guard frame.inset(by: reach).contains(x: point.x, y: point.y) else { return nil }
        let inner = frame.inset(by: -reach)
        guard inner.width > 40, inner.height > 40 else { return nil }
        guard !inner.contains(x: point.x, y: point.y) else { return nil }

        let onLeft = point.x <= frame.minX + reach
        let onRight = point.x >= frame.maxX - reach
        let onTop = point.y <= frame.minY + reach
        let onBottom = point.y >= frame.maxY - reach

        switch (onTop, onBottom, onLeft, onRight) {
        case (true, _, true, _): return .topLeft
        case (true, _, _, true): return .topRight
        case (_, true, true, _): return .bottomLeft
        case (_, true, _, true): return .bottomRight
        case (true, _, _, _): return .top
        case (_, true, _, _): return .bottom
        case (_, _, true, _): return .left
        case (_, _, _, true): return .right
        default: return nil
        }
    }

    /// Which cards offer connection dots: the selection, plus whatever the pointer is over.
    private var anchorCandidates: [String] {
        var ids = Array(selection)
        if let hovered, !selection.contains(hovered) { ids.append(hovered) }
        return ids
    }

    private func near(_ a: CanvasPoint, _ b: CanvasPoint, _ reach: Double) -> Bool {
        abs(a.x - b.x) <= reach / scale && abs(a.y - b.y) <= reach / scale
    }

    private func onFrame(_ frame: CanvasRect, _ p: CanvasPoint) -> Bool {
        let reach = Self.groupBorderReach / scale
        guard frame.inset(by: reach).contains(x: p.x, y: p.y) else { return false }
        return !frame.inset(by: -reach).contains(x: p.x, y: p.y)
    }

    /// A group's label sits above its top-left corner, and is part of the group for clicking.
    private func inLabel(_ node: CanvasNode, _ p: CanvasPoint) -> Bool {
        guard case .group(let label, _, _) = node.content, let label, !label.isEmpty else { return false }
        let height = 26 / scale
        let width = max(60, Double(label.count) * 9) / scale
        return p.y >= node.frame.minY - height && p.y <= node.frame.minY
            && p.x >= node.frame.minX && p.x <= node.frame.minX + width
    }
}

/// How far `point` is from the nearest place on `curve`.
///
/// Sampled rather than solved. The closed form for the nearest point on a cubic is a fifth-degree
/// root-find, and this is answering "did the pointer land on this line" for a handful of lines per
/// click — forty samples put the answer within a pixel at any zoom anyone uses, and the whole thing
/// stays something a test can check by hand.
func distance(from point: CanvasPoint, to curve: CanvasCurve, samples: Int = 40) -> Double {
    var best = Double.greatestFiniteMagnitude
    for step in 0...samples {
        let p = curve.point(at: Double(step) / Double(samples))
        let d = ((p.x - point.x) * (p.x - point.x) + (p.y - point.y) * (p.y - point.y)).squareRoot()
        best = min(best, d)
    }
    return best
}

// MARK: - Selecting several

/// The cards a marquee has swept, given the rectangle it covers.
///
/// Ordinary cards are taken when the marquee **touches** them, which is what makes a quick sweep
/// across a row of cards pick the row up. Frames are taken only when the marquee covers them
/// **wholly**, because a frame is large and usually has the cards you were actually sweeping inside
/// it — touching would mean every sweep within a frame also picked up the frame, and moving the
/// selection would then move the frame and everything else in it.
func canvasMarqueeSelection(_ rect: CanvasRect, in document: CanvasDocument) -> Set<String> {
    var picked: Set<String> = []
    for node in document.nodes {
        if node.isGroup {
            if rect.contains(node.frame) { picked.insert(node.id) }
        } else if rect.intersects(node.frame) {
            picked.insert(node.id)
        }
    }
    return picked
}

/// Everything that should move when `ids` are dragged.
///
/// A frame carries what it holds. Obsidian's rule, and the reason a frame is worth drawing at all: it
/// says "these belong together", and a grouping that didn't move as one would be a label rather than a
/// group. Membership is decided by containment at the moment of the drag rather than stored, so a card
/// dragged into a frame joins it with nothing to update — which is also how the file works, since the
/// format records no membership at all.
func canvasDragSet(_ ids: Set<String>, in document: CanvasDocument) -> Set<String> {
    var moving = ids
    for node in document.nodes where node.isGroup && ids.contains(node.id) {
        for other in document.nodes where other.id != node.id && node.frame.contains(other.frame) {
            moving.insert(other.id)
        }
    }
    return moving
}

/// Whether a point inside an engaged card still belongs to the board rather than to the card.
///
/// A card you have stepped into hands its clicks to whatever is in it — a text editor, a live web
/// page — and that would otherwise cost you the card itself: its eight grips are drawn over content
/// that is now swallowing every click, so the squares the overlay paints become decorations and the
/// card can no longer be moved or resized without stepping out of it first.
///
/// So the board keeps the band along the card's edge, the same 7 points a grip already claims —
/// measured on screen and divided by the zoom, so it stays the size of a pointer at any magnification.
/// That makes the *whole* border a place to grab the card rather than only the eight spots you have to
/// hunt for.
///
/// It used to keep a second thing: a web card's caption, which was a header and so also, for free, a
/// drag handle. Cards have no headers now, so the band is the whole answer — and being the whole answer
/// for every kind of card is an improvement on being one of two answers for one kind of card.
///
/// A card too small to spare its border keeps all of it. A band is a handle, and a handle that leaves
/// nothing behind it is not worth having — at 8% zoom the band alone would be 88 points, which on a
/// small card is the entire card.
///
/// - Parameters:
///   - point: In the card's own coordinates.
///   - bounds: The card's bounds.
///   - scale: The board's magnification.
func canvasBoardKeeps(_ point: NSPoint, in bounds: NSRect, scale: Double) -> Bool {
    let band = CanvasHitTester.handleReach / max(scale, 0.05)
    let inner = bounds.insetBy(dx: band, dy: band)
    guard inner.width > 40, inner.height > 40 else { return false }
    return !inner.contains(point)
}
