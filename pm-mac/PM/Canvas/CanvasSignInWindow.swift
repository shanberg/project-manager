import AppKit
import WebKit

/// A real window for signing in to the site a card shows.
///
/// The cards themselves already share one persistent session — every web card is built on
/// `WKWebsiteDataStore.default()`, which is per-app, on disk, and survives quitting PM — so a site you
/// have signed in to once stays signed in on every card on every board. That part has always worked.
/// What did not work was *getting* signed in:
///
/// - **A card is 400 points square.** That is the median on a real board, and a sign-in page is one of
///   the few pages genuinely designed for a full window: an email field, a password field, a consent
///   screen, a device-approval prompt, sometimes a QR code. Doing that inside a dashboard tile is
///   miserable in a way that no amount of page zoom fixes.
/// - **A card flattens a new window into a navigation.** That is what makes ordinary
///   `target="_blank"` links work instead of silently doing nothing, and it is right for a link.
///   Single sign-on is where it was wrong — an identity provider opened in a popup talks back to the
///   window that opened it — and a card now hands a real popup a sheet of its own rather than
///   flattening it; see `CanvasWebPopup`. This window is the other half of the same problem: not the
///   popup a page asks for mid-click, but the page you went looking for a sign-in on.
///
/// So sign-in gets its own window, on the same store, with the opposite popup rule — here a request
/// for a window gets a window. Whatever the session picks up lands in the same jar the cards read, so
/// closing this window is the end of it: the card is told to reload and comes back signed in.
@MainActor
final class CanvasSignInWindow: NSWindowController, WKUIDelegate, WKNavigationDelegate {
    /// Held so the window isn't deallocated the moment the function that made it returns.
    private static var open: Set<CanvasSignInWindow> = []

    private let web: WKWebView
    private let site: String
    /// Told when the window closes, so the card that asked can pick the session up.
    private var onFinish: (() -> Void)?

    /// - Parameter profile: the card's session, so signing in lands in the jar that card reads. Nil is
    ///   the shared one — see `CanvasCardSession`. A window that signed in to the shared session on
    ///   behalf of a card on a profile would report success and change nothing the card can see.
    static func present(for url: URL, profile: String? = nil, onFinish: @escaping () -> Void) {
        let controller = CanvasSignInWindow(url: url, profile: profile, onFinish: onFinish)
        open.insert(controller)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private init(url: URL, profile: String?, onFinish: (() -> Void)?) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = CanvasWebSession.store(named: profile)
        // The same name the card sends, for the same reason and doubly so here: a sign-in page is
        // exactly where a site decides whether it will talk to your browser at all.
        CanvasWebSession.identify(configuration)
        // The same filtering the card gets. A sign-in page that behaves differently from the card it
        // was opened for is a debugging trap, and consent banners are, if anything, worse here.
        CanvasContentBlocker.attach(to: configuration, for: url.host())
        CanvasAdvancedRules.attach(to: configuration, for: url.host())
        // The opposite of a card: here, a page that asks for a window is asking for a good reason.
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        web = WKWebView(frame: .zero, configuration: configuration)
        CanvasWebSession.identify(web, host: url.host())
        CanvasWebSession.allowInspecting(web)
        site = url.host() ?? url.absoluteString
        self.onFinish = onFinish

        // Sized for a sign-in page rather than for a browser: tall enough for a consent screen with a
        // list of permissions, narrow enough that a centred form doesn't sit in a field of white.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 760),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.contentView = web
        window.center()
        super.init(window: window)

        window.delegate = self
        window.title = "Sign in to \(site)"
        web.uiDelegate = self
        web.navigationDelegate = self
        web.allowsBackForwardNavigationGestures = true
        web.load(URLRequest(url: url))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The subtitle follows the address, because during a single sign-on you are handed between hosts
    /// and the only way to know a password field is safe to type into is to be able to see whose it is.
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        window?.subtitle = webView.url?.host() ?? ""
    }

    /// An identity provider that wants a window gets one, on a sheet over this one.
    ///
    /// **It has to be WebKit's web view, not another like it.** This used to open a second sign-in
    /// window around a configuration of its own and return nil, which reads as the same thing and is
    /// not: `window.open` returned null to the page that called it, and the page that opened had no
    /// `window.opener` to answer through. An OAuth popup is a conversation between two windows, so
    /// both ends went missing at once and the flow died on a blank callback page — the same failure a
    /// card had, by a different route. `CanvasWebPopup` returns the view WebKit handed us.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        CanvasWebPopup.present(with: configuration, features: windowFeatures,
                               userAgent: webView.customUserAgent, over: window)
    }
}

extension CanvasSignInWindow: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        web.stopLoading()
        web.uiDelegate = nil
        web.navigationDelegate = nil
        onFinish?()
        onFinish = nil
        Self.open.remove(self)
    }
}
