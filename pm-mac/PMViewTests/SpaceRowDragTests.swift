import PmLib
import XCTest

/// Dragging a card's row in a frame's sidebar (docs/spaces.md § The frame): its place in a list, the
/// marks a list means, folders, and where it lands on the tiles.
final class SpaceRowDragTests: XCTestCase {
    private func card(_ id: String, x: Double = 0, y: Double = 0) -> CanvasNode {
        CanvasNode(id: id, content: .link(url: "https://\(id).example"),
                   frame: CanvasRect(x: x, y: y, width: 200, height: 100))
    }

    private func frame(_ id: String, x: Double, y: Double, width: Double, height: Double) -> CanvasNode {
        CanvasNode(id: id, content: .group(label: id, background: nil, backgroundStyle: nil),
                   frame: CanvasRect(x: x, y: y, width: width, height: height))
    }

    /// The list's ids in the sidebar's order, as `SpaceFrame.refresh` sorts them.
    private func order(_ ids: [String], in document: CanvasDocument) -> [String] {
        SpaceCardMarks.sorted(ids) { id in document.node(id: id).flatMap(SpaceCardMarks.order) }
    }

    // MARK: Order

    func testUnmarkedCardsKeepTheirOrderAfterMarkedOnes() {
        let marks: [String: Double] = ["c": 0]
        XCTAssertEqual(SpaceCardMarks.sorted(["a", "b", "c", "d"]) { marks[$0] }, ["c", "a", "b", "d"])
    }

    func testDraggingUpPutsTheCardBeforeTheSlot() {
        var document = CanvasDocument(nodes: [card("a"), card("b"), card("c")])
        SpaceCardMarks.move("c", to: .today(folder: nil), at: 0, members: ["a", "b", "c"], in: &document)
        XCTAssertEqual(order(["a", "b", "c"], in: document), ["c", "a", "b"])
    }

    func testDraggingDownCountsTheCardsOldPlace() {
        var document = CanvasDocument(nodes: [card("a"), card("b"), card("c")])
        // The slot before c, in the list as it stands with a still in it.
        SpaceCardMarks.move("a", to: .today(folder: nil), at: 2, members: ["a", "b", "c"], in: &document)
        XCTAssertEqual(order(["a", "b", "c"], in: document), ["b", "a", "c"])
        SpaceCardMarks.move("b", to: .today(folder: nil), at: 3, members: ["b", "a", "c"], in: &document)
        XCTAssertEqual(order(["a", "b", "c"], in: document), ["a", "c", "b"])
    }

    // MARK: What a list means

    func testPinnedTodayAndFavouritesSetTheirMarks() {
        var document = CanvasDocument(nodes: [card("a"), card("b")])
        SpaceCardMarks.move("a", to: .pinned(folder: nil), at: 0, members: [], in: &document)
        XCTAssertTrue(SpaceCardMarks.isPinned(document.node(id: "a")!))
        SpaceCardMarks.move("a", to: .favorites, at: 0, members: [], in: &document)
        XCTAssertTrue(SpaceCardMarks.isFavorite(document.node(id: "a")!))
        SpaceCardMarks.move("a", to: .pinned(folder: nil), at: 0, members: [], in: &document)
        XCTAssertTrue(SpaceCardMarks.isPinned(document.node(id: "a")!))
        XCTAssertFalse(SpaceCardMarks.isFavorite(document.node(id: "a")!), "out of Favourites, still pinned")
        SpaceCardMarks.move("a", to: .today(folder: nil), at: 0, members: ["b"], in: &document)
        XCTAssertFalse(SpaceCardMarks.isPinned(document.node(id: "a")!))
        XCTAssertEqual(order(["a", "b"], in: document), ["a", "b"])
    }

    func testFavouritesDontMoveTheCardOnTheBoard() {
        var document = CanvasDocument(nodes: [frame("F", x: 0, y: 0, width: 600, height: 400), card("a", x: 50, y: 50)])
        SpaceCardMarks.move("a", to: .favorites, at: 0, members: [], in: &document)
        XCTAssertEqual(document.node(id: "a")?.frame, CanvasRect(x: 50, y: 50, width: 200, height: 100))
    }

    // MARK: Folders

    func testIntoAFolderGoesUnderItsCardsAndGrowsTheFrame() {
        var document = CanvasDocument(nodes: [
            frame("F", x: 0, y: 0, width: 300, height: 200),
            card("in", x: 20, y: 40),
            card("out", x: 1000, y: 0),
        ])
        SpaceCardMarks.move("out", to: .today(folder: "F"), at: 1, members: ["in"], in: &document)
        let moved = document.node(id: "out")!
        XCTAssertEqual(SpaceCardMarks.folder(of: moved, in: document), "F")
        XCTAssertEqual(moved.frame.minX, 20)
        XCTAssertEqual(moved.frame.minY, 160, "under the card already there")
        XCTAssertGreaterThanOrEqual(document.node(id: "F")!.frame.maxY, moved.frame.maxY)
        XCTAssertEqual(order(["in", "out"], in: document), ["in", "out"])
    }

    func testOutOfAFolderGoesRightOfEverything() {
        var document = CanvasDocument(nodes: [frame("F", x: 0, y: 0, width: 600, height: 400), card("a", x: 50, y: 50)])
        SpaceCardMarks.move("a", to: .pinned(folder: nil), at: 0, members: [], in: &document)
        let moved = document.node(id: "a")!
        XCTAssertNil(SpaceCardMarks.folder(of: moved, in: document))
        XCTAssertEqual(moved.frame.minX, 640)
    }

    func testTheInnermostFrameIsTheFolder() {
        let document = CanvasDocument(nodes: [
            frame("outer", x: 0, y: 0, width: 1000, height: 1000),
            frame("inner", x: 0, y: 0, width: 400, height: 400),
            card("a", x: 50, y: 50),
        ])
        XCTAssertEqual(SpaceCardMarks.folder(of: document.node(id: "a")!, in: document), "inner")
    }

    // MARK: Onto the tiles

    private let area = CanvasRect(x: 0, y: 0, width: 1000, height: 600)

    private func session(_ columns: [[String]]) -> CanvasTileSession {
        CanvasTileSession(columns: columns.map { CanvasTiling.Column([CanvasTiling.Tile($0)]) },
                          area: area, restoreVisible: area)
    }

    func testANewCardReplacesInATilesMiddleAndGoesBesideAtItsEdges() throws {
        let tiles = session([["a"], ["b"]])
        let a = try XCTUnwrap(tiles.tileFrames["a"])
        let middle = tiles.drop(ofCard: "x", at: CanvasPoint(x: a.midX, y: a.midY))
        XCTAssertEqual(middle?.target, "a")
        XCTAssertEqual(middle?.drop, .swap)
        let edge = tiles.drop(ofCard: "x", at: CanvasPoint(x: a.minX + 5, y: a.midY))
        XCTAssertEqual(edge?.drop, .beside(.left))
        XCTAssertNil(tiles.drop(ofCard: "x", at: CanvasPoint(x: -50, y: -50)), "off the tiles is nowhere")
    }

    func testACardAlreadyUpJoinsTabsAndHasNoPlaceInItsOwnTile() throws {
        let tiles = session([["a"], ["b"]])
        let a = try XCTUnwrap(tiles.tileFrames["a"]), b = try XCTUnwrap(tiles.tileFrames["b"])
        XCTAssertNil(tiles.drop(ofCard: "a", at: CanvasPoint(x: a.midX, y: a.midY)))
        XCTAssertNil(tiles.drop(ofCard: "a", at: CanvasPoint(x: a.maxX - 5, y: a.midY)))
        XCTAssertEqual(tiles.drop(ofCard: "a", at: CanvasPoint(x: b.midX, y: b.midY))?.drop, .beside(.tab))
    }

    /// A note dropped from outside goes beside a tile at its edges and into its tabs everywhere else —
    /// never in a tile's place, which would take what you were looking at out of view.
    func testADroppedNoteGoesBesideAtTheEdgesAndIntoTheTabsInTheMiddle() throws {
        let tiles = session([["a"], ["b"]])
        let a = try XCTUnwrap(tiles.tileFrames["a"])
        let middle = tiles.drop(ofNewCardAt: CanvasPoint(x: a.midX, y: a.midY))
        XCTAssertEqual(middle?.target, "a")
        XCTAssertEqual(middle?.drop, .beside(.tab))
        XCTAssertEqual(tiles.drop(ofNewCardAt: CanvasPoint(x: a.maxX - 5, y: a.midY))?.drop, .beside(.right))
        XCTAssertEqual(tiles.drop(ofNewCardAt: CanvasPoint(x: a.midX, y: a.maxY - 5))?.drop, .beside(.below))
        XCTAssertEqual(tiles.drop(ofNewCardAt: CanvasPoint(x: a.midX, y: a.minY + 2))?.drop, .beside(.tab))
        XCTAssertNil(tiles.drop(ofNewCardAt: CanvasPoint(x: -50, y: -50)), "off the tiles is nowhere")
    }

    /// The edges and the strip are the tiling's; the middle is the card's — a web tile's page keeps it.
    func testOnlyATilesEdgesAndStripAreTheTilings() throws {
        let tiles = session([["a"], ["b"]])
        let a = try XCTUnwrap(tiles.tileFrames["a"])
        XCTAssertFalse(tiles.isTilingGround(CanvasPoint(x: a.midX, y: a.midY)))
        XCTAssertTrue(tiles.isTilingGround(CanvasPoint(x: a.minX + 5, y: a.midY)))
        XCTAssertTrue(tiles.isTilingGround(CanvasPoint(x: a.midX, y: a.minY + 2)))
        XCTAssertFalse(tiles.isTilingGround(CanvasPoint(x: -50, y: -50)))
    }

    /// Landing where the mark said: the Figma tile keeps its place, and the note opens a column beside it.
    func testADroppedNoteLandsBesideTheTileItWasAimedAt() {
        var tiles = session([["figma"]])
        tiles.preselection = .init(target: "figma", side: .right)
        tiles.add("note", at: tiles.preselection)
        XCTAssertEqual(tiles.ids, ["figma", "note"])
        XCTAssertEqual(tiles.columns.count, 2)
        XCTAssertNil(tiles.preselection, "the place is used up")
    }

    // MARK: Several tabs at once

    private func tabbed(_ columns: [[[String]]]) -> CanvasTileSession {
        CanvasTileSession(columns: columns.map { CanvasTiling.Column($0.map { CanvasTiling.Tile($0) }) },
                          area: area, restoreVisible: area)
    }

    /// Slid along their strip, selected tabs land together where the dragged one was let go, in order.
    func testSelectedTabsMoveAlongTheirStripTogether() {
        var tiles = tabbed([[["a", "b", "c", "d", "e"]]])
        tiles.gatherTabs(["b", "d"], into: "d", at: 3)
        XCTAssertEqual(tiles.tabs(of: "a"), ["a", "c", "e", "b", "d"])
        XCTAssertEqual(tiles.ids, ["d"], "the one dragged shows")
        tiles.gatherTabs(["b", "d"], into: "b", at: 0)
        XCTAssertEqual(tiles.tabs(of: "a"), ["b", "d", "a", "c", "e"])
    }

    /// Selected tabs in other tiles come into the strip, and a tile they leave empty goes.
    func testSelectedTabsFromOtherTilesJoinTheStrip() {
        var tiles = tabbed([[["a", "b"]], [["x"], ["y", "z"]]])
        tiles.gatherTabs(["b", "x", "z"], into: "b", at: 1)
        XCTAssertEqual(tiles.tabs(of: "a"), ["a", "b", "x", "z"])
        XCTAssertEqual(tiles.tabs(of: "y"), ["y"])
        XCTAssertEqual(tiles.columns.count, 2, "x's tile went; y's stayed")
    }

    /// Carried off the strip and let go beside a tile, the group is a new tile of its own, in order.
    func testSelectedTabsPulledOutMakeOneTileBeside() {
        var tiles = tabbed([[["a", "b", "c"]], [["x"]]])
        tiles.landTabs(["b", "c"], anchor: "c", on: "x", .beside(.right))
        XCTAssertEqual(tiles.tabs(of: "a"), ["a"])
        XCTAssertEqual(tiles.tabs(of: "c"), ["b", "c"])
        XCTAssertEqual(tiles.columns.count, 3)
        XCTAssertEqual(tiles.ids.last, "c")
    }

    /// Let go on another tile's tabs, the group joins them, after what is there.
    func testSelectedTabsJoinAnotherTilesTabs() {
        var tiles = tabbed([[["a", "b", "c"]], [["x", "y"]]])
        tiles.landTabs(["a", "c"], anchor: "a", on: "x", .beside(.tab))
        XCTAssertEqual(tiles.tabs(of: "x"), ["x", "y", "a", "c"])
        XCTAssertEqual(tiles.tabs(of: "b"), ["b"])
    }

    func testLandingANewCardBesideAndInPlace() throws {
        var tiles = session([["a"], ["b"]])
        tiles.add("x", at: .init(target: "b", side: .right))
        XCTAssertEqual(tiles.ids, ["a", "b", "x"])
        XCTAssertTrue(tiles.replace("a", with: "y"))
        XCTAssertEqual(Set(tiles.cards), ["y", "b", "x"])
    }

    // MARK: Workspace rows

    func testWorkspacesFollowTheDraggedOrderThenTheRestAlphabetically() {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("order-\(UUID()).canvas")
        defer {
            for name in CanvasWorkspaces.names(of: url) { CanvasWorkspaces.remove(name, for: url) }
            CanvasWorkspaces.setOrder([], for: url)
        }
        let tiling = CanvasViewState.Tiling(ids: ["a"], arrangement: .masterStack, masterFraction: 0.5, sizes: nil)
        for name in ["Alpha", "Beta", "Gamma"] { CanvasWorkspaces.save(tiling, as: name, for: url) }
        XCTAssertEqual(CanvasWorkspaces.ordered(of: url), ["Alpha", "Beta", "Gamma"])
        CanvasWorkspaces.setOrder(["Gamma", "Alpha"], for: url)
        XCTAssertEqual(CanvasWorkspaces.ordered(of: url), ["Gamma", "Alpha", "Beta"])
        CanvasWorkspaces.renameInOrder("Gamma", to: "Zeta", for: url)
        CanvasWorkspaces.save(tiling, as: "Zeta", for: url)
        CanvasWorkspaces.remove("Gamma", for: url)
        XCTAssertEqual(CanvasWorkspaces.ordered(of: url), ["Zeta", "Alpha", "Beta"], "a rename keeps its place")
        XCTAssertEqual(CanvasWorkspaces.names(of: url), ["Alpha", "Beta", "Zeta"], "menus stay alphabetical")
    }
}
