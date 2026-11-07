import PmLib
import XCTest

/// The dock's Due section (`DockDue`): which projects come forward, how urgent each is, in what order.
final class DockDueTests: XCTestCase {
    /// Saturday 7 November 2026, 10:00 local.
    private let now = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 7, hour: 10))!

    private func project(_ name: String, _ due: String?, archived: Bool = false) -> DockDue.Candidate {
        DockDue.Candidate(projectKey: "base:\(name)", name: name, nextDue: due, isArchived: archived)
    }

    func testLevelsWithinTheWindow() {
        XCTAssertEqual(DockDue.level("2026-11-05", horizon: 2, now: now), .overdue)
        XCTAssertEqual(DockDue.level("2026-11-07", horizon: 2, now: now), .today)
        XCTAssertEqual(DockDue.level("2026-11-07 09:00", horizon: 2, now: now), .overdue, "a time today already past")
        XCTAssertEqual(DockDue.level("2026-11-07 17:00", horizon: 2, now: now), .today)
        XCTAssertEqual(DockDue.level("2026-11-09", horizon: 2, now: now), .soon)
        XCTAssertNil(DockDue.level("2026-11-10", horizon: 2, now: now), "past the window")
        XCTAssertNil(DockDue.level(nil, horizon: 2, now: now))
        XCTAssertNil(DockDue.level("someday", horizon: 2, now: now))
    }

    func testTodayWindowStillCountsOverdue() {
        XCTAssertEqual(DockDue.level("2026-10-01", horizon: 0, now: now), .overdue)
        XCTAssertNil(DockDue.level("2026-11-08", horizon: 0, now: now))
    }

    func testOffBringsNothing() {
        XCTAssertNil(DockDue.level("2026-11-01", horizon: DockDue.off, now: now))
        XCTAssertTrue(DockDue.due([project("A", "2026-11-01")], horizon: DockDue.off, now: now).isEmpty)
    }

    func testDueProjectsEarliestFirstSkippingArchivedAndLate() {
        let found = DockDue.due([
            project("Tax", "2026-11-09"),
            project("Car", "2026-11-06"),
            project("Old", "2026-11-01", archived: true),
            project("Offsite", "2026-11-12"),
            project("None", nil),
            project("Report", "2026-11-07"),
        ], horizon: 2, now: now)
        XCTAssertEqual(found.map(\.name), ["Car", "Report", "Tax"])
    }

    func testTasksWithinTheWindowEarliestFirst() {
        let tasks = DockDue.tasks([
            (due: "2026-11-09", text: "Pay estimate"),
            (due: nil, text: "No date"),
            (due: "2026-11-20", text: "Later"),
            (due: "2026-11-05", text: "Send draft"),
        ], horizon: 2, now: now)
        XCTAssertEqual(tasks.map(\.text), ["Send draft", "Pay estimate"])
    }
}
