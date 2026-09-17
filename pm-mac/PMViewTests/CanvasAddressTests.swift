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

    /// The rule the address field depends on: text that isn't an address is not an address. What happens
    /// to it next is the search engine's business — see `testSearchesOnlyWithAnEngine`.
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

    // MARK: What the header marks

    func testPlainHttpIsWorthAMark() {
        XCTAssertFalse(CanvasAddress.isEncrypted("http://tracker.example.com/board"))
    }

    func testHttpsIsNot() {
        XCTAssertTrue(CanvasAddress.isEncrypted("https://tracker.example.com/board"))
    }

    /// Plain HTTP to a machine on this Mac is how local development works, and half the cards on a
    /// developer's board are pointed at one. A mark on every one of those is a mark nobody reads —
    /// which costs exactly the one page it exists for.
    func testThisMachineIsNotAWarning() {
        for address in ["http://localhost:3000/app", "http://127.0.0.1:8080",
                        "http://mini.local/status"] {
            XCTAssertTrue(CanvasAddress.isEncrypted(address), address)
        }
    }

    /// A card that has never loaded, and the schemes with no connection to be honest about.
    func testSomethingWithNoConnectionIsNotWarnedAbout() {
        for address in ["", "about:blank", "data:text/html,hi"] {
            XCTAssertTrue(CanvasAddress.isEncrypted(address), address)
        }
    }

    /// With no engine chosen, words go nowhere — the default, and the old behaviour.
    func testSearchesOnlyWithAnEngine() {
        XCTAssertNil(CanvasAddress.resolved("weather tomorrow", engine: .none))
        XCTAssertEqual(CanvasAddress.resolved("weather tomorrow", engine: .duckDuckGo),
                       "https://duckduckgo.com/?q=weather%20tomorrow")
        XCTAssertEqual(CanvasAddress.resolved("notes", engine: .startpage),
                       "https://www.startpage.com/sp/search?query=notes")
    }

    /// An address is still an address with an engine chosen — searching for "example.com" is the one
    /// thing a browser's field must never do.
    func testAnAddressIsNeverSearched() {
        XCTAssertEqual(CanvasAddress.resolved("example.com", engine: .google), "https://example.com")
        XCTAssertNil(CanvasAddress.resolved("   ", engine: .google))
    }

    func testSearchWordsAreEncoded() {
        XCTAssertEqual(CanvasSearchEngine.google.searchAddress(for: "c++ & rust"),
                       "https://www.google.com/search?q=c%2B%2B%20%26%20rust")
    }

    /// The site is everything up to the port, whichever of host and port the address ends its origin on.
    func testAnAddressSplitsWhereTheSiteEnds() {
        XCTAssertTrue(CanvasAddress.splitAtOrigin("https://example.com/issues?q=1")
                      == ("https://example.com", "/issues?q=1"))
        XCTAssertTrue(CanvasAddress.splitAtOrigin("http://localhost:3000/app")
                      == ("http://localhost:3000", "/app"))
        XCTAssertTrue(CanvasAddress.splitAtOrigin("https://www.example.com") == ("https://www.example.com", ""))
        XCTAssertTrue(CanvasAddress.splitAtOrigin("about:blank") == ("about:blank", ""))
    }
}
