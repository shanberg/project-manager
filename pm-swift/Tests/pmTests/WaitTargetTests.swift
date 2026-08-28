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

    /// A bare code, the way the CLI has always let you name a project.
    func testResolvesByCode() {
        let r = roots(active: ["W-1 Website Refresh", "H-4 Kitchen"])
        XCTAssertEqual(resolveWaitTarget("W-1", roots: r), .pending(folder: "W-1 Website Refresh"))
    }

    /// **The rename case.** The token still says what the folder was called when it was written, and
    /// the folder has since been retitled — so folder-name and title matching both miss, and only the
    /// code the two names still share can carry it. This is the whole reason the code rule exists.
    func testRenamedProjectStillResolves() {
        let r = roots(active: ["W-1 Site Refresh"])
        XCTAssertEqual(resolveWaitTarget("W-1 Website Refresh", roots: r),
                       .pending(folder: "W-1 Site Refresh"))
    }

    /// A code is the whole token or none of it: `W-1` must not answer for `W-10`. The prefix rule this
    /// replaced could not tell these two apart and called the pair ambiguous.
    func testCodeDoesNotMatchALongerNumber() {
        let r = roots(active: ["W-1 Site", "W-10 Site Redesign"])
        XCTAssertEqual(resolveWaitTarget("W-1", roots: r), .pending(folder: "W-1 Site"))
        XCTAssertEqual(resolveWaitTarget("W-10", roots: r), .pending(folder: "W-10 Site Redesign"))
    }

    /// Two folders carrying one code — a copied folder, a hand-made duplicate — name nothing, for the
    /// same reason two matching titles do.
    func testDuplicateCodesAreUnresolved() {
        let r = roots(active: ["W-1 Site", "W-1 Site copy"])
        XCTAssertEqual(resolveWaitTarget("W-1 Site Refresh", roots: r), .unresolved)
    }

    /// A code PM has never issued isn't a near-miss to be repaired — it names nothing.
    func testUnknownCodeIsUnresolved() {
        let r = roots(active: ["W-1 Site"])
        XCTAssertEqual(resolveWaitTarget("W-9 Something", roots: r), .unresolved)
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

    /// The name-prefix rule is the fallback for folders carrying no code, and an ambiguous prefix
    /// tells the reader nothing, so it says nothing.
    func testAmbiguousPrefixIsUnresolved() {
        let r = roots(areas: ["Team Standups", "Team Standups (old)"])
        XCTAssertEqual(resolveWaitTarget("Team", roots: r), .unresolved)
    }

    /// A whole title beats a code: a folder actually titled "W-1" isn't shadowed by the code rule.
    func testTitleBeatsCode() {
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

    // MARK: The code a name carries

    func testProjectCodeReadsTheCode() {
        XCTAssertEqual(projectCode(fromName: "W-1 Website Refresh"), "W-1")
        XCTAssertEqual(projectCode(fromName: "W-1"), "W-1")
        XCTAssertEqual(projectCode(fromName: "  W-1  "), "W-1")
        XCTAssertEqual(projectCode(fromName: "H-004 Maxwell Carmody"), "H-004")
    }

    /// The lookahead: a code ends at a space or at the end, so `W-1` is never read out of `W-12`.
    func testProjectCodeStopsAtTheWholeToken() {
        XCTAssertEqual(projectCode(fromName: "W-12 Thing"), "W-12")
        XCTAssertNil(projectCode(fromName: "W-1x Thing"))
    }

    /// An area carries none, which is what makes it an area.
    func testProjectCodeIsNilWithoutOne() {
        XCTAssertNil(projectCode(fromName: "Team 1:1s"))
        XCTAssertNil(projectCode(fromName: "Dana"))
        XCTAssertNil(projectCode(fromName: ""))
    }
}
