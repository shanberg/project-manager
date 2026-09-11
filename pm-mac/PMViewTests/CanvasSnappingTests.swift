import XCTest
import PmLib
@testable import PMViewTests

/// Snapping a drag and a resize to the cards already on the board, and the ghost it offers on the way.
///
/// Every case here is one the eye would catch on a real board and the arithmetic would otherwise get
/// almost right: a column of cards whose left edges are within two points of each other, a row where
/// one card is 4pt wider than its neighbours. The point of snapping is that "almost" stops happening,
/// so these assert exact values.
///
/// The ghost's tests are the other half, and they are all really one question asked from several
/// directions: *is the offer up before the card moves?* A `showReach` of 0 — the default — is the old
/// behaviour, where the two radii are the same and there is nothing to steer by.
final class CanvasSnappingTests: XCTestCase {

    private func rect(_ x: Double, _ y: Double, _ w: Double = 200, _ h: Double = 100) -> CanvasRect {
        CanvasRect(x: x, y: y, width: w, height: h)
    }

    /// The shipping numbers, written out rather than read off `CanvasSnapping`, so that every case
    /// below states the distance it is actually about. `testTheSnapRadiusIsOneGridUnit` is what keeps
    /// the two from drifting apart.
    private let reach = 10.0
    private let show = 48.0

    /// The snap radius is one grid unit, and that is a relationship rather than a coincidence: the
    /// lattice never carries a card further than half a unit, so a guide — reaching a full one —
    /// always gets there first, and declining a guide can never cost you more than taking it would.
    func testTheSnapRadiusIsOneGridUnit() {
        XCTAssertEqual(CanvasSnapping.reach, CanvasSnapping.grid)
    }

    // MARK: Moving

    func testALeftEdgeSnapsToAnotherLeftEdge() {
        let result = CanvasSnapping.move(rect(0, 500), by: (dx: 103, dy: 0),
                                         against: [rect(100, 0)], reach: reach)
        XCTAssertEqual(result.frame.minX, 100, "pulled back the 3pt onto the other card's left edge")
        XCTAssertEqual(result.frame.minY, 500)
    }

    func testCentresSnapToCentres() {
        // The other card's centre is at x=200. Moving card is 200 wide, so its centre lands there when
        // its left edge is at 100.
        let result = CanvasSnapping.move(rect(0, 500), by: (dx: 104, dy: 0),
                                         against: [rect(100, 0)], reach: reach)
        XCTAssertEqual(result.frame.midX, 200)
    }

    /// The moving card's *right* edge finding another card's *left* edge — cards butted up in a row,
    /// which the naive "compare left to left" rule never catches. A row of two, because butting up
    /// against a *lone* card is the one placement the board steers you away from — see
    /// `testALoneCardIsOfferedOneUnitOfRoomRatherThanATouch`.
    func testARightEdgeSnapsToALeftEdge() {
        let result = CanvasSnapping.move(rect(0, 0), by: (dx: 497, dy: 0),
                                         against: [rect(700, 0), rect(1000, 0)], reach: reach)
        XCTAssertEqual(result.frame.maxX, 700)
    }

    func testBothAxesSnapIndependently() {
        let result = CanvasSnapping.move(rect(0, 0), by: (dx: 98, dy: 303),
                                         against: [rect(100, 300)], reach: reach)
        XCTAssertEqual(result.frame.minX, 100)
        XCTAssertEqual(result.frame.minY, 300)
    }

    /// Nothing to align to, so the grid gets its say — the fallback, not the rule.
    func testTheGridCatchesWhatAlignmentDoesnt() {
        let result = CanvasSnapping.move(rect(0, 0), by: (dx: 103, dy: 0),
                                         against: [rect(4000, 4000)], reach: reach)
        XCTAssertEqual(result.frame.minX, 100, "rounded to the 10pt grid")
    }

    /// **The lattice gets no ghost.** Under a target rather than a receipt it would be a mark up
    /// during every drag, everywhere, for the weakest claim the board makes — and the dot grid, which
    /// fades in for the whole of a snapping drag, already says the lattice is there.
    func testTheGridOffersNothing() {
        let result = CanvasSnapping.move(rect(0, 0), by: (dx: 103, dy: 0),
                                         against: [rect(4000, 4000)], reach: reach, showReach: show)
        XCTAssertEqual(result.frame.minX, 100, "still rounded to the grid")
        XCTAssertNil(result.ghost, "but silently — nothing appeared, so nothing matched")
    }

    /// Alignment beats the grid where both apply. Snapping to another card is a much stronger
    /// statement of intent than snapping to an invisible lattice.
    func testAlignmentWinsOverTheGrid() {
        let result = CanvasSnapping.move(rect(0, 0), by: (dx: 100, dy: 0),
                                         against: [rect(103, 0)], reach: reach)
        XCTAssertEqual(result.frame.minX, 103, "not rounded away to 100")
    }

    /// ⌥ turns the lot off, which is what makes snapping safe to have on by default.
    func testNothingSnapsWhenSnappingIsOff() {
        let result = CanvasSnapping.move(rect(0, 0), by: (dx: 103, dy: 7),
                                         against: [rect(100, 0)], reach: 0, snapsToGrid: false)
        XCTAssertEqual(result.frame.minX, 103)
        XCTAssertEqual(result.frame.minY, 7)
    }

    /// ⌥ turns the *offer* off with the snap. The modifier means "leave me alone", and a board still
    /// showing what it would have done is a quieter way of not leaving you alone.
    func testNothingIsOfferedWhenSnappingIsOff() {
        let result = CanvasSnapping.move(rect(0, 0), by: (dx: 103, dy: 7),
                                         against: [rect(100, 0)], reach: 0, showReach: 0,
                                         snapsToGrid: false)
        XCTAssertNil(result.ghost)
    }

    func testTheNearestCandidateWins() {
        // Two cards in range: one 3pt away, one 1pt away.
        let result = CanvasSnapping.move(rect(0, 0), by: (dx: 100, dy: 0),
                                         against: [rect(103, 0), rect(101, 0)], reach: reach)
        XCTAssertEqual(result.frame.minX, 101)
    }

    // MARK: Spacing

    /// **The one a lattice can never give you.** Two cards keeping a 137pt gap are a rhythm; the third
    /// card belongs 137pt past the second, and no amount of rounding to tens will ever find that
    /// number. The gap is deliberately not a multiple of the grid, so the grid cannot be what answered.
    func testACardCarriesOnTheGapItsNeighboursKeep() {
        // Cards at 0…200 and 337…537: a gap of 137. The next in the run starts at 537 + 137 = 674.
        let result = CanvasSnapping.move(rect(0, 0), by: (dx: 671, dy: 0),
                                         against: [rect(0, 0), rect(337, 0)], reach: reach)
        XCTAssertEqual(result.frame.minX, 674, "the run continued, not rounded to 670")
    }

    /// The same rhythm read the other way: arriving from the left of a run, the offer is the slot
    /// *before* it. A row is built from either end.
    func testARunIsCarriedOnBackwards() {
        // Cards at 1000…1200 and 1337…1537, gap 137. A 200-wide card before the first one leaves the
        // same gap when its left edge is at 1000 − 137 − 200.
        let result = CanvasSnapping.move(rect(0, 0), by: (dx: 660, dy: 0),
                                         against: [rect(1000, 0), rect(1337, 0)], reach: reach)
        XCTAssertEqual(result.frame.minX, 663)
    }

    /// Dropped into a hole between two cards, the offer is the middle of it — the placement where the
    /// gap on the left and the gap on the right come out the same.
    func testACardInAGapIsOfferedTheMiddleOfIt() {
        // 200…703 is 503 of clear space; a 200-wide card centred in it leaves 151.5 either side.
        let result = CanvasSnapping.move(rect(0, 0), by: (dx: 354, dy: 0),
                                         against: [rect(0, 0), rect(703, 0)], reach: reach)
        XCTAssertEqual(result.frame.minX, 351.5, "equal gaps, and half a point off the lattice")
    }

    /// Gaps run in both directions, and the arithmetic is written once for both — see `Span`.
    func testGapsWorkDownwardsToo() {
        // Cards at y 0…100 and y 237…337: a gap of 137, so the next row starts at 474.
        let result = CanvasSnapping.move(rect(0, 0), by: (dx: 0, dy: 471),
                                         against: [rect(0, 0), rect(0, 237)], reach: reach)
        XCTAssertEqual(result.frame.minY, 474)
    }

    /// **A gap is only a gap between cards you can see abreast of each other.** The same two cards, the
    /// same 137pt rhythm, moved out of the moving card's band — and the offer is gone, because the
    /// distance to a card five thousand points away is a coincidence rather than a spacing.
    func testGapsOnlyCountWithinABand() {
        let result = CanvasSnapping.move(rect(0, 0), by: (dx: 671, dy: 0),
                                         against: [rect(0, -5000), rect(337, -5000)], reach: reach)
        XCTAssertEqual(result.frame.minX, 670, "nothing to continue, so the lattice tidied it")
    }

    /// One neighbour is not a rhythm. There is a distance to it, but a single card cannot say what the
    /// board's spacing *is*, and offering a gap from it would be inventing the pitch rather than
    /// continuing one.
    func testASingleNeighbourEstablishesNoRhythm() {
        // One card, tall enough to be abreast of the moving one — so it is in the band, and the band is
        // still all there is. Its own edges and centre are deliberately out of reach vertically, so a
        // nil ghost can only mean the gap was not offered.
        let result = CanvasSnapping.move(rect(0, 0), by: (dx: 644, dy: 0),
                                         against: [rect(0, -60, 200, 560)], reach: reach,
                                         showReach: show, snapsToGrid: false)
        XCTAssertNil(result.ghost)
    }

    // MARK: Beside a lone card

    /// **With one other card on the board, the offer beside it is a unit of room, not a touch.** Flush
    /// is where the ghost's outline lies across the other card, and a second card is almost always
    /// meant to sit next to the first rather than be glued to it. So the card that would have snapped
    /// its right edge onto the lone card's left edge (at 700) is offered 690 instead — and, three points
    /// from 690, takes it.
    func testALoneCardIsOfferedOneUnitOfRoomRatherThanATouch() {
        let result = CanvasSnapping.move(rect(0, 0), by: (dx: 493, dy: 0),
                                         against: [rect(700, 0)], reach: reach, showReach: show)
        XCTAssertEqual(result.frame.maxX, 690, "one grid unit short of the other card")
        XCTAssertEqual(result.ghost?.frame, rect(490, 0))
        XCTAssertEqual(result.ghost?.sources, [rect(700, 0)], "and says which card it is keeping clear of")
    }

    /// The flush position is withdrawn, not merely outbid: arriving a point from touching, the card is
    /// still carried out to the unit of room rather than into contact.
    func testALoneCardNoLongerOffersTheFlushPosition() {
        let result = CanvasSnapping.move(rect(0, 0), by: (dx: 499, dy: 0),
                                         against: [rect(700, 0)], reach: reach, showReach: show,
                                         snapsToGrid: false)
        XCTAssertEqual(result.frame.maxX, 690)
    }

    /// On either side, and on either axis — it is the same sentence read four ways.
    func testTheUnitOfRoomIsOfferedOnEverySide() {
        let lone = rect(1000, 1000)
        let right = CanvasSnapping.move(rect(0, 1000), by: (dx: 1206, dy: 0), against: [lone],
                                        reach: reach, snapsToGrid: false)
        XCTAssertEqual(right.frame.minX, 1210, "clear of its right edge")
        let below = CanvasSnapping.move(rect(1000, 0), by: (dx: 0, dy: 1106), against: [lone],
                                        reach: reach, snapsToGrid: false)
        XCTAssertEqual(below.frame.minY, 1110, "clear of its bottom edge")
        let above = CanvasSnapping.move(rect(1000, 0), by: (dx: 0, dy: 886), against: [lone],
                                        reach: reach, snapsToGrid: false)
        XCTAssertEqual(above.frame.maxY, 990, "clear of its top edge")
    }

    /// Only beside it. A card below-and-right of the lone one, whose left edge lines up with the lone
    /// card's right edge, is keeping a column — the two do not touch, and nothing is withdrawn.
    func testALoneCardStillLendsItsEdgesToACardNotBesideIt() {
        let result = CanvasSnapping.move(rect(0, 500), by: (dx: 697, dy: 0),
                                         against: [rect(500, 0)], reach: reach)
        XCTAssertEqual(result.frame.minX, 700)
    }

    /// A gap is offered on the same terms as everything else — from the show radius, long before the
    /// card moves.
    func testAGapIsOfferedBeforeTheCardReachesIt() {
        // 30pt short of the 674 the run wants.
        let result = CanvasSnapping.move(rect(0, 0), by: (dx: 644, dy: 0),
                                         against: [rect(0, 0), rect(337, 0)], reach: reach,
                                         showReach: show, snapsToGrid: false)
        XCTAssertEqual(result.frame.minX, 644, "not moved")
        XCTAssertEqual(result.ghost?.frame, rect(674, 0), "and shown where the run continues")
    }

    /// At the same distance an edge beats a gap. Both are worth having and the nearer wins, but a tie
    /// broken by argument beats one broken by the order of an array.
    func testAnEdgeTakesTheTieFromAGap() {
        // The run offers 674, three points to the right. A card in another band offers its left edge at
        // 668, three points to the left.
        let result = CanvasSnapping.move(rect(0, 0), by: (dx: 671, dy: 0),
                                         against: [rect(0, 0), rect(337, 0), rect(668, 5000)],
                                         reach: reach)
        XCTAssertEqual(result.frame.minX, 668)
    }

    // MARK: Which cards

    /// An offer that doesn't say what it is an offer *against* is only half an answer. On a board where
    /// several cards share an edge, "you are collinear with one of them" is not the same information as
    /// which one — and which one is the whole of what tells you the offer is the one you meant.
    func testTheOfferNamesTheCardItIsAligningWith() {
        let result = CanvasSnapping.move(rect(0, 500), by: (dx: 70, dy: 0),
                                         against: [rect(100, 0)], reach: reach, showReach: show,
                                         snapsToGrid: false)
        XCTAssertEqual(result.ghost?.sources, [rect(100, 0)])
    }

    /// A gap names both cards, because a gap is not a property of either of them. One card marked would
    /// say "you are some distance from this", which is true of every card on the board.
    func testAGapNamesTheCardsEitherSideOfIt() {
        // The centred-in-a-hole case. The two cards are pushed up and down out of alignment with the
        // moving one, so the only thing they can be named for is the gap.
        let result = CanvasSnapping.move(rect(0, 0), by: (dx: 354, dy: 0),
                                         against: [rect(0, -60, 200, 560), rect(703, -60, 200, 560)],
                                         reach: reach)
        XCTAssertEqual(result.frame.minX, 351.5)
        XCTAssertEqual(result.ghost?.sources,
                       [rect(0, -60, 200, 560), rect(703, -60, 200, 560)])
    }

    /// A continued run names the two cards whose pitch is being continued — not the whole run, which is
    /// the pair the arithmetic actually used.
    func testAContinuedRunNamesThePairThatSetThePitch() {
        let result = CanvasSnapping.move(rect(0, 0), by: (dx: 644, dy: 0),
                                         against: [rect(0, 0), rect(337, 0)], reach: reach,
                                         showReach: show, snapsToGrid: false)
        XCTAssertEqual(result.ghost?.frame, rect(674, 0))
        XCTAssertEqual(result.ghost?.sources, [rect(0, 0), rect(337, 0)])
    }

    /// One card answering both axes is marked once. Drawn twice it would simply come out darker than
    /// its neighbours, which is a difference that means nothing.
    func testACardAnsweringBothAxesIsNamedOnce() {
        let result = CanvasSnapping.move(rect(0, 0), by: (dx: 97, dy: 297),
                                         against: [rect(100, 300)], reach: reach, showReach: show,
                                         snapsToGrid: false)
        XCTAssertEqual(result.frame.minX, 100)
        XCTAssertEqual(result.frame.minY, 300)
        XCTAssertEqual(result.ghost?.sources, [rect(100, 300)])
    }

    /// A matched extent names its card too, even though the card is nowhere near the one being sized —
    /// which is exactly the case that needed it. A width caught from a card 900pt away is the offer you
    /// would otherwise have no way of accounting for.
    func testAMatchedWidthNamesTheCardItCameFrom() {
        let result = CanvasSnapping.resize(rect(0, 0, 337, 100), handle: .right,
                                           against: [rect(900, 900, 340, 80)],
                                           reach: reach, snapsToGrid: false)
        XCTAssertEqual(result.ghost?.sources, [rect(900, 900, 340, 80)])
    }

    /// The lattice names nobody, because there is nobody: it is the one claim the board makes that is
    /// not about another card. It draws no ghost either — see `testTheGridOffersNothing`.
    func testTheLatticeNamesNoCards() {
        let result = CanvasSnapping.move(rect(0, 0), by: (dx: 103, dy: 0),
                                         against: [rect(4000, 4000)], reach: reach, showReach: show)
        XCTAssertEqual(result.frame.minX, 100)
        XCTAssertNil(result.ghost)
    }

    // MARK: The offer

    /// The one that says what this whole thing is for: at 30pt out the card has *not* moved, and the
    /// board is already showing where it would go. A mark that waited for the snap would be explaining
    /// something instead of offering it.
    func testAnOfferIsUpLongBeforeTheCardMoves() {
        let result = CanvasSnapping.move(rect(0, 500), by: (dx: 70, dy: 0),
                                         against: [rect(100, 0)], reach: reach, showReach: show,
                                         snapsToGrid: false)
        XCTAssertEqual(result.frame.minX, 70, "30pt short of the match, and left exactly there")
        XCTAssertEqual(result.ghost?.frame, rect(100, 500), "with the aligned slot drawn for you")
    }

    /// And it is the same offer at every distance inside the radius. The mark used to be drawn at a
    /// strength that tracked how near the match was, which over most of the approach put it at a
    /// fraction of an already quiet alpha — the offer you most needed early, drawn faintest. There is
    /// nothing left in the model that varies with distance: the ghost 20pt out is the ghost 10pt out,
    /// and the fading is the view's, at the two ends.
    func testAnOfferIsTheSameOfferAtEveryDistance() {
        func offer(at dx: Double) -> CanvasGhost? {
            CanvasSnapping.move(rect(0, 500), by: (dx: dx, dy: 0), against: [rect(100, 0)],
                                reach: reach, showReach: show, snapsToGrid: false).ghost
        }
        XCTAssertNotNil(offer(at: 80))
        XCTAssertEqual(offer(at: 80), offer(at: 90), "20pt out and 10pt out are the same offer")
        XCTAssertEqual(offer(at: 80), offer(at: 97), "and so is one already taken")
    }

    /// Past the show radius there is nothing at all — the point of the second radius is that it ends.
    ///
    /// Landed exactly between the two cards' agreements: the moving card is 200 wide and the other's
    /// edges and centre are 100 apart, so from x=50 every candidate — left to left, centre to left,
    /// right to centre — is 50pt away, two points past the radius.
    func testNothingIsOfferedFromTooFarAway() {
        let result = CanvasSnapping.move(rect(0, 500), by: (dx: 50, dy: 0),
                                         against: [rect(100, 0)], reach: reach, showReach: show,
                                         snapsToGrid: false)
        XCTAssertNil(result.ghost, "nobody is aiming at anything from here")
    }

    /// The offer is the frame the *card* would have, not the card it matched — which is the whole
    /// reason the bands went away. Here the moving card is nowhere near the card it lines up with.
    func testTheOfferDescribesTheMovingCardAndNotItsMatch() {
        let result = CanvasSnapping.move(rect(0, 500), by: (dx: 80, dy: 0),
                                         against: [rect(100, 3000)], reach: reach, showReach: show,
                                         snapsToGrid: false)
        XCTAssertEqual(result.ghost?.frame, rect(100, 500))
    }

    /// **One hit on each axis, drawn as one frame.** A drag can be ten points from one match and
    /// twenty from another, and the frame the card would have is both of them at once — there is no
    /// sense in which the further one is a separate, later offer.
    ///
    /// Two cards, each only reachable on one axis — the second is 5000 away in x, the first 5000 away
    /// in y — so the offer is 12pt out horizontally and 20pt out vertically.
    func testTwoPendingOffersAreDrawnAsOneFrame() {
        let result = CanvasSnapping.move(rect(0, 0), by: (dx: 88, dy: 70),
                                         against: [rect(100, 5000), rect(5000, 100)],
                                         reach: reach, showReach: show, snapsToGrid: false)
        XCTAssertEqual(result.frame, rect(88, 70), "neither is inside the snap, so nothing moved")
        XCTAssertEqual(result.ghost?.frame, rect(100, 50),
                       "both offers drawn together — that is the frame the card would have")
        XCTAssertEqual(result.ghost?.sources, [rect(100, 5000), rect(5000, 100)],
                       "and both cards named, one per axis")
    }

    // MARK: Resizing

    func testAGripOnlyMovesTheEdgesItTouches() {
        let result = CanvasSnapping.resize(rect(100, 100, 200, 200), handle: .right,
                                           against: [], reach: reach, snapsToGrid: false)
        XCTAssertEqual(result.frame.minX, 100)
        XCTAssertEqual(result.frame.minY, 100)
        XCTAssertEqual(result.frame.height, 200, "a right grip doesn't touch the height")
    }

    /// The one the request was really about: dragging a card's edge until it is exactly as wide as
    /// another card, and being told that's what happened.
    func testAWidthSnapsToAnotherCardsWidth() {
        // Moving card's left edge is at 0 and it is currently 337 wide; another card is 340 wide.
        let result = CanvasSnapping.resize(rect(0, 0, 337, 100), handle: .right,
                                           against: [rect(900, 900, 340, 80)],
                                           reach: reach, snapsToGrid: false)
        XCTAssertEqual(result.frame.width, 340)
    }

    /// Dragging a corner until a card is another's width *and* its height. One offer, because a target
    /// only has to say where — the two matches that used to be told apart as different claims are one
    /// rectangle now.
    func testACornerCanMatchBothDimensionsAtOnce() {
        let result = CanvasSnapping.resize(rect(0, 0, 337, 197), handle: .bottomRight,
                                           against: [rect(900, 900, 340, 200)],
                                           reach: reach, snapsToGrid: false)
        XCTAssertEqual(result.frame.width, 340)
        XCTAssertEqual(result.frame.height, 200)
    }

    func testAHeightSnapsToAnotherCardsHeight() {
        let result = CanvasSnapping.resize(rect(0, 0, 100, 456), handle: .bottom,
                                           against: [rect(900, 900, 80, 460)],
                                           reach: reach, snapsToGrid: false)
        XCTAssertEqual(result.frame.height, 460)
    }

    /// Dragging a *left* grip to match a width grows the card leftward — the right edge is the one
    /// staying put, so the candidate position is `right - otherWidth`.
    func testALeftGripMatchesAWidthByMovingLeftwards() {
        // 330 wide with its right edge at 430, so matching a 340-wide card means the left edge moving
        // 10pt out to 90 — the right edge is the one staying put. Exactly the snap radius, and it
        // snaps: the radius is inclusive, which is the boundary this case now also pins down.
        let result = CanvasSnapping.resize(rect(100, 0, 330, 100), handle: .left,
                                           against: [rect(900, 900, 340, 80)],
                                           reach: reach, snapsToGrid: false)
        XCTAssertEqual(result.frame.width, 340)
        XCTAssertEqual(result.frame.minX, 90)
        XCTAssertEqual(result.frame.maxX, 430, "the right edge didn't move")
    }

    /// A corner grip snaps both dimensions, and can take one from an alignment and the other from a
    /// size match.
    func testACornerGripSnapsBothAxes() {
        let result = CanvasSnapping.resize(rect(0, 0, 198, 337), handle: .bottomRight,
                                           against: [rect(200, 900, 100, 340)],
                                           reach: reach, snapsToGrid: false)
        XCTAssertEqual(result.frame.maxX, 200, "right edge onto the other card's left edge")
        XCTAssertEqual(result.frame.height, 340, "height matched the other card's")
    }

    func testACardCannotBeResizedInsideOut() {
        let result = CanvasSnapping.resize(CanvasRect(x: 100, y: 100, width: 5, height: 5),
                                           handle: .right, against: [], reach: reach)
        XCTAssertGreaterThanOrEqual(result.frame.width, 40)
        XCTAssertEqual(result.frame.minX, 100)
    }

    func testTheGridStillCatchesAResizeWithNothingToMatch() {
        let result = CanvasSnapping.resize(rect(0, 0, 203, 100), handle: .right,
                                           against: [], reach: reach)
        XCTAssertEqual(result.frame.width, 200)
    }

    // MARK: The offer, while resizing

    /// The request in one test: pulling an edge toward another card's height, and being shown the
    /// height while there is still room to pull.
    func testAResizeIsOfferedAHeightBeforeItReachesIt() {
        // 420 tall and heading for a 460-tall card — 40pt of pull left, well inside the show radius.
        let result = CanvasSnapping.resize(rect(0, 0, 100, 420), handle: .bottom,
                                           against: [rect(900, 900, 80, 460)],
                                           reach: reach, showReach: show, snapsToGrid: false)
        XCTAssertEqual(result.frame.height, 420, "the card is exactly where you dragged it")
        XCTAssertEqual(result.ghost?.frame.height, 460, "and the match is drawn ahead of it")
    }

    /// **Sizing a card down**, which is the case that decided the outline stands off its frame rather
    /// than lying on it: the offer is *inside* the card's current bounds, so it has to be drawn over
    /// the card's own face.
    func testACardBeingShrunkIsOfferedTheSmallerFrame() {
        let result = CanvasSnapping.resize(rect(0, 0, 100, 500), handle: .bottom,
                                           against: [rect(900, 900, 80, 460)],
                                           reach: reach, showReach: show, snapsToGrid: false)
        XCTAssertEqual(result.frame.height, 500)
        XCTAssertEqual(result.ghost?.frame.height, 460, "40pt smaller than the card it is drawn on")
    }

    /// The offer runs through the minimum-size clamp with everything else. A ghost promising a frame
    /// the clamp would refuse to hand over is an offer the board cannot keep.
    func testAnOfferCannotPromiseACardSmallerThanTheMinimum() {
        let result = CanvasSnapping.resize(CanvasRect(x: 0, y: 0, width: 100, height: 60),
                                           handle: .bottom, against: [rect(900, 900, 80, 20)],
                                           reach: reach, showReach: show, snapsToGrid: false)
        XCTAssertEqual(result.ghost?.frame.height, 40, "the minimum, not the 20 that was on offer")
    }

    /// An offer taken on one axis doesn't hold back the offer still pending on the other — and the
    /// frame drawn is both of them together, since both are what the card would become.
    func testATakenOfferAndAPendingOneAreDrawnAsOneFrame() {
        // The width is 3pt out (inside the snap); the height is 30pt out (an offer).
        let result = CanvasSnapping.resize(rect(0, 0, 337, 310), handle: .bottomRight,
                                           against: [rect(900, 900, 340, 340)],
                                           reach: reach, showReach: show, snapsToGrid: false)
        XCTAssertEqual(result.frame.width, 340, "the width snapped")
        XCTAssertEqual(result.frame.height, 310, "the height did not")
        XCTAssertEqual(result.ghost?.frame, rect(0, 0, 340, 340))
    }

    // MARK: When the outline is drawn

    /// **The outline is a claim about the whole frame**, and a match on one axis only decides half of
    /// it: the other coordinate is wherever your hand is. So the offer is up, and not complete.
    func testAMatchOnOneAxisIsNotACompleteLanding() {
        let result = CanvasSnapping.move(rect(0, 500), by: (dx: 70, dy: 0),
                                         against: [rect(100, 0)], reach: reach, showReach: show,
                                         snapsToGrid: false)
        XCTAssertNotNil(result.ghost)
        XCTAssertEqual(result.ghost?.isComplete, false)
    }

    func testAMatchOnBothAxesIsACompleteLanding() {
        let result = CanvasSnapping.move(rect(0, 0), by: (dx: 97, dy: 297),
                                         against: [rect(100, 300)], reach: reach, showReach: show,
                                         snapsToGrid: false)
        XCTAssertEqual(result.ghost?.isComplete, true)
    }

    /// A resize is complete once every axis the grip moves is matched: one for a side grip, both for a
    /// corner — the axis a side grip doesn't move is already decided by the card itself.
    func testAResizeIsCompleteOnceEveryMovingAxisIsMatched() {
        let other = rect(900, 900, 340, 300)
        let side = CanvasSnapping.resize(rect(0, 0, 337, 100), handle: .right, against: [other],
                                         reach: reach, showReach: show, snapsToGrid: false)
        XCTAssertEqual(side.ghost?.isComplete, true, "a side grip moves one axis, and it matched")
        let corner = CanvasSnapping.resize(rect(0, 0, 337, 100), handle: .bottomRight, against: [other],
                                           reach: reach, showReach: show, snapsToGrid: false)
        XCTAssertNotNil(corner.ghost, "the width is still offered")
        XCTAssertEqual(corner.ghost?.isComplete, false, "but the height is still yours")
    }

    // MARK: Crowded lines

    /// **Crowded lines offer from closer in.** Two cards whose left edges are 30pt apart: from 20pt out
    /// either could be meant, so neither is offered until the card is plainly nearer one — within half
    /// the 30. A line on its own offers from the full radius; see `testAnOfferIsUpLongBeforeTheCardMoves`.
    func testACrowdedLineIsOfferedFromCloserIn() {
        let others = [rect(100, 5000), rect(130, 6000)]
        func offer(at dx: Double) -> CanvasGhost? {
            CanvasSnapping.move(rect(0, 0), by: (dx: dx, dy: 0), against: others, reach: reach,
                                showReach: show, snapsToGrid: false).ghost
        }
        XCTAssertNil(offer(at: 80), "20pt from 100, and 130 only 30 beyond it")
        XCTAssertEqual(offer(at: 88)?.frame.minX, 100, "12pt out, it is plainly the nearest")
    }

    /// Crowding shortens the offer and never the snap: lines 12pt apart still pull a card 7pt away.
    func testCrowdingNeverShortensTheSnap() {
        let result = CanvasSnapping.move(rect(0, 0), by: (dx: 93, dy: 0),
                                         against: [rect(100, 5000), rect(112, 6000)], reach: reach,
                                         showReach: show, snapsToGrid: false)
        XCTAssertEqual(result.frame.minX, 100)
    }

    // MARK: What is marked

    /// **A card level with the landing is one mark, not three.** Its top, centre and bottom all agree
    /// with yours, which is one fact — the two are level — and one mark on the side facing you.
    func testACardLevelWithTheLandingIsOneMatch() {
        let neighbour = rect(0, 0)
        let result = CanvasSnapping.move(rect(500, 40), by: (dx: 0, dy: -37),
                                         against: [neighbour, rect(2000, 3000)], reach: reach,
                                         showReach: show, snapsToGrid: false)
        XCTAssertEqual(result.ghost?.frame, rect(500, 0))
        XCTAssertEqual(result.ghost?.matches, [.level(neighbour, horizontal: false)])
    }

    /// Every card on the matched line is marked, not only the one the search reached first — a left edge
    /// landing on a line two cards share is landing on both.
    func testEveryCardOnTheMatchedLineIsMarked() {
        let near = rect(100, 0, 150, 60), far = rect(100, 400, 300, 60)
        let result = CanvasSnapping.move(rect(0, 150, 180, 60), by: (dx: 96, dy: 0),
                                         against: [near, far, rect(3000, 3000)], reach: reach,
                                         showReach: show, snapsToGrid: false)
        XCTAssertEqual(result.ghost?.matches, [.edge(near, horizontal: true, part: .lead),
                                               .edge(far, horizontal: true, part: .lead)])
    }

    /// A continued run marks every gap along it — the row the card is joining, not only the pair the
    /// search compared — and the row's shared top is not marked again: the gaps already name each card.
    func testAContinuedRunMarksEveryGapAlongIt() {
        let row = [rect(0, 0), rect(220, 0), rect(440, 0)]
        let result = CanvasSnapping.move(rect(0, 300), by: (dx: 655, dy: -300), against: row,
                                         reach: reach, showReach: show, snapsToGrid: false)
        XCTAssertEqual(result.ghost?.frame, rect(660, 0))
        let gaps = (result.ghost?.matches ?? []).compactMap { match -> CanvasGap? in
            if case .gap(let gap) = match { return gap }
            return nil
        }
        XCTAssertEqual(gaps.map(\.lead), [200, 420, 640])
        XCTAssertEqual(gaps.map(\.trail), [220, 440, 660])
        XCTAssertEqual(result.ghost?.matches.count, 3)
        XCTAssertEqual(result.ghost?.isComplete, true)
    }

    // MARK: Tidiness

    /// The share of cards lined up with another, per axis. A column sharing a left edge at uneven
    /// heights is tidy across and not down.
    func testTidinessCountsCardsLinedUpWithAnother() {
        XCTAssertEqual(CanvasSnapping.tidiness(of: [rect(0, 0), rect(0, 137), rect(0, 300)]), 0.5)
        XCTAssertEqual(CanvasSnapping.tidiness(of: [rect(0, 0), rect(333, 157), rect(701, 419)]), 0)
        XCTAssertEqual(CanvasSnapping.tidiness(of: [rect(0, 0)]), 0, "one card is not a board")
    }
}
