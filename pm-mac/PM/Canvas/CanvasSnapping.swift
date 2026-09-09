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
/// **And a quiet mark on the cards it is agreeing with.** The bands were dropped on the argument that
/// the geometry already says which card you matched: collinearity is visible for free, and two gaps of
/// one length side by side is the easiest comparison the eye makes. That is true of the *kind* of
/// agreement and not of the *card*. On a board where six cards share a left edge, "your edge is
/// collinear with one of those" is not the same information as which one — and the difference is worth
/// exactly what it costs at the moment the offer is the one you didn't mean, which is the only moment
/// an offer needs reading at all. So the cards that produced the winning candidate are marked. See
/// `sources`.
///
/// This is not the old bands coming back. Those were one band per kind of claim, drawn around every
/// card in an agreement, at the instant the snap fired. These are the two or three cards that actually
/// won, drawn from the moment the offer appears and fading out with it — still a target, and still
/// about this one placement rather than about everything simultaneously true of the board.
///
/// **It is up before the snap fires, which is the whole of what makes it a target.** A mark that
/// arrived as the card jumped would be a receipt again: there would be nothing left to steer toward.
/// So the search runs out to `CanvasSnapping.showReach` while the snap still fires at
/// `CanvasSnapping.reach`, and everything between the two is an offer — the ghost stands where the card
/// would land and pulling the last few points closes on it.
///
/// **At one opacity the whole time it is up.** It used to be drawn at a strength that tracked how near
/// the match was, on the theory that a mark growing as you approach is the fade saying "you are nearly
/// there". In use it says something else: over most of its range the mark sits at a fraction of an
/// already quiet alpha, which is not a subtle presence but an absent one — the offer you most needed
/// early is the one drawn faintest, and the marks on the cards being agreed with, quieter again, never
/// arrive at all. So there is a threshold and no ramp: within `CanvasSnapping.showReach` the mark fades
/// in, outside it fades out, and in between it simply *is*. How near you are is not something the mark
/// has to report, being already in the hand doing it.
///
/// **Drawn standing off the frame rather than on it**, at `CanvasOverlayView.ghostStandoff`, for the
/// case that is easy to forget: sizing a card *down*. Then the offered frame is inside the card's
/// current bounds and the outline lies across the card itself, which is also why the ghost is drawn
/// above the cards and not below them with the rest of the board's chrome.
struct CanvasGhost: Equatable {
    /// Where the moving box would be. The board turns that into one outline per moving card, since a
    /// bounding box around three dragged cards is a rectangle that matches none of them.
    var frame: CanvasRect

    /// The cards the offer is made against: the one whose edge or extent the ghost is landing on, and
    /// for a gap, the pair whose rhythm it would be joining.
    ///
    /// In canvas coordinates, and never the cards being moved — so unlike `frame`, which the board
    /// translates into one outline per dragged card, these pass through untouched.
    ///
    /// At most a handful, which is what keeps them readable: an alignment names one card and a gap
    /// names two, per axis, so a corner that has caught something in both directions is four marks and
    /// usually fewer. Deduplicated, because the card your left edge found is frequently also the card
    /// your top edge found, and marking it twice would just be drawing it darker.
    var sources: [CanvasRect]
}

/// What a drag or a resize settled on, and what it is offering.
struct CanvasSnapResult: Equatable {
    var frame: CanvasRect
    var ghost: CanvasGhost?
}

/// Snapping a drag or a resize to the cards already on the board.
///
/// Three kinds of agreement are worth catching, and they are different questions. **Alignment** is
/// about position: a card's left edge, centre or right edge sitting exactly where another's does, which
/// is what makes a column read as a column. **Size** is about extent: a card being exactly as wide as
/// another, which is what makes a row of cards read as a set rather than as a row of near-misses.
/// **Spacing** is about rhythm: the gap a card leaves on one side matching the gap on the other, or
/// matching the gap the run beside it is already keeping.
///
/// Spacing is the late arrival and the one the board could not see at all before. It is also the one
/// that answers what a lattice never could: three cards with the same top edge are aligned, and are
/// still not a row until the gaps between them agree. A grid cannot produce that — two cards both
/// sitting on multiples of ten say nothing whatever about the distance between them — which is the
/// whole reason the lattice is a tidier and not a guide. See `gridShift`.
///
/// All three are expressed as candidate positions for a single edge, so they compete on the same terms
/// and the nearer one wins — rather than one being applied on top of another and quietly undoing it.
/// And nothing downstream tells them apart: a target has to say *where*, and which cards put it there,
/// and neither answer depends on which of the three produced it — so the kinds that used to be drawn as
/// three different marks are one rectangle and a few marked cards. See `CanvasGhost`.
///
/// The grid is the fallback, not the rule. Snapping to another card is a stronger statement of intent
/// than snapping to an invisible 10pt lattice, so the grid only gets a say on an axis where nothing
/// aligned. ⌥ turns the lot off, which is what makes snapping safe to have on by default.
///
/// **The lattice gets no ghost, because it is not one of the three.** It used to get a mark of its own
/// — four corners — because a card clicking to a grid nobody had mentioned reads as a card refusing to
/// go where you put it. But the mark was answering the wrong question. A guide exists to promote a
/// *relationship*, and every relationship above needs a second card to exist: an edge is another card's
/// edge, a width is another card's width, a gap is the gap beside it. The lattice needs nothing and
/// relates a card to nothing; it rounds. Drawn, it would be up during every drag, everywhere, for the
/// only claim the board makes that isn't about anything. The dot grid already fades in for the duration
/// of a snapping drag (`CanvasBoardView.showGrid`), which is the right way to show a lattice — under
/// everything, saying where the ground is — so with the ghost silent, "nothing appeared" reliably means
/// "nothing matched", and a 5pt click with no ghost reads as tidying rather than as refusal.
enum CanvasSnapping {
    /// How near counts as a snap: **one grid unit**.
    ///
    /// Tied to the lattice rather than picked, and the tie settles which of the two has the last word.
    /// The lattice never carries a card further than half a unit; a guide reaches a full one. So a
    /// guide always fires first where it applies, and a card that declines a guide as too far — more
    /// than a unit off — can never then be carried further than that guide would have taken it. The
    /// two cannot visibly disagree, and where they both have something to say, the guide wins.
    ///
    /// In **view points**, divided by the zoom at the call site, so it is the same physical distance to
    /// the pointer at 30% as at 200% — while `grid` is in canvas units. The two are the same number
    /// rather than the same measurement, and the number is what was asked for.
    static let reach: Double = grid

    /// How near, in **view points**, counts as worth *offering* — the radius the ghost appears within.
    ///
    /// Much wider than `reach` on purpose, and the gap between the two is the feature: inside `reach`
    /// the card moves, and between the two the board only says what it would do. Too small and the
    /// ghost arrives with the snap and explains a thing that has happened; too large and it is up for
    /// most of every drag and stops meaning anything. Also divided by the zoom at the call site.
    ///
    /// It is now the *only* number governing whether the mark is there, which makes it a stronger
    /// setting than it was: with the ramp gone, everything inside this radius is drawn at full
    /// strength, so what used to be a barely-visible mark at 40pt out is a present one.
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
        //
        // Alignment first of the two on each axis, so it takes a tie. Both are worth having and the
        // nearer one should win, but at the same distance an edge landing on an edge is the plainer
        // thing to have asked for — and a tie broken by argument beats one broken by array order.
        let horizontal = closer(alignment(of: [proposed.minX, proposed.midX, proposed.maxX],
                                          to: edges(of: others, horizontal: true), reach: show),
                                spacing(span(proposed, horizontal: true),
                                        among: others.map { span($0, horizontal: true) }, reach: show))
        let vertical = closer(alignment(of: [proposed.minY, proposed.midY, proposed.maxY],
                                        to: edges(of: others, horizontal: false), reach: show),
                              spacing(span(proposed, horizontal: false),
                                      among: others.map { span($0, horizontal: false) }, reach: show))

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
                                ghost: ghost(of: [horizontal, vertical], at: settle(taking: true), show: show))
    }

    // MARK: Resizing

    /// Where a dragged grip should actually leave the edge it is moving, and what it is being offered.
    ///
    /// Only the edges the grip touches are snapped — a bottom-right grip has no business moving the
    /// top edge onto a guide — and each moving edge considers both kinds of candidate at once: the
    /// positions other cards' edges and centres sit at, and the positions that would make this card
    /// exactly as wide (or as tall) as another.
    ///
    /// **No spacing here**, which is a judgement rather than an omission. A grip moves one edge, so the
    /// only gap it can equalise is the one on that side, and "stretch this card until the space it
    /// leaves matches the space over there" is a thing almost nobody is doing — while the two it
    /// already offers, an edge and a matched extent, are what sizing a card is nearly always for.
    /// Rhythm is made by placing cards, and `move` is where it belongs.
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
            let positions = edges(of: others, horizontal: true)
            let widths = others.map {
                Candidate(value: movingRight ? fixed + $0.width : fixed - $0.width, sources: [$0])
            }
            horizontal = nearest(to: movingRight ? frame.maxX : frame.minX,
                                 among: positions + widths, reach: show)
        }
        var vertical: Hit?
        if handle.unit.y != 0.5 {
            let fixed = movingBottom ? frame.minY : frame.maxY
            let positions = edges(of: others, horizontal: false)
            let heights = others.map {
                Candidate(value: movingBottom ? fixed + $0.height : fixed - $0.height, sources: [$0])
            }
            vertical = nearest(to: movingBottom ? frame.maxY : frame.minY,
                               among: positions + heights, reach: show)
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
                                ghost: ghost(of: [horizontal, vertical], at: settle(taking: true), show: show))
    }

    // MARK: -

    private struct Hit: Equatable {
        var target: Double
        var shift: Double
        /// The cards that put the target there. One for an alignment or a matched extent, two for a
        /// gap. Carried the whole way out so the ghost can name them — see `CanvasGhost.sources`.
        var sources: [CanvasRect]
    }

    /// A position one edge could take, and the cards responsible for it.
    ///
    /// The candidates used to be bare numbers, which was enough while the only question was where the
    /// card goes. Attribution is the reason for the wrapper: a position computed from a card and then
    /// separated from it cannot be traced back afterwards — several cards on a busy board will have an
    /// edge at exactly that number, and picking one of them later would be a guess dressed as an answer.
    private struct Candidate {
        var value: Double
        var sources: [CanvasRect]
    }

    /// Every position another card's edges and centre offer along one axis, each still knowing which
    /// card it came from.
    private static func edges(of others: [CanvasRect], horizontal: Bool) -> [Candidate] {
        others.flatMap { rect in
            (horizontal ? [rect.minX, rect.midX, rect.maxX] : [rect.minY, rect.midY, rect.maxY])
                .map { Candidate(value: $0, sources: [rect]) }
        }
    }

    /// One rectangle reduced to the axis being asked about: where it begins and ends along that axis,
    /// and the band it occupies across it.
    ///
    /// Spacing is the same question twice — gaps left and right, gaps above and below — and written
    /// twice it would be two chances to get one of them subtly wrong. Reduced to this, it is written
    /// once and the axis is an argument.
    private struct Span {
        var lead: Double, trail: Double, crossLead: Double, crossTrail: Double
        /// The card this was reduced from, kept so a gap can say whose gap it is.
        var rect: CanvasRect
    }

    private static func span(_ rect: CanvasRect, horizontal: Bool) -> Span {
        horizontal
            ? Span(lead: rect.minX, trail: rect.maxX,
                   crossLead: rect.minY, crossTrail: rect.maxY, rect: rect)
            : Span(lead: rect.minY, trail: rect.maxY,
                   crossLead: rect.minX, crossTrail: rect.maxX, rect: rect)
    }

    /// Where this box would have to sit for the gaps around it to agree with the gaps already there.
    ///
    /// **Only cards in the same band count.** A gap is a gap between two things you can see abreast of
    /// each other; the distance to a card two screens up is not a gap, it is a coincidence. So the
    /// candidates come only from cards whose span across the other axis overlaps the moving box's,
    /// which is the same test the eye is doing when it decides that four cards are "a row".
    ///
    /// **And only the cards it is actually between.** Every gap present anywhere in the band would be a
    /// dozen offers inside a few hundred points, most of them relating this card to something nobody is
    /// looking at — and a target that could be any of a dozen positions is not a target. So the
    /// neighbour on each side, and that neighbour's own neighbour, and nothing further out.
    ///
    /// That leaves three positions worth naming, and each is a sentence a person would say:
    ///
    /// - *Centred between these two* — the gaps either side come out equal. The one placement that
    ///   turns a card dropped into a hole into a card that belongs in it.
    /// - *Carrying on the run* — the neighbour to the left and the card before it are keeping a pitch,
    ///   and this is where the next card in that rhythm goes. What makes a row of cards a row rather
    ///   than three cards with the same top edge.
    /// - The same, reflected: carrying the run on backwards from the neighbour to the right.
    private static func spacing(_ box: Span, among others: [Span], reach: Double) -> Hit? {
        // Two, not one: one card in the band establishes no rhythm, and offering a gap because a single
        // other card exists would be inventing the pitch rather than continuing one.
        let band = others.filter { $0.crossLead < box.crossTrail && $0.crossTrail > box.crossLead }
        guard band.count > 1 else { return nil }

        let extent = box.trail - box.lead
        let before = band.filter { $0.trail <= box.lead }.max(by: { $0.trail < $1.trail })
        let after = band.filter { $0.lead >= box.trail }.min(by: { $0.lead < $1.lead })

        var candidates: [Candidate] = []
        if let before, let after {
            let room = after.lead - before.trail - extent
            if room >= 0 {
                candidates.append(Candidate(value: before.trail + room / 2,
                                            sources: [before.rect, after.rect]))
            }
        }
        if let before,
           let prior = band.filter({ $0.trail <= before.lead }).max(by: { $0.trail < $1.trail }) {
            candidates.append(Candidate(value: before.trail + (before.lead - prior.trail),
                                        sources: [prior.rect, before.rect]))
        }
        if let after,
           let next = band.filter({ $0.lead >= after.trail }).min(by: { $0.lead < $1.lead }) {
            candidates.append(Candidate(value: after.lead - (next.lead - after.trail) - extent,
                                        sources: [after.rect, next.rect]))
        }
        return nearest(to: box.lead, among: candidates, reach: reach)
    }

    /// Whichever of two offers is nearer, with the tie going to the first.
    private static func closer(_ first: Hit?, _ second: Hit?) -> Hit? {
        guard let second else { return first }
        guard let first else { return second }
        return abs(first.shift) <= abs(second.shift) ? first : second
    }

    /// The offer worth drawing, if there is one.
    ///
    /// **Any one hit puts it up.** A corner drag can be three points from one card's width and forty
    /// from another's height. The ghost draws the frame the two together produce, and it has to appear
    /// as soon as *either* is within sight, or the match you are visibly about to make is the one thing
    /// not on screen. Whether a hit has already been taken makes no difference to that — it is part of
    /// the same offered frame either way, and it was only the ramp that ever needed to tell them apart.
    private static func ghost(of hits: [Hit?], at frame: CanvasRect,
                              show: Double) -> CanvasGhost? {
        // ⌥ collapses both radii to nothing. An exact landing under it is still an exact landing, and
        // still not something to draw a mark about: the modifier means "leave me alone".
        guard show > 0 else { return nil }
        let offers = hits.compactMap { $0 }
        guard !offers.isEmpty else { return nil }

        // Every hit that is part of this frame, taken or still pending, contributes its cards: the axis
        // that has already snapped is as much a part of what the ghost is claiming as the one you are
        // still closing on, and dropping its mark the instant it landed would take the attribution away
        // at exactly the moment it came true.
        var sources: [CanvasRect] = []
        for rect in offers.flatMap(\.sources) where !sources.contains(rect) { sources.append(rect) }

        return CanvasGhost(frame: frame, sources: sources)
    }

    /// The nearest of `candidates` to `value`, within `reach`.
    ///
    /// Ties go to the first, and the order still matters even though nothing downstream distinguishes
    /// the kinds any more: edge candidates are passed before size candidates, so a position that is
    /// both lands on the alignment's target. The two targets are the same number, so the ghost is the
    /// same rectangle either way — but the card's *frame* comes from `target`, and picking
    /// deterministically is worth more than picking meaningfully here.
    private static func nearest(to value: Double, among candidates: [Candidate],
                                reach: Double) -> Hit? {
        var best: Hit?
        for candidate in candidates {
            let shift = candidate.value - value
            guard abs(shift) <= reach else { continue }
            if let current = best, abs(current.shift) <= abs(shift) { continue }
            best = Hit(target: candidate.value, shift: shift, sources: candidate.sources)
        }
        return best
    }

    /// The nearest agreement between any of `mine` and any of `theirs`.
    private static func alignment(of mine: [Double], to theirs: [Candidate], reach: Double) -> Hit? {
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
