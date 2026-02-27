import XCTest
@testable import PmLib

final class NotesHelpersTests: XCTestCase {
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
