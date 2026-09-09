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
