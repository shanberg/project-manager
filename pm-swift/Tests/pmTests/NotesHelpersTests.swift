import XCTest
@testable import PmLib

final class NotesHelpersTests: XCTestCase {
    /// Contract: Swift formatSessionDate must match Raycast's formatSessionDate (toLocaleDateString en-US short)
    /// so that session matching (e.g. addTodoToTodaySession) works. Do not change the format without updating the extension.
    func testFormatSessionDateContract() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let date = cal.date(from: DateComponents(year: 2025, month: 2, day: 25, hour: 12, minute: 0))!
        let formatted = formatSessionDate(date)
        XCTAssertEqual(formatted, "Tue, Feb 25, 2025", "Session date format must match Raycast (en-US short); change only with extension update")
    }

    func testParseSessionDateArgumentValid() throws {
        let date = try parseSessionDateArgument("2025-02-25")
        let formatted = formatSessionDate(date)
        XCTAssertTrue(formatted.contains("2025"), "formatted date should contain year: \(formatted)")
        XCTAssertTrue(formatted.contains("Feb"), "formatted date should contain month: \(formatted)")
    }

    func testParseSessionDateArgumentInvalidThrows() {
        XCTAssertThrowsError(try parseSessionDateArgument("not-a-date")) { err in
            guard case PmError.invalidSessionDate(let value) = err else {
                XCTFail("Expected invalidSessionDate, got \(err)")
                return
            }
            XCTAssertEqual(value, "not-a-date")
        }
    }
}
