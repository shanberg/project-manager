import Foundation
import PmLib

/// What the board draws to say why a card stopped where it did.
///
/// A snap without a guide is a card that mysteriously refuses to go where you put it. The guide is not
/// decoration — it is the explanation, and it names which other card was responsible.
///
/// **Three claims, because they read differently to the eye and are worth telling apart.** Two cards
/// that agree on an edge are in a row or a column; two cards that are exactly the same width are a
/// set; two cards that are the same size in *both* dimensions are the same shape, which is the
/// strongest thing a snap ever says. And landing on the grid is a claim too — the weakest one, and the
/// one that used to be silent, so a card clicking to a lattice nobody had mentioned looked like a card
/// refusing to go where you put it. Each is drawn as a different amount of the same mark; see
/// `CanvasGuideView`.
enum CanvasGuide: Equatable {
    enum Axis { case vertical, horizontal }

    /// Two or more cards line up here, at `position` on `axis`.
    ///
    /// `cards` is every card in the agreement — the moving set's box first, then each card it matched.
    /// Whole rectangles rather than the stretch each one covers, because what gets drawn is a ghost
    /// around the card itself, and a ghost needs the card's corners as much as its edges. A line
    /// states a coordinate; what is worth saying is *which cards* agree on it.
    case alignment(axis: Axis, position: Double, cards: [CanvasRect])

    /// These cards are the same size along `axes` — `.horizontal` meaning the same width, `.vertical`
    /// the same height, and **both meaning the same size and so the same aspect ratio**.
    ///
    /// One case rather than one per dimension, because "the same width *and* the same height" is not
    /// two facts that happen to be true at once: it is a different and much stronger claim, and the
    /// only one of them worth drawing as a whole shape.
    case sameSize(axes: [Axis], cards: [CanvasRect])

    /// Nothing on the board explained it; the card is where the 10pt lattice put it.
    ///
    /// Only ever emitted when there is no other guide, because the grid is the fallback rather than
    /// the rule — a card that found a real agreement was not placed by the lattice, whatever the
    /// lattice would also have said.
    case grid(CanvasRect)
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
        // Nothing on the board had anything to say, so the lattice is the whole explanation — and
        // saying so is the point: this is the case where a card visibly clicks and nothing on screen
        // admits to it. Emitted whether or not the grid actually had to move the card, because a mark
        // that blinked out every time you crossed an exact multiple of ten would be worse than none.
        if guides.isEmpty, snapsToGrid { guides.append(.grid(settled)) }
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
        // What each axis decided, kept rather than drawn, because a guide describes the card and the
        // card is not finished until both axes and the minimum-size clamp have had their turn. Built
        // as we went, the width guide was drawn around a rectangle with the *old* height in it.
        var aligned: [(axis: CanvasGuide.Axis, position: Double)] = []
        var sizedAxes: [CanvasGuide.Axis] = []
        var landedOnGrid = false

        if handle.unit.x != 0.5 {
            let movingRight = handle.unit.x == 1
            let fixed = movingRight ? left : right
            let edges = others.flatMap { [$0.minX, $0.midX, $0.maxX] }
            let sizes = others.map { movingRight ? fixed + $0.width : fixed - $0.width }

            if let hit = nearest(to: movingRight ? right : left,
                                 among: edges.map { ($0, false) } + sizes.map { ($0, true) },
                                 reach: reach) {
                if movingRight { right = hit.target } else { left = hit.target }
                if hit.isSize { sizedAxes.append(.horizontal) }
                else { aligned.append((.vertical, hit.target)) }
            } else if snapsToGrid {
                if movingRight { right = (right / grid).rounded() * grid }
                else { left = (left / grid).rounded() * grid }
                landedOnGrid = true
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
                if hit.isSize { sizedAxes.append(.vertical) }
                else { aligned.append((.horizontal, hit.target)) }
            } else if snapsToGrid {
                if movingBottom { bottom = (bottom / grid).rounded() * grid }
                else { top = (top / grid).rounded() * grid }
                landedOnGrid = true
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

        let settled = CanvasRect(x: left, y: top, width: right - left, height: bottom - top)
        var guides = aligned.map { guide(axis: $0.axis, at: $0.position, moving: settled, others: others) }
        guides += sizeGuides(sizedAxes, moving: settled, others: others)
        if guides.isEmpty, landedOnGrid { guides.append(.grid(settled)) }
        return CanvasSnapResult(frame: settled, guides: guides)
    }

    /// What the size matches add up to, once the card has finished being resized.
    ///
    /// **The two axes are looked at together, and a card matching on both is one claim.** Dragging a
    /// corner until a card is exactly another's width and exactly its height has made it the same
    /// shape, which is a stronger and more useful thing to be told than the same fact twice.
    ///
    /// **A dimension that was already right counts.** Only the axis the grip is dragging can *snap*,
    /// so a card that was already the right height and has just been dragged to the right width would
    /// otherwise be reported as a width match while sitting there being visibly congruent. The snap is
    /// what starts the sentence; the settled rectangle is what finishes it.
    ///
    /// The matched card is the first of that size on the board, which is the same arbitrary choice the
    /// snap itself made. Naming every card of that width would light up half a board of cards that all
    /// came out of the same template.
    private static func sizeGuides(_ axes: [CanvasGuide.Axis],
                                   moving: CanvasRect,
                                   others: [CanvasRect]) -> [CanvasGuide] {
        guard !axes.isEmpty else { return [] }
        let sameWidth = { (other: CanvasRect) in abs(other.width - moving.width) < 0.001 }
        let sameHeight = { (other: CanvasRect) in abs(other.height - moving.height) < 0.001 }

        if let twin = others.first(where: { sameWidth($0) && sameHeight($0) }) {
            return [.sameSize(axes: [.horizontal, .vertical], cards: [moving, twin])]
        }
        return axes.compactMap { axis in
            let matched = others.first(where: axis == .horizontal ? sameWidth : sameHeight)
            return matched.map { .sameSize(axes: [axis], cards: [moving, $0]) }
        }
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

    /// The cards in agreement at `position`.
    ///
    /// The moving set first, then the cards it matched, in board order. A guide drawn the width of the
    /// board would be true and useless — the point of drawing it is to show *which* cards are in
    /// agreement, and naming them is that fact rather than a summary of it.
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
        return .alignment(axis: axis, position: position, cards: [moving] + matched)
    }
}
