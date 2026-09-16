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
/// **And a mark on each card it is agreeing with, saying what about it agrees.** The bands were dropped
/// on the argument that the geometry already says which card you matched: collinearity is visible for
/// free, and two gaps of one length side by side is the easiest comparison the eye makes. That is true
/// of the *kind* of agreement and not of the *card*, and not of the *edge*. A glow round the whole card
/// said "this one"; on a board where six cards share a left edge and two of them are also your width,
/// "this one" is not the same information as "its left edge", and the difference is worth exactly what
/// it costs at the moment the offer is the one you didn't mean — the only moment an offer needs reading
/// at all. So each match is marked by the piece of the card that makes it: the side an edge is on, the
/// middle a centre is at, the gap a spacing keeps, the side a length is measured along. See
/// `CanvasMatch`.
///
/// This is not the old bands coming back. Those were one band per kind of claim, drawn around every
/// card in an agreement, at the instant the snap fired. These are pieces of the landing's own outline —
/// the same band at the same standoff — drawn from the moment the offer appears and fading out with it:
/// still a target, and still about this one placement.
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
/// already quiet alpha, which is not a subtle presence but an absent one. So there is a threshold and
/// no ramp: within `CanvasSnapping.showReach` the mark fades in, outside it fades out, and in between it
/// simply *is*. What does vary is how far *away* a marked card is — see `CanvasOverlayView.fade` — which
/// is a different question: not how near your hand is, but how much that card is worth pointing at.
///
/// **Drawn standing off the frame rather than on it**, at `CanvasOverlayView.ghostStandoff`, for the
/// case that is easy to forget: sizing a card *down*. Then the offered frame is inside the card's
/// current bounds and the outline lies across the card itself, which is also why the ghost is drawn
/// above the cards being placed.
///
/// **And beneath every other card.** The standoff that keeps the outline clear of the card it is
/// offering puts it across any card that card is landing beside, and a ring drawn over a neighbour's
/// face reads as a mark on the neighbour. So the overlay clips the cards standing still out of it —
/// see `CanvasOverlayView.drawGhost`.
struct CanvasGhost: Equatable {
    /// Where the moving box would be. The board turns that into one outline per moving card, since a
    /// bounding box around three dragged cards is a rectangle that matches none of them.
    var frame: CanvasRect

    /// Everything the landing agrees with, one entry per mark.
    ///
    /// **Every agreement, not only the one the search found.** The search needs one answer per axis;
    /// the eye needs every card that answer is true of. A left edge landing on a line six cards share
    /// lands on all six, and marking only the one the arithmetic happened to reach first names a card
    /// at random. So once the frame is settled it is compared against the board again — every edge and
    /// centre on the matched line, every card of the matched length, every gap along the row that keeps
    /// the matched pitch — and then **collapsed**: see `CanvasMatch.level`.
    var matches: [CanvasMatch]

    /// Whether the offer decides every coordinate the drag is moving — both axes for a move, each axis
    /// the grip moves for a resize. The landing outline is drawn only when it does; until then the
    /// landing gets the marks the other cards get. See `CanvasOverlayView.drawGhost`.
    ///
    /// **An outline is a claim about the whole frame.** Drawn for a match on one axis it promised a
    /// place the board had only half decided: the other coordinate was wherever your hand happened to
    /// be, and the "landing" slid along with the card as you moved it. On a board with any order in it
    /// one axis is nearly always matched by something, so the outline was up for most of every drag
    /// and stopped saying anything. A mark on the matched side says exactly as much as is true.
    var isComplete: Bool

    /// The cards the offer is made against, each once, in the order the matches name them.
    var sources: [CanvasRect] {
        var cards: [CanvasRect] = []
        for match in matches where !cards.contains(match.card) { cards.append(match.card) }
        return cards
    }
}

/// One agreement between the landing and a card standing still — what one match mark is drawn from.
///
/// Four kinds, and they are the four sentences a mark has to be able to say without a number or a
/// tick: *your edge is on this edge*, *you are this long*, *you are level with this*, and *this gap,
/// again*. Everything is in canvas coordinates and about cards that are not moving.
enum CanvasMatch: Equatable {
    /// `card`'s leading edge, centre or trailing edge along the axis lies on a line the landing's own
    /// edge or centre lies on. Marked on the side of `card` that edge is, or, for a centre, by a notch
    /// in the middle of the side facing the landing.
    case edge(CanvasRect, horizontal: Bool, part: CanvasSpanPart)

    /// `card` is exactly as long as the landing along the axis — as wide, or as tall. Marked on the
    /// side that measures it, on both cards.
    case length(CanvasRect, horizontal: Bool)

    /// `card` begins and ends where the landing does along the axis: the two are level.
    ///
    /// **What three edge marks and a length collapse into.** A card sharing your top, your centre and
    /// your bottom — which any card of your height beside you does — used to be three marks and a
    /// fourth for the height, all saying one thing. Two positions agreeing implies the third and the
    /// extent, so it is one fact, and one mark: on the side of the card facing you. Dropped altogether
    /// for a card a gap mark already names on the other axis, since it is then part of the row the gap
    /// is about and marking it twice would be the same card twice.
    case level(CanvasRect, horizontal: Bool)

    /// One of the equal gaps a spacing match is keeping — the one either side of a card centred in a
    /// hole, or every gap along a run that keeps the pitch.
    case gap(CanvasGap)

    /// The card this is about: the one marked, or for a gap the one on its far side from the landing.
    var card: CanvasRect {
        switch self {
        case .edge(let card, _, _), .length(let card, _), .level(let card, _): card
        case .gap(let gap): gap.far
        }
    }
}

/// Where along an axis a card's edge or centre is.
enum CanvasSpanPart: Equatable {
    case lead, middle, trail

    /// This part of `rect`, along the axis.
    func value(in rect: CanvasRect, horizontal: Bool) -> Double {
        switch self {
        case .lead: horizontal ? rect.minX : rect.minY
        case .middle: horizontal ? rect.midX : rect.midY
        case .trail: horizontal ? rect.maxX : rect.maxY
        }
    }
}

/// The space between two facing edges along an axis, and the band across the axis both sides share —
/// the stretch a gap mark bridges.
struct CanvasGap: Equatable {
    var horizontal: Bool
    /// Where the gap begins and ends along the axis.
    var lead: Double, trail: Double
    /// The band across the axis that both sides of the gap occupy.
    var crossLead: Double, crossTrail: Double
    /// The card on the side away from the landing, which is what the mark's distance is measured to.
    var far: CanvasRect
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
/// Each candidate keeps what it is *about* (see `Claim`), which the search ignores and the marks are
/// drawn from: a target has to say where, and a mark has to say which edge, which length, which gap.
///
/// The grid is the fallback, not the rule. Snapping to another card is a stronger statement of intent
/// than snapping to an invisible 10pt lattice, so the grid only gets a say on an axis where nothing
/// aligned. ⌘ or ⌃ turns the lot off, which is what makes snapping safe to have on by default.
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

    /// How near, in **view points**, counts as worth *offering* — the furthest the ghost appears from.
    ///
    /// Much wider than `reach` on purpose, and the gap between the two is the feature: inside `reach`
    /// the card moves, and between the two the board only says what it would do. Too small and the
    /// ghost arrives with the snap and explains a thing that has happened; too large and it is up for
    /// most of every drag and stops meaning anything. Also divided by the zoom at the call site.
    ///
    /// The *furthest*, not the distance every line offers from: where lines are crowded each offers
    /// from less — see `Reach`.
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
        let across = Reach(show: show, snap: reach, lines: lines(of: others, horizontal: true))
        let down = Reach(show: show, snap: reach, lines: lines(of: others, horizontal: false))

        // Searched out to the *show* radius, not the snap's. Everything past `reach` that comes back is
        // an offer rather than a move.
        //
        // Alignment first of the two on each axis, so it takes a tie. Both are worth having and the
        // nearer one should win, but at the same distance an edge landing on an edge is the plainer
        // thing to have asked for — and a tie broken by argument beats one broken by array order.
        let horizontal = closer(alignment(of: proposed, against: others, horizontal: true, reach: across),
                                spacing(span(proposed, horizontal: true),
                                        among: others.map { span($0, horizontal: true) }, reach: across))
        let vertical = closer(alignment(of: proposed, against: others, horizontal: false, reach: down),
                              spacing(span(proposed, horizontal: false),
                                      among: others.map { span($0, horizontal: false) }, reach: down))

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
                                ghost: ghost(horizontal, vertical, at: settle(taking: true),
                                             against: others,
                                             complete: horizontal != nil && vertical != nil,
                                             show: show))
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
                Candidate(value: movingRight ? fixed + $0.width : fixed - $0.width, claim: .length($0))
            }
            horizontal = nearest(to: movingRight ? frame.maxX : frame.minX, among: positions + widths,
                                 reach: Reach(show: show, snap: reach,
                                              lines: lines(of: others, horizontal: true)))
        }
        var vertical: Hit?
        if handle.unit.y != 0.5 {
            let fixed = movingBottom ? frame.minY : frame.maxY
            let positions = edges(of: others, horizontal: false)
            let heights = others.map {
                Candidate(value: movingBottom ? fixed + $0.height : fixed - $0.height, claim: .length($0))
            }
            vertical = nearest(to: movingBottom ? frame.maxY : frame.minY, among: positions + heights,
                               reach: Reach(show: show, snap: reach,
                                            lines: lines(of: others, horizontal: false)))
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

        // Complete once every axis the grip moves is matched: one for a side, both for a corner.
        let complete = (handle.unit.x == 0.5 || horizontal != nil)
            && (handle.unit.y == 0.5 || vertical != nil)
        return CanvasSnapResult(frame: settle(taking: false),
                                ghost: ghost(horizontal, vertical, at: settle(taking: true),
                                             against: others, complete: complete, show: show))
    }

    // MARK: Tidiness

    /// How tidy a set of cards already is, from 0 to 1: the share of them with an edge or centre on
    /// another's, counted once per axis.
    ///
    /// **The guides are worth less the tidier the board.** On a clean board nearly every placement
    /// matches something, and several things: the marks are everywhere and the nearest few are all
    /// that need saying. On an untidy one a match is rare, and a card lining up with one across the
    /// window is news. So `CanvasOverlayView.fade` lets marks on distant cards go further and fainter
    /// as this rises. Asked of the cards on screen — a tidy corner of a sprawling board is tidy.
    ///
    /// Sorted rather than compared pairwise, because it is asked on every event of a drag and a
    /// zoomed-out board can have a few hundred cards in view.
    static func tidiness(of cards: [CanvasRect]) -> Double {
        guard cards.count > 1 else { return 0 }
        var lined = 0
        for horizontal in [true, false] {
            let lines = cards.indices.flatMap { index in
                [CanvasSpanPart.lead, .middle, .trail].map {
                    (value: $0.value(in: cards[index], horizontal: horizontal), card: index)
                }
            }.sorted { $0.value < $1.value }
            var found = Set<Int>()
            for (i, line) in lines.enumerated() {
                var j = i + 1
                while j < lines.count, lines[j].value - line.value < 0.5 {
                    if lines[j].card != line.card {
                        found.insert(line.card)
                        found.insert(lines[j].card)
                    }
                    j += 1
                }
            }
            lined += found.count
        }
        return Double(lined) / Double(2 * cards.count)
    }

    // MARK: -

    private struct Hit: Equatable {
        var target: Double
        var shift: Double
        /// What put the target there, carried the whole way out so the ghost can say — see `Claim`.
        var claim: Claim
    }

    /// What a candidate position is *about*: nothing the search needs, and everything a mark does.
    ///
    /// The candidates used to be bare numbers, which was enough while the only question was where the
    /// card goes. A position computed from a card and then separated from it cannot be traced back
    /// afterwards — several cards on a busy board will have an edge at exactly that number, and picking
    /// one of them later would be a guess dressed as an answer.
    private enum Claim: Equatable {
        /// One of this card's edges, or its centre.
        case edge(CanvasRect, CanvasSpanPart)
        /// This card's extent along the axis, measured from the edge staying put.
        case length(CanvasRect)
        /// Equal gaps either side, between these two.
        case between(CanvasRect, CanvasRect)
        /// The pitch these two keep, carried on past the second.
        case run(CanvasRect, CanvasRect)
        /// The pitch these two keep, carried on backwards before the first.
        case runBack(CanvasRect, CanvasRect)
        /// A grid unit clear of the only other card — after it, or before it.
        case beside(CanvasRect, after: Bool)
    }

    /// A position one edge could take, and what it would be agreeing with.
    private struct Candidate {
        var value: Double
        var claim: Claim
    }

    /// How far out a line is offered from, along one axis.
    ///
    /// **The full `showReach` where lines are sparse, and less where they are crowded.** Every card
    /// brings three lines to each axis, and on a board of narrow cards, or an untidy one, 48 points
    /// either side of every one of them covers nearly all the ground there is: the ghost was up for
    /// most of every drag, offering whichever line was nearest at that instant, and flicking to the
    /// next one as you passed. Offered from half the distance to the next line instead, an offer only
    /// goes up where it is plainly the nearest thing, and two neighbouring lines never offer over each
    /// other.
    ///
    /// **Never less than the snap**, which is untouched: how near a card has to be to *move* is a
    /// matter of the hand, and the same everywhere. Only how early the board says so changes.
    private struct Reach {
        var show: Double
        var snap: Double
        /// Every card's edges and centre along this axis, sorted. Duplicates are left in; `of` steps
        /// over them.
        var lines: [Double]

        func of(_ value: Double) -> Double {
            guard show > snap else { return show }
            var low = 0, high = lines.count
            while low < high {
                let mid = (low + high) / 2
                if lines[mid] < value { low = mid + 1 } else { high = mid }
            }
            var room = Double.infinity
            var up = low
            while up < lines.count, lines[up] - value <= 0.01 { up += 1 }
            if up < lines.count { room = lines[up] - value }
            var down = low - 1
            while down >= 0, value - lines[down] <= 0.01 { down -= 1 }
            if down >= 0 { room = min(room, value - lines[down]) }
            return min(show, max(snap, room / 2))
        }
    }

    private static func lines(of others: [CanvasRect], horizontal: Bool) -> [Double] {
        others.flatMap { rect in
            [CanvasSpanPart.lead, .middle, .trail].map { $0.value(in: rect, horizontal: horizontal) }
        }.sorted()
    }

    /// Every position another card's edges and centre offer along one axis, each still knowing which
    /// card and which part of it it came from.
    private static func edges(of others: [CanvasRect], horizontal: Bool) -> [Candidate] {
        others.flatMap { rect in
            [CanvasSpanPart.lead, .middle, .trail].map {
                Candidate(value: $0.value(in: rect, horizontal: horizontal), claim: .edge(rect, $0))
            }
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
    ///
    /// **Except when there is only one other card at all.** Then there is no rhythm to continue, but
    /// there is still a placement worth offering: one grid unit clear of it, on either side. The edge
    /// that would have put the two flush is withdrawn in its place (see `alignment(of:against:)`) —
    /// flush is where the ghost's outline lies across the other card, and a second card placed next to
    /// a first is nearly always meant to sit beside it rather than be glued to it.
    private static func spacing(_ box: Span, among others: [Span], reach: Reach) -> Hit? {
        if others.count == 1 {
            guard let lone = others.first, abreast(lone, box) else { return nil }
            let extent = box.trail - box.lead
            return nearest(to: box.lead, among: [
                Candidate(value: lone.trail + grid, claim: .beside(lone.rect, after: true)),
                Candidate(value: lone.lead - grid - extent, claim: .beside(lone.rect, after: false)),
            ], reach: reach)
        }

        // Two, not one: one card in the band establishes no rhythm, and offering a gap because a single
        // card in the band exists would be inventing the pitch rather than continuing one.
        let band = others.filter { abreast($0, box) }
        guard band.count > 1 else { return nil }

        let extent = box.trail - box.lead
        let before = band.filter { $0.trail <= box.lead }.max(by: { $0.trail < $1.trail })
        let after = band.filter { $0.lead >= box.trail }.min(by: { $0.lead < $1.lead })

        var candidates: [Candidate] = []
        if let before, let after {
            let room = after.lead - before.trail - extent
            if room >= 0 {
                candidates.append(Candidate(value: before.trail + room / 2,
                                            claim: .between(before.rect, after.rect)))
            }
        }
        if let before,
           let prior = band.filter({ $0.trail <= before.lead }).max(by: { $0.trail < $1.trail }) {
            candidates.append(Candidate(value: before.trail + (before.lead - prior.trail),
                                        claim: .run(prior.rect, before.rect)))
        }
        if let after,
           let next = band.filter({ $0.lead >= after.trail }).min(by: { $0.lead < $1.lead }) {
            candidates.append(Candidate(value: after.lead - (next.lead - after.trail) - extent,
                                        claim: .runBack(after.rect, next.rect)))
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
    /// the same offered frame either way. Whether the outline goes round it is `complete`'s to say.
    private static func ghost(_ horizontal: Hit?, _ vertical: Hit?, at frame: CanvasRect,
                              against others: [CanvasRect], complete: Bool,
                              show: Double) -> CanvasGhost? {
        // ⌘ or ⌃ collapses both radii to nothing. An exact landing under it is still an exact landing, and
        // still not something to draw a mark about: the modifier means "leave me alone".
        guard show > 0, horizontal != nil || vertical != nil else { return nil }

        // Every hit that is part of this frame, taken or still pending, contributes its marks: the axis
        // that has already snapped is as much a part of what the ghost is claiming as the one you are
        // still closing on, and dropping its mark the instant it landed would take the attribution away
        // at exactly the moment it came true.
        var found: [CanvasMatch] = []
        if let horizontal {
            found += agreements(horizontal.claim, landing: frame, horizontal: true, among: others)
        }
        if let vertical {
            found += agreements(vertical.claim, landing: frame, horizontal: false, among: others)
        }
        return CanvasGhost(frame: frame, matches: collapse(found, landing: frame), isComplete: complete)
    }

    /// Every agreement of the same kind as `claim` that the settled landing has along one axis — see
    /// `CanvasGhost.matches` for why every one and not only the one that won.
    ///
    /// Asked of the landing *as settled*, not of the candidate, so that a frame the minimum-size clamp
    /// has adjusted is marked for what it actually agrees with, which may be nothing.
    private static func agreements(_ claim: Claim, landing: CanvasRect, horizontal: Bool,
                                   among others: [CanvasRect]) -> [CanvasMatch] {
        let mine = span(landing, horizontal: horizontal)
        func gap(_ a: Span, _ b: Span, far: CanvasRect) -> CanvasMatch? {
            let gap = CanvasGap(horizontal: horizontal, lead: a.trail, trail: b.lead,
                                crossLead: max(a.crossLead, b.crossLead),
                                crossTrail: min(a.crossTrail, b.crossTrail), far: far)
            return gap.trail > gap.lead && gap.crossTrail > gap.crossLead ? .gap(gap) : nil
        }
        func spans(_ cards: [CanvasRect]) -> [Span] { cards.map { span($0, horizontal: horizontal) } }

        switch claim {
        case .edge:
            let mineAt = [CanvasSpanPart.lead, .middle, .trail].map {
                $0.value(in: landing, horizontal: horizontal)
            }
            return others.flatMap { card in
                [CanvasSpanPart.lead, .middle, .trail].compactMap { part -> CanvasMatch? in
                    let at = part.value(in: card, horizontal: horizontal)
                    guard mineAt.contains(where: { abs($0 - at) < 0.01 }) else { return nil }
                    return .edge(card, horizontal: horizontal, part: part)
                }
            }
        case .length:
            let extent = mine.trail - mine.lead
            return others.filter {
                abs((horizontal ? $0.width : $0.height) - extent) < 0.01
            }.map { .length($0, horizontal: horizontal) }
        case .between(let before, let after):
            return [gap(span(before, horizontal: horizontal), mine, far: before),
                    gap(mine, span(after, horizontal: horizontal), far: after)].compactMap { $0 }
        case .run(let prior, let before):
            // Followed back along the row from the pair the search compared, for as far as it keeps
            // the pitch, and then the landing's own gap on the end.
            let chain = spans(run(prior, before, backwards: true, horizontal: horizontal, among: others))
            guard let last = chain.last else { return [] }
            return (zip(chain, chain.dropFirst()).map { gap($0, $1, far: $0.rect) }
                    + [gap(last, mine, far: last.rect)]).compactMap { $0 }
        case .runBack(let after, let next):
            let chain = spans(run(after, next, backwards: false, horizontal: horizontal, among: others))
            guard let first = chain.first else { return [] }
            return ([gap(mine, first, far: first.rect)]
                    + zip(chain, chain.dropFirst()).map { gap($0, $1, far: $1.rect) }).compactMap { $0 }
        case .beside(let lone, let after):
            let theirs = span(lone, horizontal: horizontal)
            return [after ? gap(theirs, mine, far: lone) : gap(mine, theirs, far: lone)].compactMap { $0 }
        }
    }

    /// The run a pitch belongs to, followed out from the pair that set it for as long as the cards
    /// keep it — backwards from `first`, or forwards from `second`. The whole row is what the landing
    /// is joining, not the two cards the search happened to compare.
    private static func run(_ first: CanvasRect, _ second: CanvasRect, backwards: Bool,
                            horizontal: Bool, among others: [CanvasRect]) -> [CanvasRect] {
        let pitch = span(second, horizontal: horizontal).lead - span(first, horizontal: horizontal).trail
        var chain = [first, second]
        while let end = (backwards ? chain.first : chain.last).map({ span($0, horizontal: horizontal) }) {
            let beyond = others.map { span($0, horizontal: horizontal) }.filter {
                !chain.contains($0.rect) && abreast($0, end)
                    && (backwards ? $0.trail <= end.lead : $0.lead >= end.trail)
            }
            guard let next = backwards ? beyond.max(by: { $0.trail < $1.trail })
                                       : beyond.min(by: { $0.lead < $1.lead }) else { break }
            let gap = backwards ? end.lead - next.trail : next.lead - end.trail
            guard abs(gap - pitch) <= 0.5 else { break }
            if backwards { chain.insert(next.rect, at: 0) } else { chain.append(next.rect) }
        }
        return chain
    }

    /// One claim per card per axis — see `CanvasMatch.level`.
    ///
    /// In place rather than appended, so the marks keep the order the axes were searched in.
    private static func collapse(_ found: [CanvasMatch], landing: CanvasRect) -> [CanvasMatch] {
        func isLevel(_ card: CanvasRect, _ horizontal: Bool) -> Bool {
            let theirs = span(card, horizontal: horizontal), mine = span(landing, horizontal: horizontal)
            return abs(theirs.lead - mine.lead) < 0.01 && abs(theirs.trail - mine.trail) < 0.01
        }
        func spaced(_ card: CanvasRect, horizontal: Bool) -> Bool {
            found.contains {
                if case .gap(let gap) = $0 { return gap.horizontal == horizontal && gap.far == card }
                return false
            }
        }
        var out: [CanvasMatch] = []
        for match in found {
            switch match {
            case .edge(let card, horizontal: let horizontal, part: _),
                 .length(let card, horizontal: let horizontal):
                guard isLevel(card, horizontal) else {
                    out.append(match)
                    continue
                }
                let level = CanvasMatch.level(card, horizontal: horizontal)
                if !out.contains(level), !spaced(card, horizontal: !horizontal) { out.append(level) }
            case .level, .gap:
                out.append(match)
            }
        }
        return out
    }

    /// The nearest of `candidates` to `value`, each within the distance its own line offers from.
    ///
    /// Ties go to the first, and the order still matters: edge candidates are passed before size
    /// candidates, so a position that is both lands on the alignment's target. The two targets are the
    /// same number, so the ghost is the same rectangle either way — but the card's *frame* comes from
    /// `target`, and picking deterministically is worth more than picking meaningfully here.
    private static func nearest(to value: Double, among candidates: [Candidate],
                                reach: Reach) -> Hit? {
        var best: Hit?
        for candidate in candidates {
            let shift = candidate.value - value
            guard abs(shift) <= reach.of(candidate.value) else { continue }
            if let current = best, abs(current.shift) <= abs(shift) { continue }
            best = Hit(target: candidate.value, shift: shift, claim: candidate.claim)
        }
        return best
    }

    /// Whether two spans share any of the band across their axis — whether the eye would call them
    /// side by side along it.
    private static func abreast(_ a: Span, _ b: Span) -> Bool {
        a.crossLead < b.crossTrail && a.crossTrail > b.crossLead
    }

    /// The nearest agreement between the moving box's edges and centre and every other card's, along
    /// one axis.
    ///
    /// **Less one pair, beside a lone card:** the pair that would put the two flush — this box's
    /// leading edge on that card's trailing one, or the reverse. `spacing` offers the same side one
    /// grid unit further off instead, and a flush candidate left in would sit a unit away from it and
    /// win whenever you came in from that side. Only when the lone card is abreast of the box: one
    /// above-and-right of it, whose left edge happens to line up with this one's right, is a column
    /// being kept rather than two cards touching.
    private static func alignment(of box: CanvasRect, against others: [CanvasRect],
                                  horizontal: Bool, reach: Reach) -> Hit? {
        let mine = span(box, horizontal: horizontal)
        let middle = horizontal ? box.midX : box.midY
        let theirs = edges(of: others, horizontal: horizontal)
        guard others.count == 1, let lone = others.first.map({ span($0, horizontal: horizontal) }),
              abreast(lone, mine) else {
            return alignment(of: [mine.lead, middle, mine.trail], to: theirs, reach: reach)
        }
        return closer(closer(alignment(of: [mine.lead], to: theirs.filter { $0.value != lone.trail },
                                       reach: reach),
                             alignment(of: [middle], to: theirs, reach: reach)),
                      alignment(of: [mine.trail], to: theirs.filter { $0.value != lone.lead },
                                reach: reach))
    }

    /// The nearest agreement between any of `mine` and any of `theirs`.
    private static func alignment(of mine: [Double], to theirs: [Candidate], reach: Reach) -> Hit? {
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
