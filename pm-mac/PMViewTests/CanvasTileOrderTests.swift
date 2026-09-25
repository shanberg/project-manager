import XCTest
import PmLib
@testable import PMViewTests

/// **The order a workspace reads in, and why adding one tile used to change it for the others.**
///
/// A board's cards are a scatter with no rows in them, so `CanvasTiling.order` invents rows: a band as
/// tall as the median card, measured from each card's middle. That is the right rule there and it is
/// what makes a tiling a *canvas's* tiling — the cards were placed on purpose and the arrangement keeps
/// what the board knew.
///
/// `CanvasTileSession.readingOrder` used to ask the same question of tiles, and tiles are not a
/// scatter: they are columns, laid out exactly, so their rows are a fact rather than a guess. Two
/// things came of treating them as a scatter, and this file pins both. A tall tile's *middle* is level
/// with nothing in particular, so it banded with whatever sat across its midpoint instead of with the
/// tiles beside it at the top. And the band was taken from the median of the heights, so adding a tile
/// changed what counted as a row — for tiles that had not moved at all. That is canvas-backlog.md 18.
///
/// The order matters in three places: the numbers ⌃1…9 go to, what Grid and Master and Stack deal out
/// when you run them again (`CanvasBoardView.setArrangement`), and what an older build is handed to lay
/// out its own way (`memory`).
final class CanvasTileOrderTests: XCTestCase {

    /// Landscape, like the window a workspace actually fills.
    private let wide = CanvasRect(x: 0, y: 0, width: 1400, height: 800)

    private func grid(_ n: Int, in area: CanvasRect? = nil) -> CanvasTileSession {
        let area = area ?? wide
        return CanvasTileSession(columns: CanvasTiling.columns(.grid,
                                                               of: (0..<n).map { CanvasTiling.Tile("t\($0)") },
                                                               in: area, masterFraction: 0.6),
                                 area: area, restoreVisible: area)
    }

    private func order(_ session: CanvasTileSession) -> [String] { session.readingOrder.map(\.shown) }

    // MARK: Reading a grid

    /// **Four cards in a wide window are three columns, the first holding two** — and the one in the
    /// bottom left is the last thing you read, not the second.
    ///
    /// The case the old rule was worst at, and it needed nothing added to show it: two of the three
    /// columns hold a single full-height tile, so the median height was a whole window and the band was
    /// most of one. Every tile fell in a single row and the order came out sorted by x alone, which
    /// read the bottom-left tile before both of the tall ones: t0, t3, t1, t2.
    func testAGridReadsItsTopRowBeforeItsBottomRow() {
        let session = grid(4)
        XCTAssertEqual(session.columns.map { $0.tiles.map(\.shown) }, [["t0", "t3"], ["t1"], ["t2"]],
                       "the shape this is about has changed")
        XCTAssertEqual(order(session), ["t0", "t1", "t2", "t3"])
    }

    /// Every grid from two to seven reads the way it was dealt — a row at a time, which is what
    /// `CanvasTiling.columns` deals and so what the cards' own order on the board survives as.
    func testAFreshGridReadsInTheOrderItWasDealt() {
        for n in 2...7 {
            XCTAssertEqual(order(grid(n)), (0..<n).map { "t\($0)" }, "a grid of \(n)")
        }
    }

    /// A master and its stack: the master, then down the stack.
    func testAMasterReadsBeforeItsStack() {
        let tiles = (0..<4).map { CanvasTiling.Tile("t\($0)") }
        let session = CanvasTileSession(columns: CanvasTiling.columns(.masterStack, of: tiles, in: wide,
                                                                      masterFraction: 0.6),
                                        area: wide, restoreVisible: wide)
        XCTAssertEqual(order(session), ["t0", "t1", "t2", "t3"])
    }

    // MARK: Backlog 18 — adding one tile reordered the others

    /// **The regression.** Three cards are two columns — one holding two tiles, one holding a tall one
    /// — and a card added to the right of the top-left tile opens a column between them. Nothing that
    /// was there changes places with anything: t0 is still top left, t2 still under it, t1 still on the
    /// far right.
    ///
    /// The old rule said otherwise. The new tile is full height, which moved the median height from
    /// half a window to a whole one, which widened the band until all four tiles counted as one row —
    /// and one row sorted by x reads the two tiles of the first column before anything else. t1 and t2
    /// changed places without either of them moving.
    func testAddingAColumnDoesNotReorderTheTilesAlreadyThere() {
        let before = grid(3)
        XCTAssertEqual(order(before), ["t0", "t1", "t2"])
        var after = before
        after.add("NEW", at: after.automaticPlacement(beside: "t0"))
        XCTAssertEqual(after.columns.map { $0.tiles.map(\.shown) }, [["t0", "t2"], ["NEW"], ["t1"]],
                       "the card did not open a column between them after all")
        XCTAssertEqual(order(after), ["t0", "NEW", "t1", "t2"])
        XCTAssertEqual(order(after).filter { $0 != "NEW" }, order(before),
                       "the tiles that were there have changed places, and none of them moved")
    }

    /// Pulling a tab out is the same act — a card that was sharing a tile becomes one of its own — so
    /// it has the same thing to prove.
    func testPullingATabOutDoesNotReorderTheTilesAlreadyThere() {
        var before = grid(3)
        let at = before.position(of: "t0")!
        before.columns[at.column].tiles[at.tile].cards.append("TAB")
        var after = before
        after.pull("TAB", to: .init(target: "t0", side: .right))
        XCTAssertEqual(order(after).filter { $0 != "TAB" }, order(before),
                       "the tiles that were there have changed places")
    }

    /// **The general statement, over every grid and master-and-stack from two to seven tiles and every
    /// tile a card could arrive beside: a tile that did not move cannot change places with another
    /// tile that did not move.**
    ///
    /// It holds because the order is lexicographic on a tile's own top-left corner and reads nothing
    /// about the other tiles — which is the whole of the fix. The sweep is here because the failure it
    /// replaces was not a wrong answer in one shape but a rule whose answer depended on the population,
    /// and one example would not have said that.
    func testATileThatDidNotMoveKeepsItsPlaceInTheOrder() {
        for arrangement in CanvasTiling.Arrangement.allCases {
            for n in 2...7 {
                let tiles = (0..<n).map { CanvasTiling.Tile("t\($0)") }
                let before = CanvasTileSession(columns: CanvasTiling.columns(arrangement, of: tiles,
                                                                            in: wide, masterFraction: 0.6),
                                               area: wide, restoreVisible: wide)
                for target in order(before) {
                    var after = before
                    after.add("NEW", at: after.automaticPlacement(beside: target))
                    let was = before.arrangedFrames, now = after.arrangedFrames
                    let still = Set(was.keys).filter { now[$0] == was[$0] }
                    XCTAssertEqual(order(before).filter(still.contains),
                                   order(after).filter(still.contains),
                                   "\(arrangement) of \(n), a card added beside \(target): tiles that "
                                       + "stayed exactly where they were have changed places")
                }
            }
        }
    }

    /// **Where a wrong order moves real tiles**, rather than only renumbering them: running Grid or
    /// Master and Stack again deals `readingOrder` out (`CanvasBoardView.setArrangement`), so the card
    /// the order puts first becomes the master. Under the old rule a master and stack that nobody had
    /// touched read its first stack tile before its master — the master is full height, so its middle
    /// sat level with the middle of the stack rather than with the top of it — and running Master and
    /// Stack on it promoted the wrong card.
    func testDealingAMasterAndStackAgainKeepsTheSameMaster() {
        let tiles = (0..<4).map { CanvasTiling.Tile("t\($0)") }
        let columns = CanvasTiling.columns(.masterStack, of: tiles, in: wide, masterFraction: 0.6)
        let session = CanvasTileSession(columns: columns, area: wide, restoreVisible: wide)
        let again = CanvasTiling.columns(.masterStack, of: session.readingOrder, in: wide,
                                         masterFraction: 0.6)
        XCTAssertEqual(again, columns, "the arrangement moved when it was dealt again unchanged")
        XCTAssertEqual(again.first?.tiles.first?.shown, "t0")
    }

    /// **Arrange's tick.** On for the arrangement just dealt, off for the other, and off for both once
    /// a column has been resized.
    func testTheTickFollowsTheArrangementUntilATileIsResized() {
        for arrangement in CanvasTiling.Arrangement.allCases {
            let other: CanvasTiling.Arrangement = arrangement == .grid ? .masterStack : .grid
            var session = CanvasTileSession(columns: CanvasTiling.columns(arrangement,
                                                                          of: (0..<4).map { CanvasTiling.Tile("t\($0)") },
                                                                          in: wide, masterFraction: 0.6),
                                            area: wide, restoreVisible: wide)
            XCTAssertTrue(session.isArranged(as: arrangement, masterFraction: 0.6), "\(arrangement)")
            XCTAssertFalse(session.isArranged(as: other, masterFraction: 0.6), "\(arrangement) as \(other)")
            session.columns[0].width = .pinned(123)
            XCTAssertFalse(session.isArranged(as: arrangement, masterFraction: 0.6), "\(arrangement), resized")
        }
    }

    /// The same, for a grid: dealing an untouched grid again is a no-op.
    func testDealingAGridAgainLeavesItAlone() {
        for n in 2...7 {
            let columns = CanvasTiling.columns(.grid, of: (0..<n).map { CanvasTiling.Tile("t\($0)") },
                                               in: wide, masterFraction: 0.6)
            let session = CanvasTileSession(columns: columns, area: wide, restoreVisible: wide)
            XCTAssertEqual(CanvasTiling.columns(.grid, of: session.readingOrder, in: wide,
                                                masterFraction: 0.6),
                           columns, "a grid of \(n) moved when it was dealt again unchanged")
        }
    }

    /// What the reordering was visible *as*: the numbers on the cards while you pick them (⌥B), and the
    /// ⌃1…9 that go to a tile. They are the order, one-based, and a tab wears its tile's number.
    func testTheNumbersOnTheCardsAreTheOrder() {
        var session = grid(4)
        let at = session.position(of: "t1")!
        session.columns[at.column].tiles[at.tile].cards.append("TAB")
        XCTAssertEqual(session.tileNumbers,
                       ["t0": 1, "t1": 2, "TAB": 2, "t2": 3, "t3": 4])
    }
}
