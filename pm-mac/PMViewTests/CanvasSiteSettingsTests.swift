import XCTest
import WebKit

/// What PM remembers per site (backlog 31): which browser a site is told it is talking to, and whether
/// its ads are blocked — with the old list of excused sites folded in.
@MainActor
final class CanvasSiteSettingsTests: XCTestCase {

    private var defaults: UserDefaults!
    private let suite = "PMViewTests.CanvasSiteSettings"

    override func setUp() {
        super.setUp()
        UserDefaults().removePersistentDomain(forName: suite)
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testASiteNobodyChangedIsSafariWithAdsBlocked() {
        XCTAssertEqual(CanvasSiteSettings.site(for: "example.com", in: defaults), CanvasSite())
        XCTAssertEqual(CanvasSiteSettings.site(for: nil, in: defaults), CanvasSite())
        XCTAssertTrue(CanvasSiteSettings.all(in: defaults).isEmpty)
    }

    func testAChangeIsTheSitesNotTheHosts() {
        CanvasSiteSettings.update("www.Slack.com", in: defaults) { $0.identity = .chrome }
        XCTAssertEqual(CanvasSiteSettings.site(for: "slack.com", in: defaults).identity, .chrome)
        XCTAssertEqual(CanvasSiteSettings.site(for: "other.com", in: defaults).identity, .safari)
        XCTAssertEqual(Array(CanvasSiteSettings.all(in: defaults).keys), ["slack.com"])
    }

    /// Back to the defaults is out of the list, so Settings shows only what was changed.
    func testASiteBackToTheDefaultsIsForgotten() {
        CanvasSiteSettings.update("example.com", in: defaults) { $0.blocksAds = false }
        CanvasSiteSettings.update("example.com", in: defaults) { $0.identity = .firefox }
        XCTAssertEqual(CanvasSiteSettings.site(for: "example.com", in: defaults),
                       CanvasSite(identity: .firefox, blocksAds: false))
        XCTAssertEqual(CanvasSiteSettings.unblocked(in: defaults), ["example.com"])
        CanvasSiteSettings.update("example.com", in: defaults) { $0 = CanvasSite() }
        XCTAssertTrue(CanvasSiteSettings.all(in: defaults).isEmpty)
        XCTAssertEqual((defaults.dictionary(forKey: CanvasSiteSettings.defaultsKey) ?? [:]).count, 0)
    }

    func testTheOldExcusedSitesAreFoldedInOnce() {
        defaults.set(["www.example.com", "news.site.org"], forKey: CanvasSiteSettings.legacyUnfilteredKey)
        XCTAssertEqual(CanvasSiteSettings.unblocked(in: defaults), ["example.com", "news.site.org"])
        XCTAssertNil(defaults.object(forKey: CanvasSiteSettings.legacyUnfilteredKey))
        CanvasSiteSettings.update("example.com", in: defaults) { $0.blocksAds = true }
        XCTAssertEqual(CanvasSiteSettings.unblocked(in: defaults), ["news.site.org"])
    }

    func testTheVersionsKeepUpWithTheCalendar() {
        func day(_ text: String) -> Date { ISO8601DateFormatter().date(from: text + "T12:00:00Z")! }
        XCTAssertEqual(CanvasBrowserIdentity.chromeVersion(on: day("2025-09-02")), 140)
        XCTAssertEqual(CanvasBrowserIdentity.chromeVersion(on: day("2025-12-01")), 142)
        XCTAssertGreaterThan(CanvasBrowserIdentity.chromeVersion(on: day("2026-09-17")), 150)
        XCTAssertEqual(CanvasBrowserIdentity.firefoxVersion(on: day("2025-09-16")), 143)
        let chrome = CanvasBrowserIdentity.chrome.userAgent(on: day("2025-09-02"))
        XCTAssertEqual(chrome, "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36")
        XCTAssertNil(CanvasBrowserIdentity.safari.userAgent())
    }

    /// End to end, as `CanvasUserAgentTests` does it: the page, asked, says the whole string.
    func testAWebViewToldChromeSaysChrome() async throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        CanvasWebSession.identify(configuration)
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.customUserAgent = CanvasBrowserIdentity.chrome.userAgent()
        web.loadHTMLString("<html><body></body></html>", baseURL: URL(string: "about:blank"))
        let reported = try await web.evaluateJavaScript("navigator.userAgent")
        let agent = try XCTUnwrap(reported as? String)
        XCTAssertTrue(agent.contains("Chrome/"), agent)
        XCTAssertFalse(agent.contains("Version/"), agent)
    }
}
