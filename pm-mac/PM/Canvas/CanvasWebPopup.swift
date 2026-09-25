import AppKit
import WebKit

/// The window a page opens for itself, shown over the tile that opened it.
///
/// **What was broken.** Every request for a new window went through `createWebViewWith`, and both
/// answers PM gave threw away the one thing a popup is for. A card loaded the URL in place; the
/// sign-in window built a *second* window around a *fresh* configuration and returned nil. Either way
/// the new page had no `window.opener`, and `window.open` handed the page that asked a null.
///
/// That is invisible on an ordinary `target="_blank"` link, which is why it stood for so long, and
/// fatal to single sign-on, which is a conversation between two windows rather than a navigation:
///
/// > `window.open("/start_google_sso", "", "width=600,height=600")` — Figma's "Continue with Google",
/// > and the shape of every OAuth button on the web.
///
/// The popup goes to the identity provider, you pick an account, and it comes back to a callback page
/// whose entire body is `window.opener.postMessage(…)` and `window.close()`. With no opener that page
/// has nothing to say and nobody to say it to, and it cannot close itself either — so it renders as a
/// blank rectangle and the sign-in is over. The page is not broken and neither is the account: the
/// handshake was flattened into a navigation on the way in.
///
/// **So the popup gets to be a popup.** WebKit hands `createWebViewWith` a configuration it has
/// already derived from the opener's — same data store, same user agent, same rule lists — and the
/// opener relationship exists only if the returned web view is built from *that object*. Building an
/// equivalent one is not equivalent. Everything here follows from returning it: `window.opener` is
/// live, `postMessage` lands, and `webViewDidClose` arrives when the callback closes itself.
///
/// **Over its tile, not a window of its own.** A popup belongs to the page that asked for it, the way
/// an `alert()` does — see `CanvasWebDialogs`, which puts those over the tile for the same reason. It
/// stays with the card it came from instead of becoming a stray window to lose behind something, and
/// the modality is honest but narrow: you can't half-finish a sign-in and go back to poking the card
/// underneath, and everything else on the board carries on. It was a sheet over the whole window,
/// which held the call in the next tile hostage to a sign-in in this one. See `CanvasTileAlert`, which
/// places it, dims the tile, and follows the card — behind a tab, out into a window of its own.
/// `CanvasSignInWindow` is still a real window, because that one is a *menu command* — something you
/// chose to do, not something a page asked for mid-click; its popups go over its page.
/// What a popup needs of the card whose page opened it: somewhere to go when it is moved onto the
/// board. A web card is the one there is — see `CanvasLinkNodeView`.
@MainActor
protocol CanvasPopupOpener: AnyObject {
    /// Whether the board is tiled, so the button can say where the popup will go.
    var opensPopupsAsTiles: Bool { get }
    /// Take the popup's running page onto the board as a card of its own.
    func openPopupAsCard(_ page: WKWebView)
}

@MainActor
final class CanvasWebPopup: NSObject, WKUIDelegate, WKNavigationDelegate {
    /// Held so a popup isn't deallocated the moment the delegate method that made it returns.
    private static var open: Set<CanvasWebPopup> = []

    /// Tall enough for the host and a button, short enough not to read as a second title bar.
    private static let barHeight: CGFloat = 38

    private let web: WKWebView
    /// The popup's bar and page, which is what goes over the tile.
    private var content: NSView!
    /// Up over the tile — or, with nothing to put it over, a window of its own.
    private var overlay: CanvasTileAlert?
    private var fallback: NSWindow?
    /// What it is over: the card that opened it, which it follows, or a sign-in window's page.
    private weak var asker: NSView?
    private let address: NSTextField
    /// The card whose page opened this, for moving it onto that card's board. Nil for a popup opened
    /// from somewhere that isn't a card — the sign-in window, or another popup.
    private weak var opener: CanvasPopupOpener?

    // MARK: Deciding

    /// Whether a request for a new window is a *popup* rather than a link that wants a new tab.
    ///
    /// **The signal is that a script asked for a shape.** A features string — `width=600,height=600`,
    /// or anything else that turns the toolbars off — can only come from `window.open`, and a page
    /// that names a size is a page that intends to talk to what it opened. Markup cannot ask for one:
    /// `target="_blank"` has nowhere to put a width, so every one of those still flattens into the
    /// card exactly as before. That is the whole reason the card refuses windows in the first place,
    /// and it is a good reason; this narrows the refusal to the case it was never meant to cover.
    ///
    /// A bare `window.open(url)` with no features stays flattened too — it means "a new tab", and a
    /// card is a better answer to that than a modal you have to dismiss.
    static func wanted(by action: WKNavigationAction, features: WKWindowFeatures) -> Bool {
        // Belt and braces with the features test below: a link activation is a link, whatever else it
        // arrives with.
        guard action.navigationType != .linkActivated else { return false }
        return [features.width, features.height, features.x, features.y,
                features.allowsResizing, features.menuBarVisibility,
                features.statusBarVisibility, features.toolbarsVisibility]
            .contains { $0 != nil }
    }

    // MARK: Presenting

    /// Put WebKit's page over `asker`, and hand WebKit back the view it will load into.
    ///
    /// - Parameter configuration: the one `createWebViewWith` was given, unexchanged. See above.
    /// - Parameter userAgent: the opener's `customUserAgent`. It belongs to the view, not the
    ///   configuration, so a popup would otherwise sign in as Safari for a site told to expect Chrome.
    /// - Parameter asker: what it goes over — the card whose page asked (a `CanvasTileAlert.Asker`, so
    ///   it follows the card), or a page that isn't a card's.
    /// - Parameter opener: the card whose page asked, which is what can take the popup onto the board.
    @discardableResult
    static func present(with configuration: WKWebViewConfiguration,
                        features: WKWindowFeatures,
                        userAgent: String?,
                        over asker: NSView?,
                        opener: CanvasPopupOpener? = nil) -> WKWebView {
        let popup = CanvasWebPopup(configuration: configuration, features: features, opener: opener)
        popup.web.customUserAgent = userAgent
        popup.asker = asker
        open.insert(popup)
        popup.show(asked: Self.size(asked: features))
        return popup.web
    }

    private init(configuration: WKWebViewConfiguration, features: WKWindowFeatures,
                 opener: CanvasPopupOpener?) {
        self.opener = opener
        // A popup that opens a further popup is ordinary in single sign-on — an identity provider
        // handing off to a second one, or to a device-approval window. The card says no to this
        // because a card is not a place for a window to appear from nowhere; inside a popup the
        // question has already been answered.
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        // A card's kind of page, so that one moved onto the board is the same as any other card's.
        web = CanvasPageView(frame: .zero, configuration: configuration)
        // The popup most of all: single sign-on is the flow that goes wrong, and the window it goes
        // wrong in is this one.
        CanvasWebSession.allowInspecting(web)

        address = NSTextField(labelWithString: "")
        super.init()

        content = chrome(size: Self.size(asked: features))
        web.uiDelegate = self
        web.navigationDelegate = self
        web.allowsBackForwardNavigationGestures = true
    }

    /// The popup's own furniture: who you are talking to, and the way out.
    private func chrome(size: NSSize) -> NSView {
        let content = NSView(frame: NSRect(origin: .zero, size: size))

        let bar = NSVisualEffectView(frame: NSRect(x: 0, y: size.height - Self.barHeight,
                                                   width: size.width, height: Self.barHeight))
        bar.material = .titlebar
        bar.blendingMode = .withinWindow
        bar.autoresizingMask = [.width, .minYMargin]

        // **The address is the point of the bar.** A sign-in is a chain of hosts — the site, then the
        // identity provider, then back — and the only way to know a password field is safe to type
        // into is to be able to see whose it is. A popup over a tile has no title bar to put it in, so
        // it brings one. Same reasoning as `CanvasSignInWindow`'s subtitle, which is the same problem.
        address.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        address.textColor = .secondaryLabelColor
        address.alignment = .center
        address.lineBreakMode = .byTruncatingMiddle
        address.frame = NSRect(x: 80, y: (Self.barHeight - 16) / 2, width: size.width - 160, height: 16)
        address.autoresizingMask = [.width]

        // Escape closes it. A page that finishes normally closes its own popup and this is never
        // reached; what it covers is the half of the time you change your mind, where the alternative
        // is a modal with no way out but the one the page decides to offer.
        let done = NSButton(title: "Done", target: self, action: #selector(dismissed))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\u{1b}"
        done.sizeToFit()
        done.frame = NSRect(x: size.width - done.frame.width - 12,
                            y: (Self.barHeight - done.frame.height) / 2,
                            width: done.frame.width, height: done.frame.height)
        done.autoresizingMask = [.minXMargin]

        let line = NSBox(frame: NSRect(x: 0, y: 0, width: size.width, height: 1))
        line.boxType = .separator
        line.autoresizingMask = [.width]

        bar.addSubview(line)
        bar.addSubview(address)
        bar.addSubview(done)

        // **Some popups are the thing itself**, not a step in something else: a Slack huddle, a call,
        // a player. Over the tile is right for a sign-in, which is over in a minute, and wrong for those,
        // which would hold the tile hostage for as long as they run. So they can leave — onto the
        // board, still running, still talking to the page that opened them.
        if opener != nil {
            let move = NSButton(title: opener?.opensPopupsAsTiles == true ? "Open as Tile" : "Open as Card",
                                target: self, action: #selector(moveToBoard))
            move.bezelStyle = .rounded
            move.sizeToFit()
            move.frame = NSRect(x: 12, y: (Self.barHeight - move.frame.height) / 2,
                                width: move.frame.width, height: move.frame.height)
            move.autoresizingMask = [.maxXMargin]
            move.toolTip = "Put this on the board, where it keeps running beside your other cards"
            bar.addSubview(move)
            let clear = max(80, move.frame.maxX + 8)
            address.frame = NSRect(x: clear, y: address.frame.minY, width: size.width - 2 * clear,
                                   height: address.frame.height)
        }

        web.frame = NSRect(x: 0, y: 0, width: size.width, height: size.height - Self.barHeight)
        web.autoresizingMask = [.width, .height]

        content.addSubview(web)
        content.addSubview(bar)
        return content
    }

    /// The size the page asked for, with the bar: what the popup is when the tile has room. A site that
    /// asks for 400 × 400 is describing a browser popup with no chrome, and this one has a bar, so it
    /// gets no smaller than 480 × 560 on request — the tile may still trim it to `minimum`.
    private static func size(asked features: WKWindowFeatures) -> NSSize {
        NSSize(width: max(features.width?.doubleValue ?? 620, 480),
               height: max((features.height?.doubleValue ?? 720) + barHeight, 560))
    }

    /// The least a popup is and still works as one: under this the tile is too small, and it goes over
    /// the window instead.
    ///
    /// Small enough that a tile of an ordinary grid holds one: a sign-in page scrolls, and a tile it
    /// fits is better than the whole window dimmed for it.
    static let minimum = NSSize(width: 400, height: 320)

    private func show(asked size: NSSize) {
        if let asker, let overlay = CanvasTileAlert.present(
            hosting: .init(view: content, preferred: size, minimum: Self.minimum, initialFirstResponder: web),
            over: asker, gone: { [weak self] in self?.dismiss() }) {
            self.overlay = overlay
            return
        }
        // Nothing to put it over shouldn't happen from a card, and a web view that is in no window at
        // all renders nothing at all — so it gets to be a window rather than nothing.
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = content
        window.center()
        window.makeKeyAndOrderFront(nil)
        fallback = window
    }

    /// The popup's panel over the tile, for a test to find.
    var panel: CanvasTileAlert? { overlay }

    // MARK: Ending

    @objc private func dismissed() { dismiss() }

    /// Hand the running page to a new card beside the one that opened it, and go. The page isn't
    /// stopped and its delegates aren't cleared: the card takes both over as it adopts it.
    @objc private func moveToBoard() {
        guard let opener, Self.open.contains(self) else { return }
        web.removeFromSuperview()
        takeDown()
        Self.open.remove(self)
        opener.openPopupAsCard(web)
    }

    private func dismiss() {
        guard Self.open.contains(self) else { return }
        web.stopLoading()
        web.uiDelegate = nil
        web.navigationDelegate = nil
        takeDown()
        Self.open.remove(self)
    }

    private func takeDown() {
        overlay?.withdraw()
        overlay = nil
        fallback?.orderOut(nil)
        fallback = nil
    }

    /// `window.close()`, which is how an OAuth callback signs off — and which WebKit only sends for a
    /// page that was script-opened, so it arrives exactly for the popups that need it.
    func webViewDidClose(_ webView: WKWebView) {
        // Next turn of the loop: WebKit is inside the view it is asking us to take down, and this is
        // the call that releases the last reference to it.
        Task { @MainActor in self.dismiss() }
    }

    /// Follows the address across the handoff, which is the whole job of the bar.
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        address.stringValue = webView.url?.host() ?? ""
    }

    // MARK: What the popup itself is allowed to put up

    /// A popup that opens a popup gets the same treatment, over the same tile and on top of this one —
    /// an identity provider handing off to another is a normal shape for this to take.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        Self.present(with: configuration, features: windowFeatures, userAgent: webView.customUserAgent,
                     over: asker ?? web)
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping () -> Void) {
        CanvasWebDialogs.alert(message, from: frame.securityOrigin.host, over: web, in: web.window,
                               then: completionHandler)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (Bool) -> Void) {
        CanvasWebDialogs.confirm(message, from: frame.securityOrigin.host, over: web, in: web.window,
                                 then: completionHandler)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        CanvasWebDialogs.prompt(prompt, initial: defaultText ?? "", from: frame.securityOrigin.host,
                                over: web, in: web.window, then: completionHandler)
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping ([URL]?) -> Void) {
        CanvasWebDialogs.chooseFiles(parameters, in: web.window, then: completionHandler)
    }

    /// A huddle or a call is exactly what a popup is for, so it asks the way a card does.
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        CanvasWebDialogs.mediaAccess(for: origin.host, type, over: web, in: web.window, then: decisionHandler)
    }
}
