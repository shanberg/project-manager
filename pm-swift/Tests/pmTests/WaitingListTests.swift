import XCTest
@testable import PmLib

/// Grouping is pure — it takes rows and a resolution map — so every case here is stated as both.
final class WaitingListTests: XCTestCase {

    /// A stand-in for whatever a caller's row type is: the grouping only ever asks for the target.
    private struct Row: Equatable {
        let id: String
        let waiting: String
    }

    private func group(_ rows: [Row], _ resolutions: [String: WaitTarget]) -> [WaitingGroup<Row>] {
        waitingGroups(rows, target: \.waiting, resolutions: resolutions)
    }

    /// Two spellings of one project are one thing to wait on, so they make one group. This is the
    /// grouping's whole reason to key on the resolved folder rather than on the text.
    func testSpellingsOfOneProjectMerge() {
        let rows = [Row(id: "a", waiting: "W-1"),
                    Row(id: "b", waiting: "Website Refresh"),
                    Row(id: "c", waiting: "W-1 Website Refresh")]
        let out = group(rows, ["W-1": .pending(folder: "W-1 Website Refresh"),
                               "Website Refresh": .pending(folder: "W-1 Website Refresh"),
                               "W-1 Website Refresh": .pending(folder: "W-1 Website Refresh")])
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].tasks.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(out[0].key, "W-1 Website Refresh")
    }

    /// The group is called what the project is called *now*, whatever the token says — the reader
    /// never learns that the folder was renamed.
    func testGroupTitleIsTheResolvedTitle() {
        let out = group([Row(id: "a", waiting: "W-1 Website Refresh")],
                        ["W-1 Website Refresh": .pending(folder: "W-1 Site Refresh")])
        XCTAssertEqual(out[0].title, "Site Refresh")
        XCTAssertEqual(out[0].target, "W-1 Website Refresh")
    }

    /// An unresolved target is displayed as written, because that is all anyone knows about it.
    func testUnresolvedTitleIsTheTargetAsWritten() {
        let out = group([Row(id: "a", waiting: "Dana")], [:])
        XCTAssertEqual(out[0].title, "Dana")
        XCTAssertEqual(out[0].resolution, .unresolved)
    }

    /// Two people with the same name in different cases are one person.
    func testUnresolvedTargetsGroupCaseInsensitively() {
        let out = group([Row(id: "a", waiting: "Dana"), Row(id: "b", waiting: "dana")], [:])
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].tasks.count, 2)
        // The first spelling seen is the one displayed.
        XCTAssertEqual(out[0].target, "Dana")
    }

    /// Released first: it's the only band carrying news. Then pending, then what PM can't place.
    func testReleasedGroupsComeFirst() {
        let rows = [Row(id: "a", waiting: "Dana"),
                    Row(id: "b", waiting: "Live"),
                    Row(id: "c", waiting: "Landed")]
        let out = group(rows, ["Live": .pending(folder: "W-2 Live"),
                               "Landed": .released(folder: "W-1 Landed")])
        XCTAssertEqual(out.map(\.title), ["Landed", "Live", "Dana"])
        XCTAssertTrue(out[0].isReleased)
    }

    /// Within a band, alphabetical by the title shown — so ticking something off doesn't reorder the
    /// list under the reader.
    func testGroupsSortByTitleWithinABand() {
        let rows = [Row(id: "a", waiting: "Zebra"), Row(id: "b", waiting: "apple"),
                    Row(id: "c", waiting: "Mango")]
        XCTAssertEqual(group(rows, [:]).map(\.title), ["apple", "Mango", "Zebra"])
    }

    /// Tasks keep the order they arrived in — the caller decided it, and the grouping doesn't have an
    /// opinion about which of two tasks waiting on one thing comes first.
    func testTaskOrderIsPreserved() {
        let rows = [Row(id: "c", waiting: "Dana"), Row(id: "a", waiting: "Dana"),
                    Row(id: "b", waiting: "Dana")]
        XCTAssertEqual(group(rows, [:])[0].tasks.map(\.id), ["c", "a", "b"])
    }

    /// A target the resolution map never saw is unresolved, not a crash and not a silent drop.
    func testMissingResolutionIsUnresolved() {
        let out = group([Row(id: "a", waiting: "Nobody")], ["Someone": .pending(folder: "W-1 X")])
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].resolution, .unresolved)
    }

    func testEmptyInputMakesNoGroups() {
        XCTAssertTrue(group([], [:]).isEmpty)
    }

    /// The wire spelling of a resolution, which is what an adapter branches on.
    func testStateNames() {
        XCTAssertEqual(WaitTarget.pending(folder: "x").stateName, "pending")
        XCTAssertEqual(WaitTarget.released(folder: "x").stateName, "released")
        XCTAssertEqual(WaitTarget.unresolved.stateName, "unresolved")
    }

    // MARK: The whole walk, against a vault on disk

    /// A parent declaring a wait, two children inheriting it, and the target archived.
    ///
    /// The case that matters for the write side: all three tasks are blocked and belong in the group,
    /// and exactly one of them has a line that can be edited to unblock them. A caller that sent all
    /// three refs to `task.setWaiting` would report three cleared and change one. See
    /// `WaitingModel.stopWaiting`.
    func testBucketsGroupByInheritanceButOnlyOneTaskDeclaresTheWait() throws {
        try withVault { active, archive in
            try write(project: "W-2 Launch", in: active, tasks: """
            - [ ] Ship the release waiting: [[W-1 Website Refresh]]
                - [ ] Write the announcement
                - [ ] Update the changelog
            - [ ] Something unrelated
            """)
            try write(project: "W-1 Website Refresh", in: archive, tasks: "- [x] Land it")

            let buckets = try waitingBuckets()
            XCTAssertEqual(buckets.count, 1)
            let bucket = try XCTUnwrap(buckets.first)
            XCTAssertEqual(bucket.state, "released")
            XCTAssertEqual(bucket.folder, "W-1 Website Refresh")
            // The title comes off the folder, not the token.
            XCTAssertEqual(bucket.title, "Website Refresh")
            XCTAssertEqual(bucket.tasks.count, 3)
            XCTAssertEqual(bucket.tasks.map(\.effectiveWaiting),
                           Array(repeating: "W-1 Website Refresh", count: 3))
            XCTAssertEqual(bucket.tasks.filter { $0.waiting != nil }.map(\.text), ["Ship the release"])
        }
    }

    /// A token written under the old name still finds the project, and the group is called by the new
    /// one — the rename, end to end, through the scan rather than through the matcher alone.
    func testARenamedTargetStillGroupsAndIsCalledByItsNewName() throws {
        try withVault { active, _ in
            try write(project: "W-2 Launch", in: active,
                      tasks: "- [ ] Send the email waiting: [[W-1 Website Refresh]]")
            try write(project: "W-1 Site Refresh", in: active, tasks: "- [ ] Land it")

            let buckets = try waitingBuckets()
            XCTAssertEqual(buckets.count, 1)
            XCTAssertEqual(buckets.first?.title, "Site Refresh")
            XCTAssertEqual(buckets.first?.target, "W-1 Website Refresh")
            XCTAssertEqual(buckets.first?.state, "pending")
        }
    }

    /// Nothing waiting is an empty list, not a failure.
    func testAVaultWithNoWaitsHasNoBuckets() throws {
        try withVault { active, _ in
            try write(project: "W-2 Launch", in: active, tasks: "- [ ] Just do it")
            XCTAssertEqual(try waitingBuckets().count, 0)
        }
    }

    // MARK: Vault plumbing

    /// Run `body` against a throwaway PARA vault, with `PM_CONFIG_HOME` pointed at it.
    private func withVault(_ body: (_ active: URL, _ archive: URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let active = root.appendingPathComponent("Projects")
        let archive = root.appendingPathComponent("Archive")
        let areas = root.appendingPathComponent("Areas")
        for dir in [active, archive, areas] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }

        let saved = ProcessInfo.processInfo.environment["PM_CONFIG_HOME"]
        setenv("PM_CONFIG_HOME", root.path, 1)
        defer {
            if let saved { setenv("PM_CONFIG_HOME", saved, 1) } else { unsetenv("PM_CONFIG_HOME") }
        }
        try saveConfig(PmConfig(activePath: active.path, archivePath: archive.path,
                                areasPath: areas.path, domains: ["W": "Work"],
                                subfolders: ["docs"]))
        try body(active, archive)
    }

    /// Write one project's notes file with a single session holding `tasks`.
    private func write(project folder: String, in root: URL, tasks: String) throws {
        let docs = root.appendingPathComponent(folder).appendingPathComponent("docs")
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        let title = projectTitle(fromFolderName: folder)
        let markdown = """
        # \(title)

        ## Sessions

        ### Wed, Feb 25, 2026

        \(tasks)

        """
        try markdown.write(to: docs.appendingPathComponent("Notes - \(title).md"),
                           atomically: true, encoding: .utf8)
    }
}
