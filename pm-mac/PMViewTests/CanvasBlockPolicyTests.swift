import XCTest

/// The decisions behind ad blocking, away from WebKit.
///
/// `CanvasContentBlocker` needs a bundle, a compiled rule store and a web view before it can answer
/// anything; these are the parts that decide *whether* a card is filtered, which is where the
/// behaviour anyone would notice actually lives.
final class CanvasBlockPolicyTests: XCTestCase {

    // MARK: How a site is remembered

    func testSiteKeyIgnoresCaseAndWWW() {
        XCTAssertEqual(CanvasBlockPolicy.siteKey(for: "WWW.Example.COM"), "example.com")
        XCTAssertEqual(CanvasBlockPolicy.siteKey(for: "example.com"), "example.com")
    }

    /// A fully-qualified name arrives with a trailing dot often enough to matter, and it is the same
    /// site.
    func testSiteKeyDropsTrailingDots() {
        XCTAssertEqual(CanvasBlockPolicy.siteKey(for: "example.com."), "example.com")
    }

    /// `www.` is noise; anything else in front of the domain is not. A dashboard shows
    /// `jira.example.com` without showing `example.com`, and quietly excusing the parent would turn
    /// filtering off in places nobody chose.
    func testSubdomainsAreTheirOwnSite() {
        XCTAssertEqual(CanvasBlockPolicy.siteKey(for: "jira.example.com"), "jira.example.com")
        XCTAssertNotEqual(CanvasBlockPolicy.siteKey(for: "jira.example.com"),
                          CanvasBlockPolicy.siteKey(for: "example.com"))
    }

    // MARK: Who gets filtered

    func testFilteringIsOnByDefault() {
        XCTAssertTrue(CanvasBlockPolicy.filters("example.com", unfiltered: []))
    }

    func testAnExcusedSiteIsNotFiltered() {
        XCTAssertFalse(CanvasBlockPolicy.filters("example.com", unfiltered: ["example.com"]))
    }

    /// Excusing the site from one card excuses it everywhere, however that card spelled the host.
    ///
    /// Only the host being asked about is normalised here: the stored set is already in key form,
    /// because everything that writes it goes through `siteKey` first. `CanvasContentBlocker` also
    /// normalises on read, so a set hand-edited with `defaults write` still behaves.
    func testExcusingIgnoresWWW() {
        XCTAssertFalse(CanvasBlockPolicy.filters("www.example.com", unfiltered: ["example.com"]))
        XCTAssertFalse(CanvasBlockPolicy.filters("WWW.EXAMPLE.COM.", unfiltered: ["example.com"]))
    }

    func testExcusingOneSiteLeavesTheRestFiltered() {
        XCTAssertTrue(CanvasBlockPolicy.filters("other.com", unfiltered: ["example.com"]))
        XCTAssertTrue(CanvasBlockPolicy.filters("jira.example.com", unfiltered: ["example.com"]))
    }

    /// A card whose address never parsed still gets the lists. Rules keyed to ad domains have nothing
    /// to say about such a page, so it costs nothing — and the alternative is a hole that opens every
    /// time a URL is malformed.
    func testAMissingHostIsStillFiltered() {
        XCTAssertTrue(CanvasBlockPolicy.filters(nil, unfiltered: ["example.com"]))
        XCTAssertTrue(CanvasBlockPolicy.filters("", unfiltered: [""]))
    }

    /// The number the build script checks every shipped list against. Worth pinning: one rule over and
    /// WebKit refuses the whole list, not the extra rule.
    func testRuleCeilingIsWhatWebKitEnforces() {
        XCTAssertEqual(CanvasBlockPolicy.ruleCeiling, 150_000)
    }
}

