import XCTest
import PmLib

final class ProjectEventsTests: XCTestCase {

    private let designed = """
    ---
    pm-color: blue
    pm-events:
      - calendar: Work              # the calendar's title
        account: iCloud             # optional; only when two calendars share a title
        match: ["1:1 Priya", "Priya / Stuart"]
      - calendar: Launch            # no match: every event in the calendar
    pm-icon: leaf
    ---
    # W-1
    """

    // MARK: Reading

    /// The shape views.md C2 writes down, comments and all.
    func testReadsTheDesignedShape() {
        XCTAssertEqual(projectEventSources(rawText: designed), [
            ProjectEventSource(calendar: "Work", account: "iCloud", match: ["1:1 Priya", "Priya / Stuart"]),
            ProjectEventSource(calendar: "Launch"),
        ])
    }

    /// What Obsidian or a hand edit might leave: a sequence at the key's indent, a block `match`,
    /// single quotes, a single string.
    func testReadsOtherValidShapes() {
        let raw = """
        ---
        pm-events:
        - calendar: 'Team: Eng'
          match:
            - standup
            - "retro, weekly"
        - account: Google
          calendar: Home
          match: dentist
        ---
        """
        XCTAssertEqual(projectEventSources(rawText: raw), [
            ProjectEventSource(calendar: "Team: Eng", match: ["standup", "retro, weekly"]),
            ProjectEventSource(calendar: "Home", account: "Google", match: ["dentist"]),
        ])
    }

    func testNothingToRead() {
        XCTAssertEqual(projectEventSources(rawText: "# T\npm-events:\n  - calendar: Work\n"), [])
        XCTAssertEqual(projectEventSources(rawText: "---\npm-color: red\n---\n"), [])
        XCTAssertEqual(projectEventSources(rawText: "---\npm-events: []\n---\n"), [])
        XCTAssertEqual(projectEventSources(rawText: "---\npm-events:\n  - match: [a]\n---\n"), [],
                       "an entry without a calendar names nothing")
    }

    // MARK: Writing

    func testRoundTrips() {
        let sources = [
            ProjectEventSource(calendar: "Work", account: "iCloud", match: ["1:1 Priya", "Say \"hi\""]),
            ProjectEventSource(calendar: "Team: Eng"),
            ProjectEventSource(calendar: "2026"),
        ]
        let raw = settingProjectEventSources(sources, in: "# T\n")
        XCTAssertEqual(projectEventSources(rawText: raw), sources)
        XCTAssertEqual(raw, """
        ---
        pm-events:
          - calendar: Work
            account: iCloud
            match: ["1:1 Priya", "Say \\"hi\\""]
          - calendar: "Team: Eng"
          - calendar: "2026"
        ---
        # T

        """)
    }

    /// Replacing the block leaves the keys either side of it, and the body, byte for byte.
    func testReplacesOnlyTheBlock() {
        let raw = settingProjectEventSources([ProjectEventSource(calendar: "Home")], in: designed)
        XCTAssertEqual(raw, """
        ---
        pm-color: blue
        pm-events:
          - calendar: Home
        pm-icon: leaf
        ---
        # W-1
        """)
    }

    func testAddsAfterOtherKeys() {
        let raw = settingProjectEventSources([ProjectEventSource(calendar: "Home")],
                                             in: "---\npm-color: red\n---\n# T\n")
        XCTAssertEqual(raw, "---\npm-color: red\npm-events:\n  - calendar: Home\n---\n# T\n")
    }

    /// Clearing removes every line of the block, and the frontmatter too when nothing else was in it.
    func testClearing() {
        XCTAssertEqual(settingProjectEventSources([], in: designed),
                       "---\npm-color: blue\npm-icon: leaf\n---\n# W-1")
        let only = settingProjectEventSources([ProjectEventSource(calendar: "Home")], in: "# T\n")
        XCTAssertEqual(settingProjectEventSources([], in: only), "# T\n")
        XCTAssertEqual(settingProjectEventSources([], in: "# T\n"), "# T\n")
    }

    // MARK: Matching

    private let work = ProjectEventSource(calendar: "Work", account: "iCloud", match: ["1:1 Priya", "Priya / Stuart"])

    func testSeveralMatchStrings() {
        XCTAssertTrue(work.matches(calendar: "Work", account: "iCloud", title: "1:1 Priya"))
        XCTAssertTrue(work.matches(calendar: "Work", account: "iCloud", title: "Weekly priya / stuart sync"))
        XCTAssertFalse(work.matches(calendar: "Work", account: "iCloud", title: "All hands"))
    }

    func testNoMatchTakesTheWholeCalendar() {
        let launch = ProjectEventSource(calendar: "Launch")
        XCTAssertTrue(launch.matches(calendar: "Launch", account: "Google", title: "Anything"))
        let blank = ProjectEventSource(calendar: "Launch", match: ["", "  "])
        XCTAssertTrue(blank.matches(calendar: "Launch", account: nil, title: "Anything"),
                      "blank strings are ignored, not a match on nothing")
    }

    func testAccount() {
        XCTAssertFalse(work.matches(calendar: "Work", account: "Google", title: "1:1 Priya"))
        XCTAssertFalse(work.matches(calendar: "Work", account: nil, title: "1:1 Priya"))
        XCTAssertTrue(work.matches(calendar: " work ", account: "ICLOUD", title: "1:1 Priya"))
        let anyAccount = ProjectEventSource(calendar: "Work", match: ["Priya"])
        XCTAssertTrue(anyAccount.matches(calendar: "Work", account: "Google", title: "1:1 Priya"))
        XCTAssertTrue(anyAccount.matches(calendar: "Work", account: "iCloud", title: "1:1 Priya"))
    }

    /// A calendar this Mac doesn't have is kept and just matches nothing.
    func testCalendarThatIsNotThere() {
        let sources = projectEventSources(rawText: designed)
        XCTAssertEqual(sources.count, 2)
        XCTAssertFalse(sources.matches(calendar: "Personal", account: "iCloud", title: "1:1 Priya"))
        XCTAssertTrue(sources.matches(calendar: "Launch", account: "iCloud", title: "Go/no-go"))
        XCTAssertFalse([ProjectEventSource]().matches(calendar: "Work", account: nil, title: "x"))
    }
}

final class ProjectEventChoiceTests: XCTestCase {
    private let mac: [(title: String, account: String)] = [
        ("Work", "iCloud"), ("Home", "iCloud"), ("Work", "Google"), ("Launch", "Google"),
    ]

    private func sources(_ raw: [ProjectEventSource]) -> [ProjectEventSource] {
        projectEventSources(from: projectEventChoices(calendars: mac, sources: raw))
    }

    /// Opening the sheet and saving writes back exactly what was read.
    func testUntouchedRoundTrips() {
        let cases: [[ProjectEventSource]] = [
            [],
            [ProjectEventSource(calendar: "Launch", match: ["go/no-go"]), ProjectEventSource(calendar: "Home")],
            [ProjectEventSource(calendar: "Work", account: "Google", match: ["1:1"])],
            // No account, and two calendars answer to it: still one entry.
            [ProjectEventSource(calendar: "Work", match: ["Priya"])],
            // Not on this Mac: kept.
            [ProjectEventSource(calendar: "Personal", account: "Exchange"), ProjectEventSource(calendar: "Home")],
        ]
        for original in cases { XCTAssertEqual(sources(original), original) }
    }

    func testRows() {
        let choices = projectEventChoices(calendars: mac, sources: [
            ProjectEventSource(calendar: "Work", match: ["Priya"]),
            ProjectEventSource(calendar: "Personal"),
        ])
        XCTAssertEqual(choices.map(\.title), ["Work", "Home", "Work", "Launch", "Personal"])
        XCTAssertEqual(choices.map(\.isOn), [true, false, true, false, true])
        XCTAssertEqual(choices.map(\.isOnThisMac), [true, true, true, true, false])
        XCTAssertEqual(choices[2].queries, ["Priya"])
    }

    /// Checking one of two calendars that share a title names its account; a unique title doesn't.
    func testAccountOnlyWhenNeeded() {
        var choices = projectEventChoices(calendars: mac, sources: [])
        choices[0].isOn = true                          // Work, iCloud
        choices[1].isOn = true                          // Home, iCloud
        choices[1].queries = ["  ", "dentist "]
        XCTAssertEqual(projectEventSources(from: choices), [
            ProjectEventSource(calendar: "Work", account: "iCloud"),
            ProjectEventSource(calendar: "Home", match: ["dentist"]),
        ])
    }

    /// New rows go after the file's entries, whatever their place in the list.
    func testKeepsFileOrder() {
        var choices = projectEventChoices(calendars: mac, sources: [ProjectEventSource(calendar: "Launch")])
        choices[1].isOn = true                          // Home, listed before Launch
        XCTAssertEqual(projectEventSources(from: choices).map(\.calendar), ["Launch", "Home"])
    }

    /// Splitting an account-less entry — one twin unchecked — names the account of the one left.
    func testSplittingTwins() {
        var choices = projectEventChoices(calendars: mac, sources: [ProjectEventSource(calendar: "Work")])
        choices[2].isOn = false                         // Work, Google
        XCTAssertEqual(projectEventSources(from: choices), [ProjectEventSource(calendar: "Work", account: "iCloud")])
    }
}

final class ProjectEventPlacementTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }()

    private func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute))!
    }

    private func event(_ start: Date, _ end: Date, allDay: Bool = false, _ title: String = "1:1 Priya") -> ProjectEvent {
        ProjectEvent(id: title + "\(start)", title: title, start: start, end: end, isAllDay: allDay,
                     projectFolder: "W-1 Launch", projectName: "Launch", projectColor: "blue")
    }

    func testTimedEvent() {
        let e = event(at(25, 9, 30), at(25, 10))
        XCTAssertEqual(e.days(calendar: calendar), ["2026-09-25"])
        XCTAssertEqual(e.startMinute(on: "2026-09-25", calendar: calendar), 570)
        XCTAssertEqual(e.endMinute(on: "2026-09-25", calendar: calendar), 600)
        XCTAssertEqual(e.timeLabel(calendar: calendar), "9:30–10:00 AM")
        XCTAssertEqual(event(at(25, 11, 30), at(25, 12, 15)).timeLabel(calendar: calendar), "11:30 AM–12:15 PM")
    }

    /// Ending at midnight isn't the next day; running past it is, from midnight.
    func testAcrossMidnight() {
        XCTAssertEqual(event(at(25, 22), at(26, 0)).days(calendar: calendar), ["2026-09-25"])
        XCTAssertEqual(event(at(25, 22), at(26, 0)).endMinute(on: "2026-09-25", calendar: calendar), 1440)
        let late = event(at(25, 23), at(26, 1))
        XCTAssertEqual(late.days(calendar: calendar), ["2026-09-25", "2026-09-26"])
        XCTAssertEqual(late.startMinute(on: "2026-09-26", calendar: calendar), 0)
        XCTAssertEqual(late.endMinute(on: "2026-09-26", calendar: calendar), 60)
        XCTAssertEqual(late.endMinute(on: "2026-09-25", calendar: calendar), 1440)
    }

    /// EventKit ends an all-day event at the midnight after its last day.
    func testAllDay() {
        let offsite = event(at(24, 0), at(26, 0), allDay: true, "Offsite")
        XCTAssertEqual(offsite.days(calendar: calendar), ["2026-09-24", "2026-09-25"])
        XCTAssertNil(offsite.startMinute(on: "2026-09-24", calendar: calendar))
        XCTAssertEqual(offsite.timeLabel(calendar: calendar), "All day")
    }

    func testOnADay() {
        let events = [event(at(25, 14), at(25, 15), "Review"), event(at(25, 0), at(26, 0), allDay: true, "Offsite"),
                      event(at(25, 9), at(25, 10), "Standup"), event(at(26, 9), at(26, 10), "Tomorrow")]
        XCTAssertEqual(events.on("2026-09-25", calendar: calendar).map(\.title), ["Offsite", "Standup", "Review"])
    }
}

/// Which projects show events, read across a vault. Sets PM_CONFIG_HOME, so not parallel-safe.
final class ProjectEventLinksTests: XCTestCase {
    func testFindsProjectsWithEvents() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let active = root.appendingPathComponent("Projects")
        let archive = root.appendingPathComponent("Archive")
        let areas = root.appendingPathComponent("Areas")
        for dir in [active, archive, areas] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        defer { try? FileManager.default.removeItem(at: root) }
        let saved = ProcessInfo.processInfo.environment["PM_CONFIG_HOME"]
        setenv("PM_CONFIG_HOME", root.path, 1)
        defer { if let saved { setenv("PM_CONFIG_HOME", saved, 1) } else { unsetenv("PM_CONFIG_HOME") } }
        try saveConfig(PmConfig(activePath: active.path, archivePath: archive.path, areasPath: areas.path,
                                domains: ["W": "Work"], subfolders: ["docs"]))

        func write(_ folder: String, in base: URL, frontmatter: String) throws {
            let docs = base.appendingPathComponent(folder).appendingPathComponent("docs")
            try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
            let title = projectTitle(fromFolderName: folder)
            try "\(frontmatter)# \(title)\n".write(to: docs.appendingPathComponent("Notes - \(title).md"),
                                                     atomically: true, encoding: .utf8)
        }
        let events = "---\npm-color: teal\npm-events:\n  - calendar: Work\n    match: [\"1:1\"]\n---\n"
        try write("W-1 Launch", in: active, frontmatter: events)
        try write("W-2 Quiet", in: active, frontmatter: "---\npm-color: red\n---\n")
        try write("Team 1-1s", in: areas, frontmatter: "---\npm-events:\n  - calendar: Home\n---\n")
        try write("W-3 Old", in: archive, frontmatter: events)

        let all = try projectEventLinks()
        XCTAssertEqual(all.map(\.projectFolder).sorted(), ["Team 1-1s", "W-1 Launch"], "no archive unless named")
        let launch = try XCTUnwrap(all.first { $0.projectFolder == "W-1 Launch" })
        XCTAssertEqual(launch.projectName, "Launch")
        XCTAssertEqual(launch.projectColor, "teal")
        XCTAssertEqual(launch.sources, [ProjectEventSource(calendar: "Work", match: ["1:1"])])

        XCTAssertEqual(try projectEventLinks(projects: ["W-3"]).map(\.projectFolder), ["W-3 Old"])
        XCTAssertEqual(try projectEventLinks(projects: ["W-2"]), [])
    }
}

final class ProjectEventTextTests: XCTestCase {
    func testEventsAsText() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute))!
        }
        let events = [
            ProjectEvent(id: "a", title: "1:1 Priya", start: at(25, 9), end: at(25, 9, 30), isAllDay: false,
                         projectFolder: "W-1 Launch", projectName: "Launch", projectColor: nil),
            ProjectEvent(id: "b", title: "Offsite", start: at(26, 0), end: at(27, 0), isAllDay: true,
                         projectFolder: "W-1 Launch", projectName: "Launch", projectColor: nil),
        ]
        let text = ViewMarkdown.events(events, days: ["2026-09-24", "2026-09-25", "2026-09-26"], calendar: calendar)
        XCTAssertTrue(text.hasPrefix("## Events\n\n### "))
        XCTAssertTrue(text.contains("- 9:00–9:30 AM · 1:1 Priya · [[W-1 Launch]]"))
        XCTAssertTrue(text.contains("- All day · Offsite · [[W-1 Launch]]"))
        XCTAssertEqual(text.components(separatedBy: "### ").count, 3, "a heading only for days with events")
        XCTAssertEqual(ViewMarkdown.events(events, days: ["2026-09-24"], calendar: calendar), "")
    }
}

final class MeetingForNotesTests: XCTestCase {
    private let base = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private func event(_ title: String, _ from: Double, _ to: Double, project: String = "Launch",
                       allDay: Bool = false) -> ProjectEvent {
        ProjectEvent(id: title + project, title: title, start: base.addingTimeInterval(from * 60),
                     end: base.addingTimeInterval(to * 60), isAllDay: allDay,
                     projectFolder: "W-1 \(project)", projectName: project, projectColor: nil)
    }

    func testTheOneOnNow() {
        let events = [event("Standup", -30, 15), event("1:1 Priya", -5, 25), event("Later", 5, 60)]
        XCTAssertEqual(meetingForNotes(events, now: base)?.title, "1:1 Priya", "the latest to have begun")
    }

    func testTheNextOneSoon() {
        XCTAssertEqual(meetingForNotes([event("Review", 8, 60), event("Crit", 3, 30)], now: base)?.title, "Crit")
        XCTAssertNil(meetingForNotes([event("Review", 11, 60)], now: base), "past the lead")
        XCTAssertNil(meetingForNotes([event("Done", -60, 0)], now: base), "ended as now began")
    }

    func testNeverAllDay() {
        XCTAssertNil(meetingForNotes([event("Offsite", -600, 800, allDay: true)], now: base))
    }

    func testOneEventInTwoProjects() {
        let events = [event("Sync", -5, 25, project: "Redesign"), event("Sync", -5, 25, project: "Hiring")]
        XCTAssertEqual(meetingForNotes(events, now: base)?.projectName, "Hiring")
    }

    func testLabel() {
        XCTAssertEqual(meetingSittingLabel(event("  1:1 Priya ", 0, 30)), "1:1 Priya")
        XCTAssertEqual(meetingSittingLabel(event(" ", 0, 30)), "Meeting")
    }
}
