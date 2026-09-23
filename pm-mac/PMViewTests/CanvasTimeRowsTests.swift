import XCTest
import PmLib

/// What a Time card says about a period. See docs/time-tracking.md D7.
final class CanvasTimeRowsTests: XCTestCase {

    private func project(_ name: String, seconds: Double, inferred: Bool = false,
                         sittings: Int = 0, done: Int = 0, dropped: Int = 0,
                         picked: Int = 0) -> TimeSpentItem {
        var item = TimeSpentItem(projectFolder: "W-1 \(name)", projectName: name, isArchived: false)
        item.seconds = seconds
        item.inferred = inferred
        item.sittings = sittings
        item.done = done
        item.dropped = dropped
        item.picked = picked
        return item
    }

    private func report(_ projects: [TimeSpentItem]) -> TimeSpentReport {
        TimeSpentReport(seconds: projects.reduce(0) { $0 + $1.seconds }, projects: projects)
    }

    // MARK: The card's one line

    func testTheSummaryIsTheTotalAndHowManyProjects() {
        let out = CanvasTimeRows.summary(report([project("A", seconds: 7800),
                                                 project("B", seconds: 2400)]))
        XCTAssertEqual(out, "2h 50m · 2 projects")
    }

    /// One project doesn't need counting.
    func testOneProjectJustSaysTheTime() {
        XCTAssertEqual(CanvasTimeRows.summary(report([project("A", seconds: 2400)])), "40m")
    }

    /// A total that is partly worked out says so wherever it is read aloud (D4).
    func testTheSummaryMarksInferredProjects() {
        let out = CanvasTimeRows.summary(report([project("A", seconds: 7800, inferred: true),
                                                 project("B", seconds: 2400)]))
        XCTAssertEqual(out, "2h 50m · 2 projects · 1 estimated")
    }

    func testNoTimeSaysSo() {
        XCTAssertEqual(CanvasTimeRows.summary(TimeSpentReport()), "No time")
        XCTAssertEqual(CanvasTimeRows.summary(report([project("A", seconds: 0, sittings: 1)])), "No time",
                       "a project with only changes is not time")
    }

    // MARK: Which rows go where

    func testProjectsWithTimeAreKeptApartFromThoseWithout() {
        let (tracked, untracked) = CanvasTimeRows.split(
            report([project("A", seconds: 7800, sittings: 1),
                    project("B", seconds: 0, sittings: 1, done: 2),
                    project("C", seconds: 0)]))
        XCTAssertEqual(tracked.map(\.projectName), ["A"])
        XCTAssertEqual(untracked.map(\.projectName), ["B"],
                       "C has neither time nor anything to show, so it isn't a row at all")
    }

    // MARK: The bar

    /// Against the longest, never the total — five even projects should not draw five stubs.
    func testTheLongestBarIsFull() {
        let all = [project("A", seconds: 3600), project("B", seconds: 1800)]
        XCTAssertEqual(CanvasTimeRows.share(all[0], of: all), 1)
        XCTAssertEqual(CanvasTimeRows.share(all[1], of: all), 0.5)
    }

    func testEvenlySplitProjectsAllDrawFullBars() {
        let all = (1...5).map { project("P\($0)", seconds: 1200) }
        for item in all { XCTAssertEqual(CanvasTimeRows.share(item, of: all), 1) }
    }

    /// A row drawn on its own — the untracked section passes no peers — has no bar rather than a full one.
    func testARowWithNoPeersHasNoBar() {
        XCTAssertEqual(CanvasTimeRows.share(project("A", seconds: 0), of: []), 0)
    }

    // MARK: What came of the time

    func testChangesReadAsAList() {
        XCTAssertEqual(ViewMarkdown.changes(project("A", seconds: 60, sittings: 2, done: 3, picked: 1)),
                       "2 sittings · 3 done · 1 picked up")
        XCTAssertEqual(ViewMarkdown.changes(project("A", seconds: 60, sittings: 1)), "1 sitting")
        XCTAssertEqual(ViewMarkdown.changes(project("A", seconds: 60)), "")
    }

    // MARK: The card, as a document

    func testCopyAsTextLeadsWithTheTotalAndMarksInferred() {
        let text = ViewMarkdown.time(report([project("A", seconds: 7800, inferred: true, sittings: 1, done: 2),
                                             project("B", seconds: 2400, sittings: 1)]))
        XCTAssertTrue(text.contains("**2h 50m** in total."), text)
        XCTAssertTrue(text.contains("[[W-1 A]] — **2h 10m** · 1 sitting · 2 done *(inferred)*"), text)
        XCTAssertFalse(text.contains("[[W-1 B]] — **40m** · 1 sitting *(inferred)*"), text)
    }

    func testCopyAsTextPutsUntrackedProjectsUnderTheirOwnHeading() {
        let text = ViewMarkdown.time(report([project("A", seconds: 7800),
                                             project("B", seconds: 0, sittings: 1, done: 1)]))
        XCTAssertTrue(text.contains("### No time on record"), text)
        XCTAssertTrue(text.contains("[[W-1 B]] — 1 sitting · 1 done"), text)
    }

    func testCopyAsTextOfAnEmptyPeriodSaysSo() {
        XCTAssertEqual(ViewMarkdown.time(TimeSpentReport()),
                       "## Where the time went\n\nNo time on record.\n")
    }

    // MARK: Answering for time (docs/away-time.md)

    private func away(_ project: String, _ minute: Int) -> CanvasTimeStretch {
        let from = Date(timeIntervalSince1970: 1_790_000_000 + Double(minute) * 60)
        return .away(AttentionAway(project: project, key: "/P:\(project)", from: from,
                                   to: from.addingTimeInterval(1200), why: "paused"))
    }

    private func span(_ project: String, _ minute: Int) -> CanvasTimeStretch {
        let from = Date(timeIntervalSince1970: 1_790_000_000 + Double(minute) * 60)
        return .span(AttentionSpan(project: project, key: "/P:\(project)", task: nil, start: from,
                                   end: from.addingTimeInterval(3600), basis: .measured))
    }

    func testAnAwayOffersWhatItInterruptedFirst() {
        let answers = CanvasTimeAnswers.offered(for: [away("W-2", 0)], candidates: ["W-1"])
        XCTAssertEqual(answers.suggested, "W-2")
        XCTAssertEqual(answers.projects, ["W-1", "W-2"], "the card's projects, then the away's")
        XCTAssertEqual(answers.countTitle(for: "Brand"), "Count for Brand")
        XCTAssertEqual(answers.notWorkTitle, "Not Work")
    }

    func testAwaysThatDisagreeSuggestNothing() {
        let answers = CanvasTimeAnswers.offered(for: [away("W-1", 0), away("W-2", 60)], candidates: [])
        XCTAssertNil(answers.suggested)
        XCTAssertEqual(answers.projects, ["W-1", "W-2"])
    }

    /// A span is already its project's: counting it there would change nothing but the mark.
    func testASpanIsntOfferedToItsOwnProject() {
        let answers = CanvasTimeAnswers.offered(for: [span("W-1", 0), span("W-1", 120)],
                                                candidates: ["W-1", "W-2"])
        XCTAssertEqual(answers.projects, ["W-2"])
        XCTAssertNil(answers.suggested, "spans are moved, not suggested")
    }

    func testMixedSelectionsKeepEveryProject() {
        let answers = CanvasTimeAnswers.offered(for: [span("W-1", 0), away("W-1", 120)],
                                                candidates: ["W-1", "W-2"])
        XCTAssertEqual(answers.projects, ["W-1", "W-2"], "the away still wants W-1")
        XCTAssertNil(answers.suggested)
    }

    func testTheTitlesSayTheCount() {
        let answers = CanvasTimeAnswers.offered(for: [away("W-1", 0), away("W-1", 60), away("W-1", 120)],
                                                candidates: [])
        XCTAssertEqual(answers.countTitle(for: "Website"), "Count 3 for Website")
        XCTAssertEqual(answers.countSubmenuTitle, "Count 3 For")
        XCTAssertEqual(answers.notWorkTitle, "Mark 3 as Not Work")
    }

    func testStretchKeysAreDistinctAndStable() {
        let keys = [away("W-1", 0), away("W-1", 60), span("W-1", 0), span("W-2", 0)].map(\.key)
        XCTAssertEqual(Set(keys).count, 4)
        XCTAssertEqual(away("W-1", 0).key, away("W-1", 0).key)
    }
}
