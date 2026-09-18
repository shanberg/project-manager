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
        XCTAssertEqual(card.extra, ["pmView": .string("search")], "an empty search carries no query")
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
        XCTAssertEqual(CanvasViewSpec.newLeftovers.noteText, "Tasks left open before today, across projects: a Folio view.")
        CanvasViewSpec.set(.newLeftovers, on: &card)
        XCTAssertEqual(card.extra, ["pmView": .string("leftovers")])
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
        XCTAssertEqual(card.extra, ["pmView": .string("coming-up"), "pmPeriod": .string("week")])

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
}
