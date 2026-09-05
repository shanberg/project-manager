import AppKit
import WebKit
import PmLib

/// A web page clipped onto the board, embedded live.
///
/// This is the one part of a canvas that reaches the network, and PM has been careful about that — the
/// app's only other network call is a favicon fetch, behind a switch, with a paragraph in Settings
/// explaining itself. A board of link cards is a much bigger claim: `OSINT.canvas` holds eleven, and
/// opening it eagerly would be eleven page loads and eleven renderers the moment a window appeared.
///
/// So a page loads when two things are true, and not before:
///
/// - **the card is on screen.** Cards are built as they scroll into view, so a board of a hundred
///   links only ever loads the handful you are looking at, and one scrolled away stops.
/// - **the board is zoomed in enough for the page to be worth drawing** — `pagesLoadAbove`, which is
///   much further out than the zoom a *note* stops being worth drawing at, because a page reads as a
///   shape long after its text has stopped being legible.
///
/// **The placeholder is the card; the page is drawn over it.** The site's icon and host are put up
/// immediately and stay up — through the load, and permanently if the load fails. The page is a layer
/// on top that is revealed only once it has something to show. Before, the placeholder was thrown away
/// at the moment the request started, so a card went blank for the second or two a real page takes and
/// stayed blank forever if the page never came: the card lost its identity exactly when it was least
/// able to say what it was.
///
/// **Nothing is drawn on top of the page.** No caption strip above it, no freshness capsule floating
/// over it. A loaded page fills the card corner to corner, and everything a card used to say about
/// itself in its own chrome is said somewhere that costs the page nothing: the host and the age on the
/// tooltip, and — for the one card you have stepped into, which is the only card whose address can
/// cost you anything — the live address in the window's own header, beside the controls that drive it.
/// See `cardDescription` and `CanvasHeaderModel`.
@MainActor
final class CanvasLinkNodeView: CanvasNodeView {
    /// The card's body. Holds the placeholder always, and the page over it once there is one.
    private let face = NSView()
    private var web: WKWebView?
    private var placeholder: NSView?
    /// The picture of the page that stands in for it while it is paused. See `freeze`.
    private var frozen: NSImageView?
    /// The line under the host: what the card is doing, or why it isn't doing it.
    private var status: NSTextField?
    /// Whether this card would run a page if the board let it. The board answers — see
    /// `CanvasPageBudget`.
    private var wanted = false
    /// The whole session as it was when the card was paused — the page, the scroll position, and the
    /// back-forward list — captured with `interactionState`.
    ///
    /// It replaced a URL and a scroll offset read out with JavaScript, which was worse in three ways
    /// that all showed up in use: a page with a strict CSP could refuse the read, a card that had been
    /// paused came back with **no history**, so Back was dead through no fault of yours, and it meant
    /// injecting script into a page to ask it where it was. This is one synchronous property.
    private var resumeState: Any?
    private var resumeURL: URL?
    /// Set while a snapshot is in flight, so a second pause request doesn't start a second one.
    private var freezing = false
    /// When what the card is showing arrived — the moment the page finished, and still the answer
    /// after it has been frozen, because the picture is that page.
    private(set) var loadedAt: Date?
    /// True once the page has been shown. A failure after this point leaves the page alone rather than
    /// yanking you back to the placeholder — you are reading something, and a subresource that 404s
    /// is not a reason to take the page away.
    private var revealed = false
    private var giveUp: DispatchWorkItem?

    /// Whether link cards embed the live page at all. On, because that is what a link card is for —
    /// but it is a network call made on your behalf by opening a document, so it is a switch.
    static let defaultsKey = "PMCanvasLoadsWebCards"
    static var loadsPages: Bool {
        UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true
    }

    override init(node: CanvasNode, board: CanvasBoardView, scale: Double) {
        super.init(node: node, board: board, scale: scale)
        setContent(face)
        showPlaceholder()
        reconsiderLoading(scale: scale)
    }

    override var isPageCard: Bool { true }
    override var wantsPage: Bool { wanted }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The address written on the board for this card. Where Home goes, and what the card is *for*.
    var address: String {
        if case .link(let url) = node.content { return url }
        return ""
    }

    var url: URL? { URL(string: address) }
    private var host: String { url?.host()?.replacingOccurrences(of: "www.", with: "") ?? address }

    /// Where the page actually is right now, which is not always where the board says it should be.
    var liveURL: URL? { web?.url ?? url }

    /// The host of whatever is on screen, for the window header to name.
    var liveHost: String {
        liveURL?.host()?.replacingOccurrences(of: "www.", with: "") ?? host
    }

    override func update(node: CanvasNode, scale: Double) {
        // A changed address *is* a changed content, so the base already rebuilds through
        // `contentChanged`. Doing it again here — which is what this used to do — started the page,
        // tore it down and started it a second time.
        super.update(node: node, scale: scale)
        // The zoom, on the other hand, reaches us nowhere else: `simplificationChanged` is deliberately
        // a no-op for a web card, so this is the line that notices you have zoomed in far enough.
        reconsiderLoading(scale: scale)
    }

    /// A web card keeps its own threshold, so the board crossing the *text* one is not its business.
    /// Rebuilding here would tear down a page you are looking at and load it again, which is a reload
    /// triggered by a scroll wheel.
    override func simplificationChanged() {}

    override func contentChanged() {
        // The address changed to the page this card is already displaying — see `adoptCurrentAddress`.
        // Nothing to rebuild; the card is already right, and rebuilding it would be the only thing the
        // user could see going wrong.
        if alreadyShowing {
            alreadyShowing = false
            describeYourself()
            board.pageStateChanged()
            return
        }
        tearDownPage()
        loadedAt = nil
        timePassed()
        // A different address makes everything the card remembered about the old one worthless.
        resumeURL = nil
        resumeState = nil
        wanted = false
        showPlaceholder()
        reconsiderLoading(scale: board.liveScale)
    }

    /// Say whether this card would like to be running, and let the board decide.
    private func reconsiderLoading(scale: Double) {
        let wants = Self.loadsPages && scale >= CanvasDetail.pagesLoadAbove && url != nil
        guard wants != wanted else { return }
        wanted = wants
        board.reviewPageBudget()
    }

    // MARK: Running, and not running

    /// The board's answer to `wantsPage`.
    override func setPageLive(_ live: Bool) {
        if live {
            guard web == nil, Self.loadsPages, let target = resumeURL ?? url else { return }
            showPage(target)
        } else {
            freeze()
        }
    }

    /// Stop running, and leave a picture of the page behind.
    ///
    /// The picture is the whole point of pausing rather than unloading. A board where the cards you
    /// aren't looking at turn back into globes is a board that tells you less the more of it you can
    /// see — and the cards off to the side are exactly the ones you are reading at a glance rather
    /// than using. Frozen, a card still says what it is showing; it just stops costing anything.
    ///
    /// The snapshot is best-effort — one of a card that never painted comes back nil, which just means
    /// waking up through the placeholder instead of through a picture. The session capture is not: it
    /// is a synchronous property read that cannot fail or be refused.
    private func freeze() {
        guard let web, !freezing else { return }
        freezing = true
        giveUp?.cancel()
        giveUp = nil
        resumeState = web.interactionState
        resumeURL = web.url ?? resumeURL ?? url
        snapshotThenStop(web)
    }

    private func snapshotThenStop(_ running: WKWebView) {
        guard web === running else { freezing = false; return }
        let configuration = WKSnapshotConfiguration()
        // The card may well be off the edge of the window by now, and asking for a fresh screen update
        // on a view nobody can see is how a snapshot comes back nil. Take what has already painted.
        configuration.afterScreenUpdates = false
        let showing = revealed
        running.takeSnapshot(with: configuration) { [weak self] image, _ in
            guard let self, web === running else { self?.freezing = false; return }
            if let image, showing { showFrozen(image) }
            tearDownPage()
            freezing = false
        }
    }

    private func showFrozen(_ image: NSImage) {
        frozen?.removeFromSuperview()
        let view = NSImageView()
        view.image = image
        view.imageScaling = .scaleAxesIndependently
        view.setAccessibilityLabel(host)
        frozen = view
        fill(face, with: view, below: placeholder)
    }

    // MARK: The card, and the page over it

    private func showPlaceholder() {
        placeholder?.removeFromSuperview()

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 7
        stack.alignment = .centerX

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: 24, weight: .light)
        icon.contentTintColor = .tertiaryLabelColor
        icon.setAccessibilityLabel(host)

        // The site's own icon if the app already has it. Fetched through the shared loader, which
        // asks the site directly and remembers a miss — the same one the project window's links use,
        // and switched off by the same setting.
        if let site = url?.host() {
            if let cached = FaviconLoader.shared.cached(for: site) {
                icon.image = cached
                icon.contentTintColor = nil
            } else {
                FaviconLoader.shared.warm(hosts: [site])
                Task { [weak icon] in
                    guard let image = await FaviconLoader.shared.favicon(for: site) else { return }
                    icon?.image = image
                    icon?.contentTintColor = nil
                }
            }
        }

        let title = NSTextField(labelWithString: host)
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.alignment = .center
        title.lineBreakMode = .byTruncatingTail

        let note = NSTextField(labelWithString: "")
        note.font = .systemFont(ofSize: 10.5)
        note.textColor = .tertiaryLabelColor
        note.alignment = .center
        note.lineBreakMode = .byTruncatingTail
        note.isHidden = true
        status = note

        stack.addArrangedSubview(icon)
        stack.addArrangedSubview(title)
        stack.addArrangedSubview(note)

        let container = NSView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor, constant: -20),
        ])

        placeholder = container
        fill(face, with: container)
        revealed = false
    }

    private func say(_ text: String?, tooltip: String? = nil) {
        status?.stringValue = text ?? ""
        status?.isHidden = text == nil
        status?.toolTip = tooltip
    }

    private func showPage(_ url: URL) {
        let configuration = WKWebViewConfiguration()
        // Every card, on every board, and the sign-in window too. Signing in once is signing in.
        configuration.websiteDataStore = CanvasWebSession.store
        // Ads, trackers and cookie banners. A rule list can only be handed to a web view as that view
        // is built, which is also why excusing a site rebuilds the page rather than reloading it.
        CanvasContentBlocker.attach(to: configuration, for: url.host())
        CanvasAdvancedRules.attach(to: configuration, for: url.host())
        // A card is a clipping, not a browser: it shouldn't be able to *spontaneously* open windows.
        // A link you click is a different matter — see `createWebViewWith` below, which is what makes
        // a `target="_blank"` link navigate instead of silently doing nothing.
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        // Nothing is shown until the page has laid out anyway, because the placeholder is over it —
        // this just spares the card a half-painted frame at the moment of the reveal.
        configuration.suppressesIncrementalRendering = true

        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        view.uiDelegate = self
        // Left off deliberately: a two-finger swipe inside an engaged card would be a horizontal
        // scroll on most pages and a "go back" on the rest. Back is on the card's menu instead, where
        // it can't be triggered by accident.
        view.allowsBackForwardNavigationGestures = false
        view.setValue(false, forKey: "drawsBackground")
        if let resumeState {
            // Puts the page, the scroll position and the back-forward list back as they were, and
            // starts the navigation itself — so no `load` here.
            view.interactionState = resumeState
            self.resumeState = nil
            // A restore that produced nothing leaves a card that would sit behind its own snapshot
            // for good. Cheap to check, and the address is still the honest fallback.
            if view.backForwardList.currentItem == nil { view.load(URLRequest(url: url)) }
        } else {
            view.load(URLRequest(url: url))
        }
        web = view
        // The lists take about ten seconds to compile on the first launch after an update, and a
        // canvas restored at startup can open well inside that window. A card built before they were
        // ready gets one chance to notice and start again, rather than staying unfiltered until
        // something else happens to reload it.
        if !CanvasContentBlocker.isReady {
            CanvasContentBlocker.onReady { [weak self, weak view] in
                guard let self, let view, web === view else { return }
                reapplyFiltering()
            }
        }

        // Under whatever is standing in for the page — the picture from the last time it ran, or the
        // placeholder. Waking up should not flash anything.
        fill(face, with: view, below: frozen ?? placeholder)
        if isEngaged { window?.makeFirstResponder(view) }
        if frozen == nil { say("Loading…") }
        waitForIt()
    }

    /// A page that never finishes is shown anyway after a while.
    ///
    /// `didFinish` is the honest signal that a page is ready, but plenty of real pages hold a request
    /// open forever — a socket, a poll, an ad that never settles — and would sit behind the
    /// placeholder for good while being perfectly readable underneath it. After eight seconds, take
    /// whatever has painted.
    private func waitForIt() {
        giveUp?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.revealPage() }
        giveUp = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: work)
    }

    /// How long the placeholder takes to get out of the page's way.
    ///
    /// It used to be an instant `isHidden`, which on a card the size of a real one is a hard cut from
    /// a centred globe to a full page — the one moment on the board where something appears out of
    /// nothing. A fifth of a second of cross-fade is below the threshold at which it reads as an
    /// animation and above the one at which it reads as a jump.
    private static let revealDuration = 0.2

    private func revealPage() {
        giveUp?.cancel()
        giveUp = nil
        guard web != nil else { return }
        let first = !revealed
        revealed = true
        loadedAt = Date()
        describeYourself()

        let going = [placeholder, frozen].compactMap { $0 }
        if first, !going.isEmpty {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.revealDuration
                context.allowsImplicitAnimation = true
                for view in going { view.animator().alphaValue = 0 }
            } completionHandler: { [weak self] in
                guard let self else { return }
                // Hidden rather than removed, because the placeholder is the card's fallback: a page
                // that later fails, or a card that is frozen and woken, comes back through it. Its
                // alpha is put back at the same time, or it would come back invisible.
                placeholder?.isHidden = true
                placeholder?.alphaValue = 1
                frozen?.removeFromSuperview()
                frozen = nil
            }
        } else {
            placeholder?.isHidden = true
            placeholder?.alphaValue = 1
            frozen?.removeFromSuperview()
            frozen = nil
        }
        board.pageStateChanged()
    }

    private func tearDownPage() {
        giveUp?.cancel()
        giveUp = nil
        web?.stopLoading()
        web?.navigationDelegate = nil
        web?.uiDelegate = nil
        web?.removeFromSuperview()
        web = nil
        revealed = false
    }

    /// Put `view` in `container`, filling it, optionally beneath a view already there.
    private func fill(_ container: NSView, with view: NSView, below sibling: NSView? = nil) {
        view.translatesAutoresizingMaskIntoConstraints = false
        if let sibling, sibling.superview === container {
            container.addSubview(view, positioned: .below, relativeTo: sibling)
        } else {
            container.addSubview(view)
        }
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    /// What the card says about itself when you linger on it.
    ///
    /// This is where the caption strip went, and the freshness capsule with it. Both were chrome drawn
    /// on the card — one above the page, one over it — and both were saying things worth knowing
    /// occasionally and not worth looking at continuously. A board of eleven web cards carried eleven
    /// captions and eleven capsules permanently on screen so that you could, once in a while, want one
    /// of them.
    ///
    /// A tooltip is the Mac's own answer to exactly that: it costs nothing until you ask, it takes no
    /// space, and asking is lingering rather than clicking. The board owns the tooltip and reads this
    /// from whichever card is under the pointer — a card doesn't hit-test until you step into it, so it
    /// could not carry one itself. See `CanvasBoardView.hovered`.
    override var cardDescription: String? {
        var lines = [liveHost]
        if let loadedAt { lines.append(canvasFreshnessLabel(for: loadedAt)) }
        if hasWandered { lines.append("Not the address saved on this board \u{2014} " + address) }
        return lines.joined(separator: "\n")
    }

    /// Say it again, after anything that changes what it would say — the tooltip if the pointer is
    /// here, and the window's header if this is the card you have stepped into.
    private func describeYourself() {
        board.descriptionChanged(for: node.id)
    }

    /// The age is a fact that changes with nothing happening, so the board's heartbeat is what keeps
    /// whatever is showing it honest.
    override func timePassed() {
        describeYourself()
    }

    // MARK: Stepping in and out

    /// A click on a web card steps *into* it: the page starts taking its own clicks, scrolls and keys,
    /// which is the only way to actually use an embedded page.
    ///
    /// A click, not a double-click, and this is the one card kind that gets that. A web card is a live
    /// thing — a click on it means the thing under the pointer, the way it would in any browser — and
    /// making that take a gesture nobody would guess at is what turned these cards into pictures of
    /// websites. The board still gets first refusal: `stepIn` only runs on a press that didn't move,
    /// so dragging a link card by its middle still drags it. Clicking any other card, clicking the
    /// board, or Escape steps back out.
    override func beginEditing() {
        // Stepping in is an explicit request, so it overrides the zoom threshold — but not the budget,
        // which the board applies next: rule one there is that a card you are using stays live.
        if url != nil, Self.loadsPages { wanted = true }
        engage(true)
        board.reviewPageBudget()
    }

    override var engagesOnClick: Bool { true }

    /// Hand the keyboard to the page on the way in and take it back on the way out.
    ///
    /// Without the second half the page keeps first responder after you have stepped out of it, and
    /// the board's own keys — ⌫ to delete a card, the arrows to nudge one — go on being typed into a
    /// web page that is no longer listening for them.
    override func engagementChanged() {
        if isEngaged {
            if let web { window?.makeFirstResponder(web) }
        } else if let web, (window?.firstResponder as? NSView)?.isDescendant(of: web) == true {
            window?.makeFirstResponder(board)
        }
        board.pageStateChanged()
    }

    override func prepareForRemoval() {
        tearDownPage()
        wanted = false
    }

    // MARK: What the card's menu can do to it

    var canGoBack: Bool { web?.canGoBack ?? false }
    var canGoForward: Bool { web?.canGoForward ?? false }
    /// True once the page has wandered off the address the board saved for this card.
    var hasWandered: Bool { web != nil && url != nil && web?.url != url }

    func goBack() { web?.goBack() }
    func goForward() { web?.goForward() }

    /// Put the card back on its own address.
    ///
    /// The button that matters most, and the one a browser doesn't have. Back walks the history; this
    /// returns the card to the thing it is *for*, and it works where Back cannot — after a sign-on
    /// redirect chain with nothing sensible behind it, or on a card whose page was rebuilt. "I am
    /// somewhere I did not mean to be" is a different question from "what was I looking at before".
    func goHome() {
        guard let url else { return }
        web?.load(URLRequest(url: url))
    }

    /// Make where the page has got to the address this card is *for*.
    ///
    /// The counterpart of Home, and the reason a card is more than a bookmark: you follow a link out of
    /// a dashboard tile, land somewhere you would rather the tile pointed at, and say so. Home takes
    /// you back to the card's address; this makes where you are the card's address.
    ///
    /// **Without rebuilding the page.** Changing a card's content normally tears the web view down and
    /// starts again, which is right when the address is genuinely different and absurd here — the page
    /// being loaded would be the page already on screen, so the only visible effect of doing the honest
    /// thing would be a flash and a lost scroll position. `contentChanged` is suppressed for exactly
    /// the case where the new address is what the view is already showing.
    func adoptCurrentAddress() {
        guard let live = liveURL, live.absoluteString != address else { return }
        setAddress(live.absoluteString)
    }

    /// Point this card somewhere else. Undoable, and named for what the Edit menu should say.
    func setAddress(_ next: String) {
        let trimmed = next.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != address else { return }
        // Set before the store's change lands, because the change comes back through `update(node:)`
        // and then `contentChanged`, which is the teardown this exists to skip.
        alreadyShowing = web?.url?.absoluteString == trimmed
        let id = node.id
        board.store.change("Change Address") { doc in
            guard let index = doc.nodes.firstIndex(where: { $0.id == id }) else { return }
            doc.nodes[index].content = .link(url: trimmed)
        }
    }

    /// Set for the one turn in which a new address is being adopted from the page already on screen.
    /// See `adoptCurrentAddress`.
    private var alreadyShowing = false

    /// Load it again from the top — and if the card had given up, start over from the placeholder.
    func reload() {
        if let web, revealed { web.reload() } else { contentChanged() }
    }

    /// Open the page in the browser — what the card's menu offers, and where a page you actually want
    /// to *use* belongs. A card is a clipping.
    func openInBrowser() {
        guard let url else { return }
        NSWorkspace.shared.open(url)
    }

    /// The site this card shows, for the sign-in item's title.
    var siteName: String { host }

    /// Whether this card's site is being filtered, for the menu's checkmark.
    var isFiltered: Bool { CanvasContentBlocker.filters(host: url?.host() ?? host) }

    /// Turn filtering on or off for this card's site, and show the result immediately.
    func setFiltered(_ on: Bool) {
        CanvasContentBlocker.setFilters(on, host: url?.host() ?? host)
        reapplyFiltering()
    }

    /// Build the page again so it picks up a different set of rule lists.
    ///
    /// A reload would not do it: the lists belong to the configuration, which is fixed once the web
    /// view exists. The interaction state comes across, so the page returns to the scroll position and
    /// the back-forward list it had rather than starting again at the top.
    func reapplyFiltering() {
        guard let running = web else { return }
        resumeURL = running.url ?? url
        resumeState = running.interactionState
        tearDownPage()
        setPageLive(true)
    }

    /// Forget this site, then show what a signed-out card looks like — which is the only honest
    /// confirmation that anything happened.
    func signOut() {
        let site = url?.host() ?? host
        Task { @MainActor in
            await CanvasWebSession.forget(host: site)
            reload()
        }
    }

    /// Sign in to this card's site in a window you can actually use — see `CanvasSignInWindow`.
    func signIn() {
        guard let url else { return }
        CanvasSignInWindow.present(for: url) { [weak self] in
            // Whatever the session picked up is in the shared jar now, so the quickest way to see it
            // is to ask the card for the page again.
            self?.reload()
        }
    }
}

// MARK: - Loading

extension CanvasLinkNodeView: WKNavigationDelegate {
    /// Say what the card is actually showing, as soon as it starts showing it.
    ///
    /// On `didCommit` rather than `didFinish`, because the page is on screen and can be typed into from
    /// the moment it commits — a readout that only caught up once the page had finished loading would
    /// be wrong for exactly the window in which being wrong costs something. That window is the whole
    /// reason the address is shown at all: during a single sign-on you are handed between hosts, and a
    /// password field is only safe to type into if you can see whose it is.
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        describeYourself()
        board.pageStateChanged()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        revealPage()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        failed(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        failed(error)
    }

    /// Fall back to the placeholder, with the reason on it.
    ///
    /// Only if the page was never shown. Once you are reading something, a failed navigation is the
    /// page's business — snatching it away and replacing it with a globe would lose what you had over
    /// a link that didn't resolve.
    private func failed(_ error: Error) {
        let ns = error as NSError
        // A load superseded by another one — including the one `reload()` starts. Not a failure.
        guard !(ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled) else { return }
        giveUp?.cancel()
        giveUp = nil
        guard !revealed else { return }
        tearDownPage()
        placeholder?.isHidden = false
        say("Couldn't load", tooltip: ns.localizedDescription)
    }
}

// MARK: - Navigating

extension CanvasLinkNodeView: WKUIDelegate {
    /// A link that asks for a new window gets this one.
    ///
    /// Without it those links do nothing at all: `target="_blank"` and `window.open` route through
    /// here, and a web view with no UI delegate drops the navigation on the floor. On a real site that
    /// is a large share of the links on the page, and a card where half the links are dead reads as a
    /// picture of a website rather than a website.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url { webView.load(URLRequest(url: url)) }
        return nil
    }
}
