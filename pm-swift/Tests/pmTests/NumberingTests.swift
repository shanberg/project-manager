import XCTest
@testable import PmLib

final class NumberingTests: XCTestCase {
    func testParseProjectNumbersEmptyFolderList() {
        let (numbers, observedMinDigits) = parseProjectNumbers(folderNames: [], domainCode: "W")
        XCTAssertEqual(numbers, [])
        XCTAssertEqual(observedMinDigits, 0)
    }

    func testParseProjectNumbers() {
        let names = ["W-1 Foo", "W-2 Bar", "W-10 Baz", "P-01 Personal"]
        let (numbers, observedMinDigits) = parseProjectNumbers(folderNames: names, domainCode: "W")
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
    }

    func testMatchProject() {
        let folders = ["W-1 Alpha", "W-2 Beta", "W-10 Gamma"]
        XCTAssertEqual(matchProject(folders: folders, query: "W-1 Alpha"), "W-1 Alpha")
        XCTAssertEqual(matchProject(folders: folders, query: "W-2"), "W-2 Beta")
        XCTAssertNil(matchProject(folders: folders, query: "W-1")) // ambiguous (W-1 Alpha and W-10 Gamma)
        XCTAssertNil(matchProject(folders: folders, query: "X-1"))
        XCTAssertNil(matchProject(folders: folders, query: ""))
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
}
