import XCTest
import PmLib
@testable import PMViewTests

/// Closing under a frame: a tile is a tab. See `SpaceClosing` and docs/spaces.md § Closing.
@MainActor
final class SpaceClosingTests: XCTestCase {
    private let area = CanvasRect(x: 0, y: 0, width: 1200, height: 800)

    /// One tile per entry; an entry of several cards is one tile of tabs, its first showing.
    private func session(_ tiles: [[String]]) -> CanvasTileSession {
        let made = tiles.map { CanvasTiling.Tile($0) }
        return CanvasTileSession(columns: CanvasTiling.columns(.grid, of: made, in: area, masterFraction: 0.6, sizes: [:]),
                                 area: area, restoreVisible: area)
    }

    private let everything: (String) -> Bool = { _ in true }

    // MARK: The layout

    func testTheOnlyTileTakesTheCardInFrontBeforeIt() {
        let plan = SpaceClosing.plan(closing: ["a"], front: "a", tiling: session([["a"]]),
                                     recent: ["a", "b", "c"], exists: everything)
        XCTAssertEqual(plan.replace?.closing, "a")
        XCTAssertEqual(plan.replace?.with, "b")
        XCTAssertEqual(plan.leave, [])
        XCTAssertEqual(plan.next, "b")
    }

    func testTheOnlyTileSkipsCardsGoneOrClosingToo() {
        let plan = SpaceClosing.plan(closing: ["a", "b"], front: "a", tiling: session([["a"]]),
                                     recent: ["a", "b", "c", "d"], exists: { $0 != "c" })
        XCTAssertEqual(plan.replace?.with, "d")
    }

    func testWithNothingRememberedTheLastTileLeavesForTheBoard() {
        let plan = SpaceClosing.plan(closing: ["a"], front: "a", tiling: session([["a"]]), recent: ["a"],
                                     exists: everything)
        XCTAssertNil(plan.replace)
        XCTAssertEqual(plan.leave, ["a"])
        XCTAssertNil(plan.next)
    }

    func testATileOfASplitGoesAndTheLayoutClosesUp() {
        let plan = SpaceClosing.plan(closing: ["a"], front: "a", tiling: session([["a"], ["b"]]),
                                     recent: ["a", "c", "b"], exists: everything)
        XCTAssertNil(plan.replace, "nothing from off the screen fills a split's pane")
        XCTAssertEqual(plan.leave, ["a"])
        XCTAssertNil(plan.next)
    }

    func testATabGivesWayToTheTabOfItsTileInFrontMostLately() {
        let plan = SpaceClosing.plan(closing: ["a"], front: "a", tiling: session([["a", "b", "c"], ["d"]]),
                                     recent: ["a", "d", "c", "b"], exists: everything)
        XCTAssertNil(plan.replace, "the tab is already up")
        XCTAssertEqual(plan.leave, ["a"])
        XCTAssertEqual(plan.next, "c", "not d, in the other tile, though it was in front more lately")
    }

    func testACardNotInFrontJustLeaves() {
        let plan = SpaceClosing.plan(closing: ["b"], front: "a", tiling: session([["a"], ["b"]]),
                                     recent: ["a", "b"], exists: everything)
        XCTAssertNil(plan.replace)
        XCTAssertEqual(plan.leave, ["b"])
        XCTAssertNil(plan.next)
    }

    func testACardNotUpLeavesTheLayoutAlone() {
        let plan = SpaceClosing.plan(closing: ["z"], front: "a", tiling: session([["a"]]), recent: ["a"],
                                     exists: everything)
        XCTAssertEqual(plan, SpaceClosing.Plan(replace: nil, leave: [], next: nil))
    }

    // MARK: The board

    func testCardsComeOffWithTheirLinesAndGoBackAsTheyWere() throws {
        var note = CanvasNode(content: .text("# Plan"), frame: CanvasRect(x: 10, y: 20, width: 300, height: 200),
                              extra: ["pmSomethingNew": .string("kept")])
        SpaceCardMarks.setPinned(false, on: &note)
        let web = CanvasNode(content: .link(url: "https://example.com"), frame: CanvasRect(x: 400, y: 0, width: 400, height: 400))
        let other = CanvasNode(content: .text("other"), frame: CanvasRect(x: 900, y: 0, width: 100, height: 100))
        let toWeb = CanvasEdge(fromNode: note.id, toNode: web.id)
        let toOther = CanvasEdge(fromNode: note.id, toNode: other.id)
        var document = CanvasDocument(nodes: [note, web, other], edges: [toWeb, toOther])
        let edges = document.edges

        SpaceClosing.takeOff([note.id, web.id], from: &document)
        XCTAssertEqual(document.nodes.map(\.id), [other.id])
        XCTAssertTrue(document.edges.isEmpty)

        // Keep or Undo with only the note: its line to the web card waits for the web card.
        SpaceClosing.putBack([note], edges: edges, into: &document)
        XCTAssertEqual(document.edges.map(\.id), [toOther.id])
        let back = try XCTUnwrap(document.node(id: note.id))
        XCTAssertEqual(back, note, "as it was: place, content, keys Folio doesn't know")

        SpaceClosing.putBack([note, web], edges: edges, into: &document)
        XCTAssertEqual(document.nodes.count, 3, "a card already back is left alone")
        XCTAssertEqual(Set(document.edges.map(\.id)), [toWeb.id, toOther.id])
    }

    func testAProjectBoardIsKeptUnderItsCanvasInTheArchive() {
        let canvas = URL(fileURLWithPath: "/tmp/Project/board.canvas")
        XCTAssertEqual(SpaceArchive.key(spaceID: "s1", canvas: canvas), "s1")
        XCTAssertEqual(SpaceArchive.key(spaceID: nil, canvas: canvas), "canvas:/tmp/Project/board.canvas")
    }
}
