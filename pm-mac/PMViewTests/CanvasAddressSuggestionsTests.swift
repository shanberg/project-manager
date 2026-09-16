import XCTest
import PmLib

/// The two pure pieces behind backlog item 13 — suggesting a project's own links in the add-a-link
/// field. The board itself isn't in this bundle (see `CanvasLinkDropTests`), so what a picked
/// suggestion resolves to, and which of a project's links are worth offering, are asserted on their
/// own: `CanvasLinkSuggestions.resolvedAddress` and `CanvasLinkSuggestions.suggestions`.
@MainActor
final class CanvasAddressSuggestionsTests: XCTestCase {

    // MARK: linkSuggestions(from:)

    func testALabelledLinkOffersItsLabelAndItsURL() {
        let links = [LinkEntry(label: "Design doc", url: "https://x.dev/design")]
        let result = CanvasLinkSuggestions.suggestions(from: links)
        XCTAssertEqual(result.map(\.label), ["Design doc"])
        XCTAssertEqual(result.map(\.url), ["https://x.dev/design"])
    }

    /// An unlabelled link has nothing else to show, so the url stands in as its own label.
    func testAnUnlabelledLinkOffersItsURLAsTheLabel() {
        let links = [LinkEntry(label: nil, url: "https://x.dev/docs")]
        XCTAssertEqual(CanvasLinkSuggestions.suggestions(from: links).map(\.label), ["https://x.dev/docs"])
    }

    /// The empty label a link can carry (typed and then cleared) is the same case as no label at all.
    func testAnEmptyLabelAlsoFallsBackToTheURL() {
        let links = [LinkEntry(label: "", url: "https://x.dev/docs")]
        XCTAssertEqual(CanvasLinkSuggestions.suggestions(from: links).map(\.label), ["https://x.dev/docs"])
    }

    /// The blank row a linkless project's notes carry, and anything else with no url, are not
    /// addresses — there is nothing to suggest.
    func testEntriesWithNoURLOfferNothing() {
        let links = [LinkEntry(label: nil, url: nil), LinkEntry(label: "Empty", url: "")]
        XCTAssertTrue(CanvasLinkSuggestions.suggestions(from: links).isEmpty)
    }

    func testOrderIsPreserved() {
        let links = [LinkEntry(label: "A", url: "https://x.dev/a"),
                     LinkEntry(label: "B", url: "https://x.dev/b")]
        XCTAssertEqual(CanvasLinkSuggestions.suggestions(from: links).map(\.label), ["A", "B"])
    }

    // MARK: resolvedAddress(_:against:)

    /// Picking a suggestion is choosing it by the only thing the field ever shows for one — its label
    /// — so that is what has to resolve back to the url that will actually become the card.
    func testAPickedSuggestionResolvesToItsURL() {
        let suggestions = [(label: "Design doc", url: "https://x.dev/design")]
        XCTAssertEqual(CanvasLinkSuggestions.resolvedAddress("Design doc", against: suggestions),
                       "https://x.dev/design")
    }

    /// Anything typed that isn't one of the labels on offer is address text, unchanged — the field
    /// behaves exactly as it did before suggestions existed.
    func testTypedTextThatMatchesNoSuggestionPassesThrough() {
        let suggestions = [(label: "Design doc", url: "https://x.dev/design")]
        XCTAssertEqual(CanvasLinkSuggestions.resolvedAddress("https://y.dev/new", against: suggestions),
                       "https://y.dev/new")
    }

    /// No suggestions on offer is the same case as typing something that matches none of them.
    func testNoSuggestionsPassesTextThrough() {
        XCTAssertEqual(CanvasLinkSuggestions.resolvedAddress("https://y.dev/new", against: []),
                       "https://y.dev/new")
    }

    /// An unlabelled suggestion's label *is* its url — see `testAnUnlabelledLinkOffersItsURLAsTheLabel`
    /// — so picking it has to resolve to the same url rather than being treated as free text that
    /// happens to already be one.
    func testAnUnlabelledSuggestionResolvesToItself() {
        let suggestions = [(label: "https://x.dev/docs", url: "https://x.dev/docs")]
        XCTAssertEqual(CanvasLinkSuggestions.resolvedAddress("https://x.dev/docs", against: suggestions),
                       "https://x.dev/docs")
    }
}
