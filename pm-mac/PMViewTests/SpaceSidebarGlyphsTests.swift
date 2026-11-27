import XCTest
@testable import PMViewTests

/// The sidebar's icon column: a site's hue, and a layout's drawing. See `SpaceSidebarGlyphs.swift`.
final class SpaceSidebarGlyphsTests: XCTestCase {
    private typealias Tiling = CanvasViewState.Tiling

    // MARK: Hue

    func testHueIsStableAndIgnoresCaseAndWww() {
        // FNV-1a, so a site is the same colour on every launch, not just within one.
        XCTAssertEqual(SidebarHue.index(for: "github.com"), SidebarHue.index(for: "github.com"))
        XCTAssertEqual(SidebarHue.index(host: "GitHub.com", title: "x"), SidebarHue.index(host: "github.com", title: "y"))
        XCTAssertEqual(SidebarHue.index(host: "www.github.com", title: ""), SidebarHue.index(host: "github.com", title: ""))
        XCTAssertEqual(SidebarHue.index(for: ""), 2_166_136_261 % 8)
    }

    func testHueFallsBackToTitleAndStaysInPalette() {
        XCTAssertEqual(SidebarHue.index(host: nil, title: "Design Studio"), SidebarHue.index(for: "Design Studio"))
        XCTAssertEqual(SidebarHue.index(host: "", title: "Plans"), SidebarHue.index(for: "Plans"))
        for name in ["a", "b", "linear.app", "figma.com", "localhost", "Overview"] {
            XCTAssertTrue(SidebarHue.palette.indices.contains(SidebarHue.index(for: name)))
        }
    }

    func testHuesSpreadAcrossThePalette() {
        let hosts = (0..<64).map { "site\($0).example.com" }
        XCTAssertGreaterThanOrEqual(Set(hosts.map { SidebarHue.index(for: $0) }).count, 6)
    }

    // MARK: Layout shape

    private func tint(_ id: String) -> LayoutShape.Tint { id.hasPrefix("w") ? .hue(1) : .plain }

    func testNoTilingIsOnePlainTile() {
        XCTAssertEqual(LayoutShape(nil, tint: tint), .empty)
    }

    func testColumnsAreDrawnAsSavedWithTheirShares() {
        let tiling = Tiling(ids: ["a", "w", "b"], arrangement: .grid, masterFraction: 0.5, sizes: nil, columns: [
            .init(width: .flexible(2), [.init("a")]),
            .init(width: .pinned(300), [.init("w"), .init(["b", "c"], showing: 1)]),
        ])
        let shape = LayoutShape(tiling, tint: tint)
        XCTAssertEqual(shape.columns.map(\.share), [2, 1])
        XCTAssertEqual(shape.columns.map(\.tiles), [[.plain], [.hue(1), .plain]])
    }

    func testTooManyColumnsOrTilesAreCapped() {
        let column = CanvasTiling.Column([.init("a"), .init("b"), .init("c"), .init("d")])
        let tiling = Tiling(ids: [], arrangement: .grid, masterFraction: 0.5, sizes: nil,
                            columns: Array(repeating: column, count: 6))
        let shape = LayoutShape(tiling, tint: tint)
        XCTAssertEqual(shape.columns.count, LayoutShape.maxColumns)
        XCTAssertTrue(shape.columns.allSatisfy { $0.tiles.count == LayoutShape.maxTiles })
    }

    func testEmptyColumnsAreDropped() {
        let tiling = Tiling(ids: [], arrangement: .grid, masterFraction: 0.5, sizes: nil,
                            columns: [.init([]), .init([.init("a")])])
        XCTAssertEqual(LayoutShape(tiling, tint: tint).columns.count, 1)
        let none = Tiling(ids: [], arrangement: .grid, masterFraction: 0.5, sizes: nil, columns: [.init([])])
        XCTAssertEqual(LayoutShape(none, tint: tint), .empty)
    }

    func testOldGridTilingIsRebuiltNearSquare() {
        func shape(_ n: Int) -> [Int] {
            let tiling = Tiling(ids: (0..<n).map { "c\($0)" }, arrangement: .grid, masterFraction: 0.5,
                                sizes: nil, columns: nil)
            return LayoutShape(tiling, tint: tint).columns.map(\.tiles.count)
        }
        XCTAssertEqual(shape(1), [1])
        XCTAssertEqual(shape(2), [1, 1])
        XCTAssertEqual(shape(4), [2, 2])
        XCTAssertEqual(shape(6), [2, 2, 2])
    }

    func testOldMasterStackIsMasterAndStack() {
        let tiling = Tiling(ids: ["a", "w", "b"], arrangement: .masterStack, masterFraction: 0.6,
                            sizes: nil, columns: nil)
        let shape = LayoutShape(tiling, tint: tint)
        XCTAssertEqual(shape.columns.map(\.tiles), [[.plain], [.hue(1), .plain]])
        XCTAssertEqual(shape.columns[0].share, 0.6, accuracy: 0.0001)
        XCTAssertEqual(shape.columns[1].share, 0.4, accuracy: 0.0001)
    }
}
