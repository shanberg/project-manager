import XCTest
import Foundation
@testable import PmLib

/// Coming up (`task.due`), Projects (`project.list`'s activity) and every view's text (docs/views.md D1,
/// D8, D10, build step 7).
final class ViewQueriesTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        return calendar
    }()

    /// Friday the 18th, midday.
    private var now: Date { calendar.date(from: DateComponents(year: 2026, month: 9, day: 18, hour: 12))! }

    private func read(_ markdown: String) throws -> (ProjectNotes, [Todo]) {
        let notes = normalizeFocusMarker(notes: try parseNotes(markdown: markdown))
        return (notes, todosWithEffectiveDueDates(try parseTodos(notes: notes)))
    }

    private func hit(_ todo: Todo, project: String = "W-1 Launch") -> TaskSearchHit {
        TaskSearchHit(projectFolder: project, projectName: projectTitle(fromFolderName: project),
                      projectKey: project, isArchived: false, text: todo.text,
                      due: todo.effectiveDueDate ?? todo.dueDate, waiting: nil, effectiveWaiting: nil,
                      isFocused: false, session: todo.sessionISODate, sessionOrdinal: todo.sessionOrdinal,
                      line: todo.lineIndex, digest: todo.digest)
    }

    private let launch = """
    # Launch

    ## Sessions

    ### Wed, Sep 16, 2026 2:15 PM · Venue

    Settled on the hall.

    - [ ] Book the venue due: 2026-09-22
      - [ ] Pay the deposit
    - [ ] Send the invites due: 2026-09-17
    - [x] Email Dana due: 2026-09-10
    - [ ] Print the menus due: 2026-10-30
    - [ ] Whenever

    """

    // MARK: Coming up

    /// A line that says a date itself, overdue included, soonest first; not a subtask inheriting one, not
    /// a finished task, not past the horizon.
    func testDueListsOwnDatesOverdueFirst() throws {
        let (_, todos) = try read(launch)
        let open = todos.filter { !$0.checked }.map { (hit: hit($0), todo: $0) }
        let week = try dueCutoff(until: nil, now: now, calendar: calendar)
        XCTAssertEqual(dueHits(open, before: week, calendar: calendar).map(\.text),
                       ["Send the invites", "Book the venue"])
        XCTAssertEqual(dueHits(open, before: try dueCutoff(until: "today", now: now, calendar: calendar),
                               calendar: calendar).map(\.text), ["Send the invites"], "overdue is due today too")
        XCTAssertEqual(dueHits(open, before: try dueCutoff(until: "2026-10-30", now: now, calendar: calendar),
                               calendar: calendar).map(\.text),
                       ["Send the invites", "Book the venue", "Print the menus"], "a date is through that day")
    }

    /// `week` rolls: the next seven days, today included — not the calendar's week, which on a Friday
    /// would end tomorrow.
    func testWeekIsTheNextSevenDays() throws {
        XCTAssertEqual(try dueCutoff(until: "week", now: now, calendar: calendar),
                       calendar.date(from: DateComponents(year: 2026, month: 9, day: 25)))
        XCTAssertThrowsError(try dueCutoff(until: "soon", now: now, calendar: calendar))
    }

    // MARK: Projects

    /// Last activity is the later of the newest sitting's start and the notes' last write; with it, the
    /// sitting's lede, what's open and the soonest due.
    func testASummaryCarriesWhatsHappening() throws {
        let (notes, todos) = try read(launch)
        let base = ProjectSummary(folder: "W-1 Launch", name: "Launch", kind: "project", scope: "active", path: "/p")
        let sitting = calendar.date(from: DateComponents(year: 2026, month: 9, day: 16, hour: 14, minute: 15))!

        let older = summarize(base, notes: notes, todos: todos, notesModified: sitting.addingTimeInterval(-3600),
                              calendar: calendar)
        XCTAssertEqual(older.lastActivity, DoneLog.timestamp(sitting), "the sitting, when the file is older")
        XCTAssertEqual(older.lastSitting, "2026-09-16")
        XCTAssertEqual(older.lastSittingLede, "Venue")
        XCTAssertEqual(older.open, 5)
        XCTAssertEqual(older.nextDue, "2026-09-17")
        XCTAssertEqual(older.nextDueText, "Send the invites")

        let edited = now.addingTimeInterval(-60)
        XCTAssertEqual(summarize(base, notes: notes, todos: todos, notesModified: edited, calendar: calendar)
                        .lastActivity, DoneLog.timestamp(edited), "a later write to the file wins")
    }

    /// Moving is touched within two weeks; everything else, and anything never touched, is quiet.
    func testProjectsSplitIntoMovingAndQuiet() {
        func project(_ folder: String, daysAgo: Double?) -> ProjectSummary {
            var summary = ProjectSummary(folder: folder, name: folder, kind: "project", scope: "active", path: "")
            summary.lastActivity = daysAgo.map { DoneLog.timestamp(now.addingTimeInterval(-$0 * 86_400)) }
            return summary
        }
        let (moving, quiet) = ViewMarkdown.split([project("A", daysAgo: 1), project("B", daysAgo: 20),
                                                  project("C", daysAgo: nil), project("D", daysAgo: 13)], now: now)
        XCTAssertEqual(moving.map(\.folder), ["A", "D"])
        XCTAssertEqual(quiet.map(\.folder), ["B", "C"])
    }

    // MARK: Every view as text

    func testDueReadsAsDaysWithLinks() throws {
        let (_, todos) = try read(launch)
        let open = todos.filter { !$0.checked }.map { (hit: hit($0), todo: $0) }
        let due = dueHits(open, before: try dueCutoff(until: nil, now: now, calendar: calendar), calendar: calendar)
        XCTAssertEqual(ViewMarkdown.due(due, now: now, calendar: calendar), """
        ## Coming up

        ### Overdue

        - [ ] Send the invites · [[W-1 Launch]] · was due Sep 17

        ### Tue, Sep 22, 2026

        - [ ] Book the venue · [[W-1 Launch]]

        """)
        XCTAssertEqual(ViewMarkdown.due([], now: now, calendar: calendar), "## Coming up\n\nNothing due.\n")
    }

    func testLeftoversReadAsProjectsAndSittings() throws {
        let (notes, todos) = try read(launch)
        let project = try XCTUnwrap(leftovers(projectFolder: "W-1 Launch", notes: notes, todos: todos,
                                              before: try leftoversCutoff(before: nil, now: now, calendar: calendar),
                                              calendar: calendar))
        XCTAssertEqual(ViewMarkdown.leftovers(LeftoverList(projects: [project]), calendar: calendar), """
        ## Left open before today

        ### [[W-1 Launch]]

        **Sep 16 · 2:15 PM** — Venue

        - [ ] Book the venue · due Sep 22
          - [ ] Pay the deposit · due Sep 22
        - [ ] Send the invites · due Sep 17
        - [ ] Print the menus · due Oct 30
        - [ ] Whenever

        """)
    }

    func testADayReadsAsSittingsWithTheirProse() throws {
        let (notes, todos) = try read(launch)
        let range = DoneRange(start: calendar.date(from: DateComponents(year: 2026, month: 9, day: 16))!,
                              end: calendar.date(from: DateComponents(year: 2026, month: 9, day: 17))!)
        let list = sittings(projectFolder: "W-1 Launch", notes: notes, todos: todos, picks: [], doneEvents: [],
                            in: range, now: now, calendar: calendar)
        let text = ViewMarkdown.day(list, calendar: calendar)
        XCTAssertTrue(text.hasPrefix("""
        ## Wed, Sep 16, 2026

        ### 2:15 PM · [[W-1 Launch]] · Venue

        Settled on the hall.

        - [ ] Book the venue
          - [ ] Pay the deposit
        """), text)
        XCTAssertTrue(text.contains("- [x] Email Dana"), "a finished task keeps its box")
    }

    func testProjectsReadAsMovingAndQuiet() {
        var launch = ProjectSummary(folder: "W-1 Launch", name: "Launch", kind: "project", scope: "active", path: "")
        launch.lastActivity = DoneLog.timestamp(now.addingTimeInterval(-86_400))
        launch.open = 4
        launch.nextDue = "2026-09-22"
        var old = ProjectSummary(folder: "W-2 Old", name: "Old", kind: "project", scope: "active", path: "")
        old.lastActivity = DoneLog.timestamp(calendar.date(from: DateComponents(year: 2026, month: 7, day: 1, hour: 12))!)
        XCTAssertEqual(ViewMarkdown.projects([launch, old], now: now, calendar: calendar), """
        ## Projects

        ### Moving

        - [[W-1 Launch]] · last worked on Sep 17 · 4 open · next due Sep 22

        ### Quiet

        - [[W-2 Old]] · last worked on Jul 1 · 0 open

        """)
    }

    // MARK: Against a vault

    /// `task.due` across projects, `projects` narrowing it; `project.list` with activity, newest first.
    func testDueAndActivityAcrossTheVault() throws {
        try withVault { active in
            try write("W-2 Launch", in: active, tasks: "- [ ] Ship it due: 2026-09-19")
            try write("W-3 Docs", in: active, tasks: "- [ ] Proofread due: 2026-09-18")
            let due = try dueTasks(now: now, calendar: calendar)
            XCTAssertEqual(due.map(\.text), ["Proofread", "Ship it"])
            XCTAssertEqual(due.first?.due, "2026-09-18")
            XCTAssertEqual(try dueTasks(projects: ["W-2"], now: now, calendar: calendar).map(\.text), ["Ship it"])

            let result = try performApi("project.list", {
                var input = ApiInput()
                input.activity = true
                input.projects = ["W-3"]
                return input
            }(), options: ApiOptions(source: "test"))
            let entries = try XCTUnwrap(result.data?.arrayValue)
            XCTAssertEqual(entries.count, 1)
            XCTAssertEqual(entries.first?.objectValue?["folder"]?.stringValue, "W-3 Docs")
            XCTAssertEqual(entries.first?.objectValue?["open"], .number(1))
            XCTAssertEqual(entries.first?.objectValue?["nextDue"]?.stringValue, "2026-09-18")
            XCTAssertNotNil(entries.first?.objectValue?["lastActivity"]?.stringValue)
        }
    }

    private func withVault(_ body: (_ active: URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let active = root.appendingPathComponent("Projects")
        for dir in [active, root.appendingPathComponent("Archive"), root.appendingPathComponent("Areas")] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let saved = ProcessInfo.processInfo.environment["PM_CONFIG_HOME"]
        setenv("PM_CONFIG_HOME", root.path, 1)
        defer {
            if let saved { setenv("PM_CONFIG_HOME", saved, 1) } else { unsetenv("PM_CONFIG_HOME") }
        }
        try saveConfig(PmConfig(activePath: active.path, archivePath: root.appendingPathComponent("Archive").path,
                                areasPath: root.appendingPathComponent("Areas").path, domains: ["W": "Work"],
                                subfolders: ["docs"]))
        try body(active)
    }

    private func write(_ folder: String, in root: URL, tasks: String) throws {
        let docs = root.appendingPathComponent(folder).appendingPathComponent("docs")
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        let title = projectTitle(fromFolderName: folder)
        try "# \(title)\n\n## Sessions\n\n### Wed, Sep 16, 2026\n\n\(tasks)\n"
            .write(to: docs.appendingPathComponent("Notes - \(title).md"), atomically: true, encoding: .utf8)
    }
}
