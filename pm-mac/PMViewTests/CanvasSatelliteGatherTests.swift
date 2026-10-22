import AppKit
import XCTest

/// Gather by where the windows are: satellites read back into columns, left to right and top to bottom.
/// Screen coordinates, so a higher window has the larger y.
final class CanvasSatelliteGatherTests: XCTestCase {
    private func tile(_ id: String) -> CanvasTiling.Tile { CanvasTiling.Tile([id]) }
    private func ids(_ columns: [CanvasTiling.Column]) -> [[String]] {
        columns.map { $0.tiles.flatMap(\.cards) }
    }

    /// A workspace popped out and left where it opened gathers back into the tiling it came from: a full-height
    /// column, a column of two, a full-height column.
    func testUntouchedPopOutGathersIntoTheSameTiling() {
        let columns = CanvasSatelliteGather.columns(from: [
            (tile("tasks"), NSRect(x: 600, y: 100, width: 200, height: 500)),
            (tile("cal"), NSRect(x: 300, y: 100, width: 300, height: 200)),
            (tile("plan"), NSRect(x: 0, y: 100, width: 300, height: 500)),
            (tile("huddle"), NSRect(x: 300, y: 300, width: 300, height: 300)),
        ])
        XCTAssertEqual(ids(columns), [["plan"], ["huddle", "cal"], ["tasks"]])
        XCTAssertEqual(columns[0].width, .flexible(0.375))
        XCTAssertEqual(columns[1].tiles[0].height, .flexible(0.6))
    }

    /// Windows moved side by side become columns; windows moved onto one another's column become tiles.
    func testRearrangedWindowsBecomeTheirArrangement() {
        let columns = CanvasSatelliteGather.columns(from: [
            (tile("a"), NSRect(x: 0, y: 400, width: 400, height: 300)),
            (tile("b"), NSRect(x: 40, y: 0, width: 380, height: 300)),
            (tile("c"), NSRect(x: 900, y: 200, width: 300, height: 300)),
        ])
        XCTAssertEqual(ids(columns), [["a", "b"], ["c"]])
    }

    /// Overlapping by less than half the narrower window is side by side, not stacked.
    func testASmallOverlapIsSideBySide() {
        let columns = CanvasSatelliteGather.columns(from: [
            (tile("a"), NSRect(x: 0, y: 0, width: 400, height: 300)),
            (tile("b"), NSRect(x: 300, y: 0, width: 400, height: 300)),
        ])
        XCTAssertEqual(ids(columns), [["a"], ["b"]])
    }

    /// A window of tabs comes back as one tile holding them all, showing the tab it was showing.
    func testAWindowOfTabsIsOneTile() {
        let columns = CanvasSatelliteGather.columns(from: [
            (CanvasTiling.Tile(["x", "y"], showing: 1), NSRect(x: 0, y: 0, width: 400, height: 300)),
        ])
        XCTAssertEqual(columns.count, 1)
        XCTAssertEqual(columns[0].tiles.first?.cards, ["x", "y"])
        XCTAssertEqual(columns[0].tiles.first?.showing, 1)
    }

    func testNothingOutIsNoColumns() {
        XCTAssertTrue(CanvasSatelliteGather.columns(from: []).isEmpty)
        XCTAssertTrue(CanvasSatelliteGather.columns(from: [(CanvasTiling.Tile([]), .zero)]).isEmpty)
    }
}
