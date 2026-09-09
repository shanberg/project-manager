import Foundation
import PmLib

/// The outline the board draws while a card is being placed: the frame that card would have if the
/// match it is near were carried through.
///
/// **A target, not a receipt.** What was here before drew a band around every card in an agreement, at
/// the moment the snap fired — an explanation of something already done. Three kinds of band, one per
/// kind of claim, several of them at once on a busy board, and all of it arriving too late to be any
/// use in placing the card. This is one outline, in one place: where the card is going.
///
/// **The relationship needs no mark of its own.** Losing the bands sounds like losing the answer to
/// "which card did I match", and it isn't, because the geometry says it: the ghost's height *is* the
/// other card's height and that card is on screen, the ghost's edge is collinear with the other card's
/// edge and collinearity is visible for free. The bands were saying a second time what the ghost's
/// position already says. (The case that genuinely goes dark is a match against a card scrolled off
/// screen — where the band was off screen too, and no better.)
///
/// **It is up before the snap fires, which is the whole of what makes it a target.** A mark that
/// arrived as the card jumped would be a receipt again: there would be nothing left to steer toward.
/// So the search runs out to `CanvasSnapping.showReach` while the snap still fires at
/// `CanvasSnapping.reach`, and everything between the two is an offer — the ghost stands where the card
/// would land and pulling the last few points closes on it.
///
/// **Drawn standing off the frame rather than on it**, at `CanvasOverlayView.ghostStandoff`, for the
/// case that is easy to forget: sizing a card *down*. Then the offered frame is inside the card's
/// current bounds and the outline lies across the card itself, which is also why the ghost is drawn
/// above the cards and not below them with the rest of the board's chrome.
struct CanvasGhost: Equatable {
    /// Where the moving box would be. The board turns that into one outline per moving card, since a
    /// bounding box around three dragged cards is a rectangle that matches none of them.
    var frame: CanvasRect

    /// How close the offer is to being taken: 0 at the far edge of the show radius, 1 once the snap
    /// has actually fired. The board multiplies the ghost's alpha by this, so it is faint at the moment
    /// the match becomes possible and solid at the moment it becomes true — which is the fade doing the
    /// work of saying "you are nearly there" instead of merely softening an appearance.
    var nearness: Double
}

/// What a drag or a resize settled on, and what it is offering.
struct CanvasSnapResult: Equatable {
    var frame: CanvasRect
    var ghost: CanvasGhost?
}

/// Snapping a drag or a resize to the cards already on the board.
///
/// Two kinds of agreement are worth catching, and they are different questions. **Alignment** is about
/// position: a card's left edge, centre or right edge sitting exactly where another's does, which is
/// what makes a column read as a column. **Size** is about extent: a card being exactly as wide as
/// another, which is what makes a row of cards read as a set rather than as a row of near-misses.
///
/// Both are expressed as candidate positions for a single edge, so they compete on the same terms and
/// the nearer one wins — rather than one being applied on top of the other and quietly undoing it. And
/// nothing downstream tells them apart any more: a target only has to say *where*, so the two kinds
/// that used to be drawn as two different marks are now one rectangle. See `CanvasGhost`.
///
/// The grid is the fallback, not the rule. Snapping to another card is a stronger statement of intent
/// than snapping to an invisible 10pt lattice, so the grid only gets a say on an axis where nothing
/// aligned. ⌥ turns the lot off, which is what makes snapping safe to have on by default.
///
/// **The lattice gets no ghost.** It used to get a mark of its own — four corners — because a card
/// clicking to a grid nobody had mentioned reads as a card refusing to go where you put it. Under a
/// target that mark would be up during every drag, everywhere, for the weakest claim the board makes,
/// which is the loudest possible answer to the mildest possible complaint. The dot grid already fades
/// in for the duration of a snapping drag (`CanvasBoardView.showGrid`), which announces the lattice
/// far better than a mark on one card ever did — so with the ghost silent, "nothing appeared" now
/// reliably means "nothing matched", and a 5pt click with no ghost reads as tidying rather than as
/// refusal.
enum CanvasSnapping {
    /// How near, in **view points**, counts as a snap. Divided by the zoom at the call site, so it is
    /// the same physical distance to the pointer at 30% as at 200%.
    static let reach: Double = 7

    /// How near, in **view points**, counts as worth *offering* — the radius the ghost appears within.
    ///
    /// Much wider than `reach` on purpose, and the gap between the two is the feature: inside `reach`
    /// the card moves, and between the two the board only says what it would do. Too small and the
    /// ghost arrives with the snap and explains a thing that has happened; too large and it is up for
    /// most of every drag and stops meaning anything. Also divided by the zoom at the call site.
    static let showReach: Double = 48

    static let grid: Double = 10

    // MARK: Moving

    /// Where a dragged card should actually land, and what it is being offered.
    ///
    /// `moving` is the whole dragged set's bounding box, not one card: dragging three cards should
    /// align the group you can see, and snapping to whichever card happened to be under the pointer
    /// would align something the eye isn't following.
    static func move(_ moving: CanvasRect,
                     by delta: (dx: Double, dy: Double),
                     against others: [CanvasRect],
                     reach: Double,
                     showReach: Double = 0,
                     snapsToGrid: Bool = true) -> CanvasSnapResult {
        let proposed = CanvasRect(x: moving.minX + delta.dx, y: moving.minY + delta.dy,
                                  width: moving.width, height: moving.height)
        let show = max(reach, showReach)

        // Searched out to the *show* radius, not the snap's. Everything past `reach` that comes back is
        // an offer rather than a move.
        let horizontal = alignment(of: [proposed.minX, proposed.midX, proposed.maxX],
                                   to: others.flatMap { [$0.minX, $0.midX, $0.maxX] },
                                   reach: show)
        let vertical = alignment(of: [proposed.minY, proposed.midY, proposed.maxY],
                                 to: others.flatMap { [$0.minY, $0.midY, $0.maxY] },
                                 reach: show)

        /// The frame this drag produces — twice, from the same arithmetic. `taking` is the difference
        /// between the two questions: false is "where does the card go", which declines an offer that
        /// is still out of reach and lets the lattice have that axis; true is "where would it go if you
        /// closed the gap", which is the ghost.
        func settle(taking offers: Bool) -> CanvasRect {
            func place(_ start: Double, _ hit: Hit?) -> Double {
                if let hit, offers || abs(hit.shift) <= reach { return start + hit.shift }
                return start + gridShift(start, on: snapsToGrid)
            }
            return CanvasRect(x: place(proposed.minX, horizontal), y: place(proposed.minY, vertical),
                              width: moving.width, height: moving.height)
        }

        return CanvasSnapResult(frame: settle(taking: false),
                                ghost: ghost(of: [horizontal, vertical], at: settle(taking: true),
                                             reach: reach, show: show))
    }

    // MARK: Resizing

    /// Where a dragged grip should actually leave the edge it is moving, and what it is being offered.
    ///
    /// Only the edges the grip touches are snapped — a bottom-right grip has no business moving the
    /// top edge onto a guide — and each moving edge considers both kinds of candidate at once: the
    /// positions other cards' edges and centres sit at, and the positions that would make this card
    /// exactly as wide (or as tall) as another.
    static func resize(_ frame: CanvasRect,
                       handle: CanvasHandle,
                       against others: [CanvasRect],
                       reach: Double,
                       showReach: Double = 0,
                       snapsToGrid: Bool = true) -> CanvasSnapResult {
        let show = max(reach, showReach)
        let movingRight = handle.unit.x == 1
        let movingBottom = handle.unit.y == 1

        var horizontal: Hit?
        if handle.unit.x != 0.5 {
            let fixed = movingRight ? frame.minX : frame.maxX
            let edges = others.flatMap { [$0.minX, $0.midX, $0.maxX] }
            let sizes = others.map { movingRight ? fixed + $0.width : fixed - $0.width }
            horizontal = nearest(to: movingRight ? frame.maxX : frame.minX,
                                 among: edges + sizes, reach: show)
        }
        var vertical: Hit?
        if handle.unit.y != 0.5 {
            let fixed = movingBottom ? frame.minY : frame.maxY
            let edges = others.flatMap { [$0.minY, $0.midY, $0.maxY] }
            let sizes = others.map { movingBottom ? fixed + $0.height : fixed - $0.height }
            vertical = nearest(to: movingBottom ? frame.maxY : frame.minY,
                               among: edges + sizes, reach: show)
        }

        /// Both answers from one piece of arithmetic — see the same function in `move`. Running the
        /// minimum-size clamp inside it is the point of doing it this way: a ghost that promised a
        /// frame the clamp would refuse to give you would be an offer the board cannot keep.
        func settle(taking offers: Bool) -> CanvasRect {
            var left = frame.minX, right = frame.maxX, top = frame.minY, bottom = frame.maxY

            if handle.unit.x != 0.5 {
                if let horizontal, offers || abs(horizontal.shift) <= reach {
                    if movingRight { right = horizontal.target } else { left = horizontal.target }
                } else if snapsToGrid {
                    if movingRight { right = (right / grid).rounded() * grid }
                    else { left = (left / grid).rounded() * grid }
                }
            }
            if handle.unit.y != 0.5 {
                if let vertical, offers || abs(vertical.shift) <= reach {
                    if movingBottom { bottom = vertical.target } else { top = vertical.target }
                } else if snapsToGrid {
                    if movingBottom { bottom = (bottom / grid).rounded() * grid }
                    else { top = (top / grid).rounded() * grid }
                }
            }

            // A card can be dragged through itself; the minimum is what keeps it from coming out
            // inverted, which the format stores happily and Obsidian draws as nothing.
            let minimum = 40.0
            if right - left < minimum {
                if movingRight { right = left + minimum } else { left = right - minimum }
            }
            if bottom - top < minimum {
                if movingBottom { bottom = top + minimum } else { top = bottom - minimum }
            }
            return CanvasRect(x: left, y: top, width: right - left, height: bottom - top)
        }

        return CanvasSnapResult(frame: settle(taking: false),
                                ghost: ghost(of: [horizontal, vertical], at: settle(taking: true),
                                             reach: reach, show: show))
    }

    // MARK: -

    private struct Hit: Equatable {
        var target: Double
        var shift: Double
    }

    /// The offer worth drawing, if there is one, and how near it is to being taken.
    ///
    /// **The nearest *pending* promise governs, not the furthest.** A corner drag can be three points
    /// from one card's width and forty from another's height. The ghost draws both, because both
    /// together are what the frame would be — but it has to appear as soon as *either* is within
    /// sight, or the match you are visibly about to make is the one thing not on screen.
    ///
    /// A hit that has already been taken is not pending and does not hold the ghost back; with none
    /// left pending the snap has fired and the ghost is at full strength, standing off the card it now
    /// contains.
    private static func ghost(of hits: [Hit?], at frame: CanvasRect,
                              reach: Double, show: Double) -> CanvasGhost? {
        // ⌥ collapses both radii to nothing. An exact landing under it is still an exact landing, and
        // still not something to draw a mark about: the modifier means "leave me alone".
        guard show > 0 else { return nil }
        let offers = hits.compactMap { $0 }
        guard !offers.isEmpty else { return nil }
        guard let nearest = offers.map({ abs($0.shift) }).filter({ $0 > reach }).min() else {
            return CanvasGhost(frame: frame, nearness: 1)
        }
        guard show > reach else { return nil }
        // Squared rather than linear, so the ghost stays out of the way over most of its range and
        // arrives over the last few points. Linear, it is a mark that is half-present for half of
        // every drag, which is the loudness this replaced.
        let closeness = max(0, min(1, (show - nearest) / (show - reach)))
        return CanvasGhost(frame: frame, nearness: closeness * closeness)
    }

    /// The nearest of `candidates` to `value`, within `reach`.
    ///
    /// Ties go to the first, and the order still matters even though nothing downstream distinguishes
    /// the kinds any more: edge candidates are passed before size candidates, so a position that is
    /// both lands on the alignment's target. The two targets are the same number, so the ghost is the
    /// same rectangle either way — but the card's *frame* comes from `target`, and picking
    /// deterministically is worth more than picking meaningfully here.
    private static func nearest(to value: Double, among candidates: [Double],
                                reach: Double) -> Hit? {
        var best: Hit?
        for candidate in candidates {
            let shift = candidate - value
            guard abs(shift) <= reach else { continue }
            if let current = best, abs(current.shift) <= abs(shift) { continue }
            best = Hit(target: candidate, shift: shift)
        }
        return best
    }

    /// The nearest agreement between any of `mine` and any of `theirs`.
    private static func alignment(of mine: [Double], to theirs: [Double], reach: Double) -> Hit? {
        var best: Hit?
        for value in mine {
            guard let hit = nearest(to: value, among: theirs, reach: reach) else { continue }
            if let current = best, abs(current.shift) <= abs(hit.shift) { continue }
            best = hit
        }
        return best
    }

    private static func gridShift(_ value: Double, on: Bool) -> Double {
        on ? (value / grid).rounded() * grid - value : 0
    }
}
