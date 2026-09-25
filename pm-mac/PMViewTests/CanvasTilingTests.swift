import XCTest
import PmLib
@testable import PMViewTests

/// The geometry a tiled view is made of, the order it puts cards in, and the columns a workspace is.
///
/// Worth testing without a board because it is the part that is easy to get subtly wrong and hard to
/// see: a grid that ignores the shape of the window it is filling produces letterboxed tiles, an order
/// that ignores where the cards were produces an arrangement that has thrown away the one thing the
/// board knew, and a workspace that changes shape on the way to disk and back is one you rebuild every
/// morning. See docs/canvas-workspaces.md §7k for the columns.
@MainActor
final class CanvasTilingTests: XCTestCase {
    private let wide = CanvasRect(x: 0, y: 0, width: 1200, height: 600)
    private let tall = CanvasRect(x: 0, y: 0, width: 600, height: 1200)
    /// Square, so four tiles land as two rows of two — the grid picks its column count from the shape
    /// of the window, and on `wide` the same four become three across.
    private let square = CanvasRect(x: 0, y: 0, width: 800, height: 800)

    private func card(_ id: String, _ x: Double, _ y: Double,
                      _ w: Double = 200, _ h: Double = 150) -> (id: String, frame: CanvasRect) {
        (id, CanvasRect(x: x, y: y, width: w, height: h))
    }

    /// `count` tiles named "0", "1"… dealt out by `arrangement` into `area`.
    private func arranged(_ arrangement: CanvasTiling.Arrangement, _ count: Int, in area: CanvasRect,
                          fraction: Double = 0.6,
                          sizes: [String: CanvasTiling.Size] = [:]) -> CanvasTileSession {
        let tiles = (0..<count).map { CanvasTiling.Tile(String($0)) }
        return CanvasTileSession(columns: CanvasTiling.columns(arrangement, of: tiles, in: area,
                                                               masterFraction: fraction, sizes: sizes),
                                 area: area, restoreVisible: area)
    }

    /// The frames those tiles get, in the order the tiles were named — which is the order they were
    /// dealt, so `[0]` is the first card whatever column it landed in.
    private func frames(_ arrangement: CanvasTiling.Arrangement, _ count: Int, in area: CanvasRect,
                        fraction: Double = 0.6,
                        sizes: [String: CanvasTiling.Size] = [:]) -> [CanvasRect] {
        let layout = arranged(arrangement, count, in: area, fraction: fraction, sizes: sizes).layout
        return (0..<count).map { layout.frames[String($0)]! }
    }

    // MARK: The shape of a tile

    /// The rule, stated as a test: a corner goes wide only where it is a corner of the tile space in
    /// *both* directions. Every other corner is a seam with another tile and stays tight.
    ///
    /// A 2×2 grid is the clean case — each tile gets exactly one outer corner, the one facing out, and
    /// the four together trace the outline of the arrangement.
    func testEachTileInAGridKeepsOnlyTheCornerFacingOut() {
        let space = CanvasTiling.space(of: square)
        let corners = frames(.grid, 4, in: square).map { CanvasTiling.corners(of: $0, in: space) }

        XCTAssertEqual(corners[0], .init(topLeft: true, topRight: false,
                                         bottomRight: false, bottomLeft: false))
        XCTAssertEqual(corners[1], .init(topLeft: false, topRight: true,
                                         bottomRight: false, bottomLeft: false))
        XCTAssertEqual(corners[2], .init(topLeft: false, topRight: false,
                                         bottomRight: false, bottomLeft: true))
        XCTAssertEqual(corners[3], .init(topLeft: false, topRight: false,
                                         bottomRight: true, bottomLeft: false))
    }

    /// The master runs the full height of the space, so it keeps both of its leading corners — and
    /// loses both trailing ones to the divider, which is the whole argument for the rule.
    func testTheMasterKeepsItsOutsideCornersAndLosesTheOnesAtTheDivider() {
        let space = CanvasTiling.space(of: wide)
        XCTAssertEqual(CanvasTiling.corners(of: frames(.masterStack, 4, in: wide)[0], in: space),
                       .init(topLeft: true, topRight: false, bottomRight: false, bottomLeft: true))
    }

    /// A tile with nothing at the frame in both directions — the middle of a stack — is tight all
    /// round. That is what makes the arrangement read as one object with cuts in it.
    func testATileInTheMiddleOfAStackIsTightAllRound() {
        let space = CanvasTiling.space(of: wide)
        XCTAssertEqual(CanvasTiling.corners(of: frames(.masterStack, 4, in: wide)[2], in: space),
                       .init(topLeft: false, topRight: false, bottomRight: false, bottomLeft: false),
                       "the second of three stacked tiles touches the frame on one side only")
    }

    /// The last tile in a run reaches the bottom of the space through two roundings, and a corner rule
    /// that compared exactly would drop its outer corners on some window heights and not others.
    func testTheEndOfARunStillCountsAsTheFrame() {
        let odd = CanvasRect(x: 0, y: 0, width: 1000.5, height: 733.3)
        let last = CanvasTiling.corners(of: frames(.masterStack, 4, in: odd)[3],
                                        in: CanvasTiling.space(of: odd))
        XCTAssertTrue(last.bottomRight, "the bottom of the stack is the bottom of the space")
        XCTAssertTrue(last.topRight == false, "and its top is a seam with the tile above")
    }

    /// One tile is the whole space, so it is a window and gets four wide corners.
    func testASingleTileIsWideAllRound() {
        XCTAssertEqual(CanvasTiling.corners(of: frames(.grid, 1, in: wide)[0],
                                            in: CanvasTiling.space(of: wide)), .all)
    }

    /// The two radii, and which corner gets which.
    func testOuterCornersTakeTheWiderRadius() {
        let corners = CanvasTiling.Corners(topLeft: true, topRight: false,
                                           bottomRight: false, bottomLeft: true)
        let radii = corners.radii(inner: CanvasTiling.innerRadius, outer: CanvasTiling.outerRadius)
        XCTAssertEqual(radii.topLeft, CanvasTiling.outerRadius)
        XCTAssertEqual(radii.topRight, CanvasTiling.innerRadius)
        XCTAssertFalse(radii.isUniform)
        XCTAssertGreaterThan(CanvasTiling.outerRadius, CanvasTiling.innerRadius,
                             "a seam is tighter than the frame, or there was no point having two")
    }

    /// A curve inset from another curve stays parallel to it only when its radius drops by the inset —
    /// which is what keeps the clip inside a tile's hairline from pinching shut at the corners.
    func testInsettingCornersDropsEachRadiusAndStopsAtZero() {
        let radii = CanvasTiling.Radii(topLeft: 9, topRight: 5, bottomRight: 0.5, bottomLeft: 5)
        let inside = radii.inset(by: 1)
        XCTAssertEqual(inside.topLeft, 8)
        XCTAssertEqual(inside.topRight, 4)
        XCTAssertEqual(inside.bottomRight, 0, "a corner tighter than the inset goes square, not negative")
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
        XCTAssertEqual(Set(frames(.grid, 6, in: wide).map(\.minX)).count, 3)
        XCTAssertEqual(Set(frames(.grid, 6, in: tall).map(\.minX)).count, 2)
    }

    func testTilesStayInsideTheAreaAndDoNotOverlap() {
        let tiles = frames(.grid, 7, in: wide)
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

    /// Dealt a row at a time, so a full grid reads the way the board does: the first three cards are
    /// the top row, left to right, and not the first column.
    func testAFullGridReadsInTheBoardsOrder() {
        let tiles = frames(.grid, 6, in: wide)
        XCTAssertEqual(tiles[0].minY, tiles[2].minY, accuracy: 0.5, "the first three are the top row")
        XCTAssertLessThan(tiles[0].minX, tiles[1].minX)
        XCTAssertLessThan(tiles[1].minX, tiles[2].minX)
        XCTAssertGreaterThan(tiles[3].minY, tiles[0].minY, "the fourth starts the second row")
    }

    /// **A short last row leaves the columns past its end one tile shorter**, and every column still
    /// fills the height — which is what a grid of columns is, and why it no longer centres the row.
    func testAShortLastRowLeavesItsColumnsFullHeight() {
        let session = arranged(.grid, 7, in: wide)
        XCTAssertEqual(session.columns.map(\.tiles.count), [2, 2, 2, 1])
        let room = CanvasTiling.space(of: wide)
        for column in CanvasTiling.frames(of: session.columns, in: wide) {
            XCTAssertEqual(column.last!.maxY, room.maxY, accuracy: 0.5)
        }
    }

    // MARK: Master and stack

    func testTheMasterTakesItsShareAndTheStackTakesTheRest() {
        let room = CanvasTiling.space(of: wide)
        let tiles = frames(.masterStack, 4, in: wide)
        XCTAssertEqual(tiles[0].height, room.height, accuracy: 0.5, "the master is full height")
        XCTAssertEqual(tiles[0].width, (room.width - CanvasTiling.gap) * 0.6, accuracy: 0.5)
        for tile in tiles.dropFirst() {
            XCTAssertEqual(tile.maxX, room.maxX, accuracy: 0.5, "the stack is flush to the trailing edge")
        }
        for (a, b) in pairs(tiles) {
            XCTAssertFalse(a.inset(by: -1).intersects(b.inset(by: -1)))
        }
    }

    /// A fraction dragged past either end is clamped rather than producing a tile with no width.
    func testTheSplitIsClamped() {
        for fraction in [-2.0, 0.0, 1.0, 5.0] {
            for tile in frames(.masterStack, 3, in: wide, fraction: fraction) {
                XCTAssertGreaterThan(tile.width, 1, "fraction \(fraction)")
            }
        }
    }

    // MARK: One card

    /// ⌘Return with one card selected is "fill the window with this", which is the same command and
    /// has to produce one tile filling the area whichever arrangement is asked for.
    func testOneCardFillsTheWindow() {
        for arrangement in CanvasTiling.Arrangement.allCases {
            let tiles = frames(arrangement, 1, in: wide, fraction: 0.62)
            XCTAssertEqual(tiles.count, 1)
            XCTAssertLessThan(tiles[0].width, wide.width, "inset from the edges")
            XCTAssertGreaterThan(tiles[0].width, wide.width - 4 * CanvasTiling.gap)
        }
    }

    // MARK: What the command is called

    /// The wording the View menu, the contextual menu and the header button all share. One title
    /// however many are picked — see `CanvasTiling.commandTitle`.
    func testAnUntiledBoardOffersToMakeAWorkspaceOfTheSelection() {
        for targets in [1, 6, 9] {
            XCTAssertEqual(CanvasTiling.commandTitle(tiled: false, targets: targets),
                           "New Workspace from Selection")
        }
    }

    /// **Nothing selected is nothing to make.** A workspace is saved, named and given a tab, so one
    /// made out of wherever the board happened to be scrolled is a surprise you then have to delete.
    func testNothingSelectedHasNoWorkspaceToOffer() {
        XCTAssertEqual(CanvasTiling.commandTitle(tiled: false, targets: 0), "New Workspace")
    }

    /// **Inside a workspace this is the way out, whatever is picked.** Looking at one tile on its own
    /// is Maximize, which is a different command and puts the workspace back.
    func testInsideAWorkspaceTheCommandIsAlwaysTheWayOut() {
        for targets in [0, 1, 6] {
            XCTAssertEqual(CanvasTiling.commandTitle(tiled: true, targets: targets), "Show Canvas")
        }
    }

    // MARK: Pinning one and stretching the rest

    /// The case the whole mechanism exists for: one length held, the others absorb the window.
    func testAPinnedTileKeepsItsLengthAndTheRestShareWhatIsLeft() {
        let lengths = CanvasTiling.run([.pinned(300), .even, .even], across: 1000)
        XCTAssertEqual(lengths[0], 300)
        XCTAssertEqual(lengths[1], 350)
        XCTAssertEqual(lengths[2], 350)
    }

    /// The same run in a window 200pt narrower: every point of that comes off the flexible ones.
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

    /// A pin is a request, and a request that would push tiles out of the window has to lose.
    func testAPinYieldsRatherThanOverflowingTheWindow() {
        let lengths = CanvasTiling.run([.pinned(600), .even, .even], across: 500)
        XCTAssertEqual(lengths.reduce(0, +), 500, accuracy: 0.001, "nothing hangs off the edge")
        XCTAssertLessThan(lengths[0], 600, "the pin was overruled")
        XCTAssertEqual(lengths[1], CanvasTiling.minimumTile)
        XCTAssertEqual(lengths[2], CanvasTiling.minimumTile)
    }

    /// Squeezed past the point where even the minimums fit, everything shares.
    func testAWindowTooSmallForAnyoneSharesEvenly() {
        let lengths = CanvasTiling.run([.pinned(600), .even, .even], across: 90)
        XCTAssertEqual(lengths.reduce(0, +), 90, accuracy: 0.001)
        for length in lengths { XCTAssertEqual(length, 30, accuracy: 0.001) }
    }

    // MARK: A workspace saved before columns

    /// Lengths kept per card are honoured where the arrangement honoured them: two cards side by side
    /// is a grid of one row, which is a run, and the pinned one keeps its width.
    func testAGridOfOneRowIsARun() {
        let room = CanvasTiling.space(of: wide)
        let tiles = frames(.grid, 2, in: wide, sizes: ["0": .pinned(300)])
        XCTAssertEqual(tiles[0].width, 300)
        XCTAssertEqual(tiles[0].maxX + CanvasTiling.gap, tiles[1].minX, accuracy: 0.001)
        XCTAssertEqual(tiles[1].maxX, room.maxX, accuracy: 0.001)
    }

    /// A grid of rows *and* columns had no run to pin along, so its lengths come back even.
    func testARealGridIgnoresSizes() {
        XCTAssertEqual(frames(.grid, 6, in: wide, sizes: ["0": .pinned(200)]).map(\.width),
                       frames(.grid, 6, in: wide).map(\.width))
    }

    /// The stack is a vertical run, so a length pinned there holds a height.
    func testPinningInTheStackHoldsAHeight() {
        let tiles = frames(.masterStack, 3, in: wide, sizes: ["1": .pinned(120)])
        XCTAssertEqual(tiles[1].height, 120)
        XCTAssertEqual(tiles[2].maxY, CanvasTiling.space(of: wide).maxY, accuracy: 0.001)
    }

    /// A pinned master is a width in points rather than a fraction of the window.
    func testAPinnedMasterIgnoresTheFraction() {
        for fraction in [0.3, 0.62, 0.85] {
            XCTAssertEqual(frames(.masterStack, 3, in: wide, fraction: fraction,
                                  sizes: ["0": .pinned(420)])[0].width, 420)
        }
    }

    /// Restoring one is running its arrangement once, into this window, and keeping what it can.
    func testAWorkspaceSavedBeforeColumnsIsLaidOutByItsArrangement() {
        let saved = CanvasViewState.Tiling(ids: ["a", "b", "c", "d"], arrangement: .masterStack,
                                           masterFraction: 0.6, sizes: ["a": .pinned(420)])
        let session = CanvasTileSession(restoring: saved, keeping: { _ in true }, area: wide,
                                        restoreVisible: wide, restoreZoom: 1)
        XCTAssertEqual(session?.master, "a")
        XCTAssertEqual(session?.columns[0].width, .pinned(420))
        XCTAssertEqual(session?.columns[1].tiles.map(\.shown), ["b", "c", "d"])
    }

    // MARK: What is saved

    /// A workspace comes back exactly as it went: the same columns, the same tiles, the same lengths.
    func testASavedWorkspaceComesBackAsItWas() {
        var session = arranged(.masterStack, 4, in: wide)
        session.togglePin("2")
        let back = CanvasTileSession(restoring: session.memory, keeping: { _ in true }, area: wide,
                                     restoreVisible: wide, restoreZoom: 1)
        XCTAssertEqual(back?.columns, session.columns)
    }

    /// And through JSON, which is where it actually goes.
    func testTheColumnsSurviveEncoding() throws {
        var session = arranged(.grid, 5, in: wide)
        session.togglePin("1")
        let data = try JSONEncoder().encode(session.memory)
        let decoded = try JSONDecoder().decode(CanvasViewState.Tiling.self, from: data)
        XCTAssertEqual(decoded.columns, session.columns)
    }

    /// **A build from before columns can still open one.** It reads the old fields and nothing else,
    /// so they are written — every card, in the order you read them off the screen, and the
    /// arrangement the shape looks like.
    func testOlderBuildsCanStillReadWhatIsSaved() throws {
        struct Before: Codable {
            var ids: [String]
            var arrangement: CanvasTiling.Arrangement
            var masterFraction: Double
            var sizes: [String: CanvasTiling.Size]?
        }
        let grid = try JSONDecoder().decode(Before.self,
                                            from: JSONEncoder().encode(arranged(.grid, 4, in: square).memory))
        XCTAssertEqual(grid.ids, ["0", "1", "2", "3"], "reading order, not the columns' order")
        XCTAssertEqual(grid.arrangement, .grid)

        let master = try JSONDecoder().decode(Before.self,
                                              from: JSONEncoder().encode(arranged(.masterStack, 3, in: wide).memory))
        XCTAssertEqual(master.arrangement, .masterStack)
        XCTAssertEqual(master.masterFraction, 0.6, accuracy: 0.001)
    }

    /// What the file wrote before columns existed still decodes, as a tiling with none.
    func testATilingFromBeforeColumnsStillDecodes() throws {
        let old = Data(#"{"ids":["a","b"],"arrangement":"grid","masterFraction":0.62}"#.utf8)
        let tiling = try JSONDecoder().decode(CanvasViewState.Tiling.self, from: old)
        XCTAssertNil(tiling.columns)
        XCTAssertEqual(tiling.ids, ["a", "b"])
    }

    /// A card deleted since is dropped, and a column it leaves empty goes with it.
    func testACardThatHasGoneIsDroppedOnRestore() {
        let saved = arranged(.masterStack, 3, in: wide).memory
        let back = CanvasTileSession(restoring: saved, keeping: { $0 != "0" }, area: wide,
                                     restoreVisible: wide, restoreZoom: 1)
        XCTAssertEqual(back?.columns.count, 1, "the master's column went with the master")
        XCTAssertEqual(back?.ids, ["1", "2"])
    }

    func testNothingLeftIsNoWorkspace() {
        let saved = arranged(.grid, 3, in: wide).memory
        XCTAssertNil(CanvasTileSession(restoring: saved, keeping: { _ in false }, area: wide,
                                       restoreVisible: wide, restoreZoom: 1))
    }

    /// Re-arranging deals the tiles in reading order, so the card you read first is the master.
    func testRearrangingKeepsTheCardYouReadFirst() {
        let grid = arranged(.grid, 4, in: square)
        let columns = CanvasTiling.columns(.masterStack, of: grid.readingOrder, in: square,
                                           masterFraction: 0.6)
        XCTAssertEqual(columns[0].tiles.map(\.shown), ["0"])
        XCTAssertEqual(columns[1].tiles.map(\.shown), ["1", "2", "3"])
    }

    // MARK: Adding and removing tiles

    /// A row of tiles, one column each, in a window wide enough to hold them.
    private func row(_ ids: [String], widths: [CanvasTiling.Size]? = nil) -> CanvasTileSession {
        let area = CanvasRect(x: 0, y: 0, width: 1800, height: 300)
        let columns = ids.enumerated().map { index, id in
            CanvasTiling.Column(width: widths?[index] ?? .even, [CanvasTiling.Tile(id)])
        }
        return CanvasTileSession(columns: columns, area: area, restoreVisible: area)
    }

    /// A master and a stack beside it, the stack's tiles at the heights given.
    private func masterAndStack(_ master: String, _ stack: [(String, CanvasTiling.Size)]) -> CanvasTileSession {
        CanvasTileSession(columns: [.init(width: .flexible(0.6), [.init(master)]),
                                    .init(width: .flexible(0.4), stack.map { .init($0.0, height: $0.1) })],
                          area: wide, restoreVisible: wide)
    }

    /// With nowhere to go beside, a new card goes on the end: the bottom of the last column.
    func testANewCardGoesOnTheEnd() {
        var session = row(["a", "b", "c"])
        session.add("d")
        XCTAssertEqual(session.ids, ["a", "b", "c", "d"])
    }

    /// Including in master-and-stack, where the end is the bottom of the stack — *not* the master slot.
    func testANewCardDoesNotBecomeTheMaster() {
        var session = masterAndStack("a", [("b", .even), ("c", .even)])
        session.add("d")
        XCTAssertEqual(session.master, "a", "the master is still the master")
        XCTAssertEqual(session.ids.last, "d")
    }

    func testACardAlreadyUpIsNotAddedTwice() {
        var session = row(["a", "b", "c"])
        session.add("b")
        XCTAssertEqual(session.ids, ["a", "b", "c"])
    }

    /// Every tile gets a frame, so a card added is a card on the screen.
    func testTheAddedCardIsOnScreen() {
        var session = row(["a", "b", "c"])
        session.add("d")
        XCTAssertNotNil(session.layout.frames["d"])
        XCTAssertTrue(session.layout.shows("d"))
        XCTAssertEqual(session.layout.frames.count, 4)
    }

    /// **A peer, not a sliver.** A column whose heights a drag has stated in points gives a newcomer
    /// the average of them, rather than a weight of 1 among weights in the hundreds.
    func testANewTileArrivesTheSizeOfItsNeighbours() {
        var session = masterAndStack("a", [("b", .flexible(300)), ("c", .flexible(100))])
        session.add("d")
        XCTAssertEqual(session.columns[1].tiles.last?.height, .flexible(200))
    }

    func testRemovingATileTakesItOffTheScreen() {
        var session = row(["a", "b", "c"])
        session.remove("b")
        XCTAssertEqual(session.ids, ["a", "c"])
        XCTAssertNil(session.layout.frames["b"])
        XCTAssertFalse(session.layout.shows("b"), "the layout stops showing it")
    }

    /// A tile alone in its column takes the column with it, and the column's width; every other
    /// length is exactly what must survive, or every removal would quietly even out an arrangement you
    /// had dragged into shape.
    func testRemovingATileTakesItsColumnAndLeavesEveryOtherLengthAlone() {
        var session = row(["a", "b", "c"], widths: [.pinned(300), .pinned(420), .even])
        session.remove("b")
        XCTAssertEqual(session.columns.map(\.width), [.pinned(300), .even])
    }

    func testRemovingACardThatIsNotUpChangesNothing() {
        var session = row(["a", "b", "c"], widths: [.pinned(300), .even, .even])
        let before = session
        session.remove("zzz")
        XCTAssertEqual(session, before)
    }

    /// Add then remove is the identity, which is what "a tiling is a way of looking" has to mean.
    func testAddingAndRemovingLeavesTheArrangementAsItWas() {
        let before = masterAndStack("a", [("b", .flexible(300)), ("c", .pinned(120))])
        var session = before
        session.add("d")
        session.remove("d")
        XCTAssertEqual(session, before)
    }

    // MARK: Swapping and promoting

    /// **The cards change places and the sizes stay put** (docs/canvas-workspaces.md §7k).
    func testSwappingMovesTheCardsAndLeavesTheSizes() {
        var session = row(["a", "b", "c"], widths: [.pinned(300), .even, .even])
        session.swap("a", with: "c")
        XCTAssertEqual(session.ids, ["c", "b", "a"])
        XCTAssertEqual(session.columns.map(\.width), [.pinned(300), .even, .even])
    }

    /// The promoted tile becomes the master, the old master goes to the top of the stack, and the tiles
    /// above the promoted one move down one — with every slot keeping its size.
    func testPromotingPutsTheOldMasterAtTheTopOfTheStack() {
        var session = masterAndStack("m", [("a", .flexible(100)), ("b", .flexible(200)),
                                           ("x", .flexible(300))])
        session.promote("x")
        XCTAssertEqual(session.ids, ["x", "m", "a", "b"])
        XCTAssertEqual(session.columns[1].tiles.map(\.height),
                       [.flexible(100), .flexible(200), .flexible(300)])
    }

    /// **There is a master when the shape has one** — two columns, the first holding one tile — and
    /// not otherwise, whichever arrangement made the columns.
    func testAGridHasNoMaster() {
        let grid = arranged(.grid, 6, in: wide)
        XCTAssertNil(grid.master)
        XCTAssertFalse(grid.canPromote("3"))
        XCTAssertTrue(arranged(.masterStack, 3, in: wide).canPromote("2"))
        XCTAssertFalse(arranged(.masterStack, 3, in: wide).canPromote("0"), "the master already is")
    }

    // MARK: Tabs

    /// A tab that isn't showing is not drawn, which is the whole of what makes switching tabs free.
    func testOnlyTheShowingTabIsDrawn() {
        let session = CanvasTileSession(columns: [.init([.init(["a", "b"], showing: 1)]),
                                                  .init([.init("c")])],
                                        area: wide, restoreVisible: wide)
        XCTAssertEqual(session.layout.visible, ["b", "c"])
        XCTAssertEqual(session.cards, ["a", "b", "c"])
        XCTAssertEqual(session.ids, ["b", "c"])
    }

    /// Taking out the tab that is showing shows its neighbour, and the tile stays.
    func testTakingOutTheShowingTabShowsTheNextOne() {
        var session = CanvasTileSession(columns: [.init([.init(["a", "b"], showing: 1)]),
                                                  .init([.init("c")])],
                                        area: wide, restoreVisible: wide)
        session.remove("b")
        XCTAssertEqual(session.ids, ["a", "c"])
        XCTAssertEqual(session.columns.count, 2)
    }

    // MARK: Tabs, drawn and moved

    /// Two cards sharing the first tile, one on its own beside it.
    private func tabbed() -> CanvasTileSession {
        CanvasTileSession(columns: [.init([.init(["a", "b"])]), .init([.init("c")])],
                          area: wide, restoreVisible: wide)
    }

    /// A tile of several cards has a strip across its top, and the card showing is drawn below it.
    func testATileOfSeveralDrawsItsCardBelowItsTabs() {
        let session = tabbed()
        XCTAssertEqual(session.tabStrips.map(\.cards), [["a", "b"]])
        let tile = session.tileFrames["a"]!
        XCTAssertEqual(session.layout.frames["a"]!.minY, tile.minY + CanvasTiling.tabStrip, accuracy: 0.001)
        XCTAssertEqual(session.layout.frames["a"]!.maxY, tile.maxY, accuracy: 0.001)
        XCTAssertEqual(session.layout.frames["c"], session.tileFrames["c"], "a tile of one has no strip")
    }

    /// Tabs share the strip, none wider than a tab needs to be, none overlapping.
    /// A tab slid along its strip lands where it was let go, and the card showing stays the one shown.
    func testATabMovesAlongItsStripKeepingTheOneShowing() {
        var session = CanvasTileSession(columns: [.init([.init(["a", "b", "c"], showing: 1)])],
                                        area: wide, restoreVisible: wide)
        XCTAssertTrue(session.moveTab("a", to: 2))
        XCTAssertEqual(session.tabStrips.first?.cards, ["b", "c", "a"])
        XCTAssertEqual(session.tabStrips.first.map { $0.cards[$0.showing] }, "b")
        XCTAssertFalse(session.moveTab("a", to: 2), "where it already is is no move")
        XCTAssertTrue(session.moveTab("c", to: 0))
        XCTAssertEqual(session.tabStrips.first?.cards, ["c", "b", "a"])
    }

    func testTabsShareTheStripAndNoneIsTooWide() {
        let band = CanvasRect(x: 0, y: 0, width: 900, height: 28)
        let tabs = CanvasTiling.tabs(in: band, count: 3)
        for tab in tabs {
            XCTAssertLessThanOrEqual(tab.width, CanvasTiling.longestTab)
            XCTAssertGreaterThanOrEqual(tab.minX, band.minX)
            XCTAssertLessThanOrEqual(tab.maxX, band.maxX)
        }
        for (a, b) in pairs(tabs) { XCTAssertFalse(a.intersects(b)) }
        let plus = CanvasTiling.newTabButton(in: band, count: 3)
        XCTAssertGreaterThan(plus.minX, tabs[2].maxX, "the + follows the last tab")
        XCTAssertLessThanOrEqual(plus.maxX, band.maxX)
        let squeezed = CanvasRect(x: 0, y: 0, width: 300, height: 28)
        XCTAssertLessThanOrEqual(CanvasTiling.newTabButton(in: squeezed, count: 3).maxX, squeezed.maxX,
                                 "however many tabs there are, the + stays on the strip")
        let narrow = CanvasTiling.tabs(in: CanvasRect(x: 0, y: 0, width: 300, height: 28), count: 3)
        XCTAssertLessThan(narrow[0].width, 100, "squeezed, they share what there is")
    }

    // MARK: Tabs down the side (backlog 36)

    /// A tile with its tabs on the side draws its card beside them: names wide on a tile that can spare
    /// it, icons wide on one that can't, and the tabs stacked down the band without overlapping.
    func testTabsOnTheSideStandBesideTheCard() {
        var session = tabbed()
        XCTAssertTrue(session.setTabsOnSide("a", true))
        XCTAssertFalse(session.setTabsOnSide("b", true), "already on the side")
        let tile = session.tileFrames["a"]!
        let strip = session.tabStrips[0]
        XCTAssertTrue(strip.onSide)
        XCTAssertEqual(strip.band.width, CanvasTiling.sideStrip, accuracy: 0.001)
        XCTAssertTrue(strip.namesShown)
        let card = session.layout.frames[session.ids[0]]!
        XCTAssertEqual(card.minX, tile.minX + CanvasTiling.sideStrip, accuracy: 0.001)
        XCTAssertEqual(card.minY, tile.minY, accuracy: 0.001, "no strip across the top")
        XCTAssertEqual(card.maxX, tile.maxX, accuracy: 0.001)
        let tabs = strip.tabs
        XCTAssertLessThan(tabs[0].maxY, tabs[1].minY)
        XCTAssertGreaterThan(strip.newTabButton.minY, tabs[1].maxY, "the + follows the last tab down")
        for tab in tabs { XCTAssertTrue(strip.band.contains(x: tab.midX, y: tab.midY)) }

        let narrow = CanvasRect(x: 0, y: 0, width: 400, height: 600)
        let icons = CanvasTileSession.tabBand(of: narrow, onSide: true)
        XCTAssertEqual(icons.width, CanvasTiling.iconStrip, accuracy: 0.001)
        XCTAssertFalse(CanvasTileSession.TabStrip(band: icons, cards: ["a", "b"], showing: 0, onSide: true).namesShown)
    }

    /// A column of tabs longer than its tile scrolls, never past either end, and showing a tab scrolled
    /// out of sight brings it back.
    func testASideStripTooShortScrollsAndShowsTheTabShowing() {
        let cards = (0..<30).map { "t\($0)" }
        var session = CanvasTileSession(columns: [.init([.init(cards, tabsOnSide: true)])],
                                        area: wide, restoreVisible: wide)
        var strip = session.tabStrips[0]
        XCTAssertGreaterThan(strip.maxScroll, 0)
        XCTAssertEqual(strip.scroll, 0)
        XCTAssertFalse(session.scrollTabs(of: "t0", by: -50), "nothing above the top")
        XCTAssertTrue(session.scrollTabs(of: "t0", by: 100_000))
        strip = session.tabStrips[0]
        XCTAssertEqual(strip.scroll, strip.maxScroll, accuracy: 0.001)
        XCTAssertLessThanOrEqual(strip.newTabButton.maxY, strip.band.maxY + 0.001, "the end is in view")

        XCTAssertTrue(session.showTab("t29"))
        XCTAssertEqual(session.tabStrips[0].scroll, strip.maxScroll, accuracy: 0.001, "in view already")
        XCTAssertTrue(session.showTab("t0"))
        strip = session.tabStrips[0]
        XCTAssertGreaterThanOrEqual(strip.tabs[0].minY, strip.band.minY, "the tab shown is scrolled to")
        XCTAssertTrue(session.showTab("t29"))
        strip = session.tabStrips[0]
        XCTAssertLessThanOrEqual(strip.tabs[29].maxY, strip.band.maxY, "and to the bottom as well")

        let short = CanvasTileSession(columns: [.init([.init(["a", "b"], tabsOnSide: true)])],
                                      area: wide, restoreVisible: wide)
        XCTAssertEqual(short.tabStrips[0].maxScroll, 0, "a column that fits doesn't scroll")
    }

    /// A drop on the side strip joins the tabs, and the tile's sides are still reachable beside it.
    func testDroppingOnASideStripJoinsItsTabs() {
        let frame = CanvasRect(x: 0, y: 0, width: 800, height: 600)
        XCTAssertEqual(CanvasTileSession.drop(at: CanvasPoint(x: 90, y: 300), on: frame, tabsOnSide: true),
                       .beside(.tab))
        XCTAssertEqual(CanvasTileSession.drop(at: CanvasPoint(x: 200, y: 300), on: frame, tabsOnSide: true),
                       .beside(.left), "just past the strip is the card's left edge")
        XCTAssertEqual(CanvasTileSession.drop(at: CanvasPoint(x: 400, y: 10), on: frame, tabsOnSide: true),
                       .beside(.above), "the top is no longer the tabs'")
        var session = tabbed()
        session.setTabsOnSide("a", true)
        XCTAssertEqual(session.dropMark(.beside(.tab), on: "a"),
                       CanvasTileSession.tabBand(of: session.tileFrames["a"]!, onSide: true))
    }

    /// The setting is the tile's: it goes with the tile when tiles swap, and it is saved — written only
    /// when on, and read as off from a workspace saved before it existed.
    func testTabsOnTheSideGoWithTheTileAndAreSaved() throws {
        var session = tabbed()
        session.setTabsOnSide("a", true)
        session.swap("a", with: "c")
        XCTAssertTrue(session.tabsOnSide("a"))
        XCTAssertFalse(session.tabsOnSide("c"))

        let on = try JSONEncoder().encode(CanvasTiling.Tile(["a", "b"], tabsOnSide: true))
        XCTAssertEqual(try JSONDecoder().decode(CanvasTiling.Tile.self, from: on).tabsOnSide, true)
        let off = try JSONEncoder().encode(CanvasTiling.Tile(["a", "b"]))
        XCTAssertFalse(String(decoding: off, as: UTF8.self).contains("tabsOnSide"))
        let height = try JSONEncoder().encode(CanvasTiling.Size.even)
        let saved = Data(#"{"cards":["a"],"showing":0,"height":"#.utf8) + height + Data("}".utf8)
        XCTAssertEqual(try JSONDecoder().decode(CanvasTiling.Tile.self, from: saved).tabsOnSide, false)
    }

    /// The strip's menus act on a whole tile: Close Other Tabs and Remove Tile read its cards from here.
    func testATilesTabsAreItsCards() {
        var session = tabbed()
        XCTAssertEqual(session.tabs(of: "b"), ["a", "b"])
        XCTAssertEqual(session.tabs(of: "c"), ["c"])
        XCTAssertEqual(session.tabs(of: "z"), [])
        // Adding as a tab is the ⌥N preselection the + and the strip's menu set.
        session.add("d", at: .init(target: "a", side: .tab))
        XCTAssertEqual(session.tabs(of: "a"), ["a", "b", "d"])
        XCTAssertEqual(session.ids, ["d", "c"], "the tab just added is the one showing")
    }

    /// ⌥[ and ⌥]: step through the tabs, round and round.
    func testSteppingTabsWrapsRound() {
        var session = tabbed()
        XCTAssertEqual(session.stepTab(of: "a", by: 1), "b")
        XCTAssertEqual(session.stepTab(of: "b", by: 1), "a")
        XCTAssertEqual(session.stepTab(of: "a", by: -1), "b")
        XCTAssertNil(session.stepTab(of: "c", by: 1), "a tile of one has nothing to step to")
    }

    /// The tile filling the room is named by the card it shows, so the name follows the tab — and
    /// maximizing a tile doesn't close its tabs.
    func testShowingATabKeepsItsTileMaximized() {
        var session = tabbed()
        session.maximized = "a"
        session.showTab("b")
        XCTAssertEqual(session.maximized, "b")
        XCTAssertEqual(session.layout.visible, ["b"])
        XCTAssertEqual(session.tabStrips.count, 1)
    }

    /// ⌥T, and a tab dragged beside the tile it came from: out into a tile of its own, and the tile it
    /// left shows another of its cards.
    func testPullingATabOutPutsItBesideTheTileItCameFrom() {
        var session = tabbed()
        session.pull("a", to: .init(target: "a", side: .right))
        XCTAssertEqual(session.columns.map { $0.tiles.map(\.cards) }, [[["b"]], [["a"]], [["c"]]])
    }

    /// Into another tile's tabs, where it is the one that shows.
    func testPullingATabIntoAnotherTilesTabs() {
        var session = tabbed()
        session.pull("a", to: .init(target: "c", side: .tab))
        XCTAssertEqual(session.columns.map { $0.tiles.map(\.cards) }, [[["b"]], [["c", "a"]]])
        XCTAssertEqual(session.ids, ["b", "a"])
    }

    /// Back into the tabs it came from is where it already is.
    func testPullingATabIntoItsOwnTabsDoesNothing() {
        var session = tabbed()
        let before = session
        session.pull("a", to: .init(target: "b", side: .tab))
        XCTAssertEqual(session, before)
    }

    /// A card with its tile to itself takes the tile with it.
    func testPullingTheOnlyCardMovesItsTile() {
        var session = tabbed()
        session.pull("c", to: .init(target: "a", side: .below))
        XCTAssertEqual(session.columns.map { $0.tiles.map(\.cards) }, [[["a", "b"], ["c"]]])
    }

    /// A whole tile dropped on the top of another joins its tabs, and is what shows.
    func testDroppingATileOnAnotherTilesStripJoinsItsTabs() {
        var session = tabbed()
        session.drop("c", on: "a", .beside(.tab))
        XCTAssertEqual(session.columns.map { $0.tiles.map(\.cards) }, [[["a", "b", "c"]]])
        XCTAssertEqual(session.ids, ["c"], "what you put there is what shows")
    }

    /// The top of a tile is its tabs; a tab pulled out joins them from the middle too.
    func testTheTopOfATileIsItsTabs() {
        let frame = CanvasRect(x: 0, y: 0, width: 400, height: 300)
        XCTAssertEqual(CanvasTileSession.drop(at: CanvasPoint(x: 200, y: 10), on: frame), .beside(.tab))
        XCTAssertEqual(CanvasTileSession.drop(at: CanvasPoint(x: 200, y: 150), on: frame,
                                              middle: .beside(.tab)), .beside(.tab))
    }

    /// As a tab there is no room to make: nothing moves, and the place is the top of the tile.
    func testChoosingATabMakesNoRoom() {
        var session = row(["a", "b"])
        let before = session.layout
        session.preselection = .init(target: "b", side: .tab)
        XCTAssertEqual(session.layout, before)
        XCTAssertEqual(session.placementFrame, CanvasTileSession.tabBand(of: session.tileFrames["b"]!))
    }

    /// Added as a tab, the new card is the one that shows. Backlog 8 — swap the card in a tile — is
    /// that, and then taking the old one out.
    func testAddingAsATabShowsItAndSwapsTheCardInATile() {
        var session = row(["a", "b"])
        session.add("n", at: .init(target: "a", side: .tab))
        XCTAssertEqual(session.ids, ["n", "b"])
        session.remove("a")
        XCTAssertEqual(session.columns.map { $0.tiles.map(\.cards) }, [[["n"]], [["b"]]])
    }

    // MARK: Picking on the board

    /// The workspace's cards are numbered as it reads — rows, then left to right, not the columns'
    /// order — and a tile's tabs share its number.
    func testTheWorkspaceIsNumberedAsItReads() {
        XCTAssertEqual(arranged(.grid, 4, in: square).tileNumbers, ["0": 1, "1": 2, "2": 3, "3": 4])
        XCTAssertEqual(tabbed().tileNumbers, ["a": 1, "b": 1, "c": 2])
    }

    /// A click puts in whatever isn't in, takes out what is all in already, and never takes out the last
    /// card — a frame half in goes all in, which is the useful half of the ambiguity.
    func testAPickAddsWhatIsMissingAndTakesOutWhatIsAllIn() {
        let session = row(["a", "b", "c"])
        XCTAssertEqual(session.pick(["x"]), .add(["x"]))
        XCTAssertEqual(session.pick(["a", "x", "y"]), .add(["x", "y"]))
        XCTAssertEqual(session.pick(["b"]), .remove(["b"]))
        XCTAssertEqual(session.pick(["a", "b", "c"]), .refuse, "not every card out")
        XCTAssertEqual(session.pick([]), .refuse)
    }

    // MARK: Peeking

    /// Space on a card while picking brings it close at its own size when the window has room for it —
    /// never larger — in the middle of what the sidebar and the header leave.
    func testAPeekShowsACardAtItsOwnSizeInTheMiddleOfTheRoom() {
        let card = CanvasRect(x: 1000, y: 500, width: 400, height: 300)
        let margins = CanvasTiling.Margins(leading: 200, trailing: 0, top: 40)
        let peek = CanvasTiling.peek(at: card, in: (width: 1200, height: 800), margins: margins)
        XCTAssertEqual(peek.zoom, 1)
        let room = CanvasTiling.area(of: seen(peek, 1200, 800), margins: margins)
        XCTAssertEqual(room.midX, card.midX, accuracy: 0.5)
        XCTAssertEqual(room.midY, card.midY, accuracy: 0.5)
    }

    /// A card bigger than the window is shown whole, with room round it, and still in the middle.
    func testAPeekAtACardBiggerThanTheWindowShowsItWhole() {
        let card = CanvasRect(x: 0, y: 0, width: 2000, height: 1600)
        let margins = CanvasTiling.Margins(leading: 100, trailing: 0, top: 40)
        let peek = CanvasTiling.peek(at: card, in: (width: 1200, height: 800), margins: margins)
        XCTAssertLessThan(peek.zoom, 1)
        XCTAssertEqual(card.height * peek.zoom, 800 - 40 - 2 * CanvasTiling.peekRoom, accuracy: 0.5,
                       "the tall way is the one that runs out")
        XCTAssertLessThanOrEqual(card.width * peek.zoom, 1200 - 100 - 2 * CanvasTiling.peekRoom)
        let scaled = CanvasTiling.Margins(leading: 100 / peek.zoom, trailing: 0, top: 40 / peek.zoom)
        let room = CanvasTiling.area(of: seen(peek, 1200, 800), margins: scaled)
        XCTAssertEqual(room.midX, card.midX, accuracy: 0.5)
        XCTAssertEqual(room.midY, card.midY, accuracy: 0.5)
    }

    // MARK: Sizing to content

    /// Each column's share becomes its widest card's — a tab that isn't showing counts — and a pinned
    /// column keeps its pin.
    func testSizingToContentSharesTheWidthByTheWidestCardInEachColumn() {
        var session = row(["a", "b", "c"])
        session.add("d", at: .init(target: "b", side: .tab))
        session.togglePin(.columns, at: 2)
        let pinned = session.sizes(of: .columns)[2]
        let widths: [String: Double] = ["a": 1024, "b": 320, "c": 720, "d": 1024]
        session.sizeToContent { widths[$0] ?? 0 }
        XCTAssertEqual(session.sizes(of: .columns), [.flexible(1024), .flexible(1024), pinned])
    }

    /// A page wants the most room, then a PDF, a note, a picture, and a text card the least.
    func testWhatACardReadsAtFollowsItsKind() {
        let frame = CanvasRect(x: 0, y: 0, width: 200, height: 150)
        let page = CanvasTileSession.contentWidth(of: CanvasNode(content: .link(url: "https://example.com"),
                                                                 frame: frame))
        let pdf = CanvasTileSession.contentWidth(of: CanvasNode(content: .file(path: "a.pdf", subpath: nil),
                                                                frame: frame))
        let note = CanvasTileSession.contentWidth(of: CanvasNode(content: .file(path: "docs/Notes - Walkable.md",
                                                                                subpath: nil), frame: frame))
        let picture = CanvasTileSession.contentWidth(of: CanvasNode(content: .file(path: "b.png", subpath: nil),
                                                                    frame: frame))
        let text = CanvasTileSession.contentWidth(of: CanvasNode(content: .text("hello"), frame: frame))
        XCTAssertEqual([page, pdf, note, picture, text], [page, pdf, note, picture, text].sorted(by: >))
        XCTAssertGreaterThan(page, pdf)
        XCTAssertGreaterThan(picture, text)
        XCTAssertGreaterThan(text, 0)
    }

    /// What a window `width` by `height` points shows, looking where a peek says to.
    private func seen(_ peek: (zoom: Double, centre: CanvasPoint), _ width: Double, _ height: Double) -> CanvasRect {
        CanvasRect(x: peek.centre.x - width / peek.zoom / 2, y: peek.centre.y - height / peek.zoom / 2,
                   width: width / peek.zoom, height: height / peek.zoom)
    }

    // MARK: Boundaries

    /// One between each pair of columns, and one between each pair of tiles down every column — and a
    /// boundary between two tiles reaches only as far as their column is wide.
    func testEveryColumnAndEveryTileInAColumnHasABoundary() {
        let session = arranged(.masterStack, 4, in: wide)
        let dividers = session.dividers
        XCTAssertEqual(dividers.filter(\.isVertical).count, 1)
        XCTAssertEqual(dividers.filter { !$0.isVertical }.count, 2)
        let stack = session.layout.frames["1"]!
        for divider in dividers where !divider.isVertical {
            XCTAssertEqual(divider.span.lowerBound, stack.minX, accuracy: 0.5,
                           "the stack's boundaries stop at the stack")
        }
    }

    /// A grid of rows *and* columns used to have no boundaries at all. Every one of them drags now.
    func testAGridOfRowsAndColumnsCanBeResized() {
        let dividers = arranged(.grid, 6, in: wide).dividers
        XCTAssertEqual(dividers.filter(\.isVertical).count, 2)
        XCTAssertEqual(dividers.filter { !$0.isVertical }.count, 3)
    }

    func testNoBoundariesWhileOneTileFillsTheRoom() {
        var session = arranged(.grid, 4, in: wide)
        session.maximized = "2"
        XCTAssertTrue(session.dividers.isEmpty)
    }

    /// Dragging a boundary moves the two either side of it and nothing else.
    func testDraggingABoundaryMovesOnlyTheTwoBesideIt() {
        var session = row(["a", "b", "c"])
        let lengths = session.lengths(of: .columns)
        session.resize(.columns, before: 0, lengths: lengths, to: lengths[0] + 100)
        let after = session.lengths(of: .columns)
        XCTAssertEqual(after[0], lengths[0] + 100, accuracy: 0.5)
        XCTAssertEqual(after[1], lengths[1] - 100, accuracy: 0.5)
        XCTAssertEqual(after[2], lengths[2], accuracy: 0.5)
    }

    /// A pin that was not dragged is left alone: its current length may be a squeeze the window forced.
    func testDraggingLeavesAnUndraggedPinAlone() {
        var session = row(["a", "b", "c"], widths: [.even, .even, .pinned(300)])
        let lengths = session.lengths(of: .columns)
        session.resize(.columns, before: 0, lengths: lengths, to: lengths[0] + 50)
        XCTAssertEqual(session.columns[2].width, .pinned(300))
    }

    // MARK: Pinning a tile

    /// A tile with its column to itself holds the column's width; one sharing its column holds its
    /// height — the master and the stack, as it always was.
    func testATilePinsAlongTheRunItIsIn() {
        var session = arranged(.masterStack, 3, in: wide)
        XCTAssertFalse(session.runIsVertical("0"))
        XCTAssertTrue(session.runIsVertical("1"))

        session.togglePin("0")
        guard case .pinned = session.columns[0].width else { return XCTFail("the master's width") }
        session.togglePin("1")
        guard case .pinned = session.columns[1].tiles[0].height else { return XCTFail("a stack tile's height") }
        XCTAssertTrue(session.isPinned("0"))
        XCTAssertTrue(session.isPinned("1"))
        XCTAssertFalse(session.isPinned("2"))
    }

    /// **Letting go keeps the picture.** An unpinned length takes its current size as its share, so
    /// nothing jumps until the window next changes.
    func testUnpinningKeepsThePicture() {
        var session = row(["a", "b", "c"], widths: [.flexible(1), .flexible(3), .flexible(1)])
        session.togglePin("b")
        let pinned = session.lengths(of: .columns)
        session.togglePin("b")
        XCTAssertFalse(session.isPinned("b"))
        for (after, before) in zip(session.lengths(of: .columns), pinned) {
            XCTAssertEqual(after, before, accuracy: 0.5)
        }
    }

    // MARK: Maximizing one tile

    /// **A maximized tile is a layout of one**, and that is the whole mechanism — the covered tiles
    /// simply are not in the layout, so their pages pause the same turn.
    func testAMaximizedTileIsTheOnlyOneInTheLayout() {
        var session = row(["a", "b", "c"])
        let shared = session.layout

        session.maximized = "b"
        let full = session.layout

        XCTAssertEqual(full.visible, ["b"])
        XCTAssertFalse(full.shows("a"))
        XCTAssertFalse(full.shows("c"))
        XCTAssertGreaterThan(full.frames["b"]!.width, shared.frames["b"]!.width,
                             "it fills the room the three were sharing")
        XCTAssertEqual(full.frames["b"], CanvasTiling.space(of: session.area),
                       "the whole tile space, which is why all four of its corners are outside ones")
    }

    /// Restoring is the layout that was already there — there is no second copy of it to drift.
    func testRestoringPutsTheSameLayoutBack() {
        var session = row(["a", "b", "c"])
        let before = session.layout
        session.maximized = "b"
        session.maximized = nil
        XCTAssertEqual(session.layout, before)
    }

    func testRemovingTheMaximizedTileClearsIt() {
        var session = row(["a", "b", "c"])
        session.maximized = "b"
        session.remove("b")
        XCTAssertNil(session.maximized)
        XCTAssertEqual(session.layout.visible, ["a", "c"])
    }

    func testRemovingAnotherTileLeavesTheMaximizedOneUp() {
        var session = row(["a", "b", "c"])
        session.maximized = "b"
        session.remove("c")
        XCTAssertEqual(session.maximized, "b")
        XCTAssertEqual(session.layout.visible, ["b"])
    }

    /// **A name that is not in the tiling is not a maximized tile.**
    func testAStaleMaximizedNameFallsBackToTheColumns() {
        var session = row(["a", "b", "c"])
        session.maximized = "gone"
        XCTAssertEqual(session.layout.visible, ["a", "b", "c"])
    }

    // MARK: Where the next card goes

    /// One column of tiles in a tall, narrow window.
    private func column(_ ids: [String]) -> CanvasTileSession {
        let area = CanvasRect(x: 0, y: 0, width: 300, height: 1800)
        return CanvasTileSession(columns: [.init(ids.map { CanvasTiling.Tile($0) })],
                                 area: area, restoreVisible: area)
    }

    /// **Splitting the tile along its longer side**: a wide one gets a new column beside it, a tall
    /// one a new tile below.
    func testAWideTileGetsANewColumnAndATallOneANewTileBelow() {
        XCTAssertEqual(row(["a", "b"]).automaticPlacement(beside: "a"), .init(target: "a", side: .right))
        XCTAssertEqual(column(["a", "b"]).automaticPlacement(beside: "a"), .init(target: "a", side: .below))
    }

    /// **Left and right are a new column beside the whole column** — full height, even when the tile
    /// you placed beside shares its column. No one tile of a column is ever split sideways.
    func testANewColumnOpensBesideTheWholeColumn() {
        var session = masterAndStack("m", [("a", .even), ("b", .even)])
        session.add("n", at: .init(target: "a", side: .right))
        XCTAssertEqual(session.columns.map { $0.tiles.map(\.shown) }, [["m"], ["a", "b"], ["n"]])
        XCTAssertEqual(session.layout.frames["n"]!.height, CanvasTiling.space(of: wide).height, accuracy: 0.5)
        XCTAssertEqual(session.columns.map(\.width), [.flexible(0.6), .flexible(0.2), .flexible(0.2)],
                       "the stack's share was split, and the master's left alone")
    }

    /// **Even stays even**: in a run nobody has sized, the newcomer is one more sharing.
    func testAnEvenRunStaysEven() {
        var session = row(["a", "b", "c"])
        session.add("d", at: .init(target: "b", side: .right))
        XCTAssertEqual(session.ids, ["a", "b", "d", "c"])
        XCTAssertEqual(session.columns.map(\.width), [.even, .even, .even, .even])
    }

    /// **A pin keeps its points**, and the newcomer arrives the size of an average share.
    func testAPinnedNeighbourKeepsItsPoints() {
        var session = row(["a", "b", "c"], widths: [.pinned(400), .flexible(2), .flexible(4)])
        session.add("n", at: .init(target: "a", side: .right))
        XCTAssertEqual(session.ids, ["a", "n", "b", "c"])
        XCTAssertEqual(session.columns.map(\.width),
                       [.pinned(400), .flexible(3), .flexible(2), .flexible(4)])
    }

    /// Above and below are a new tile in the column, taking half the one they opened beside.
    func testAboveAndBelowOpenATileInTheColumn() {
        var session = masterAndStack("m", [("a", .flexible(300)), ("b", .flexible(100))])
        session.add("n", at: .init(target: "a", side: .above))
        XCTAssertEqual(session.columns[1].tiles.map(\.shown), ["n", "a", "b"])
        XCTAssertEqual(session.columns[1].tiles.map(\.height),
                       [.flexible(150), .flexible(150), .flexible(100)])
    }

    func testWithNowhereSaidItGoesOnTheEnd() {
        var session = row(["a", "b", "c"])
        session.add("d", at: nil)
        XCTAssertEqual(session.ids.last, "d")
    }

    /// **The chosen place is marked, not made**: nothing moves aside while you choose, the mark is the
    /// one a drag uses, and the card still lands there.
    func testAChosenPlaceIsMarkedOnTheTilesAsTheyStand() {
        var session = row(["a", "b"])
        let before = session.layout.frames
        session.preselection = .init(target: "b", side: .right)

        XCTAssertEqual(session.layout.frames, before, "nothing moves until the card arrives")
        XCTAssertEqual(session.layout.visible, ["a", "b"])
        let place = try! XCTUnwrap(session.placementFrame)
        XCTAssertEqual(place, session.dropMark(.beside(.right), on: "b"), "the drag's mark")
        XCTAssertEqual(place.maxX, before["b"]!.maxX, accuracy: 0.5, "down b's right-hand side")
        XCTAssertFalse(session.dividers.isEmpty, "the boundaries stay live")

        session.add("n", at: session.preselection)
        XCTAssertGreaterThan(session.layout.frames["n"]!.minX, session.layout.frames["b"]!.minX,
                             "and the card lands where the mark was")
    }

    /// Where you were about to put something is not part of what you built.
    func testTheChosenPlaceIsNotSaved() {
        var session = row(["a", "b"])
        let saved = session.memory
        session.preselection = .init(target: "b", side: .below)
        XCTAssertEqual(session.memory, saved)
    }

    func testTakingOutItsTileForgetsThePlace() {
        var session = row(["a", "b"])
        session.preselection = .init(target: "b", side: .right)
        session.remove("b")
        XCTAssertNil(session.preselection)
        XCTAssertNil(session.placementFrame)
    }

    // MARK: The keys

    /// ⌥⇧← and →: into the next column, level with where it was.
    func testMovingAcrossLandsLevelWithWhereItWas() {
        var session = masterAndStack("m", [("a", .even), ("b", .even), ("c", .even)])
        XCTAssertTrue(session.moveAcross("c", by: -1))
        XCTAssertEqual(session.columns[0].tiles.map(\.shown), ["m", "c"], "from the bottom, below")

        var other = masterAndStack("m", [("a", .even), ("b", .even), ("c", .even)])
        other.moveAcross("a", by: -1)
        XCTAssertEqual(other.columns[0].tiles.map(\.shown), ["a", "m"], "from the top, above")
    }

    /// Past the last column is a column of its own.
    func testMovingPastTheEdgeOpensAColumn() {
        var session = masterAndStack("m", [("a", .even), ("b", .even)])
        XCTAssertTrue(session.moveAcross("b", by: 1))
        XCTAssertEqual(session.columns.map { $0.tiles.map(\.shown) }, [["m"], ["a"], ["b"]])
    }

    /// A tile alone in its column at the edge has nowhere to go, and says so.
    func testATileAloneAtTheEdgeStaysWhereItIs() {
        var session = row(["a", "b"])
        let before = session
        XCTAssertFalse(session.moveAcross("b", by: 1))
        XCTAssertFalse(session.moveAcross("a", by: -1))
        XCTAssertEqual(session, before)
    }

    /// Moving the only tile out of a column takes the column with it.
    func testMovingIntoTheNextColumnEmptiesItsOwn() {
        var session = row(["a", "b", "c"])
        session.moveAcross("b", by: 1)
        XCTAssertEqual(session.columns.map { $0.tiles.map(\.shown) }, [["a"], ["b", "c"]])
    }

    /// ⌥⇧↑ and ↓: change places with the neighbour, the height going with the tile.
    func testMovingWithinChangesPlacesWithTheNeighbour() {
        var session = masterAndStack("m", [("a", .flexible(100)), ("b", .flexible(200))])
        XCTAssertTrue(session.moveWithin("a", by: 1))
        XCTAssertEqual(session.columns[1].tiles.map(\.shown), ["b", "a"])
        XCTAssertEqual(session.columns[1].tiles.map(\.height), [.flexible(200), .flexible(100)])
        XCTAssertFalse(session.moveWithin("a", by: 1), "already at the bottom")
    }

    /// ⌥=: the column wider, and the room taken from the others in proportion.
    func testGrowingTakesFromTheOthers() {
        var session = row(["a", "b", "c"])
        let before = session.lengths(of: .columns)
        XCTAssertTrue(session.grow("a", vertically: false, by: 100))
        let after = session.lengths(of: .columns)
        XCTAssertEqual(after[0], before[0] + 100, accuracy: 0.5)
        XCTAssertEqual(after[1], before[1] - 50, accuracy: 0.5)
        XCTAssertEqual(after[2], before[2] - 50, accuracy: 0.5)
    }

    /// A pin that isn't the one being sized holds still, and the room comes from the rest.
    func testGrowingLeavesAPinAlone() {
        var session = row(["a", "b", "c"], widths: [.even, .even, .pinned(300)])
        let before = session.lengths(of: .columns)
        session.grow("a", vertically: false, by: 100)
        XCTAssertEqual(session.columns[2].width, .pinned(300))
        XCTAssertEqual(session.lengths(of: .columns)[1], before[1] - 100, accuracy: 0.5)
    }

    func testGrowingStopsShortOfNothingLeft() {
        var session = row(["a", "b"])
        let before = session
        XCTAssertFalse(session.grow("a", vertically: false, by: 5000))
        XCTAssertEqual(session, before)
    }

    /// ⌥⇧=: the tile taller, down its own column.
    func testGrowingATileDownItsColumn() {
        var session = masterAndStack("m", [("a", .even), ("b", .even)])
        let before = session.lengths(of: .tiles(inColumn: 1))
        XCTAssertTrue(session.grow("a", vertically: true, by: 50))
        XCTAssertEqual(session.lengths(of: .tiles(inColumn: 1))[0], before[0] + 50, accuracy: 0.5)
    }

    /// ⌥0: everything sharing equally again, pins included.
    func testBalancingEvensEverything() {
        var session = masterAndStack("m", [("a", .pinned(120)), ("b", .flexible(3))])
        session.balance()
        XCTAssertEqual(session.columns.map(\.width), [.even, .even])
        XCTAssertEqual(session.columns[1].tiles.map(\.height), [.even, .even])
    }

    // MARK: Dropping a tile

    /// Near an edge is a place beside it; the middle — the largest target — is a swap.
    func testTheEdgesOfATileArePlacesAndTheMiddleIsASwap() {
        let frame = CanvasRect(x: 0, y: 0, width: 400, height: 300)
        func at(_ x: Double, _ y: Double) -> CanvasTileSession.Drop {
            CanvasTileSession.drop(at: CanvasPoint(x: x, y: y), on: frame)
        }
        XCTAssertEqual(at(10, 150), .beside(.left))
        XCTAssertEqual(at(390, 150), .beside(.right))
        XCTAssertEqual(at(200, 50), .beside(.above))
        XCTAssertEqual(at(200, 10), .beside(.tab), "the band across the top is the tile's tabs")
        XCTAssertEqual(at(200, 290), .beside(.below))
        XCTAssertEqual(at(200, 150), .swap)
    }

    /// Dropped beside a tile, it comes out of its place — taking an emptied column with it — and goes
    /// there.
    func testDroppingBesideMovesTheTileOutOfItsPlace() {
        var session = row(["a", "b", "c"])
        session.drop("a", on: "c", .beside(.below))
        XCTAssertEqual(session.columns.map { $0.tiles.map(\.shown) }, [["b"], ["c", "a"]])
    }

    /// Dropped in the middle, the two change places and the sizes stay put.
    func testDroppingInTheMiddleSwaps() {
        var session = row(["a", "b", "c"], widths: [.pinned(300), .even, .even])
        session.drop("a", on: "c", .swap)
        XCTAssertEqual(session.ids, ["c", "b", "a"])
        XCTAssertEqual(session.columns.map(\.width), [.pinned(300), .even, .even])
    }

    /// **Nothing moves until you let go**: a drop is marked on the tiles as they stand — a swap as the
    /// tile, a tab as its top band, a tile below as the half that would give way, and a new column as
    /// the side of the whole column, however many tiles the column holds.
    func testADropIsMarkedOnTheTilesAsTheyStand() {
        let session = masterAndStack("m", [("a", .even), ("b", .even)])
        let a = session.tileFrames["a"]!, b = session.tileFrames["b"]!
        XCTAssertEqual(session.dropMark(.swap, on: "a"), a)
        XCTAssertEqual(session.dropMark(.beside(.tab), on: "a"), CanvasTileSession.tabBand(of: a))
        XCTAssertEqual(session.dropMark(.beside(.below), on: "a")!.minY, a.midY, accuracy: 0.001)
        let right = session.dropMark(.beside(.right), on: "a")!
        XCTAssertEqual(right.minY, a.minY, accuracy: 0.001)
        XCTAssertEqual(right.maxY, b.maxY, accuracy: 0.001, "the whole column's side, not the tile's")
        XCTAssertEqual(right.maxX, a.maxX, accuracy: 0.001)
    }

    func testDroppingOnItselfDoesNothing() {
        var session = row(["a", "b"])
        let before = session
        session.drop("a", on: "a", .beside(.right))
        XCTAssertEqual(session, before)
    }

    private func pairs(_ tiles: [CanvasRect]) -> [(CanvasRect, CanvasRect)] {
        var out: [(CanvasRect, CanvasRect)] = []
        for i in tiles.indices { for j in tiles.indices where j > i { out.append((tiles[i], tiles[j])) } }
        return out
    }
}

// MARK: - What a workspace is made of

/// The tiling rules that lived as computed properties on `CanvasBoardView` and could not be tested there,
/// because nothing in this bundle can build a board. Each case below is a rule the code's own comments
/// describe having got wrong once.
final class CanvasTilingPlanTests: XCTestCase {

    private func card(_ id: String, x: Double = 0, y: Double = 0, width: Double = 100) -> CanvasNode {
        CanvasNode(id: id, content: .text(id), frame: CanvasRect(x: x, y: y, width: width, height: 100))
    }

    private func frame(_ id: String, x: Double, y: Double, width: Double, height: Double) -> CanvasNode {
        CanvasNode(id: id, content: .group(label: id, background: nil, backgroundStyle: nil),
                   frame: CanvasRect(x: x, y: y, width: width, height: height))
    }

    // MARK: Targets

    /// **Nothing selected is nothing to make.** It used to be everything on screen, and a workspace made
    /// out of wherever the board was scrolled is one you then have to delete.
    func testNothingSelectedIsNothingToTile() {
        let doc = CanvasDocument(nodes: [card("a"), card("b")])
        XCTAssertTrue(CanvasTiling.targets(of: [], in: doc).isEmpty)
    }

    /// A selected frame means the cards in it — by centre, so one poking out by a corner still counts —
    /// and never the frame itself.
    func testASelectedFrameMeansTheCardsWhoseCentresAreInsideIt() {
        let doc = CanvasDocument(nodes: [
            frame("f", x: 0, y: 0, width: 300, height: 300),
            card("inside", x: 50, y: 50),
            card("pokingOut", x: 220, y: 220),       // centre 270,270: still inside
            card("outside", x: 400, y: 400),
        ])
        XCTAssertEqual(CanvasTiling.targets(of: ["f"], in: doc), ["inside", "pokingOut"])
    }

    func testSelectedCardsAndFramesCombine() {
        let doc = CanvasDocument(nodes: [frame("f", x: 0, y: 0, width: 200, height: 200),
                                         card("inFrame", x: 10, y: 10), card("loose", x: 900, y: 900)])
        XCTAssertEqual(CanvasTiling.targets(of: ["f", "loose"], in: doc), ["inFrame", "loose"])
    }

    // MARK: Plans

    func testOnlyFramesIsNoPlan() {
        let doc = CanvasDocument(nodes: [frame("f", x: 0, y: 0, width: 10, height: 10)])
        XCTAssertNil(CanvasTiling.plan(for: ["f"], in: doc, remembered: nil, arrangement: nil,
                                       savedArrangement: nil, savedMasterFraction: 0.5))
    }

    /// **The same cards as last time get last time's arrangement** — matched on the set, since the order
    /// is one of the things being remembered.
    func testTheSameCardsInAnyOrderGetTheRememberedTiling() throws {
        let doc = CanvasDocument(nodes: [card("a"), card("b"), card("c")])
        let last = CanvasViewState.Tiling(ids: ["c", "a", "b"], arrangement: .masterStack,
                                          masterFraction: 0.7, sizes: nil)
        let plan = try XCTUnwrap(CanvasTiling.plan(for: ["a", "b", "c"], in: doc, remembered: last,
                                                   arrangement: nil, savedArrangement: .grid,
                                                   savedMasterFraction: 0.5))
        XCTAssertEqual(plan.ids, ["c", "a", "b"])
        XCTAssertEqual(plan.arrangement, .masterStack)
        XCTAssertEqual(plan.masterFraction, 0.7)
    }

    /// **Asking for an arrangement deals the tiles out again**: the order is kept, the sizes are not.
    func testAskingForAnArrangementKeepsTheOrderButNotTheSizes() throws {
        let doc = CanvasDocument(nodes: [card("a"), card("b")])
        var last = CanvasViewState.Tiling(ids: ["b", "a"], arrangement: .grid, masterFraction: 0.6, sizes: nil)
        last.sizes = nil
        let plan = try XCTUnwrap(CanvasTiling.plan(for: ["a", "b"], in: doc, remembered: last,
                                                   arrangement: .masterStack, savedArrangement: nil,
                                                   savedMasterFraction: 0.5))
        XCTAssertEqual(plan.ids, ["b", "a"], "the order is where the cards were")
        XCTAssertEqual(plan.arrangement, .masterStack)
        XCTAssertNil(plan.sizes)
    }

    func testADifferentSetOfCardsIsNotMistakenForTheRememberedOne() throws {
        let doc = CanvasDocument(nodes: [card("a"), card("b"), card("c")])
        let last = CanvasViewState.Tiling(ids: ["a", "b"], arrangement: .masterStack, masterFraction: 0.7, sizes: nil)
        let plan = try XCTUnwrap(CanvasTiling.plan(for: ["a", "b", "c"], in: doc, remembered: last,
                                                   arrangement: nil, savedArrangement: nil,
                                                   savedMasterFraction: 0.5))
        XCTAssertEqual(plan.arrangement, .grid, "three cards, nothing saved: the preferred arrangement")
        XCTAssertEqual(plan.masterFraction, 0.5)
    }

    func testWithNothingRememberedTheSavedArrangementBeatsThePreferredOne() throws {
        let doc = CanvasDocument(nodes: (1...5).map { card("\($0)", x: Double($0) * 200) })
        let ids = Set(doc.nodes.map(\.id))
        let saved = try XCTUnwrap(CanvasTiling.plan(for: ids, in: doc, remembered: nil, arrangement: nil,
                                                    savedArrangement: .grid, savedMasterFraction: 0.5))
        XCTAssertEqual(saved.arrangement, .grid)
        let preferred = try XCTUnwrap(CanvasTiling.plan(for: ids, in: doc, remembered: nil, arrangement: nil,
                                                        savedArrangement: nil, savedMasterFraction: 0.5))
        XCTAssertEqual(preferred.arrangement, .masterStack, "four or more cards prefer a master column")
    }

    func testPreferredArrangementTurnsOverAtFourCards() {
        XCTAssertEqual(CanvasTiling.preferredArrangement(for: 3), .grid)
        XCTAssertEqual(CanvasTiling.preferredArrangement(for: 4), .masterStack)
    }

    // MARK: Summary

    func testTheSummaryCountsCardsAndNotFrames() {
        let doc = CanvasDocument(nodes: [card("a"), card("b"), card("c"),
                                         frame("f", x: 0, y: 0, width: 10, height: 10)])
        XCTAssertEqual(CanvasTiling.summary(cardsInTiling: 2, of: doc).long, "2 of 3 cards")
        XCTAssertEqual(CanvasTiling.summary(cardsInTiling: 2, of: doc).short, "2/3")
        XCTAssertEqual(CanvasTiling.summary(cardsInTiling: 1, of: doc).long, "1 card of 3")
    }

    /// The precedence both a plan and a fresh tiling deal from, in its one place.
    func testTheArrangementIsAskedThenRememberedThenSavedThenPreferred() {
        typealias T = CanvasTiling
        XCTAssertEqual(T.arrangement(asked: .grid, remembered: .masterStack, saved: .masterStack, cardCount: 9), .grid)
        XCTAssertEqual(T.arrangement(asked: nil, remembered: .grid, saved: .masterStack, cardCount: 9), .grid)
        XCTAssertEqual(T.arrangement(asked: nil, remembered: nil, saved: .grid, cardCount: 9), .grid)
        XCTAssertEqual(T.arrangement(asked: nil, remembered: nil, saved: nil, cardCount: 9), .masterStack)
    }
}
