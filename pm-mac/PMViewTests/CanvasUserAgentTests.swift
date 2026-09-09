import XCTest
import WebKit

/// What a web card tells a site it is.
///
/// Slack and Google Docs both answered a card with "your browser is not supported", and neither was
/// judging the engine — a card is Safari's engine at Safari's version. They were reading the user
/// agent, which a bare `WKWebView` ends at `AppleWebKit/605.1.15 (KHTML, like Gecko)` with no
/// `Version/` and no `Safari/` token after it. Detection tables are lists of exactly those two tokens,
/// so a card read as an unknown browser rather than an old one.
///
/// Asserted end to end — a real web view, loaded, asked what `navigator.userAgent` says — because the
/// property we set is only the *tail* of the string WebKit composes, and the thing that has to be true
/// is about the whole of it.
@MainActor
final class CanvasUserAgentTests: XCTestCase {

    private func userAgent(identified: Bool) async throws -> String {
        let configuration = WKWebViewConfiguration()
        // The shared jar is deliberately not touched: this is about what we say, not where cookies go,
        // and a test that built the app's persistent store would leave one behind.
        configuration.websiteDataStore = .nonPersistent()
        if identified { CanvasWebSession.identify(configuration) }
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.loadHTMLString("<html><body></body></html>", baseURL: URL(string: "about:blank"))
        let reported = try await web.evaluateJavaScript("navigator.userAgent")
        return try XCTUnwrap(reported as? String)
    }

    /// The bug, so the fix is measured against something rather than asserted about itself.
    func testAnUnidentifiedWebViewNamesNoBrowser() async throws {
        let agent = try await userAgent(identified: false)
        XCTAssertTrue(agent.contains("AppleWebKit"), agent)
        XCTAssertFalse(agent.contains("Safari/"), "Unset, WebKit names no browser at all: \(agent)")
    }

    func testACardSaysItIsSafari() async throws {
        let agent = try await userAgent(identified: true)
        XCTAssertTrue(agent.contains("Version/"), agent)
        XCTAssertTrue(agent.contains("Safari/605.1.15"), agent)
        // Appended to WebKit's own string rather than replacing it — the platform and engine tokens a
        // site reads before it gets to the browser name are still there.
        XCTAssertTrue(agent.contains("Macintosh"), agent)
        XCTAssertTrue(agent.contains("AppleWebKit"), agent)
    }

    /// The version is the installed Safari's, not a constant that ages. On a machine with Safari where
    /// it belongs, that is the number in its `Info.plist`.
    func testTheVersionIsTheInstalledSafari() throws {
        let installed = Bundle(path: "/Applications/Safari.app")?
            .infoDictionary?["CFBundleShortVersionString"] as? String
        try XCTSkipIf(installed == nil, "No Safari to compare against.")
        XCTAssertEqual(CanvasWebSession.applicationName,
                       "Version/\(installed!) Safari/605.1.15")
    }
}
