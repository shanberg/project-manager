import XCTest

/// The name Duplicate offers, which is the only part of the prompt that has a rule.
final class WorkspaceNameTests: XCTestCase {

    func testTheFirstCopyIsJustCopy() {
        XCTAssertEqual(WorkspaceNamePrompt.copyName(of: "Dashboard", avoiding: ["Dashboard"]),
                       "Dashboard copy")
    }

    /// The second duplicate must not offer a name that is already taken — a workspace's name is its
    /// whole identity, so saving over one is losing it, and the prompt should never be the thing that
    /// suggests doing that.
    func testASecondCopyCountsPastTheOnesThatExist() {
        let taken = ["Dashboard", "Dashboard copy"]
        XCTAssertEqual(WorkspaceNamePrompt.copyName(of: "Dashboard", avoiding: taken),
                       "Dashboard copy 2")
        XCTAssertEqual(WorkspaceNamePrompt.copyName(of: "Dashboard",
                                                    avoiding: taken + ["Dashboard copy 2"]),
                       "Dashboard copy 3")
    }

    /// Duplicating a duplicate reads as one, rather than becoming "Dashboard copy copy".
    func testDuplicatingACopyKeepsCounting() {
        XCTAssertEqual(
            WorkspaceNamePrompt.copyName(of: "Dashboard copy",
                                         avoiding: ["Dashboard", "Dashboard copy"]),
            "Dashboard copy copy",
            "the honest answer, and the Finder's: the name being copied is the whole name")
    }

    /// A gap in the run is filled rather than skipped past, so the numbers stay the count of what
    /// exists rather than a high-water mark.
    func testAGapIsFilled() {
        XCTAssertEqual(
            WorkspaceNamePrompt.copyName(of: "Dashboard",
                                         avoiding: ["Dashboard copy", "Dashboard copy 3"]),
            "Dashboard copy 2")
    }
}

/// The name a workspace is born with — see `WorkspaceNamePrompt.freshName(avoiding:)`.
final class WorkspaceFreshNameTests: XCTestCase {
    func testTheFirstOneIsJustTheWord() {
        XCTAssertEqual(WorkspaceNamePrompt.freshName(avoiding: []), "Workspace")
    }

    /// Counted past the ones that exist, so ⌘Return never has to ask and never collides.
    func testItCountsPastWhatIsTaken() {
        XCTAssertEqual(WorkspaceNamePrompt.freshName(avoiding: ["Workspace"]), "Workspace 2")
        XCTAssertEqual(WorkspaceNamePrompt.freshName(avoiding: ["Workspace", "Workspace 2"]),
                       "Workspace 3")
    }

    /// The first free number rather than one past the highest, so a row you have been renaming out of
    /// does not climb forever.
    func testItTakesTheFirstFreeNumber() {
        XCTAssertEqual(WorkspaceNamePrompt.freshName(avoiding: ["Workspace", "Workspace 3"]),
                       "Workspace 2")
    }
}

/// The contextual menu's Workspaces submenu — see `CanvasWorkspaces.names(holdingAnyOf:in:)`.
final class WorkspacesHoldingCardsTests: XCTestCase {
    private func tiling(_ ids: [String]) -> CanvasViewState.Tiling {
        CanvasViewState.Tiling(ids: ids, arrangement: .masterStack, masterFraction: 0.5, sizes: nil)
    }

    /// Any of the cards, not all of them: a workspace holding two of three is an answer to "where
    /// else do these live". Listed in menu order, and the ones holding none are left out.
    func testWorkspacesHoldingAnyOfTheCardsAreListedInMenuOrder() {
        let all = ["Zeta": tiling(["a", "b"]), "alpha": tiling(["c"]),
                   "Beta": tiling(["x", "y"]), "Gamma 10": tiling(["b"]), "Gamma 2": tiling(["a"])]
        XCTAssertEqual(CanvasWorkspaces.names(holdingAnyOf: ["a", "b", "c"], in: all),
                       ["alpha", "Gamma 2", "Gamma 10", "Zeta"])
    }

    func testNoCardsHoldNoWorkspaces() {
        XCTAssertEqual(CanvasWorkspaces.names(holdingAnyOf: [], in: ["A": tiling(["a"])]), [])
    }
}
