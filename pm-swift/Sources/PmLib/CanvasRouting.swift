import Foundation

/// A point in canvas coordinates.
public struct CanvasPoint: Equatable, Sendable {
    public var x: Double, y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

/// The line between two cards, as the cubic the view draws.
///
/// Canvas coordinates, not view coordinates — the curve is a property of where the cards sit, so it
/// survives a zoom without being recomputed and can be reasoned about in a test with no window.
public struct CanvasCurve: Equatable, Sendable {
    public var start: CanvasPoint
    public var control1: CanvasPoint
    public var control2: CanvasPoint
    public var end: CanvasPoint
    /// The sides actually used, which is what the writer stores when an edge didn't name them.
    public var startSide: CanvasSide
    public var endSide: CanvasSide

    /// The point at `t` along the curve, `0` at the start and `1` at the end. Where a line's label
    /// goes, and how the view finds a point to hit-test a click against.
    public func point(at t: Double) -> CanvasPoint {
        let u = 1 - t
        let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
        return CanvasPoint(x: a * start.x + b * control1.x + c * control2.x + d * end.x,
                           y: a * start.y + b * control1.y + c * control2.y + d * end.y)
    }

    /// The direction the curve is travelling at `t`, normalised. The arrowhead's rotation.
    ///
    /// Falls back to the straight line between the ends where the derivative vanishes — which happens
    /// whenever a control point sits exactly on its anchor, and would otherwise leave an arrowhead
    /// pointing along whatever `atan2(0, 0)` returns.
    public func direction(at t: Double) -> CanvasPoint {
        let u = 1 - t
        let dx = 3 * u * u * (control1.x - start.x) + 6 * u * t * (control2.x - control1.x)
            + 3 * t * t * (end.x - control2.x)
        let dy = 3 * u * u * (control1.y - start.y) + 6 * u * t * (control2.y - control1.y)
            + 3 * t * t * (end.y - control2.y)
        let length = (dx * dx + dy * dy).squareRoot()
        guard length > 0.0001 else {
            let fx = end.x - start.x, fy = end.y - start.y
            let fl = (fx * fx + fy * fy).squareRoot()
            return fl > 0.0001 ? CanvasPoint(x: fx / fl, y: fy / fl) : CanvasPoint(x: 1, y: 0)
        }
        return CanvasPoint(x: dx / length, y: dy / length)
    }

    /// The box the curve stays inside — its ends and its control points.
    ///
    /// A cubic is contained by the hull of its four points, so this is a true bound rather than an
    /// estimate. It is what lets the view skip drawing a line that isn't on screen, and what sizes the
    /// layer a line is drawn into.
    public var bounds: CanvasRect {
        let xs = [start.x, control1.x, control2.x, end.x]
        let ys = [start.y, control1.y, control2.y, end.y]
        return CanvasRect(x: xs.min()!, y: ys.min()!,
                          width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }
}

/// Which sides two cards should be joined on when the edge doesn't say.
///
/// The format makes `fromSide` and `toSide` optional, and Obsidian fills them in from where the cards
/// are: whichever axis they're further apart on wins, and each card offers the side that faces the
/// other. Cards side by side join right-to-left; one above the other joins bottom-to-top.
///
/// The axis is chosen on the **gap** between the cards rather than the distance between their centres,
/// because a wide card above a narrow one has centres that are close horizontally and edges that are
/// nowhere near — measuring centres routes that line out of the side of a card it should have left
/// from the bottom.
public func canvasPreferredSides(from: CanvasRect, to: CanvasRect) -> (CanvasSide, CanvasSide) {
    let horizontalGap = max(to.minX - from.maxX, from.minX - to.maxX)
    let verticalGap = max(to.minY - from.maxY, from.minY - to.maxY)

    if horizontalGap >= verticalGap {
        return to.midX >= from.midX ? (.right, .left) : (.left, .right)
    }
    return to.midY >= from.midY ? (.bottom, .top) : (.top, .bottom)
}

/// The curve joining two cards.
///
/// Each end leaves its card square to the side it's on — the control point is pushed straight out
/// along that side's normal — which is what gives a canvas line its familiar shape: it exits
/// perpendicular, bends once, and arrives perpendicular. Anything else and a line leaving the right
/// edge of a card would appear to graze it.
///
/// How far the control point is pushed sets how much the line bows. Proportional to the distance so
/// long lines bow more than short ones, with a floor so that two cards nearly touching still get a
/// visible curve rather than a kink, and a ceiling so a line across a large board doesn't swing out
/// into the middle of it.
public func canvasRoute(from: CanvasRect,
                        fromSide: CanvasSide?,
                        to: CanvasRect,
                        toSide: CanvasSide?) -> CanvasCurve {
    let preferred = canvasPreferredSides(from: from, to: to)
    let a = fromSide ?? preferred.0
    let b = toSide ?? preferred.1

    let start = anchor(of: from, on: a)
    let end = anchor(of: to, on: b)
    let span = ((end.x - start.x) * (end.x - start.x) + (end.y - start.y) * (end.y - start.y))
        .squareRoot()
    let reach = min(max(40, span * 0.4), 300)
    let na = normal(a), nb = normal(b)

    return CanvasCurve(start: start,
                       control1: CanvasPoint(x: start.x + na.x * reach, y: start.y + na.y * reach),
                       control2: CanvasPoint(x: end.x + nb.x * reach, y: end.y + nb.y * reach),
                       end: end,
                       startSide: a,
                       endSide: b)
}

/// The curve for `edge` within `document`, or nil when either end names a card that isn't there.
///
/// A dangling edge is not an error to report — a canvas hand-edited, or merged from two copies, can
/// hold one, and Obsidian simply doesn't draw it. Nil rather than a crash or a stub line, and the edge
/// is still written back untouched.
public func canvasRoute(for edge: CanvasEdge, in document: CanvasDocument) -> CanvasCurve? {
    guard let from = document.node(id: edge.fromNode), let to = document.node(id: edge.toNode)
    else { return nil }
    return canvasRoute(from: from.frame, fromSide: edge.fromSide, to: to.frame, toSide: edge.toSide)
}

public func anchor(of rect: CanvasRect, on side: CanvasSide) -> CanvasPoint {
    switch side {
    case .top: return CanvasPoint(x: rect.midX, y: rect.minY)
    case .bottom: return CanvasPoint(x: rect.midX, y: rect.maxY)
    case .left: return CanvasPoint(x: rect.minX, y: rect.midY)
    case .right: return CanvasPoint(x: rect.maxX, y: rect.midY)
    }
}

/// The outward unit normal of a side, in canvas coordinates — where y grows downward, so `.top` is
/// negative y.
private func normal(_ side: CanvasSide) -> CanvasPoint {
    switch side {
    case .top: return CanvasPoint(x: 0, y: -1)
    case .bottom: return CanvasPoint(x: 0, y: 1)
    case .left: return CanvasPoint(x: -1, y: 0)
    case .right: return CanvasPoint(x: 1, y: 0)
    }
}
