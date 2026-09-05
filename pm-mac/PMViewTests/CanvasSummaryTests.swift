import XCTest
@testable import PMViewTests

/// The line a card is reduced to when the board is zoomed out past reading.
///
/// The fixtures are real cards from a real board, because the failure mode this guards against is
/// specific and only shows up on real prose: a card whose first line is a screenshot embed being
/// labelled `CleanShot 2025-02-24 at 20.36.04@2x.png`, which is both the longest and the least useful
/// thing that card could be called.
final class CanvasSummaryTests: XCTestCase {

    func testAHeadingLosesItsHashes() {
        XCTAssertEqual(canvasCardSummary("# Where are the Werewolves based?"),
                       "Where are the Werewolves based?")
        XCTAssertEqual(canvasCardSummary("### Deeper heading"), "Deeper heading")
    }

    func testPlainProseComesThroughUnchanged() {
        XCTAssertEqual(canvasCardSummary("Where can I find hay in Strahd?"),
                       "Where can I find hay in Strahd?")
    }

    func testTheFirstLineWins() {
        XCTAssertEqual(canvasCardSummary("# Wilbur Longs for Hay, the Sun\n\nI found a horse in Krezk"),
                       "Wilbur Longs for Hay, the Sun")
    }

    /// The one that matters. A card that opens with a screenshot is about what it says underneath.
    func testAnEmbedIsSkippedForTheLineThatSaysSomething() {
        let card = "![[CleanShot 2025-02-24 at 21.01.55@2x.png]]\n\n# Wilbur escaped into the dark woods"
        XCTAssertEqual(canvasCardSummary(card), "Wilbur escaped into the dark woods")
    }

    func testACardThatIsOnlyAPictureSaysSo() {
        XCTAssertEqual(canvasCardSummary("![[CleanShot 2025-02-10 at 20.46.57@2x.png]]"), "Image")
        XCTAssertEqual(canvasCardSummary("![](attachments/shot.png)"), "Image")
    }

    func testListAndTaskMarkersComeOff() {
        XCTAssertEqual(canvasCardSummary("- Missing 2 nights ago"), "Missing 2 nights ago")
        XCTAssertEqual(canvasCardSummary("* starred item"), "starred item")
        XCTAssertEqual(canvasCardSummary("1. first"), "first")
        XCTAssertEqual(canvasCardSummary("12) twelfth"), "twelfth")
        XCTAssertEqual(canvasCardSummary("- [ ] an open task"), "an open task")
        XCTAssertEqual(canvasCardSummary("- [x] a done task"), "a done task")
        XCTAssertEqual(canvasCardSummary("> - # stacked markers"), "stacked markers")
    }

    func testInlineEmphasisComesOffAndVaultLinksReadAsTheirName() {
        XCTAssertEqual(canvasCardSummary("**Designed for gameplay**"), "Designed for gameplay")
        XCTAssertEqual(canvasCardSummary("a `code` span"), "a code span")
        XCTAssertEqual(canvasCardSummary("we went to [[Vallaki]] after dark"),
                       "we went to Vallaki after dark")
        XCTAssertEqual(canvasCardSummary("~~struck~~ and ==highlighted=="), "struck and highlighted")
    }

    func testNothingToSaySaysNothing() {
        XCTAssertEqual(canvasCardSummary(""), "")
        XCTAssertEqual(canvasCardSummary("\n\n   \n"), "")
        XCTAssertEqual(canvasCardSummary("---\n"), "")
        XCTAssertEqual(canvasCardSummary("---\nafter the rule"), "after the rule")
    }

    /// A hash with no space after it is a tag, not a heading — and a tag is written with its hash and
    /// read with it. Stripping it would turn a recognisable `#strahd` into a bare word.
    func testATagKeepsItsHash() {
        XCTAssertEqual(canvasCardSummary("#strahd"), "#strahd")
        XCTAssertEqual(canvasCardSummary("# strahd"), "strahd", "with a space it is a heading")
    }

    // MARK: How old what you are looking at is

    /// Fixed so the assertions are about the branching rather than about where the machine is or what
    /// language it is in.
    private var clock: (Calendar, Locale) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return (calendar, Locale(identifier: "en_GB"))
    }

    private func at(_ iso: String) -> Date {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_GB")
        return formatter.date(from: iso)!
    }

    private func label(_ loaded: String, now: String) -> String {
        let (calendar, locale) = clock
        return canvasFreshnessLabel(for: at(loaded), now: at(now), calendar: calendar, locale: locale)
    }

    func testAPageThatJustArrivedSaysSo() {
        XCTAssertEqual(label("2026-09-04 09:12", now: "2026-09-04 09:12"), "just now",
                       "a clock time here would just be telling you what time it is")
    }

    func testTodayIsAClockTime() {
        XCTAssertEqual(label("2026-09-04 09:12", now: "2026-09-04 11:40"), "as of 09:12")
    }

    func testEarlierInTheWeekCarriesTheDay() {
        XCTAssertEqual(label("2026-09-01 17:40", now: "2026-09-04 09:12"), "as of Tue 17:40")
    }

    func testOlderThanAWeekIsADate() {
        XCTAssertEqual(label("2026-08-20 17:40", now: "2026-09-04 09:12"), "as of 20 Aug")
    }

    /// Just before midnight and just after is two different days, however few minutes apart — which is
    /// the answer you want, because "as of 23:58" on a board you opened this morning is a lie.
    func testYesterdayLateIsNotToday() {
        XCTAssertEqual(label("2026-09-03 23:58", now: "2026-09-04 00:04"), "as of Thu 23:58")
    }
}
