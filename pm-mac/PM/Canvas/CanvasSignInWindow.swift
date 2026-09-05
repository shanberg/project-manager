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
/// - **Cards deliberately refuse to open windows.** A card answers `createWebViewWith` by loading the
///   link in place, which is what makes ordinary `target="_blank"` links work instead of silently
///   doing nothing. Single sign-on is the one flow where that is the wrong answer: an identity
///   provider opened in a popup often talks back to the window that opened it, and flattening that
///   into one navigation can leave the handshake with nowhere to land.
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

    static func present(for url: URL, onFinish: @escaping () -> Void) {
        let controller = CanvasSignInWindow(url: url, onFinish: onFinish)
        open.insert(controller)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private init(url: URL, onFinish: (() -> Void)?) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = CanvasWebSession.store
        // The same filtering the card gets. A sign-in page that behaves differently from the card it
        // was opened for is a debugging trap, and consent banners are, if anything, worse here.
        CanvasContentBlocker.attach(to: configuration, for: url.host())
        // The opposite of a card: here, a page that asks for a window is asking for a good reason.
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        web = WKWebView(frame: .zero, configuration: configuration)
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

    /// An identity provider that wants a window gets one, and it is the same kind of window — so a
    /// popup that opens a further popup still works.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let url = navigationAction.request.url else { return nil }
        Self.present(for: url, onFinish: {})
        return nil
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
