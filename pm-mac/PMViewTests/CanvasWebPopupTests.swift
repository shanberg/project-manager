import XCTest
import WebKit

/// The two-window handshake a sign-in is made of.
///
/// A card used to answer every request for a new window by loading it in place, which is right for a
/// `target="_blank"` link and fatal for "Continue with Google": the popup came back to a callback page
/// whose whole job is `window.opener.postMessage(…)`, found no opener, and stopped as a blank
/// rectangle. So these assert the opener itself — not that a window appeared, but that the two ends
/// can still talk, which is the thing that was actually missing.
@MainActor
final class CanvasWebPopupTests: XCTestCase {

    /// The card's answer to `createWebViewWith`, with the board and the node left out: the same two
    /// calls `CanvasLinkNodeView` makes, in the same order.
    @MainActor
    private final class Card: NSObject, WKUIDelegate {
        let parent: NSWindow
        /// URLs the card loaded in place instead of giving a window to.
        var flattened: [URL] = []
        var popup: WKWebView?

        init(parent: NSWindow) { self.parent = parent }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            if CanvasWebPopup.wanted(by: navigationAction, features: windowFeatures) {
                popup = CanvasWebPopup.present(with: configuration, features: windowFeatures, userAgent: nil,
                                               over: parent)
                // The popup's page opts into dark too; this covers the sheet before it paints.
                popup?.underPageBackgroundColor = .windowBackgroundColor
                return popup
            }
            if let url = navigationAction.request.url { flattened.append(url) }
            webView.load(navigationAction.request)
            return nil
        }
    }

    /// A page that can open a popup the way a sign-in button does, and that remembers being spoken to.
    ///
    /// `about:blank` rather than a URL off the network, so the test needs no host to be up: a popup
    /// opened that way inherits the opener's origin, which is exactly the relationship under test.
    private static let page = """
    <html><meta name="color-scheme" content="light dark"><body><script>
    window.received = null;
    addEventListener('message', function (event) { window.received = event.data; });
    function popup(features) {
      var opened = window.open('about:blank', '', features);
      if (!opened) { return 'flattened'; }
      opened.document.write('<meta name="color-scheme" content="light dark"><scr' + 'ipt>window.opener.postMessage("hello", "*");<' + '/script>');
      return 'opened';
    }
    </script></body></html>
    """

    private var board: NSWindow!
    private var card: Card!
    private var opener: WKWebView!

    override func setUp() async throws {
        try await super.setUp()
        TestApp.start()
        board = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
                         styleMask: [.titled], backing: .buffered, defer: false)
        board.orderFront(nil)
        card = Card(parent: board)

        let configuration = WKWebViewConfiguration()
        // Not the app's jar: this is about which windows exist, and a test that wrote into the shared
        // store would leave a cookie behind on the machine that ran it.
        configuration.websiteDataStore = .nonPersistent()
        // A card sets this false, so a page can only open a window from a click. There is no click
        // here, and what is under test starts once the request has been made either way.
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        opener = WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 400),
                           configuration: configuration)
        opener.uiDelegate = card
        opener.loadHTMLString(Self.page, baseURL: URL(string: "https://opener.invalid/"))
        // Asked about the page's own function rather than `document.readyState`, which answers
        // "complete" about the empty document a web view starts with — before the load under way has
        // replaced it, so every question after it is asked of the wrong page.
        try await until("the page loads") {
            (try? await self.opener.evaluateJavaScript("typeof popup")) as? String == "function"
        }
    }

    override func tearDown() async throws {
        opener?.uiDelegate = nil
        if let sheet = board?.attachedSheet { board.endSheet(sheet) }
        board?.orderOut(nil)
        try await super.tearDown()
    }

    // MARK: The bug

    /// The whole of it: what a script opens is a real second window, and it can still reach the one
    /// that opened it.
    func testAPopupCanStillTalkToThePageThatOpenedIt() async throws {
        let opened = try await opener.evaluateJavaScript("popup('width=600,height=600')")
        XCTAssertEqual(opened as? String, "opened", "window.open was answered with null.")

        let popup = try XCTUnwrap(card.popup, "A sign-in popup was flattened into the card.")
        let hasOpener = try await popup.evaluateJavaScript("window.opener !== null")
        XCTAssertEqual(hasOpener as? Bool, true,
                       "The popup has no opener, so an OAuth callback has nobody to answer.")

        // Both directions, since a sign-in needs the reply as much as the call: the popup posted to
        // the opener as the callback page does, and the opener heard it.
        try await until("the opener hears from the popup") {
            (try? await self.opener.evaluateJavaScript("window.received")) as? String == "hello"
        }
    }

    /// A popup on a sheet over the board, and gone from it when the page closes itself — which is how
    /// an OAuth callback signs off, and what used to leave a dead window standing.
    func testAPopupIsASheetThatTheCallbackCanClose() async throws {
        _ = try await opener.evaluateJavaScript("popup('width=600,height=600')")
        let popup = try XCTUnwrap(card.popup)
        XCTAssertNotNil(board.attachedSheet, "The popup didn't land on the board's window.")

        _ = try? await popup.evaluateJavaScript("window.close()")
        try await until("the sheet goes away with the page") { self.board.attachedSheet == nil }
    }

    // MARK: What must not change

    /// The reason a card refuses windows in the first place. A link that wants a new tab has no size
    /// to ask for, so it still opens in the card rather than a modal you have to dismiss.
    func testAWindowNobodyGaveAShapeStillOpensInTheCard() async throws {
        let opened = try await opener.evaluateJavaScript("popup('')")
        XCTAssertEqual(opened as? String, "flattened")
        XCTAssertNil(card.popup)
        XCTAssertEqual(card.flattened.map(\.absoluteString), ["about:blank"])
    }

    // MARK: Waiting

    private func until(_ what: String, _ done: () async -> Bool) async throws {
        for _ in 0..<200 {
            if await done() { return }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTFail("Timed out waiting for \(what).")
    }
}
