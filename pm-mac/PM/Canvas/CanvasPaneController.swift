import AppKit
import SwiftUI
import UniformTypeIdentifiers
import PmLib

/// A canvas, with its chrome, as a view controller — so the same board can be a window of its own and
/// the contents of a project window's content pane.
///
/// Everything about showing and driving a board lives here: the scroller, the floating header, the
/// notice banner, find, the page controls, and the page budget's answer to nobody looking. What is left
/// outside is what genuinely belongs to a window — its frame, its title, its tabs — which is why this
/// exists at all. `CanvasWindowController` is now a window wrapped around one of these, and a project
/// window puts another one in the pane its task list would otherwise be in.
///
/// The store is **not** created here. Two surfaces can be showing the same file, so the store comes from
/// `CanvasStoreRegistry` and the owner is responsible for taking and giving back its hold — see
/// `teardown`.
@MainActor
final class CanvasPaneController: NSViewController, NSMenuItemValidation {
    let store: CanvasDocumentStore
    private let scroll: CanvasScrollView
    private let notice = CanvasNoticeBar()
    private let container = NSView()

    /// Everything the header shows and everything its controls do. Exposed so an owner can put its own
    /// commands in the options menu — a project window adds the switch back to its task list.
    let header = CanvasHeaderModel()
    private var pill: NSHostingView<CanvasTitlePill>!
    private var capsule: NSHostingView<CanvasControlCapsule>!
    private var pillLeading: NSLayoutConstraint!

    /// How far the header's leading edge starts in from the pane's own edge.
    ///
    /// Normally the window's traffic lights decide it. A project window's sidebar holds those buttons
    /// over *itself*, so a board in that window's content pane wants no inset at all — the same
    /// reasoning, and the same answer, as the task column's header.
    var ignoresTrafficLights = false {
        didSet { measureTitlebar() }
    }

    init(store: CanvasDocumentStore) {
        self.store = store
        scroll = CanvasScrollView(store: store)
        super.init(nibName: nil, bundle: nil)

        wireHeader()
        scroll.board.onPageStateChanged = { [weak self] in self?.pageStateChanged() }
        scroll.board.onTilingChanged = { [weak self] in
            guard let self else { return }
            header.tiling = scroll.board.tilingSummary
        }
        // The pane's own width, which is what the capsule has to fit inside — not the window's, since a
        // project window's sidebar takes a bite out of it.
        container.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(paneResized),
                                               name: NSView.frameDidChangeNotification,
                                               object: container)
        scroll.board.onModeChanged = { [weak self] in
            guard let self else { return }
            // The mode is flipped from the View menu and from the header's options, so the header
            // follows the board rather than being the only thing that knows.
            header.mode = scroll.board.mode
        }
        store.addWatcher(self,
                         changed: { [weak self] in self?.documentChanged() },
                         reloaded: { [weak self] in self?.noteOutsideChange() })
        scroll.onZoomChanged = { [weak self] zoom in self?.showZoom(zoom) }
        // Filtering is verified after launch, which is usually after this pane exists.
        NotificationCenter.default.addObserver(
            self, selector: #selector(blockingHealthChanged),
            name: CanvasContentBlocker.healthChanged, object: nil)
        notice.onDismissedByUser = { [weak self] in self?.hidBlockingNotice = true }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { NotificationCenter.default.removeObserver(self) }

    /// What the board's name is called in the header's pill.
    var title_: String {
        get { header.title }
        set { header.title = newValue }
    }

    override func loadView() {
        buildContent()
        view = container
    }

    /// Give up the board, and the document with it.
    ///
    /// Called by whoever owns this pane when it is finished with — a window closing, or a project
    /// window switching back to its task list. Explicit rather than in `deinit` because the registry is
    /// main-actor work and a hold given back late is a store that goes on polling a file nobody is
    /// looking at.
    func teardown() {
        idleTimer?.invalidate()
        idleTimer = nil
        stopWatchingTheWindow()
        scroll.board.pauseAllPages()
        scroll.board.releaseCards()
        store.removeWatcher(self)
        CanvasStoreRegistry.release(store)
    }

    // MARK: Appearing

    override func viewDidAppear() {
        super.viewDidAppear()
        watchTheWindow()
        view.window?.layoutIfNeeded()
        measureTitlebar()
        paneResized()
        guard !hasFitted else { return }
        hasFitted = true
        // Fitted after the pane has a size, or "fit" is computed against a zero-width clip view.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            scroll.zoomToFit()
            showZoom(scroll.magnification)
            view.window?.makeFirstResponder(scroll.board)
        }
    }

    private var hasFitted = false

    /// Take the keyboard, for an owner that has just put this pane on screen.
    func focusBoard() { view.window?.makeFirstResponder(scroll.board) }

    /// The traffic lights move when the titlebar's height changes and disappear in full screen, and a
    /// window's own resize is not the only thing that moves them — a project window's sidebar opening
    /// does too. Watched here rather than left to a window delegate, because this pane can be inside a
    /// window whose delegate is somebody else's.
    private func watchTheWindow() {
        guard let window = view.window, watchedWindow !== window else { return }
        stopWatchingTheWindow()
        watchedWindow = window
        let centre = NotificationCenter.default
        for name in [NSWindow.didResizeNotification, NSWindow.didEnterFullScreenNotification,
                     NSWindow.didExitFullScreenNotification] {
            centre.addObserver(self, selector: #selector(windowGeometryChanged),
                               name: name, object: window)
        }
        centre.addObserver(self, selector: #selector(windowBecameKey),
                           name: NSWindow.didBecomeKeyNotification, object: window)
        centre.addObserver(self, selector: #selector(windowResignedKey),
                           name: NSWindow.didResignKeyNotification, object: window)
    }

    private var watchedWindow: NSWindow?

    private func stopWatchingTheWindow() {
        guard let watchedWindow else { return }
        for name in [NSWindow.didResizeNotification, NSWindow.didEnterFullScreenNotification,
                     NSWindow.didExitFullScreenNotification, NSWindow.didBecomeKeyNotification,
                     NSWindow.didResignKeyNotification] {
            NotificationCenter.default.removeObserver(self, name: name, object: watchedWindow)
        }
        self.watchedWindow = nil
    }

    @objc private func windowGeometryChanged() { measureTitlebar() }

    @objc private func paneResized() {
        let room = CanvasHeaderModel.Room(width: container.bounds.width)
        if header.room != room { header.room = room }
    }

    @objc private func windowBecameKey() {
        idleTimer?.invalidate()
        idleTimer = nil
        scroll.board.reviewPageBudget()
        store.checkForOutsideChange()
    }

    @objc private func windowResignedKey() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: Self.idleGrace, repeats: false) { _ in
            Task { @MainActor [weak self] in self?.scroll.board.pauseAllPages() }
        }
    }

    /// The board, edge to edge, with the window's chrome floating over it.
    ///
    /// Nothing in this window is a bar. The board fills the content view — under the titlebar, out to
    /// every edge — and the pill, the capsule and the notice banner are laid over it. The pill and the
    /// capsule are **separate hosting views sized to their own contents** rather than one strip across
    /// the top: a strip would hit-test its whole width and swallow every click in the band where the
    /// cards you are reading actually are.
    private func buildContent() {
        pill = NSHostingView(rootView: CanvasTitlePill(model: header))
        capsule = NSHostingView(rootView: CanvasControlCapsule(model: header))
        // The hosting view is the size SwiftUI says it is, so each view's frame is the pill or the
        // capsule and not a rectangle of window around it. Set one at a time because the two are
        // different generic types and an array of them is an array of `NSView`.
        pill.sizingOptions = [.intrinsicContentSize]
        capsule.sizingOptions = [.intrinsicContentSize]
        // And no safe area, which is the difference between this header sitting *in* the titlebar band
        // and sitting below it. The window has a full-size content view, so AppKit reports the titlebar
        // and toolbar as a top safe area inset — correct for content that should stay clear of the
        // window's chrome, and exactly backwards for chrome that is meant to run up into it. SwiftUI
        // honours that inset inside a hosting view by default, so the pill was starting below the band
        // and then taking its own drop on top: about 66 points of droop for a 14-point offset.
        pill.safeAreaRegions = []
        capsule.safeAreaRegions = []
        pill.translatesAutoresizingMaskIntoConstraints = false
        capsule.translatesAutoresizingMaskIntoConstraints = false

        container.translatesAutoresizingMaskIntoConstraints = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        notice.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(scroll)
        container.addSubview(notice)
        container.addSubview(pill)
        container.addSubview(capsule)

        // Held so the leading inset can follow the traffic lights, which move with the titlebar's
        // height and vanish in full screen.
        pillLeading = pill.leadingAnchor.constraint(equalTo: container.leadingAnchor,
                                                    constant: TitlebarButtonMetrics.unmeasured.leadingInset)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: container.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            pill.topAnchor.constraint(equalTo: container.topAnchor),
            pillLeading,
            capsule.topAnchor.constraint(equalTo: container.topAnchor),
            capsule.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            // The pill gives way first when the window is too narrow to hold both — the controls have a
            // floor and the title has a truncation.
            pill.trailingAnchor.constraint(lessThanOrEqualTo: capsule.leadingAnchor, constant: -12),

            // Under the chrome rather than level with it, so the banner reads as something the window
            // is telling you about the board rather than as part of the window's controls.
            notice.topAnchor.constraint(equalTo: container.topAnchor, constant: 56),
            notice.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            notice.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -14),
        ])
        pill.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        notice.onRepairAll = { [weak self] in self?.repairAllPaths() }
        notice.onReveal = { [weak self] in self?.selectMovedCards() }
    }

    /// Keep the header level with, and clear of, the window's own buttons.
    ///
    /// The vertical drop is the header's business (see `TitlebarDrop`), because it depends on how tall
    /// each piece turns out to be. The leading inset is this pane's, because it depends on where the
    /// traffic lights are relative to *it* — and there are three answers, not two. A canvas window puts
    /// them over the board, so the pill starts clear of them. Full screen has none, so it starts at the
    /// edge. And in a project window with its sidebar showing they sit over the sidebar, which is a
    /// different pane entirely, so again the pill starts at the edge — see `ignoresTrafficLights`.
    private func measureTitlebar() {
        guard pillLeading != nil else { return }
        let metrics = view.window?.titlebarButtonMetrics()
        // `Self.margin` is the floor in every case, so the pill never sits hard against the pane's edge
        // — full screen reports no buttons at all, and a sidebar holding them reports buttons that are
        // over somebody else's pane.
        let inset = ignoresTrafficLights ? Self.margin
            : max(Self.margin, metrics?.leadingInset ?? pillLeading.constant)
        if abs(pillLeading.constant - inset) > 0.5 { pillLeading.constant = inset }
        if let metrics, header.titlebar != metrics { header.titlebar = metrics }
    }

    /// The gap between the header's chrome and the edge of the pane. The task column's is 14 too.
    private static let margin: CGFloat = 14

    // MARK: The header

    /// Point the header's controls at the board and the window.
    private func wireHeader() {
        header.addCard = { [weak self] in self?.addTextCard() }
        header.addFrame = { [weak self] in self?.addFrame() }
        header.addLink = { [weak self] in self?.scroll.board.addLinkCard(at: nil) }
        header.addFile = { [weak self] in self?.scroll.board.addFileCard(at: nil) }
        header.setMode = { [weak self] mode in self?.scroll.board.mode = mode }
        header.zoomIn = { [weak self] in self?.scroll.zoom(by: 1.25) }
        header.zoomOut = { [weak self] in self?.scroll.zoom(by: 1 / 1.25) }
        header.zoomToFit = { [weak self] in self?.scroll.zoomToFit() }
        header.zoomActualSize = { [weak self] in self?.scroll.zoomToActualSize() }
        header.pageBack = { [weak self] in self?.engagedCard?.goBack() }
        header.pageForward = { [weak self] in self?.engagedCard?.goForward() }
        header.pageReload = { [weak self] in self?.engagedCard?.reload() }
        header.pageHome = { [weak self] in self?.engagedCard?.goHome() }
        header.pageAdoptAddress = { [weak self] in self?.engagedCard?.adoptCurrentAddress() }
        header.findChanged = { [weak self] query in self?.search(query) }
        header.findClosed = { [weak self] in self?.closeFind() }
        header.leaveTiling = { [weak self] in self?.scroll.board.untile(animated: true) }
        header.findCommitted = { [weak self] in
            guard let self else { return }
            view.window?.makeFirstResponder(scroll.board)
        }
    }

    // MARK: Driving the page inside a card

    /// Back, forward, reload, home — and the address the page is actually on.
    ///
    /// In the window's chrome rather than on the card, and that is now the *only* place they could be:
    /// a card has no chrome to put them in. It was the right answer before that was true. On the card
    /// they were laid out over the page, which meant fighting the site for the one piece of a web page
    /// every site puts its own navigation in, at a size that had to be fought back from the zoom, in a
    /// corner the board also wanted for dragging.
    ///
    /// They appear only while a card is engaged. A board is not a browser, and a header carrying
    /// browser buttons for a board with nothing running on it would say otherwise.
    private var engagedCard: CanvasLinkNodeView? {
        scroll.board.engagedPageCard as? CanvasLinkNodeView
    }

    func pageStateChanged() {
        guard let card = engagedCard else {
            header.page = nil
            return
        }
        header.page = CanvasHeaderModel.Page(
            host: card.liveHost,
            savedAddress: card.address,
            wandered: card.hasWandered,
            canGoBack: card.canGoBack,
            canGoForward: card.canGoForward,
            age: card.loadedAt.map { canvasFreshnessLabel(for: $0) })
    }

    // MARK: Finding

    private var lastQuery: String { header.find.query }

    /// Run the query, and say when it found nothing.
    ///
    /// The count goes in the field's own trailing edge; only the empty result gets the banner, because
    /// that is the one outcome where the board itself shows you nothing and would otherwise look like a
    /// board that had simply lost your selection.
    private func search(_ query: String) {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            scroll.board.select([])
            header.find.summary = ""
            notice.dismiss()
            updateNotice()
            return
        }
        let found = scroll.board.find(query)
        header.find.summary = found.isEmpty ? "" : "\(found.count)"
        if found.isEmpty {
            notice.show(message: "Nothing on this canvas matches \u{201C}\(query)\u{201D}.",
                        kind: .informational, actionTitle: nil)
        } else {
            notice.dismiss()
            updateNotice()
        }
    }

    /// Close the field and drop the query with it — a selection you can no longer see the reason for is
    /// a selection you'll wonder about.
    private func closeFind() {
        header.find = CanvasHeaderModel.Find()
        scroll.board.select([])
        updateNotice()
        view.window?.makeFirstResponder(scroll.board)
    }

    /// Edit ▸ Find. AppKit's standard Find selector, told apart by the item's `tag` — the same
    /// convention the project window follows, so ⌘F means the same thing in both.
    ///
    /// The field grows out of the header's capsule rather than opening a bar of its own; ⌘F while it is
    /// already open re-focuses and selects, so a second press is "search again" rather than a no-op.
    @objc func performFindPanelAction(_ sender: Any?) {
        let action = (sender as? NSMenuItem).map { NSTextFinder.Action(rawValue: $0.tag) } ?? .showFindInterface
        switch action {
        case .showFindInterface:
            header.find.isShowing = true
            header.find.focusToken &+= 1
        case .nextMatch, .previousMatch:
            scroll.board.findNext(lastQuery)
        default:
            break
        }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == Selector(("undo:")) { return validateUndo(item, redoing: false) }
        if item.action == Selector(("redo:")) { return validateUndo(item, redoing: true) }
        guard item.action == #selector(performFindPanelAction(_:)) else { return true }
        switch NSTextFinder.Action(rawValue: item.tag) {
        case .showFindInterface: return true
        case .nextMatch, .previousMatch: return !lastQuery.isEmpty
        default: return false
        }
    }

    // MARK: Reacting

    private func documentChanged() {
        // The canvas is now the more recently edited of the two documents a board can hold — see
        // `CanvasBoardView.lastEditedProject`.
        scroll.board.lastEditedProject = nil
        scroll.board.documentChanged()
        updateNotice()
    }

    // MARK: Undo, on a board that can hold two kinds of document

    /// ⌘Z and ⇧⌘Z, routed to whichever document was edited last.
    ///
    /// A board holds a canvas — cards moved, resized, added — and it can hold project cards, whose edits
    /// belong to a `PMStore` and its own snapshot stack. Both are real documents with real histories,
    /// and the window can only hand back one `UndoManager`. So the routing is here, on the pane, which
    /// sits in the responder chain ahead of the window: it answers `undo:` itself and sends it to the
    /// right one.
    ///
    /// "Edited last" rather than "whatever has focus", because that is what a person means by ⌘Z. You
    /// tick a task, you press ⌘Z, and you expect the tick back — not the card you nudged before it.
    @objc func undo(_ sender: Any?) {
        if let project = scroll.board.lastEditedProject, project.canUndo { return project.undo() }
        store.undoManager.undo()
    }

    @objc func redo(_ sender: Any?) {
        if let project = scroll.board.lastEditedProject, project.canRedo { return project.redo() }
        store.undoManager.redo()
    }

    /// What the Edit menu says, and whether it says it at all.
    ///
    /// Named, because the two documents are answering the same key and the title is the only thing that
    /// can say which one it is about to act on: "Undo Complete Task" and "Undo Move Card" are the
    /// difference between a command you can trust and one you have to try.
    private func validateUndo(_ item: NSMenuItem, redoing: Bool) -> Bool {
        if let project = scroll.board.lastEditedProject, redoing ? project.canRedo : project.canUndo {
            item.title = redoing ? "Redo" : "Undo"
            return true
        }
        let manager = store.undoManager
        let can = redoing ? manager.canRedo : manager.canUndo
        item.title = redoing ? manager.redoMenuItemTitle : manager.undoMenuItemTitle
        return can
    }

    /// The header's quiet percentage. It used to read in the window's subtitle, which a hidden title
    /// takes with it.
    private func showZoom(_ zoom: CGFloat) {
        header.zoom = Double(zoom)
    }

    private func noteOutsideChange() {
        notice.show(message: "This canvas changed in another app. PM reloaded it.",
                    kind: .informational, actionTitle: nil)
    }

    /// How many cards point at a file that isn't where the canvas says.
    private var movedCards: [CanvasNode] {
        store.document.nodes.filter { node in
            guard case .file(let path, _) = node.content else { return false }
            return store.resolver.resolve(path).hasMoved
        }
    }

    @objc private func blockingHealthChanged() { updateNotice() }

    /// Dismissing the blocking warning keeps it dismissed for the life of this window. It is app-wide
    /// and there is nothing to do about it from here, so saying it again on the next redraw would be
    /// nagging rather than informing.
    private var hidBlockingNotice = false

    private func updateNotice() {
        let moved = movedCards.count
        if moved > 0 {
            return notice.show(message: moved == 1
                                   ? "1 card points at a file that has moved. PM is showing it from where it is now."
                                   : "\(moved) cards point at files that have moved. PM is showing them from where they are now.",
                               kind: .warning,
                               actionTitle: "Repair Paths")
        }
        // Second, because the moved-file warning is about *this* canvas and can be acted on, while
        // this one is about the app. It is still worth the space: a filtering failure looks exactly
        // like a page, so nothing else on screen would ever tell you.
        if let trouble = CanvasContentBlocker.trouble, !hidBlockingNotice {
            return notice.show(message: trouble, kind: .warning, actionTitle: nil)
        }
        notice.dismiss()
    }

    private func selectMovedCards() {
        let ids = Set(movedCards.map(\.id))
        scroll.board.select(ids)
        if let first = movedCards.first {
            scroll.centre(on: CanvasPoint(x: first.frame.midX, y: first.frame.midY))
        }
    }

    /// Rewrite every stale path in one step — undoable as one, because that is how it will be regretted
    /// if it is regretted at all.
    private func repairAllPaths() {
        let resolver = store.resolver
        store.change("Repair Card Paths") { doc in
            for index in doc.nodes.indices {
                guard case .file(let path, let subpath) = doc.nodes[index].content,
                      case .moved(let url, _) = resolver.resolve(path),
                      let corrected = resolver.storablePath(for: url) else { continue }
                doc.nodes[index].content = .file(path: corrected, subpath: subpath)
            }
        }
        notice.dismiss()
    }

    // MARK: Commands

    @objc private func zoomIn() { scroll.zoom(by: 1.25) }
    @objc private func zoomOut() { scroll.zoom(by: 1 / 1.25) }
    @objc private func zoomToFit() { scroll.zoomToFit() }

    /// A new card lands in the middle of what you're looking at, which is the only place you can be
    /// sure you'll see it.
    private var centreOfView: CanvasPoint {
        let visible = scroll.documentVisibleRect
        return scroll.board.canvasPoint(NSPoint(x: visible.midX, y: visible.midY))
    }

    @objc private func addTextCard() {
        let centre = centreOfView
        let node = CanvasNode(content: .text(""),
                              frame: CanvasRect(x: centre.x - 125, y: centre.y - 30,
                                                width: 250, height: 60))
        store.change("Add Card") { $0.nodes.append(node) }
        scroll.board.select([node.id])
        scroll.board.beginEditing(node.id)
    }

    @objc private func addFrame() {
        let centre = centreOfView
        let node = CanvasNode(content: .group(label: "Frame", background: nil, backgroundStyle: nil),
                              frame: CanvasRect(x: centre.x - 300, y: centre.y - 200,
                                                width: 600, height: 400))
        store.change("Add Frame") { $0.nodes.append(node) }
        scroll.board.select([node.id])
    }

    @objc private func addLink() { scroll.board.addLinkCard(at: nil) }

    @objc private func addFile() { scroll.board.addFileCard(at: nil) }

    // MARK: A board nobody is looking at

    private var idleTimer: Timer?

    /// How long a board goes on running its pages after you have looked away.
    ///
    /// Not immediately, and that is the whole design of the number: switching to your editor to check
    /// something and switching straight back is the single most common thing that happens to a
    /// dashboard, and a board that tore down eight renderers each time would spend the day rebuilding
    /// them — costing more than it saved and making every glance back a reload. Two minutes is long
    /// enough to cover going away and coming back, and short enough that a board left open behind your
    /// work isn't quietly running a browser all afternoon.
    private static let idleGrace: TimeInterval = 120

}
