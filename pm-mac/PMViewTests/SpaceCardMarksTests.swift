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
}
