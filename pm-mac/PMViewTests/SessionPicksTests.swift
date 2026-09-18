import XCTest
import PmLib
@testable import PMViewTests

/// What a card draws of picked-up work (docs/sessions.md D5): the Picked up group, the pile, and the
/// words on the chips.
final class SessionPicksTests: XCTestCase {

    private func task(_ text: String, session: Int, line: Int, depth: Int = 0, checked: Bool = false,
                      iso: String = "2026-09-02") -> Todo {
        let indent = String(repeating: "  ", count: depth)
        return Todo(text: text, checked: checked, rawLine: "\(indent)- [\(checked ? "x" : " ")] \(text)",
                    context: "", depth: depth, sessionIndex: session, lineIndex: line,
                    sessionISODate: iso)
    }

    private func pick(_ todo: Todo, into: Int, id: String = UUID().uuidString) -> TaskPick {
        TaskPick(id: id, at: "2026-09-17T15:00:00Z", sessionIndex: todo.sessionIndex,
                 lineIndex: todo.lineIndex, into: "2026-09-17", intoIndex: into)
    }

    // MARK: Picked up

    func testASittingDrawsWhatWasPickedUpIntoItInTheOrderItWasPickedUp() {
        let dana = task("Email Dana", session: 2, line: 0)
        let venue = task("Book the venue", session: 2, line: 1)
        let florist = task("Call the florist", session: 1, line: 0)
        let picks = [pick(venue, into: 0), pick(dana, into: 0), pick(florist, into: 1)]
        let drawn = SessionPicks.pickedUp(into: 0, picks: picks, todos: [florist, dana, venue])
        XCTAssertEqual(drawn.map(\.todo.text), ["Book the venue", "Email Dana"])
    }

    /// Two picks of one task into one sitting are one row: a duplicate id is what makes `ForEach`
    /// animate the wrong row.
    func testATaskPickedUpTwiceIntoOneSittingIsOneRow() {
        let dana = task("Email Dana", session: 2, line: 0)
        let drawn = SessionPicks.pickedUp(into: 0, picks: [pick(dana, into: 0), pick(dana, into: 0)],
                                          todos: [dana])
        XCTAssertEqual(drawn.count, 1)
    }

    /// A pick is a tree: a picked subtask draws the task it belongs to, and everything under it,
    /// with the chip on the top line only.
    func testAPickedSubtaskDrawsItsWholeTree() {
        let offsite = task("Plan the offsite", session: 2, line: 0)
        let room = task("Find a room", session: 2, line: 1, depth: 1)
        let catering = task("Book catering", session: 2, line: 2, depth: 1)
        let dana = task("Email Dana", session: 2, line: 3)
        let todos = [offsite, room, catering, dana]
        let drawn = SessionPicks.pickedUp(into: 0, picks: [pick(catering, into: 0)], todos: todos)
        XCTAssertEqual(drawn.map(\.todo.text), ["Plan the offsite", "Find a room", "Book catering"])
        XCTAssertEqual(drawn.map(\.showsOrigin), [true, false, false])
    }

    /// Two picks inside one tree (two subtasks picked by an older build, or the root and a subtask)
    /// draw the tree once.
    func testTwoPicksInOneTreeDrawItOnce() {
        let offsite = task("Plan the offsite", session: 2, line: 0)
        let room = task("Find a room", session: 2, line: 1, depth: 1)
        let catering = task("Book catering", session: 2, line: 2, depth: 1)
        let drawn = SessionPicks.pickedUp(into: 0, picks: [pick(room, into: 0), pick(catering, into: 0),
                                                           pick(offsite, into: 0)],
                                          todos: [offsite, room, catering])
        XCTAssertEqual(drawn.map(\.todo.text), ["Plan the offsite", "Find a room", "Book catering"])
    }

    // MARK: The pile

    /// Current's pile leaves out the latest sitting's own tasks and what it picked up — both are drawn
    /// above it — and keeps the rest in document order, which is newest origin first.
    func testThePileLeavesOutWhatTheLatestSittingAlreadyDraws() {
        let today = task("Draft the agenda", session: 0, line: 0, iso: "2026-09-17")
        let florist = task("Call the florist", session: 1, line: 0, iso: "2026-09-10")
        let dana = task("Email Dana", session: 2, line: 0)
        let venue = task("Book the venue", session: 2, line: 1)
        let rows = SessionPicks.pile(todos: [today, florist, venue, dana].shuffled(), excluding: 0,
                                     picks: [pick(dana, into: 0)]) { _ in true }
        XCTAssertEqual(rows.map(\.todo.text), ["Call the florist", "Book the venue"])
    }

    /// The pile leaves out the whole of a tree the latest sitting picked up, not only the line the pick
    /// names — the tree is drawn above it.
    func testThePileLeavesOutAPickedTreeWhole() {
        let today = task("Draft the agenda", session: 0, line: 0, iso: "2026-09-17")
        let offsite = task("Plan the offsite", session: 2, line: 0)
        let room = task("Find a room", session: 2, line: 1, depth: 1)
        let dana = task("Email Dana", session: 2, line: 2)
        let rows = SessionPicks.pile(todos: [today, offsite, room, dana], excluding: 0,
                                     picks: [pick(room, into: 0)]) { _ in true }
        XCTAssertEqual(rows.map(\.todo.text), ["Email Dana"])
    }

    /// A Tasks card is nothing but the pile, so nothing is left out of it.
    func testWithNoLatestSittingThePileIsEverythingVisible() {
        let today = task("Draft the agenda", session: 0, line: 0, iso: "2026-09-17")
        let done = task("Send invites", session: 0, line: 1, checked: true, iso: "2026-09-17")
        let dana = task("Email Dana", session: 2, line: 0)
        let rows = SessionPicks.pile(todos: [today, done, dana], excluding: nil,
                                     picks: [pick(dana, into: 0)]) { !$0.checked }
        XCTAssertEqual(rows.map(\.todo.text), ["Draft the agenda", "Email Dana"])
    }

    /// A subtask under its parent doesn't repeat the parent's chip; a row that starts its sitting's run
    /// carries one whatever its depth.
    func testASubtaskUnderItsParentCarriesNoChip() {
        let parent = task("Plan the offsite", session: 1, line: 0)
        let child = task("Find a room", session: 1, line: 1, depth: 1)
        let orphan = task("Confirm catering", session: 2, line: 1, depth: 1)
        let rows = SessionPicks.pile(todos: [parent, child, orphan], excluding: nil, picks: []) { _ in true }
        XCTAssertEqual(rows.map(\.showsOrigin), [true, false, true])
    }

    // MARK: Saying when

    func testADayThisYearLeavesTheYearOff() {
        let now = ISO8601DateFormatter().date(from: "2026-09-17T12:00:00Z")!
        XCTAssertEqual(SessionPicks.day(iso: "2026-09-02", now: now), "Sep 2")
        XCTAssertEqual(SessionPicks.day(iso: "2025-01-05", now: now), "Jan 5, 2025")
        XCTAssertNil(SessionPicks.day(iso: "Wed, Sep 2", now: now))
        XCTAssertNil(SessionPicks.day(iso: nil, now: now))
    }

    func testAPickedUpTaskSaysWhenOnItsOwnLine() {
        let now = ISO8601DateFormatter().date(from: "2026-09-17T12:00:00Z")!
        var dana = task("Email Dana", session: 2, line: 0)
        XCTAssertNil(SessionPicks.pickedDay(dana, now: now))
        dana.picked = PickMark(into: "2026-09-17", at: "2026-09-17T15:00:00Z")
        XCTAssertEqual(SessionPicks.pickedDay(dana, now: now), "Sep 17")

        // Every line of a picked tree carries the fact; only the top line says it.
        var room = task("Find a room", session: 2, line: 1, depth: 1)
        room.picked = dana.picked
        XCTAssertNil(SessionPicks.pickedDay(room, now: now))
    }

    // MARK: The sentence it was written in

    private let body = """

        Dana has the numbers from last year.

        Talked it through with Sam. The venue needs a deposit by Friday, so:
        - [ ] Email Dana
        - [ ] Book the venue
        """

    private var bodyTasks: [Todo] {
        [task("Email Dana", session: 2, line: 0), task("Book the venue", session: 2, line: 1)]
    }

    func testTheChipQuotesTheParagraphWrittenJustAboveTheTask() {
        XCTAssertEqual(SessionPicks.sentence(before: bodyTasks[0], body: body, tasks: bodyTasks),
                       "Talked it through with Sam. The venue needs a deposit by Friday, so:")
    }

    /// A task two rows under a paragraph was written beside the task between them.
    func testATaskUnderAnotherTaskHasNoSentenceOfItsOwn() {
        XCTAssertNil(SessionPicks.sentence(before: bodyTasks[1], body: body, tasks: bodyTasks))
    }

    func testTheHoverSaysWhichSittingEvenWithoutASentence() {
        let sessions = [Session(date: "Wed, Sep 2, 2026", label: "Offsite", body: body)]
        let tasks = [task("Email Dana", session: 0, line: 0), task("Book the venue", session: 0, line: 1)]
        XCTAssertEqual(SessionPicks.originHelp(tasks[1], sessions: sessions, tasks: tasks),
                       "Written Wed, Sep 2, 2026 · Offsite")
        XCTAssertTrue(SessionPicks.originHelp(tasks[0], sessions: sessions, tasks: tasks)
            .hasSuffix("deposit by Friday, so:"))
    }

    // MARK: A sitting's heading

    /// Noon on Fri, Sep 18, 2026 in the test's own calendar, so "today" doesn't depend on the clock.
    private var friday: (now: Date, calendar: Calendar) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 18, hour: 12))!
        return (now, calendar)
    }

    func testARecentSittingIsNamedForItsDayAndKeepsTheDateBesideIt() {
        let (now, calendar) = friday
        let today = SessionDay.heading("Fri, Sep 18, 2026", time: "10:40 AM", now: now, calendar: calendar)
        XCTAssertEqual(today.day, "Today")
        XCTAssertEqual(today.detail?.hasSuffix(" · 10:40 AM"), true)
        XCTAssertEqual(SessionDay.heading("Thu, Sep 17, 2026", now: now, calendar: calendar).day, "Yesterday")
        let tuesday = SessionDay.heading("Tue, Sep 15, 2026", now: now, calendar: calendar)
        XCTAssertNotEqual(tuesday.day, "Today")
        XCTAssertNotNil(tuesday.detail, "a weekday keeps its date beside it")
    }

    /// A day parsed at UTC midnight is the evening before west of Greenwich; the heading has to be the
    /// day the file says, wherever it's read.
    func testTodayIsTodayWestOfGreenwich() {
        var (now, calendar) = friday
        now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 18, hour: 21))!
        XCTAssertEqual(SessionDay.heading("Fri, Sep 18, 2026", now: now, calendar: calendar).day, "Today")
    }

    func testAnOlderSittingIsNamedForItsDate() {
        let (now, calendar) = friday
        let old = SessionDay.heading("Sat, Aug 22, 2026", now: now, calendar: calendar)
        XCTAssertEqual(old.day, SessionPicks.day(iso: "2026-08-22", now: now, calendar: calendar))
        XCTAssertNotNil(old.detail)
    }

    func testAHeadingItCannotReadIsShownAsWritten() {
        let heading = SessionDay.heading("Someday", now: friday.now, calendar: friday.calendar)
        XCTAssertEqual(heading.day, "Someday")
        XCTAssertNil(heading.detail)
    }
}
