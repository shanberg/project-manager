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
