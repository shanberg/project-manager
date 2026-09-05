import AppKit
import SwiftUI
import UniformTypeIdentifiers
import PmLib

/// A window on one canvas.
///
/// A board wants the whole frame, so it gets one — full-size content under a hidden titlebar, with the
/// window's controls floating over the board instead of occupying a bar across the top of it. That is
/// the project window's chrome, and using it here rather than something like it is the point: a canvas
/// is a document window in the same app and shouldn't be a second idea of what a window looks like.
/// See `CanvasHeaderModel`.
///
/// Tabbable, so several boards stack the way several projects do, and one window per file — asking for
/// a canvas that is already open brings its window forward rather than opening a second view of the
/// same document.
@MainActor
final class CanvasWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    let store: CanvasDocumentStore
    private let scroll: CanvasScrollView
    private let notice = CanvasNoticeBar()
    private let container = NSView()

    /// Everything the header shows and everything its controls do.
    private let header = CanvasHeaderModel()
    private var pill: NSHostingView<CanvasTitlePill>!
    private var capsule: NSHostingView<CanvasControlCapsule>!

    /// Every open canvas, by the file it shows.
    private static var open: [URL: CanvasWindowController] = [:]

    // MARK: Opening

    /// Show `url`, or bring its window forward if it's already up.
    ///
    /// A canvas that won't parse is reported here rather than opening an empty window: an empty board
    /// and a broken file look identical, and only one of them is something you can fix.
    @discardableResult
    static func open(url: URL) -> CanvasWindowController? {
        let key = url.standardizedFileURL
        if let existing = open[key] {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            return existing
        }
        do {
            let controller = try CanvasWindowController(url: key)
            Log.write("canvas opened: \(key.lastPathComponent) "
                + "nodes=\(controller.store.document.nodes.count) "
                + "edges=\(controller.store.document.edges.count)")
            open[key] = controller
            controller.showWindow(nil)
            controller.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return controller
        } catch {
            Log.write("canvas open failed: \(key.lastPathComponent): \(error)")
            let alert = NSAlert()
            alert.messageText = "Couldn't open \(url.lastPathComponent)."
            alert.informativeText = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
            return nil
        }
    }

    /// Open a project's own canvas, making it if the project hasn't got one yet.
    ///
    /// Here rather than in either caller because the header button and File ▸ Project Canvas are the
    /// same errand reached two ways, and the half worth not duplicating is the failure: creating the
    /// board writes a file, so a refusal has to be *said*, not logged. Silence and a window that
    /// didn't appear is the one outcome that leaves you with nothing to act on.
    static func openProjectCanvas(for store: PMStore) {
        store.openableCanvasPath { result in
            switch result {
            case .success(let path):
                open(url: URL(fileURLWithPath: path))
            case .failure(let error):
                let alert = NSAlert()
                alert.messageText = "Couldn't open the project canvas."
                alert.informativeText = (error as? LocalizedError)?.errorDescription
                    ?? String(describing: error)
                alert.alertStyle = .warning
                alert.runModal()
            }
        }
    }

    /// The open panel behind File ▸ Open Canvas.
    static func runOpenPanel() {
        let panel = NSOpenPanel()
        // By extension rather than by the declared type: `md.obsidian.canvas` is only *imported* by
        // PM, so on a Mac without Obsidian installed it may not be registered at all, and a panel
        // filtered on an unregistered type shows nothing openable.
        if let canvas = UTType(filenameExtension: "canvas") {
            panel.allowedContentTypes = [canvas]
        }
        panel.allowsMultipleSelection = true
        panel.message = "Choose an Obsidian canvas."
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { open(url: url) }
    }

    // MARK: Building

    private init(url: URL) throws {
        let undo = UndoManager()
        store = try CanvasDocumentStore(url: url, undoManager: undo)
        scroll = CanvasScrollView(store: store)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 720),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable,
                                          .fullSizeContentView],
                              backing: .buffered, defer: false)
        // The project window's chrome, for the same reasons and by the same route: no visible title, no
        // toolbar in the UI sense, content running to the top of the frame. The title is still *set* —
        // `titleVisibility` only hides it from the titlebar, while window tabs, the Window menu and ⌘`
        // all keep reading it, and `representedURL` still gives the proxy icon its file.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = url.deletingPathExtension().lastPathComponent
        window.representedURL = url
        window.contentMinSize = NSSize(width: 480, height: 360)
        window.tabbingIdentifier = "PMCanvas"
        window.tabbingMode = .automatic
        window.setFrameAutosaveName("PMCanvasWindow")
        // An empty toolbar, purely for its geometry — the taller unified titlebar and the lower,
        // further-inset traffic lights that go with it. Exactly the arrangement `ProjectWindowController`
        // explains at length; it has no delegate and so no items, and customization is off, so there is
        // nothing here for anyone to find or toggle.
        let toolbar = NSToolbar(identifier: "PMCanvasTitlebar")
        toolbar.allowsUserCustomization = false
        toolbar.showsBaselineSeparator = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        super.init(window: window)

        undoManagerForWindow = undo
        window.delegate = self
        header.title = window.title
        wireHeader()
        buildContent()
        scroll.board.onPageStateChanged = { [weak self] in self?.pageStateChanged() }
        scroll.board.onModeChanged = { [weak self] in
            guard let self else { return }
            // The mode is flipped from the View menu and from the header's options, so the header
            // follows the board rather than being the only thing that knows.
            header.mode = scroll.board.mode
        }

        store.onChange = { [weak self] in self?.documentChanged() }
        store.onReloadedFromDisk = { [weak self] in self?.noteOutsideChange() }
        store.startWatching()

        scroll.onZoomChanged = { [weak self] zoom in self?.showZoom(zoom) }
        // Filtering is verified after launch, which is usually after this window exists.
        NotificationCenter.default.addObserver(
            self, selector: #selector(blockingHealthChanged),
            name: CanvasContentBlocker.healthChanged, object: nil)
        notice.onDismissedByUser = { [weak self] in self?.hidBlockingNotice = true }

        updateNotice()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { NotificationCenter.default.removeObserver(self) }

    /// The window's own undo stack. Held here so ⌘Z reaches the board's changes rather than whatever
    /// text field last had focus.
    private var undoManagerForWindow: UndoManager?

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { undoManagerForWindow }

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
        window?.contentView = container

        notice.onRepairAll = { [weak self] in self?.repairAllPaths() }
        notice.onReveal = { [weak self] in self?.selectMovedCards() }
    }

    private var pillLeading: NSLayoutConstraint!

    /// Keep the header level with, and clear of, the window's own buttons.
    ///
    /// The vertical drop is the header's business (see `TitlebarDrop`), because it depends on how tall
    /// each piece turns out to be. The leading inset is the window's, because it depends on where the
    /// traffic lights are — and in full screen there aren't any, so the pill moves back to the edge.
    private func measureTitlebar() {
        guard let metrics = window?.titlebarButtonMetrics() else { return }
        if abs(pillLeading.constant - metrics.leadingInset) > 0.5 {
            pillLeading.constant = metrics.leadingInset
        }
        if header.titlebar != metrics { header.titlebar = metrics }
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        // Forces the theme frame to place its buttons, which is what makes them measurable before the
        // first frame is drawn — otherwise the header lays out against the starting guess and visibly
        // settles onto the real numbers as the window opens.
        window?.layoutIfNeeded()
        measureTitlebar()
        // Fitted after the window has a size, or "fit" is computed against a zero-width clip view.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            scroll.zoomToFit()
            showZoom(scroll.magnification)
            window?.makeFirstResponder(scroll.board)
        }
    }

    // The traffic lights move when the titlebar's height changes and disappear in full screen, and the
    // header follows them rather than holding whatever it measured at construction.
    func windowDidResize(_ notification: Notification) { measureTitlebar() }
    func windowDidEnterFullScreen(_ notification: Notification) { measureTitlebar() }
    func windowDidExitFullScreen(_ notification: Notification) { measureTitlebar() }

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
        header.findCommitted = { [weak self] in
            guard let self else { return }
            window?.makeFirstResponder(scroll.board)
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
        window?.makeFirstResponder(scroll.board)
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
        guard item.action == #selector(performFindPanelAction(_:)) else { return true }
        switch NSTextFinder.Action(rawValue: item.tag) {
        case .showFindInterface: return true
        case .nextMatch, .previousMatch: return !lastQuery.isEmpty
        default: return false
        }
    }

    // MARK: Reacting

    private func documentChanged() {
        scroll.board.documentChanged()
        updateNotice()
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

    // MARK: Closing

    func windowWillClose(_ notification: Notification) {
        idleTimer?.invalidate()
        idleTimer = nil
        scroll.board.pauseAllPages()
        store.stopWatching()
        store.save()
        Self.open.removeValue(forKey: store.url)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        idleTimer?.invalidate()
        idleTimer = nil
        scroll.board.reviewPageBudget()
        store.checkForOutsideChange()
    }

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

    func windowDidResignKey(_ notification: Notification) {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: Self.idleGrace, repeats: false) { _ in
            Task { @MainActor [weak self] in self?.scroll.board.pauseAllPages() }
        }
    }
}
