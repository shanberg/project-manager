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
    /// window back with it and picks the card out there. Closing it with its close button changes
    /// nothing else: see `satelliteReturned`.
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
    /// The window's menu, innermost of the buttons on the right: the project panel, and the way to the
    /// workspace's other tiles and the project's other workspaces. See `showMenu`.
    private let more = NSButton()
    private let tabs = CanvasSatelliteTabs()
    /// The header's words: the project's mark, the card's title and host, or the tabs, and the
    /// workspace's name. Hidden while the address is being typed.
    private let words = NSStackView()
    private var barHeight: NSLayoutConstraint?
    private var backLeading: NSLayoutConstraint?
    /// The title's room on the leading side: clear of Back and Reload when a page shows them, clear of
    /// the traffic lights alone when not. One of the two is on — see `describe`.
    private var clearOfLights: NSLayoutConstraint?
    private var clearOfPage: NSLayoutConstraint?
    private let back = CanvasHistoryButton()
    private let forward = CanvasHistoryButton()
    private let reload = NSButton()
    /// ⌘L: the page's address, typed over in place of the header's words. See `pageOpenAddress`.
    private let addressField = NSTextField()
    /// ⌘F: a page's own find, at the trailing end of the header. See `performFindPanelAction`.
    private let findField = NSSearchField()
    private var pageWatches: [NSKeyValueObservation] = []
    private var linkPress: URL?
    private var linkReorder: LinkReorder?
    /// The lit row and the line while a link is dragged along its list, over the card.
    private let reorderMark = CanvasLinkReorderMark()
    private var linkMonitor: Any?
    /// The project's name, colour and icon, as the header draws them — and the dock, which groups
    /// satellites by workspace and wants each group dressed as its project.
    private(set) var projectTitle: String?
    var projectColor: NSColor? { wash.color?.nsColor }
    var projectMark: NSImage? { mark.image }
    /// The project's icon itself, for the dock to draw at its own size and in its own colour.
    private(set) var projectMarkIcon: ProjectIcon?

    static let headerHeight: CGFloat = 28

    /// The space a canvas is, if it is one. A seam: tests never wake `Spaces.shared`, which reads the
    /// real spaces file and can write carried-over canvases.
    static var spaceOf: (URL) -> Space? = { Spaces.shared.space(forCanvas: $0) }

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
    ///
    /// - Parameter lifting: the window flies out of the tile it came from (`CanvasSatelliteFlight`),
    ///   for a move asked for in so many words; otherwise it fades in where it is.
    static func open(_ cards: [CanvasNodeView], showing: String?, frame: NSRect?, on board: CanvasBoardView,
                     lifting: Bool = false) -> CanvasSatelliteWindow? {
        // Before the content is lent, while the tile still shows it.
        let origin = lifting ? (cards.first { $0.node.id == showing } ?? cards.first)
            .flatMap(CanvasSatelliteFlight.origin(of:)) : nil
        let satellite = CanvasSatelliteWindow(board: board, frame: frame.map { onScreen($0) })
        for card in cards { satellite.take(card) }
        guard !satellite.cards.isEmpty else { return nil }
        let before = open.last?.window
        open.append(satellite)
        satellite.showTab(satellite.cards.firstIndex { $0.node.id == showing } ?? 0)
        satellite.refreshAppearance()
        if frame == nil, let window = satellite.window { place(window, after: before) }
        CanvasSatelliteFlight.arrive(satellite, from: origin)
        satellite.remember()
        return satellite
    }

    /// A window with no frame of its own: centred, or — with another satellite up — a step down and
    /// across from the last one, as AppKit cascades a document window, so two never lie exactly over
    /// each other.
    private static func place(_ window: NSWindow, after previous: NSWindow?) {
        guard let previous, previous.isVisible else { return window.center() }
        let topLeft = NSPoint(x: previous.frame.minX, y: previous.frame.maxY)
        window.setFrameTopLeftPoint(window.cascadeTopLeft(from: topLeft))
        window.setFrame(onScreen(window.frame), display: false)
    }

    /// A remembered frame where it can be seen: kept if its title bar is on some screen, else moved
    /// onto the screen it overlaps most — the main one when none — and shrunk to fit. A display taken
    /// away since would otherwise bring the window back somewhere nobody can reach.
    static func onScreen(_ frame: NSRect, screens: [NSRect] = NSScreen.screens.map(\.visibleFrame)) -> NSRect {
        let titleBar = NSRect(x: frame.minX + 40, y: frame.maxY - headerHeight,
                              width: max(0, frame.width - 80), height: headerHeight)
        if screens.contains(where: { $0.intersects(titleBar) }) { return frame }
        let area = { (r: NSRect) in r.isNull ? 0 : r.width * r.height }
        guard let main = screens.first else { return frame }
        let most = screens.max { area($0.intersection(frame)) < area($1.intersection(frame)) } ?? main
        // The first screen is the one with the menu bar.
        let screen = area(most.intersection(frame)) > 0 ? most : main
        var fitted = frame
        fitted.size.width = min(frame.width, screen.width)
        fitted.size.height = min(frame.height, screen.height)
        fitted.origin.x = min(max(frame.minX, screen.minX), screen.maxX - fitted.width)
        fitted.origin.y = min(max(frame.minY, screen.minY), screen.maxY - fitted.height)
        return fitted
    }

    private init(board: CanvasBoardView, frame: NSRect?) {
        self.board = board
        canvas = board.store.url
        workspace = board.satelliteScope
        let window = CanvasSatelliteNSWindow(contentRect: frame ?? NSRect(x: 0, y: 0, width: 760, height: 620),
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

    /// A card new to the workspace that belongs out here: a link ⌘-clicked on one of this window's
    /// pages, or one handed to Folio while this window was in front. It joins as the last tab — the
    /// slot it was given in the tiling is this window's tile, so Bring Back and Gather agree.
    func adopt(_ card: CanvasNodeView, showing: Bool) {
        let before = shownCard
        take(card)
        guard cards.last === card else { return }
        showTab(showing ? cards.count - 1 : cards.firstIndex { $0 === before } ?? 0)
        CanvasSatelliteDock.shared.refresh()
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
        release(card)
        board?.satelliteReturned([id], showing: id, from: workspace, raisingWindow: true)
    }

    /// Close a tab — its ×, ⌘W, the tab's menu: the card home to the slot it kept, quietly, as closing
    /// the window is for every tab in it. The last tab is the window.
    func closeTab(_ index: Int) {
        guard cards.indices.contains(index) else { return }
        guard cards.count > 1 else { return close() }
        let card = cards[index]
        release(card)
        board?.satelliteReturned([card.node.id], showing: card.node.id, from: workspace, raisingWindow: false)
    }

    /// ⌘W: the tab showing, while there are several. False with one, for the window to close.
    func closeShownTab() -> Bool {
        guard cards.count > 1 else { return false }
        closeTab(shown)
        return true
    }

    /// Every tab but `index` home.
    func closeOtherTabs(_ index: Int) {
        guard cards.indices.contains(index) else { return }
        let keep = cards[index]
        for card in cards where card !== keep {
            if let at = cards.firstIndex(where: { $0 === card }) { closeTab(at) }
        }
    }

    /// A tab dragged along the row: its card's place in the window's order. The tab showing stays the
    /// one showing.
    func moveTab(from: Int, to: Int) {
        guard cards.indices.contains(from), cards.indices.contains(to), from != to else { return }
        let showing = shownCard
        let first = cardIDs.first ?? ""
        cards.insert(cards.remove(at: from), at: to)
        if first != cardIDs.first { CanvasSatellites.forget(first, canvas: canvas, workspace: workspace) }
        showTab(cards.firstIndex { $0 === showing } ?? 0)
        CanvasSatelliteDock.shared.refresh()
    }

    /// A tab out into a window of its own, at `frame` — or a step from this one.
    @discardableResult
    func moveTabToNewWindow(_ index: Int, frame: NSRect? = nil) -> CanvasSatelliteWindow? {
        guard cards.count > 1, cards.indices.contains(index), let board else { return nil }
        let card = cards[index]
        release(card)
        return board.moveToWindow([card.node.id], showing: card.node.id, frame: frame)
    }

    /// A tab dragged onto another of the board's satellites: it joins that window, showing.
    func moveTab(_ index: Int, to other: CanvasSatelliteWindow) {
        guard other !== self, other.board === board, cards.count > 1, cards.indices.contains(index) else { return }
        let card = cards[index]
        release(card)
        other.adopt(card, showing: true)
        other.window?.makeKeyAndOrderFront(nil)
    }

    /// Let a card go from this window without saying where it goes: its content back in the card and
    /// its tab gone, the tab beside it showing if it was the one showing. Not the last card — that is
    /// the window closing.
    private func release(_ card: CanvasNodeView) {
        guard let index = cards.firstIndex(where: { $0 === card }), cards.count > 1 else { return }
        let showing = shownCard
        let first = cardIDs.first ?? ""
        card.takeBack()
        cards.remove(at: index)
        if first != cardIDs.first { CanvasSatellites.forget(first, canvas: canvas, workspace: workspace) }
        showTab(cards.firstIndex { $0 === showing } ?? min(index, cards.count - 1))
        CanvasSatelliteDock.shared.refresh()
    }

    /// Where a tab let go at `point` on screen goes: onto another satellite of the board, into it; onto
    /// the board's own window, home; anywhere else, a window of its own there, this one's size.
    func dropTab(_ index: Int, atScreenPoint point: NSPoint) {
        guard cards.count > 1, cards.indices.contains(index), let board else { return }
        let under = NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0)
        if let other = Self.open.first(where: { $0 !== self && $0.board === board && $0.window?.windowNumber == under }) {
            return moveTab(index, to: other)
        }
        if let home = board.window, home.isVisible, home.windowNumber == under {
            return giveBack(cards[index])
        }
        let size = window?.frame.size ?? NSSize(width: 760, height: 620)
        moveTabToNewWindow(index, frame: NSRect(x: point.x - min(120, size.width / 2), y: point.y - size.height + 14,
                                                width: size.width, height: size.height))
    }

    private func showTab(_ index: Int) {
        let leaving = shownCard
        shown = max(0, min(index, cards.count - 1))
        for (i, card) in cards.enumerated() { card.cardContent?.isHidden = i != shown }
        if leaving !== shownCard, leaving?.isEngaged == true { leaving?.engage(false) }
        if window?.isKeyWindow == true {
            shownCard?.engage(true)
            // The project panel is the tab's to show or not (`CanvasSatelliteCompanion.isShown`).
            if leaving !== shownCard { CanvasSatelliteCompanion.shared.refresh() }
        }
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
        configure(forward, "chevron.forward", "Forward", #selector(goForward))
        configure(reload, "arrow.clockwise", "Reload", #selector(reloadPage))
        // Held, or right-clicked: where Back or Forward would go, several steps at once.
        back.history = { [weak self] in self?.historyMenu(back: true) }
        forward.history = { [weak self] in self?.historyMenu(back: false) }
        configure(bringBack, "arrow.down.left", "Bring Back to Workspace", #selector(returnToWorkspace))
        configure(gather, "rectangle.grid.2x2", "Gather Workspace", #selector(gatherWorkspace))
        configure(more, "ellipsis.circle", "More", #selector(showMenu))
        showButtons(false)
        findField.placeholderString = "Find in Page"
        findField.controlSize = .small
        findField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        findField.sendsSearchStringImmediately = false
        findField.sendsWholeSearchString = true
        findField.target = self
        findField.action = #selector(findFromField)
        findField.delegate = self
        findField.isHidden = true
        findField.widthAnchor.constraint(equalToConstant: 180).isActive = true
        let home = NSStackView(views: [findField, more, gather, bringBack])
        home.spacing = 0
        home.setCustomSpacing(6, after: findField)

        addressField.font = .systemFont(ofSize: 12)
        addressField.controlSize = .small
        addressField.bezelStyle = .roundedBezel
        addressField.lineBreakMode = .byTruncatingTail
        addressField.usesSingleLineMode = true
        addressField.cell?.isScrollable = true
        addressField.target = self
        addressField.action = #selector(goToTypedAddress)
        addressField.delegate = self
        addressField.isHidden = true

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
        tabs.onClose = { [weak self] in self?.closeTab($0) }
        tabs.onMove = { [weak self] in self?.moveTab(from: $0, to: $1) }
        tabs.onDropOutside = { [weak self] in self?.dropTab($0, atScreenPoint: $1) }
        tabs.menuForTab = { [weak self] in self?.tabMenu($0) }
        tabs.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
        let words = self.words
        for view in [mark, titleLabel, hostLabel, tabs, workspaceLabel] as [NSView] { words.addArrangedSubview(view) }
        words.orientation = .horizontal
        words.alignment = .centerY
        words.spacing = 6
        words.setCustomSpacing(8, after: mark)

        for view in [bar, line, back, forward, reload, home, words, addressField, stage] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        root.addSubview(stage)
        root.addSubview(reorderMark)
        root.addSubview(bar)
        for view in [line, back, forward, reload, home, words, addressField] as [NSView] { bar.addSubview(view) }
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
            forward.leadingAnchor.constraint(equalTo: back.trailingAnchor, constant: 2),
            forward.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            reload.leadingAnchor.constraint(equalTo: forward.trailingAnchor, constant: 2),
            reload.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            addressField.leadingAnchor.constraint(equalTo: reload.trailingAnchor, constant: 8),
            addressField.trailingAnchor.constraint(equalTo: home.leadingAnchor, constant: -8),
            addressField.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
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
        reorderMark.frame = root.bounds
        reorderMark.autoresizingMask = [.width, .height]
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

    func windowDidExitFullScreen(_ notification: Notification) {
        fitToTitleBar()
        fullScreenFrom = nil
        remember()
    }

    func windowWillEnterFullScreen(_ notification: Notification) { fullScreenFrom = window?.frame }
    func windowDidEnterFullScreen(_ notification: Notification) { remember() }
    func windowDidMiniaturize(_ notification: Notification) { remember() }
    func windowDidDeminiaturize(_ notification: Notification) { remember() }

    /// Where the window was before it went full screen — what it comes back to, and what is remembered.
    private var fullScreenFrom: NSRect?

    /// Minimized or in full screen again, as it was when it was remembered — see `restoreSatellites`.
    func restore(_ record: CanvasSatellites.Record) {
        guard let window else { return }
        if record.minimized == true {
            window.miniaturize(nil)
        } else if record.fullScreen == true, !window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
        }
    }

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
            page.observe(\.canGoForward) { [weak self] _, _ in MainActor.assumeIsolated { self?.describe() } },
            page.observe(\.isLoading) { [weak self] _, _ in MainActor.assumeIsolated { self?.describe() } },
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
        forward.isHidden = page == nil
        reload.isHidden = page == nil
        clearOfPage?.isActive = page != nil
        clearOfLights?.isActive = page == nil
        back.isEnabled = page?.canGoBack == true
        forward.isEnabled = page?.canGoForward == true
        // Reload is Stop while the page loads, as in a browser's toolbar.
        let loading = page?.isLoading == true
        reload.image = NSImage(systemSymbolName: loading ? "xmark" : "arrow.clockwise",
                               accessibilityDescription: loading ? "Stop" : "Reload")
        reload.toolTip = loading ? "Stop" : "Reload"
        if page == nil { endAddress(); endFind() }
        words.isHidden = !addressField.isHidden
        refreshPlaceholders()
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
        // From the sidebar's index, which read the notes off main — never the notes file here.
        let folder = CanvasProjectNoteCard.candidateProject(forCanvasAt: board.store.url).lastPathComponent
        let icon = ProjectIndex.shared.allProjects.first { $0.name == folder }
            .flatMap { entry in entry.icon?.resolved(notesPath: entry.notesPath) }
        projectMarkIcon = icon.flatMap { ProjectIconMark.canDraw($0) ? $0 : nil }
        let tint = wash.color?.swiftUIColor
        // In the title's ink rather than the project's colour, which the bar's wash already says: drawn
        // black and handed over as a template, for the image view to tint with the label colour as the
        // appearance changes. An emoji, or an image in colours of its own, keeps them.
        let ink = icon.map { ProjectIconMark.canDraw($0) && !ProjectIconMark.keepsOwnColors($0) } ?? false
        let drawn: AnyView? = if let icon, ProjectIconMark.canDraw(icon) {
            AnyView(ProjectIconMark(icon: icon, size: 14, tint: ink ? .black : tint))
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
        mark.image?.isTemplate = ink
        mark.contentTintColor = ink ? .labelColor : nil
        mark.isHidden = mark.image == nil
        markWidth?.constant = mark.image == nil ? 0 : 16
        // A space's board has no project: the space's name says where the window belongs instead.
        projectTitle = board.boardProject?.title ?? Self.spaceOf(board.store.url)?.title
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

    /// Nine slots retitled on validation with the tabs' own names, as a project window's are; and the
    /// page and zoom commands, which a satellite answers for its own card (see `Page commands`).
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if let answer = validatePageCommand(item) { return answer }
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
    @objc private func goForward() { page?.goForward() }
    @objc private func reloadPage() {
        guard let card = shownCard as? CanvasLinkNodeView else { return }
        if page?.isLoading == true { card.stopLoading() } else { card.reload() }
    }

    /// Back's or Forward's list, nearest first, for the button held down.
    private func historyMenu(back: Bool) -> NSMenu? {
        guard let page else { return nil }
        let list = back ? Array(page.backForwardList.backList.reversed()) : page.backForwardList.forwardList
        guard !list.isEmpty else { return nil }
        let menu = NSMenu()
        for item in list.prefix(20) {
            let title = item.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let entry = NSMenuItem(title: title.isEmpty ? item.url.host() ?? item.url.absoluteString : title,
                                   action: #selector(goToHistoryItem(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = item
            entry.toolTip = item.url.absoluteString
            menu.addItem(entry)
        }
        return menu
    }

    @objc private func goToHistoryItem(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? WKBackForwardListItem else { return }
        page?.go(to: item)
    }
    @objc private func returnToWorkspace() {
        guard !bringingBack else { return }
        bringingBack = true
        CanvasSatelliteFlight.home([self]) { [weak self] in self?.close() }
    }
    @objc private func gatherWorkspace() { board?.gatherWorkspace() }

    // MARK: A tab's menu

    /// Right-click on a tab: home, out on its own, closed.
    private func tabMenu(_ index: Int) -> NSMenu? {
        guard cards.indices.contains(index) else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        func add(_ title: String, _ action: Selector, enabled: Bool = true) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.tag = index
            item.isEnabled = enabled
            menu.addItem(item)
        }
        add(workspace.isEmpty ? "Bring Back" : "Bring Back to \(workspace)", #selector(bringBackTab(_:)))
        add("Move to New Window", #selector(tabToNewWindow(_:)), enabled: cards.count > 1)
        menu.addItem(.separator())
        add("Close Tab", #selector(closeTabFromMenu(_:)))
        add("Close Other Tabs", #selector(closeOtherTabsFromMenu(_:)), enabled: cards.count > 1)
        return menu
    }

    @objc private func bringBackTab(_ sender: NSMenuItem) {
        if cards.indices.contains(sender.tag) { giveBack(cards[sender.tag]) }
    }
    @objc private func tabToNewWindow(_ sender: NSMenuItem) { moveTabToNewWindow(sender.tag) }
    @objc private func closeTabFromMenu(_ sender: NSMenuItem) { closeTab(sender.tag) }
    @objc private func closeOtherTabsFromMenu(_ sender: NSMenuItem) { closeOtherTabs(sender.tag) }

    /// ⇧⌘W: the window, whatever its tabs — the project window's Close Window item, answered here.
    @objc func closeProjectWindow(_ sender: Any?) {
        (window as? CanvasSatelliteNSWindow)?.performCloseIgnoringTabs(sender)
    }

    // MARK: The menu

    /// The header's menu, built as it opens so it lists what is there now: the project panel on or off,
    /// then this workspace's other tiles, then the project's workspaces.
    @objc private func showMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let panel = NSMenuItem(title: "Show Project Panel", action: #selector(toggleProjectPanel), keyEquivalent: "")
        panel.target = self
        panel.state = CanvasSatelliteCompanion.isShown(beside: self) ? .on : .off
        // The panel is a project's: a board on a bare canvas file has none to show.
        panel.isEnabled = board?.boardProject != nil
        menu.addItem(panel)

        let tiles = otherTiles()
        if !tiles.isEmpty {
            menu.addItem(.separator())
            menu.addItem(.sectionHeader(title: "Tiles"))
            FaviconLoader.shared.warm(hosts: tiles.compactMap { card -> String? in
                if case .page(let host)? = board?.describeCard(card)?.kind { return host }
                return nil
            })
            for card in tiles {
                let described = board?.describeCard(card)
                let item = NSMenuItem(title: described?.title ?? "Card", action: #selector(openTile(_:)), keyEquivalent: "")
                item.target = self
                // The board's own card menus' icons: a page's site, else the card's symbol — what says
                // which tile is which when page titles don't.
                item.image = described.map { CanvasBoardView.menuIcon(for: $0.kind) }
                    ?? MenuPictures.symbol("text.alignleft", nil)
                MenuPictures.forceImageVisible(item)
                item.representedObject = card
                menu.addItem(item)
            }
        }

        let workspaces = CanvasWorkspaces.names(of: canvas)
        if !workspaces.isEmpty {
            menu.addItem(.separator())
            menu.addItem(.sectionHeader(title: "Workspaces"))
            for name in workspaces {
                let item = NSMenuItem(title: name, action: #selector(openWorkspace(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = name
                item.image = MenuPictures.symbol("rectangle.split.2x2", nil)
                MenuPictures.forceImageVisible(item)
                item.state = name == workspace ? .on : .off
                menu.addItem(item)
            }
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: more.bounds.maxY + 4), in: more)
    }

    /// The workspace's tiles that aren't this window — on its board or out in windows of their own — by
    /// the card each shows.
    private func otherTiles() -> [String] {
        guard let board, let session = board.tiling, board.satelliteScope == workspace else { return [] }
        let mine = Set(cardIDs)
        return session.columns.flatMap(\.tiles).filter { $0.cards.allSatisfy { !mine.contains($0) } }.map(\.shown)
    }

    @objc private func toggleProjectPanel() {
        CanvasSatelliteCompanion.setShown(!CanvasSatelliteCompanion.isShown(beside: self), beside: self)
    }

    /// A tile out in a window: that window forward, at the card. A tile on the board: the workspace's
    /// window forward with the tile picked out — it opens where it is rather than coming out, which
    /// would rearrange the workspace for a look.
    @objc private func openTile(_ sender: NSMenuItem) {
        guard let board, let id = sender.representedObject as? String, let card = board.nodeViews[id] else { return }
        if let out = card.lentTo { return out.reveal(card) }
        board.showWorkspaceWindow()
        board.select([id])
        if board.tiling?.hasTabs(id) == true { board.showTab(id) }
    }

    /// Another workspace in the project's window — a tab of its own, so this one stays out and its
    /// satellites with it. This workspace: its window forward.
    @objc private func openWorkspace(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        if name == workspace, let board { return board.showWorkspaceWindow() }
        ProjectWindowController.showWorkspace(name, projectKey: board?.boardProject?.key, canvas: canvas)
    }

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
            context.duration = 0.15  // motion: fade-only
            for button in [bringBack, gather, more] { button.animator().alphaValue = shown ? 1 : 0 }
        }
    }

    /// Put the window away with its workspace: the content goes back into the cards, and the window is
    /// remembered so the workspace can bring it out again.
    func putAway() {
        puttingAway = true
        close()
    }

    // MARK: Page commands

    // The menu bar's Page items, ⌘F and ⌘+ ⌘− ⌘0 are the board's — and the board is not in this
    // window's responder chain, so without these they were dim here: the window you moved a page into
    // to keep it up was the one place ⌘R and ⌘L did nothing. Same selectors, answered for the card
    // showing.

    private var linkCard: CanvasLinkNodeView? { shownCard as? CanvasLinkNodeView }

    @objc func pageBack(_ sender: Any?) { linkCard?.goBack() }
    @objc func pageForward(_ sender: Any?) { linkCard?.goForward() }
    @objc func pageReload(_ sender: Any?) { linkCard?.reload() }
    @objc func pageHardReload(_ sender: Any?) { linkCard?.hardReload() }
    @objc func pageHome(_ sender: Any?) { linkCard?.goHome() }
    @objc func pageOpenInBrowser(_ sender: Any?) { linkCard?.openInBrowser() }
    @objc func pageCopyAddress(_ sender: Any?) { linkCard?.copyAddress() }
    @objc func pagePrint(_ sender: Any?) { linkCard?.printPage() }
    @objc func pageToggleReader(_ sender: Any?) { linkCard?.toggleReader() }
    @objc func pageToggleMute(_ sender: Any?) {
        guard let card = linkCard else { return }
        card.setMuted(!card.isMuted)
    }
    @objc func pageOpenAsNewCard(_ sender: Any?) {
        if let card = linkCard { _ = board?.openPageAsNewCard(from: card) }
    }
    @objc func pageExportPDF(_ sender: Any?) { board?.pageExportPDF(sender) }
    @objc func setPageRefresh(_ sender: Any?) { board?.setPageRefresh(sender) }

    @objc func zoomIn(_ sender: Any?) { if let card = shownCard { board?.stepContentZoom(of: card, by: 1) } }
    @objc func zoomOut(_ sender: Any?) { if let card = shownCard { board?.stepContentZoom(of: card, by: -1) } }
    @objc func zoomActualSize(_ sender: Any?) { if let card = shownCard { board?.resetContentZoom(of: card) } }

    /// ⌘L: the address, typed over in the header — a satellite's address bar, as a project window's
    /// header field is its own.
    @objc func pageOpenAddress(_ sender: Any?) {
        guard let page else { return }
        addressField.stringValue = page.url?.absoluteString ?? linkCard?.liveURL?.absoluteString ?? ""
        addressField.isHidden = false
        words.isHidden = true
        window?.makeFirstResponder(addressField)
        addressField.currentEditor()?.selectAll(nil)
    }

    @objc private func goToTypedAddress() {
        // Return, not the field merely losing the keyboard.
        guard NSApp.currentEvent?.type == .keyDown else { return endAddress() }
        let typed = addressField.stringValue
        endAddress()
        guard let card = linkCard,
              let address = CanvasAddress.resolved(typed, engine: CanvasSearchEngine.current) else { return }
        card.go(to: address)
        window?.makeFirstResponder(page)
    }

    private func endAddress() {
        guard !addressField.isHidden else { return }
        addressField.isHidden = true
        words.isHidden = false
    }

    /// Edit ▸ Find, for a page: the header's find field, searching with WebKit's own find. A note's
    /// editor answers ⌘F itself before this is asked.
    @objc func performFindPanelAction(_ sender: Any?) {
        guard let card = linkCard else { return NSSound.beep() }
        let action = (sender as? NSMenuItem).map { NSTextFinder.Action(rawValue: $0.tag) } ?? .showFindInterface
        switch action {
        case .nextMatch, .previousMatch:
            let query = findField.stringValue
            guard !query.isEmpty else { return showFind() }
            card.find(query, forward: action == .nextMatch) { found in if !found { NSSound.beep() } }
        case .setSearchString:
            card.selectedText { [weak self] text in
                let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let self, !query.isEmpty else { return NSSound.beep() }
                findField.stringValue = query
                showFind()
                findFromField()
            }
        case .hideFindInterface:
            endFind()
        default:
            showFind()
        }
    }

    private func showFind() {
        findField.isHidden = false
        window?.makeFirstResponder(findField)
        findField.currentEditor()?.selectAll(nil)
    }

    @objc private func findFromField() {
        guard let card = linkCard, !findField.stringValue.isEmpty else { return }
        card.find(findField.stringValue) { found in if !found { NSSound.beep() } }
    }

    private func endFind() {
        guard !findField.isHidden else { return }
        findField.isHidden = true
        if window?.firstResponder === findField.currentEditor() { window?.makeFirstResponder(page) }
    }

    /// Nil for anything that isn't a page or zoom command.
    private func validatePageCommand(_ item: NSMenuItem) -> Bool? {
        let card = linkCard
        let running = card?.canPrint == true
        switch item.action {
        case #selector(pageBack(_:)): return page?.canGoBack == true
        case #selector(pageForward(_:)): return page?.canGoForward == true
        case #selector(pageReload(_:)):
            item.title = "Reload Page"
            return card != nil
        case #selector(pageHardReload(_:)):
            item.title = "Hard Reload"
            return card != nil
        case #selector(pageHome(_:)): return card?.hasWandered == true
        case #selector(pageOpenInBrowser(_:)), #selector(pageOpenAddress(_:)): return card != nil
        case #selector(pageOpenAsNewCard(_:)): return card?.liveURL != nil
        case #selector(pagePrint(_:)), #selector(pageExportPDF(_:)), #selector(pageToggleReader(_:)),
             #selector(pageCopyAddress(_:)):
            return running
        case #selector(pageToggleMute(_:)):
            item.title = card?.isMuted == true ? "Unmute Page" : "Mute Page"
            return running
        case #selector(setPageRefresh(_:)):
            return board?.validateUserInterfaceItem(item) ?? false
        case #selector(zoomIn(_:)), #selector(zoomOut(_:)), #selector(zoomActualSize(_:)):
            return shownCard?.zoomsItsContent == true
        case #selector(performFindPanelAction(_:)):
            switch NSTextFinder.Action(rawValue: item.tag) {
            case .showFindInterface?, .setSearchString?: return card != nil
            case .nextMatch?, .previousMatch?: return card != nil && !findField.stringValue.isEmpty
            case .hideFindInterface?: return !findField.isHidden
            default: return false
            }
        default: return nil
        }
    }

    /// What each card's tile on the board says while it is out here — its name and icon, as they are
    /// now: a page that has gone somewhere else since it came out is named for where it is.
    private func refreshPlaceholders() {
        for card in cards {
            let described = board?.describeCard(card.node.id)
            card.satelliteEmpty?.update(title: described?.title ?? "Card", image: Self.symbol(for: described?.kind))
        }
    }

    // MARK: Links

    /// A link in a card's content is the board's to follow when the card is on the board — see
    /// `CanvasLinkZones` — and there is no board here. So the window follows them itself: a press and
    /// release on the same link, the first click of a run, as on the board.
    ///
    /// A link in a list that reorders moves along it when dragged, as on the board: its row lit and a
    /// line where it would go (`CanvasLinkReorderMark`), let go to put it there — and not followed.
    private func watchLinks() {
        linkMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) {
            [weak self] event in
            MainActor.assumeIsolated {
                guard let self, event.window === self.window, let card = self.shownCard else { return event }
                return self.handleLink(event, on: card)
            }
        }
    }

    private func handleLink(_ event: NSEvent, on card: CanvasNodeView) -> NSEvent? {
        let point = event.locationInWindow
        switch event.type {
        case .leftMouseDown:
            let url = card.lentLink(atWindowPoint: point)
            linkPress = event.clickCount == 1 ? url : nil
            linkReorder = nil
            if url != nil, let row = card.lentLinkRow(atWindowPoint: point) {
                let rows = card.lentLinkRows(of: row.list)
                if rows.count > 1, rows.indices.contains(row.slot) {
                    linkReorder = LinkReorder(list: row.list, from: row.slot, rows: rows, start: point)
                }
            }
            return url == nil ? event : nil
        case .leftMouseDragged:
            guard linkPress != nil else { return event }
            guard var reorder = linkReorder,
                  reorder.to != nil || hypot(point.x - reorder.start.x, point.y - reorder.start.y) > 3 else { return nil }
            // Rows are in window coordinates, which run up: a row is passed once the pointer is below
            // its middle.
            reorder.to = reorder.rows.indices.filter { $0 != reorder.from && reorder.rows[$0].midY > point.y }.count
            linkReorder = reorder
            reorderMark.show(reorder.rows.map { reorderMark.convert($0, from: nil) }, from: reorder.from, to: reorder.to)
            return nil
        default:
            defer {
                linkPress = nil
                linkReorder = nil
                reorderMark.show([], from: 0, to: nil)
            }
            guard let pressed = linkPress else { return event }
            if let reorder = linkReorder, let to = reorder.to {
                if to != reorder.from { card.moveLink(in: reorder.list, from: reorder.from, to: to) }
                return nil
            }
            if card.lentLink(atWindowPoint: point) == pressed, !card.followsInPlace(pressed) {
                NSWorkspace.shared.open(pressed)
            }
            return nil
        }
    }

    /// A press on a link in a list that reorders, and where it would go.
    private struct LinkReorder {
        var list: UUID
        var from: Int
        var rows: [NSRect]
        var start: NSPoint
        var to: Int?
    }

    // MARK: NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        shownCard?.engage(true)
        CanvasSatelliteCompanion.shared.satelliteBecameKey(self)
        focusProject()
    }

    /// The board's project becomes the focused one, as a project window's does on becoming main
    /// (`ProjectWindowController.pushFocusToDisk`). A canvas that is no project's board moves nothing.
    private func focusProject() {
        // A space's satellite makes its space the one used last, as the space's window does.
        if board?.boardProject == nil, let canvas = board?.store.url, let space = Self.spaceOf(canvas) {
            Spaces.shared.lastUsed = space.id
        }
        guard let key = board?.boardProject?.key, key != PMFiles.focusedProjectKey() else { return }
        PMStore.setGlobalFocus(key: key) {
            (NSApp.delegate as? AppDelegate)?.syncFocusedStore()
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        if shownCard?.isEngaged == true { shownCard?.engage(false) }
    }

    /// ⌘Z here is the card's: a note's own typing, else the board's document.
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        guard let board else { return nil }
        return shownCard.flatMap(board.undoManager(forCard:)) ?? board.store.undoManager
    }

    func windowWillClose(_ notification: Notification) {
        // AppKit closes every window on the way out. Quitting puts a satellite away, to come back on
        // the next launch as it is now; its project window no longer does that for it
        // (`CanvasSatelliteKeeper`).
        if WindowManager.shared.quitting {
            remember()
            puttingAway = true
        }
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
        guard let window, !puttingAway, !cards.isEmpty,
              Self.open.contains(where: { $0 === self }) else { return }
        let fullScreen = window.styleMask.contains(.fullScreen)
        var record = CanvasSatellites.Record(cards: cardIDs, showing: shownCard?.node.id,
                                             frame: fullScreen ? fullScreenFrom ?? window.frame : window.frame)
        record.minimized = window.isMiniaturized
        record.fullScreen = fullScreen
        CanvasSatellites.remember(record, canvas: canvas, workspace: workspace)
    }
}

/// Which satellites each workspace had out, and where — so a workspace you come back to brings them
/// back. In user defaults beside `CanvasWorkspaces`, keyed by canvas and workspace name; a frame, not a
/// layout, so it stays out of the tiling's own equality (`CanvasViewState.Tiling`).
enum CanvasSatellites {
    static let defaultsKey = "PMCanvasSatellites"

    /// One window: its cards in tab order, the one showing, where it was — the windowed frame, for one
    /// in full screen — and whether it was minimized or in full screen. Nil in records from before
    /// those were kept.
    struct Record: Codable, Equatable {
        var cards: [String]
        var showing: String?
        var frame: String
        var minimized: Bool?
        var fullScreen: Bool?

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

// MARK: - The header's fields

extension CanvasSatelliteWindow: NSSearchFieldDelegate {
    /// Escape leaves the address or the find field, back to the page; ⇧Return in find goes back a
    /// match, as Safari's does.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)):
            if control === addressField { endAddress() } else { endFind() }
            window?.makeFirstResponder(page)
            return true
        case #selector(NSResponder.insertNewline(_:)) where control !== addressField
            && NSEvent.modifierFlags.contains(.shift):
            let previous = NSMenuItem()
            previous.tag = NSTextFinder.Action.previousMatch.rawValue
            performFindPanelAction(previous)
            return true
        default:
            return false
        }
    }

    /// An address left without Return goes back to the words, as it found them.
    func controlTextDidEndEditing(_ notification: Notification) {
        if (notification.object as? NSControl) === addressField { endAddress() }
    }
}

/// A satellite's window. **⌘W is the tab showing while there are several**, as a project window's is
/// the tile (`TextFocusWindow.performClose`); the last tab is the window. The close button and ⇧⌘W
/// are always the window.
@MainActor
final class CanvasSatelliteNSWindow: NSWindow {
    override func performClose(_ sender: Any?) {
        let closeButton = (sender as? NSButton).map { $0 === standardWindowButton(.closeButton) } ?? false
        if !closeButton, let satellite = windowController as? CanvasSatelliteWindow, satellite.closeShownTab() {
            return
        }
        super.performClose(sender)
    }

    /// The window itself, whatever its tabs — ⇧⌘W.
    func performCloseIgnoringTabs(_ sender: Any?) { super.performClose(sender) }
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
                      restoring: Bool = false, lifting: Bool = false) -> CanvasSatelliteWindow? {
        let cards = ids.compactMap { nodeViews[$0] }.filter { $0.lentTo == nil }
        guard !cards.isEmpty else { return nil }
        let satellite = CanvasSatelliteWindow.open(cards, showing: showing, frame: frame, on: self, lifting: lifting)
        CanvasSatelliteDock.shared.refresh()
        if !restoring, isAllOut, (tiling?.ids.count ?? 0) > 1 { putWindowAway() }
        return satellite
    }

    /// Cards into a satellite already up, as its last tabs — a tile dragged out of the window and let go
    /// over one. They keep their own slots in the tiling, as any card out in a window does.
    func moveToSatellite(_ ids: [String], showing: String?, into satellite: CanvasSatelliteWindow) {
        guard satellite.board === self else { return }
        let cards = ids.compactMap { nodeViews[$0] }.filter { $0.lentTo == nil }
        guard !cards.isEmpty else { return }
        for card in cards { satellite.adopt(card, showing: card.node.id == (showing ?? ids.first)) }
        satellite.window?.makeKeyAndOrderFront(nil)
        if isAllOut, (tiling?.ids.count ?? 0) > 1 { putWindowAway() }
    }

    /// Every card of the tile holding `id`, or `id` alone off the tiling.
    func tileCards(of id: String) -> [String] {
        guard let tiling, let at = tiling.position(of: id) else { return [id] }
        return tiling.columns[at.column].tiles[at.tile].cards
    }

    /// This board's satellite whose window is frontmost at a point on screen, if one is.
    func satellite(atScreenPoint point: NSPoint) -> CanvasSatelliteWindow? {
        let under = NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0)
        return satellites.first { $0.window?.windowNumber == under }
    }

    /// The workspace's window off the screen while every tile is out, remembered so a relaunch does the
    /// same. `showWorkspaceWindow` is the way back.
    func putWindowAway() {
        window?.orderOut(nil)
        CanvasSatellites.setPoppedOut(true, canvas: store.url, workspace: satelliteScope)
    }

    /// Move the whole tile holding `id` — every tab of it — into a window of its own.
    @discardableResult
    func moveTileToWindow(_ id: String, frame: NSRect? = nil, lifting: Bool = false) -> CanvasSatelliteWindow? {
        guard let tiling, let at = tiling.position(of: id) else {
            return moveToWindow([id], frame: frame, lifting: lifting)
        }
        let tile = tiling.columns[at.column].tiles[at.tile]
        return moveToWindow(tile.cards, showing: tile.shown, frame: frame, lifting: lifting)
    }

    /// A satellite has come home. Its cards kept their slots, so there is nothing to place.
    ///
    /// A card whose tile was removed while it was out goes back in beside the selection, as a new card
    /// would. And nothing is placed when the board has gone on to another workspace since — `scope` is
    /// where the satellite came from: its cards are in that workspace's saved tiling, and come back
    /// with it.
    ///
    /// **Bring Back brings the card home; the close button only closes.** Bring Back brings the window
    /// that has the workspace up into view (`showWindow(onWorkspace:)`), and picks the tile out at the
    /// card that was showing. Closing a window changes nothing else on screen: no window comes back or
    /// forward, the board's selection and tabs stay as they were, and a workspace window Pop Out put
    /// away stays away — the dock is the way back to it.
    func satelliteReturned(_ ids: [String], showing: String?, from scope: String, raisingWindow: Bool) {
        if var session = tiling, scope == satelliteScope {
            let missing = ids.filter { !session.cards.contains($0) && document.node(id: $0) != nil }
            if let first = missing.first {
                session.add(first, at: nextPlacement)
                for id in missing.dropFirst() { session.add(id, at: .init(target: first, side: .tab)) }
                tiling = session
                setLayout(session.layout, animated: true)
                onTilingChanged?()
                announceTiling()
            }
        }
        guard raisingWindow else { return }
        showWindow(onWorkspace: scope)
        guard let session = tiling, scope == satelliteScope,
              let front = showing.flatMap({ ids.contains($0) ? $0 : nil }) ?? ids.first,
              session.cards.contains(front) else { return }
        select([front])
        if session.hasTabs(front) { showTab(front) }
    }

    /// Bring Back's window: whichever has this canvas at `scope` up, brought into view — this board's,
    /// put away by Pop Out, behind other windows, minimised or on another of its tabs; else, when this
    /// board has gone on to another workspace, another window showing that one. None up, none opens.
    private func showWindow(onWorkspace scope: String) {
        if scope == satelliteScope, let window {
            guard window.isVisible || !isAllOut else { return }
            CanvasSatellites.setPoppedOut(false, canvas: store.url, workspace: scope)
            if isHiddenOrHasHiddenAncestor, let workspaceName { onGoToWorkspace(workspaceName) }
            return window.makeKeyAndOrderFront(nil)
        }
        WindowManager.shared.controllers.first { controller in
            guard !controller.isCarrier, let board = controller.canvasPane?.board else { return false }
            return board !== self && board.store.url == store.url && board.satelliteScope == scope
        }?.show()
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
                         frame: window.convertToScreen(convert(viewRect(frame), to: nil)), restoring: true,
                         lifting: true)
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
        // Every window's picture flies home into the slot its card ends up in, once the windows have gone.
        CanvasSatelliteFlight.home(out) { [weak self] in self?.gather(out) }
    }

    private func gather(_ out: [CanvasSatelliteWindow]) {
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
    ///
    /// Tiled or not: a card moved out of the free canvas is remembered as one from the canvas's own
    /// tiling is, under the same scope, and came back after a relaunch only if the canvas was tiled.
    func restoreSatellites() {
        DispatchQueue.main.async { [weak self] in
            guard let self, window != nil, !isHiddenOrHasHiddenAncestor else { return }
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
                moveToWindow(ids, showing: record.showing, frame: record.rect, restoring: true)?.restore(record)
            }
            if isAllOut, CanvasSatellites.isPoppedOut(canvas: store.url, workspace: satelliteScope) {
                window?.orderOut(nil)
            }
            CanvasSatelliteKeeper.satellitesRestored(on: self)
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
    /// The tab's × — shown in place of its icon under the pointer, as Safari's is.
    var onClose: (Int) -> Void = { _ in }
    /// A tab dragged along the row, as it passes its neighbours.
    var onMove: (_ from: Int, _ to: Int) -> Void = { _, _ in }
    /// A tab let go off the row — out past the header, or out of the window — at a point on screen.
    var onDropOutside: (_ index: Int, _ screenPoint: NSPoint) -> Void = { _, _ in }
    var menuForTab: (Int) -> NSMenu? = { _ in nil }
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
            context.duration = Motion.duration(Motion.Tempo.standard)
            context.timingFunction = Motion.Curve.out
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

    /// A press on a tab: a click picks it, or closes it on its ×; a drag along the row moves it among
    /// the others; a drag off the row takes it out, to wherever it is let go (`onDropOutside`).
    ///
    /// A loop of its own rather than a dragging session, because a tab is not data to hand to another
    /// app: it only ever goes to a window of Folio's, and the row reorders under the pointer as it goes.
    func track(_ button: CanvasSatelliteTabButton, from down: NSEvent) {
        guard let window else { return }
        var index = button.tag
        if button.isOnClose(down) {
            // Closed on mouse-up over the same ×, as a button is.
            while let next = window.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
                if next.type == .leftMouseUp {
                    if button.isOnClose(next) { onClose(index) }
                    return
                }
            }
            return
        }
        let start = down.locationInWindow
        var dragging = false
        var outside = false
        while let next = window.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
            let point = next.locationInWindow
            if next.type == .leftMouseUp {
                NSCursor.arrow.set()
                buttons.forEach { $0.alphaValue = 1 }
                if !dragging { return onSelect(index) }
                if outside { onDropOutside(index, window.convertPoint(toScreen: point)) }
                return
            }
            if !dragging, hypot(point.x - start.x, point.y - start.y) < 4 { continue }
            dragging = true
            // Off the row: more than a header's height above or below it, or out of the window.
            let local = convert(point, from: nil)
            let off = local.y < -Self.tearDistance || local.y > bounds.height + Self.tearDistance
                || !window.frame.contains(window.convertPoint(toScreen: point))
            if off != outside {
                outside = off
                (off ? NSCursor.dragCopy : NSCursor.arrow).set()
                if buttons.indices.contains(index) { buttons[index].alphaValue = off ? 0.4 : 1 }
            }
            guard !off else { continue }
            // Along the row: its place is after every other tab whose middle it has passed.
            let mids = buttons.enumerated().filter { $0.offset != index }.map { convert($0.element.frame, from: row).midX }
            let target = mids.filter { $0 < local.x }.count
            if target != index {
                onMove(index, target)
                index = target
            }
        }
    }

    /// How far off the row, up or down, a tab has to go before it is coming out rather than moving.
    static let tearDistance: CGFloat = 24
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
        icon = image
        showIcon()
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

    override func mouseEntered(with event: NSEvent) { hovered = true; showIcon() }
    override func mouseExited(with event: NSEvent) { hovered = false; showIcon() }

    private var icon: NSImage?
    private static let closeImage = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Tab")?
        .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))

    /// The card's icon, or the × in its place while the pointer is over the tab.
    private func showIcon() {
        image = hovered ? Self.closeImage : icon
        toolTip = hovered ? nil : title
        invalidateIntrinsicContentSize()
    }

    /// Whether `event` is on the ×: the icon's place, with the pointer over the tab.
    func isOnClose(_ event: NSEvent) -> Bool {
        guard hovered, let cell = cell as? NSButtonCell else { return false }
        let point = convert(event.locationInWindow, from: nil)
        return cell.imageRect(forBounds: bounds).insetBy(dx: -4, dy: -4).contains(point)
    }

    override func mouseDown(with event: NSEvent) {
        guard let tabs = superview?.superview as? CanvasSatelliteTabs else { return super.mouseDown(with: event) }
        tabs.track(self, from: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        (superview?.superview as? CanvasSatelliteTabs)?.menuForTab(tag)
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        super.updateLayer()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = hovered && !showing ? NSColor.labelColor.withAlphaComponent(0.07).cgColor : nil
        }
    }
}

/// A link being dragged along its list in a satellite: its row lit, and a line where it would go — the
/// board's own mark (`CanvasOverlayView.drawLinkReorder`), at the window's scale.
@MainActor
final class CanvasLinkReorderMark: NSView {
    private var rows: [NSRect] = []
    private var from = 0
    private var to: Int?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ rows: [NSRect], from: Int, to: Int?) {
        self.rows = rows
        self.from = from
        self.to = to
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let to, rows.indices.contains(from) else { return }
        let accent = NSColor.controlAccentColor
        accent.withAlphaComponent(0.12).setFill()
        NSBezierPath(roundedRect: rows[from].insetBy(dx: -4, dy: -1), xRadius: 4, yRadius: 4).fill()
        guard to != from else { return }
        // In this view's coordinates, which run up: the rows in list order go down the screen.
        let others = rows.enumerated().filter { $0.offset != from }.map(\.element)
        let left = rows.map(\.minX).min() ?? 0
        let right = rows.map(\.maxX).max() ?? 0
        let y: CGFloat
        if to == 0 { y = others[0].maxY + 1.5 }
        else if to >= others.count { y = others[others.count - 1].minY - 1.5 }
        else { y = (others[to - 1].minY + others[to].maxY) / 2 }
        accent.setFill()
        NSBezierPath(roundedRect: NSRect(x: left - 4, y: y - 1, width: right - left + 8, height: 2),
                     xRadius: 1, yRadius: 1).fill()
    }
}

/// Back or Forward in a satellite's header: a click goes one step; held down, or right-clicked, it
/// lists the steps it could go, as a browser's does.
@MainActor
final class CanvasHistoryButton: NSButton {
    /// The steps, nearest first — nil when there are none.
    var history: () -> NSMenu? = { nil }
    /// How long a press is held before it is asking for the list.
    static let holdDelay: TimeInterval = 0.4

    override func mouseDown(with event: NSEvent) {
        guard isEnabled, let window else { return super.mouseDown(with: event) }
        highlight(true)
        let up = window.nextEvent(matching: [.leftMouseUp], until: Date(timeIntervalSinceNow: Self.holdDelay),
                                  inMode: .eventTracking, dequeue: true)
        highlight(false)
        if let up {
            if bounds.contains(convert(up.locationInWindow, from: nil)) { sendAction(action, to: target) }
            return
        }
        showHistory()
    }

    override func menu(for event: NSEvent) -> NSMenu? { isEnabled ? history() : nil }

    private func showHistory() {
        guard let menu = history() else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.maxY + 4), in: self)
    }
}
