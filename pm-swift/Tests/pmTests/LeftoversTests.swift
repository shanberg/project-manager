import XCTest
import Foundation
@testable import PmLib

/// What's been left open, across projects: which tasks count, where they're said to be, and the order the
/// pile is read in. See docs/views.md D1, D2 and D8.
final class LeftoversTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        calendar.firstWeekday = 1
        return calendar
    }()

    /// Friday the 18th, midday.
    private var now: Date { calendar.date(from: DateComponents(year: 2026, month: 9, day: 18, hour: 12))! }

    private func project(_ markdown: String, before: String? = nil,
                         picked: [String: PickMark] = [:]) throws -> LeftoverProject? {
        let notes = normalizeFocusMarker(notes: try parseNotes(markdown: markdown))
        var todos = try parseTodos(notes: notes)
        for i in todos.indices { todos[i].picked = picked[todos[i].text] }
        return leftovers(projectFolder: "W-1 Redesign", notes: notes, todos: todos,
                         before: try leftoversCutoff(before: before, now: now, calendar: calendar),
                         calendar: calendar)
    }

    private let notes = """
    # Redesign

    ## Sessions

    ### Fri, Sep 18, 2026 9:00 AM

    - [ ] Today's task

    ### Wed, Sep 16, 2026 2:15 PM · Venue

    - [ ] Book the venue
      - [x] Call the first venue
        - [ ] Chase their deposit
      - [ ] Call the second venue

    ### Wed, Sep 16, 2026 9:10 AM

    Came back to the nav.

    - [x] Email Dana
    - [-] Dropped it

    ### Mon, Sep 14, 2026

    #### Nav spec

    - [ ] Draft the nav spec waiting: [[Dana]]

    """

    /// Open tasks in sittings before today, oldest sitting first; a sitting with nothing open isn't
    /// listed, and today's sitting isn't old enough to leave anything in.
    func testOpenTasksInOlderSittingsOldestFirst() throws {
        let redesign = try XCTUnwrap(try project(notes))
        XCTAssertEqual(redesign.sittings.map(\.session), ["2026-09-14", "2026-09-16"])
        XCTAssertEqual(redesign.sittings.flatMap { $0.tasks.map(\.text) },
                       ["Draft the nav spec", "Book the venue", "Chase their deposit", "Call the second venue"])
        XCTAssertEqual(redesign.sittings[0].lede, "Nav spec", "What the sitting was about")
        XCTAssertEqual(redesign.sittings[1].lede, "Venue")
        XCTAssertEqual(redesign.sittings[0].tasks.first?.waiting, "Dana")
    }

    /// A subtask sits under its parent when its parent is listed, and starts a tree of its own when the
    /// parent was finished — it's drawn among what's open, not where a finished line would have been.
    func testDepthCountsOnlyListedAncestors() throws {
        let venue = try XCTUnwrap(try project(notes)?.sittings.last)
        XCTAssertEqual(venue.tasks.map(\.depth), [0, 1, 1])
    }

    /// Each task can be written back to: its ref names the day's *second* sitting when that's where it is.
    func testATaskInADaysSecondSittingIsNamedWhole() throws {
        let venue = try XCTUnwrap(try project(notes, before: "2026-09-17")?.sittings.last)
        XCTAssertEqual(venue.session, "2026-09-16")
        XCTAssertEqual(venue.sessionOrdinal, 0, "2:15 PM is the newer of the day's two, first in the file")
        let book = try XCTUnwrap(venue.tasks.first)
        XCTAssertEqual(book.ref.session, "2026-09-16")
        XCTAssertEqual(book.ref.sessionOrdinal, 0)
        XCTAssertEqual(book.ref.line, 0)
        XCTAssertEqual(book.ref.digest, taskDigest("Book the venue"))
    }

    /// `before`: yesterday leaves out Thursday and after; this week leaves out everything since Sunday; a
    /// date is that day.
    func testBeforeIsTheCutOff() throws {
        XCTAssertEqual(try project(notes, before: "week")?.sittings.map(\.session), nil,
                       "The week began on Sunday the 13th; the 14th is this week")
        XCTAssertEqual(try project(notes, before: "2026-09-15")?.sittings.map(\.session), ["2026-09-14"])
        XCTAssertEqual(try project(notes, before: "yesterday")?.sittings.map(\.session),
                       ["2026-09-14", "2026-09-16"])
        XCTAssertEqual(try leftoversCutoff(before: "week", now: now, calendar: calendar),
                       calendar.date(from: DateComponents(year: 2026, month: 9, day: 13)))
        XCTAssertEqual(try leftoversCutoff(before: "month", now: now, calendar: calendar),
                       calendar.date(from: DateComponents(year: 2026, month: 9, day: 1)), "This calendar month")
        XCTAssertThrowsError(try leftoversCutoff(before: "someday", now: now, calendar: calendar))
    }

    /// A picked-up task is still left over — picking up isn't finishing — and says where it went.
    func testAPickedUpTaskIsStillListedWithItsPick() throws {
        let mark = PickMark(into: "2026-09-18", at: "2026-09-18T14:00:00Z")
        let venue = try XCTUnwrap(try project(notes, picked: ["Book the venue": mark])?.sittings.last)
        XCTAssertEqual(venue.tasks.first?.picked, mark)
        XCTAssertNil(venue.tasks.last?.picked)
    }

    /// A project with nothing left isn't in the answer at all.
    func testAProjectWithNothingLeftIsNil() throws {
        XCTAssertNil(try project("""
        # Done

        ## Sessions

        ### Mon, Sep 14, 2026

        - [x] All of it

        """))
    }

    // MARK: The whole walk, against a vault on disk

    /// Projects by their oldest leftover, with their picks read from the log beside the notes; `projects`
    /// narrows it, and the archive is read only when it's asked for by name.
    func testAcrossTheVault() throws {
        try withVault { active, archive in
            // Picked up into today's sitting, which is too new to leave anything in.
            try write(project: "W-2 Launch", in: active, day: "Fri, Sep 18, 2026",
                      tasks: "- [ ] New today\n\n### Wed, Sep 16, 2026\n\n- [ ] Ship it")
            try write(project: "W-3 Docs", in: active, day: "Mon, Sep 14, 2026", tasks: "- [ ] Proofread")
            try write(project: "W-4 Old", in: archive, day: "Mon, Sep 7, 2026", tasks: "- [ ] Never done")
            let launch = active.appendingPathComponent("W-2 Launch")
            let read = try notesShow(rawText: String(contentsOf: launch.appendingPathComponent("docs/Notes - Launch.md"),
                                                     encoding: .utf8))
            let ship = try XCTUnwrap(read.todos.first { $0.text == "Ship it" })
            try PickLog.append([PickEvent(
                at: "2026-09-18T14:00:00Z", event: .picked,
                task: try XCTUnwrap(PickLog.task(ship, in: read.notes)),
                into: try XCTUnwrap(PickLog.sitting(at: 0, in: read.notes)))], projectPath: launch.path)

            let list = try leftoverTasks(now: now, calendar: calendar)
            XCTAssertEqual(list.projects.map(\.projectFolder), ["W-3 Docs", "W-2 Launch"],
                           "Oldest first, and the archive left out")
            let picked = list.projects.last?.sittings.first?.tasks.first
            XCTAssertEqual(picked?.text, "Ship it")
            XCTAssertEqual(picked?.picked?.into, "2026-09-18", "Its last pick-up, from the pick log")

            XCTAssertEqual(try leftoverTasks(projects: ["W-2"], now: now, calendar: calendar)
                            .projects.map(\.projectFolder), ["W-2 Launch"])
            XCTAssertEqual(try leftoverTasks(projects: ["W-4"], now: now, calendar: calendar)
                            .projects.map(\.projectFolder), ["W-4 Old"])
            XCTAssertEqual(list.taskCount, 2)
            XCTAssertEqual(list.sittingCount, 2)
        }
    }

    // MARK: Vault plumbing

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

    private func write(project folder: String, in root: URL, day: String, tasks: String) throws {
        let docs = root.appendingPathComponent(folder).appendingPathComponent("docs")
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        let title = projectTitle(fromFolderName: folder)
        let markdown = """
        # \(title)

        ## Sessions

        ### \(day)

        \(tasks)

        """
        try markdown.write(to: docs.appendingPathComponent("Notes - \(title).md"),
                           atomically: true, encoding: .utf8)
    }
}
