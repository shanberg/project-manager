import XCTest
import PmLib
@testable import PMViewTests

/// The geometry a tiled view is made of, and the order it puts cards in.
///
/// Worth testing without a board because it is the part that is easy to get subtly wrong and hard to
/// see: a grid that ignores the shape of the window it is filling produces letterboxed tiles, and an
/// order that ignores where the cards were produces an arrangement that has thrown away the one thing
/// the board knew.
@MainActor
final class CanvasTilingTests: XCTestCase {
    private let wide = CanvasRect(x: 0, y: 0, width: 1200, height: 600)
    private let tall = CanvasRect(x: 0, y: 0, width: 600, height: 1200)

    private func card(_ id: String, _ x: Double, _ y: Double,
                      _ w: Double = 200, _ h: Double = 150) -> (id: String, frame: CanvasRect) {
        (id, CanvasRect(x: x, y: y, width: w, height: h))
    }

    // MARK: Order

    /// Reading order of where the cards actually sit — rows top to bottom, each left to right. This is
    /// what makes it a canvas's tiling rather than a generic one.
    func testCardsTileInTheReadingOrderOfTheBoard() {
        let cards = [card("br", 400, 400), card("tl", 0, 0), card("tr", 400, 0), card("bl", 0, 400)]
        XCTAssertEqual(CanvasTiling.order(cards), ["tl", "tr", "bl", "br"])
    }

    /// A row is a band as tall as the median card, not a fixed number — a board of 400pt dashboard
    /// tiles and a board of 60pt stickies disagree about "the same row" by an order of magnitude.
    func testCardsRoughlyLevelCountAsOneRow() {
        let cards = [card("b", 0, 30), card("a", 300, 0)]
        XCTAssertEqual(CanvasTiling.order(cards), ["b", "a"],
                       "30 points apart on a 150pt card is one row, so they sort by x")
    }

    func testCardsWellApartAreSeparateRows() {
        let cards = [card("lower", 0, 900), card("upper", 300, 0)]
        XCTAssertEqual(CanvasTiling.order(cards), ["upper", "lower"])
    }

    // MARK: Grid

    /// The column count follows the area's proportions rather than being ceil(sqrt(n)): six tiles in a
    /// wide window want three across, and the same six in a tall one want two.
    func testTheGridFollowsTheShapeOfTheWindow() {
        let across = Set(CanvasTiling.grid(sizes: even(6), in: wide).map(\.minX)).count
        let down = Set(CanvasTiling.grid(sizes: even(6), in: tall).map(\.minX)).count
        XCTAssertEqual(across, 3)
        XCTAssertEqual(down, 2)
    }

    func testTilesStayInsideTheAreaAndDoNotOverlap() {
        let tiles = CanvasTiling.grid(sizes: even(7), in: wide)
        for tile in tiles {
            XCTAssertGreaterThanOrEqual(tile.minX, wide.minX - 0.5)
            XCTAssertLessThanOrEqual(tile.maxX, wide.maxX + 0.5)
            XCTAssertGreaterThanOrEqual(tile.minY, wide.minY - 0.5)
            XCTAssertLessThanOrEqual(tile.maxY, wide.maxY + 0.5)
        }
        for (a, b) in pairs(tiles) {
            XCTAssertFalse(a.inset(by: -1).intersects(b.inset(by: -1)), "tiles must not overlap")
        }
    }

    /// A grid whose last row is short leaves a gap. Pushed to the left it reads as a mistake; centred
    /// it reads as the end of a list.
    ///
    /// The *row* is centred, not the last tile — those are only the same thing when the row holds one.
    /// Asserting the tile was the first version of this test and it was wrong about the feature.
    func testAShortLastRowIsCentred() {
        for count in [5, 7, 10] {
            let tiles = CanvasTiling.grid(sizes: even(count), in: wide)
            let lastRowY = tiles.last!.minY
            let lastRow = tiles.filter { abs($0.minY - lastRowY) < 0.5 }
            guard lastRow.count < tiles.filter({ abs($0.minY - tiles[0].minY) < 0.5 }).count else {
                continue  // a full last row has nothing to centre
            }
            let span = (lastRow.first!.minX + lastRow.last!.maxX) / 2
            XCTAssertEqual(span, wide.midX, accuracy: 0.5, "\(count) tiles")
        }
    }

    // MARK: Master and stack

    func testTheMasterTakesItsShareAndTheStackTakesTheRest() {
        let tiles = CanvasTiling.masterStack(sizes: even(4), in: wide, fraction: 0.6)
        XCTAssertEqual(tiles[0].height, wide.height, accuracy: 0.5, "the master is full height")
        XCTAssertEqual(tiles[0].width, (wide.width - CanvasTiling.gap) * 0.6, accuracy: 0.5)
        for tile in tiles.dropFirst() {
            XCTAssertEqual(tile.maxX, wide.maxX, accuracy: 0.5, "the stack is flush to the trailing edge")
        }
        for (a, b) in pairs(tiles) {
            XCTAssertFalse(a.inset(by: -1).intersects(b.inset(by: -1)))
        }
    }

    /// A fraction dragged past either end is clamped rather than producing a tile with no width — the
    /// divider can be thrown at the window's edge and the arrangement has to survive it.
    func testTheSplitIsClamped() {
        for fraction in [-2.0, 0.0, 1.0, 5.0] {
            let tiles = CanvasTiling.masterStack(sizes: even(3), in: wide, fraction: fraction)
            for tile in tiles { XCTAssertGreaterThan(tile.width, 1, "fraction \(fraction)") }
        }
    }

    // MARK: One card

    /// ⌘Return with one card selected is "fill the window with this", which is the same command and
    /// has to produce one tile filling the area whichever arrangement is up.
    func testOneCardFillsTheWindow() {
        for arrangement in CanvasTiling.Arrangement.allCases {
            let tiles = CanvasTiling.frames(arrangement, sizes: even(1), in: wide, masterFraction: 0.62)
            XCTAssertEqual(tiles.count, 1)
            XCTAssertLessThan(tiles[0].width, wide.width, "inset from the edges")
            XCTAssertGreaterThan(tiles[0].width, wide.width - 4 * CanvasTiling.gap)
        }
    }

    // MARK: What the command is called

    /// The wording the View menu, the contextual menu and the header button all share. Worth pinning
    /// down because it is the only part of the command a person reads before committing to it, and
    /// because the version it replaces got the most consequential case wrong.
    func testAnUntiledBoardOffersToTileWhatIsSelected() {
        XCTAssertEqual(CanvasTiling.commandTitle(tiled: nil, picked: 0, targets: 6, selected: true),
                       "Fill Window with These 6 Cards")
        XCTAssertEqual(CanvasTiling.commandTitle(tiled: nil, picked: 0, targets: 1, selected: true),
                       "Fill Window with This Card")
    }

    /// The count is the *target* count, not the selection's: selecting one frame that holds nine cards
    /// says nine. That is the whole reason the number is in the title.
    func testAFrameIsCountedByWhatIsInside() {
        XCTAssertEqual(CanvasTiling.commandTitle(tiled: nil, picked: 0, targets: 9, selected: true),
                       "Fill Window with These 9 Cards")
    }

    /// Nothing selected falls back to the visible region, which is deliberately not counted — the
    /// number would change under you as you scrolled.
    func testNothingSelectedNamesTheVisibleCardsWithoutCountingThem() {
        for targets in [0, 1, 40] {
            XCTAssertEqual(CanvasTiling.commandTitle(tiled: nil, picked: 0,
                                                     targets: targets, selected: false),
                           "Fill Window with Visible Cards")
        }
    }

    /// Inside a tiling with some of the tiles picked, ⌘Return drills in — and now says so. It used to
    /// say "Leave Tiled View" here, which was the menu promising the opposite of what would happen.
    func testPickingSomeOfTheTilesOffersToDrillIn() {
        XCTAssertEqual(CanvasTiling.commandTitle(tiled: 6, picked: 2, targets: 0, selected: true),
                       "Fill Window with These 2 Tiles")
        XCTAssertEqual(CanvasTiling.commandTitle(tiled: 6, picked: 1, targets: 0, selected: true),
                       "Fill Window with This Tile")
    }

    /// All of them, or none of them, is not a narrowing — so the command is the way back out, and both
    /// of those have to say so.
    func testTakingAllOrNoneOfTheTilesIsTheWayOut() {
        XCTAssertEqual(CanvasTiling.commandTitle(tiled: 6, picked: 6, targets: 0, selected: true),
                       "Leave Tiled View")
        XCTAssertEqual(CanvasTiling.commandTitle(tiled: 6, picked: 0, targets: 0, selected: false),
                       "Leave Tiled View")
    }

    /// A tiling of one is already as far in as it goes.
    func testAFullscreenTileCanOnlyBeLeft() {
        XCTAssertEqual(CanvasTiling.commandTitle(tiled: 1, picked: 1, targets: 0, selected: true),
                       "Leave Tiled View")
    }

    // MARK: Pinning one and stretching the rest

    /// The case the whole mechanism exists for: one tile holds a width, the others absorb the window.
    func testAPinnedTileKeepsItsLengthAndTheRestShareWhatIsLeft() {
        let lengths = CanvasTiling.run([.pinned(300), .even, .even], across: 1000)
        XCTAssertEqual(lengths[0], 300)
        XCTAssertEqual(lengths[1], 350)
        XCTAssertEqual(lengths[2], 350)
    }

    /// The same run in a window 200pt narrower: every point of that comes off the flexible tiles.
    func testTheWindowsChangeComesOffTheFlexibleTilesOnly() {
        let lengths = CanvasTiling.run([.pinned(300), .even, .even], across: 800)
        XCTAssertEqual(lengths[0], 300, "the pin didn't move")
        XCTAssertEqual(lengths[1], 250)
        XCTAssertEqual(lengths[2], 250)
    }

    /// Only the ratio of the weights means anything, which is what lets a drag write lengths straight
    /// in as weights without renormalising anything else.
    func testWeightsAreShares() {
        XCTAssertEqual(CanvasTiling.run([.flexible(300), .flexible(100)], across: 800), [600, 200])
        XCTAssertEqual(CanvasTiling.run([.flexible(3), .flexible(1)], across: 800), [600, 200],
                       "the same run, said with smaller numbers")
    }

    /// A pin is a request, and a request that would push tiles out of the window has to lose. The
    /// flexible tiles keep the minimum and the pin gives up the difference.
    func testAPinYieldsRatherThanOverflowingTheWindow() {
        let lengths = CanvasTiling.run([.pinned(600), .even, .even], across: 500)
        XCTAssertEqual(lengths.reduce(0, +), 500, accuracy: 0.001, "nothing hangs off the edge")
        XCTAssertLessThan(lengths[0], 600, "the pin was overruled")
        XCTAssertEqual(lengths[1], CanvasTiling.minimumTile)
        XCTAssertEqual(lengths[2], CanvasTiling.minimumTile)
    }

    /// Squeezed past the point where even the minimums fit, everything shares — rather than the first
    /// tiles taking all of it and the last ones getting nothing.
    func testAWindowTooSmallForAnyoneSharesEvenly() {
        let lengths = CanvasTiling.run([.pinned(600), .even, .even], across: 90)
        XCTAssertEqual(lengths.reduce(0, +), 90, accuracy: 0.001)
        for length in lengths { XCTAssertEqual(length, 30, accuracy: 0.001) }
    }

    /// Two or three cards side by side is a grid of one row — which is a run, and gets the sizes. It is
    /// the commonest tiling there is and the one where pinning is most obviously wanted.
    func testAGridOfOneRowIsARun() {
        let tiles = CanvasTiling.grid(sizes: [.pinned(300), .even], in: wide)
        XCTAssertEqual(tiles[0].width, 300)
        XCTAssertEqual(tiles[0].maxX + CanvasTiling.gap, tiles[1].minX, accuracy: 0.001)
        XCTAssertEqual(tiles[1].maxX, wide.maxX, accuracy: 0.001)
    }

    /// A grid of rows *and* columns has no run to pin along: a width there is a column's, shared with
    /// tiles nobody selected. So the sizes are ignored rather than half-honoured.
    func testARealGridIgnoresSizes() {
        let even = CanvasTiling.grid(sizes: even(6), in: wide)
        let asked = CanvasTiling.grid(sizes: [.pinned(200), .even, .even, .even, .even, .even], in: wide)
        XCTAssertEqual(asked.map(\.width), even.map(\.width))
    }

    /// The stack is a vertical run, so pinning a tile there holds its height.
    func testPinningInTheStackHoldsAHeight() {
        let tiles = CanvasTiling.masterStack(sizes: [.even, .pinned(120), .even], in: wide, fraction: 0.6)
        XCTAssertEqual(tiles[1].height, 120)
        XCTAssertEqual(tiles[2].maxY, wide.maxY, accuracy: 0.001)
    }

    /// A pinned master is a width in points rather than a fraction of the window — the fraction is what
    /// an *unpinned* master falls back to, which is what the divider has always meant.
    func testAPinnedMasterIgnoresTheFraction() {
        for fraction in [0.3, 0.62, 0.85] {
            let tiles = CanvasTiling.masterStack(sizes: [.pinned(420), .even, .even],
                                                 in: wide, fraction: fraction)
            XCTAssertEqual(tiles[0].width, 420)
        }
    }

    // MARK: Adding and removing tiles

    private func row(_ ids: [String], sizes: [String: CanvasTiling.Size] = [:]) -> CanvasTileSession {
        CanvasTileSession(ids: ids, arrangement: .grid, sizes: sizes,
                          area: CanvasRect(x: 0, y: 0, width: 1800, height: 300),
                          restoreVisible: .init(x: 0, y: 0, width: 1800, height: 300))
    }

    /// The decision, stated as a test so it cannot quietly become something cleverer: a new card goes
    /// on the end, wherever you were looking and whatever is focused.
    func testANewCardGoesOnTheEnd() {
        var session = row(["a", "b", "c"])
        session.add("d")
        XCTAssertEqual(session.ids, ["a", "b", "c", "d"])
    }

    /// Including in master-and-stack, where the end is the bottom of the stack — *not* the master
    /// slot. Landing in the master would take the window away from whatever you were reading in order
    /// to give it to a card you have not looked at yet.
    func testANewCardDoesNotBecomeTheMaster() {
        var session = row(["a", "b", "c"])
        session.arrangement = .masterStack
        session.add("d")
        XCTAssertEqual(session.ids.first, "a", "the master is still the master")
        XCTAssertEqual(session.ids.last, "d")
    }

    /// And then you move it, which is the other half of the sentence.
    func testAndThenYouMoveIt() {
        var session = row(["a", "b", "c"])
        session.add("d")
        session.move("d", to: 1)
        XCTAssertEqual(session.ids, ["a", "d", "b", "c"])
    }

    func testACardAlreadyUpIsNotAddedTwice() {
        var session = row(["a", "b", "c"])
        session.add("b")
        XCTAssertEqual(session.ids, ["a", "b", "c"])
    }

    /// Every tile gets a frame, so a card added to the order is a card on the screen — the assertion
    /// that would fail if `add` appended to `ids` and the layout were built from something else.
    func testTheAddedCardIsOnScreen() {
        var session = row(["a", "b", "c"])
        session.add("d")
        XCTAssertNotNil(session.layout.frames["d"])
        XCTAssertTrue(session.layout.shows("d"))
        XCTAssertEqual(session.layout.frames.count, 4)
    }

    func testRemovingATileTakesItOffTheScreen() {
        var session = row(["a", "b", "c"])
        session.remove("b")
        XCTAssertEqual(session.ids, ["a", "c"])
        XCTAssertNil(session.layout.frames["b"])
        XCTAssertFalse(session.layout.shows("b"), "the layout stops showing it")
    }

    /// A length is a share of one particular run, so it does not lie in wait for a card that has left.
    func testRemovingATileTakesItsLengthWithIt() {
        var session = row(["a", "b", "c"], sizes: ["b": .pinned(420)])
        session.remove("b")
        XCTAssertNil(session.sizes["b"])
        XCTAssertEqual(session.run.count, 2)
    }

    /// The negative control for the one above: the *other* tiles' lengths are exactly what must
    /// survive, or every removal would quietly even out an arrangement you had dragged into shape.
    func testRemovingATileLeavesEveryOtherLengthAlone() {
        var session = row(["a", "b", "c"], sizes: ["a": .pinned(300), "b": .pinned(420)])
        session.remove("b")
        XCTAssertEqual(session.sizes, ["a": .pinned(300)])
    }

    func testRemovingACardThatIsNotUpChangesNothing() {
        var session = row(["a", "b", "c"], sizes: ["a": .pinned(300)])
        let before = session
        session.remove("zzz")
        XCTAssertEqual(session, before)
    }

    /// Add then remove is the identity, which is what "a tiling is a way of looking" has to mean:
    /// nothing about the arrangement you built is spent by looking at one more card for a moment.
    func testAddingAndRemovingLeavesTheArrangementAsItWas() {
        let before = row(["a", "b", "c"], sizes: ["a": .pinned(300)])
        var session = before
        session.add("d")
        session.remove("d")
        XCTAssertEqual(session, before)
    }

    // MARK: Reordering under the hand

    /// A row wide enough to be laid out as one run, with the tiles at deliberately unequal widths —
    /// which is what a dragged divider leaves behind, and what makes the geometry below move.
    private func unevenRow() -> CanvasTileSession {
        CanvasTileSession(ids: ["a", "b", "c"], arrangement: .grid,
                          sizes: ["a": .flexible(4), "b": .flexible(1), "c": .flexible(1)],
                          area: CanvasRect(x: 0, y: 0, width: 1800, height: 300),
                          restoreVisible: .init(x: 0, y: 0, width: 1800, height: 300))
    }

    /// The bug this rule exists for: a tile's width travels with the card, so moving a tile onto a
    /// wide one re-lays the row out and leaves that same wide tile under a pointer that has not moved.
    /// Asked again on the next event, the drag displaces it again — and the board flickers between two
    /// orders for as long as you hold still.
    func testMovingATileCanLeaveTheSameTileUnderThePointer() {
        var session = unevenRow()
        let middle = CanvasPoint(x: 900, y: 150)
        XCTAssertEqual(tile(under: middle, in: session), "a", "the wide tile fills the middle")

        session.move("c", to: 0)
        XCTAssertEqual(tile(under: middle, in: session), "a",
                       "the row was re-laid out and 'a' is still there — which is the whole trouble")
    }

    /// So the drag remembers what it has already moved against, and holding still changes nothing.
    func testADragHoldingStillMovesOnce() {
        var session = unevenRow()
        var displaced: String?
        let middle = CanvasPoint(x: 900, y: 150)

        let moves = (0..<30).filter { _ in step(&session, carrying: "c", at: middle, displaced: &displaced) }
        XCTAssertEqual(moves.count, 1, "one crossing is one move, however long the pointer rests there")
        XCTAssertEqual(session.ids, ["c", "a", "b"])
    }

    /// And leaving the tile — for the gap, or for the card in your hand — is what earns it back, so a
    /// drag that goes on crossing goes on rearranging.
    func testCrossingAgainMovesAgain() {
        var session = unevenRow()
        var displaced: String?
        _ = step(&session, carrying: "c", at: CanvasPoint(x: 900, y: 150), displaced: &displaced)
        XCTAssertEqual(session.ids, ["c", "a", "b"])

        // Out over the tile in your hand, then back onto the wide one.
        _ = step(&session, carrying: "c", at: CanvasPoint(x: 100, y: 150), displaced: &displaced)
        XCTAssertNil(displaced, "the carried tile is not something to move onto")
        XCTAssertTrue(step(&session, carrying: "c", at: CanvasPoint(x: 900, y: 150),
                           displaced: &displaced))
        XCTAssertEqual(session.ids, ["a", "c", "b"], "the second crossing moved it on")
    }

    /// One event of a handlebar drag, as `CanvasBoardView+Input` runs it: what is under the pointer,
    /// the rule, and the move. Answers whether the order changed.
    private func step(_ session: inout CanvasTileSession, carrying id: String, at point: CanvasPoint,
                      displaced: inout String?) -> Bool {
        let over = tile(under: point, in: session)
        let next = CanvasTileSession.reorder(carrying: id, over: over, displaced: displaced)
        displaced = next.displaced
        guard let onto = next.displace, let index = session.ids.firstIndex(of: onto) else { return false }
        session.move(id, to: index)
        return true
    }

    /// The tile drawn under a point — the hit tester's answer inside a tiling, which is containment
    /// and nothing else.
    private func tile(under point: CanvasPoint, in session: CanvasTileSession) -> String? {
        session.layout.frames.first { $0.value.contains(x: point.x, y: point.y) }?.key
    }

    private func even(_ count: Int) -> [CanvasTiling.Size] {
        Array(repeating: .even, count: count)
    }

    private func pairs(_ tiles: [CanvasRect]) -> [(CanvasRect, CanvasRect)] {
        var out: [(CanvasRect, CanvasRect)] = []
        for i in tiles.indices { for j in tiles.indices where j > i { out.append((tiles[i], tiles[j])) } }
        return out
    }
}
