import XCTest
import Foundation
@testable import PmLib

/// How a log of edges becomes spans of time. See docs/time-tracking.md D3 and D4.
final class AttentionLogTests: XCTestCase {

    // MARK: Building a log

    private let day = DateComponents(year: 2026, month: 9, day: 22)

    /// `9:00` on the test's day, in the machine's zone — the clock the assertions are written in.
    private func at(_ hour: Int, _ minute: Int = 0, calendar: Calendar = .current) -> Date {
        var parts = day
        parts.hour = hour
        parts.minute = minute
        return calendar.date(from: parts)!
    }

    private func began(_ project: String, _ when: Date, task: String? = nil) -> AttentionEvent {
        AttentionEvent(at: DoneLog.timestamp(when), event: .began, project: project,
                       key: "/PARA/active:\(project)", task: task)
    }

    private func ended(_ project: String, _ when: Date) -> AttentionEvent {
        AttentionEvent(at: DoneLog.timestamp(when), event: .ended, project: project,
                       key: "/PARA/active:\(project)")
    }

    private func minutes(_ span: AttentionSpan) -> Int { Int((span.seconds / 60).rounded()) }

    // MARK: A span with both its edges

    func testAMeasuredSpanIsWhatTheLogSays() {
        let spans = AttentionLog.spans(from: [began("W-1", at(9)), ended("W-1", at(10, 30))],
                                       now: at(12))
        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans.first?.basis, .measured)
        XCTAssertEqual(minutes(spans[0]), 90)
        XCTAssertEqual(spans.first?.project, "W-1")
    }

    /// One project at a time: arriving somewhere is leaving wherever you were.
    func testABeganEndsTheSpanBeforeIt() {
        let spans = AttentionLog.spans(from: [began("W-1", at(9)), began("W-2", at(9, 40))],
                                       evidence: ["W-1": [at(9, 35)]], now: at(12))
        XCTAssertEqual(spans.count, 2)
        XCTAssertEqual(spans[0].project, "W-1")
        XCTAssertEqual(minutes(spans[0]), 35, "closed by the evidence inside it, not by the next began")
        XCTAssertEqual(spans[0].basis, .inferred)
        XCTAssertEqual(spans[1].project, "W-2")
    }

    /// An `ended` naming a project that isn't the open one — Folio closing a span a later `began` from
    /// another surface already superseded. It bounds the open span without measuring it.
    func testAStaleEndedBoundsButDoesNotMeasure() {
        let spans = AttentionLog.spans(from: [began("W-1", at(9)), ended("W-2", at(9, 30))],
                                       now: at(12))
        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans[0].basis, .inferred)
        XCTAssertEqual(minutes(spans[0]), 30, "bounded by the edge all the same")
    }

    // MARK: Closing a span nothing closed (D4)

    /// The case the whole rule exists for: focus lands in the morning and moves at five, and that is
    /// not eight hours.
    func testAnUnclosedSpanRunsToTheLastEvidenceInIt() {
        let spans = AttentionLog.spans(from: [began("W-1", at(9)), began("W-2", at(17))],
                                       evidence: ["W-1": [at(9, 10), at(9, 20), at(16, 55)]],
                                       now: at(18))
        XCTAssertEqual(minutes(spans[0]), 475, "the latest evidence inside it, not the first")
        XCTAssertEqual(spans[0].basis, .inferred)
    }

    /// Proof beats the cap: a write at 11:40 says you were still there at 11:40.
    func testEvidenceBeyondTheCapIsCreditedInFull() {
        let spans = AttentionLog.spans(from: [began("W-1", at(9))],
                                       evidence: ["W-1": [at(11, 40)]], now: at(18))
        XCTAssertEqual(minutes(spans[0]), 160)
    }

    /// With nothing on record, an hour of the benefit of the doubt and no more.
    func testAnUnwitnessedSpanIsWorthTheCap() {
        let spans = AttentionLog.spans(from: [began("W-1", at(9)), began("W-2", at(17))], now: at(18))
        XCTAssertEqual(minutes(spans[0]), 60)
        XCTAssertEqual(spans[0].basis, .inferred)
    }

    /// Never past where attention demonstrably went elsewhere.
    func testAnInferredSpanIsClampedToTheNextEdge() {
        let spans = AttentionLog.spans(from: [began("W-1", at(9)), began("W-2", at(9, 20))],
                                       evidence: ["W-1": [at(9, 10), at(15, 0)]], now: at(18))
        XCTAssertEqual(minutes(spans[0]), 10, "the 15:00 write was in another project's time")
    }

    /// Evidence for one project says nothing about another's span.
    func testEvidenceIsPerProject() {
        let spans = AttentionLog.spans(from: [began("W-1", at(9)), began("W-2", at(17))],
                                       evidence: ["W-2": [at(9, 30)]], now: at(18))
        XCTAssertEqual(minutes(spans[0]), 60, "W-2's evidence doesn't extend W-1")
    }

    /// The span still running is bounded by the moment it's read, so a report for a past day doesn't
    /// grow every time anybody asks for it.
    func testTheOpenSpanStopsAtNow() {
        let spans = AttentionLog.spans(from: [began("W-1", at(9))],
                                       evidence: ["W-1": [at(9, 50)]], now: at(9, 30))
        XCTAssertEqual(minutes(spans[0]), 30)
    }

    func testASpanWithNothingAfterItsStartIsNotDrawn() {
        XCTAssertEqual(AttentionLog.spans(from: [began("W-1", at(9))], now: at(9)).count, 0)
    }

    // MARK: Days

    /// A day's total is a day's: a stretch across midnight is split, and each half keeps its basis.
    func testASpanAcrossMidnightIsSplit() {
        let start = at(23, 40)
        let end = at(23, 40).addingTimeInterval(50 * 60)   // 00:30 the next day
        let span = AttentionSpan(project: "W-1", key: "k", task: nil, start: start, end: end,
                                 basis: .measured)
        let split = AttentionLog.splittingAtMidnight([span])
        XCTAssertEqual(split.count, 2)
        XCTAssertEqual(minutes(split[0]), 20)
        XCTAssertEqual(minutes(split[1]), 30)
        XCTAssertEqual(split.map(\.basis), [.measured, .measured])
    }

    func testASpanInsideOneDayIsLeftAlone() {
        let span = AttentionSpan(project: "W-1", key: "k", task: nil, start: at(9), end: at(10),
                                 basis: .measured)
        XCTAssertEqual(AttentionLog.splittingAtMidnight([span]), [span])
    }

    /// Clipped rather than dropped: work that began at 23:50 on Monday is ten minutes of Monday.
    func testASpanStraddlingTheRangeIsClippedToIt() throws {
        let calendar = Calendar.current
        let range = try DoneRange.resolve(period: "today", since: nil, until: nil, now: at(12),
                                          calendar: calendar)
        let before = AttentionSpan(project: "W-1", key: "k", task: nil,
                                   start: at(0).addingTimeInterval(-20 * 60), end: at(0, 10),
                                   basis: .measured)
        let clipped = AttentionLog.clipped([before], to: range)
        XCTAssertEqual(clipped.count, 1)
        XCTAssertEqual(minutes(clipped[0]), 10)
    }

    func testASpanWhollyOutsideTheRangeIsDropped() throws {
        let range = try DoneRange.resolve(period: "today", since: nil, until: nil, now: at(12))
        let before = AttentionSpan(project: "W-1", key: "k", task: nil,
                                   start: at(0).addingTimeInterval(-60 * 60),
                                   end: at(0).addingTimeInterval(-30 * 60), basis: .measured)
        XCTAssertEqual(AttentionLog.clipped([before], to: range), [])
    }

    // MARK: The report

    private func span(_ project: String, _ from: Date, _ to: Date,
                      _ basis: AttentionSpan.Basis = .measured) -> AttentionSpan {
        AttentionSpan(project: project, key: "/PARA/active:\(project)", task: nil,
                      start: from, end: to, basis: basis)
    }

    func testTheReportIsLongestFirstAndTotalsEverything() {
        let report = tallying(spans: [span("W-1", at(9), at(9, 40)),
                                      span("W-2", at(10), at(12)),
                                      span("W-1", at(13), at(14, 30))],
                              sittings: SittingList(), named: [:])
        XCTAssertEqual(report.projects.map(\.projectFolder), ["W-1", "W-2"])
        XCTAssertEqual(Int(report.projects[0].seconds / 60), 130, "both of W-1's spans")
        XCTAssertEqual(Int(report.seconds / 60), 250)
        XCTAssertEqual(report.projects[0].spans.count, 2)
    }

    /// One guessed span makes the project's total a guess, and the report has to say so.
    func testOneInferredSpanMarksTheProject() {
        let report = tallying(spans: [span("W-1", at(9), at(10)),
                                      span("W-1", at(11), at(12), .inferred)],
                              sittings: SittingList(), named: [:])
        XCTAssertTrue(report.projects[0].inferred)
    }

    func testAMeasuredProjectIsNotMarked() {
        let report = tallying(spans: [span("W-1", at(9), at(10))], sittings: SittingList(), named: [:])
        XCTAssertFalse(report.projects[0].inferred)
    }

    // MARK: Saying how long

    func testDurationsReadInMinutesAndHours() {
        XCTAssertEqual(durationLabel(0), "<1m")
        XCTAssertEqual(durationLabel(20), "<1m")
        XCTAssertEqual(durationLabel(40 * 60), "40m")
        XCTAssertEqual(durationLabel(60 * 60), "1h")
        XCTAssertEqual(durationLabel(130 * 60), "2h 10m")
    }

    // MARK: The record itself

    func testAnEventRoundTripsThroughTheLogsLine() throws {
        let event = began("W-1", at(9), task: "Draft the brief")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let line = try encoder.encode(event)
        XCTAssertEqual(try JSONDecoder().decode(AttentionEvent.self, from: line), event)
    }

    /// "Not work" is a `counted` with no project, and the line says so by leaving the fields out.
    func testANotWorkAnswerHasNoProjectOnTheLine() throws {
        let event = counted(nil, at(11), at(12), answeredAt: at(13))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let line = try encoder.encode(event)
        let text = String(decoding: line, as: UTF8.self)
        XCTAssertFalse(text.contains("\"project\""), text)
        XCTAssertFalse(text.contains("\"key\""), text)
        XCTAssertEqual(try JSONDecoder().decode(AttentionEvent.self, from: line), event)
    }

    // MARK: Counting (docs/away-time.md)

    private func counted(_ project: String?, _ from: Date, _ to: Date, answeredAt: Date,
                         id: String = AttentionLog.newID()) -> AttentionEvent {
        AttentionEvent(id: id, at: DoneLog.timestamp(answeredAt), event: .counted, project: project,
                       key: project.map { "/PARA/active:\($0)" },
                       from: DoneLog.timestamp(from), to: DoneLog.timestamp(to))
    }

    private func withdrawn(_ ref: String, _ when: Date) -> AttentionEvent {
        AttentionEvent(at: DoneLog.timestamp(when), event: .withdrawn, project: nil, key: nil, ref: ref)
    }

    /// Pause at 11:00, back at 11:30, away counted for the same project: three spans, 2h in all.
    func testCountingAnAwayFillsTheGap() {
        let spans = AttentionLog.spans(from: [began("W-1", at(10)), ended("W-1", at(11)),
                                              began("W-1", at(11, 30)), ended("W-1", at(12)),
                                              counted("W-1", at(11), at(11, 30), answeredAt: at(12))],
                                       now: at(13))
        XCTAssertEqual(spans.map(\.basis), [.measured, .counted, .measured])
        XCTAssertEqual(spans.map(minutes), [60, 30, 30])
        XCTAssertEqual(spans.reduce(0) { $0 + $1.seconds } / 60, 120)
    }

    func testCountingForAnotherProjectMovesTheTime() {
        let spans = AttentionLog.spans(from: [began("W-1", at(9)), ended("W-1", at(12)),
                                              counted("W-2", at(10), at(11), answeredAt: at(13))],
                                       now: at(14))
        XCTAssertEqual(spans.map(\.project), ["W-1", "W-2", "W-1"])
        XCTAssertEqual(spans.map(minutes), [60, 60, 60])
        XCTAssertEqual(spans.map(\.basis), [.measured, .counted, .measured])
    }

    func testNotWorkTakesTimeAwayAndGivesItToNobody() {
        let spans = AttentionLog.spans(from: [began("W-1", at(9)), ended("W-1", at(12)),
                                              counted(nil, at(11), at(12), answeredAt: at(13))],
                                       now: at(14))
        XCTAssertEqual(spans.map(minutes), [120])
        XCTAssertEqual(spans.first?.basis, .measured)
    }

    /// Not work over an away that was never counted changes nothing — it only answers the question.
    func testNotWorkOverAGapChangesNothing() {
        let events = [began("W-1", at(10)), ended("W-1", at(11)), began("W-1", at(11, 30)),
                      ended("W-1", at(12))]
        let before = AttentionLog.spans(from: events, now: at(13))
        let after = AttentionLog.spans(from: events + [counted(nil, at(11), at(11, 30), answeredAt: at(12))],
                                       now: at(13))
        XCTAssertEqual(after, before)
    }

    /// The answer given later wins, whatever order the lines are in.
    func testTheLaterAnswerWins() {
        let first = counted("W-1", at(11), at(12), answeredAt: at(13))
        let second = counted("W-2", at(11), at(12), answeredAt: at(14))
        for order in [[first, second], [second, first]] {
            let spans = AttentionLog.spans(from: order, now: at(15))
            XCTAssertEqual(spans.map(\.project), ["W-2"])
            XCTAssertEqual(spans.map(minutes), [60])
        }
    }

    /// A later answer over part of an earlier one cuts it like any other span.
    func testALaterAnswerCutsAnEarlierOne() {
        let spans = AttentionLog.spans(from: [counted("W-1", at(11), at(13), answeredAt: at(14)),
                                              counted(nil, at(12), at(12, 30), answeredAt: at(15))],
                                       now: at(16))
        XCTAssertEqual(spans.map(minutes), [60, 30])
        XCTAssertEqual(spans.map(\.project), ["W-1", "W-1"])
    }

    func testWithdrawingPutsBackExactlyWhatWasThere() {
        let events = [began("W-1", at(9)), ended("W-1", at(12))]
        let answer = counted("W-2", at(10), at(11), answeredAt: at(13), id: "answer")
        let spans = AttentionLog.spans(from: events + [answer, withdrawn("answer", at(13, 5))],
                                       now: at(14))
        XCTAssertEqual(spans, AttentionLog.spans(from: events, now: at(14)))
    }

    /// Nothing is known past `now` — a report for a past day passes that day's end.
    func testAnAnswerIsCutAtNow() {
        let spans = AttentionLog.spans(from: [counted("W-1", at(11), at(13), answeredAt: at(11))],
                                       now: at(12))
        XCTAssertEqual(spans.map(minutes), [60])
        XCTAssertEqual(AttentionLog.spans(from: [counted("W-1", at(13), at(14), answeredAt: at(11))],
                                          now: at(12)), [])
    }

    /// Answers don't move attention: an answer between two edges doesn't end the open span.
    func testAnAnswerDoesntEndTheOpenSpan() {
        let spans = AttentionLog.spans(from: [began("W-1", at(9)),
                                              counted(nil, at(7), at(8), answeredAt: at(9, 30)),
                                              ended("W-1", at(10))],
                                       now: at(11))
        XCTAssertEqual(spans.map(\.basis), [.measured])
        XCTAssertEqual(spans.map(minutes), [60])
    }

    func testACountedSpanIsSplitAtMidnight() {
        let spans = AttentionLog.splittingAtMidnight(
            AttentionLog.spans(from: [counted("W-1", at(23, 30), at(23, 30).addingTimeInterval(3600),
                                              answeredAt: at(23, 59).addingTimeInterval(3600))],
                               now: at(23).addingTimeInterval(4 * 3600)))
        XCTAssertEqual(spans.map(minutes), [30, 30])
        XCTAssertEqual(spans.map(\.basis), [.counted, .counted])
    }

    // MARK: A report on some projects

    /// Reading one project still reads the whole log: W-2's `began` is what ends W-1's span.
    func testOnlyIsAppliedAfterTheWholeLogIsRead() {
        let spans = AttentionLog.spans(from: [began("W-1", at(9)), began("W-2", at(9, 40))],
                                       now: at(12), only: ["W-1"])
        XCTAssertEqual(spans.map(\.project), ["W-1"])
        XCTAssertEqual(spans.map(minutes), [40])
    }

    func testAnotherProjectsAnswerStillTakesTimeFromThisOne() {
        let spans = AttentionLog.spans(from: [began("W-1", at(9)), ended("W-1", at(12)),
                                              counted("W-2", at(10), at(11), answeredAt: at(13))],
                                       now: at(14), only: ["W-1"])
        XCTAssertEqual(spans.map(minutes), [60, 60])
    }
}
