import XCTest
import PmLib
@testable import PMViewTests

/// A view card as the node carries it, and a sitting as a Day card draws it (docs/views.md D2, D3, D5).
final class CanvasViewSpecTests: XCTestCase {

    private func node(_ extra: [String: JSONValue], text: String = "Today, across projects: a Folio view.") -> CanvasNode {
        CanvasNode(content: .text(text), frame: CanvasRect(x: 0, y: 0, width: 360, height: 480), extra: extra)
    }

    func testATextNodeWithAViewIsThatView() {
        let spec = CanvasViewSpec.of(node(["pmView": .string("day")]))
        XCTAssertEqual(spec, CanvasViewSpec(kind: .day, period: .today, projects: .everything))
    }

    /// The forgiving fallback `CanvasCardShows` has: a view this build doesn't know is the text card
    /// it also is, and a setting it can't read is the default rather than nothing.
    func testAnUnknownViewIsATextCardAndAnUnknownSettingIsTheDefault() {
        XCTAssertNil(CanvasViewSpec.of(node(["pmView": .string("calendar")])))
        XCTAssertNil(CanvasViewSpec.of(node([:])))
        XCTAssertNil(CanvasViewSpec.of(CanvasNode(content: .link(url: "https://example.com"),
                                                  frame: CanvasRect(x: 0, y: 0, width: 1, height: 1),
                                                  extra: ["pmView": .string("day")])),
                     "Only a text node can be a view")
        let spec = CanvasViewSpec.of(node(["pmView": .string(" Day "), "pmPeriod": .string("fortnight"),
                                           "pmProjects": .number(3)]))
        XCTAssertEqual(spec, CanvasViewSpec(kind: .day))
    }

    func testPeriodsAndProjectsReadAsWritten() {
        let week = CanvasViewSpec.of(node(["pmView": .string("day"), "pmPeriod": .string("week"),
                                           "pmProjects": .string("board")]))
        XCTAssertEqual(week?.period, .week)
        XCTAssertEqual(week?.projects, .board)
        let pinned = CanvasViewSpec.of(node(["pmView": .string("day"), "pmPeriod": .string("2026-09-17"),
                                             "pmProjects": .array([.string("[[W-1 Redesign]]"), .string("Home")])]))
        XCTAssertEqual(pinned?.period, .day("2026-09-17"))
        XCTAssertEqual(pinned?.projects, .named(["[[W-1 Redesign]]", "Home"]))
    }

    /// Set back to the defaults, a card carries only `pmView`: narrowed and widened again, the file is
    /// as it was.
    func testWritingLeavesOutTheDefaults() {
        var card = node(["pmView": .string("day")])
        CanvasViewSpec.set(CanvasViewSpec(kind: .day, period: .yesterday, projects: .board), on: &card)
        XCTAssertEqual(card.extra["pmPeriod"], .string("yesterday"))
        XCTAssertEqual(card.extra["pmProjects"], .string("board"))
        CanvasViewSpec.set(.newDay, on: &card)
        XCTAssertEqual(card.extra, ["pmView": .string("day")])
        XCTAssertEqual(card.content, .text("Today, across projects: a Folio view."), "The text is never rewritten")
    }

    func testARelativePeriodFollowsTheClock() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 18, hour: 10))!
        let today = try CanvasViewSpec.Period.today.range(now: now, calendar: calendar)
        XCTAssertEqual(today.start, calendar.date(from: DateComponents(year: 2026, month: 9, day: 18)))
        let pinned = try CanvasViewSpec.Period.day("2026-09-02").range(now: now, calendar: calendar)
        XCTAssertEqual(pinned.start, calendar.date(from: DateComponents(year: 2026, month: 9, day: 2)))
        XCTAssertEqual(pinned.end, calendar.date(from: DateComponents(year: 2026, month: 9, day: 3)))
    }

    // MARK: A sitting's rows

    /// A sitting as `session.list` sends it — decoded from the wire, as every surface gets it.
    private func sitting(_ json: String) throws -> SittingEntry {
        let base = """
        "projectFolder": "W-1 Redesign", "projectName": "Redesign", "isArchived": false,
        "session": "2026-09-18", "sessionOrdinal": 0, "sessionDigest": "d", "startTime": "9:10 AM",
        "startedAt": "2026-09-18T14:10:00Z", "name": "", "prose": "", "isCurrent": false,
        """
        return try JSONDecoder().decode(SittingEntry.self, from: Data("{\(base) \(json)}".utf8))
    }

    private func ref(_ session: String, _ line: Int) -> String {
        #"{"session": "\#(session)", "sessionOrdinal": 0, "line": \#(line), "digest": "x"}"#
    }

    /// `session.list` lists a task by every role it has. Written and ticked in one sitting, it's one row,
    /// in the state its line is in; finished here but written elsewhere, it's a row with where it's from.
    func testEachLineIsDrawnOnceWithWhereItCameFrom() throws {
        let entry = try sitting("""
        "written": [{"text": "Email Dana", "state": "done", "depth": 0, "ref": \(ref("2026-09-18", 0))},
                    {"text": "Draft the spec", "state": "open", "depth": 0, "ref": \(ref("2026-09-18", 1))}],
        "picked": [{"text": "Book the venue", "state": "open", "depth": 0, "ref": \(ref("2026-09-02", 0)), "from": "2026-09-02"},
                   {"text": "Call the second", "state": "open", "depth": 1, "ref": \(ref("2026-09-02", 1)), "from": "2026-09-02"}],
        "finished": [{"text": "Email Dana", "state": "done", "depth": 0, "ref": \(ref("2026-09-18", 0)), "at": "2026-09-18T15:00:00Z"},
                     {"text": "Renew the domain", "state": "done", "depth": 2, "ref": \(ref("2026-09-03", 4)), "at": "2026-09-18T15:10:00Z"},
                     {"text": "Tidied away", "state": "done", "depth": 0, "at": "2026-09-18T15:20:00Z"}],
        "dropped": []
        """)
        let rows = CanvasDayRows.rows(entry)
        XCTAssertEqual(rows.map(\.text), ["Email Dana", "Draft the spec", "Book the venue", "Call the second",
                                          "Renew the domain", "Tidied away"])
        XCTAssertEqual(rows.map(\.state), [.done, .open, .open, .open, .done, .done])
        XCTAssertEqual(rows.map(\.depth), [0, 0, 0, 1, 0, 0], "A finished subtask from elsewhere stands alone")
        XCTAssertEqual(rows.map(\.pickedUp), [false, false, true, false, false, false])
        XCTAssertEqual(rows[2].origin, SessionPicks.day(iso: "2026-09-02"), "The picked tree's root says where from")
        XCTAssertNil(rows[3].origin, "…and the lines under it don't repeat it")
        XCTAssertEqual(rows[4].origin, SessionPicks.day(iso: "2026-09-03"))
        XCTAssertNil(rows[5].origin, "A line that's gone has nowhere to point")
        XCTAssertEqual(Set(rows.map(\.id)).count, rows.count, "Ids are unique, for ForEach")
    }

    func testAWeekDrawsWhatCameOfASitting() throws {
        let entry = try sitting("""
        "written": [{"text": "a", "state": "open", "depth": 0}, {"text": "b", "state": "done", "depth": 0}],
        "picked": [{"text": "c", "state": "open", "depth": 0, "from": "2026-09-02"},
                   {"text": "c1", "state": "open", "depth": 1, "from": "2026-09-02"}],
        "finished": [{"text": "b", "state": "done", "depth": 0}],
        "dropped": [{"text": "d", "state": "dropped", "depth": 0}]
        """)
        XCTAssertEqual(CanvasDayRows.counts(entry), "1 done · 1 dropped · 1 picked up · 1 open")
    }

    func testTheSummaryCountsSittingsDoneAndDroppedApart() throws {
        let entry = try sitting("""
        "written": [], "picked": [],
        "finished": [{"text": "b", "state": "done", "depth": 0}],
        "dropped": [{"text": "d", "state": "dropped", "depth": 0}]
        """)
        let elsewhere = try JSONDecoder().decode(DoneItem.self, from: Data("""
        {"projectFolder": "Home", "projectName": "Home", "isArchived": false,
         "at": "2026-09-18T20:00:00Z", "text": "Renew passport", "dropped": false}
        """.utf8))
        XCTAssertEqual(CanvasDayRows.summary(SittingList(sittings: [entry], elsewhere: [elsewhere])),
                       "1 sitting · 2 done · 1 dropped")
        XCTAssertEqual(CanvasDayRows.summary(SittingList()), "No sittings")
    }
}

extension CanvasViewSpecTests {
    private func entry(current: Bool) throws -> SittingEntry {
        let base = """
        {"projectFolder": "W-1 Redesign", "projectName": "Redesign", "isArchived": false,
         "session": "2026-09-18", "sessionOrdinal": 0, "sessionDigest": "d", "startTime": null,
         "startedAt": null, "name": "", "prose": "", "isCurrent": \(current),
         "written": [], "picked": [], "finished": [], "dropped": []}
        """
        return try JSONDecoder().decode(SittingEntry.self, from: Data(base.utf8))
    }

    private func row(_ state: TaskState, pickedUp: Bool = false, ref: Bool = true) -> CanvasDayRow {
        CanvasDayRow(id: "r", text: "t", state: state, depth: 0, origin: nil, pickedUp: pickedUp,
                     ref: ref ? TaskRefInput(session: "2026-09-18", sessionOrdinal: 0, line: 0, digest: "x") : nil)
    }

    /// A row offers the project card's verbs for it, as far as the row alone can say (D6).
    func testARowOffersWhatItCanBeToldToDo() throws {
        let now = try entry(current: true), before = try entry(current: false)
        XCTAssertEqual(CanvasDayAction.offered(for: row(.open), in: now), [.complete, .drop, .focus])
        XCTAssertEqual(CanvasDayAction.offered(for: row(.open), in: before), [.complete, .drop, .focus, .pickUp],
                       "An older sitting's open task can be picked up into the current one")
        XCTAssertEqual(CanvasDayAction.offered(for: row(.open, pickedUp: true), in: now),
                       [.complete, .drop, .focus, .putBack])
        XCTAssertEqual(CanvasDayAction.offered(for: row(.done), in: now), [.reopen])
        XCTAssertEqual(CanvasDayAction.offered(for: row(.dropped), in: before), [.reopen])
        XCTAssertEqual(CanvasDayAction.offered(for: row(.open, ref: false), in: now), [],
                       "A line that's gone can only be read")
    }
}
