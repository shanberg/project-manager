import XCTest
@testable import PMViewTests

/// What a web card is called, and what it refuses to be called.
///
/// The cases that matter are the ones where remembering a title would be *worse* than having none: a
/// name that only repeats the host the card is already showing underneath it, and a cache that grows
/// for as long as the app is installed.
final class CanvasPageTitlesTests: XCTestCase {

    private let address = "https://example.com/browse/PM-4127"

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "PMCanvasPageTitles")
        super.tearDown()
    }

    func testACardWithNoTitleYetHasNoName() {
        XCTAssertNil(CanvasPageTitles.of(address))
    }

    func testAPageIsRememberedByItsAddress() {
        CanvasPageTitles.remember("Billing rollover fails on renewal", for: address)
        XCTAssertEqual(CanvasPageTitles.of(address), "Billing rollover fails on renewal")
    }

    /// The point of keying by address rather than by node: a card duplicated, or the same URL pasted
    /// onto another board, is named before it has ever loaded.
    func testAnyCardOnThatAddressGetsTheName() {
        CanvasPageTitles.remember("Q3 Planning", for: "https://wiki.example.com/q3")
        XCTAssertEqual(CanvasPageTitles.of("https://wiki.example.com/q3"), "Q3 Planning")
    }

    func testAnAddressIsTheSameRowHoweverItWasPasted() {
        CanvasPageTitles.remember("Q3 Planning", for: "  https://wiki.example.com/q3\n")
        XCTAssertEqual(CanvasPageTitles.of("https://wiki.example.com/q3"), "Q3 Planning")
    }

    // MARK: Names that say nothing

    /// WebKit reports a page with no `<title>` as its own URL, and the card is already showing that.
    func testATitleThatIsJustTheAddressIsRefused() {
        CanvasPageTitles.remember(address, for: address)
        XCTAssertNil(CanvasPageTitles.of(address))
    }

    /// A great many sites title themselves with their bare host, in every combination of scheme,
    /// `www.` and trailing slash. The card draws the host on its own line underneath.
    func testATitleThatIsJustTheHostIsRefused() {
        for name in ["example.com", "Example.com", "www.example.com", "https://example.com/"] {
            CanvasPageTitles.remember(name, for: address)
            XCTAssertNil(CanvasPageTitles.of(address), "\(name) tells the card nothing it isn't showing")
        }
    }

    func testAnEmptyTitleIsRefused() {
        CanvasPageTitles.remember("   ", for: address)
        XCTAssertNil(CanvasPageTitles.of(address))
    }

    /// The host appearing *within* a real name is the ordinary case — "Jira · example.com" — and is not
    /// the case above.
    func testANameThatMerelyMentionsTheHostIsKept() {
        CanvasPageTitles.remember("PM-4127 · example.com", for: address)
        XCTAssertEqual(CanvasPageTitles.of(address), "PM-4127 · example.com")
    }

    func testANameIsTrimmedOnTheWayIn() {
        CanvasPageTitles.remember("\n  Sprint board  ", for: address)
        XCTAssertEqual(CanvasPageTitles.of(address), "Sprint board")
    }

    // MARK: Not growing forever

    /// Over the cap the least recently seen go, and — the part that matters — the pages you keep
    /// looking at stay. A card reloaded every day being evicted in favour of one opened once last
    /// month would be an LRU with its sign the wrong way round.
    func testThePagesYouKeepSeeingSurviveTheCap() {
        let kept = "https://example.com/every-day"
        CanvasPageTitles.remember("The one I use", for: kept)

        for n in 0...CanvasPageTitles.capacity {
            CanvasPageTitles.remember("Page \(n)", for: "https://example.com/\(n)")
            // Seen again, and so newer than everything filling the cache up behind it.
            CanvasPageTitles.remember("The one I use", for: kept)
        }

        XCTAssertEqual(CanvasPageTitles.of(kept), "The one I use")
        XCTAssertNil(CanvasPageTitles.of("https://example.com/0"), "the oldest went")
        XCTAssertLessThanOrEqual(stored().count, CanvasPageTitles.capacity)
    }

    private func stored() -> [String: Any] {
        UserDefaults.standard.dictionary(forKey: "PMCanvasPageTitles") ?? [:]
    }
}
