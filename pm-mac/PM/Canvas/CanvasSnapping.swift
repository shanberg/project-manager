import Foundation
import PmLib

/// A line the board draws to say why a card stopped where it did.
///
/// A snap without a guide is a card that mysteriously refuses to go where you put it. The guide is not
/// decoration — it is the explanation, and it names which other card was responsible.
enum CanvasGuide: Equatable {
    enum Axis { case vertical, horizontal }

    /// Two or more cards line up here. Drawn at `position` on `axis`, spanning `from`…`to` along the
    /// other axis so it reaches from the card being moved to the card it matched and no further.
    case alignment(axis: Axis, position: Double, from: Double, to: Double)

    /// These two are now the same width (or height). Drawn as a measured bar over each.
    case sameSize(axis: Axis, moving: CanvasRect, matched: CanvasRect)
}

/// What a drag or a resize settled on.
struct CanvasSnapResult: Equatable {
    var frame: CanvasRect
    var guides: [CanvasGuide]
}

/// Snapping a drag or a resize to the cards already on the board.
///
/// Two kinds of agreement are worth catching, and they are different questions. **Alignment** is about
/// position: a card's left edge, centre or right edge sitting exactly where another's does, which is
/// what makes a column read as a column. **Size** is about extent: a card being exactly as wide as
/// another, which is what makes a row of cards read as a set rather than as a row of near-misses.
///
/// Both are expressed as candidate positions for a single edge, so they compete on the same terms and
/// the nearer one wins — rather than one being applied on top of the other and quietly undoing it.
///
/// The grid is the fallback, not the rule. Snapping to another card is a stronger statement of intent
/// than snapping to an invisible 10pt lattice, so the grid only gets a say on an axis where nothing
/// aligned. ⌥ turns the lot off, which is what makes snapping safe to have on by default.
enum CanvasSnapping {
    /// How near, in **view points**, counts as a snap. Divided by the zoom at the call site, so it is
    /// the same physical distance to the pointer at 30% as at 200%.
    static let reach: Double = 7
    static let grid: Double = 10

    // MARK: Moving

    /// Where a dragged card should actually land.
    ///
    /// `moving` is the whole dragged set's bounding box, not one card: dragging three cards should
    /// align the group you can see, and snapping to whichever card happened to be under the pointer
    /// would align something the eye isn't following.
    static func move(_ moving: CanvasRect,
                     by delta: (dx: Double, dy: Double),
                     against others: [CanvasRect],
                     reach: Double,
                     snapsToGrid: Bool = true) -> CanvasSnapResult {
        let proposed = CanvasRect(x: moving.minX + delta.dx, y: moving.minY + delta.dy,
                                  width: moving.width, height: moving.height)

        let horizontal = alignment(of: [proposed.minX, proposed.midX, proposed.maxX],
                                   to: others.flatMap { [$0.minX, $0.midX, $0.maxX] },
                                   reach: reach)
        let vertical = alignment(of: [proposed.minY, proposed.midY, proposed.maxY],
                                 to: others.flatMap { [$0.minY, $0.midY, $0.maxY] },
                                 reach: reach)

        var x = proposed.minX + (horizontal?.shift ?? gridShift(proposed.minX, on: snapsToGrid))
        var y = proposed.minY + (vertical?.shift ?? gridShift(proposed.minY, on: snapsToGrid))
        if horizontal == nil && !snapsToGrid { x = proposed.minX }
        if vertical == nil && !snapsToGrid { y = proposed.minY }

        let settled = CanvasRect(x: x, y: y, width: moving.width, height: moving.height)
        var guides: [CanvasGuide] = []
        if let horizontal {
            guides.append(guide(axis: .vertical, at: horizontal.target, moving: settled, others: others))
        }
        if let vertical {
            guides.append(guide(axis: .horizontal, at: vertical.target, moving: settled, others: others))
        }
        return CanvasSnapResult(frame: settled, guides: guides)
    }

    // MARK: Resizing

    /// Where a dragged grip should actually leave the edge it is moving.
    ///
    /// Only the edges the grip touches are snapped — a bottom-right grip has no business moving the
    /// top edge onto a guide — and each moving edge considers both kinds of candidate at once: the
    /// positions other cards' edges and centres sit at, and the positions that would make this card
    /// exactly as wide (or as tall) as another.
    static func resize(_ frame: CanvasRect,
                       handle: CanvasHandle,
                       against others: [CanvasRect],
                       reach: Double,
                       snapsToGrid: Bool = true) -> CanvasSnapResult {
        var left = frame.minX, right = frame.maxX, top = frame.minY, bottom = frame.maxY
        var guides: [CanvasGuide] = []

        if handle.unit.x != 0.5 {
            let movingRight = handle.unit.x == 1
            let fixed = movingRight ? left : right
            let edges = others.flatMap { [$0.minX, $0.midX, $0.maxX] }
            let sizes = others.map { movingRight ? fixed + $0.width : fixed - $0.width }

            if let hit = nearest(to: movingRight ? right : left,
                                 among: edges.map { ($0, false) } + sizes.map { ($0, true) },
                                 reach: reach) {
                if movingRight { right = hit.target } else { left = hit.target }
                if hit.isSize {
                    let width = abs(right - left)
                    if let matched = others.first(where: { abs($0.width - width) < 0.001 }) {
                        guides.append(.sameSize(axis: .horizontal,
                                                moving: CanvasRect(x: left, y: top,
                                                                   width: right - left, height: bottom - top),
                                                matched: matched))
                    }
                } else {
                    guides.append(guide(axis: .vertical, at: hit.target,
                                        moving: CanvasRect(x: left, y: top,
                                                           width: right - left, height: bottom - top),
                                        others: others))
                }
            } else if snapsToGrid {
                if movingRight { right = (right / grid).rounded() * grid }
                else { left = (left / grid).rounded() * grid }
            }
        }

        if handle.unit.y != 0.5 {
            let movingBottom = handle.unit.y == 1
            let fixed = movingBottom ? top : bottom
            let edges = others.flatMap { [$0.minY, $0.midY, $0.maxY] }
            let sizes = others.map { movingBottom ? fixed + $0.height : fixed - $0.height }

            if let hit = nearest(to: movingBottom ? bottom : top,
                                 among: edges.map { ($0, false) } + sizes.map { ($0, true) },
                                 reach: reach) {
                if movingBottom { bottom = hit.target } else { top = hit.target }
                if hit.isSize {
                    let height = abs(bottom - top)
                    if let matched = others.first(where: { abs($0.height - height) < 0.001 }) {
                        guides.append(.sameSize(axis: .vertical,
                                                moving: CanvasRect(x: left, y: top,
                                                                   width: right - left, height: bottom - top),
                                                matched: matched))
                    }
                } else {
                    guides.append(guide(axis: .horizontal, at: hit.target,
                                        moving: CanvasRect(x: left, y: top,
                                                           width: right - left, height: bottom - top),
                                        others: others))
                }
            } else if snapsToGrid {
                if movingBottom { bottom = (bottom / grid).rounded() * grid }
                else { top = (top / grid).rounded() * grid }
            }
        }

        // A card can be dragged through itself; the minimum is what keeps it from coming out inverted,
        // which the format stores happily and Obsidian draws as nothing.
        let minimum = 40.0
        if right - left < minimum {
            if handle.unit.x == 1 { right = left + minimum } else { left = right - minimum }
        }
        if bottom - top < minimum {
            if handle.unit.y == 1 { bottom = top + minimum } else { top = bottom - minimum }
        }

        return CanvasSnapResult(frame: CanvasRect(x: left, y: top,
                                                  width: right - left, height: bottom - top),
                                guides: guides)
    }

    // MARK: -

    private struct Hit: Equatable {
        var target: Double
        var shift: Double
        var isSize: Bool
    }

    /// The nearest of `candidates` to `value`, within `reach`.
    ///
    /// Ties go to the first, and the order matters: edge candidates are passed before size candidates,
    /// so a position that is both an alignment and a size match is reported as the alignment — the
    /// stronger and more obvious of the two readings.
    private static func nearest(to value: Double,
                                among candidates: [(Double, Bool)],
                                reach: Double) -> Hit? {
        var best: Hit?
        for (candidate, isSize) in candidates {
            let shift = candidate - value
            guard abs(shift) <= reach else { continue }
            if let current = best, abs(current.shift) <= abs(shift) { continue }
            best = Hit(target: candidate, shift: shift, isSize: isSize)
        }
        return best
    }

    /// The nearest agreement between any of `mine` and any of `theirs`.
    private static func alignment(of mine: [Double], to theirs: [Double], reach: Double) -> Hit? {
        var best: Hit?
        for value in mine {
            guard let hit = nearest(to: value, among: theirs.map { ($0, false) }, reach: reach)
            else { continue }
            if let current = best, abs(current.shift) <= abs(hit.shift) { continue }
            best = hit
        }
        return best
    }

    private static func gridShift(_ value: Double, on: Bool) -> Double {
        on ? (value / grid).rounded() * grid - value : 0
    }

    /// A guide line long enough to reach from the moving card to the furthest card it agrees with, and
    /// no longer. A line drawn the width of the board would be true and useless — the point of drawing
    /// it is to show *which* cards are in agreement.
    private static func guide(axis: CanvasGuide.Axis,
                              at position: Double,
                              moving: CanvasRect,
                              others: [CanvasRect]) -> CanvasGuide {
        let matched = others.filter { other in
            let candidates = axis == .vertical
                ? [other.minX, other.midX, other.maxX]
                : [other.minY, other.midY, other.maxY]
            return candidates.contains { abs($0 - position) < 0.001 }
        }
        var low = axis == .vertical ? moving.minY : moving.minX
        var high = axis == .vertical ? moving.maxY : moving.maxX
        for other in matched {
            low = min(low, axis == .vertical ? other.minY : other.minX)
            high = max(high, axis == .vertical ? other.maxY : other.maxX)
        }
        return .alignment(axis: axis, position: position, from: low, to: high)
    }
}
