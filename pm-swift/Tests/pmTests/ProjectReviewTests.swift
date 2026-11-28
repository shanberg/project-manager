import XCTest
import Foundation
@testable import PmLib

/// Reviewing a project: review sittings, "since last time", and the reasons a project is creaky. See
/// docs/project-review.md.
final class ProjectReviewTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// Noon on Sat, Nov 28, 2026.
    private let now = ISO8601DateFormatter().date(from: "2026-11-28T12:00:00Z")!

    private func sitting(_ date: String, _ label: String = "9:00 AM", body: String = "Thought about it.") -> Session {
        Session(date: date, label: label, body: body)
    }

    private func task(_ text: String, on day: String, session: Int = 0, line: Int = 0, due: String? = nil,
                      waiting: String? = nil, focused: Bool = false, checked: Bool = false) -> Todo {
        var todo = Todo(text: text, checked: checked, rawLine: "- [ ] \(text)", context: "", sessionIndex: session,
                        lineIndex: line, isFocused: focused, dueDate: due, waiting: waiting, sessionISODate: day)
        todo.effectiveDueDate = due
        todo.effectiveWaiting = waiting
        return todo
    }

    private func notes(_ sessions: [Session], summary: String = "A thing", goals: [String] = ["Ship it", "", ""],
                       problem: String = "It's broken", approach: String = "Fix it") -> ProjectNotes {
        ProjectNotes(title: "Thing", summary: summary, problem: problem, goals: goals, approach: approach,
                     sessions: sessions)
    }

    // MARK: Review sittings

    func testASittingNamedReviewIsOne() {
        XCTAssertTrue(ProjectReview.isReview(sitting("Sat, Nov 28, 2026", "9:10 AM · Review")))
        XCTAssertTrue(ProjectReview.isReview(sitting("Sat, Nov 28, 2026", "9:10 AM · review")))
        XCTAssertTrue(ProjectReview.isReview(sitting("Sat, Nov 28, 2026", "9:10 AM · Review: Q4")))
        XCTAssertTrue(ProjectReview.isReview(sitting("Sat, Nov 28, 2026", "Review")))
    }

    func testOnlyTheNameCounts() {
        XCTAssertFalse(ProjectReview.isReview(sitting("Sat, Nov 28, 2026", "9:10 AM")))
        XCTAssertFalse(ProjectReview.isReview(sitting("Sat, Nov 28, 2026", "9:10 AM · Code review")))
        XCTAssertFalse(ProjectReview.isReview(sitting("Sat, Nov 28, 2026", "9:10 AM · Reviewers sync")))
        XCTAssertFalse(ProjectReview.isReview(sitting("Sat, Nov 28, 2026", "9:10 AM", body: "Review the deck")))
    }

    func testLastReviewedIsTheNewestReviewSitting() {
        let n = notes([
            sitting("Fri, Nov 27, 2026"),
            sitting("Tue, Nov 10, 2026", "9:00 AM · Review"),
            sitting("Mon, Oct 12, 2026", "9:00 AM · Review"),
        ])
        XCTAssertEqual(ProjectReview.lastReviewIndex(in: n), 1)
        XCTAssertEqual(ProjectReview.lastReviewIndex(in: n, after: 1), 2)
        XCTAssertNil(ProjectReview.lastReviewIndex(in: n, after: 2))
        XCTAssertEqual(ProjectReview.lastReviewed(n, calendar: calendar),
                       ISO8601DateFormatter().date(from: "2026-11-10T00:00:00Z"))
        XCTAssertNil(ProjectReview.lastReviewed(notes([sitting("Fri, Nov 27, 2026")]), calendar: calendar))
    }

    /// A finished review writes a line saying so, which keeps it a review once its sitting is renamed.
    func testARenamedReviewStillCounts() {
        let renamed = sitting("Tue, Nov 10, 2026", "9:00 AM · Planning Q1", body: "Thoughts.\n\nReviewed: kept 3 · dropped 1.")
        XCTAssertFalse(ProjectReview.isReview(renamed))
        XCTAssertTrue(ProjectReview.wasReview(renamed))
        XCTAssertTrue(ProjectReview.wasReview(sitting("Tue, Nov 10, 2026", "9:00 AM", body: "Reviewed.")))
        XCTAssertFalse(ProjectReview.wasReview(sitting("Tue, Nov 10, 2026", "9:00 AM", body: "Reviewed the deck with Dana.")))
        let n = notes([sitting("Fri, Nov 27, 2026"), renamed])
        XCTAssertEqual(ProjectReview.lastReviewIndex(in: n), 1)
    }

    /// Opened and left without a word: not a review.
    func testAnEmptyReviewSittingDoesntCount() {
        let n = notes([
            sitting("Sat, Nov 28, 2026", "9:00 AM · Review", body: "\n"),
            sitting("Tue, Nov 10, 2026", "9:00 AM · Review"),
        ])
        XCTAssertEqual(ProjectReview.lastReviewIndex(in: n), 1)
    }

    // MARK: Since last time

    func testSinceLastTimeIsTheSittingsAfterTheLastReview() {
        let n = notes([
            sitting("Sat, Nov 28, 2026", "9:00 AM · Review"),   // the review in progress
            sitting("Fri, Nov 27, 2026"),
            sitting("Thu, Nov 19, 2026"),
            sitting("Tue, Nov 10, 2026", "9:00 AM · Review"),
            sitting("Mon, Nov 2, 2026"),
        ])
        XCTAssertEqual(ProjectReview.sittingsSince(n, current: 0, now: now, calendar: calendar), [1, 2])
    }

    /// Never reviewed: the last three weeks, which is as far back as Catch Up doesn't reach.
    func testAFirstReviewLooksBackThreeWeeks() {
        let n = notes([
            sitting("Sat, Nov 28, 2026", "9:00 AM · Review"),
            sitting("Fri, Nov 20, 2026"),
            sitting("Sat, Nov 7, 2026"),
            sitting("Wed, Oct 14, 2026"),
        ])
        XCTAssertEqual(ProjectReview.sittingsSince(n, current: 0, now: now, calendar: calendar), [1, 2])
    }

    // MARK: Health

    func testAHealthyProjectIsntCreaky() {
        let n = notes([sitting("Fri, Nov 27, 2026")])
        let health = ProjectHealth(notes: n, todos: [task("Fresh", on: "2026-11-27")], now: now, calendar: calendar)
        XCTAssertFalse(health.isCreaky)
        XCTAssertEqual(health.reasons, [])
        XCTAssertEqual(health.score, 0)
        XCTAssertEqual(health.daysSinceLastSitting, 1)
        XCTAssertNil(health.daysSinceReview)
    }

    func testEachKindOfCreak() {
        let n = notes([sitting("Fri, Nov 27, 2026"), sitting("Tue, Sep 1, 2026")])
        let todos = [
            task("Late", on: "2026-11-27", session: 0, line: 0, due: "2026-01-05"),
            task("Waiting on the launch", on: "2026-11-27", session: 0, line: 1, waiting: "W-2 Launch"),
            task("Waiting on Dana", on: "2026-11-27", session: 0, line: 2, waiting: "Dana"),
            task("Forgotten", on: "2026-09-01", session: 1, line: 0),
            task("Focus", on: "2026-09-01", session: 1, line: 1, focused: true),
        ]
        let health = ProjectHealth(notes: n, todos: todos, isReleased: { $0 == "W-2 Launch" },
                                   now: now, calendar: calendar)
        XCTAssertEqual(health.overdue, 1)
        XCTAssertEqual(health.releasedWaits, 1)
        XCTAssertEqual(health.staleTrees, 1)
        XCTAssertTrue(health.focusGoneQuiet)
        XCTAssertFalse(health.hasGoneQuiet)
        XCTAssertTrue(health.isCreaky)
        XCTAssertEqual(health.reasons, ["1 overdue", "1 wait released", "1 stale task", "focus untouched for 3+ weeks"])
    }

    func testAQuietProjectSaysForHowLong() {
        let n = notes([sitting("Mon, Oct 19, 2026")])
        let health = ProjectHealth(notes: n, todos: [], now: now, calendar: calendar)
        XCTAssertEqual(health.daysSinceLastSitting, 40)
        XCTAssertTrue(health.hasGoneQuiet)
        XCTAssertTrue(health.isCreaky)
        XCTAssertEqual(health.reasons, ["no sitting for 5 weeks"])
    }

    /// An empty brief is reported, for the review's brief step, but on its own it isn't a creak.
    func testAnEmptyBriefIsReportedButIsntACreak() {
        let n = notes([sitting("Fri, Nov 27, 2026")], summary: " ", goals: ["", "", ""], problem: "", approach: "")
        let project = ProjectHealth(notes: n, todos: [], now: now, calendar: calendar)
        XCTAssertEqual(project.emptyBrief, ["Summary", "Problem", "Goals", "Approach"])
        XCTAssertFalse(project.isCreaky)
        let area = ProjectHealth(notes: n, todos: [], kind: .area, now: now, calendar: calendar)
        XCTAssertEqual(area.emptyBrief, ["Summary", "Goals"])
    }

    /// The creakiest first: overdue work outweighs a pile of stale tasks.
    func testScoreRanksOverdueAboveStale() {
        let overdue = ProjectHealth(overdue: 2, daysSinceLastSitting: 1)
        let stale = ProjectHealth(staleTrees: 3, daysSinceLastSitting: 1)
        XCTAssertGreaterThan(overdue.score, stale.score)
    }

    func testClosedTasksDontCount() {
        let n = notes([sitting("Fri, Nov 27, 2026")])
        let todos = [task("Late but done", on: "2026-11-27", due: "2026-01-05", checked: true)]
        XCTAssertEqual(ProjectHealth(notes: n, todos: todos, now: now, calendar: calendar).overdue, 0)
    }
}
