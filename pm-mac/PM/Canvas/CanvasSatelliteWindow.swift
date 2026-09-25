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
    private let stage = NSView()
    private let wash = CanvasColorWash()
    /// The project's icon, drawn once into a picture: a hosted SwiftUI view in an AppKit row sizes and
    /// places itself by rules of its own, and this only ever needs to be a picture.
    private let mark = NSImageView()
    private var markWidth: NSLayoutConstraint?
    private let titleLabel = NSTextField(labelWithString: "")
    private let hostLabel = NSTextField(labelWithString: "")
    private let tabs = NSStackView()
    private let back = NSButton()
    private let reload = NSButton()
    private var pageWatches: [NSKeyValueObservation] = []
    private var linkPress: URL?
    private var linkMonitor: Any?
    private var projectTitle: String?

    static let headerHeight: CGFloat = 38

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
        super.init(window: window)
        window.delegate = self
        window.contentView = content()
        watchLinks()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Cards

    /// Borrow a card's content and add it as a tab.
    private func take(_ card: CanvasNodeView) {
        card.prepareToLend()
        guard let content = card.lend(to: self) else { return }
        cards.append(card)
        place(content)
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
        new.isHidden = card !== shownCard
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

    @objc private func tabClicked(_ sender: NSButton) { showTab(sender.tag) }

    // MARK: The window

    private func content() -> NSView {
        let root = NSView()
        let bar = wash
        let line = NSBox()
        line.boxType = .separator

        configure(back, "chevron.backward", "Back", #selector(goBack))
        configure(reload, "arrow.clockwise", "Reload", #selector(reloadPage))
        let home = NSButton()
        configure(home, "arrow.down.right.and.arrow.up.left", "Put this back in its workspace",
                  #selector(returnToWorkspace))

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        // The title gives way first: the host is the half that says whose page this is.
        titleLabel.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
        hostLabel.font = .systemFont(ofSize: 12)
        hostLabel.textColor = .secondaryLabelColor
        hostLabel.lineBreakMode = .byTruncatingMiddle
        hostLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        mark.translatesAutoresizingMaskIntoConstraints = false
        let markWidth = mark.widthAnchor.constraint(equalToConstant: 16)
        self.markWidth = markWidth
        NSLayoutConstraint.activate([markWidth, mark.heightAnchor.constraint(equalToConstant: 16)])
        tabs.orientation = .horizontal
        tabs.spacing = 2
        tabs.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
        let words = NSStackView(views: [mark, titleLabel, hostLabel, tabs])
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
        // Clear of the traffic lights, which sit at the leading edge of the title bar.
        let lights = window?.standardWindowButton(.zoomButton).map { $0.frame.maxX + 14 } ?? 78
        let centred = words.centerXAnchor.constraint(equalTo: bar.centerXAnchor)
        centred.priority = .defaultLow
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: root.topAnchor),
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: Self.headerHeight),
            line.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            line.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
            back.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: lights),
            back.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            reload.leadingAnchor.constraint(equalTo: back.trailingAnchor, constant: 2),
            reload.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            home.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -10),
            home.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            centred,
            words.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            words.leadingAnchor.constraint(greaterThanOrEqualTo: bar.leadingAnchor, constant: lights + 64),
            words.trailingAnchor.constraint(lessThanOrEqualTo: home.leadingAnchor, constant: -12),
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
        button.symbolConfiguration = .init(pointSize: 14, weight: .regular)
        button.contentTintColor = .secondaryLabelColor
        button.widthAnchor.constraint(equalToConstant: 28).isActive = true
        button.heightAnchor.constraint(equalToConstant: 24).isActive = true
    }

    /// One tab per card, when there is more than one: its icon and name, the one showing in the label
    /// colour and bold and the rest in grey, as a tile's own strip draws them.
    private func rebuildTabs() {
        tabs.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard cards.count > 1 else { return }
        for (index, card) in cards.enumerated() {
            let described = board?.describeCard(card.node.id)
            let showing = index == shown
            let button = NSButton(title: described?.title ?? "Card", target: self, action: #selector(tabClicked(_:)))
            button.tag = index
            button.bezelStyle = .accessoryBarAction
            button.isBordered = showing
            button.font = .systemFont(ofSize: 12, weight: showing ? .semibold : .regular)
            button.contentTintColor = showing ? .labelColor : .secondaryLabelColor
            button.image = Self.symbol(for: described?.kind)
            button.imagePosition = .imageLeading
            button.lineBreakMode = .byTruncatingTail
            button.toolTip = described?.title
            button.widthAnchor.constraint(lessThanOrEqualToConstant: 180).isActive = true
            button.setContentCompressionResistancePriority(.defaultLow - 2, for: .horizontal)
            button.setAccessibilityValue(showing ? "Showing" : nil)
            tabs.addArrangedSubview(button)
        }
    }

    private static func symbol(for kind: CanvasItem.Kind?) -> NSImage? {
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
        back.isEnabled = page?.canGoBack == true
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
    }

    @objc private func goBack() { page?.goBack() }
    @objc private func reloadPage() { page?.reload() }
    @objc private func returnToWorkspace() { close() }

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
        if !puttingAway { board?.satelliteReturned(ids, showing: showing) }
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

    /// Move cards into a window of their own, as its tabs. They leave the tiling, so the rest close up
    /// round the gap — unless nothing would be left, which a tiling can't be, so they stay as a tile
    /// that says where its cards have gone.
    ///
    /// - Parameter frame: where the window goes, in screen coordinates; nil centres it.
    @discardableResult
    func moveToWindow(_ ids: [String], showing: String? = nil, frame: NSRect? = nil) -> CanvasSatelliteWindow? {
        let cards = ids.compactMap { nodeViews[$0] }.filter { $0.lentTo == nil }
        guard !cards.isEmpty else { return nil }
        let home = returnPlacement(for: cards.map(\.node.id))
        // The content goes out first: a tile leaving the tiling is a card the board may stop keeping,
        // and being lent out is what tells the board to keep it (`isHeldElsewhere`).
        guard let satellite = CanvasSatelliteWindow.open(cards, showing: showing, frame: frame, on: self)
        else { return nil }
        if let tiling {
            let tiled = satellite.cardIDs.filter(tiling.cards.contains)
            if !tiled.isEmpty, tiling.cards.count > tiled.count {
                for id in tiled { satelliteHomes[id] = home }
                removeFromTiling(tiled)
            }
        }
        return satellite
    }

    /// Move the whole tile holding `id` — every tab of it — into a window of its own.
    @discardableResult
    func moveTileToWindow(_ id: String, frame: NSRect? = nil) -> CanvasSatelliteWindow? {
        guard let tiling, let at = tiling.position(of: id) else { return moveToWindow([id], frame: frame) }
        let tile = tiling.columns[at.column].tiles[at.tile]
        return moveToWindow(tile.cards, showing: tile.shown, frame: frame)
    }

    /// A satellite has come home: its cards go back as one tile of tabs, beside the tile they were next
    /// to — or into it, for a tab pulled out of one.
    func satelliteReturned(_ ids: [String], showing: String?) {
        let homes = ids.compactMap { satelliteHomes.removeValue(forKey: $0) }
        guard var session = tiling else { return }
        let back = ids.filter { !session.cards.contains($0) && document.node(id: $0) != nil }
        guard let first = back.first else { return }
        let placement = homes.first.flatMap { session.cards.contains($0.target) ? $0 : nil } ?? nextPlacement
        session.add(first, at: placement)
        for id in back.dropFirst() { session.add(id, at: .init(target: first, side: .tab)) }
        let front = showing.flatMap { back.contains($0) ? $0 : nil } ?? first
        tiling = session
        select([front])
        setLayout(session.layout, animated: true)
        onTilingChanged?()
        announceTiling()
        if back.count > 1 { showTab(front) }
    }

    /// Put this board's satellites away, remembering them — its workspace has gone behind another, or
    /// its window is closing.
    func putSatellitesAway() {
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
            for record in CanvasSatellites.records(canvas: store.url, workspace: satelliteScope) {
                let ids = record.cards.filter { self.document.node(id: $0) != nil }
                guard !ids.isEmpty, !ids.contains(where: { self.nodeViews[$0]?.lentTo != nil }) else { continue }
                if ids.contains(where: { self.nodeViews[$0] == nil }) { refreshNodeViews() }
                moveToWindow(ids, showing: record.showing, frame: record.rect)
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

    /// The place a tile would go back to: into the tile a tab was pulled from, else beside a neighbour
    /// in its column, else beside the next column.
    private func returnPlacement(for ids: [String]) -> CanvasTileSession.Placement? {
        guard let tiling, let first = ids.first, let at = tiling.position(of: first) else { return nil }
        let column = tiling.columns[at.column].tiles
        if let stays = column[at.tile].cards.first(where: { !ids.contains($0) }) {
            return .init(target: stays, side: .tab)
        }
        func other(_ tile: CanvasTiling.Tile) -> String? { tile.cards.first { !ids.contains($0) } }
        if at.tile > 0, let above = other(column[at.tile - 1]) { return .init(target: above, side: .below) }
        if at.tile + 1 < column.count, let below = other(column[at.tile + 1]) {
            return .init(target: below, side: .above)
        }
        if at.column > 0, let left = tiling.columns[at.column - 1].tiles.first.flatMap(other) {
            return .init(target: left, side: .right)
        }
        if at.column + 1 < tiling.columns.count,
           let right = tiling.columns[at.column + 1].tiles.first.flatMap(other) {
            return .init(target: right, side: .left)
        }
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
