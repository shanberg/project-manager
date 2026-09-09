import XCTest

/// What a window's tabs do when you open, close, reorder and cycle them.
///
/// The interesting parts are all about the selection, which is the thing a user notices when it is
/// wrong: closing the tab you are looking at has to land you somewhere sensible, and a set rebuilt
/// from storage that no longer agrees with itself has to be repaired rather than shown.
final class ProjectTabTests: XCTestCase {

    /// A window nobody has given tabs is the window this app has always had.
    func testStartsAsOneNotesTabWithNoBar() {
        let set = ProjectTabSet()
        XCTAssertEqual(set.tabs.count, 1)
        XCTAssertEqual(set.selected.view, .notes)
        XCTAssertFalse(set.showsBar)
    }

    /// Opened next to the tab it came from, not at the end of the row — a frame opened from its board
    /// belongs beside that board.
    func testOpensAfterTheCurrentTabAndSelectsIt() {
        var set = ProjectTabSet()
        let board = set.open(.board(.whole))
        let frame = set.open(.board(.frame("group-1")))
        XCTAssertEqual(set.tabs.map(\.id), [set.tabs[0].id, board.id, frame.id])
        XCTAssertEqual(set.selectedID, frame.id)
        XCTAssertTrue(set.showsBar)

        // Going back to the first and opening again puts the new one second, not last.
        set.select(set.tabs[0].id)
        let notes = set.open(.notes)
        XCTAssertEqual(set.tabs.map(\.id), [set.tabs[0].id, notes.id, board.id, frame.id])
    }

    /// The renderer switch changes what this tab holds rather than adding one.
    func testReplacingTheSelectedViewAddsNoTab() {
        var set = ProjectTabSet()
        set.replaceSelected(with: .board(.whole))
        XCTAssertEqual(set.tabs.count, 1)
        XCTAssertEqual(set.selected.view, .board(.whole))
    }

    /// Closing the tab you are on goes right — the direction you were travelling.
    func testClosingTheSelectedTabSelectsTheOneToItsRight() {
        var set = ProjectTabSet()
        let second = set.open(.board(.whole))
        let third = set.open(.board(.workspace("Review")))
        set.select(second.id)

        XCTAssertTrue(set.close(second.id))
        XCTAssertEqual(set.selectedID, third.id)
    }

    /// Except at the end of the row, where there is nothing to the right.
    func testClosingTheLastTabInTheRowFallsBackToTheLeft() {
        var set = ProjectTabSet()
        let second = set.open(.board(.whole))
        let third = set.open(.notes)
        XCTAssertEqual(set.selectedID, third.id)

        XCTAssertTrue(set.close(third.id))
        XCTAssertEqual(set.selectedID, second.id)
    }

    /// Closing one you are not looking at leaves you where you are.
    func testClosingAnotherTabKeepsTheSelection() {
        var set = ProjectTabSet()
        let first = set.tabs[0].id
        let second = set.open(.board(.whole))
        set.select(second.id)

        XCTAssertTrue(set.close(first))
        XCTAssertEqual(set.selectedID, second.id)
        XCTAssertEqual(set.tabs.count, 1)
        XCTAssertFalse(set.showsBar)
    }

    /// The final tab never closes. A window with no tab has nothing in it, and closing the window is
    /// the window's decision rather than this type's.
    func testTheLastTabWillNotClose() {
        var set = ProjectTabSet()
        XCTAssertFalse(set.close(set.tabs[0].id))
        XCTAssertEqual(set.tabs.count, 1)
    }

    /// ⌃⇥ wraps in both directions.
    func testCyclingWraps() {
        var set = ProjectTabSet()
        let second = set.open(.board(.whole))
        let third = set.open(.notes)
        set.select(set.tabs[0].id)

        set.selectNext()
        XCTAssertEqual(set.selectedID, second.id)
        set.selectNext()
        XCTAssertEqual(set.selectedID, third.id)
        set.selectNext()
        XCTAssertEqual(set.selectedID, set.tabs[0].id)

        set.selectNext(by: -1)
        XCTAssertEqual(set.selectedID, third.id)
    }

    /// A drag along the bar reorders without changing what you are looking at.
    func testMovingATabKeepsTheSelection() {
        var set = ProjectTabSet()
        let second = set.open(.board(.whole))
        let third = set.open(.board(.frame("g")))
        set.select(second.id)

        set.move(third.id, to: 0)
        XCTAssertEqual(set.tabs.map(\.id), [third.id, set.tabs[1].id, second.id])
        XCTAssertEqual(set.selectedID, second.id)
    }

    /// Storage that no longer agrees with itself is repaired rather than trusted.
    func testARebuiltSetRepairsItself() {
        let orphan = ProjectTabSet(tabs: [], selectedID: "gone")
        XCTAssertEqual(orphan.tabs.count, 1)
        XCTAssertEqual(orphan.selected.view, .notes)

        let tab = ProjectTab(.board(.whole))
        let dangling = ProjectTabSet(tabs: [tab], selectedID: "not-here")
        XCTAssertEqual(dangling.selectedID, tab.id)
    }

    /// A tab pinned to part of a board survives the trip through storage — the case that matters is
    /// the associated value, which is the whole of what distinguishes two tabs on one canvas.
    func testAPinnedTabRoundTrips() throws {
        let tabs = [ProjectTab(.notes),
                    ProjectTab(.board(.whole)),
                    ProjectTab(.board(.frame("group-7"))),
                    ProjectTab(.board(.workspace("Standup")))]
        let data = try JSONEncoder().encode(tabs)
        XCTAssertEqual(try JSONDecoder().decode([ProjectTab].self, from: data), tabs)
    }
}
