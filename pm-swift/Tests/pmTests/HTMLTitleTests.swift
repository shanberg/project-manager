import XCTest
@testable import PmLib

/// What a page calls itself, read out of the shapes real pages are actually written in.
final class HTMLTitleTests: XCTestCase {

    func testReadsAPlainTitle() {
        XCTAssertEqual(HTMLTitle.read("<html><head><title>Q3 Runbook</title></head></html>"),
                       "Q3 Runbook")
    }

    /// Titles are routinely written across indented lines and mean one line.
    func testFoldsWhitespaceIntoOneLine() {
        let html = "<head>\n  <title>\n    Quarterly\n    Planning\n  </title>\n</head>"
        XCTAssertEqual(HTMLTitle.read(html), "Quarterly Planning")
    }

    func testSkipsAttributesOnTheTag() {
        XCTAssertEqual(HTMLTitle.read("<title data-rh=\"true\">Ticket #412</title>"), "Ticket #412")
    }

    /// `<titlebar>` starts with `<title` and is not one.
    func testIgnoresATagThatMerelyStartsWithTheName() {
        XCTAssertEqual(HTMLTitle.read("<titlebar>nope</titlebar><title>Real</title>"), "Real")
    }

    func testDecodesTheEntitiesTitlesActuallyUse() {
        XCTAssertEqual(HTMLTitle.read("<title>Ben &amp; Jerry&#39;s &mdash; &#x2018;news&#x2019;</title>"),
                       "Ben & Jerry's \u{2014} \u{2018}news\u{2019}")
    }

    /// An entity the table doesn't know is left as written rather than swallowed.
    func testLeavesAnUnknownEntityAlone() {
        XCTAssertEqual(HTMLTitle.read("<title>50&percnt; done</title>"), "50&percnt; done")
    }

    /// A bare ampersand is not the start of an entity and must not eat the rest of the line.
    func testSurvivesABareAmpersand() {
        XCTAssertEqual(HTMLTitle.read("<title>R&D; roadmap</title>"), "R&D; roadmap")
    }

    // MARK: Falling back

    func testFallsBackToOpenGraphWhenThereIsNoTitle() {
        let html = "<head><meta property=\"og:title\" content=\"Migration Notes\"></head>"
        XCTAssertEqual(HTMLTitle.read(html), "Migration Notes")
    }

    func testPrefersTheTitleTagOverOpenGraph() {
        let html = "<head><meta property=\"og:title\" content=\"Shared\"><title>Tab</title></head>"
        XCTAssertEqual(HTMLTitle.read(html), "Tab")
    }

    /// An empty `<title>` is a page that didn't say, so the fallback still gets its turn.
    func testAnEmptyTitleFallsThrough() {
        let html = "<title></title><meta name='og:title' content='Named Elsewhere'>"
        XCTAssertEqual(HTMLTitle.read(html), "Named Elsewhere")
    }

    func testIgnoresOtherMetaTagsOnTheWay() {
        let html = """
            <meta charset="utf-8">
            <meta name="description" content="Not the title">
            <meta property="og:title" content="The Title">
            """
        XCTAssertEqual(HTMLTitle.read(html), "The Title")
    }

    /// `data-content=` ends in `content` and is not it.
    func testDoesNotReadAPrefixedAttribute() {
        let html = "<meta property=\"og:title\" data-content=\"wrong\" content=\"right\">"
        XCTAssertEqual(HTMLTitle.read(html), "right")
    }

    func testSaysNothingWhenThePageDoesnt() {
        XCTAssertNil(HTMLTitle.read("<html><body><h1>Heading</h1></body></html>"))
    }

    /// The fetch stops at the head, so a truncated document is the ordinary input — not a failure to
    /// crash on.
    func testATruncatedDocumentIsNotATitle() {
        XCTAssertNil(HTMLTitle.read("<html><head><title>Half a titl"))
    }
}
