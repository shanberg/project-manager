import XCTest
@testable import PmLib

/// The capture parser and the task ranking, moved out of the macOS app so every surface reads a
/// typed line and finds a task the same way. See docs/api-contract.md.
final class CaptureParseTests: XCTestCase {

    /// A Saturday, so "friday" is genuinely next week rather than today.
    ///
    /// The local calendar on purpose: `DueFormat` renders in the local zone, and a date computed in
    /// one calendar and printed in another comes out a day off. Every real caller passes `.current`
    /// to both, and a test that didn't would be testing a combination nothing uses.
    private let now = DueFormat.parse("2026-08-22")!
    private let calendar = Calendar.current

    func testReadsTheDueMarker() {
        let result = QuickCaptureParser.parse("Email Dana due:2026-09-01", now: now, calendar: calendar)
        XCTAssertEqual(result.text, "Email Dana")
        XCTAssertEqual(result.due, "2026-09-01")
        XCTAssertNil(result.unreadableDue)
    }

    /// The words the due menu offers, read back out of a typed line — which is why the presets moved
    /// here with the parser rather than staying in the app beside the menu.
    func testReadsThePresetsTheMenuOffers() {
        for preset in duePresets(now: now, calendar: calendar) {
            let typed = QuickCaptureParser.parse("Ship it due:\(preset.title.lowercased())",
                                                 now: now, calendar: calendar)
            XCTAssertEqual(typed.due, DueFormat.string(preset.date), preset.title)
        }
    }

    func testReadsTheShorthandBadgesUse() {
        for (phrase, expected) in [("tomorrow", "2026-08-23"), ("in 3d", "2026-08-25"),
                                   ("in 2w", "2026-09-05"), ("yesterday", "2026-08-21")] {
            XCTAssertEqual(QuickCaptureParser.parse("X due:\(phrase)", now: now, calendar: calendar).due,
                           expected, phrase)
        }
    }

    /// A weekday means the next one of those — "friday" on a Friday is a week away, since a task due
    /// today would have been typed as "today".
    func testAWeekdayMeansTheNextOne() {
        XCTAssertEqual(QuickCaptureParser.parse("X due:friday", now: now, calendar: calendar).due,
                       "2026-08-28")
    }

    /// Losing "due:thurdsay" to a typo is worse than a task whose title has a typo in it.
    func testAnUnreadableDateStaysInTheText() {
        let result = QuickCaptureParser.parse("Fix it due:thurdsay", now: now, calendar: calendar)
        XCTAssertEqual(result.text, "Fix it due:thurdsay")
        XCTAssertNil(result.due)
        XCTAssertEqual(result.unreadableDue, "thurdsay")
    }

    func testOverdueIsNotADateMarker() {
        let result = QuickCaptureParser.parse("Chase the overdue:invoice", now: now, calendar: calendar)
        XCTAssertEqual(result.text, "Chase the overdue:invoice")
        XCTAssertNil(result.unreadableDue)
    }

    func testTheTrailingProjectComesOff() {
        let split = QuickCaptureParser.splitTarget("Email Dana @maxwell carmody")
        XCTAssertEqual(split?.text, "Email Dana")
        XCTAssertEqual(split?.projectQuery, "maxwell carmody")
        // A leading `@` is the go-to-project sigil, not a redirect.
        XCTAssertNil(QuickCaptureParser.splitTarget("@redesign"))
        XCTAssertNil(QuickCaptureParser.splitTarget("Email bob@example.com".replacingOccurrences(of: " ", with: "")))
    }

    // MARK: Ranking

    private struct Task: SearchableTask {
        let text: String
        var isFocused = false
        var isArchived = false
        var projectKey = "base:W-1 Redesign"
    }

    /// You remember a task as some of the words in it, in any order.
    func testEveryWordHasToMatchSomething() {
        let tasks = [Task(text: "Email Dana about pricing"), Task(text: "Email the surveyor"),
                     Task(text: "Review the contract")]
        XCTAssertEqual(TaskSearch.rank(tasks, query: "dana email", focusedProjectKey: nil).map(\.text),
                       ["Email Dana about pricing"])
        XCTAssertTrue(TaskSearch.rank(tasks, query: "email zzz", focusedProjectKey: nil).isEmpty,
                      "a task that answers half the query is a task you didn't mean")
    }

    func testAnExactPhraseOutranksSharedVocabulary() {
        let tasks = [Task(text: "Email the surveyor about the contract"),
                     Task(text: "Email Dana")]
        XCTAssertEqual(TaskSearch.rank(tasks, query: "email dana", focusedProjectKey: nil).first?.text,
                       "Email Dana")
    }

    func testArchivedWorkMatchesButNeverLeads() {
        let tasks = [Task(text: "Email Dana", isArchived: true), Task(text: "Email Dana again")]
        XCTAssertEqual(TaskSearch.rank(tasks, query: "email dana", focusedProjectKey: nil).map(\.text),
                       ["Email Dana again", "Email Dana"])
    }

    func testTheProjectYouAreInBreaksTies() {
        let tasks = [Task(text: "Email Dana", projectKey: "base:H-1 Other"),
                     Task(text: "Email Dana", projectKey: "base:W-1 Redesign")]
        XCTAssertEqual(TaskSearch.rank(tasks, query: "email dana",
                                       focusedProjectKey: "base:W-1 Redesign").first?.projectKey,
                       "base:W-1 Redesign")
    }

    func testAnEmptyQueryMatchesNothing() {
        XCTAssertTrue(TaskSearch.rank([Task(text: "Anything")], query: "  ", focusedProjectKey: nil).isEmpty)
    }
}
