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
/// itself in its own chrome is said somewhere that costs the page nothing: the host and the age to
/// VoiceOver, and — for the one card you have stepped into, which is the only card whose address can
/// cost you anything — the live address in the window's own header, beside the controls that drive it.
/// See `cardDescription` and `CanvasHeaderModel`.
@MainActor
final class CanvasLinkNodeView: CanvasNodeView {
    /// The card's body. Holds the placeholder always, and the page over it once there is one.
    private let face = NSView()
    private var web: WKWebView?
    private var placeholder: NSView?
    /// The picture of the page that stands in for it while it is paused. See `freeze`.
    private var frozen: CanvasFrozenPageView?
    /// The placeholder's two lines of identity: what the page calls itself, and whose page it is. The
    /// second is hidden until there is a name above it to tell it apart from.
    private var nameLabel: NSTextField?
    private var siteLabel: NSTextField?
    /// The line under the host: what the card is doing, or why it isn't doing it.
    private var status: NSTextField?
    /// Told when the page renames itself. See `titleChanged`.
    private var titleWatch: NSKeyValueObservation?
    /// Told as the load advances, for the header's progress hairline. See `watchTitle`.
    private var progressWatch: NSKeyValueObservation?
    /// Whether a title arriving now is a name for *this card's* address.
    ///
    /// True from the moment the card sends the page to its own address, and false again as soon as you
    /// navigate — a page you followed a link to is not what the card is for, and naming the card after
    /// it would mean a board that renames its own cards while you read from them. A redirect chain the
    /// card started is still the card's own navigation and keeps the flag; see `decidePolicyFor`,
    /// which exists to tell those two apart.
    private var capturingTitle = false
    /// The file a ⌥-drop is sending the page to, so `decidePolicyFor` lets that one navigation through
    /// while still refusing the file URLs a page reaches on its own.
    private var droppedFile: URL?
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
    ///
    /// **Kept for the card, not for this view** — see `CanvasPageHandover`. The canvas and a workspace
    /// each have a view of the card, and a page paused in one should wake in the other where you left
    /// it.
    private var resumeState: Any? {
        get { CanvasPageHandover.resumes[pageKey]?.state }
        set { CanvasPageHandover.resumes[pageKey, default: .init()].state = newValue }
    }
    /// Where the page had got to, which outlives the session the state does not — see
    /// `CanvasPageVisits`. The paused page's own answer first, because it is the newer of the two.
    private var resumeURL: URL? {
        get { CanvasPageHandover.resumes[pageKey]?.url ?? CanvasPageVisits.of(pageKey) }
        set { CanvasPageHandover.resumes[pageKey, default: .init()].url = newValue }
    }
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
    /// When the load now running started, or nil when nothing is. Only the chrome reads it — see
    /// `showsLoad`.
    private var loadingSince: Date?
    /// Asking, every so often, whether the page has painted — see `probeForPaint`. Alive only between
    /// the page committing and the card being revealed, which is a second or two at most.
    private var paintProbe: Timer?
    /// One snapshot in flight at a time, since a probe that takes longer than the interval would
    /// otherwise queue more of itself behind it.
    private var probing = false

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
        // What this card was last showing, from this session or the last one. A board opened cold used
        // to come up as a screen of globes and fill in over the next several seconds as the budget
        // woke the cards one at a time — which is the moment a board most needs to say what it is, and
        // was the moment it said least.
        showStoredPicture()
        Self.cards.add(self)
        reconsiderLoading(scale: scale)
        // A card built into a board you have just switched to — a tile the workspace had not needed
        // until now — comes up showing the page the tab behind was running, not a globe.
        reclaimPage()
        // A popup moved onto the board: its page is running already, and is this card's from the start.
        if web == nil, let parked = CanvasPageHandover.parked.removeValue(forKey: pageKey) {
            cameFromPopup = true
            adopt(Handover(web: parked, revealed: true, loadedAt: Date(), capturingTitle: false))
        }
    }

    // MARK: Out in a window of its own

    /// The window this card's page is lent to, while it is. See `CanvasSatelliteWindow`.
    private(set) weak var satellite: CanvasSatelliteWindow?

    override var isHeldElsewhere: Bool { satellite != nil }

    /// Lend the page to a window of its own, starting it first if it isn't running.
    func moveToSatellite(frame: NSRect?) {
        guard satellite == nil else { return }
        if web == nil, let target = resumeURL ?? url { showPage(target) }
        guard let page = web else { return }
        if (window?.firstResponder as? NSView)?.isDescendant(of: page) == true { window?.makeFirstResponder(board) }
        page.removeFromSuperview()
        placeholder?.isHidden = false
        say("In its own window")
        let window = CanvasSatelliteWindow(card: self, page: page, frame: frame)
        satellite = window
        window.show()
        board.pageStateChanged()
    }

    /// Take the page back from its window. Home to the workspace when you sent it there; left out of the
    /// tiling when the workspace is only being put away, since it will be lent out again when it's back.
    func returnFromSatellite(toWorkspace: Bool) {
        satellite = nil
        say(nil)
        if let page = web {
            fill(face, with: page, below: frozen ?? placeholder)
            if revealed { uncover() }
        }
        board.pageStateChanged()
        if toWorkspace { board.satelliteReturned(node.id) }
    }

    /// Whether this card's page is a popup that was moved onto the board, which is still connected to
    /// the page that opened it. When it closes itself — a call ending, a huddle left — the card goes
    /// with it, as the popup would have. Not kept across launches: by then it's an ordinary page.
    private var cameFromPopup = false

    /// Move a popup this card's page opened onto the board, still running — see `CanvasWebPopup`.
    func openPopupAsCard(_ page: WKWebView) {
        board.addLinkCard(page.url?.absoluteString ?? address, beside: node.id, joined: false,
                          profile: profile, adopting: page)
    }

    /// `window.close()` from a page that was a popup. Anything else asking is ignored, as a browser tab
    /// ignores a page it didn't open.
    func webViewDidClose(_ webView: WKWebView) {
        guard cameFromPopup, webView === web else { return }
        let id = node.id
        Task { @MainActor [board] in
            board.store.change("Close Popup") { doc in
                doc.nodes.removeAll { $0.id == id }
                doc.edges.removeAll { $0.fromNode == id || $0.toNode == id }
            }
        }
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

    /// What the page at this card's address calls itself, if it has ever been loaded — here or on any
    /// other board. See `CanvasPageTitles`.
    var savedTitle: String? { CanvasPageTitles.of(address) }

    /// The name of whatever is actually on screen.
    ///
    /// The running page's own title first, and deliberately: a card you have followed a link out of is
    /// showing something else, and what a name owes you is the thing in front of you rather than the
    /// thing the board meant to put there. The remembered one is the
    /// answer for every card that isn't running, which is most of them — and for a paused card, the
    /// name of the page it paused on, which is the page its picture shows.
    var liveTitle: String? {
        if let title = web?.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty,
           let live = liveURL?.absoluteString, CanvasPageTitles.adds(title, to: live) {
            return title
        }
        if web == nil, let paused = resumeURL?.absoluteString, let title = CanvasPageTitles.of(paused) {
            return title
        }
        return savedTitle
    }

    /// The browser session this card uses, or nil for the one every card shares.
    var profile: String? { CanvasCardSession.of(node) }

    /// Whether this card's page may start playing by itself, and whether it may be heard.
    var autoplays: Bool { CanvasCardMedia.autoplays(node) }
    var isMuted: Bool { CanvasCardMedia.isMuted(node) }

    override func update(node: CanvasNode, scale: Double) {
        // Changing which jar a card drinks from is a different page in every sense that matters —
        // signed in as somebody else, or signed in at all — and it lives in `extra`, where the base
        // class has no reason to look. Nothing else would notice it.
        let rejarred = CanvasCardSession.of(node) != profile
        // Mute is the one card setting you reach for *while the page is doing the thing* — a video is
        // playing and you would rather it wasn't — so it is deliberately not in the list above. It is
        // thrown on the running page instead of rebuilding it, which is the difference between muting
        // what you are watching and losing it. Autoplay needs nothing at all here: it governs whether a
        // page may start by itself, which is only asked as a page loads, so it lands next time this one
        // does. See `CanvasCardMedia`.
        let quieted = CanvasCardMedia.isMuted(node) != isMuted
        // A changed address *is* a changed content, so the base already rebuilds through
        // `contentChanged`. Doing it again here — which is what this used to do — started the page,
        // tore it down and started it a second time.
        super.update(node: node, scale: scale)
        if rejarred { contentChanged() } else if quieted { applyMuting() }
        // The zoom, on the other hand, reaches us nowhere else: `simplificationChanged` is deliberately
        // a no-op for a web card, so this is the line that notices you have zoomed in far enough.
        reconsiderLoading(scale: scale)
    }

    /// A web card keeps its own threshold, so the board crossing the *text* one is not its business.
    /// Rebuilding here would tear down a page you are looking at and load it again, which is a reload
    /// triggered by a scroll wheel.
    override func simplificationChanged() {}

    override func contentChanged() {
        // Undoing a Pin puts back the address it replaced, and redoing it puts the Pin's back — both
        // while the pinned page is still on screen. Neither is a different page, so neither rebuilds
        // one: the card is simply off its address again, or on it again. See `pinned`.
        if let pinned, [pinned.home, pinned.page].contains(address),
           web?.url?.absoluteString == pinned.page {
            alreadyShowing = true
        }
        // A different address makes where the old one had wandered to meaningless — and the address
        // being adopted from the page on screen means the card is no longer off its address at all.
        // Both are true before the branch below, so this is above it.
        CanvasPageVisits.forget(pageKey)
        // The picture, on the other hand, is only wrong when the address really did change: a card
        // adopting the address of the page it is already showing is showing the right picture.
        if !alreadyShowing { CanvasPageSnapshots.forget(pageKey) }
        // The address changed to the page this card is already displaying — see `adoptCurrentAddress`.
        // Nothing to rebuild; the card is already right, and rebuilding it would be the only thing the
        // user could see going wrong.
        if alreadyShowing {
            alreadyShowing = false
            // On its address now or off it again (an undone Pin): written down either way, since
            // quitting freezes nothing and the next launch should find the card where it is.
            noteVisit()
            refreshName()
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

    /// Ask again at the zoom the board is actually at — for when the answer changed underneath the
    /// card rather than because of it, which is what flipping the web-cards switch in Settings is.
    override func reconsiderLoading() { reconsiderLoading(scale: board.liveScale) }

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
            guard web == nil, Self.loadsPages else { return }
            let holder = holder
            switch CanvasPageHandover.decide(inSight: boardInSight,
                                             holder: holder.map { $0.boardInSight ? .inSight : .outOfSight }) {
            case .adopt: if let holder { adopt(from: holder) }
            case .start: if let target = resumeURL ?? url { showPage(target) }
            case .wait: break
            }
        } else {
            freeze()
        }
    }

    // MARK: One page, whichever board is showing it

    /// Every web card alive, for finding this card on the other boards showing it. Weak, so a card
    /// thrown away leaves without having to say so.
    private static let cards = NSHashTable<CanvasLinkNodeView>.weakObjects()

    /// This card, on any board. See `CanvasPageHandover`.
    private var pageKey: String { CanvasPageHandover.key(canvas: board.store.url, card: node.id) }

    /// Whether this card's board is somewhere you can see it: in a window, and not in a tab behind
    /// another one. A card the board itself has hidden under a tiling still counts — it is that board's
    /// to wake and freeze, which is what `CanvasPageBudget.liveWhileTiled` is for.
    private var boardInSight: Bool { board.window != nil && !board.isHiddenOrHasHiddenAncestor }

    /// The same card on another board, if it has the page running.
    ///
    /// The address and the jar as well as the id, though the boards share one document: a page is only
    /// the same page if it was loaded from the same place, as the same person. The live page is checked
    /// first, which is also what keeps this from reaching a board through a card that has outlived it.
    private var holder: CanvasLinkNodeView? {
        Self.cards.allObjects.first {
            $0 !== self && $0.web != nil && $0.pageKey == pageKey
                && $0.address == address && $0.profile == profile
        }
    }

    /// Take this card's page from the tab you have just left, if that tab has it — without asking the
    /// budget.
    ///
    /// Called as a board comes forward and as a card is built, which is what lets a tile fly in already
    /// showing its page rather than a globe that turns into one a second after the crossing lands. It
    /// can skip the budget because it adds nothing: the renderer exists already, and this only changes
    /// which board draws it. The budget has its say on the next pass, as it does for every page.
    /// Never *starts* one — that is the budget's decision.
    override func reclaimPage() {
        guard wanted, web == nil, boardInSight, let holder, !holder.boardInSight else { return }
        adopt(from: holder)
    }

    /// What a card hands over with its page: the page, and what the card knew about it.
    private struct Handover {
        let web: WKWebView
        let revealed: Bool
        let loadedAt: Date?
        let capturingTitle: Bool
    }

    /// Move `donor`'s running page into this card, exactly as it is.
    private func adopt(from donor: CanvasLinkNodeView) {
        guard let handover = donor.giveUpPage() else { return }
        adopt(handover)
    }

    /// Put a running page in this card, exactly as it is.
    private func adopt(_ handover: Handover) {
        // The page is running, so there is nothing to resume — and a state left behind would be what
        // the next card to start this page from scratch went back to, older than where it is now.
        resumeState = nil
        resumeURL = nil
        let view = handover.web
        view.navigationDelegate = self
        view.uiDelegate = self
        (view as? CanvasPageView)?.dropFallback = board
        (view as? CanvasPageView)?.linkHost = self
        web = view
        capturingTitle = handover.capturingTitle
        watchTitle(of: view)
        applyContentZoom()
        refilterWhenReady(view)
        fill(face, with: view, below: frozen ?? placeholder)
        if handover.revealed {
            // Shown already, so shown now: no cross-fade and no Loading… over a page that has loaded,
            // and the freshness is the page's, not the moment it changed boards.
            revealed = true
            loadedAt = handover.loadedAt
            uncover()
            describeYourself()
        } else {
            if frozen == nil { say("Loading…") }
            waitForIt()
        }
        if isEngaged {
            window?.makeFirstResponder(view)
        } else if (window?.firstResponder as? NSView)?.isDescendant(of: view) == true {
            // You were typing into it on the board you left. Here you have not stepped in yet.
            window?.makeFirstResponder(board)
        }
        board.pageStateChanged()
    }

    /// Give this card's running page to another board's copy of the card, and keep a picture of it.
    ///
    /// Not `tearDownPage`, which stops the page: the whole point is that it goes on exactly as it was.
    /// The delegates are left for the new owner to replace in the same turn, so nothing the page reports
    /// in between is lost. The picture is `freeze`'s, for `freeze`'s reason — this card is out of sight,
    /// and if you come back to it zoomed out too far to run pages it should still say what it showed.
    private func giveUpPage() -> Handover? {
        // Not while it is out in a window: the window is showing it, and the page is still this card's.
        guard let running = web, satellite == nil else { return nil }
        let handover = Handover(web: running, revealed: revealed, loadedAt: loadedAt,
                                capturingTitle: capturingTitle)
        // The page goes on running on the other board, which will record its own navigations from here
        // — but this is the last moment *this* card can say where it was, and a handover at quitting
        // time is the one that never gets a next navigation.
        noteVisit()
        if revealed {
            let configuration = WKSnapshotConfiguration()
            configuration.afterScreenUpdates = false
            running.takeSnapshot(with: configuration) { [weak self] image, _ in
                guard let self, let image, web == nil else { return }
                showFrozen(image)
                placeholder?.isHidden = true
            }
        }
        giveUp?.cancel()
        giveUp = nil
        titleWatch?.invalidate()
        titleWatch = nil
        progressWatch?.invalidate()
        progressWatch = nil
        capturingTitle = false
        // A pause in flight is abandoned: its snapshot finds the page gone and stops there.
        freezing = false
        running.removeFromSuperview()
        web = nil
        revealed = false
        placeholder?.isHidden = false
        board.pageStateChanged()
        return handover
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
        // Not while it is full screen: the view is in WebKit's window, not this card, and a paused video
        // there is still what you are looking at.
        guard let web, !freezing, web.fullscreenState == .notInFullscreen, satellite == nil else { return }
        freezing = true
        giveUp?.cancel()
        giveUp = nil
        resumeState = web.interactionState
        resumeURL = web.url ?? resumeURL ?? url
        noteVisit()
        snapshotThenStop(web)
    }

    /// Write down where the page has got to, so the card comes back here after a relaunch rather than
    /// at the address the board has for it. See `CanvasPageVisits`.
    ///
    /// Asked as a navigation commits and as the card is paused, which between them cover every way a
    /// page moves and every way a card stops: quitting the app freezes nothing, and `prepareForRemoval`
    /// tears a card down without asking the page anything, so a capture that only ran on the way out
    /// would run exactly never in the case this exists for. A page that rewrites its own URL in script
    /// without navigating is not recorded until one of the two happens, which is the same blind spot
    /// `capturingTitle` has and for the same reason.
    ///
    /// **A card on its own address is forgotten rather than recorded.** The board already says where
    /// that is, so a row for it would be a second copy of a fact that can change underneath it — and it
    /// is what makes Home a real erasure rather than a thing the next launch undoes.
    private func noteVisit() {
        guard let live = web?.url else { return }
        if live == url {
            CanvasPageVisits.forget(pageKey)
        } else {
            CanvasPageVisits.remember(live, for: pageKey)
        }
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

    /// Put a picture of the page up, and keep it for the card as well as for this view.
    ///
    /// **Kept for the card**, which is the same move `CanvasPageHandover` made for the page and
    /// `CanvasPageVisits` made for the address, and for the same reason: a view is the shortest-lived
    /// thing here. See `CanvasPageSnapshots`.
    private func showFrozen(_ image: NSImage) {
        CanvasPageSnapshots.keep(image, for: pageKey, tiled: board.isTiled)
        showPicture(image)
        pictureIsTiled = board.isTiled
    }

    /// Whether the picture up was taken as a tile — nil when there isn't one — so crossing between the
    /// board and a workspace can swap it for the picture of the shape the card is now. See
    /// `CanvasPageSnapshots` on why a card has two.
    private var pictureIsTiled: Bool?

    /// The stored picture for the shape the card is now, or the placeholder when there is none.
    private func showStoredPicture() {
        pictureIsTiled = board.isTiled
        if let picture = CanvasPageSnapshots.of(pageKey, tiled: board.isTiled) {
            showPicture(picture)
            placeholder?.isHidden = true
        } else {
            frozen?.removeFromSuperview()
            frozen = nil
            placeholder?.isHidden = false
        }
    }

    /// The board crossed between its modes. A card not showing its page is showing a picture of one,
    /// and a picture of the other shape is swapped for this one's — cheap to ask on every frame of the
    /// crossing, since it only does anything on the frame the mode actually flips.
    override func refreshTiledness(fading: Bool) {
        super.refreshTiledness(fading: fading)
        guard !revealed, pictureIsTiled != board.isTiled else { return }
        showStoredPicture()
    }

    /// Put a picture up without filing it — for one that came out of the store in the first place.
    private func showPicture(_ image: NSImage) {
        frozen?.removeFromSuperview()
        let view = CanvasFrozenPageView()
        view.image = image
        view.setAccessibilityLabel(host)
        frozen = view
        fill(face, with: view, below: placeholder)
    }

    // MARK: The card, and the page over it

    /// The placeholder's view: it takes no clicks while a page is under it.
    ///
    /// It stays over a running page until the reveal — through the load, and through the fade out — and
    /// it is transparent apart from the globe and the name, so the page shows through while every click
    /// on it landed here. Right after a tab switch that was up to eight seconds of a page you could see
    /// and not use. With no page under it (a card that is off, or whose load failed) it takes the
    /// pointer as any view does, which is what keeps the "Couldn't load" tooltip.
    private final class Placeholder: NSView {
        var coversAPage: () -> Bool = { false }
        override func hitTest(_ point: NSPoint) -> NSView? {
            coversAPage() ? nil : super.hitTest(point)
        }
    }

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

        // What the page calls itself, over whose page it is. A card that has never loaded has only the
        // host, and then the host is the name — one line rather than a name-shaped gap above it.
        let name = NSTextField(labelWithString: savedTitle ?? host)
        name.font = .systemFont(ofSize: 13, weight: .medium)
        name.alignment = .center
        name.maximumNumberOfLines = 2
        name.lineBreakMode = .byTruncatingTail
        name.cell?.truncatesLastVisibleLine = true
        nameLabel = name

        let site = NSTextField(labelWithString: host)
        site.font = .systemFont(ofSize: 11)
        site.textColor = .secondaryLabelColor
        site.alignment = .center
        site.lineBreakMode = .byTruncatingTail
        site.isHidden = savedTitle == nil
        siteLabel = site

        let note = NSTextField(labelWithString: "")
        note.font = .systemFont(ofSize: 10.5)
        note.textColor = .tertiaryLabelColor
        note.alignment = .center
        note.lineBreakMode = .byTruncatingTail
        note.isHidden = true
        status = note

        stack.addArrangedSubview(icon)
        stack.addArrangedSubview(name)
        stack.addArrangedSubview(site)
        stack.addArrangedSubview(note)
        // The name and the host are one fact in two lines; the status is a different one. Tightened
        // between the first two so they read as a pair rather than as three evenly spaced things.
        stack.setCustomSpacing(2, after: name)

        let container = Placeholder()
        container.coversAPage = { [weak self] in self?.web != nil }
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

    /// The card this zoom was built for. A page set at 11px is unreadable at any board zoom, because
    /// the board scales the card's frame along with its text — and in a tiled view the frame is not
    /// yours to change at all. See `CanvasCardZoom`.
    override var zoomsItsContent: Bool { true }

    override var scrollsItsContent: Bool { true }

    /// The page itself. A `WKWebView` is not built out of an `NSScrollView` — the scrolling happens in
    /// the web process — so the generic search would find nothing here, and the view that has to be
    /// handed the wheel is the web view.
    ///
    /// Nil while the card is frozen, which is the honest answer: there is no page to scroll, only a
    /// picture of one. The wheel goes back to the board, and the card wakes on its own terms — see
    /// `setPageLive`.
    override var contentScroller: NSView? {
        guard scrollsItsContent, !isSimplified else { return nil }
        return web
    }

    override func contentZoomChanged() { applyContentZoom() }

    /// WebKit's own page zoom, which is what a browser's ⌘+ does: the page relays out at the new size
    /// rather than being scaled as a picture, so text stays sharp and a column still fits the card.
    private func applyContentZoom() { web?.pageZoom = contentZoom }

    // MARK: What is injected into the page

    /// Everything this card asks WebKit to run inside the page, in one place.
    ///
    /// One call rather than two at the point of use, because a user script cannot be taken back out of
    /// a page once it is there and `removeAllUserScripts` is the only eraser WebKit has — so changing
    /// any of them means putting all of them back. Keeping the set in a single function is what makes
    /// that safe to do; adding a script anywhere else would silently lose it at the next toggle.
    private func installScripts(in configuration: WKWebViewConfiguration, for host: String?) {
        CanvasAdvancedRules.attach(to: configuration, for: host)
        CanvasCardMedia.installScript(muted: isMuted, to: configuration)
    }

    /// Mute or unmute the page that is already on screen, and set the switch for the pages after it.
    ///
    /// Two halves because the two questions are answered in different places. The running page — every
    /// frame of it, including the cross-origin iframe a YouTube card actually consists of — is reached
    /// through the switch already inside it. A page loaded later gets the setting at document start
    /// from a fresh user script, which is why the scripts are reinstalled here: without that, following
    /// a link inside a card you had muted would bring the sound back.
    private func applyMuting() {
        guard let web else { return }
        reinstallScripts()
        CanvasCardMedia.tell(web, muted: isMuted)
    }

    private func reinstallScripts() {
        guard let web else { return }
        web.configuration.userContentController.removeAllUserScripts()
        installScripts(in: web.configuration, for: (web.url ?? url)?.host())
    }

    // MARK: What the page calls itself

    /// Watch the page's name, which arrives after the page does and can change again without a
    /// navigation.
    ///
    /// KVO rather than reading `title` when the load finishes, which is the obvious version and is
    /// wrong for exactly the pages a dashboard is made of: at the moment an app-shell page finishes
    /// loading it is still called "Loading…", or called nothing at all, and its real name lands a beat
    /// later when the script that fetches the ticket has run.
    private func watchTitle(of view: WKWebView) {
        titleWatch = view.observe(\.title, options: [.initial, .new]) { [weak self] view, _ in
            MainActor.assumeIsolated { self?.titleChanged(view.title) }
        }
        // And how far the load has got, for the hairline under the header's address field. The
        // delegate cannot say this: `didStartProvisionalNavigation` and `didFinish` are the two ends
        // and there is nothing in between but this property.
        //
        // Cheap because `loadProgress` rounds to twentieths — the header's `Page` is `Equatable`, so
        // a value that hasn't moved a step costs one comparison and no redraw at all.
        progressWatch = view.observe(\.estimatedProgress) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.board.pageStateChanged() }
        }
    }

    /// The page named itself. Keep it if it is this card's own page, and say it wherever it shows.
    ///
    /// **Kept under wherever the page is, every time**, as well as under the card's address while it is
    /// capturing. Capturing stops the moment you step in, which is the moment a page like Slack starts
    /// being used — so a card's remembered name used to be whatever it was called when you last stepped
    /// into it: "* Someone (DM)" long after the message had been read. The page's own address is the
    /// one key a title can't be wrong about, and when that address is the card's, this is the card's
    /// name kept current; when it isn't, it is the name a paused card's picture shows (`liveTitle`).
    private func titleChanged(_ title: String?) {
        guard let title, !title.isEmpty else { return }
        if capturingTitle { CanvasPageTitles.remember(title, for: address) }
        if let live = web?.url?.absoluteString, !capturingTitle || live != address {
            CanvasPageTitles.remember(title, for: live)
        }
        refreshName()
        describeYourself()
    }

    /// Put the card's name on the placeholder, after it has arrived or changed.
    ///
    /// The placeholder is nearly always behind a loaded page by the time this runs, and is kept right
    /// anyway: it is what the card comes back to when the page is frozen without a snapshot, when a
    /// load fails, and when the board is zoomed out past the point of running pages at all. A name that
    /// only reached cards which happened to be nameless at the moment they loaded would be missing from
    /// the cards that have been used most.
    private func refreshName() {
        let name = savedTitle
        nameLabel?.stringValue = name ?? host
        siteLabel?.isHidden = name == nil
    }

    private func say(_ text: String?, tooltip: String? = nil) {
        status?.stringValue = text ?? ""
        status?.isHidden = text == nil
        status?.toolTip = tooltip
    }

    private func showPage(_ url: URL) {
        let configuration = WKWebViewConfiguration()
        // Every card, on every board, and the sign-in window too — unless this card has been put on a
        // profile of its own, which is how one board holds two accounts. See `CanvasCardSession`.
        configuration.websiteDataStore = CanvasWebSession.store(named: profile)
        // Name ourselves as the Safari we are, or the sites that read the user agent send us to their
        // unsupported-browser page. See `CanvasWebSession.applicationName`.
        CanvasWebSession.identify(configuration)
        // Ads, trackers and cookie banners. A rule list can only be handed to a web view as that view
        // is built, which is also why excusing a site rebuilds the page rather than reloading it.
        CanvasContentBlocker.attach(to: configuration, for: url.host())
        // A card is a clipping, not a browser: it shouldn't be able to *spontaneously* open windows.
        // A link you click is a different matter — see `createWebViewWith` below, which is what makes
        // a `target="_blank"` link navigate instead of silently doing nothing.
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        // A video's full-screen button. Off by default in a `WKWebView`, which left the button there and
        // doing nothing. WebKit lifts the view into a full-screen window of its own and puts it back in
        // the card afterwards; a playing page is never frozen (`CanvasPageBudget`), and `freeze` waits
        // out a paused one.
        configuration.preferences.isElementFullscreenEnabled = true
        // The rules interpreter, and the mute switch. Both are user scripts, and both go in through the
        // one call that knows the whole set — because changing the mute setting later means replacing
        // the lot. See `reinstallScripts`.
        installScripts(in: configuration, for: url.host())
        // Nothing plays because you looked at it, unless this card says otherwise. Decided here because
        // it is a property of the configuration rather than of the page — which is also why turning it
        // on doesn't start anything: it is the policy the *next* page will load under.
        configuration.mediaTypesRequiringUserActionForPlayback = autoplays ? [] : .all
        // **Incremental rendering is left on, and it is load-bearing.** It used to be suppressed, to
        // spare the card a half-painted frame at the moment of the reveal — cheap then, because the
        // reveal was at `didFinish` and the page was finished by definition. The card now reveals as
        // soon as the page has *painted* (see `startProbingForPaint`), and suppression makes that
        // impossible rather than merely unnecessary: the property means what it says, fully loaded, so
        // a suppressed view paints nothing at all until the load ends and there is nothing to notice.
        // Measured against an app shell holding a request open for three seconds — suppressed, every
        // probe was blank and the page arrived at `didFinish`; allowed, the first probe after the shell
        // painted saw it, 2.7s earlier.
        //
        // The frame that suppression was protecting is now covered by the two things that replaced it:
        // the probe only fires on a view with something actually drawn on it, and the placeholder
        // cross-fades out over that rather than cutting.
        configuration.suppressesIncrementalRendering = false

        let view = CanvasPageView(frame: .zero, configuration: configuration)
        // A link dropped on the page makes a card, unless there is a field under it to type into.
        view.dropFallback = board
        // And a link right-clicked or middle-clicked can make one too.
        view.linkHost = self
        // Safari unless this site has been told otherwise; the configuration above already says Safari.
        CanvasWebSession.identify(view, host: url.host())
        CanvasWebSession.allowInspecting(view)
        view.navigationDelegate = self
        view.uiDelegate = self
        // Left off deliberately: a two-finger swipe inside an engaged card would be a horizontal
        // scroll on most pages and a "go back" on the rest. Back is on the card's menu instead, where
        // it can't be triggered by accident.
        view.allowsBackForwardNavigationGestures = false
        // Left on deliberately, and it is the `drawsBackground` line that used to be here. A page is
        // only obliged to paint a background if it wants one other than the browser's; plenty of real
        // pages set none and rely on the default. Through a transparent web view "no background" means
        // the card's own surface, which in dark appearance is near-black under black text — the page
        // renders perfectly and is unreadable. Letting the view draw its own background hands that
        // decision back to WebKit, which is the only party that knows which default the page presumes:
        // white for a page that never mentions `color-scheme`, WebKit's dark canvas for one that opts
        // in. Nothing flashes, because the placeholder is over the page until `revealPage`.
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
        // A page sent to the card's own address is a page whose name is the card's name. One that has
        // been restored to wherever you had navigated to before the card was frozen is not.
        capturingTitle = url == self.url
        watchTitle(of: view)
        applyContentZoom()
        refilterWhenReady(view)

        // Under whatever is standing in for the page — the picture from the last time it ran, or the
        // placeholder. Waking up should not flash anything.
        fill(face, with: view, below: frozen ?? placeholder)
        if isEngaged { window?.makeFirstResponder(view) }
        if frozen == nil { say("Loading…") }
        waitForIt()
    }

    /// The lists take about ten seconds to compile on the first launch after an update, and a canvas
    /// restored at startup can open well inside that window. A card built before they were ready gets
    /// one chance to notice and start again, rather than staying unfiltered until something else
    /// happens to reload it. Asked again by a card that adopts a page, since the chance belongs to
    /// whichever card holds the page when the lists arrive.
    private func refilterWhenReady(_ view: WKWebView) {
        guard !CanvasContentBlocker.isReady else { return }
        CanvasContentBlocker.onReady { [weak self, weak view] in
            guard let self, let view, web === view else { return }
            reapplyFiltering()
        }
    }

    /// **Show the page when it has something on it, rather than when it has stopped loading.**
    ///
    /// `didFinish` is the honest signal that a page is *ready*, and on the pages a board is mostly
    /// made of it is far too late: an app shell paints its bar, its nav and its first screenful and
    /// then goes on fetching for several seconds, all of which the card spent behind a globe or a
    /// stale picture of itself. The complaint was never that the reveal was wrong — it was that it
    /// was waiting for the wrong event.
    ///
    /// The right event is WebKit's first visually-non-empty layout, which is private. Its effect is
    /// not: a snapshot of a view that has not painted comes back as one flat colour, and one of a view
    /// that has comes back as a page. So the card takes a very small snapshot every so often and asks
    /// `CanvasPagePaint` whether there is a page on it — a poll standing in for the notification,
    /// reading the same fact off the other side of it. This is also why the view no longer suppresses
    /// incremental rendering; that argument is where the property is set.
    ///
    /// **Both of the old signals stay**, because this one can be wrong in one direction: a page whose
    /// first paint is genuinely uniform — a dark canvas with a spinner, an error page — never trips
    /// it, and falls through to `didFinish` and then to the eight seconds, which is exactly the
    /// behaviour it had before. Nothing is lost by the probe failing; something is gained every time
    /// it doesn't.
    ///
    /// Every 200ms, from `didCommit` — before which there is nothing to photograph — and stopped by the
    /// reveal, the teardown, or a failure. Two or three snapshots is the usual cost of a load: against
    /// a real app shell the paint landed about 300ms after the commit. 48 points wide, which is a
    /// render WebKit does in a fraction of a millisecond and enough pixels to tell a bar and a spinner
    /// from a blank ground.
    private func startProbingForPaint() {
        paintProbe?.invalidate()
        guard !revealed, web != nil else { return paintProbe = nil }
        let probe = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.probeForPaint() }
        }
        // The common modes, so a card goes on deciding it is ready while the board is being scrolled
        // or a menu is down. A page that painted during a gesture and was revealed after it would be
        // the same late reveal in a smaller window.
        RunLoop.main.add(probe, forMode: .common)
        paintProbe = probe
    }

    private func stopProbingForPaint() {
        paintProbe?.invalidate()
        paintProbe = nil
    }

    private func probeForPaint() {
        guard !revealed, !probing, let web, web.bounds.width > 1, web.bounds.height > 1 else { return }
        probing = true
        let wanted = WKSnapshotConfiguration()
        wanted.snapshotWidth = 48
        // The card, not the page: a tall page snapshotted whole would be mostly the part you cannot
        // see, and what is being asked is whether there is anything to look at *now*.
        wanted.rect = web.bounds
        web.takeSnapshot(with: wanted) { [weak self] image, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.probing = false
                guard !self.revealed, let image, CanvasPagePaint.hasSomethingOnIt(image) else { return }
                self.revealPage()
            }
        }
    }

    /// A page that never finishes is shown anyway after a while.
    ///
    /// `didFinish` is the honest signal that a page is ready, but plenty of real pages hold a request
    /// open forever — a socket, a poll, an ad that never settles — and would sit behind the
    /// placeholder for good while being perfectly readable underneath it. After eight seconds, take
    /// whatever has painted.
    ///
    /// Still the backstop rather than the answer: `startProbingForPaint` usually gets there first now,
    /// and this is what is left for a page whose first paint is one flat colour.
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
        stopProbingForPaint()
        guard web != nil else { return }
        let first = !revealed
        revealed = true
        loadedAt = Date()
        describeYourself()

        let going = [placeholder, frozen].compactMap { $0 }
        if first, !going.isEmpty {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Motion.duration(Self.revealDuration)
                context.allowsImplicitAnimation = true
                for view in going { view.animator().alphaValue = 0 }
            } completionHandler: { [weak self] in self?.uncover() }
        } else {
            uncover()
        }
        board.pageStateChanged()
    }

    /// Take the placeholder and the picture out from over the page.
    ///
    /// Hidden rather than removed, because the placeholder is the card's fallback: a page that later
    /// fails, or a card that is frozen and woken, comes back through it. Its alpha is put back at the
    /// same time, or it would come back invisible.
    private func uncover() {
        placeholder?.isHidden = true
        placeholder?.alphaValue = 1
        frozen?.removeFromSuperview()
        frozen = nil
    }

    private func tearDownPage() {
        // A page that is ending takes its window with it, and the tile goes home: an empty window, or
        // one left showing a page the card has let go of, would be a window that means nothing.
        if let satellite { satellite.pageEnded() }
        giveUp?.cancel()
        giveUp = nil
        stopProbingForPaint()
        // Before the view goes: an observation outliving what it observes is the one way this can
        // crash, and a page being torn down is about to report a title of nothing.
        titleWatch?.invalidate()
        titleWatch = nil
        progressWatch?.invalidate()
        progressWatch = nil
        capturingTitle = false
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

    /// What this card would say about itself if asked.
    ///
    /// This is where the caption strip went, and the freshness capsule with it. Both were chrome drawn
    /// on the card — one above the page, one over it — and both were saying things worth knowing
    /// occasionally and not worth looking at continuously. A board of eleven web cards carried eleven
    /// captions and eleven capsules permanently on screen so that you could, once in a while, want one
    /// of them.
    ///
    /// For a while a tooltip carried it, and no longer: hovering is how you get *past* a card as much
    /// as how you attend to one, so the sentence arrived over cards nobody had asked about. It is now
    /// said in the two places where it was asked for — the header, for the card you have stepped into,
    /// and VoiceOver. See `CanvasNodeView.cardDescription`.
    override var cardDescription: String? {
        // The name first and the host under it, which is the order the placeholder puts them in and the
        // order the question is actually asked: what is this, then whose is it. A card whose page has
        // never loaded anywhere has only the second half, and says only that.
        var lines: [String] = []
        if let liveTitle { lines.append(liveTitle) }
        lines.append(liveHost)
        if let loadedAt { lines.append(canvasFreshnessLabel(for: loadedAt)) }
        if hasWandered { lines.append("Not the address saved on this board \u{2014} " + address) }
        return lines.joined(separator: "\n")
    }

    /// Say it again, after anything that changes what it would say — the window's header, if this is
    /// the card you have stepped into.
    private func describeYourself() {
        board.descriptionChanged(for: node.id)
    }

    /// The age is a fact that changes with nothing happening, so the board's heartbeat is what keeps
    /// whatever is showing it honest.
    override func timePassed() {
        describeYourself()
        askWhetherPlaying()
    }

    /// Only a page that is running can be playing, whatever WebKit said last.
    override var isPlayingMedia: Bool { web != nil && playing }

    override var keepsPageRunning: Bool { CanvasCardMedia.keepsRunning(node) }

    /// Keep Running from the tile's menu, which is about this card rather than the selection.
    func setKeepRunning(_ on: Bool) { board.setKeepRunning(on, on: [self]) }

    /// What WebKit last said about the page playing anything. See `askWhetherPlaying`.
    private var playing = false

    /// Ask whether the page is playing something, on the heartbeat.
    ///
    /// Asked rather than told. WebKit answers the question and posts nothing when the answer changes,
    /// and a script listening for `play` in every frame would be one more thing PM says to every iframe
    /// on the web — which `CanvasCardMedia.script` has already learnt the cost of. The heartbeat runs
    /// every twenty seconds while anything is live and the idle pause is two minutes out, so the answer
    /// is fresh by the time anything acts on it. See `CanvasPageBudget.Candidate.isInUse`.
    private func askWhetherPlaying() {
        guard let web else { return }
        Task { [weak self] in
            let state = await web.requestMediaPlaybackState()
            guard let self, self.web === web else { return }
            self.playing = state == .playing
        }
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
            // Stepping in is where a card stops adopting names. Clicking a link is the only way a page
            // goes somewhere the card didn't send it, and a click is only possible from in here — so
            // this is the earliest honest moment to stop, and it is the one that covers the case
            // `decidePolicyFor` cannot see: a site that navigates itself in script, where the URL is
            // rewritten with no navigation for a delegate to be asked about at all.
            capturingTitle = false
            if let web { window?.makeFirstResponder(web) }
        } else {
            // A page that still has the pointer when you've stepped out of it has the mouse for a card
            // that no longer takes clicks. Asked of the main frame only, which is where a page that
            // wants the pointer nearly always asks for it.
            if let page = web as? CanvasPageView, page.holdsPointer {
                page.evaluateJavaScript("document.exitPointerLock()")
            }
            if let web, (window?.firstResponder as? NSView)?.isDescendant(of: web) == true {
                window?.makeFirstResponder(board)
            }
        }
        board.pageStateChanged()
    }

    /// The view is going; the card is not.
    ///
    /// Cards are built as they scroll into view and thrown away as they leave, so this runs constantly
    /// on an ordinary board — and it used to tear a page down without asking it anything. A card
    /// scrolled off and back came up as a globe and a hostname, its picture gone with the view and its
    /// session as stale as the last time something had *paused* it. Freezing captured all of this
    /// properly; being recycled captured none of it, and being recycled is the common one.
    ///
    /// Not `freeze()` itself, which installs its picture into a view that is about to be discarded and
    /// stops on a `freezing` flag this has no way to clear. The three things worth keeping are kept
    /// straight into the stores that outlive the view, and the web view is held by the snapshot's own
    /// closure so the answer still arrives after `tearDownPage` has let go of it.
    override func prepareForRemoval() {
        if let web, revealed {
            resumeState = web.interactionState
            resumeURL = web.url ?? resumeURL ?? url
            noteVisit()
            let key = pageKey
            let tiled = board.isTiled
            let configuration = WKSnapshotConfiguration()
            configuration.afterScreenUpdates = false
            web.takeSnapshot(with: configuration) { image, _ in
                MainActor.assumeIsolated {
                    // Held deliberately: without it the view is released by `tearDownPage` below,
                    // before the web process has answered, and the picture never arrives.
                    _ = web
                    guard let image else { return }
                    CanvasPageSnapshots.keep(image, for: key, tiled: tiled)
                }
            }
        }
        tearDownPage()
        wanted = false
    }

    // MARK: What the card's menu can do to it

    var canGoBack: Bool { web?.canGoBack ?? false }
    var canGoForward: Bool { web?.canGoForward ?? false }
    /// Mid-navigation, for the header's Reload button to become a Stop.
    var isLoading: Bool { web?.isLoading ?? false }

    /// **Whether a load has been going long enough to be worth saying anything about.**
    ///
    /// A live page is not only the page you asked for: an app shell polls, a socket reconnects, a
    /// dashboard re-fetches itself every few seconds, and each of those is a real main-frame load that
    /// starts and ends before you could read anything about it. Reported honestly, they turned the
    /// chrome into a metronome — Reload became Stop and back, and the progress bar faded up and out
    /// along the address field, every few seconds, for as long as the card was open.
    ///
    /// Nothing about that was information. The two things the readout is for are a load you started
    /// and a load that is stuck, and both last: `loadWorthReporting` is below the point where a person
    /// would begin to wonder, and above everything a page does to itself while you read it. Which is
    /// the same rule a browser follows — Safari does not flash its progress bar for a load that is
    /// already over.
    ///
    /// The card goes on knowing it is loading (`isLoading` is unchanged, and Stop still stops it the
    /// moment the button is there). This is only what the *chrome* is told.
    var showsLoad: Bool {
        isLoading && CanvasPageLoad.isWorthReporting(startedAt: loadingSince)
    }
    /// True once the page has wandered off the address the board saved for this card.
    var hasWandered: Bool { web != nil && url != nil && web?.url != url }

    /// Whether what is on screen arrived over a connection nobody can read. The rule, and why it marks
    /// only the bad answer, is `CanvasAddress.isEncrypted`.
    var isSecure: Bool { CanvasAddress.isEncrypted(liveURL?.absoluteString ?? address) }

    /// How far the current load has got, or zero when nothing is loading.
    ///
    /// Rounded to twentieths, which is what makes it cheap: the header's `Page` is an `Equatable`
    /// struct rebuilt on every change, and an unrounded `estimatedProgress` changes on every packet —
    /// so the readout would be a SwiftUI pass per packet for a bar two points tall.
    var loadProgress: Double {
        guard let web, web.isLoading, showsLoad else { return 0 }
        return (web.estimatedProgress * 20).rounded(.down) / 20
    }

    /// Where Back would take you, nearest first — the list behind a press-and-hold.
    ///
    /// Capped, because a card left open on a wiki for a day has a back list nobody wants as a menu,
    /// and the entries past the first handful are not a place you remember being.
    var backSteps: [(title: String, address: String)] {
        guard let web else { return [] }
        return web.backForwardList.backList.reversed().prefix(12).map { item in
            // A page WebKit has no title for — one never loaded in this session, or one that titled
            // itself with nothing — is named by its host, which is what the card would call it too.
            let named = item.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return (title: named.isEmpty ? (item.url.host() ?? item.url.absoluteString) : named,
                    address: item.url.absoluteString)
        }
    }

    /// Go back `steps` pages at once. One is what Back does; more is what the menu behind it offers.
    func goBack(_ steps: Int) {
        guard let web, steps > 0 else { return }
        let list = web.backForwardList.backList.reversed()
        guard steps <= list.count else { return }
        web.go(to: Array(list)[steps - 1])
    }

    /// Put the address on the clipboard — the page you are looking at, as everywhere else.
    func copyAddress() {
        guard let url = liveURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    func goBack() { web?.goBack() }
    func goForward() { web?.goForward() }
    func stopLoading() {
        web?.stopLoading()
        board.pageStateChanged()
    }

    /// Send the page to an address typed into the header's field.
    ///
    /// Navigation, not an edit: what the board has saved for this card is untouched, so this lands the
    /// card in the same wandered state as clicking a link would, with Home and Pin beside the address to
    /// resolve it. A card whose saved address quietly followed wherever you looked would be a board that
    /// rewrites itself while you read it.
    func go(to address: String) {
        guard let url = URL(string: address) else { return }
        web?.load(URLRequest(url: url))
        board.pageStateChanged()
    }

    /// Put the card back on its own address.
    ///
    /// The button that matters most, and the one a browser doesn't have. Back walks the history; this
    /// returns the card to the thing it is *for*, and it works where Back cannot — after a sign-on
    /// redirect chain with nothing sensible behind it, or on a card whose page was rebuilt. "I am
    /// somewhere I did not mean to be" is a different question from "what was I looking at before".
    ///
    /// **Undoable**, because it is also a way of losing your place: Home from three links into a site
    /// is a page you may not find your way back to. Undo walks back to where you were; redo goes home.
    func goHome() {
        guard let url else { return }
        let from = web?.url
        // Back on its own address, so the page about to arrive is the card's own page again and its
        // name is the card's name. The one way out of the state stepping in put the card into.
        capturingTitle = true
        web?.load(URLRequest(url: url))
        if let from, from != url {
            registerUndo("Go Home", returningTo: from) { $0.goHome() }
        }
    }

    /// Put a navigation on the board's undo stack: undo takes the page back to `page`, redo does `redo`.
    ///
    /// On the canvas's stack, because ⌘Z on a board already means the board's last act and a card has
    /// no stack of its own. Found again by id when it runs rather than held, because the view that
    /// registered the step may have been recycled by then; a card that is no longer built leaves the
    /// step spent and its page where it was.
    private func registerUndo(_ name: String, returningTo page: URL,
                              redo: @escaping @MainActor (CanvasLinkNodeView) -> Void) {
        let id = node.id
        let store = board.store
        weak var owner = board
        store.undoManager.registerUndo(withTarget: store) { store in
            MainActor.assumeIsolated {
                guard let card = owner?.nodeViews[id] as? CanvasLinkNodeView else { return }
                card.walkBack(to: page)
                store.undoManager.registerUndo(withTarget: store) { _ in
                    MainActor.assumeIsolated {
                        (owner?.nodeViews[id] as? CanvasLinkNodeView).map(redo)
                    }
                }
                store.undoManager.setActionName(name)
            }
        }
        store.undoManager.setActionName(name)
    }

    /// Take the page to `page` — by Back, when Back goes there, so undoing your way to a page leaves a
    /// history rather than a second copy of it.
    private func walkBack(to page: URL) {
        guard let web else { return }
        // Wherever this lands is somewhere the card went, not what it is for, so not its name either.
        capturingTitle = false
        if web.backForwardList.backItem?.url == page {
            web.goBack()
        } else {
            web.load(URLRequest(url: page))
        }
        board.pageStateChanged()
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
    ///
    /// **Undone without rebuilding either.** Undo puts the old address back while this page stays where
    /// it is, which leaves the card exactly as it was a moment before — off its address, with Home and
    /// Pin beside it — and redo is the Pin again. See `pinned`.
    func adoptCurrentAddress() {
        guard let live = liveURL, live.absoluteString != address else { return }
        // The page on screen is what the card is for now, so its name is the card's name — and it is
        // in hand already. Remembered before the address changes, or the card would sit nameless until
        // the next time something loaded it, having been looking at the answer the whole time.
        if let title = web?.title { CanvasPageTitles.remember(title, for: live.absoluteString) }
        pinned = (home: address, page: live.absoluteString)
        setAddress(live.absoluteString, as: "Pin Address")
        capturingTitle = true
    }

    /// Point this card somewhere else. Undoable, and named for what the Edit menu should say.
    func setAddress(_ next: String, as actionName: String = "Change Address") {
        let trimmed = next.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != address else { return }
        // Set before the store's change lands, because the change comes back through `update(node:)`
        // and then `contentChanged`, which is the teardown this exists to skip.
        alreadyShowing = web?.url?.absoluteString == trimmed
        let id = node.id
        board.store.change(actionName) { doc in
            guard let index = doc.nodes.firstIndex(where: { $0.id == id }) else { return }
            doc.nodes[index].content = .link(url: trimmed)
        }
    }

    /// Set for the one turn in which a new address is being adopted from the page already on screen.
    /// See `adoptCurrentAddress`.
    private var alreadyShowing = false

    /// The last Pin: the address it replaced, and the page it made the address. Its undo and its redo
    /// arrive as ordinary changes of address through the document, and this is how `contentChanged`
    /// tells them from an edit that means a different page — the page on screen is the one pinned.
    private var pinned: (home: String, page: String)?

    /// Load it again from the top — and if the card had given up, start over from the placeholder.
    func reload() {
        if let web, revealed { web.reload() } else { contentChanged() }
    }

    /// Load it again without trusting anything cached: every subresource is revalidated with the server.
    /// A card that had given up starts over, as `reload` does.
    func hardReload() {
        if let web, revealed { web.reloadFromOrigin() } else { contentChanged() }
    }

    /// Throw away this site's cached files in the card's own session, then hard reload.
    ///
    /// Only the cache: cookies and storage stay, so the card is still signed in afterwards. Scoped to
    /// the card's site within the card's session, since every other card sharing that session is
    /// relying on the rest of it.
    func emptyCacheAndReload() {
        guard let web else { return contentChanged() }
        let store = web.configuration.websiteDataStore
        let site = (web.url?.host() ?? host).lowercased()
        let types: Set<String> = [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache,
                                  WKWebsiteDataTypeFetchCache]
        store.fetchDataRecords(ofTypes: types) { records in
            let mine = records.filter { site == $0.displayName || site.hasSuffix("." + $0.displayName) }
            store.removeData(ofTypes: types, for: mine) { [weak self] in
                MainActor.assumeIsolated { self?.hardReload() }
            }
        }
    }

    // MARK: Searching it, and keeping it fresh

    /// Look for `query` in the page, and say whether it was there.
    ///
    /// ⌘F on a board means "which card", and inside a page it has to mean "where on this page" — those
    /// are the same question asked at two scales, which is the argument ⌘+ and ⌘− already make on this
    /// board. WebKit's own find is used rather than a script injected into the page: it highlights, it
    /// scrolls the match into view, and it works on a page whose content security policy would refuse
    /// anything PM injected.
    /// The page's selected text, for Edit ▸ Find ▸ Use Selection for Find. Empty when nothing is
    /// selected or the page can't say.
    func selectedText(then give: @escaping (String) -> Void) {
        guard let web else { return give("") }
        web.evaluateJavaScript("String(window.getSelection())") { result, _ in
            MainActor.assumeIsolated { give((result as? String) ?? "") }
        }
    }

    func find(_ query: String, forward: Bool = true, then say: @escaping (Bool) -> Void) {
        guard let web, !query.isEmpty else { return say(false) }
        let configuration = WKFindConfiguration()
        configuration.backwards = !forward
        configuration.caseSensitive = false
        configuration.wraps = true
        web.find(query, configuration: configuration) { result in
            MainActor.assumeIsolated { say(result.matchFound) }
        }
    }

    /// Load it again if what is on screen is older than `interval`.
    ///
    /// The board asks, on its heartbeat — see `CanvasBoardView.refreshStalePages`. Only a card that is
    /// actually running is asked, so a refresh cadence never wakes a frozen renderer, and never a card
    /// you are inside: reloading the page under somebody's hands, mid-scroll or mid-form, is the one
    /// way an automatic refresh can cost you something.
    override func reloadIfStale(after interval: TimeInterval) {
        guard let loadedAt, web != nil, !isEngaged, !isLoading,
              Date().timeIntervalSince(loadedAt) >= interval else { return }
        web?.reload()
    }

    /// Open the page in the browser — what the card's menu offers, and where a page you actually want
    /// to *use* belongs. A card is a clipping.
    ///
    /// **The page you are looking at, not the address on the board.** This used to open the saved one,
    /// which meant that following three links out of a tracker and then asking for a browser handed you
    /// the tracker — the one page you could already see, instead of the one you had gone to the trouble
    /// of finding. Every other command in this file is explicit about which of a card's two addresses
    /// it means, and this one had picked the wrong one silently.
    ///
    /// `liveURL` falls back to the saved address for a card with no page running, which is the same
    /// answer as before for every card that never wandered.
    func openInBrowser() {
        guard let url = liveURL else { return }
        NSWorkspace.shared.open(url)
    }

    /// Where the running page is — scroll, history — for a second card to start from. Nil with no page.
    var liveInteractionState: Any? { web?.interactionState }

    /// A second card on the page this one is showing — see `CanvasBoardView.openPageAsNewCard`.
    func openPageAsNewCard() { _ = board.openPageAsNewCard(from: self) }

    /// The site this card shows, for the sign-in item's title.
    var siteName: String { host }

    /// Whether this card's site is being filtered, for the menu's checkmark.
    var isFiltered: Bool { CanvasContentBlocker.filters(host: url?.host() ?? host) }

    /// Turn filtering on or off for this card's site, and show the result on every card showing it.
    func setFiltered(_ on: Bool) {
        CanvasContentBlocker.setFilters(on, host: url?.host() ?? host)
        Self.siteChanged(url?.host() ?? host)
    }

    /// Which browser this card's site is told it is talking to, for the menu's checkmark.
    var identity: CanvasBrowserIdentity { CanvasSiteSettings.site(for: url?.host() ?? host).identity }

    /// Tell this card's site it is talking to a different browser, and rebuild every card showing it.
    func setIdentity(_ identity: CanvasBrowserIdentity) {
        let site = url?.host() ?? host
        guard let key = CanvasSiteSettings.update(site, { $0.identity = identity }) else { return }
        Log.write("canvas site: \(key) identifies as \(identity.rawValue)")
        Self.siteChanged(site)
    }

    /// Rebuild every running page on a site whose settings just changed — from a card's menu, the tile's
    /// menu or the list in Settings.
    ///
    /// **Every card, not the one you asked from.** The setting is the site's, so a second card on the same
    /// site left running under the old one would be two answers to one question on the same screen. A
    /// card with no page running has nothing to rebuild and picks the setting up when it next starts.
    static func siteChanged(_ host: String) {
        let key = CanvasBlockPolicy.siteKey(for: host)
        for card in cards.allObjects where CanvasBlockPolicy.siteKey(for: card.url?.host() ?? card.host) == key {
            card.reapplyFiltering()
        }
    }

    /// Build the page again so it picks up a different set of rule lists, or a different name.
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
        let jar = CanvasWebSession.store(named: profile)
        Task { @MainActor in
            await CanvasWebSession.forget(host: site, in: jar)
            reload()
        }
    }

    /// Sign in to this card's site in a window you can actually use — see `CanvasSignInWindow`.
    func signIn() {
        guard let url else { return }
        // Into this card's jar, which is the only one signing in to it would help.
        CanvasSignInWindow.present(for: url, profile: profile) { [weak self] in
            // Whatever the session picked up is in the shared jar now, so the quickest way to see it
            // is to ask the card for the page again.
            self?.reload()
        }
    }
}

// MARK: - What a link on the page can become

/// The two things a board can do with a link that a browser cannot, offered where a browser offers
/// "Open in New Tab": put it on the board, and write it into the project.
///
/// ⌘-click already makes a card — see `decidePolicyFor` — and always did the more useful half of this.
/// What it didn't do is announce itself. A gesture nobody is told about is a gesture for the person who
/// wrote it, and the menu is where every browser has taught people to look for exactly this.
///
/// **The page is offered too, not just links.** A right-click on open ground has no link under it and
/// still has an answer worth having: the page you are looking at is the thing you would want in the
/// project's links, and by then you have usually followed three links to reach it.
extension CanvasLinkNodeView: CanvasPageLinkHost {
    func pageMenuItems(for link: PageLink?) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        if let link {
            items.append(item("Open Link as New Card", #selector(openLinkAsCard), link))
        } else if let page = liveURL {
            items.append(item("Open Page as New Card", #selector(openPageAsCard), PageLink(url: page, name: liveTitle)))
        }
        if let project = board.boardProject {
            // Whatever the click was on: the link under the pointer, or the page itself. The page's
            // own name comes from the running view, which is the one place it is certainly current.
            let target = link ?? liveURL.map { PageLink(url: $0, name: liveTitle) }
            if let target {
                let what = link == nil ? "Add Page to" : "Add Link to"
                items.append(item("\(what) \(project.title)", #selector(addLinkToProject), target))
            }
        }
        return items
    }

    func openInNewCard(_ link: PageLink) {
        board.addLinkCard(link.url.absoluteString, beside: node.id)
    }

    /// A tile, or a card you have stepped into: somewhere you are working in the page, not arranging it.
    var pageTakesFiles: Bool { isEngaged || board.isTiled }

    func loadDroppedFile(_ url: URL) {
        guard let web else { return }
        // A page you were sent to by hand is not what the card is for — the card's name stays.
        capturingTitle = false
        droppedFile = url
        web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }

    private func item(_ title: String, _ action: Selector, _ link: PageLink) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        // The link travels on the item rather than in a property, because the menu outlives the press
        // that built it and the pointer will have moved on by the time anything is chosen.
        item.representedObject = link
        return item
    }

    @objc private func openPageAsCard(_ sender: NSMenuItem) {
        openPageAsNewCard()
    }

    @objc private func openLinkAsCard(_ sender: NSMenuItem) {
        guard let link = sender.representedObject as? PageLink else { return }
        openInNewCard(link)
    }

    @objc private func addLinkToProject(_ sender: NSMenuItem) {
        guard let link = sender.representedObject as? PageLink else { return }
        board.addLinkToProject(link.url.absoluteString, named: link.name)
    }
}

// MARK: - Loading

extension CanvasLinkNodeView: WKNavigationDelegate {
    /// Notice when the page is being sent somewhere the card didn't send it.
    ///
    /// **Nothing is refused here.** Every navigation is allowed, exactly as it was when this method did
    /// not exist — what it is for is `capturingTitle`. A card is named after the page it is *for*, and
    /// a link followed out of that page is a different page; a redirect the card's own load ran into is
    /// not, and arrives as `.other`. So the question this asks is who navigated rather than where the
    /// page ended up, which is the only form of the question a redirect chain answers correctly.
    ///
    /// Stepping into a card stops the capture too, and has to: a site that navigates itself in script
    /// rewrites the URL with no navigation for a delegate to be asked about. This catches the case
    /// stepping in cannot — Back and Forward, which the card's menu offers without stepping in at all.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let clicked = navigationAction.navigationType == .linkActivated
        switch navigationAction.navigationType {
        case .linkActivated, .formSubmitted, .formResubmitted, .backForward: capturingTitle = false
        default: break
        }

        // ⌘-click: the link becomes a card of its own, beside this one and joined to it.
        if clicked, navigationAction.modifierFlags.contains(.command),
           let target = navigationAction.request.url, isWeb(target) {
            board.addLinkCard(target.absoluteString, beside: node.id)
            return decisionHandler(.cancel)
        }

        // A link the page has asked to be downloaded rather than shown — `download` on the anchor.
        if navigationAction.shouldPerformDownload { return decisionHandler(.download) }

        guard let target = navigationAction.request.url, !isWeb(target) else {
            return decisionHandler(.allow)
        }
        // The file a ⌥-drop just sent here — and a fragment link within it.
        if target.isFileURL, let dropped = droppedFile, target.path == dropped.path {
            return decisionHandler(.allow)
        }
        decisionHandler(.cancel)
        // A file the page had nowhere to put arrives as the page navigating to it — WebKit's answer to
        // a drop nobody took, now that a tile's page is offered files (`pageTakesFiles`). Nothing to
        // open and nothing to report: the drop simply didn't land.
        if target.isFileURL { return }
        handOff(target, clicked: clicked)
    }

    /// Whether this is a page a card can show. Everything else belongs to some other app, or to nobody.
    private func isWeb(_ url: URL) -> Bool {
        ["http", "https", "about", "data", "blob"].contains(url.scheme?.lowercased() ?? "")
    }

    /// A link that isn't a web page: `mailto:`, `slack://`, `zoom://`, a vault's own `obsidian://`.
    ///
    /// **A click hands it to the system; a page redirecting itself does not.** Clicking a `mailto:` and
    /// getting Mail is what every browser does and what you meant by clicking it. A page navigating
    /// *itself* to an app scheme is the "open in our app" interstitial, and honouring that would be a
    /// board that launches applications while you read it — so it is refused, out loud, which is also
    /// the honest answer for a scheme nothing on this Mac can open. Both used to be silence.
    private func handOff(_ url: URL, clicked: Bool) {
        let scheme = (url.scheme ?? "link") + ":"
        guard clicked else {
            return board.report("This page tried to open a \(scheme) link on its own. Folio didn't.")
        }
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: url) else {
            return board.report("Nothing on this Mac opens \(scheme) links.")
        }
        NSWorkspace.shared.open(url)
        board.report("Opened in " + FileManager.default.displayName(atPath: app.path) + ".")
    }

    /// A response that is a file rather than a page — an export, a zip, a signed PDF.
    ///
    /// **Two tests, and the obvious one is not enough.** `canShowMIMEType` catches a zip; it does not
    /// catch a CSV, because WebKit can perfectly well *display* `text/csv` and will, as a wall of
    /// commas inside the card. What the server actually said is `Content-Disposition: attachment`,
    /// which is that header's entire purpose — this is a file, not a page — and it is what the Export
    /// button on a dashboard relies on. Measured, not assumed: a `text/csv` export came back
    /// `canShowMIMEType == true`.
    ///
    /// With neither test the response was rendered or dropped and nothing was saved anywhere, which is
    /// the silence `CanvasDownload` exists to end.
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(isFile(navigationResponse) ? .download : .allow)
    }

    private func isFile(_ response: WKNavigationResponse) -> Bool {
        guard response.canShowMIMEType else { return true }
        let disposition = (response.response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Disposition")?
            .trimmingCharacters(in: .whitespaces).lowercased()
        return disposition?.hasPrefix("attachment") ?? false
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction,
                 didBecome download: WKDownload) {
        take(download)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse,
                 didBecome download: WKDownload) {
        take(download)
    }

    private func take(_ download: WKDownload) {
        CanvasDownload.take(download) { [weak self] message, file in
            self?.board.report(message, reveal: file)
        }
        // A navigation that turned into a download leaves the card mid-load, with a Stop button in the
        // header and no navigation left for it to stop.
        board.pageStateChanged()
    }

    /// A site asking who you are. Basic, digest and NTLM get a panel; anything else gets the system's
    /// own answer.
    ///
    /// **A certificate is deliberately not ours to wave through.** Answering a server-trust challenge
    /// here would be PM deciding on your behalf that an expired or self-signed certificate is fine, in
    /// a card with no address bar of its own. `performDefaultHandling` leaves that where it belongs.
    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping (URLSession.AuthChallengeDisposition,
                                               URLCredential?) -> Void) {
        let asks = [NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest,
                    NSURLAuthenticationMethodNTLM]
        guard asks.contains(challenge.protectionSpace.authenticationMethod),
              challenge.previousFailureCount < 3 else {
            return completionHandler(.performDefaultHandling, nil)
        }
        CanvasWebDialogs.signIn(to: challenge.protectionSpace.host,
                                realm: challenge.protectionSpace.realm,
                                in: window) { credential in
            if let credential { completionHandler(.useCredential, credential) }
            else { completionHandler(.cancelAuthenticationChallenge, nil) }
        }
    }

    /// Say what the card is actually showing, as soon as it starts showing it.
    ///
    /// On `didCommit` rather than `didFinish`, because the page is on screen and can be typed into from
    /// the moment it commits — a readout that only caught up once the page had finished loading would
    /// be wrong for exactly the window in which being wrong costs something. That window is the whole
    /// reason the address is shown at all: during a single sign-on you are handed between hosts, and a
    /// password field is only safe to type into if you can see whose it is.
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        noteVisit()
        describeYourself()
        // There is a document now, so there is something to photograph: start asking whether it has
        // painted. See `startProbingForPaint`, which is what gets a card out from behind its
        // placeholder before the page has finished loading.
        startProbingForPaint()
        board.pageStateChanged()
    }

    /// The header's Stop button exists between here and `didFinish`, so both edges have to be reported.
    /// A card mid-navigation is otherwise indistinguishable from one sitting still — it goes on drawing
    /// the page it already had until the new one paints.
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        // When it started, which is the whole of what `showsLoad` needs — and a nudge at the moment it
        // becomes worth saying, because a load that is *stuck* is exactly the one that will send no
        // further progress for the header to notice it on.
        if loadingSince == nil { loadingSince = Date() }
        DispatchQueue.main.asyncAfter(deadline: .now() + CanvasPageLoad.worthReporting) { [weak self] in
            guard let self, isLoading else { return }
            board.pageStateChanged()
        }
        board.pageStateChanged()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loadingSince = nil
        revealPage()
        board.pageStateChanged()
        adoptDeclaredIcon(from: webView)
    }

    /// If the site has no `/favicon.ico`, use the icon the page itself declares. Asked once per
    /// finished load and only while the host has no icon, so a card with one pays nothing.
    private func adoptDeclaredIcon(from webView: WKWebView) {
        guard FaviconLoader.isEnabled, let host = webView.url?.host,
              FaviconLoader.shared.cached(for: host) == nil else { return }
        let js = """
        (() => { const l = [...document.querySelectorAll('link[rel~="icon"], link[rel="apple-touch-icon"]')]
          .filter(e => e.href); return l.length ? l[l.length - 1].href : null; })()
        """
        webView.evaluateJavaScript(js) { [weak self] result, _ in
            guard let self, let s = result as? String, let url = URL(string: s) else { return }
            Task { @MainActor in
                guard await FaviconLoader.shared.adopt(declared: url, for: host) != nil else { return }
                self.board.pageStateChanged()
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        failed(error)
        loadingEnded()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        failed(error)
        loadingEnded()
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
        stopProbingForPaint()
        guard !revealed else { return }
        // Out in a window, the page stays where it is: the window is all there is to show, and it has
        // its own Reload. See `CanvasSatelliteWindow`.
        if satellite != nil {
            revealPage()
            return
        }
        tearDownPage()
        // The picture from the last time the page ran is what the card showed while it tried. Once the
        // answer is that it couldn't, a page drawn under "Couldn't load" contradicts it. Marked as
        // settled for this shape, so a crossing between the board and tiles doesn't put one back; the
        // stored picture is kept, and stands in again the next time the card tries.
        frozen?.removeFromSuperview()
        frozen = nil
        pictureIsTiled = board.isTiled
        placeholder?.isHidden = false
        say("Couldn't load", tooltip: ns.localizedDescription)
    }

    /// A failure the card rides out — the page is still there — still ends the load, and the header is
    /// showing a Stop button that has nothing left to stop.
    private func loadingEnded() {
        loadingSince = nil
        board.pageStateChanged()
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
    ///
    /// The exception is a *popup* — a window a script asked for by name and size, which is what every
    /// "Continue with Google" on the web is. Flattening one of those into a navigation here is what
    /// left a sign-in dead on a blank page; see `CanvasWebPopup`, which is also where the two are told
    /// apart.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let url = navigationAction.request.url else { return nil }
        // ⌘-click reaches here too, and means the same thing it means on an ordinary link: this one
        // goes on the board. Without it, the gesture would work on half the links of a real site and
        // not the other half, for a reason nobody could see.
        if navigationAction.modifierFlags.contains(.command) {
            board.addLinkCard(url.absoluteString, beside: node.id)
        } else if CanvasWebPopup.wanted(by: navigationAction, features: windowFeatures) {
            return CanvasWebPopup.present(with: configuration, features: windowFeatures,
                                          userAgent: webView.customUserAgent, over: window, opener: self)
        } else {
            capturingTitle = false
            webView.load(URLRequest(url: url))
        }
        return nil
    }

    // MARK: What a page is allowed to put up

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping () -> Void) {
        CanvasWebDialogs.alert(message, from: frame.securityOrigin.host, in: window,
                               then: completionHandler)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (Bool) -> Void) {
        CanvasWebDialogs.confirm(message, from: frame.securityOrigin.host, in: window,
                                 then: completionHandler)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        CanvasWebDialogs.prompt(prompt, initial: defaultText ?? "", from: frame.securityOrigin.host,
                                in: window, then: completionHandler)
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping ([URL]?) -> Void) {
        CanvasWebDialogs.chooseFiles(parameters, in: window, then: completionHandler)
    }

    /// The camera and the microphone: asked once per site, then remembered. See
    /// `CanvasWebDialogs.mediaAccess`.
    ///
    /// A refusal is still said out loud. Denied without a word, a call's buttons look exactly like a
    /// broken page — which is how this looked when every request was refused.
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        CanvasWebDialogs.mediaAccess(for: origin.host, type, in: window) { [weak self] decision in
            if decision == .deny {
                self?.board.report("\(origin.host) isn't allowed the camera or microphone. Change it in "
                    + "Settings, under Sites.")
            }
            decisionHandler(decision)
        }
    }

    // MARK: Pointer lock

    /// A page asking for the pointer — `requestPointerLock()`, which is how a game or a 3D view gets
    /// raw mouse movement instead of a cursor that stops at the edge of the screen.
    ///
    /// **WebKit's only door for this is private.** Pointer lock is switched on in every web view, but
    /// the grant goes through `WKUIDelegatePrivate`, and a delegate that doesn't answer it is a refusal:
    /// the page gets `pointerlockerror` and nothing else happens, which is how this looked for as long
    /// as cards had no answer. Safari answers the same method. Folio ships Developer ID, not through
    /// the App Store, so the private selector costs nothing but the chance WebKit renames it.
    ///
    /// Only for a page you are working in: a card you have stepped into, or a tile. WebKit already
    /// insists on a click in the page first, and a card that isn't taking clicks can't be given one —
    /// this says so in the one place a later change to that could make it untrue.
    ///
    /// Said out loud, as every browser says it: the cursor vanishes, and the one way back has to be
    /// on screen when it does.
    @objc(_webViewDidRequestPointerLock:completionHandler:)
    func webViewDidRequestPointerLock(_ webView: WKWebView, completionHandler: @escaping (Bool) -> Void) {
        guard takesItsOwnClicks, webView.window?.isKeyWindow == true,
              let page = webView as? CanvasPageView else { return completionHandler(false) }
        page.holdsPointer = true
        board.report("\(host) has the pointer. Press Esc to get it back.")
        completionHandler(true)
    }

    /// The lock ended — Escape, the page letting go, or the window losing the keyboard.
    @objc(_webViewDidLosePointerLock:)
    func webViewDidLosePointerLock(_ webView: WKWebView) {
        (webView as? CanvasPageView)?.holdsPointer = false
    }
}
