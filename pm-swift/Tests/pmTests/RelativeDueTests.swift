import XCTest
@testable import PmLib

/// The one implementation of how a `due:` value reads, pinned.
///
/// These exist because there were three implementations and they disagreed — see the type's own
/// header. The phrasing is now a published fact rather than a coincidence of whichever copy you were
/// looking at, so it is asserted exactly, including at the boundaries where the copies parted company.
final class RelativeDueTests: XCTestCase {

    /// A fixed "now" so nothing here depends on the day it runs. Noon, because a bare stored date
    /// parses to noon and a test straddling midnight would be testing the clock.
    private let now: Date = {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 9; comps.day = 12; comps.hour = 12
        return Calendar.current.date(from: comps)!
    }()

    private func due(inDays days: Int) -> String {
        let date = Calendar.current.date(byAdding: .day, value: days, to: now)!
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    private func short(_ days: Int) -> String {
        RelativeDue.short(due(inDays: days), now: now)
    }

    // MARK: The near days, which are words rather than numbers

    func testTheThreeDaysWithNamesUseThem() {
        XCTAssertEqual(short(0), "today")
        XCTAssertEqual(short(1), "tomorrow")
        XCTAssertEqual(short(-1), "yesterday")
    }

    func testDaysInsideAWeekAreCounted() {
        XCTAssertEqual(short(2), "in 2d")
        XCTAssertEqual(short(6), "in 6d")
        XCTAssertEqual(short(-2), "2d ago")
        XCTAssertEqual(short(-6), "6d ago")
    }

    // MARK: The rule the copies broke

    /// **Units are floored, never rounded.** The TypeScript copy rounded, so eleven days out read
    /// "in 2w" there and "in 1w" here — and a badge that rounds up tells you a deadline is further
    /// away than it is, which is the direction that costs something. Eleven, twelve and thirteen days
    /// are the offsets where the two answers differ, so they are the ones asserted.
    func testWeeksAreFlooredSoABadgeNeverClaimsMoreTimeThanThereIs() {
        XCTAssertEqual(short(7), "in 1w")
        XCTAssertEqual(short(10), "in 1w")
        XCTAssertEqual(short(11), "in 1w", "rounding would say 2w and buy you a week you do not have")
        XCTAssertEqual(short(13), "in 1w")
        XCTAssertEqual(short(14), "in 2w")
        XCTAssertEqual(short(20), "in 2w")
        XCTAssertEqual(short(29), "in 4w")
    }

    func testWeeksAgoAreFlooredTheSameWay() {
        XCTAssertEqual(short(-7), "1w ago")
        XCTAssertEqual(short(-11), "1w ago")
        XCTAssertEqual(short(-13), "1w ago")
        XCTAssertEqual(short(-14), "2w ago")
    }

    func testMonthsAndYearsAreFlooredToo() {
        XCTAssertEqual(short(30), "in 1mo")
        XCTAssertEqual(short(59), "in 1mo")
        XCTAssertEqual(short(60), "in 2mo")
        XCTAssertEqual(short(364), "in 12mo")
        XCTAssertEqual(short(365), "in 1y")
        XCTAssertEqual(short(-30), "1mo ago")
        XCTAssertEqual(short(-365), "1y ago")
    }

    /// Every boundary in the table, in one place, so a reordered `switch` cannot quietly move one.
    func testTheUnitBoundariesAreWhereTheySay() {
        XCTAssertEqual(short(6), "in 6d")
        XCTAssertEqual(short(7), "in 1w")
        XCTAssertEqual(short(29), "in 4w")
        XCTAssertEqual(short(30), "in 1mo")
        XCTAssertEqual(short(364), "in 12mo")
        XCTAssertEqual(short(365), "in 1y")
    }

    // MARK: Parsing

    func testABareDateIsNoonSoTodayIsNotAlreadyOverdue() throws {
        let parsed = try XCTUnwrap(RelativeDue.parse("2026-09-12"))
        let comps = Calendar.current.dateComponents([.hour, .minute], from: parsed)
        XCTAssertEqual(comps.hour, 12)
        XCTAssertEqual(comps.minute, 0)
    }

    func testAStoredTimeIsKept() throws {
        let parsed = try XCTUnwrap(RelativeDue.parse("2026-09-12 15:30"))
        let comps = Calendar.current.dateComponents([.hour, .minute], from: parsed)
        XCTAssertEqual(comps.hour, 15)
        XCTAssertEqual(comps.minute, 30)
    }

    func testTheDuePrefixIsOptional() {
        XCTAssertEqual(RelativeDue.parse("due:2026-09-12"), RelativeDue.parse("2026-09-12"))
        XCTAssertEqual(RelativeDue.parse("  due: 2026-09-12 "), RelativeDue.parse("2026-09-12"))
    }

    func testUnparseableInputIsNeverOverdueAndShowsItself() {
        XCTAssertNil(RelativeDue.parse("not a date"))
        XCTAssertNil(RelativeDue.dayDelta("not a date", now: now))
        XCTAssertFalse(RelativeDue.isOverdue("not a date", now: now))
        XCTAssertEqual(RelativeDue.short("not a date", now: now), "not a date")
        XCTAssertEqual(RelativeDue.full("not a date"), "not a date")
    }

    func testCarriesTimeTellsAPinnedTimeFromABareDate() {
        XCTAssertFalse(RelativeDue.carriesTime("2026-09-12"))
        XCTAssertTrue(RelativeDue.carriesTime("2026-09-12 15:30"))
        XCTAssertTrue(RelativeDue.carriesTime("due:2026-09-12 09:05"))
        XCTAssertFalse(RelativeDue.carriesTime("nonsense"))
    }

    func testOverdueIsAboutTheStoredInstantNotTheDay() {
        XCTAssertTrue(RelativeDue.isOverdue("2026-09-11", now: now))
        XCTAssertFalse(RelativeDue.isOverdue("2026-09-13", now: now))
        // Noon exactly is not yet past at noon exactly.
        XCTAssertFalse(RelativeDue.isOverdue("2026-09-12", now: now))
    }

    // MARK: The table the other surfaces have to match

    /// The conformance table, emitted for `pm api call due.table` and checked by the Raycast test.
    /// Asserted here as well so the table itself cannot drift unnoticed.
    func testTheConformanceTableCoversEveryOffsetInsideAMonth() {
        let table = RelativeDue.conformanceTable(now: now)
        XCTAssertEqual(table.count, 59, "-29 through 29 inclusive")
        XCTAssertEqual(table.first?.days, -29)
        XCTAssertEqual(table.last?.days, 29)
        XCTAssertEqual(table.first { $0.days == 11 }?.label, "in 1w")
        XCTAssertEqual(table.first { $0.days == 0 }?.label, "today")
    }
}
