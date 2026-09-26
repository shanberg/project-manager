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
