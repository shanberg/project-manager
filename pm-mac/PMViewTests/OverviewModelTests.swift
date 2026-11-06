import XCTest

/// The overview's selection, finding, reordering and grid (docs/spaces.md § Overview).
final class OverviewModelTests: XCTestCase {
    private func tiles() -> [OverviewModel.Tile] {
        [.init(key: "folio", title: "Folio"),
         .init(key: "kitchen", title: "Kitchen Remodel"),
         .init(key: "space:r", title: "Reading", isSpace: true),
         .init(key: "space:m", title: "Music", isSpace: true),
         .init(key: "space:x", title: "Research", isSpace: true, isClosed: true)]
    }

    func testSelectsWhatItWasGivenElseTheFirst() {
        XCTAssertEqual(OverviewModel(tiles: tiles(), selected: "space:m").selected, "space:m")
        XCTAssertEqual(OverviewModel(tiles: tiles(), selected: "gone").selected, "folio")
        XCTAssertEqual(OverviewModel(tiles: tiles(), selected: OverviewModel.plusKey).selected, OverviewModel.plusKey)
        XCTAssertEqual(OverviewModel(tiles: [], selected: nil).selected, OverviewModel.plusKey)
    }

    func testTabWalksTilesThenThePlusAndStopsAtTheEnds() {
        var model = OverviewModel(tiles: tiles(), selected: "space:x")
        model.move(by: 1)
        XCTAssertEqual(model.selected, OverviewModel.plusKey)
        model.move(by: 1)
        XCTAssertEqual(model.selected, OverviewModel.plusKey)
        model.move(by: -10)
        XCTAssertEqual(model.selected, "folio")
    }

    func testTypingFindsPlacesAndHidesThePlus() {
        var model = OverviewModel(tiles: tiles(), selected: "folio")
        model.type("re")
        XCTAssertEqual(model.visible.map(\.key), ["kitchen", "space:r", "space:x"], "a title, or a word in it, starting with it")
        XCTAssertEqual(model.selected, "kitchen")
        XCTAssertFalse(model.showsPlus)
        model.type("a")
        XCTAssertEqual(model.visible.map(\.key), ["space:r"])
        model.deleteBackward()
        model.deleteBackward()
        model.deleteBackward()
        XCTAssertEqual(model.visible.count, 5)
        XCTAssertTrue(model.showsPlus)
    }

    func testReorderStaysWithinItsKind() {
        var model = OverviewModel(tiles: tiles(), selected: nil)
        model.move("space:x", to: "space:r", after: false)
        XCTAssertEqual(model.tiles.map(\.key), ["folio", "kitchen", "space:x", "space:r", "space:m"])
        model.move("folio", to: "kitchen", after: true)
        XCTAssertEqual(model.tiles.map(\.key), ["kitchen", "folio", "space:x", "space:r", "space:m"])
        model.move("folio", to: "space:r", after: false)
        XCTAssertEqual(model.tiles.map(\.key), ["kitchen", "folio", "space:x", "space:r", "space:m"], "a project never goes among spaces")
    }

    func testGridPutsSpacesOnANewRowPastTheDivider() {
        // 1000 wide at 210: four columns of 236.5.
        let result = OverviewLayout.grid(projects: 3, others: 3, width: 1000, minTile: 210)
        XCTAssertEqual(result.columns, 4)
        XCTAssertEqual(result.cells.count, 6)
        XCTAssertEqual(result.cells[0].width, (1000 - 3 * OverviewLayout.gap) / 4, accuracy: 0.01)
        XCTAssertEqual(result.cells[3].minX, 0, "the first space starts a row")
        let divider = try! XCTUnwrap(result.divider)
        XCTAssertLessThan(result.cells[2].maxY, divider.minY)
        XCTAssertGreaterThan(result.cells[3].minY, divider.maxY)
        XCTAssertNil(OverviewLayout.grid(projects: 0, others: 4, width: 1000).divider)
    }

    func testFillingTakesTheFewestColumnsThatFit() {
        // Three projects, two spaces and the + on 1600×900: two columns are too tall, three fit.
        let filled = OverviewLayout.filling(projects: 3, others: 3, width: 1600, height: 900)
        XCTAssertEqual(filled.columns, 3)
        XCTAssertLessThanOrEqual(filled.height, 900)
        XCTAssertGreaterThan(OverviewLayout.grid(projects: 3, others: 3, width: 1600, columns: 2).height, 900)
        let many = OverviewLayout.filling(projects: 4, others: 12, width: 1200, height: 700)
        XCTAssertLessThanOrEqual(many.height, 700)
    }

    func testUpAndDownLandOnTheNearestTileInTheNextRow() {
        let result = OverviewLayout.grid(projects: 2, others: 5, width: 1000, minTile: 210)
        // Row 1: projects 0, 1. Row 2: spaces 2…5. Row 3: space 6.
        XCTAssertEqual(OverviewLayout.vertical(from: 1, by: 1, in: result.cells), 3)
        XCTAssertEqual(OverviewLayout.vertical(from: 6, by: -1, in: result.cells), 2)
        XCTAssertNil(OverviewLayout.vertical(from: 0, by: -1, in: result.cells))
    }

    func testWindowsOutSitSmallerBesideTheirPlacesWindowWithoutOverlapping() {
        // A project window; one window out over its right half, one over its left, one lower right.
        let main = CGRect(x: 0, y: 0, width: 1000, height: 600)
        let right = CGRect(x: 700, y: 300, width: 600, height: 300)
        let left = CGRect(x: -100, y: 100, width: 400, height: 400)
        let lower = CGRect(x: 800, y: 0, width: 400, height: 200)
        let area = CGRect(x: 0, y: 0, width: 320, height: 200)
        let rects = OverviewLayout.cluster([main, right, left, lower], in: area)
        for a in rects.indices { for b in rects.indices where a < b {
            XCTAssertFalse(rects[a].intersects(rects[b]), "\(a) and \(b) overlap")
        } }
        XCTAssertLessThan(rects[1].height, rects[0].height)
        XCTAssertGreaterThan(rects[1].minX, rects[0].maxX, "right of it, as on screen")
        XCTAssertLessThan(rects[2].maxX, rects[0].minX, "left of it, as on screen")
        XCTAssertLessThan(rects[1].minY, rects[3].minY, "the higher one first")
        XCTAssertEqual(rects[1].minY, rects[0].minY, accuracy: 0.01, "level with its top")
        XCTAssertEqual(rects.reduce(rects[0]) { $0.union($1) }.maxY, area.maxY, accuracy: 0.01, "on the foot")
        XCTAssertLessThanOrEqual(rects.reduce(rects[0]) { $0.union($1) }.width, area.width + 0.01)
        XCTAssertEqual(OverviewLayout.cluster([main], in: area)[0].width, 320, accuracy: 0.01, "one window fills the width")
    }

    func testDockOrderPutsPlacedProjectsFirstAndRemembersClosedOnes() {
        XCTAssertEqual(DockOrder.sorted(["a", "b", "c", "d"], preferred: ["c", "a"]), ["c", "a", "b", "d"])
        XCTAssertEqual(DockOrder.sorted(["a", "b"], preferred: []), ["a", "b"])
        XCTAssertEqual(DockOrder.remembered(["b", "a"], previous: ["a", "z", "b"]), ["b", "a", "z"])
    }
}
