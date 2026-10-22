import AppKit
import PmLib
import SwiftUI
import WebKit

/// A tile moved out into a window of its own — a satellite of the workspace it came from. Any kind of
/// card, and a tile of tabs comes out as a window of tabs.
///
/// **For what has to stay up while you work beside it**: a call, a huddle, a dashboard on the other
/// screen, the note you are writing from. A tile is always a share of the window it's in; a satellite
/// is a card you can put anywhere, at any size, and still have belong to the workspace — switching to
/// another workspace puts it away, and coming back brings it out again where it was. See
/// `CanvasBoardView.restoreSatellites`.
///
/// **The content is lent, not given.** Each card goes on owning what it shows — its page, its models,
/// its store — and on being the card the board knows; what moves is the view (`CanvasNodeView.lend`).
/// So a page doesn't reload either way, a note keeps its undo, and anything the card rebuilds while it
/// is out arrives here (`replace`). The card is stepped into while its window is the key one, which is
/// what lets a note be written in and a list take its keys.
///
/// **A lean header** rather than a browser's: the project's icon, the tabs (or the one card's title),
/// Back and Reload when a page is showing, and the way home. AppKit controls rather than SwiftUI ones,
/// since the header sits in the title bar's drag band and only controls carve their clicks out of it.
///
/// **Dressed as its project**, so a window on another screen still says where it belongs: the header
/// lies on the project's colour and texture — the wash its board lies on, `CanvasColorWash` — and the
/// project's icon leads, its tooltip the project's name.
@MainActor
final class CanvasSatelliteWindow: NSWindowController, NSWindowDelegate {
    /// Every satellite up, in every window.
    private(set) static var open: [CanvasSatelliteWindow] = []

    private(set) weak var board: CanvasBoardView?
    /// The cards whose content is out here, in tab order.
    private(set) var cards: [CanvasNodeView] = []
    private(set) var shown = 0
    /// Where it is remembered: the canvas and the workspace it belongs to.
    let canvas: URL
    let workspace: String

    var cardIDs: [String] { cards.map(\.node.id) }
    var shownCard: CanvasNodeView? { cards.indices.contains(shown) ? cards[shown] : nil }

    /// The web page showing, for Back and Reload and the host — nil when the tab showing isn't a page.
    var page: WKWebView? { (shownCard as? CanvasLinkNodeView)?.livePage }

    /// Set while the window is going away because its workspace is — which puts it away rather than
    /// sending it home, so it comes back with the workspace.
    private var puttingAway = false
    /// Set while the window is going because Bring Back was asked for — which brings the workspace's
    /// window back with it. Closing it with its close button doesn't: see `satelliteReturned`.
    private var bringingBack = false
    private let stage = NSView()
    private let wash = CanvasColorWash()
    /// The project's icon, drawn once into a picture: a hosted SwiftUI view in an AppKit row sizes and
    /// places itself by rules of its own, and this only ever needs to be a picture.
    private let mark = NSImageView()
    private var markWidth: NSLayoutConstraint?
    private let titleLabel = NSTextField(labelWithString: "")
    private let hostLabel = NSTextField(labelWithString: "")
    /// The workspace's name, after the card's: windows from two workspaces of one project share its
    /// colour, and this is what tells them apart.
    private let workspaceLabel = NSTextField(labelWithString: "")
    private let bringBack = NSButton()
    private let gather = NSButton()
    private let tabs = CanvasSatelliteTabs()
    private var barHeight: NSLayoutConstraint?
    private var backLeading: NSLayoutConstraint?
    /// The title's room on the leading side: clear of Back and Reload when a page shows them, clear of
    /// the traffic lights alone when not. One of the two is on — see `describe`.
    private var clearOfLights: NSLayoutConstraint?
    private var clearOfPage: NSLayoutConstraint?
    private let back = NSButton()
    private let reload = NSButton()
    private var pageWatches: [NSKeyValueObservation] = []
    private var linkPress: URL?
    private var linkMonitor: Any?
    /// The project's name, colour and icon, as the header draws them — and the dock, which groups
    /// satellites by workspace and wants each group dressed as its project.
    private(set) var projectTitle: String?
    var projectColor: NSColor? { wash.color?.nsColor }
    var projectMark: NSImage? { mark.image }
    /// The project's icon itself, for the dock to draw at its own size and in its own colour.
    private(set) var projectMarkIcon: ProjectIcon?

    static let headerHeight: CGFloat = 28

    /// Whether the next undo (or redo) in `window` would take away a card that is out in a satellite,
    /// closing its window: the step on top of the stack says what document it would put back
    /// (`CanvasUndoStep`), and a card out here that isn't in it is a window that goes. For
    /// `PageFirstMenu`, which then asks for the key twice.
    static func undoClosesWindows(undoing: Bool, in window: NSWindow?) -> Bool {
        guard let window, let manager = (window.firstResponder ?? window).undoManager else { return false }
        let value = undoing ? manager.undoActionUserInfoValue(forKey: CanvasDocumentStore.undoStepKey)
            : manager.redoActionUserInfoValue(forKey: CanvasDocumentStore.undoStepKey)
        guard let step = value as? CanvasUndoStep, let store = step.store else { return false }
        let kept = Set(step.document.nodes.map(\.id))
        return open.contains { $0.canvas == store.url && $0.cardIDs.contains { !kept.contains($0) } }
    }

    /// Lend `cards` to a new window. Nil when none of them had anything to lend.
    static func open(_ cards: [CanvasNodeView], showing: String?, frame: NSRect?, on board: CanvasBoardView)
        -> CanvasSatelliteWindow? {
        let satellite = CanvasSatelliteWindow(board: board, frame: frame)
        for card in cards { satellite.take(card) }
        guard !satellite.cards.isEmpty else { return nil }
        open.append(satellite)
        satellite.showTab(satellite.cards.firstIndex { $0.node.id == showing } ?? 0)
        satellite.refreshAppearance()
        if frame == nil { satellite.window?.center() }
        satellite.showWindow(nil)
        satellite.remember()
        return satellite
    }

    private init(board: CanvasBoardView, frame: NSRect?) {
        self.board = board
        canvas = board.store.url
        workspace = board.satelliteScope
        let window = NSWindow(contentRect: frame ?? NSRect(x: 0, y: 0, width: 760, height: 620),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        if let frame { window.setFrame(frame, display: false) }
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 320, height: 240)
        window.tabbingMode = .disallowed
        // **A plain title bar, no toolbar**: the header is the title bar's own height, the shortest a
        // window's top can be. It sat in an empty compact toolbar's taller band, which centred the lights
        // in 38 points — a satellite is a card on its own, and its top was taking more than a tile's.
        // See `fitToTitleBar`.
        super.init(window: window)
        window.delegate = self
        window.contentView = content()
        fitToTitleBar()
        watchLinks()
        watchHover()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Cards

    /// Borrow a card's content and add it as a tab.
    private func take(_ card: CanvasNodeView) {
        card.prepareToLend()
        // One of the tabs before it is lent: lending can rebuild the content (a card zoomed out to its
        // name comes out as itself), and a rebuild arriving for a card this window didn't know was
        // placed hidden, as a tab behind another.
        cards.append(card)
        guard let content = card.lend(to: self) else {
            cards.removeLast()
            return
        }
        if content.superview !== stage { place(content) }
    }

    private func place(_ content: NSView) {
        content.translatesAutoresizingMaskIntoConstraints = false
        stage.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: stage.topAnchor),
            content.leadingAnchor.constraint(equalTo: stage.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: stage.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: stage.bottomAnchor),
        ])
    }

    /// A lent card has rebuilt its content: the new view goes where the old one was.
    func replace(_ old: NSView?, with new: NSView, for card: CanvasNodeView) {
        old?.removeFromSuperview()
        place(new)
        new.isHidden = cards.count > 1 && card !== shownCard
        if card === shownCard { watchPage() }
        describe()
    }

    /// Something about a card changed that the header shows — its page, its title.
    func cardChanged(_ card: CanvasNodeView) {
        if card === shownCard { watchPage() }
        describe()
    }

    /// A card has gone from the board while it was out here. Its tab goes; the last one takes the
    /// window with it, and nothing is left to remember.
    func drop(_ card: CanvasNodeView) {
        guard let index = cards.firstIndex(where: { $0 === card }) else { return }
        let first = cardIDs.first ?? ""
        card.takeBack()
        cards.remove(at: index)
        guard !cards.isEmpty else {
            CanvasSatellites.forget(first, canvas: canvas, workspace: workspace)
            puttingAway = true
            close()
            return
        }
        if first != cardIDs.first { CanvasSatellites.forget(first, canvas: canvas, workspace: workspace) }
        showTab(min(shown, cards.count - 1))
        CanvasSatelliteDock.shared.refresh()
    }

    /// This window as a tile of `session`, for Gather: its cards, the one showing, and the side its
    /// tabs were on.
    func tile(in session: CanvasTileSession) -> CanvasTiling.Tile {
        let ids = cardIDs.filter(session.cards.contains)
        let showing = shownCard.flatMap { ids.firstIndex(of: $0.node.id) } ?? 0
        return CanvasTiling.Tile(ids, showing: showing, tabsOnSide: ids.first.map(session.tabsOnSide) ?? false)
    }

    /// Show — from the card's slot, or the dock: this window forward, at the card's tab.
    func reveal(_ card: CanvasNodeView) {
        if let index = cards.firstIndex(where: { $0 === card }), index != shown { showTab(index) }
        window?.makeKeyAndOrderFront(nil)
    }

    /// Bring Back — from the card's slot: the card home, into the slot it kept. The window's last card
    /// takes the window with it; one of several leaves its tab, and the rest stay out.
    func giveBack(_ card: CanvasNodeView) {
        guard cards.contains(where: { $0 === card }) else { return }
        guard cards.count > 1 else { return returnToWorkspace() }
        let id = card.node.id
        let first = cardIDs.first ?? ""
        card.takeBack()
        cards.removeAll { $0 === card }
        if first != cardIDs.first { CanvasSatellites.forget(first, canvas: canvas, workspace: workspace) }
        showTab(min(shown, cards.count - 1))
        board?.satelliteReturned([id], showing: id, from: workspace, raisingWindow: true)
        CanvasSatelliteDock.shared.refresh()
    }

    private func showTab(_ index: Int) {
        let leaving = shownCard
        shown = max(0, min(index, cards.count - 1))
        for (i, card) in cards.enumerated() { card.cardContent?.isHidden = i != shown }
        if leaving !== shownCard, leaving?.isEngaged == true { leaving?.engage(false) }
        if window?.isKeyWindow == true { shownCard?.engage(true) }
        watchPage()
        describe()
        remember()
    }

    // MARK: The window

    private func content() -> NSView {
        let root = NSView()
        // A plain view holds the controls, with the wash behind them: the wash is a board's ground,
        // which takes no clicks (`CanvasColorWash.hitTest`), and controls inside it would take none
        // either — Return, Back and the tabs drawn but dead.
        let bar = NSView()
        // Clipped, both: the wash fills whatever it is asked to redraw, and a view isn't clipped to its
        // bounds unless it says so — on a board it lies under everything, but here it is in front of
        // the page and painted the board's ground over all of it.
        bar.clipsToBounds = true
        wash.clipsToBounds = true
        wash.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(wash)
        NSLayoutConstraint.activate([
            wash.topAnchor.constraint(equalTo: bar.topAnchor), wash.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
            wash.leadingAnchor.constraint(equalTo: bar.leadingAnchor), wash.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
        ])
        let line = NSBox()
        line.boxType = .separator

        configure(back, "chevron.backward", "Back", #selector(goBack))
        configure(reload, "arrow.clockwise", "Reload", #selector(reloadPage))
        configure(bringBack, "arrow.down.left", "Bring Back to Workspace", #selector(returnToWorkspace))
        configure(gather, "rectangle.grid.2x2", "Gather Workspace", #selector(gatherWorkspace))
        showButtons(false)
        let home = NSStackView(views: [gather, bringBack])
        home.spacing = 0

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        // The title gives way first: the host is the half that says whose page this is.
        titleLabel.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
        hostLabel.font = .systemFont(ofSize: 12)
        hostLabel.textColor = .secondaryLabelColor
        hostLabel.lineBreakMode = .byTruncatingMiddle
        hostLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        workspaceLabel.font = .systemFont(ofSize: 12)
        workspaceLabel.textColor = .secondaryLabelColor
        workspaceLabel.lineBreakMode = .byTruncatingTail
        workspaceLabel.setContentCompressionResistancePriority(.defaultLow - 2, for: .horizontal)
        mark.translatesAutoresizingMaskIntoConstraints = false
        let markWidth = mark.widthAnchor.constraint(equalToConstant: 16)
        self.markWidth = markWidth
        NSLayoutConstraint.activate([markWidth, mark.heightAnchor.constraint(equalToConstant: 16)])
        tabs.onSelect = { [weak self] in self?.showTab($0) }
        tabs.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
        let words = NSStackView(views: [mark, titleLabel, hostLabel, tabs, workspaceLabel])
        words.orientation = .horizontal
        words.alignment = .centerY
        words.spacing = 6
        words.setCustomSpacing(8, after: mark)

        for view in [bar, line, back, reload, home, words, stage] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        root.addSubview(stage)
        root.addSubview(bar)
        for view in [line, back, reload, home, words] as [NSView] { bar.addSubview(view) }
        // Clear of the traffic lights, which sit at the leading edge of the title bar; measured again once
        // the window has its title bar (`fitToTitleBar`).
        let lights: CGFloat = 78
        let barHeight = bar.heightAnchor.constraint(equalToConstant: Self.headerHeight)
        let backLeading = back.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: lights)
        self.barHeight = barHeight
        self.backLeading = backLeading
        let centred = words.centerXAnchor.constraint(equalTo: bar.centerXAnchor)
        centred.priority = .defaultLow
        let clearOfLights = words.leadingAnchor.constraint(greaterThanOrEqualTo: back.leadingAnchor, constant: 4)
        let clearOfPage = words.leadingAnchor.constraint(greaterThanOrEqualTo: reload.trailingAnchor, constant: 8)
        clearOfLights.isActive = true
        self.clearOfLights = clearOfLights
        self.clearOfPage = clearOfPage
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: root.topAnchor),
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            barHeight,
            line.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            line.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
            backLeading,
            back.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            reload.leadingAnchor.constraint(equalTo: back.trailingAnchor, constant: 2),
            reload.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            home.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -10),
            home.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            centred,
            words.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            words.trailingAnchor.constraint(lessThanOrEqualTo: home.leadingAnchor, constant: -6),
            stage.topAnchor.constraint(equalTo: bar.bottomAnchor),
            stage.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stage.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stage.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        return root
    }

    private func configure(_ button: NSButton, _ symbol: String, _ label: String, _ action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.target = self
        button.action = action
        button.toolTip = label
        button.bezelStyle = .accessoryBarAction
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.symbolConfiguration = .init(pointSize: 13, weight: .regular)
        button.contentTintColor = .secondaryLabelColor
        // Sized for the plain title bar's 28 points, with room above and below.
        button.widthAnchor.constraint(equalToConstant: 26).isActive = true
        button.heightAnchor.constraint(equalToConstant: 22).isActive = true
    }

    /// One tab per card, when there is more than one: its icon and name. See `CanvasSatelliteTabs`.
    private func rebuildTabs() {
        guard cards.count > 1 else {
            tabs.show([], selected: 0)
            tabs.isHidden = true
            return
        }
        tabs.isHidden = false
        tabs.show(cards.map { card in
            let described = board?.describeCard(card.node.id)
            return .init(title: described?.title ?? "Card", image: Self.symbol(for: described?.kind))
        }, selected: shown)
    }

    /// The header as tall as the title bar, and its first control clear of the traffic lights — so the
    /// lights sit centred in the header rather than high in it. Asked once the window has its toolbar,
    /// and again when it comes out of full screen, which lays the title bar out anew.
    private func fitToTitleBar() {
        guard let window, let metrics = window.titlebarButtonMetrics(), !window.styleMask.contains(.fullScreen)
        else { return }
        barHeight?.constant = (metrics.buttonCenterY * 2).rounded()
        backLeading?.constant = metrics.leadingInset + 2
    }

    func windowDidExitFullScreen(_ notification: Notification) { fitToTitleBar() }

    static func symbol(for kind: CanvasItem.Kind?) -> NSImage? {
        let name: String
        switch kind {
        case .page(let host)?:
            if let favicon = FaviconLoader.shared.cached(for: host)?.copy() as? NSImage {
                favicon.size = NSSize(width: 14, height: 14)
                return favicon
            }
            name = "globe"
        case .file(let symbol)?, .view(let symbol)?: name = symbol
        case .text?, nil: name = "text.alignleft"
        }
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
    }

    /// Follow the page showing, for the header: its title, where it is, whether it can go back.
    private func watchPage() {
        pageWatches = []
        guard let page else { return }
        pageWatches = [
            page.observe(\.title) { [weak self] _, _ in MainActor.assumeIsolated { self?.describe() } },
            page.observe(\.url) { [weak self] _, _ in MainActor.assumeIsolated { self?.describe() } },
            page.observe(\.canGoBack) { [weak self] _, _ in MainActor.assumeIsolated { self?.describe() } },
        ]
    }

    /// The header's words: one card's title — a page's, then its host in grey, the host being the half
    /// that matters when a page asks for a password — or, with tabs, the tabs themselves.
    private func describe() {
        let many = cards.count > 1
        let host = page?.url?.host() ?? ""
        let pageTitle = page?.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let cardTitle = shownCard.flatMap { board?.describeCard($0.node.id)?.title } ?? ""
        // A page with nothing to say yet — loading, or failed before it had an address — goes by the
        // card's own name, as its tab on the board does.
        let title = !pageTitle.isEmpty ? pageTitle : !host.isEmpty ? host : cardTitle
        titleLabel.stringValue = title
        titleLabel.isHidden = many
        hostLabel.stringValue = host
        hostLabel.isHidden = many || page == nil || pageTitle.isEmpty
        back.isHidden = page == nil
        reload.isHidden = page == nil
        clearOfPage?.isActive = page != nil
        clearOfLights?.isActive = page == nil
        back.isEnabled = page?.canGoBack == true
        workspaceLabel.stringValue = workspace.isEmpty ? "" : "· \(workspace)"
        workspaceLabel.isHidden = workspace.isEmpty
        bringBack.toolTip = workspace.isEmpty ? "Bring Back" : "Bring Back to \(workspace)"
        gather.toolTip = workspace.isEmpty ? "Gather" : "Gather \(workspace)"
        rebuildTabs()
        // The Window menu and Mission Control have only this to go on, so it names the project too.
        let named = title.isEmpty ? "Card" : title
        window?.title = projectTitle.map { "\(named) — \($0)" } ?? named
    }

    /// The project's colour, texture and icon, from the board the cards are on. Asked again whenever the
    /// board's change — see `CanvasPaneController.projectColor`.
    func refreshAppearance() {
        guard let board else { return }
        let ground = board.enclosingScrollView as? CanvasScrollView
        wash.color = ground?.washColor
        wash.texture = ground?.groundView.texture
        let icon = CanvasProjectNoteCard.notes(forCanvasAt: board.store.url).flatMap { notes in
            (try? String(contentsOf: notes, encoding: .utf8)).flatMap { projectIcon(rawText: $0, notesPath: notes.path) }
        }
        projectMarkIcon = icon.flatMap { ProjectIconMark.canDraw($0) ? $0 : nil }
        let tint = wash.color?.swiftUIColor
        let drawn: AnyView? = if let icon, ProjectIconMark.canDraw(icon) {
            AnyView(ProjectIconMark(icon: icon, size: 14, tint: tint))
        } else if let tint {
            // No icon of its own: the project's colour says as much, as a dot.
            AnyView(Circle().fill(tint).frame(width: 9, height: 9))
        } else {
            nil
        }
        mark.image = drawn.flatMap { view in
            let renderer = ImageRenderer(content: view.frame(width: 16, height: 16))
            renderer.scale = window?.backingScaleFactor ?? 2
            return renderer.nsImage
        }
        mark.isHidden = mark.image == nil
        markWidth?.constant = mark.image == nil ? 0 : 16
        projectTitle = board.boardProject?.title
        mark.toolTip = projectTitle
        describe()
        CanvasSatelliteDock.shared.refresh()
    }

    /// ⌘1…⌘9, the same menu items a project window answers: this window's tabs by position, ⌘9 the last.
    /// Not answered at one card, where there is no row to move along, so the key goes on to whoever
    /// else wants it.
    @objc func selectProjectTabByIndex(_ sender: Any?) {
        guard let slot = (sender as? NSMenuItem)?.tag, cards.count > 1 else { return }
        showTab(slot == 8 ? cards.count - 1 : slot)
    }

    /// Nine slots retitled on validation with the tabs' own names, as a project window's are.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard item.action == #selector(selectProjectTabByIndex(_:)) else { return true }
        let last = item.tag == 8
        let index = last ? cards.count - 1 : item.tag
        guard cards.count > 1, index >= 0, index < cards.count else {
            item.title = last ? "Last Tab" : "Tab \(item.tag + 1)"
            item.state = .off
            return false
        }
        item.title = last ? "Last Tab" : board?.describeCard(cards[index].node.id)?.title ?? "Card"
        item.state = index == shown ? .on : .off
        return true
    }

    @objc private func goBack() { page?.goBack() }
    @objc private func reloadPage() { page?.reload() }
    @objc private func returnToWorkspace() {
        bringingBack = true
        close()
    }
    @objc private func gatherWorkspace() { board?.gatherWorkspace() }

    /// The header's two buttons are there only while the pointer is over the window — the title bar
    /// included: they are for the moment you reach for them, and the rest of the time the header is the
    /// card's. Tracked on the window's frame view rather than the content, because the title bar is laid
    /// over the content and took the pointer off it: the buttons went as you reached up for them.
    private func watchHover() {
        guard let frame = window?.contentView?.superview else { return }
        frame.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                             owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { showButtons(true) }
    override func mouseExited(with event: NSEvent) { showButtons(false) }

    private func showButtons(_ shown: Bool) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            for button in [bringBack, gather] { button.animator().alphaValue = shown ? 1 : 0 }
        }
    }

    /// Put the window away with its workspace: the content goes back into the cards, and the window is
    /// remembered so the workspace can bring it out again.
    func putAway() {
        puttingAway = true
        close()
    }

    // MARK: Links

    /// A link in a card's content is the board's to follow when the card is on the board — see
    /// `CanvasLinkZones` — and there is no board here. So the window follows them itself: a press and
    /// release on the same link, the first click of a run, as on the board.
    private func watchLinks() {
        linkMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, event.window === self.window, let card = self.shownCard else { return event }
                let url = card.lentLink(atWindowPoint: event.locationInWindow)
                if event.type == .leftMouseDown {
                    self.linkPress = event.clickCount == 1 ? url : nil
                    return url == nil ? event : nil
                }
                defer { self.linkPress = nil }
                guard let pressed = self.linkPress else { return event }
                if url == pressed, !card.followsInPlace(pressed) { NSWorkspace.shared.open(pressed) }
                return nil
            }
        }
    }

    // MARK: NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) { shownCard?.engage(true) }

    func windowDidResignKey(_ notification: Notification) {
        if shownCard?.isEngaged == true { shownCard?.engage(false) }
    }

    /// ⌘Z here is the card's: a note's own typing, else the board's document.
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        guard let board else { return nil }
        return shownCard.flatMap(board.undoManager(forCard:)) ?? board.store.undoManager
    }

    func windowWillClose(_ notification: Notification) {
        if let linkMonitor { NSEvent.removeMonitor(linkMonitor) }
        linkMonitor = nil
        pageWatches = []
        Self.open.removeAll { $0 === self }
        let ids = cardIDs
        let showing = shownCard?.node.id
        if !puttingAway { CanvasSatellites.forget(ids.first ?? "", canvas: canvas, workspace: workspace) }
        for card in cards { card.takeBack() }
        cards = []
        if !puttingAway { board?.satelliteReturned(ids, showing: showing, from: workspace, raisingWindow: bringingBack) }
        CanvasSatelliteDock.shared.refresh()
        if let board { CanvasSatelliteKeeper.releaseIfDone(board) }
    }

    func windowDidMove(_ notification: Notification) { remember() }
    func windowDidEndLiveResize(_ notification: Notification) { remember() }

    private func remember() {
        guard let frame = window?.frame, !puttingAway, !cards.isEmpty,
              Self.open.contains(where: { $0 === self }) else { return }
        CanvasSatellites.remember(.init(cards: cardIDs, showing: shownCard?.node.id, frame: frame),
                                  canvas: canvas, workspace: workspace)
    }
}

/// Which satellites each workspace had out, and where — so a workspace you come back to brings them
/// back. In user defaults beside `CanvasWorkspaces`, keyed by canvas and workspace name; a frame, not a
/// layout, so it stays out of the tiling's own equality (`CanvasViewState.Tiling`).
enum CanvasSatellites {
    static let defaultsKey = "PMCanvasSatellites"

    /// One window: its cards in tab order, the one showing, and where it was.
    struct Record: Codable, Equatable {
        var cards: [String]
        var showing: String?
        var frame: String

        init(cards: [String], showing: String?, frame: NSRect) {
            self.cards = cards
            self.showing = showing
            self.frame = NSStringFromRect(frame)
        }

        var rect: NSRect { NSRectFromString(frame) }
    }

    static func records(canvas: URL, workspace: String, in defaults: UserDefaults = .standard) -> [Record] {
        let stored = defaults.dictionary(forKey: defaultsKey)?[key(canvas, workspace)] as? [String: Data] ?? [:]
        return stored.values.compactMap { try? JSONDecoder().decode(Record.self, from: $0) }
            .sorted { ($0.cards.first ?? "") < ($1.cards.first ?? "") }
    }

    /// Remember a window, keyed by its first card. A record sharing a card with it is an older word on
    /// the same window, and goes.
    static func remember(_ record: Record, canvas: URL, workspace: String, in defaults: UserDefaults = .standard) {
        guard let first = record.cards.first, let data = try? JSONEncoder().encode(record) else { return }
        change(canvas, workspace, in: defaults) { stored in
            for (key, value) in stored where key != first {
                if let other = try? JSONDecoder().decode(Record.self, from: value),
                   !Set(other.cards).isDisjoint(with: record.cards) { stored[key] = nil }
            }
            stored[first] = data
        }
    }

    static func forget(_ first: String, canvas: URL, workspace: String, in defaults: UserDefaults = .standard) {
        change(canvas, workspace, in: defaults) { $0[first] = nil }
    }

    /// The workspaces whose window is put away because every tile is out — so a relaunch that brings
    /// their satellites back puts the window away again, rather than showing a window of Empties.
    static let poppedOutKey = "PMCanvasPoppedOut"

    static func isPoppedOut(canvas: URL, workspace: String, in defaults: UserDefaults = .standard) -> Bool {
        defaults.stringArray(forKey: poppedOutKey)?.contains(key(canvas, workspace)) ?? false
    }

    static func setPoppedOut(_ poppedOut: Bool, canvas: URL, workspace: String, in defaults: UserDefaults = .standard) {
        var all = Set(defaults.stringArray(forKey: poppedOutKey) ?? [])
        let key = key(canvas, workspace)
        guard all.contains(key) != poppedOut else { return }
        if poppedOut { all.insert(key) } else { all.remove(key) }
        defaults.set(all.sorted(), forKey: poppedOutKey)
    }

    private static func change(_ canvas: URL, _ workspace: String, in defaults: UserDefaults,
                               _ edit: (inout [String: Data]) -> Void) {
        var all = defaults.dictionary(forKey: defaultsKey) ?? [:]
        let key = key(canvas, workspace)
        var stored = all[key] as? [String: Data] ?? [:]
        edit(&stored)
        all[key] = stored.isEmpty ? nil : stored
        defaults.set(all, forKey: defaultsKey)
    }

    private static func key(_ canvas: URL, _ workspace: String) -> String {
        canvas.standardizedFileURL.path + "\u{1}" + workspace
    }
}

// MARK: - The board's half

extension CanvasBoardView {
    /// Which workspace a satellite belongs to: the named one that is up, or the canvas's own tiling.
    var satelliteScope: String { workspaceName ?? "" }

    /// The satellites this board has out.
    var satellites: [CanvasSatelliteWindow] {
        CanvasSatelliteWindow.open.filter { $0.board === self }
    }

    /// Whether every card in the tiling is out in a satellite — a popped-out workspace, however it got
    /// that way.
    var isAllOut: Bool {
        guard let tiling, !tiling.cards.isEmpty else { return false }
        return tiling.cards.allSatisfy { nodeViews[$0]?.lentTo != nil }
    }

    /// Move cards into a window of their own, as its tabs.
    ///
    /// **They keep their place in the tiling.** Each card's tile stays where it was and shows what is
    /// out and where (`CanvasSatelliteEmpty`), so the window still says the card belongs here and Bring
    /// Back has a slot to fill. Taking them out of the tiling — the rest closing up over the gap — left
    /// people unable to say where a card had gone.
    ///
    /// **The last tile out takes the window with it**, as Pop Out does: a window of nothing but Empties
    /// is in the way of the windows it lists, and the dock is the way back to it. Not for a workspace of
    /// one tile — the notes, moved out to write beside something, would take the whole project window
    /// with them — and not while satellites are being brought back out (`restoring`), which put the
    /// window away only if it was away before (`restoreSatellites`).
    ///
    /// - Parameter frame: where the window goes, in screen coordinates; nil centres it.
    @discardableResult
    func moveToWindow(_ ids: [String], showing: String? = nil, frame: NSRect? = nil,
                      restoring: Bool = false) -> CanvasSatelliteWindow? {
        let cards = ids.compactMap { nodeViews[$0] }.filter { $0.lentTo == nil }
        guard !cards.isEmpty else { return nil }
        let satellite = CanvasSatelliteWindow.open(cards, showing: showing, frame: frame, on: self)
        CanvasSatelliteDock.shared.refresh()
        if !restoring, isAllOut, (tiling?.ids.count ?? 0) > 1 { putWindowAway() }
        return satellite
    }

    /// The workspace's window off the screen while every tile is out, remembered so a relaunch does the
    /// same. `showWorkspaceWindow` is the way back.
    func putWindowAway() {
        window?.orderOut(nil)
        CanvasSatellites.setPoppedOut(true, canvas: store.url, workspace: satelliteScope)
    }

    /// Move the whole tile holding `id` — every tab of it — into a window of its own.
    @discardableResult
    func moveTileToWindow(_ id: String, frame: NSRect? = nil) -> CanvasSatelliteWindow? {
        guard let tiling, let at = tiling.position(of: id) else { return moveToWindow([id], frame: frame) }
        let tile = tiling.columns[at.column].tiles[at.tile]
        return moveToWindow(tile.cards, showing: tile.shown, frame: frame)
    }

    /// A satellite has come home. Its cards kept their slots, so there is nothing to place: the tile is
    /// picked out, at the card that was showing, and the window comes back if Pop Out put it away.
    ///
    /// A card whose tile was removed while it was out goes back in beside the selection, as a new card
    /// would. And nothing is placed when the board has gone on to another workspace since — `scope` is
    /// where the satellite came from: its cards are in that workspace's saved tiling, and come back
    /// with it.
    ///
    /// **Bring Back raises the window; the close button doesn't.** Closing a window is putting it away,
    /// not asking for another — so a workspace window that Pop Out put away stays away while others are
    /// still out, and comes back behind everything once none are.
    func satelliteReturned(_ ids: [String], showing: String?, from scope: String, raisingWindow: Bool) {
        guard var session = tiling, scope == satelliteScope else { return }
        let missing = ids.filter { !session.cards.contains($0) && document.node(id: $0) != nil }
        if let first = missing.first {
            session.add(first, at: nextPlacement)
            for id in missing.dropFirst() { session.add(id, at: .init(target: first, side: .tab)) }
            tiling = session
            setLayout(session.layout, animated: true)
            onTilingChanged?()
            announceTiling()
        }
        if let window, !window.isVisible, !isAllOut, raisingWindow || satellites.isEmpty {
            if raisingWindow { window.orderFront(nil) } else { window.orderBack(nil) }
            CanvasSatellites.setPoppedOut(false, canvas: store.url, workspace: satelliteScope)
        }
        guard let front = showing.flatMap({ ids.contains($0) ? $0 : nil }) ?? ids.first,
              session.cards.contains(front) else { return }
        select([front])
        if session.hasTabs(front) { showTab(front) }
    }

    /// Pop Out Workspace: every tile into a window of its own, each opened over the tile it was — a
    /// tile of tabs as a window of tabs — and the workspace's window put away, leaving the cards
    /// themselves on screen. The tiles stay behind as Empties for Gather and Bring Back to fill, and the
    /// dock (`CanvasSatelliteDock`) is the way back to the window.
    func popOutWorkspace() {
        guard isTiled, let window else { return }
        restoreMaximizedTile(animated: false)
        guard let session = tiling else { return }
        let frames = session.tileFrames
        for tile in session.columns.flatMap(\.tiles) {
            guard tile.cards.contains(where: { nodeViews[$0]?.lentTo == nil }), let frame = frames[tile.shown]
            else { continue }
            moveToWindow(tile.cards, showing: tile.shown,
                         frame: window.convertToScreen(convert(viewRect(frame), to: nil)), restoring: true)
        }
        if isAllOut { putWindowAway() }
    }

    /// Gather Workspace: every satellite of this workspace home, and its window back.
    ///
    /// **With every tile out, the tiling is rebuilt from where the windows are** — columns left to
    /// right, tiles top to bottom within one (`CanvasSatelliteGather.columns`) — so arranging the
    /// windows and gathering them is a way of rearranging the workspace. A workspace popped out and left alone
    /// gathers back into the tiling it came from. With only some out, each fills the slot it kept.
    /// The rearranging is one step of ⌘Z; the windows are not part of it.
    func gatherWorkspace() {
        let out = satellites
        guard !out.isEmpty else { return showWorkspaceWindow() }
        let undoFrom = beginTilingUndo()
        defer { endTilingUndo("Gather Workspace", from: undoFrom) }
        let rebuilt = isAllOut ? tiling.flatMap { session in
            CanvasSatelliteGather.columns(from: out.compactMap { satellite in
                satellite.window.map { (satellite.tile(in: session), $0.frame) }
            })
        } : nil
        for satellite in out { satellite.close() }
        if let rebuilt, var session = tiling,
           rebuilt.flatMap({ $0.tiles.flatMap(\.cards) }).sorted() == session.cards.sorted() {
            session.columns = rebuilt
            session.maximized = nil
            tiling = session
            setLayout(session.layout, animated: true)
            onTilingChanged?()
            announceTiling()
        }
        showWorkspaceWindow()
    }

    /// This workspace's window forward, at this workspace's tab — from the dock, or Gather.
    ///
    /// A board that has lost its window — its window went on to another project while its satellites
    /// were out (`CanvasSatelliteKeeper`) — asks for a window on its project at this workspace, and the
    /// board that comes up there takes the satellites over.
    func showWorkspaceWindow() {
        CanvasSatellites.setPoppedOut(false, canvas: store.url, workspace: satelliteScope)
        guard let window else { return CanvasSatelliteKeeper.reopen(self) }
        if isHiddenOrHasHiddenAncestor, let workspaceName { onGoToWorkspace(workspaceName) }
        window.makeKeyAndOrderFront(nil)
    }

    /// Put this board's satellites away, remembering them — the board is leaving its window: the window
    /// is closing, or the tab it was in has gone. Its tab merely going behind another leaves them out.
    func putSatellitesAway() {
        guard !CanvasSatelliteKeeper.isKeeping else { return }
        for satellite in satellites { satellite.putAway() }
    }

    /// Bring out the satellites this board's workspace had, where they were.
    ///
    /// On the next turn, so the pages the board is taking over from the tab behind it have arrived:
    /// a card whose page is still elsewhere starts one, and the one elsewhere is then a second.
    func restoreSatellites() {
        guard isTiled else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, window != nil, !isHiddenOrHasHiddenAncestor, isTiled else { return }
            // A board kept from a window that went on to another project hands its windows over: put
            // away where they are, and brought out again below on this board.
            CanvasSatelliteKeeper.adopt(by: self)
            let out = CanvasSatelliteWindow.open.filter { $0.canvas == self.store.url && $0.workspace == self.satelliteScope }
            for record in CanvasSatellites.records(canvas: store.url, workspace: satelliteScope) {
                let ids = record.cards.filter { self.document.node(id: $0) != nil }
                guard !ids.isEmpty, !ids.contains(where: { self.nodeViews[$0]?.lentTo != nil }),
                      // Already out from another board on this workspace — a second window on it.
                      !out.contains(where: { !Set($0.cardIDs).isDisjoint(with: ids) }) else { continue }
                if ids.contains(where: { self.nodeViews[$0] == nil }) { refreshNodeViews() }
                moveToWindow(ids, showing: record.showing, frame: record.rect, restoring: true)
            }
            if isAllOut, CanvasSatellites.isPoppedOut(canvas: store.url, workspace: satelliteScope) {
                window?.orderOut(nil)
            }
        }
    }

    /// ⌘Z for a card whose content is out in a satellite: its own typing, if it has some.
    func undoManager(forCard card: CanvasNodeView) -> UndoManager? {
        if let text = card as? CanvasTextNodeView, let undo = text.editingUndo { return undo }
        if let file = card as? CanvasFileNodeView, let undo = file.documentUndo { return undo }
        if let file = card as? CanvasFileNodeView, let undo = file.projectDisplay.noteUndo { return undo }
        if let content = card.cardContent,
           let undo = CanvasUndoRoute.typingUndo(in: content, boardUndo: store.undoManager) { return undo }
        return nil
    }
}

// MARK: - Dragging out of the window

extension CanvasBoardView {
    /// Whether the pointer is out past this board's window — where letting go of a tile opens a window
    /// for it rather than placing it among the others.
    var isOutsideWindow: Bool {
        guard let window else { return false }
        return !window.frame.contains(Self.pointerOnScreen())
    }

    /// Where the pointer is on screen. A seam for tests, which can't move the real one.
    nonisolated(unsafe) static var pointerOnScreen: () -> NSPoint = { NSEvent.mouseLocation }

    /// The frame for a window pulled out at the pointer: as big as the tile was, with its title bar
    /// under the pointer the way a tab torn out of a browser arrives.
    func satelliteFrame(for tile: CanvasRect?) -> NSRect {
        let scale = liveScale
        let size = NSSize(width: max(320, (tile?.width ?? 640) * scale),
                          height: max(240, (tile?.height ?? 480) * scale + CanvasSatelliteWindow.headerHeight))
        let pointer = Self.pointerOnScreen()
        return NSRect(x: pointer.x - min(120, size.width / 2), y: pointer.y - size.height + 14,
                      width: size.width, height: size.height)
    }
}

/// A satellite's tabs: one per card, its icon and name, and a chip under the one showing.
///
/// **The chip is a view of its own and travels**, 0.2s from the tab that was showing to the one that is,
/// the way a tile's strip slides its chip (`CanvasTileHandleView.chipRect`). And the names keep one
/// weight, so a tab is the same width chosen or not and the row never shifts under the pointer: which is
/// showing is said by the chip and the colour of the name.
///
/// **Raised, not tinted.** On the board the chip is a wash of the label colour on a card, which reads;
/// on a project's coloured wash the same grey all but vanished. So here it is the control-background
/// colour, lifted by a rim and a small shadow — a segmented control's chosen segment.
@MainActor
final class CanvasSatelliteTabs: NSView {
    struct Tab: Equatable {
        var title: String
        var image: NSImage?
    }

    var onSelect: (Int) -> Void = { _ in }
    private(set) var selected = 0
    private let row = NSStackView()
    private let chip = CanvasSatelliteTabChip()
    private var buttons: [CanvasSatelliteTabButton] { row.arrangedSubviews.compactMap { $0 as? CanvasSatelliteTabButton } }
    /// Set while the chip is on its way, so a layout pass meanwhile doesn't snap it to the end.
    private var travelling = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        row.orientation = .horizontal
        row.spacing = 2
        row.translatesAutoresizingMaskIntoConstraints = false
        chip.isHidden = true
        addSubview(chip)
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor), row.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor), row.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Show these tabs with this one chosen. The buttons are kept when the tabs are the same number —
    /// a page's title changing renames its tab rather than rebuilding the row — and the chip travels
    /// when the choice changed.
    func show(_ tabs: [Tab], selected index: Int) {
        let moving = index != selected && !chip.isHidden && buttons.count == tabs.count
        if buttons.count != tabs.count {
            row.arrangedSubviews.forEach { $0.removeFromSuperview() }
            for i in tabs.indices {
                let button = CanvasSatelliteTabButton()
                button.tag = i
                button.target = self
                button.action = #selector(clicked(_:))
                row.addArrangedSubview(button)
            }
        }
        selected = index
        for (i, (button, tab)) in zip(buttons, tabs).enumerated() {
            button.set(tab.title, image: tab.image, showing: i == index)
        }
        chip.isHidden = tabs.isEmpty
        layoutSubtreeIfNeeded()
        guard let target = chipFrame else { return }
        guard moving else {
            if !travelling { chip.frame = target }
            return
        }
        travelling = true
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            chip.animator().frame = target
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                self?.travelling = false
                self?.needsLayout = true
            }
        })
    }

    private var chipFrame: NSRect? {
        guard buttons.indices.contains(selected) else { return nil }
        return convert(buttons[selected].bounds, from: buttons[selected])
    }

    override func layout() {
        super.layout()
        if !travelling, let target = chipFrame { chip.frame = target }
    }

    @objc private func clicked(_ sender: NSButton) { onSelect(sender.tag) }
}

/// The chip under the tab showing. See `CanvasSatelliteTabs`.
@MainActor
final class CanvasSatelliteTabChip: NSView {
    override var wantsUpdateLayer: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 0.5
        layer?.shadowOffset = CGSize(width: 0, height: -1)
        layer?.shadowRadius = 1.5
        layer?.masksToBounds = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateLayer() {
        guard let layer else { return }
        let dark = effectiveAppearance.isDark
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer.backgroundColor = (dark ? NSColor.white.withAlphaComponent(0.2)
                                          : NSColor.white.withAlphaComponent(0.92)).cgColor
            layer.borderColor = (dark ? NSColor.white.withAlphaComponent(0.14)
                                      : NSColor.black.withAlphaComponent(0.12)).cgColor
        }
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOpacity = dark ? 0.35 : 0.14
    }
}

/// One tab: borderless, its icon and name, a faint fill under the pointer when it isn't the one showing.
/// An `NSButton` because the header lies in the title bar's drag band, and only controls take clicks
/// there.
@MainActor
final class CanvasSatelliteTabButton: NSButton {
    private var showing = false
    private var hovered = false { didSet { needsDisplay = true } }

    init() {
        super.init(frame: .zero)
        bezelStyle = .accessoryBarAction
        isBordered = false
        imagePosition = .imageLeading
        imageHugsTitle = true
        lineBreakMode = .byTruncatingTail
        font = .systemFont(ofSize: 12)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous
        widthAnchor.constraint(lessThanOrEqualToConstant: 180).isActive = true
        heightAnchor.constraint(equalToConstant: 24).isActive = true
        setContentCompressionResistancePriority(.defaultLow - 2, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func set(_ title: String, image: NSImage?, showing: Bool) {
        self.showing = showing
        self.title = title
        self.image = image
        toolTip = title
        contentTintColor = showing ? .labelColor : .secondaryLabelColor
        setAccessibilityLabel(title)
        setAccessibilityValue(showing ? "Showing" : nil)
        needsDisplay = true
    }

    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        // Room either side of the icon and name: the chip is the button's own frame.
        size.width += image == nil ? 16 : 22
        return size
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        super.updateLayer()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = hovered && !showing ? NSColor.labelColor.withAlphaComponent(0.07).cgColor : nil
        }
    }
}

/// A view that says when the pointer comes over it and goes, wherever in it — the satellite's root, for
/// the header buttons that show on hover.
@MainActor
final class CanvasHoverView: NSView {
    var onHover: (Bool) -> Void = { _ in }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { onHover(true) }
    override func mouseExited(with event: NSEvent) { onHover(false) }
}
