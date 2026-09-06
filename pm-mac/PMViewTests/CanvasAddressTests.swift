import XCTest

/// What the two places you can type an address at will do with what you typed.
///
/// This used to be one line inside a modal dialog, which meant it could only be exercised by running
/// the app and putting an alert on screen. It is now the shared answer for the Add Link box and the
/// header's address field, and the interesting cases are the ones where the two would otherwise drift.
final class CanvasAddressTests: XCTestCase {

    func testAddsTheSchemeNobodyTypes() {
        XCTAssertEqual(CanvasAddress.normalized("example.com"), "https://example.com")
        XCTAssertEqual(CanvasAddress.normalized("example.com/a/b?c=d"), "https://example.com/a/b?c=d")
    }

    func testLeavesAnAddressThatHasOneAlone() {
        XCTAssertEqual(CanvasAddress.normalized("http://example.com"), "http://example.com")
        XCTAssertEqual(CanvasAddress.normalized("https://example.com"), "https://example.com")
        // Not everything on a board is the web. A card pointed at a local file keeps its scheme.
        XCTAssertEqual(CanvasAddress.normalized("file:///tmp/a.html"), "file:///tmp/a.html")
    }

    func testTrimsWhatWasPasted() {
        XCTAssertEqual(CanvasAddress.normalized("  https://example.com \n"), "https://example.com")
    }

    /// The rule the address field depends on: text that isn't an address leaves the page where it is,
    /// rather than being handed to a search engine PM never agreed to talk to.
    func testRejectsWhatIsNotAnAddress() {
        XCTAssertNil(CanvasAddress.normalized(""))
        XCTAssertNil(CanvasAddress.normalized("   "))
        XCTAssertNil(CanvasAddress.normalized("weather tomorrow"))
        XCTAssertNil(CanvasAddress.normalized("notes"))
    }

    /// The one common address with no dot in it. A card pointed at something you are running is a real
    /// thing to want, and rejecting it would be the rule being clever at your expense.
    func testAllowsThisMachine() {
        XCTAssertEqual(CanvasAddress.normalized("localhost:3000"), "https://localhost:3000")
    }
}
