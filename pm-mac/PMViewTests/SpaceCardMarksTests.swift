import PmLib
import XCTest

/// Pinned and favourite on a space's cards (docs/spaces.md § The frame).
final class SpaceCardMarksTests: XCTestCase {
    private func card() -> CanvasNode {
        CanvasNode(content: .link(url: "https://example.com"), frame: CanvasRect(x: 0, y: 0, width: 400, height: 400))
    }

    func testACardStartsInTodayWithNoKeys() {
        let node = card()
        XCTAssertFalse(SpaceCardMarks.isPinned(node))
        XCTAssertFalse(SpaceCardMarks.isFavorite(node))
        XCTAssertTrue(node.extra.isEmpty)
    }

    func testAFavouriteIsPinnedAndUnpinningClearsBoth() {
        var node = card()
        SpaceCardMarks.setFavorite(true, on: &node)
        XCTAssertTrue(SpaceCardMarks.isPinned(node))
        XCTAssertTrue(SpaceCardMarks.isFavorite(node))
        SpaceCardMarks.setPinned(false, on: &node)
        XCTAssertFalse(SpaceCardMarks.isPinned(node))
        XCTAssertFalse(SpaceCardMarks.isFavorite(node))
        XCTAssertTrue(node.extra.isEmpty, "false is the key gone, not false written")
    }

    func testRemovingAFavouriteLeavesItPinned() {
        var node = card()
        SpaceCardMarks.setFavorite(true, on: &node)
        SpaceCardMarks.setFavorite(false, on: &node)
        XCTAssertTrue(SpaceCardMarks.isPinned(node))
        XCTAssertFalse(SpaceCardMarks.isFavorite(node))
    }

    func testTheMarksAreTheFilesOwnKeys() {
        var node = card()
        SpaceCardMarks.setPinned(true, on: &node)
        XCTAssertEqual(node.extra["pmPinned"], .bool(true))
    }

    /// Files dropped in the sidebar (`SpaceFrame.landFiles`): in drop order from the slot, the list's
    /// other cards kept around them, and each takes the list's marks.
    func testDroppedCardsGoInOrderAtTheSlot() {
        let a = card(), b = card()
        var document = CanvasDocument(nodes: [a, b])
        let x = CanvasNode(content: .file(path: "x.csv", subpath: nil), frame: CanvasRect(x: 0, y: 0, width: 400, height: 350))
        let y = CanvasNode(content: .file(path: "y.csv", subpath: nil), frame: CanvasRect(x: 0, y: 0, width: 400, height: 350))
        SpaceCardMarks.insert([x, y], into: .pinned(folder: nil), at: 1, members: [a.id, b.id], in: &document)
        let ordered = SpaceCardMarks.sorted(document.nodes) { SpaceCardMarks.order($0) }.map(\.id)
        XCTAssertEqual(ordered, [a.id, x.id, y.id, b.id])
        XCTAssertTrue(document.nodes.filter { [x.id, y.id].contains($0.id) }.allSatisfy(SpaceCardMarks.isPinned))
    }

    func testDroppedCardsAtTheEndOfAnEmptyList() {
        var document = CanvasDocument(nodes: [])
        let x = card(), y = card()
        SpaceCardMarks.insert([x, y], into: .today(folder: nil), at: 0, members: [], in: &document)
        XCTAssertEqual(SpaceCardMarks.sorted(document.nodes) { SpaceCardMarks.order($0) }.map(\.id), [x.id, y.id])
        XCTAssertFalse(document.nodes.contains(where: SpaceCardMarks.isPinned))
    }
}
