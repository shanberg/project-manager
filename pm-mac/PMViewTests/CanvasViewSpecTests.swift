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
        CanvasViewSpec.set(CanvasViewSpec(kind: .day), on: &card)
        XCTAssertEqual(card.extra, ["pmView": .string("day")])
        XCTAssertEqual(card.content, .text("Today, across projects: a Folio view."), "The text is never rewritten")
    }

    /// A new Today card starts on the projects of the board it is put on; one stored without the key is
    /// still everything, so cards already on a board don't change what they show.
    func testANewDayCardStartsOnTheBoardsProjectsButAnOldOneStaysEverything() {
        var fresh = node([:])
        CanvasViewSpec.set(.newDay, on: &fresh)
        XCTAssertEqual(CanvasViewSpec.of(fresh)?.projects, .board)
        XCTAssertEqual(CanvasViewSpec.of(node(["pmView": .string("day")]))?.projects, .everything)
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

// MARK: Selection, trees and drags

extension CanvasViewSpecTests {
    /// A selection is one sitting's rows. ⌘ and ⇧ work inside it; a click in another sitting starts
    /// over there, whatever keys are held, so a selection is always one project's.
    func testASelectionStaysInOneSitting() {
        var selection = CanvasDaySelection()
        let order = ["a", "b", "c"]
        selection.click("a", in: "S1", modifiers: [], order: order)
        selection.click("c", in: "S1", modifiers: .shift, order: order)
        XCTAssertEqual(selection.count, 3)
        XCTAssertEqual(selection.targets(clicked: "b", in: "S1"), ["a", "b", "c"])

        selection.click("a", in: "S2", modifiers: .command, order: order)
        XCTAssertEqual(selection.count, 1, "⌘-click in another sitting starts over, not adds")
        XCTAssertTrue(selection.contains("a", in: "S2"))
        XCTAssertFalse(selection.contains("a", in: "S1"), "The same row id in another sitting is another row")
        XCTAssertEqual(selection.targets(clicked: "b", in: "S1"), ["b"], "A row outside it acts alone")

        selection.revealForContextMenu("c", in: "S1")
        XCTAssertTrue(selection.contains("c", in: "S1"))
        XCTAssertEqual(selection.count, 1)

        selection.keep(within: ["S2": ["a"]])
        XCTAssertTrue(selection.isEmpty, "A sitting no longer drawn takes its selection with it")
    }

    private func tree() -> [CanvasDayRow] {
        [("p", 0, TaskState.open), ("p1", 1, .open), ("p2", 1, .done), ("q", 0, .open)].map {
            CanvasDayRow(id: $0.0, text: $0.0, state: $0.2, depth: $0.1, origin: nil, pickedUp: $0.0 == "p",
                         ref: TaskRefInput(session: "2026-09-18", sessionOrdinal: 0, line: 0, digest: "x"))
        }
    }

    func testASelectionCountsItsTreesForPicks() {
        let rows = tree()
        XCTAssertEqual(CanvasDayRows.roots(of: rows, in: rows).map(\.id), ["p", "q"])
        XCTAssertEqual(CanvasDayRows.roots(of: [rows[1], rows[2]], in: rows).map(\.id), ["p1", "p2"],
                       "Subtasks without their parent are trees of their own")
        XCTAssertEqual(CanvasDayAction.pickUp.count(of: rows, among: rows), 2)
        XCTAssertEqual(CanvasDayAction.pickUp.title(count: 2), "Pick Up 2 Tasks")
        XCTAssertEqual(CanvasDayAction.drop.count(of: rows, among: rows), 3, "Only the open ones drop")
        XCTAssertEqual(CanvasDayAction.putBack.count(of: rows, among: rows), 1)
    }

    func testASelectionOffersTheBatchVerbs() throws {
        let now = try entry(current: true), before = try entry(current: false)
        let rows = tree()
        XCTAssertEqual(CanvasDayAction.offered(for: rows, in: before), [.complete, .drop, .pickUp],
                       "No Focus for more than one")
        XCTAssertEqual(CanvasDayAction.offered(for: rows, in: now), [.complete, .drop, .putBack])
        XCTAssertEqual(CanvasDayAction.offered(for: [rows[2]], in: now), [.reopen])
    }

    /// Dragged off, rows are the lines they'd be in a note — a subtask dragged alone is a task.
    func testRowsDragAsTheirMarkdown() {
        let rows = tree()
        XCTAssertEqual(CanvasDayRows.markdown(rows), "- [ ] p\n  - [ ] p1\n  - [x] p2\n- [ ] q")
        XCTAssertEqual(CanvasDayRows.markdown([rows[2]]), "- [x] p2")
    }
}

// MARK: - Waiting and Search (step 5)

extension CanvasViewSpecTests {
    /// A search hit as the contract sends one. Its initializer is PmLib's own, so a test reads one off
    /// the wire, which is what the card is handed anyway.
    private func hit(_ text: String, project: String = "W-1 Launch", session: String = "2026-09-18",
                     ordinal: Int = 0, line: Int = 0, waiting: String? = nil) throws -> TaskSearchHit {
        var object: [String: Any] = [
            "projectFolder": project, "projectName": String(project.dropFirst(4)), "projectKey": "/p:\(project)",
            "isArchived": false, "text": text, "isFocused": false, "session": session,
            "sessionOrdinal": ordinal, "line": line, "digest": "d-\(text)",
        ]
        if let waiting { object["waiting"] = waiting; object["effectiveWaiting"] = waiting }
        return try JSONDecoder().decode(TaskSearchHit.self, from: JSONSerialization.data(withJSONObject: object))
    }

    func testWaitingAndSearchAreViewsAndSearchKeepsItsWords() {
        XCTAssertEqual(CanvasViewSpec.of(node(["pmView": .string("waiting")]))?.kind, .waiting)
        let search = CanvasViewSpec.of(node(["pmView": .string("search"), "pmQuery": .string("email dana")]))
        XCTAssertEqual(search?.kind, .search)
        XCTAssertEqual(search?.query, "email dana")
        XCTAssertFalse(CanvasViewSpec.Kind.waiting.hasPeriod, "Waiting is about now")
        XCTAssertFalse(CanvasViewSpec.Kind.search.hasPeriod, "a search is about words")

        var card = node(["pmView": .string("search")])
        CanvasViewSpec.set(CanvasViewSpec(kind: .search, query: "  email dana "), on: &card)
        XCTAssertEqual(card.extra["pmQuery"], .string("email dana"))
        CanvasViewSpec.set(.newSearch, on: &card)
        XCTAssertEqual(card.extra, ["pmView": .string("search"), "pmProjects": .string("board")],
                       "an empty search carries no query")
    }

    /// The contract's buckets are the groups, in its order (released first), each heading a target.
    func testWaitingGroupsAreTheContractsBuckets() throws {
        let released = WaitingBucket(target: "W-2 Site", title: "Site", folder: "W-2 Site", state: "released",
                                     tasks: [try hit("Ship it", waiting: "W-2 Site")])
        let person = WaitingBucket(target: "Dana", title: "Dana", folder: nil, state: "unresolved",
                                   tasks: [try hit("Proofread", line: 1, waiting: "Dana"),
                                           try hit("Sign off", line: 2)])
        let groups = CanvasTaskLists.groups(waiting: [released, person])
        XCTAssertEqual(groups.map(\.title), ["Site", "Dana"])
        XCTAssertEqual(groups.map(\.folder), ["W-2 Site", nil])
        XCTAssertEqual(groups.map(\.id), ["waiting/W-2 Site", "waiting/dana"])
        XCTAssertEqual(CanvasTaskLists.summary(.waiting, groups), "3 tasks · 2 things · 1 released")
        XCTAssertEqual(CanvasTaskLists.summary(.waiting, []), "Nothing waiting")
    }

    /// Ranked by the contract's own ranking, as one list with no heading, and capped.
    func testSearchIsOneRankedList() throws {
        let hits = [try hit("Book the venue"), try hit("Email Dana about the venue", line: 1),
                    try hit("Email Dana", line: 2)]
        let groups = CanvasTaskLists.groups(search: hits, query: "email dana")
        XCTAssertEqual(groups.count, 1)
        XCTAssertNil(groups.first?.title)
        XCTAssertEqual(groups.first?.hits.map(\.text), ["Email Dana", "Email Dana about the venue"])
        XCTAssertEqual(CanvasTaskLists.summary(.search, groups), "2 matches")
        XCTAssertTrue(CanvasTaskLists.groups(search: hits, query: "passport").isEmpty)

        let many = try (0..<80).map { try hit("Email \($0)", line: $0) }
        XCTAssertEqual(CanvasTaskLists.groups(search: many, query: "email").first?.hits.count,
                       CanvasTaskLists.searchLimit)
    }

    /// A hit's row carries its whole ref — the sitting's ordinal too — and whether its own line waits.
    func testAHitsRowCanBeActedOn() throws {
        let row = CanvasTaskLists.row(try hit("Call Dana", ordinal: 1, line: 3, waiting: "Dana"))
        XCTAssertEqual(row.ref, TaskRefInput(session: "2026-09-18", sessionOrdinal: 1, line: 3, digest: "d-Call Dana"))
        XCTAssertTrue(row.declaresWait)
        XCTAssertEqual(row.state, .open)
        XCTAssertNotEqual(CanvasTaskLists.rowID(try hit("Call Dana", ordinal: 0, line: 3)), row.id,
                          "the same line number in a day's other sitting is another row")
    }

    /// No sitting to pick up from or put back into; Stop Waiting where a line says what it waits on.
    func testATaskRowOffersItsVerbs() throws {
        let plain = CanvasTaskLists.row(try hit("Book the venue"))
        let waits = CanvasTaskLists.row(try hit("Ship it", line: 1, waiting: "W-2 Site"))
        XCTAssertEqual(CanvasDayAction.offered(forTasks: [plain]), [.complete, .drop, .focus])
        XCTAssertEqual(CanvasDayAction.offered(forTasks: [plain, waits]), [.complete, .drop, .stopWaiting])
        XCTAssertEqual(CanvasDayAction.stopWaiting.count(of: [plain, waits], among: [plain, waits]), 1)
        XCTAssertEqual(CanvasDayAction.stopWaiting.title(count: 2), "Stop Waiting on 2 Tasks")
        var gone = plain
        gone.ref = nil
        XCTAssertEqual(CanvasDayAction.offered(forTasks: [gone]), [], "a row that can't be named can't be acted on")
    }

    /// A selection on a task list is one project's rows, in the order they're drawn across its groups;
    /// a click in another project's row starts over there.
    func testATaskListSelectionStaysInOneProject() throws {
        let a1 = try hit("One"), b1 = try hit("Two", project: "W-2 Site")
        let a2 = try hit("Three", line: 1)
        let groups = [CanvasTaskGroup(id: "x", title: "X", state: "pending", folder: nil, hits: [a1, b1]),
                      CanvasTaskGroup(id: "y", title: "Y", state: "pending", folder: nil, hits: [a2])]
        let order = CanvasTaskLists.order(groups)
        XCTAssertEqual(order["W-1 Launch"], [CanvasTaskLists.rowID(a1), CanvasTaskLists.rowID(a2)])

        var selection = CanvasDaySelection()
        selection.click(CanvasTaskLists.rowID(a1), in: "W-1 Launch", modifiers: [], order: order["W-1 Launch"]!)
        selection.click(CanvasTaskLists.rowID(a2), in: "W-1 Launch", modifiers: .shift, order: order["W-1 Launch"]!)
        XCTAssertEqual(selection.count, 2, "⇧ reaches across groups within the project")
        selection.click(CanvasTaskLists.rowID(b1), in: "W-2 Site", modifiers: .command, order: order["W-2 Site"]!)
        XCTAssertEqual(selection.count, 1)
        XCTAssertTrue(selection.contains(CanvasTaskLists.rowID(b1), in: "W-2 Site"))
    }

    // MARK: Leftovers (step 6)

    /// A Leftovers card is a view with a period, read as a cut-off, and says so in its menu and its note.
    func testLeftoversReadsItsPeriodAsACutOff() throws {
        var card = node(["pmView": .string("leftovers"), "pmPeriod": .string("week")])
        let spec = try XCTUnwrap(CanvasViewSpec.of(card))
        XCTAssertEqual(spec.kind, .leftovers)
        XCTAssertTrue(spec.kind.hasPeriod)
        XCTAssertEqual(spec.period, .week)
        XCTAssertEqual(spec.period.beforeTitle, "Before This Week")
        XCTAssertEqual(CanvasViewSpec.Period.today.beforeTitle, "Before Today")
        XCTAssertEqual(CanvasViewSpec.newLeftovers.noteText,
                       "Tasks left open before today, across this board's projects: a Folio view.")
        CanvasViewSpec.set(.newLeftovers, on: &card)
        XCTAssertEqual(card.extra, ["pmView": .string("leftovers"), "pmProjects": .string("board")])
    }

    private func leftovers() -> LeftoverList {
        func task(_ text: String, line: Int, depth: Int = 0, session: String, picked: PickMark? = nil) -> LeftoverTask {
            LeftoverTask(text: text, depth: depth, due: nil, waiting: nil, effectiveWaiting: nil, isFocused: false,
                         ref: TaskRefInput(session: session, sessionOrdinal: 0, line: line, digest: "d-\(text)"),
                         picked: picked)
        }
        let launch = LeftoverProject(
            projectFolder: "W-1 Launch", projectName: "Launch", isArchived: false,
            sittings: [
                LeftoverSitting(session: "2026-09-14", sessionOrdinal: 0, sessionDigest: "s1", startTime: nil,
                                name: "", lede: "Nav spec",
                                tasks: [task("Draft the spec", line: 0, session: "2026-09-14")]),
                LeftoverSitting(session: "2026-09-16", sessionOrdinal: 0, sessionDigest: "s2", startTime: "2:15 PM",
                                name: "Venue", lede: "Venue",
                                tasks: [task("Book the venue", line: 0, session: "2026-09-16",
                                             picked: PickMark(into: CanvasTaskLists.todayISO(), at: "")),
                                        task("Call the second venue", line: 2, depth: 1, session: "2026-09-16")]),
            ])
        let site = LeftoverProject(
            projectFolder: "W-2 Site", projectName: "Site", isArchived: false,
            sittings: [LeftoverSitting(session: "2026-09-15", sessionOrdinal: 0, sessionDigest: "s3", startTime: nil,
                                       name: "", lede: "", tasks: [task("Proofread", line: 0, session: "2026-09-15")])])
        return LeftoverList(projects: [launch, site])
    }

    /// One group per sitting, in the contract's order; the first of each project's heads the project.
    func testLeftoversGroupsAreSittingsUnderTheirProjects() throws {
        let groups = CanvasTaskLists.groups(leftovers: leftovers())
        XCTAssertEqual(groups.map(\.folder), ["W-1 Launch", "W-1 Launch", "W-2 Site"])
        XCTAssertEqual(groups.compactMap(\.sitting?.startsProject), [true, false, true])
        XCTAssertEqual(groups[1].sitting?.lede, "Venue")
        XCTAssertEqual(groups[1].sitting?.ref, SessionRef(date: "2026-09-16", ordinal: 0, digest: "s2"),
                       "enough to drag it off as a card of its own")
        XCTAssertEqual(groups[1].items.map { $0.row().depth }, [0, 1])
        XCTAssertEqual(groups[1].items.first?.hit.ref,
                       TaskRefInput(session: "2026-09-16", sessionOrdinal: 0, line: 0, digest: "d-Book the venue"))
        XCTAssertEqual(CanvasTaskLists.summary(.leftovers, groups), "4 tasks · 3 sittings · 2 projects")
        XCTAssertEqual(CanvasTaskLists.summary(.leftovers, []), "Nothing left open")
        XCTAssertEqual(CanvasTaskLists.order(groups)["W-1 Launch"]?.count, 3, "⇧ reaches across a project's sittings")
    }

    /// Pick Up where a row isn't already picked up today; Put Back where it is. Neither on Waiting or Search.
    func testALeftoverOffersPickUpAndPutBack() throws {
        let items = CanvasTaskLists.groups(leftovers: leftovers()).flatMap(\.items)
        let old = try XCTUnwrap(items.first { $0.hit.text == "Draft the spec" }).row()
        let today = try XCTUnwrap(items.first { $0.hit.text == "Book the venue" }).row()
        XCTAssertFalse(old.pickedUp)
        XCTAssertTrue(today.pickedUp)
        XCTAssertEqual(CanvasDayAction.offered(forTasks: [old], picking: true), [.complete, .drop, .focus, .pickUp])
        XCTAssertEqual(CanvasDayAction.offered(forTasks: [today], picking: true), [.complete, .drop, .focus, .putBack])
        XCTAssertEqual(CanvasDayAction.offered(forTasks: [old]), [.complete, .drop, .focus])
        let yesterday = CanvasTaskItem(hit: try hit("Old pick"), picked: PickMark(into: "2020-01-01", at: ""))
        XCTAssertFalse(yesterday.row().pickedUp, "a pick into an older sitting can be picked up again")
    }

    // MARK: Coming up and Projects (step 7)

    /// Coming up reads its period as a horizon and has no yesterday; a new one starts a week out.
    /// Projects has no period at all.
    func testComingUpAndProjectsAreViews() throws {
        let comingUp = try XCTUnwrap(CanvasViewSpec.of(node(["pmView": .string("coming-up")])))
        XCTAssertEqual(comingUp.kind, .comingUp)
        XCTAssertEqual(comingUp.kind.periods, [.today, .week])
        XCTAssertEqual(comingUp.kind.title(of: .week), "Next 7 Days")
        XCTAssertEqual(comingUp.kind.title(of: .today), "Due Today")
        XCTAssertEqual(CanvasViewSpec.Kind.leftovers.title(of: .week), "Before This Week")
        XCTAssertEqual(CanvasViewSpec.Kind.day.title(of: .week), "This Week")
        var card = node(["pmView": .string("coming-up")])
        CanvasViewSpec.set(.newComingUp, on: &card)
        XCTAssertEqual(card.extra, ["pmView": .string("coming-up"), "pmPeriod": .string("week"),
                                    "pmProjects": .string("board")])

        XCTAssertEqual(CanvasViewSpec.of(node(["pmView": .string("projects")]))?.kind, .projects)
        XCTAssertFalse(CanvasViewSpec.Kind.projects.hasPeriod)
    }

    /// Overdue under one heading, then Today, Tomorrow, and the date.
    func testComingUpGroupsByDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 18, hour: 12))!
        func due(_ text: String, _ day: String, line: Int) throws -> TaskSearchHit {
            var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(try hit(text, line: line))) as! [String: Any]
            object["due"] = day
            return try JSONDecoder().decode(TaskSearchHit.self, from: JSONSerialization.data(withJSONObject: object))
        }
        let hits = [try due("Old", "2026-09-10", line: 0), try due("Older", "2026-09-16", line: 1),
                    try due("Now", "2026-09-18", line: 2), try due("Next", "2026-09-19", line: 3),
                    try due("Later", "2026-09-22", line: 4)]
        let groups = CanvasTaskLists.groups(due: hits, now: now, calendar: calendar)
        XCTAssertEqual(groups.map(\.title), ["Overdue", "Today", "Tomorrow", "Tue, Sep 22"])
        XCTAssertEqual(groups.map(\.state), ["overdue", nil, nil, nil])
        XCTAssertEqual(groups.first?.hits.count, 2)
        XCTAssertEqual(CanvasTaskLists.summary(.comingUp, groups), "5 due · 2 overdue")
        XCTAssertEqual(CanvasTaskLists.summary(.comingUp, []), "Nothing due")
    }

    /// When a project was last worked on, as a person says it; what's open and next due under its name.
    func testAProjectRowSaysHowLongItsBeen() {
        let now = Date()
        func project(daysAgo: Double?) -> ProjectSummary {
            var summary = ProjectSummary(folder: "W-1 Launch", name: "Launch", kind: "project", scope: "active", path: "")
            summary.lastActivity = daysAgo.map { ISO8601DateFormatter().string(from: now.addingTimeInterval(-$0 * 86_400)) }
            return summary
        }
        XCTAssertEqual(CanvasProjectRows.lastWorked(project(daysAgo: 0), now: now), "Today")
        XCTAssertEqual(CanvasProjectRows.lastWorked(project(daysAgo: 3), now: now), "3 days ago")
        XCTAssertEqual(CanvasProjectRows.lastWorked(project(daysAgo: 21), now: now), "3 weeks ago")
        XCTAssertEqual(CanvasProjectRows.lastWorked(project(daysAgo: nil), now: now), "Never")
        var busy = project(daysAgo: 1)
        busy.open = 4
        busy.nextDue = "2026-09-22"
        XCTAssertTrue(CanvasProjectRows.detail(busy).hasPrefix("4 open · next due "))
        XCTAssertEqual(CanvasProjectRows.detail(project(daysAgo: 1)), "Nothing open")
        XCTAssertEqual(CanvasProjectRows.summary([busy, project(daysAgo: 40)], now: now), "1 moving · 1 quiet")
    }

    // MARK: Layouts (step 8)

    private var chicago: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        calendar.firstWeekday = 1
        return calendar
    }

    /// Friday the 18th, mid-morning.
    private var friday: Date { chicago.date(from: DateComponents(year: 2026, month: 9, day: 18, hour: 10))! }

    /// `pmLayout` reads as written and is left off at List; a layout a view doesn't offer, or the rail on
    /// more than one day, draws the list and keeps what was set.
    func testALayoutIsOnTheNodeAndDrawnOnlyWhereItFits() {
        var card = node(["pmView": .string("day"), "pmLayout": .string("Month")])
        XCTAssertEqual(CanvasViewSpec.of(card)?.layout, .month)
        XCTAssertEqual(CanvasViewSpec.of(node(["pmView": .string("day"), "pmLayout": .string("gantt")]))?.layout, .list)
        CanvasViewSpec.set(CanvasViewSpec(kind: .day), on: &card)
        XCTAssertNil(card.extra["pmLayout"], "List is the default, and isn't written")

        var rail = CanvasViewSpec(kind: .day, layout: .rail)
        XCTAssertEqual(rail.shownLayout, .rail)
        rail.period = .week
        XCTAssertEqual(rail.shownLayout, .list, "The rail is one day's")
        XCTAssertEqual(rail.layout, .rail, "and is kept for when it's one day again")
        XCTAssertEqual(CanvasViewSpec(kind: .comingUp, layout: .rail).shownLayout, .list)
        XCTAssertEqual(CanvasViewSpec(kind: .comingUp, layout: .month).shownLayout, .month)
        XCTAssertEqual(CanvasViewSpec(kind: .waiting, layout: .week).shownLayout, .list)
        XCTAssertEqual(CanvasViewSpec.Kind.day.layouts, [.list, .rail, .week, .month])
        XCTAssertEqual(CanvasViewSpec.Kind.leftovers.layouts, [.list])
    }

    /// A Day's week and month are the calendar's, around the period's first day: whole weeks, from the
    /// reader's first weekday.
    func testADaysWeekAndMonthAreTheCalendars() throws {
        let week = try XCTUnwrap(CanvasViewSpec(kind: .day, layout: .week).calendarSpan(now: friday, calendar: chicago))
        XCTAssertEqual(week.days.first, "2026-09-13")
        XCTAssertEqual(week.days.last, "2026-09-19")
        XCTAssertEqual(week.title, "This Week · Sep 13–19")
        XCTAssertEqual(week.range.start, chicago.date(from: DateComponents(year: 2026, month: 9, day: 13)))
        XCTAssertEqual(week.range.end, chicago.date(from: DateComponents(year: 2026, month: 9, day: 20)))

        let month = try XCTUnwrap(CanvasViewSpec(kind: .day, layout: .month).calendarSpan(now: friday, calendar: chicago))
        XCTAssertEqual(month.title, "September 2026")
        XCTAssertEqual(month.month, "2026-09")
        XCTAssertEqual(month.days.first, "2026-08-30", "The Sunday before the 1st")
        XCTAssertEqual(month.days.last, "2026-10-03", "The Saturday after the 30th")
        XCTAssertEqual(month.days.count, 35)

        let june = try XCTUnwrap(CanvasViewSpec(kind: .day, period: .day("2026-06-03"), layout: .month)
            .calendarSpan(now: friday, calendar: chicago))
        XCTAssertEqual(june.title, "June 2026")
        XCTAssertEqual(june.days.first, "2026-05-31")
        XCTAssertNil(try CanvasViewSpec(kind: .day).calendarSpan(now: friday, calendar: chicago), "A list draws its period")
    }

    /// Coming up rolls: its week is the next seven days, and its month five weeks from this one's start —
    /// both starting today, whatever the period. The grid asks `dueCutoff` for that span, the same
    /// function the list draws from, so the two can never disagree.
    func testComingUpsWeekAndMonthLookAhead() throws {
        let week = try XCTUnwrap(CanvasViewSpec(kind: .comingUp, period: .today, layout: .week)
            .calendarSpan(now: friday, calendar: chicago))
        XCTAssertEqual(week.days, ["2026-09-18", "2026-09-19", "2026-09-20", "2026-09-21", "2026-09-22",
                                   "2026-09-23", "2026-09-24"], "Whatever its period, today and on")
        let weekOfWeek = try XCTUnwrap(CanvasViewSpec(kind: .comingUp, period: .week, layout: .week)
            .calendarSpan(now: friday, calendar: chicago))
        XCTAssertEqual(weekOfWeek.days, week.days, "Period: Week is the week grid's own horizon")
        let month = try XCTUnwrap(CanvasViewSpec(kind: .comingUp, period: .month, layout: .month)
            .calendarSpan(now: friday, calendar: chicago))
        XCTAssertEqual(month.days.first, "2026-09-13")
        XCTAssertEqual(month.days.last, "2026-10-17")
        XCTAssertNil(month.month)
    }

    /// The grid's span is the period's, not a second calculation: a period reaching further than the
    /// grid's own shape widens it, rather than being silently discarded.
    func testComingUpsGridFollowsAFartherPeriod() throws {
        let pinned = try XCTUnwrap(CanvasViewSpec(kind: .comingUp, period: .day("2026-10-30"), layout: .week)
            .calendarSpan(now: friday, calendar: chicago))
        XCTAssertGreaterThan(pinned.days.count, 7, "Through Oct 30 is farther out than the week grid's own 7 days")
        XCTAssertEqual(pinned.days.last, "2026-10-30")
    }

    /// Paging a week or month pins the period to that span's first day, and paging back to the one
    /// today is in follows the clock again.
    func testPagingPinsAndComesBackToToday() throws {
        let week = CanvasViewSpec(kind: .day, layout: .week)
        XCTAssertEqual(try week.stepped(by: -1, now: friday, calendar: chicago), .day("2026-09-06"))
        let back = CanvasViewSpec(kind: .day, period: .day("2026-09-06"), layout: .week)
        XCTAssertEqual(try back.stepped(by: 1, now: friday, calendar: chicago), .today)
        XCTAssertFalse(back.showsToday(now: friday, calendar: chicago))
        XCTAssertTrue(week.showsToday(now: friday, calendar: chicago))
        XCTAssertEqual(try back.calendarSpan(now: friday, calendar: chicago)?.title, "Week of Sep 6")

        let month = CanvasViewSpec(kind: .day, layout: .month)
        XCTAssertEqual(try month.stepped(by: -1, now: friday, calendar: chicago), .day("2026-08-01"))
        XCTAssertEqual(try month.stepped(by: 1, now: friday, calendar: chicago), .day("2026-10-01"))
        XCTAssertNil(try CanvasViewSpec(kind: .comingUp, layout: .week).stepped(by: 1, now: friday, calendar: chicago))
        XCTAssertNil(try CanvasViewSpec(kind: .day).stepped(by: 1, now: friday, calendar: chicago))
    }

    /// A heading's time as minutes past midnight, noon and midnight included.
    func testAHeadingsTimeIsMinutesPastMidnight() {
        XCTAssertEqual(CanvasTimeGrid.minutes(of: "9:10 AM"), 550)
        XCTAssertEqual(CanvasTimeGrid.minutes(of: "2:15 PM"), 855)
        XCTAssertEqual(CanvasTimeGrid.minutes(of: "12:30 PM"), 750)
        XCTAssertEqual(CanvasTimeGrid.minutes(of: "12:05 AM"), 5)
        XCTAssertNil(CanvasTimeGrid.minutes(of: nil))
        XCTAssertNil(CanvasTimeGrid.minutes(of: "Week in review"))
    }

    /// The rail: back to back when a block is longer than the time to the next, further apart when the
    /// time between them is longer than the block — and an untimed one just follows.
    func testTheRailSpacesBlocksByTheTimeBetweenThem() {
        XCTAssertEqual(CanvasTimeGrid.railTops(heights: [40, 40, 40], minutes: [nil, 600, 610], perMinute: 1, gap: 0),
                       [0, 40, 80])
        XCTAssertEqual(CanvasTimeGrid.railTops(heights: [50, 20], minutes: [540, 840], perMinute: 1, gap: 0),
                       [0, 300], "Five hours apart is 300 points of rail")
        XCTAssertEqual(CanvasTimeGrid.railTops(heights: [120, 20, 20], minutes: [540, 600, 840], perMinute: 1, gap: 4),
                       [0, 124, 364], "Measured from where the last timed block landed, not where it would have")
    }

    /// A week's grid is the working day, widened for an early or late sitting; a column pushes a block
    /// down when two began too close together to fit.
    func testAWeeksGridTakesInEverySitting() {
        XCTAssertEqual(CanvasTimeGrid.hours(for: []), 9...17)
        XCTAssertEqual(CanvasTimeGrid.hours(for: [7 * 60 + 30, 20 * 60 + 10]), 7...21)
        XCTAssertEqual(CanvasTimeGrid.columnTops(minutes: [540, 550, 660], firstHour: 9, perHour: 46, blockHeight: 44),
                       [0, 46, 92])
        XCTAssertEqual(CanvasTimeGrid.columnTops(minutes: [600], firstHour: 9, perHour: 46, blockHeight: 44), [46])
    }

    /// The rail's order is the day's: an untimed sitting first, then sittings and stray completions by
    /// their times.
    func testTheRailIsInTheOrderTheDayWent() throws {
        func sitting(_ time: String?, _ name: String) -> String {
            """
            {"projectFolder": "W-1 Redesign", "projectName": "Redesign", "isArchived": false,
             "session": "2026-09-18", "sessionOrdinal": 0, "sessionDigest": "\(name)",
             \(time.map { #""startTime": "\#($0)","# } ?? "") "name": "\(name)", "prose": "", "isCurrent": false,
             "written": [], "picked": [], "finished": [], "dropped": []}
            """
        }
        let tick = ISO8601DateFormatter().string(from: chicago.date(from: DateComponents(year: 2026, month: 9, day: 18, hour: 16, minute: 2))!)
        let json = """
        {"sittings": [\(sitting("2:15 PM", "c")), \(sitting("9:10 AM", "b")), \(sitting(nil, "a"))],
         "elsewhere": [{"projectFolder": "H-1 Home", "projectName": "Home", "isArchived": false,
                        "at": "\(tick)", "text": "Renew passport", "dropped": false}]}
        """
        let list = try JSONDecoder().decode(SittingList.self, from: Data(json.utf8))
        let entries = CanvasTimeGrid.railEntries(list, calendar: chicago)
        XCTAssertEqual(entries.map(\.minute), [nil, 550, 855, 16 * 60 + 2])
        XCTAssertEqual(CanvasTimeGrid.ordered(list.sittings).map(\.name), ["a", "b", "c"])
    }

    // MARK: How much a calendar says

    func testAMonthsDaySaysMoreAsItHasRoom() {
        typealias D = CanvasCalendarDetail
        // Too narrow for a name, or too small on screen to read: dots.
        XCTAssertEqual(D.monthCell(sittings: 3, width: 50, lines: 6, readable: true), .dots)
        XCTAssertEqual(D.monthCell(sittings: 3, width: 150, lines: 6, readable: false), .dots)
        // Room for everyone twice over, and width for a lede: two lines each.
        XCTAssertEqual(D.monthCell(sittings: 3, width: 150, lines: 6, readable: true), .ledes)
        // Room for names but not ledes, or not the width for them.
        XCTAssertEqual(D.monthCell(sittings: 3, width: 150, lines: 5, readable: true), .names(shown: 3))
        XCTAssertEqual(D.monthCell(sittings: 3, width: 80, lines: 6, readable: true), .names(shown: 3))
        // More than fit: the last line is how many more.
        XCTAssertEqual(D.monthCell(sittings: 5, width: 150, lines: 3, readable: true), .names(shown: 2))
        // One line is no room for a name and a count.
        XCTAssertEqual(D.monthCell(sittings: 2, width: 150, lines: 1, readable: true), .dots)
        XCTAssertEqual(D.monthCell(sittings: 1, width: 150, lines: 1, readable: true), .names(shown: 1))
    }

    func testAWeeksBlockSaysMoreAsItHasRoom() {
        typealias D = CanvasCalendarDetail
        // What it always said: the time, the project, a line of lede.
        XCTAssertEqual(D.weekBlock(lines: 1, width: 100, finished: 4, readable: true), .init(lede: 1))
        // Then what came of it, then the tasks it finished, then more lede.
        XCTAssertEqual(D.weekBlock(lines: 2, width: 100, finished: 4, readable: true), .init(lede: 1, counts: true))
        XCTAssertEqual(D.weekBlock(lines: 4, width: 100, finished: 4, readable: true),
                       .init(lede: 1, counts: true, tasks: 2))
        XCTAssertEqual(D.weekBlock(lines: 9, width: 100, finished: 4, readable: true),
                       .init(lede: 3, counts: true, tasks: 4))
        XCTAssertEqual(D.weekBlock(lines: 9, width: 100, finished: 0, readable: true), .init(lede: 3, counts: true))
        // Narrow, or unreadable: colour and a name.
        XCTAssertEqual(D.weekBlock(lines: 9, width: 50, finished: 4, readable: true), .init(time: false))
        XCTAssertEqual(D.weekBlock(lines: 9, width: 100, finished: 4, readable: false), .init(time: false))
    }

    func testAWeeksHoursFillTheCard() {
        typealias D = CanvasCalendarDetail
        XCTAssertEqual(D.perHour(available: 200, hours: 8, minimum: 46), 46)
        XCTAssertEqual(D.perHour(available: 800, hours: 8, minimum: 46), 100)
        XCTAssertEqual(D.column(width: 100), .compact)
        XCTAssertEqual(D.column(width: 180), .regular)
        XCTAssertEqual(D.column(width: 260), .named)
    }

    func testSmallPrintGivesWayWhenTheBoardIsZoomedOut() {
        XCTAssertTrue(CanvasCalendarDetail.finePrintReadable(zoom: 1, scale: 1))
        XCTAssertFalse(CanvasCalendarDetail.finePrintReadable(zoom: 1, scale: 0.6))
        // The card's own zoom makes its type larger, so it reads further out.
        XCTAssertTrue(CanvasCalendarDetail.finePrintReadable(zoom: 1.5, scale: 0.6))
        // Still readable above where the card becomes its label.
        XCTAssertLessThan(CanvasDetail.simplifiedBelow, 0.75)
    }

    // MARK: Period ▸ as a grid of periods and layouts

    /// Only the pairs that draw something sensible: a day down a rail, a week in seven columns, a
    /// month as a grid — and every period as a list.
    func testTheDayGridOffersOnlyTheLayoutsEachPeriodCanTake() {
        let rows = CanvasViewSpec.spans(for: .day, pinned: [])
        XCTAssertEqual(rows.map(\.period), [.today, .yesterday, .week, .month])
        XCTAssertEqual(rows.map(\.layouts), [[.list, .rail], [.list, .rail], [.list, .week], [.list, .month]])
    }

    /// Next 5 Weeks as a list is on offer; it used to exist only as the month grid.
    func testComingUpOffersFiveWeeksAsAList() {
        let rows = CanvasViewSpec.spans(for: .comingUp, pinned: [])
        XCTAssertEqual(rows.map(\.period), [.today, .week, .month])
        XCTAssertEqual(rows.last?.layouts, [.list, .month])
        XCTAssertTrue(CanvasViewSpec.spans(for: .search, pinned: []).isEmpty)
    }

    func testAPinnedDayStaysOnOfferOnce() {
        let rows = CanvasViewSpec.spans(for: .day, pinned: [.day("2026-06-03"), .day("2026-06-03")])
        XCTAssertEqual(rows.count, 5)
        XCTAssertEqual(rows.last?.layouts, [.list, .rail])
    }

    /// A Day paged back to this week by its header is Today laid out as a week, and ticks This Week.
    func testTheTickFollowsWhatTheCardDraws() {
        var spec = CanvasViewSpec(kind: .day, period: .today, projects: .everything)
        spec.layout = .week
        XCTAssertTrue(spec.shows(.week, as: .week))
        XCTAssertFalse(spec.shows(.today, as: .list))
        spec.layout = .rail
        XCTAssertTrue(spec.shows(.today, as: .rail))
        spec.period = .week
        XCTAssertTrue(spec.shows(.week, as: .list), "a rail over a week draws as a list")
    }
}
