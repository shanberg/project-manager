import XCTest

/// What a window's tabs do when you open, close, reorder and cycle them.
///
/// The interesting parts are all about the selection, which is the thing a user notices when it is
/// wrong: closing the tab you are looking at has to land you somewhere sensible, and a set rebuilt
/// from storage that no longer agrees with itself has to be repaired rather than shown.
final class ProjectTabTests: XCTestCase {

    /// A window nobody has given tabs is the canvas and the notes, with the notes up — the window this
    /// app has always shown, plus the board it has always been showing it out of.
    func testStartsOnTheNotesWithTheCanvasBehindIt() {
        let set = ProjectTabSet()
        XCTAssertEqual(set.tabs.map(\.view), [.board(.whole), .notes])
        XCTAssertEqual(set.selected.view, .notes)
        XCTAssertEqual(set.canvasID, set.tabs[0].id)
        XCTAssertTrue(set.showsBar)
    }

    /// Asked for the canvas alone, that is the whole row — there is no second tab to make, because the
    /// canvas is the one that was already there.
    func testTheCanvasSeedIsNotOpenedTwice() {
        let set = ProjectTabSet(.board(.whole))
        XCTAssertEqual(set.tabs.map(\.view), [.board(.whole)])
        XCTAssertFalse(set.showsBar)
    }

    /// Opened next to the tab it came from, not at the end of the row — a frame opened from its board
    /// belongs beside that board.
    func testOpensAfterTheCurrentTabAndSelectsIt() {
        var set = ProjectTabSet()
        let workspace = set.open(.board(.workspace("Review")))
        let frame = set.open(.board(.frame("group-1")))
        XCTAssertEqual(set.tabs.map(\.id),
                       [set.canvasID, set.tabs[1].id, workspace.id, frame.id])
        XCTAssertEqual(set.selectedID, frame.id)

        // Going back to the canvas and opening again puts the new one second, not last.
        set.select(set.canvasID)
        let another = set.open(.board(.workspace("Standup")))
        XCTAssertEqual(set.tabs[1].id, another.id)
    }

    /// Closing the tab you are on goes right — the direction you were travelling.
    func testClosingTheSelectedTabSelectsTheOneToItsRight() {
        var set = ProjectTabSet()
        let notes = set.tabs[1].id
        let frame = set.open(.board(.frame("g")))
        set.select(notes)

        XCTAssertTrue(set.close(notes))
        XCTAssertEqual(set.selectedID, frame.id)
    }

    /// Except at the end of the row, where there is nothing to the right.
    func testClosingTheLastTabInTheRowFallsBackToTheLeft() {
        var set = ProjectTabSet()
        let notes = set.tabs[1].id
        let frame = set.open(.board(.frame("g")))
        XCTAssertEqual(set.selectedID, frame.id)

        XCTAssertTrue(set.close(frame.id))
        XCTAssertEqual(set.selectedID, notes)
    }

    /// Closing one you are not looking at leaves you where you are.
    func testClosingAnotherTabKeepsTheSelection() {
        var set = ProjectTabSet()
        let notes = set.tabs[1].id
        let frame = set.open(.board(.frame("g")))

        XCTAssertTrue(set.close(notes))
        XCTAssertEqual(set.selectedID, frame.id)
        XCTAssertEqual(set.tabs.map(\.view), [.board(.whole), .board(.frame("g"))])
    }

    /// **The canvas never closes.** It is the view every other tab is a narrowing of, so a window
    /// without it is a window with no way back to its own board.
    func testTheCanvasWillNotClose() {
        var set = ProjectTabSet()
        XCTAssertFalse(set.close(set.canvasID))
        XCTAssertEqual(set.tabs.count, 2)
    }

    /// **And neither does a workspace.** A workspace's chip is the workspace (§7i) — closing one would
    /// leave a named thing in the store with nowhere to be, and the row would put the chip straight
    /// back. Delete is the verb that removes one, and it removes both.
    func testAWorkspaceWillNotClose() {
        var set = ProjectTabSet()
        let dashboard = set.open(.board(.workspace("Dashboard")))
        XCTAssertFalse(set.close(dashboard.id))
        XCTAssertFalse(set.closable(dashboard))
        XCTAssertTrue(set.closable(set.tabs[1]), "the notes close")
    }

    /// ⌃⇥ wraps in both directions.
    func testCyclingWraps() {
        var set = ProjectTabSet()
        let canvas = set.canvasID
        let notes = set.tabs[1].id
        let frame = set.open(.board(.frame("g")))
        set.select(canvas)

        set.selectNext()
        XCTAssertEqual(set.selectedID, notes)
        set.selectNext()
        XCTAssertEqual(set.selectedID, frame.id)
        set.selectNext()
        XCTAssertEqual(set.selectedID, canvas)

        set.selectNext(by: -1)
        XCTAssertEqual(set.selectedID, frame.id)
    }

    /// A drag along the bar reorders without changing what you are looking at.
    func testMovingATabKeepsTheSelection() {
        var set = ProjectTabSet()
        let notes = set.tabs[1].id
        let frame = set.open(.board(.frame("g")))
        set.select(notes)

        set.move(frame.id, to: 1)
        XCTAssertEqual(set.tabs.map(\.id), [set.canvasID, frame.id, notes])
        XCTAssertEqual(set.selectedID, notes)
    }

    /// **The canvas is the row's fixed point.** It cannot be dragged out of first place, and nothing
    /// can be dropped in front of it — a row whose fixed point moves is a row with two firsts.
    func testTheCanvasHoldsItsPlaceAtBothEnds() {
        var set = ProjectTabSet()
        let canvas = set.canvasID
        let notes = set.tabs[1].id

        set.move(canvas, to: 1)
        XCTAssertEqual(set.tabs.map(\.id), [canvas, notes])

        set.move(notes, to: 0)
        XCTAssertEqual(set.tabs.map(\.id), [canvas, notes])
    }

    /// Storage that no longer agrees with itself is repaired rather than trusted.
    func testARebuiltSetRepairsItself() {
        let orphan = ProjectTabSet(tabs: [], selectedID: "gone")
        XCTAssertEqual(orphan.tabs.map(\.view), [.board(.whole)])

        let tab = ProjectTab(.notes)
        let dangling = ProjectTabSet(tabs: [tab], selectedID: "not-here")
        XCTAssertEqual(dangling.selectedID, dangling.canvasID)
    }

    /// **A row written before the canvas was permanent still opens.** It has no canvas tab, or it has
    /// one somewhere in the middle; either way it comes back with exactly one, first, and the tab you
    /// were on is still the tab you were on.
    func testAnOldRowIsGivenItsCanvas() {
        let notes = ProjectTab(.notes)
        let seeded = ProjectTabSet(tabs: [notes], selectedID: notes.id)
        XCTAssertEqual(seeded.tabs.map(\.view), [.board(.whole), .notes])
        XCTAssertEqual(seeded.selectedID, notes.id)

        let board = ProjectTab(.board(.whole))
        let middle = ProjectTabSet(tabs: [notes, board], selectedID: board.id)
        XCTAssertEqual(middle.tabs.map(\.id), [board.id, notes.id])
        XCTAssertEqual(middle.selectedID, board.id, "still looking at the board")
    }

    /// Two canvases in a stored row are two names for one thing, so the second is dropped.
    func testASecondCanvasIsNotKept() {
        let one = ProjectTab(.board(.whole))
        let two = ProjectTab(.board(.whole))
        let set = ProjectTabSet(tabs: [one, two], selectedID: one.id)
        XCTAssertEqual(set.tabs.map(\.id), [one.id])
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

    /// A rename is the one act that changes what a chip points at without moving the chip. The row and
    /// the selection are untouched — one chip changed what it says.
    func testRetargetingATabLeavesTheRowAlone() {
        var set = ProjectTabSet()
        let workspace = set.open(.board(.workspace("Review")))
        let frame = set.open(.board(.frame("group-1")))
        set.select(workspace.id)
        set.retarget(workspace.id, to: .board(.workspace("Dashboard")))
        XCTAssertEqual(set.tabs.map(\.view),
                       [.board(.whole), .notes, .board(.workspace("Dashboard")),
                        .board(.frame("group-1"))])
        XCTAssertEqual(set.selectedID, workspace.id)
        XCTAssertEqual(set.tabs[3].id, frame.id)
    }

    /// An id that is not in the row is a tab that was closed while something was deciding what to do
    /// about it — silence rather than a crash, and rather than retargeting some other tab.
    func testRetargetingAnUnknownTabDoesNothing() {
        var set = ProjectTabSet()
        set.retarget("gone", to: .board(.workspace("Dashboard")))
        XCTAssertEqual(set.tabs.map(\.view), [.board(.whole), .notes])
    }
}

// MARK: - The row is the project's workspaces

/// **A workspace is a chip and a chip is a workspace** (docs/canvas-workspaces.md §7i).
///
/// §7g made the row a view of what exists rather than of what the window was left holding, and kept a
/// list of the ones you had closed so a close would outlast the session. Once every workspace has a
/// name and no workspace can be closed, there is nothing left for that list to record: the row is the
/// store, in your order, and Delete is what takes something out of both.
final class TabsAreTheProjectsWorkspacesTests: XCTestCase {
    func testAWorkspaceWithNoTabGetsOne() {
        var tabs = ProjectTabSet()
        tabs.include(workspaces: ["Dashboard", "Research"])
        XCTAssertEqual(tabs.tabs.map(\.view),
                       [.board(.whole), .notes,
                        .board(.workspace("Dashboard")), .board(.workspace("Research"))])
    }

    /// The row can be dragged into an order and that order is the user's, so newcomers land after it
    /// rather than being sorted into it.
    func testAnExistingRowKeepsItsOrder() {
        var tabs = ProjectTabSet(.board(.workspace("Research")))
        tabs.include(workspaces: ["Alpha", "Research"])
        XCTAssertEqual(tabs.tabs.map(\.view),
                       [.board(.whole), .board(.workspace("Research")), .board(.workspace("Alpha"))])
    }

    /// Two chips on one workspace are two names for one thing (§7c), so a workspace that already has a
    /// tab does not get a second — whichever tab it is, and however the row is ordered.
    func testAWorkspaceThatAlreadyHasATabGetsNoSecondOne() {
        var tabs = ProjectTabSet(.board(.workspace("Dashboard")))
        tabs.include(workspaces: ["Dashboard"])
        XCTAssertEqual(tabs.tabs.count, 2)
    }

    /// **Seeding the row never moves the selection.** It used to take a "last used" name and go there,
    /// on the grounds that leaving a tiled view un-pinned the tab so the selection could not say which
    /// workspace you were in. Nothing un-pins a tab now — see docs/canvas-workspaces.md §7h and §7i.
    func testSeedingLeavesTheSelectionWhereItWas() {
        var tabs = ProjectTabSet(.board(.whole))
        let was = tabs.selectedID
        tabs.include(workspaces: ["Alpha", "Dashboard"])
        XCTAssertEqual(tabs.selectedID, was)
        XCTAssertEqual(tabs.selected.view, .board(.whole))
    }

    /// **A workspace deleted somewhere else loses its chip here.** The row is the list of workspaces,
    /// so a chip pointing at a name nothing answers to is a chip for something that is not there.
    func testAChipForAWorkspaceThatIsGoneIsDropped() {
        var tabs = ProjectTabSet()
        tabs.include(workspaces: ["Alpha", "Dashboard"])
        tabs.include(workspaces: ["Dashboard"])
        XCTAssertEqual(tabs.tabs.map(\.view),
                       [.board(.whole), .notes, .board(.workspace("Dashboard"))])
    }

    /// And you land somewhere sensible when the chip that went was the one you were on.
    func testLosingTheSelectedChipLandsOnItsNeighbour() {
        var tabs = ProjectTabSet(.board(.whole))
        tabs.include(workspaces: ["Alpha", "Dashboard"])
        tabs.select(tabs.first(showing: .board(.workspace("Alpha")))!.id)
        tabs.include(workspaces: ["Dashboard"])
        XCTAssertEqual(tabs.selected.view, .board(.workspace("Dashboard")))
    }

    /// Nothing named, nothing added: a project with no workspaces opens as the canvas and its notes.
    func testNoWorkspacesChangesNothing() {
        var tabs = ProjectTabSet()
        tabs.include(workspaces: [])
        XCTAssertEqual(tabs.tabs.map(\.view), [.board(.whole), .notes])
    }
}

/// **Two chips on one thing are two names for it** (docs/canvas-workspaces.md §7c), which `openTab`
/// has always refused to make and a rename could not: renaming onto a name that already has a chip
/// makes a pair after the fact.
final class TabsCollapseDuplicatesTests: XCTestCase {
    func testAPairOnOneViewBecomesOne() {
        var tabs = ProjectTabSet(.board(.workspace("Dashboard")))
        let second = tabs.open(.board(.workspace("Review")))
        tabs.retarget(second.id, to: .board(.workspace("Dashboard")))
        XCTAssertEqual(tabs.collapseDuplicates(), [second.id])
        XCTAssertEqual(tabs.tabs.map(\.view), [.board(.whole), .board(.workspace("Dashboard"))])
    }

    /// The leftmost survives, because the row has an order and it is the user's.
    func testTheChipThatWasAlreadyThereIsTheOneThatStays() {
        var tabs = ProjectTabSet(.board(.workspace("Dashboard")))
        let first = tabs.tabs[1].id
        let second = tabs.open(.board(.workspace("Review")))
        tabs.retarget(second.id, to: .board(.workspace("Dashboard")))
        tabs.collapseDuplicates()
        XCTAssertEqual(tabs.tabs.map(\.id), [tabs.canvasID, first])
    }

    /// A selection on the chip that goes moves to the one that stays, so the window is still showing
    /// what it was showing.
    func testTheSelectionFollowsTheSurvivor() {
        var tabs = ProjectTabSet(.board(.workspace("Dashboard")))
        let first = tabs.tabs[1].id
        let second = tabs.open(.board(.workspace("Review")))
        tabs.retarget(second.id, to: .board(.workspace("Dashboard")))
        tabs.collapseDuplicates()
        XCTAssertEqual(tabs.selectedID, first)
        XCTAssertEqual(tabs.selected.view, .board(.workspace("Dashboard")))
    }

    func testARowWithNoDuplicatesIsLeftAlone() {
        var tabs = ProjectTabSet()
        tabs.open(.board(.workspace("Dashboard")))
        XCTAssertEqual(tabs.collapseDuplicates(), [])
        XCTAssertEqual(tabs.tabs.count, 3)
    }
}

/// ⌘1…⌘9 — see `ProjectWindowController.selectProjectTabByIndex`. ⌘1 is the canvas, always, which is
/// the one thing about this row that never has to be looked up.
final class TabsSelectByIndexTests: XCTestCase {
    func testAPositionSelectsThatTab() {
        var tabs = ProjectTabSet()
        tabs.open(.board(.workspace("Dashboard")))
        tabs.select(at: 0)
        XCTAssertEqual(tabs.selected.view, .board(.whole))
        tabs.select(at: 1)
        XCTAssertEqual(tabs.selected.view, .notes)
    }

    /// ⌘9 asks for the last one however many there are, which is what every browser on this Mac does.
    func testPastTheEndIsTheLastTab() {
        var tabs = ProjectTabSet()
        tabs.open(.board(.workspace("Dashboard")))
        tabs.select(at: .max)
        XCTAssertEqual(tabs.selected.view, .board(.workspace("Dashboard")))
    }
}
