import XCTest
@testable import PmLib

final class NumberingTests: XCTestCase {
    func testParseProjectNumbersEmptyFolderList() throws {
        let (numbers, observedMinDigits) = try parseProjectNumbers(folderNames: [], domainCode: "W")
        XCTAssertEqual(numbers, [])
        XCTAssertEqual(observedMinDigits, 0)
    }

    func testParseProjectNumbers() throws {
        let names = ["W-1 Foo", "W-2 Bar", "W-10 Baz", "P-01 Personal"]
        let (numbers, observedMinDigits) = try parseProjectNumbers(folderNames: names, domainCode: "W")
        XCTAssertEqual(numbers.sorted(), [1, 2, 10])
        XCTAssertEqual(observedMinDigits, 2)
    }

    func testNextNumberAndPadding() {
        let (next, formatted) = nextNumberAndPadding(existingNumbers: [1, 2, 10], observedMinDigits: 2)
        XCTAssertEqual(next, 11)
        XCTAssertEqual(formatted, "11")
        let (first, firstFmt) = nextNumberAndPadding(existingNumbers: [], observedMinDigits: 0)
        XCTAssertEqual(first, 1)
        XCTAssertEqual(firstFmt, "1")
        // Padding: when observedMinDigits exceeds next number's digit count, pad with leading zero
        let (two, twoFmt) = nextNumberAndPadding(existingNumbers: [1], observedMinDigits: 2)
        XCTAssertEqual(two, 2)
        XCTAssertEqual(twoFmt, "02")
        // At 100 with 2-digit convention: no leading zero (README: "W-01 … then W-100 when you hit 100").
        let (hundred, hundredFmt) = nextNumberAndPadding(existingNumbers: [1, 2, 99], observedMinDigits: 2)
        XCTAssertEqual(hundred, 100)
        XCTAssertEqual(hundredFmt, "100")
    }

    /// getNextFormattedNumber throws when a path cannot be listed (e.g. does not exist).
    func testGetNextFormattedNumberThrowsWhenPathCannotBeListed() {
        let notExist = "/nonexistent/path"
        XCTAssertThrowsError(try getNextFormattedNumber(activePath: notExist, archivePath: notExist, domainCode: "W")) { err in
            guard case PmError.cannotListDirectory(let path, _) = err else {
                XCTFail("Expected cannotListDirectory, got \(err)")
                return
            }
            XCTAssertEqual(path, notExist)
        }
    }

    /// parseProjectNumbers throws invalidProjectPattern when the pattern is invalid (e.g. unclosed bracket).
    func testParseProjectNumbersThrowsWhenPatternInvalid() {
        XCTAssertThrowsError(try parseProjectNumbersWithPattern(folderNames: [], pattern: "[")) { err in
            guard case PmError.invalidProjectPattern(let pattern) = err else {
                XCTFail("Expected invalidProjectPattern, got \(err)")
                return
            }
            XCTAssertEqual(pattern, "[")
        }
    }
}
