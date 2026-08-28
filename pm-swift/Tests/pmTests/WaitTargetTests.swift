import XCTest
@testable import PmLib

/// Resolution is pure — it takes folder lists, not a disk — so every case here is stated as folders.
final class WaitTargetTests: XCTestCase {

    private func roots(active: [String] = [], areas: [String] = [], archive: [String] = [])
        -> [(scope: ProjectScope, folders: [String])] {
        [(.active, active), (.areas, areas), (.archive, archive)]
    }

    /// The title alone is the form a person writes, and the form the app offers.
    func testResolvesByTitle() {
        let r = roots(active: ["W-1 Website Refresh", "H-4 Kitchen"])
        XCTAssertEqual(resolveWaitTarget("Website Refresh", roots: r), .pending(folder: "W-1 Website Refresh"))
    }

    /// The full folder name resolves too — that's what the app writes when it fills the token in.
    func testResolvesByFolderName() {
        let r = roots(active: ["W-1 Website Refresh"])
        XCTAssertEqual(resolveWaitTarget("W-1 Website Refresh", roots: r),
                       .pending(folder: "W-1 Website Refresh"))
    }

    /// An unambiguous code prefix, the way the CLI has always let you name a project.
    func testResolvesByCodePrefix() {
        let r = roots(active: ["W-1 Website Refresh", "H-4 Kitchen"])
        XCTAssertEqual(resolveWaitTarget("W-1", roots: r), .pending(folder: "W-1 Website Refresh"))
    }

    /// Names are typed into sentences, so case doesn't decide the answer.
    func testResolvesCaseInsensitively() {
        let r = roots(active: ["W-1 Website Refresh"])
        XCTAssertEqual(resolveWaitTarget("website refresh", roots: r),
                       .pending(folder: "W-1 Website Refresh"))
    }

    /// An area has no code, so it resolves by its name alone.
    func testResolvesArea() {
        let r = roots(active: ["W-1 Site"], areas: ["Team 1:1s"])
        XCTAssertEqual(resolveWaitTarget("Team 1:1s", roots: r), .pending(folder: "Team 1:1s"))
    }

    /// Archived means the thing being waited on has landed.
    func testArchivedTargetIsReleased() {
        let r = roots(active: ["W-2 Launch"], archive: ["W-1 Website Refresh"])
        XCTAssertEqual(resolveWaitTarget("Website Refresh", roots: r),
                       .released(folder: "W-1 Website Refresh"))
        XCTAssertTrue(resolveWaitTarget("Website Refresh", roots: r).isReleased)
    }

    /// A project unarchived back into active reads as live again — active wins over archive, which is
    /// the point of the root order rather than a tiebreak.
    func testActiveWinsOverArchive() {
        let r = roots(active: ["W-1 Website Refresh"], archive: ["W-1 Website Refresh"])
        XCTAssertEqual(resolveWaitTarget("W-1 Website Refresh", roots: r),
                       .pending(folder: "W-1 Website Refresh"))
    }

    /// A person is not a project, and that is not a failure.
    func testUnknownNameIsUnresolved() {
        let r = roots(active: ["W-1 Website Refresh"])
        XCTAssertEqual(resolveWaitTarget("Dana", roots: r), .unresolved)
        XCTAssertNil(resolveWaitTarget("Dana", roots: r).folder)
    }

    /// A prefix that could mean two projects tells the reader nothing, so it says nothing.
    func testAmbiguousPrefixIsUnresolved() {
        let r = roots(active: ["W-1 Site", "W-10 Site Redesign"])
        XCTAssertEqual(resolveWaitTarget("W-1", roots: r), .unresolved)
    }

    /// A whole title beats a prefix: a folder actually titled "W-1" isn't shadowed by the prefix rule.
    func testTitleBeatsPrefix() {
        let r = roots(active: ["P-3 W-1", "W-1 Website Refresh"])
        XCTAssertEqual(resolveWaitTarget("W-1", roots: r), .pending(folder: "P-3 W-1"))
    }

    /// Two projects sharing a title can't be told apart, so neither is claimed.
    func testDuplicateTitlesAreUnresolved() {
        let r = roots(active: ["W-1 Refresh", "H-2 Refresh"])
        XCTAssertEqual(resolveWaitTarget("Refresh", roots: r), .unresolved)
    }

    /// The batch form answers each distinct target once.
    func testBatchResolution() {
        let r = roots(active: ["W-1 Website Refresh"], archive: ["H-2 Old Thing"])
        let out = resolveWaitTargets(["Website Refresh", "Old Thing", "Dana", "Website Refresh"], roots: r)
        XCTAssertEqual(out.count, 3)
        XCTAssertEqual(out["Website Refresh"], .pending(folder: "W-1 Website Refresh"))
        XCTAssertEqual(out["Old Thing"], .released(folder: "H-2 Old Thing"))
        XCTAssertEqual(out["Dana"], .unresolved)
    }

    /// An empty or whitespace target names nothing.
    func testEmptyTargetIsUnresolved() {
        let r = roots(active: ["W-1 Website Refresh"])
        XCTAssertEqual(resolveWaitTarget("   ", roots: r), .unresolved)
    }
}
