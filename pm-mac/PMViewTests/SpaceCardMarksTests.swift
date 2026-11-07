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

    // MARK: Several rows dragged together, and names typed into rows

    private func ordered(_ document: CanvasDocument, _ ids: [String]) -> [String] {
        SpaceCardMarks.sorted(document.nodes.filter { ids.contains($0.id) }) { SpaceCardMarks.order($0) }.map(\.id)
    }

    /// Picked rows from above the slot and below it land together, in sidebar order, at the slot.
    func testSeveralRowsLandTogetherAtTheSlot() {
        let nodes = (0..<5).map { _ in card() }
        let ids = nodes.map(\.id)
        var document = CanvasDocument(nodes: nodes)
        // a b c d e: carry b and e to before d.
        SpaceCardMarks.move([ids[1], ids[4]], to: .today(folder: nil), at: 3, members: ids, in: &document)
        XCTAssertEqual(ordered(document, ids), [ids[0], ids[2], ids[1], ids[4], ids[3]])
    }

    func testSeveralRowsToTheTop() {
        let nodes = (0..<4).map { _ in card() }
        let ids = nodes.map(\.id)
        var document = CanvasDocument(nodes: nodes)
        SpaceCardMarks.move([ids[2], ids[3]], to: .today(folder: nil), at: 0, members: ids, in: &document)
        XCTAssertEqual(ordered(document, ids), [ids[2], ids[3], ids[0], ids[1]])
    }

    /// From Today into Pinned: each carried card is pinned, and lands at the slot in Pinned.
    func testSeveralRowsIntoAnotherList() {
        var pin = card()
        SpaceCardMarks.setPinned(true, on: &pin)
        let x = card(), y = card()
        var document = CanvasDocument(nodes: [pin, x, y])
        SpaceCardMarks.move([x.id, y.id], to: .pinned(folder: nil), at: 1, members: [pin.id], in: &document)
        XCTAssertEqual(ordered(document, [pin.id, x.id, y.id]), [pin.id, x.id, y.id])
        XCTAssertTrue(document.nodes.allSatisfy(SpaceCardMarks.isPinned))
    }

    func testATypedNameIsAKeyAndClearingItRemovesTheKey() {
        var node = card()
        XCTAssertNil(SpaceCardMarks.title(node))
        SpaceCardMarks.setTitle("  Inbox ", on: &node)
        XCTAssertEqual(SpaceCardMarks.title(node), "Inbox")
        XCTAssertEqual(node.extra["pmTitle"], .string("Inbox"))
        SpaceCardMarks.setTitle("   ", on: &node)
        XCTAssertNil(SpaceCardMarks.title(node))
        XCTAssertTrue(node.extra.isEmpty)
    }
}
