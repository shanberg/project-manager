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
                    ProjectTab(.board(.note)),
                    ProjectTab(.board(.workspace("Standup")))]
        let data = try JSONEncoder().encode(tabs)
        XCTAssertEqual(try JSONDecoder().decode([ProjectTab].self, from: data), tabs)
    }

    /// **A workspace still goes on the wire as `arrangement`.** Every stored tab written since tabs
    /// existed spells it that way, and a case added beside it must not disturb the spelling — a tab
    /// that decodes as nothing comes back as a window one tab short, quietly, weeks later. This asserts
    /// the bytes rather than a round trip, which would pass however the case were named.
    func testAWorkspaceKeepsItsOldNameOnDisk() throws {
        let json = String(decoding: try JSONEncoder().encode(ProjectTab(.board(.workspace("Standup")),
                                                                        id: "t1")),
                          as: UTF8.self)
        XCTAssertTrue(json.contains("\"arrangement\""), json)
        XCTAssertFalse(json.contains("\"workspace\""), json)

        // And the note, whose name on disk is its own — it is new, so there is nothing to keep faith
        // with, and the honest word is the one the code uses.
        let note = String(decoding: try JSONEncoder().encode(ProjectTab(.board(.note), id: "t2")),
                          as: UTF8.self)
        XCTAssertTrue(note.contains("\"note\""), note)
    }

    // MARK: Tabs as the home of a workspace

    /// ⌘Return leaves the named workspace it was in *open*, behind the pane that became the fresh
    /// unnamed one. Before rather than after, so the row reads in the order the two were made — and
    /// without moving the selection, which stays on the thing the command just built.
    func testOpeningBehindKeepsTheSelectionAndGoesFirst() {
        var set = ProjectTabSet()
        let board = set.open(.board(.whole))
        set.openBehind(.board(.workspace("Dashboard")))
        XCTAssertEqual(set.tabs.count, 3)
        XCTAssertEqual(set.tabs[1].view, .board(.workspace("Dashboard")))
        XCTAssertEqual(set.tabs[2].id, board.id)
        XCTAssertEqual(set.selectedID, board.id, "still in what ⌘Return just made")
    }

    /// Two chips on one workspace are two names for one thing, so switching finds the one that is
    /// open rather than making a second.
    func testFindsTheTabAThingIsAlreadyOpenIn() {
        var set = ProjectTabSet()
        let dashboard = set.open(.board(.workspace("Dashboard")))
        set.open(.board(.workspace("Review")))
        XCTAssertEqual(set.first(showing: .board(.workspace("Dashboard")))?.id, dashboard.id)
        XCTAssertNil(set.first(showing: .board(.workspace("Standup"))),
                     "a workspace that is not open is not open")
        XCTAssertNil(set.first(showing: .board(.frame("Dashboard"))),
                     "a frame and a workspace of the same name are different things")
    }

    /// A tab follows the board it is holding: you named the workspace it was showing, so it is that
    /// workspace's tab now. The row and the selection are untouched — nothing moved, one chip changed
    /// what it says.
    func testRetargetingATabLeavesTheRowAlone() {
        var set = ProjectTabSet()
        let board = set.open(.board(.whole))
        let frame = set.open(.board(.frame("group-1")))
        set.select(board.id)
        set.retarget(board.id, to: .board(.workspace("Dashboard")))
        XCTAssertEqual(set.tabs.map(\.view),
                       [.notes, .board(.workspace("Dashboard")), .board(.frame("group-1"))])
        XCTAssertEqual(set.selectedID, board.id)
        XCTAssertEqual(set.tabs[2].id, frame.id)
    }

    /// An id that is not in the row is a tab that was closed while something was deciding what to do
    /// about it — silence rather than a crash, and rather than retargeting some other tab.
    func testRetargetingAnUnknownTabDoesNothing() {
        var set = ProjectTabSet()
        set.retarget("gone", to: .board(.workspace("Dashboard")))
        XCTAssertEqual(set.tabs.map(\.view), [.notes])
    }
}

// MARK: - A tab follows its board

/// The rule that replaced the renderer switch. See `ProjectTabView.following(workspaceName:…)`.
final class TabFollowsItsBoardTests: XCTestCase {
    func testLeavingTheOneCardTilingTurnsTheNotesIntoTheBoard() {
        XCTAssertEqual(ProjectTabView.notes.following(workspaceName: nil,
                                                      showingProjectNoteAlone: false),
                       .board(.whole))
    }

    func testTheNotesStayTheNotesWhileTheirCardIsWhatIsTiled() {
        XCTAssertEqual(ProjectTabView.notes.following(workspaceName: nil,
                                                      showingProjectNoteAlone: true),
                       .notes)
    }

    func testTilingTheProjectCardAloneOnTheBoardIsTheWayBackToTheNotes() {
        XCTAssertEqual(ProjectTabView.board(.whole).following(workspaceName: nil,
                                                             showingProjectNoteAlone: true),
                       .notes)
    }

    func testAStoredNoteFocusIsTreatedAsTheNotes() {
        XCTAssertEqual(ProjectTabView.board(.note).following(workspaceName: nil,
                                                            showingProjectNoteAlone: true),
                       .notes)
    }

    /// Naming outranks the note rule: you asked for a workspace, so you get one.
    func testNamingTheOneCardViewMakesItThatWorkspace() {
        XCTAssertEqual(ProjectTabView.notes.following(workspaceName: "Reading",
                                                      showingProjectNoteAlone: true),
                       .board(.workspace("Reading")))
    }

    func testABoardThatBecomesANamedWorkspaceFollowsIt() {
        XCTAssertEqual(ProjectTabView.board(.whole).following(workspaceName: "Dashboard",
                                                             showingProjectNoteAlone: false),
                       .board(.workspace("Dashboard")))
    }

    /// A frame is somewhere that exists whatever is tiled, so tiling its cards down to the project's
    /// own card must not quietly turn the tab into the notes.
    func testAFrameTabIsNotDraggedOffItsFrameByWhatIsTiled() {
        XCTAssertNil(ProjectTabView.board(.frame("n1")).following(workspaceName: nil,
                                                                  showingProjectNoteAlone: true))
    }

    func testAFrameTabStillFollowsANameItIsGiven() {
        XCTAssertEqual(ProjectTabView.board(.frame("n1")).following(workspaceName: "Sprint",
                                                                    showingProjectNoteAlone: false),
                       .board(.workspace("Sprint")))
    }

    /// Same argument as the frame: a name points at something that outlives the tiling on screen.
    func testANamedWorkspaceIsNotDraggedOffItsNameByWhatIsTiled() {
        XCTAssertNil(ProjectTabView.board(.workspace("Dashboard"))
            .following(workspaceName: "Dashboard", showingProjectNoteAlone: true))
    }

    func testAWorkspaceLeftBehindLandsOnTheBoard() {
        XCTAssertEqual(ProjectTabView.board(.workspace("Dashboard"))
            .following(workspaceName: nil, showingProjectNoteAlone: false),
                       .board(.whole))
    }

    func testAWorkspaceRenamedUnderneathATabIsFollowed() {
        XCTAssertEqual(ProjectTabView.board(.workspace("Old"))
            .following(workspaceName: "New", showingProjectNoteAlone: false),
                       .board(.workspace("New")))
    }
}

/// The row of tabs a project opens with.
///
/// **The row is the project's workspaces, not only the ones the window was left holding.** A tab is
/// where an *open* workspace lives (docs/canvas-workspaces.md §7c), which was the whole story while a
/// workspace could only be reached by making one, and the wrong story on the way in: one you built and
/// then zoomed out of has no chip, so opening the project showed you none of the work you named.
final class TabsIncludeTheProjectsWorkspacesTests: XCTestCase {
    func testAWorkspaceWithNoTabGetsOne() {
        var tabs = ProjectTabSet(.notes)
        tabs.include(workspaces: ["Dashboard", "Research"])
        XCTAssertEqual(tabs.tabs.map(\.view),
                       [.notes, .board(.workspace("Dashboard")), .board(.workspace("Research"))])
    }

    /// The row can be dragged into an order and that order is the user's, so newcomers land after it
    /// rather than being sorted into it.
    func testAnExistingRowKeepsItsOrder() {
        var tabs = ProjectTabSet(.board(.workspace("Research")))
        tabs.open(.notes)
        tabs.include(workspaces: ["Alpha", "Research"])
        XCTAssertEqual(tabs.tabs.map(\.view),
                       [.board(.workspace("Research")), .notes, .board(.workspace("Alpha"))])
    }

    /// Two chips on one workspace are two names for one thing (§7c), so a workspace that already has a
    /// tab does not get a second — whichever tab it is, and however the row is ordered.
    func testAWorkspaceThatAlreadyHasATabGetsNoSecondOne() {
        var tabs = ProjectTabSet(.board(.workspace("Dashboard")))
        tabs.include(workspaces: ["Dashboard"])
        XCTAssertEqual(tabs.tabs.count, 1)
    }

    /// The point of the recency: the tab you left selected can be the whole board — leaving a tiled
    /// view un-pins the tab from its workspace — so "which workspace was I in" has to be asked of the
    /// workspace store rather than of the selection.
    func testTheMostRecentWorkspaceIsTheOneSelected() {
        var tabs = ProjectTabSet(.board(.whole))
        tabs.include(workspaces: ["Alpha", "Dashboard"], selecting: "Dashboard")
        XCTAssertEqual(tabs.selected.view, .board(.workspace("Dashboard")))
    }

    /// A name that is not on the row — deleted in another window between the two reads — leaves the
    /// stored selection alone rather than landing on whatever happens to be first.
    func testAnUnknownRecentWorkspaceLeavesTheSelectionAlone() {
        var tabs = ProjectTabSet(.notes)
        let was = tabs.selectedID
        tabs.include(workspaces: ["Alpha"], selecting: "Deleted")
        XCTAssertEqual(tabs.selectedID, was)
    }

    /// Nothing named, nothing added: a project with no workspaces opens exactly as it always has.
    func testNoWorkspacesChangesNothing() {
        var tabs = ProjectTabSet(.notes)
        tabs.include(workspaces: [])
        XCTAssertEqual(tabs.tabs.map(\.view), [.notes])
        XCTAssertFalse(tabs.showsBar)
    }

    /// `openBehind` aimed at a named tab rather than at the one that is up — what a pane leaving a
    /// workspace uses when you are looking at a different tab.
    func testOpenBehindANamedTabLandsInFrontOfIt() {
        var tabs = ProjectTabSet(.notes)
        let second = tabs.open(.board(.whole))
        tabs.select(tabs.tabs[0].id)
        tabs.openBehind(.board(.workspace("Dashboard")), of: second.id)
        XCTAssertEqual(tabs.tabs.map(\.view),
                       [.notes, .board(.workspace("Dashboard")), .board(.whole)])
    }
}
