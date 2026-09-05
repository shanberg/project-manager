import AppKit
import UniformTypeIdentifiers
import PmLib

/// A window on one canvas.
///
/// Its own window rather than a mode of the project window: a board wants the whole frame and a
/// project window is already a split view with a task list in it. Tabbable, so several boards stack
/// the way several projects do, and one window per file — asking for a canvas that is already open
/// brings its window forward rather than opening a second view of the same document.
@MainActor
final class CanvasWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate,
                                    NSMenuItemValidation {
    let store: CanvasDocumentStore
    private let scroll: CanvasScrollView
    private let bar: CanvasFloatingBar
    private let notice = CanvasNoticeBar()
    private let container = NSView()

    private var zoomLabel: NSTextField?
    private var modeControl: NSSegmentedControl?
    private var searchField: NSSearchField?

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
        bar = CanvasFloatingBar(scroll: scroll)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 720),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = url.deletingPathExtension().lastPathComponent
        window.representedURL = url
        window.contentMinSize = NSSize(width: 480, height: 360)
        window.tabbingIdentifier = "PMCanvas"
        window.tabbingMode = .automatic
        window.setFrameAutosaveName("PMCanvasWindow")
        super.init(window: window)

        undoManagerForWindow = undo
        window.delegate = self
        buildContent()
        buildToolbar()
        scroll.board.onPageStateChanged = { [weak self] in self?.pageStateChanged() }
        scroll.board.onModeChanged = { [weak self] in
            guard let self else { return }
            // The mode can now be flipped from the menu as well as the toolbar, so the segmented
            // control follows the board rather than being the only thing that knows.
            modeControl?.selectedSegment = scroll.board.mode == .edit ? 1 : 0
            bar.follow(board: scroll.board)
        }

        store.onChange = { [weak self] in self?.documentChanged() }
        store.onReloadedFromDisk = { [weak self] in self?.noteOutsideChange() }
        store.startWatching()

        scroll.board.onSelectionChanged = { [weak self] _ in self?.selectionChanged() }
        scroll.onZoomChanged = { [weak self] zoom in
            self?.showZoom(zoom)
            self?.bar.follow(board: self!.scroll.board)
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(scrolled),
            name: NSView.boundsDidChangeNotification, object: scroll.contentView)
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

    private func buildContent() {
        container.translatesAutoresizingMaskIntoConstraints = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        notice.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(notice)
        container.addSubview(scroll)
        scroll.addSubview(bar)

        NSLayoutConstraint.activate([
            notice.topAnchor.constraint(equalTo: container.topAnchor),
            notice.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            notice.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: notice.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        window?.contentView = container

        notice.onRepairAll = { [weak self] in self?.repairAllPaths() }
        notice.onReveal = { [weak self] in self?.selectMovedCards() }
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        // Fitted after the window has a size, or "fit" is computed against a zero-width clip view.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            scroll.zoomToFit()
            showZoom(scroll.magnification)
            window?.makeFirstResponder(scroll.board)
        }
    }

    // MARK: Toolbar

    /// A small default set, and the Mac's own answer to anyone who disagrees with it.
    ///
    /// Customisation is the point rather than a nicety. Every command up here also lives in the menu
    /// bar or a card's contextual menu, so the toolbar is a convenience layer, and which conveniences
    /// are worth permanent screen on a board full of cards is a judgement only the person reading the
    /// board can make. Ship few, allow all, remember the choice.
    private func buildToolbar() {
        let toolbar = NSToolbar(identifier: "PMCanvasToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        window?.toolbar = toolbar
        window?.toolbarStyle = .unified
    }

    private enum Item {
        static let zoom = NSToolbarItem.Identifier("zoom")
        static let fit = NSToolbarItem.Identifier("fit")
        static let mode = NSToolbarItem.Identifier("mode")
        static let add = NSToolbarItem.Identifier("add")
        static let search = NSToolbarItem.Identifier("search")
        static let page = NSToolbarItem.Identifier("page")
    }

    /// Zoom and Fit are deliberately not here. Both are in the View menu with the shortcuts a Mac user
    /// already has in their hands — ⌘+, ⌘−, ⌘0 — the trackpad zooms by pinch, and the percentage now
    /// reads in the window's subtitle, which is where a document says what state it is in. Two toolbar
    /// items were spending permanent space to duplicate all of that. Anyone who wants them back is one
    /// Customize Toolbar away.
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Item.mode, Item.add, Item.search]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Item.zoom, Item.fit, Item.mode, Item.add, Item.search, Item.page,
         .flexibleSpace, .space]
    }

    // MARK: Driving the page inside a card

    /// Back, forward, reload and home for the web card you have stepped into.
    ///
    /// In the window's toolbar rather than on the card, and that is the second answer to where these
    /// go. On the card they were laid out over the page — which meant fighting the site for the one
    /// piece of a web page every site puts its own navigation in, at a size that had to be fought back
    /// from the zoom, in a corner the board also wanted for dragging. The window frame has room that
    /// belongs to PM, needs no compensation, and is where a Mac app's controls live anyway.
    ///
    /// They appear only while a card is engaged. A board is not a browser, and a toolbar carrying
    /// browser buttons for a board with nothing running on it would say otherwise.
    private var pageControls: NSStackView?
    private var pageBack: NSButton?
    private var pageForward: NSButton?
    private var pageHome: NSButton?

    private var enagedCard: CanvasLinkNodeView? {
        scroll.board.engagedPageCard as? CanvasLinkNodeView
    }

    /// Put the controls in the toolbar, or take them out — rather than leaving a disabled row of
    /// buttons sitting there for the entire time you are not using a page.
    func pageStateChanged() {
        let card = enagedCard
        if let toolbar = window?.toolbar {
            let present = toolbar.items.firstIndex { $0.itemIdentifier == Item.page }
            if card != nil, present == nil {
                toolbar.insertItem(withItemIdentifier: Item.page, at: toolbar.items.count)
            } else if card == nil, let present {
                toolbar.removeItem(at: present)
            }
        }
        pageBack?.isEnabled = card?.canGoBack ?? false
        pageForward?.isEnabled = card?.canGoForward ?? false
        pageHome?.isEnabled = card?.hasWandered ?? false
    }

    @objc private func pageGoBack() { enagedCard?.goBack() }
    @objc private func pageGoForward() { enagedCard?.goForward() }
    @objc private func pageReload() { enagedCard?.reload() }
    @objc private func pageGoHome() { enagedCard?.goHome() }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: identifier)
        switch identifier {
        case Item.zoom:
            let out = NSButton(image: NSImage(systemSymbolName: "minus.magnifyingglass",
                                              accessibilityDescription: "Zoom Out")!,
                               target: self, action: #selector(zoomOut))
            let label = NSTextField(labelWithString: "100%")
            label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            label.textColor = .secondaryLabelColor
            label.alignment = .center
            label.widthAnchor.constraint(equalToConstant: 42).isActive = true
            zoomLabel = label
            let inn = NSButton(image: NSImage(systemSymbolName: "plus.magnifyingglass",
                                              accessibilityDescription: "Zoom In")!,
                               target: self, action: #selector(zoomIn))
            for button in [out, inn] { button.bezelStyle = .texturedRounded; button.isBordered = false }
            let stack = NSStackView(views: [out, label, inn])
            stack.orientation = .horizontal
            stack.spacing = 2
            item.view = stack
            item.label = "Zoom"

        case Item.page:
            func button(_ symbol: String, _ help: String, _ action: Selector) -> NSButton {
                let button = NSButton(image: NSImage(systemSymbolName: symbol,
                                                     accessibilityDescription: help)!,
                                      target: self, action: action)
                button.bezelStyle = .texturedRounded
                button.toolTip = help
                return button
            }
            let back = button("chevron.left", "Back", #selector(pageGoBack))
            let forward = button("chevron.right", "Forward", #selector(pageGoForward))
            let reload = button("arrow.clockwise", "Reload", #selector(pageReload))
            let home = button("house", "Back to this card\u{2019}s page", #selector(pageGoHome))
            pageBack = back
            pageForward = forward
            pageHome = home
            let stack = NSStackView(views: [back, forward, reload, home])
            stack.orientation = .horizontal
            stack.spacing = 2
            pageControls = stack
            item.view = stack
            item.label = "Page"
            // The item is inserted the moment a card is engaged, so its buttons have to arrive already
            // agreeing with that card rather than waiting for the next thing to happen.
            DispatchQueue.main.async { [weak self] in self?.pageStateChanged() }

        case Item.fit:
            item.view = NSButton(title: "Fit", target: self, action: #selector(zoomToFit))
            (item.view as? NSButton)?.bezelStyle = .texturedRounded
            item.label = "Fit"

        case Item.mode:
            // The mode the whole interaction model turns on. Two words rather than a switch, because
            // "Edit" has to be readable at a glance — the connection dots appearing is a big enough
            // change to the board that you should never be unsure which mode you're in.
            let control = NSSegmentedControl(labels: ["View", "Edit"],
                                             trackingMode: .selectOne,
                                             target: self, action: #selector(modeChanged(_:)))
            control.selectedSegment = 0
            control.setToolTip("Reading: cards and lines, nothing else", forSegment: 0)
            control.setToolTip("Editing: cards offer the dots you drag lines from", forSegment: 1)
            modeControl = control
            item.view = control
            item.label = "Mode"

        case Item.add:
            let button = NSPopUpButton(frame: .zero, pullsDown: true)
            button.bezelStyle = .texturedRounded
            button.imagePosition = .imageOnly
            let menu = NSMenu()
            menu.addItem(NSMenuItem())  // the pull-down's own title slot
            menu.addItem(withTitle: "Card", action: #selector(addTextCard), keyEquivalent: "")
            menu.addItem(withTitle: "Frame", action: #selector(addFrame), keyEquivalent: "")
            menu.addItem(withTitle: "Link…", action: #selector(addLink), keyEquivalent: "")
            menu.addItem(withTitle: "File…", action: #selector(addFile), keyEquivalent: "")
            for entry in menu.items { entry.target = self }
            button.menu = menu
            button.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add")
            item.view = button
            item.label = "Add"

        case Item.search:
            let field = NSSearchField()
            field.placeholderString = "Find on canvas"
            field.sendsSearchStringImmediately = false
            field.sendsWholeSearchString = false
            field.target = self
            field.action = #selector(searchChanged(_:))
            field.widthAnchor.constraint(equalToConstant: 170).isActive = true
            searchField = field
            item.view = field
            item.label = "Find"

        default:
            return nil
        }
        return item
    }

    // MARK: Finding

    private var lastQuery: String { searchField?.stringValue ?? "" }

    @objc private func searchChanged(_ sender: NSSearchField) {
        let query = sender.stringValue
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            scroll.board.select([])
            notice.dismiss()
            updateNotice()
            return
        }
        let found = scroll.board.find(query)
        if found.isEmpty {
            notice.show(message: "Nothing on this canvas matches \u{201C}\(query)\u{201D}.",
                        kind: .informational, actionTitle: nil)
        } else {
            notice.dismiss()
            updateNotice()
        }
    }

    /// Edit ▸ Find. AppKit's standard Find selector, told apart by the item's `tag` — the same
    /// convention the project window follows, so ⌘F means the same thing in both.
    @objc func performFindPanelAction(_ sender: Any?) {
        let action = (sender as? NSMenuItem).map { NSTextFinder.Action(rawValue: $0.tag) } ?? .showFindInterface
        switch action {
        case .showFindInterface:
            window?.makeFirstResponder(searchField)
            searchField?.selectText(nil)
        case .nextMatch:
            scroll.board.findNext(lastQuery)
        case .previousMatch:
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
        bar.follow(board: scroll.board)
        updateNotice()
    }

    private func selectionChanged() {
        bar.follow(board: scroll.board)
    }

    @objc private func scrolled() {
        bar.follow(board: scroll.board)
    }

    /// Where a document says what state it is in. The toolbar's own readout is still fed, for anyone
    /// who has added that item back.
    private func showZoom(_ zoom: CGFloat) {
        let reading = "\(Int((zoom * 100).rounded()))%"
        window?.subtitle = reading == "100%" ? "" : reading
        zoomLabel?.stringValue = reading
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

    @objc private func modeChanged(_ sender: NSSegmentedControl) {
        scroll.board.mode = sender.selectedSegment == 1 ? .edit : .view
    }

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
