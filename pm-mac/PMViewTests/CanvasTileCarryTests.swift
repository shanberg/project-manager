import XCTest
import PmLib
@testable import PMViewTests

/// A tile drag's pickup curve, the bars that mark a place beside a tile, and the curve the mark glides
/// on. See `CanvasTileCarry` and docs/canvas-workspaces.md §7k.
@MainActor
final class CanvasTileCarryTests: XCTestCase {
    private let square = CanvasRect(x: 0, y: 0, width: 800, height: 800)

    /// Two columns of two: "0" over "1" on the left, "2" over "3" on the right — or however the grid
    /// deals them; the tests ask the session where each tile is rather than assuming.
    private func grid() -> CanvasTileSession {
        let tiles = (0..<4).map { CanvasTiling.Tile(String($0)) }
        return CanvasTileSession(columns: CanvasTiling.columns(.grid, of: tiles, in: square,
                                                               masterFraction: 0.6, sizes: [:]),
                                 area: square, restoreVisible: square)
    }

    private func tile(in session: CanvasTileSession, column: Int, row: Int) -> String {
        session.columns[column].tiles[row].shown
    }

    // MARK: The pickup

    func testATileComesOutAtFortyEightPointsHavingFollowedAThirdOfThePull() {
        let short = CanvasTileCarry.lean(dx: 47, dy: 0)
        XCTAssertFalse(short.free)
        let out = CanvasTileCarry.lean(dx: 48, dy: 0)
        XCTAssertTrue(out.free)
        // niri's band at its threshold: (1 - 1 / (1 / 0.5 + 1)) × 0.5.
        XCTAssertEqual(out.fraction, 1.0 / 3, accuracy: 1e-9)
        // Diagonal pulls count by distance, not by axis.
        XCTAssertTrue(CanvasTileCarry.lean(dx: 34, dy: 34).free)
        XCTAssertFalse(CanvasTileCarry.lean(dx: 33, dy: 33).free)
    }

    func testTheLeanGrowsWithThePullAndNeverReachesHalf() {
        var last = -1.0
        for step in 0...400 {
            let fraction = CanvasTileCarry.lean(dx: Double(step), dy: 0).fraction
            XCTAssertGreaterThanOrEqual(fraction, last)
            XCTAssertLessThan(fraction, CanvasTileCarry.follows)
            last = fraction
        }
        XCTAssertEqual(CanvasTileCarry.lean(dx: 0, dy: 0).fraction, 0)
    }

    // MARK: The curve the mark glides on

    func testSettledRunsFromNothingToAllWithoutPassingIt() {
        XCTAssertEqual(Motion.settled(0), 0)
        XCTAssertEqual(Motion.settled(1), 1)
        var last = 0.0
        for step in 1...200 {
            let value = Motion.settled(Double(step) / 200)
            XCTAssertGreaterThanOrEqual(value, last - 1e-9)
            XCTAssertLessThanOrEqual(value, 1 + 1e-9)
            last = value
        }
        // Most of the travel is spent early: that is the curve's whole character.
        XCTAssertGreaterThan(Motion.settled(1.0 / 3), 0.75)
    }

    func testTheSolverMatchesKnownCurves() {
        // Linear control points give the identity; CSS `ease-in-out` is symmetric about its middle.
        XCTAssertEqual(Motion.cubic(1.0 / 3, 1.0 / 3, 2.0 / 3, 2.0 / 3, at: 0.3), 0.3, accuracy: 1e-6)
        XCTAssertEqual(Motion.cubic(0.42, 0, 0.58, 1, at: 0.5), 0.5, accuracy: 1e-6)
        XCTAssertEqual(Motion.cubic(0.42, 0, 0.58, 1, at: 0.2) + Motion.cubic(0.42, 0, 0.58, 1, at: 0.8),
                       1, accuracy: 1e-6)
    }

    // MARK: The bars

    func testANewColumnBetweenTwoIsABarCentredOnTheirGap() throws {
        let session = grid()
        try XCTSkipIf(session.columns.count != 2, "expected the square grid to be two columns")
        let right = tile(in: session, column: 1, row: 0)
        let leftColumn = session.tileFrames[tile(in: session, column: 0, row: 0)]!
        let bar = try XCTUnwrap(session.dragMark(.beside(.left), on: right, bar: 28))
        let gapMiddle = (leftColumn.maxX + session.tileFrames[right]!.minX) / 2
        XCTAssertEqual(bar.minX + bar.width / 2, gapMiddle, accuracy: 1e-9)
        XCTAssertEqual(bar.width, 28)
        // The whole column's height, since a new column is what opens.
        let column = session.columns[1].tiles.compactMap { session.tileFrames[$0.shown] }
        XCTAssertEqual(bar.minY, column.map(\.minY).min()!, accuracy: 1e-9)
        XCTAssertEqual(bar.maxY, column.map(\.maxY).max()!, accuracy: 1e-9)
        // And the same gap from the other side.
        let fromLeft = try XCTUnwrap(session.dragMark(.beside(.right), on: tile(in: session, column: 0, row: 0), bar: 28))
        XCTAssertEqual(fromLeft.minX + fromLeft.width / 2, gapMiddle, accuracy: 1e-9)
    }

    func testAtTheOuterEdgeTheBarLiesAlongTheEdgeInside() throws {
        let session = grid()
        let first = session.tileFrames[tile(in: session, column: 0, row: 0)]!
        let leftmost = try XCTUnwrap(session.dragMark(.beside(.left), on: tile(in: session, column: 0, row: 0), bar: 28))
        XCTAssertEqual(leftmost.minX, first.minX, accuracy: 1e-9)
        let lastColumn = session.columns.count - 1
        let last = session.tileFrames[tile(in: session, column: lastColumn, row: 0)]!
        let rightmost = try XCTUnwrap(session.dragMark(.beside(.right), on: tile(in: session, column: lastColumn, row: 0), bar: 28))
        XCTAssertEqual(rightmost.maxX, last.maxX, accuracy: 1e-9)
        let top = try XCTUnwrap(session.dragMark(.beside(.above), on: tile(in: session, column: 0, row: 0), bar: 28))
        XCTAssertEqual(top.minY, first.minY, accuracy: 1e-9)
        XCTAssertEqual(top.height, 28)
        XCTAssertEqual(top.width, first.width, accuracy: 1e-9)
    }

    func testATileAboveOrBelowIsABarOnTheGapBetweenTheTwoTiles() throws {
        let session = grid()
        try XCTSkipIf(session.columns[0].tiles.count < 2, "expected two tiles in the first column")
        let upper = tile(in: session, column: 0, row: 0), lower = tile(in: session, column: 0, row: 1)
        let gapMiddle = (session.tileFrames[upper]!.maxY + session.tileFrames[lower]!.minY) / 2
        let below = try XCTUnwrap(session.dragMark(.beside(.below), on: upper, bar: 28))
        let above = try XCTUnwrap(session.dragMark(.beside(.above), on: lower, bar: 28))
        XCTAssertEqual(below.minY + below.height / 2, gapMiddle, accuracy: 1e-9)
        XCTAssertEqual(above, below)
    }

    func testASwapAndATabAreMarkedAsTheyWere() {
        let session = grid()
        let target = tile(in: session, column: 0, row: 0)
        XCTAssertEqual(session.dragMark(.swap, on: target, bar: 28), session.dropMark(.swap, on: target))
        XCTAssertEqual(session.dragMark(.beside(.tab), on: target, bar: 28),
                       session.dropMark(.beside(.tab), on: target))
    }

    // MARK: The glide

    /// With no screen to tick against, a glide arrives at once — the same path Reduce Motion takes.
    func testAGlideWithNoScreenArrivesAtOnce() {
        let view = NSView()
        var changes = 0
        let glide = CanvasGlide(seconds: 0.21, on: view) { changes += 1 }
        let a = CanvasRect(x: 0, y: 0, width: 10, height: 10), b = CanvasRect(x: 100, y: 0, width: 10, height: 10)
        glide.jump(to: a)
        glide.move(to: b)
        XCTAssertEqual(glide.current, b)
        XCTAssertEqual(changes, 2)
    }
}
