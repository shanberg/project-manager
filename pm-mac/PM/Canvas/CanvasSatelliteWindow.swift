import AppKit
import WebKit

/// A web tile moved out into a window of its own — a satellite of the workspace it came from.
///
/// **For the page that has to stay up while you work beside it**: a call, a huddle, a dashboard on the
/// other screen. A tile is always a share of the window it's in; a satellite is a page you can put
/// anywhere, at any size, and still have belong to the workspace — switching to another workspace puts
/// it away, and coming back brings it out again where it was. See `CanvasBoardView.restoreSatellites`.
///
/// **The page stays the card's.** The web view is lent to the window, not given: the card still owns
/// it, its budget leaves it running (`CanvasLinkNodeView.freeze`), and no other board can take it
/// (`giveUpPage`). Returning is putting the view back in the card, so nothing reloads either way.
///
/// **A lean header** rather than a browser's: whose page it is, Back and Reload, and the way home.
/// AppKit controls rather than SwiftUI ones, since the header sits in the title bar's drag band and
/// only controls carve their clicks out of it.
@MainActor
final class CanvasSatelliteWindow: NSWindowController, NSWindowDelegate {
    /// Every satellite up, in every window.
    private(set) static var open: [CanvasSatelliteWindow] = []

    private(set) weak var card: CanvasLinkNodeView?
    let page: WKWebView
    let cardID: String
    /// Where it is remembered: the canvas and the workspace it belongs to.
    let canvas: URL
    let workspace: String

    /// Set while the window is going away because its workspace is — which puts it away rather than
    /// sending it home, so it comes back with the workspace.
    private var puttingAway = false
    private let titleLabel = NSTextField(labelWithString: "")
    private let hostLabel = NSTextField(labelWithString: "")
    private let back = NSButton()
    private var watches: [NSKeyValueObservation] = []

    static let headerHeight: CGFloat = 38

    init(card: CanvasLinkNodeView, page: WKWebView, frame: NSRect?) {
        self.card = card
        self.page = page
        cardID = card.node.id
        canvas = card.board.store.url
        workspace = card.board.satelliteScope
        let window = NSWindow(contentRect: frame ?? NSRect(x: 0, y: 0, width: 760, height: 620),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 320, height: 240)
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self
        window.contentView = content()
        watches = [
            page.observe(\.title) { [weak self] _, _ in MainActor.assumeIsolated { self?.describe() } },
            page.observe(\.url) { [weak self] _, _ in MainActor.assumeIsolated { self?.describe() } },
            page.observe(\.canGoBack) { [weak self] _, _ in MainActor.assumeIsolated { self?.describe() } },
        ]
        describe()
        if frame == nil { window.center() }
        Self.open.append(self)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: The window

    private func content() -> NSView {
        let root = NSView()
        let bar = NSVisualEffectView()
        bar.material = .titlebar
        bar.blendingMode = .withinWindow
        let line = NSBox()
        line.boxType = .separator

        back.image = NSImage(systemSymbolName: "chevron.backward", accessibilityDescription: "Back")
        back.target = self
        back.action = #selector(goBack)
        back.toolTip = "Back"
        let reload = Self.glyph("arrow.clockwise", "Reload", #selector(reloadPage), self)
        let home = Self.glyph("rectangle.inset.filled.and.arrow.down", "Return to Workspace",
                              #selector(returnToWorkspace), self)
        home.toolTip = "Put this back in its workspace"
        for button in [back, reload, home] { Self.style(button) }

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        hostLabel.font = .systemFont(ofSize: 11)
        hostLabel.textColor = .secondaryLabelColor
        hostLabel.lineBreakMode = .byTruncatingMiddle
        let words = NSStackView(views: [titleLabel, hostLabel])
        words.orientation = .vertical
        words.alignment = .centerX
        words.spacing = 0

        for view in [bar, line, back, reload, home, words, page] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        root.addSubview(page)
        root.addSubview(bar)
        for view in [line, back, reload, home, words] as [NSView] { bar.addSubview(view) }
        // Clear of the traffic lights, which sit at the leading edge of the title bar.
        let lights = window?.standardWindowButton(.zoomButton).map { $0.frame.maxX + 14 } ?? 78
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
            words.centerXAnchor.constraint(equalTo: bar.centerXAnchor),
            words.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            words.leadingAnchor.constraint(greaterThanOrEqualTo: reload.trailingAnchor, constant: 12),
            words.trailingAnchor.constraint(lessThanOrEqualTo: home.leadingAnchor, constant: -12),
            page.topAnchor.constraint(equalTo: bar.bottomAnchor),
            page.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            page.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        return root
    }

    private static func glyph(_ symbol: String, _ label: String, _ action: Selector, _ target: AnyObject) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label) ?? NSImage(),
                              target: target, action: action)
        button.toolTip = label
        return button
    }

    private static func style(_ button: NSButton) {
        button.bezelStyle = .accessoryBarAction
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.symbolConfiguration = .init(pointSize: 14, weight: .regular)
        button.contentTintColor = .secondaryLabelColor
        button.widthAnchor.constraint(equalToConstant: 28).isActive = true
        button.heightAnchor.constraint(equalToConstant: 24).isActive = true
    }

    /// The page's title, and whose page it is — the host is the half that matters when a page asks for
    /// a password, which is why it is always there.
    private func describe() {
        let host = page.url?.host() ?? ""
        let title = page.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        titleLabel.stringValue = title.isEmpty ? host : title
        hostLabel.stringValue = host
        hostLabel.isHidden = title.isEmpty
        window?.title = title.isEmpty ? host : title
        back.isEnabled = page.canGoBack
    }

    @objc private func goBack() { page.goBack() }
    @objc private func reloadPage() { page.reload() }
    @objc private func returnToWorkspace() { close() }

    func show() {
        showWindow(nil)
        window?.makeFirstResponder(page)
        remember()
    }

    /// The card's page is ending — rebuilt for a changed setting, or its address changed — so the
    /// window has nothing to show. It closes, and the tile goes home.
    func pageEnded() { close() }

    /// Put the window away with its workspace: the page goes back into the card, and the window is
    /// remembered so the workspace can bring it out again.
    func putAway() {
        puttingAway = true
        close()
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        watches = []
        Self.open.removeAll { $0 === self }
        if !puttingAway { CanvasSatellites.forget(card: cardID, canvas: canvas, workspace: workspace) }
        page.removeFromSuperview()
        if let card {
            card.returnFromSatellite(toWorkspace: !puttingAway)
        } else {
            // The card has gone from the board while its page was out here, and nothing else holds it.
            page.stopLoading()
        }
    }

    func windowDidMove(_ notification: Notification) { remember() }
    func windowDidEndLiveResize(_ notification: Notification) { remember() }

    private func remember() {
        guard let frame = window?.frame, !puttingAway, Self.open.contains(where: { $0 === self }) else { return }
        CanvasSatellites.remember(card: cardID, frame: frame, canvas: canvas, workspace: workspace)
    }
}

/// Which satellites each workspace had out, and where — so a workspace you come back to brings them
/// back. In user defaults beside `CanvasWorkspaces`, keyed by canvas and workspace name; a frame, not a
/// layout, so it stays out of the tiling's own equality (`CanvasViewState.Tiling`).
enum CanvasSatellites {
    static let defaultsKey = "PMCanvasSatellites"

    static func frames(canvas: URL, workspace: String,
                       in defaults: UserDefaults = .standard) -> [String: NSRect] {
        let stored = defaults.dictionary(forKey: defaultsKey)?[key(canvas, workspace)] as? [String: String] ?? [:]
        return stored.mapValues(NSRectFromString)
    }

    static func remember(card: String, frame: NSRect, canvas: URL, workspace: String,
                         in defaults: UserDefaults = .standard) {
        change(canvas, workspace, in: defaults) { $0[card] = NSStringFromRect(frame) }
    }

    static func forget(card: String, canvas: URL, workspace: String, in defaults: UserDefaults = .standard) {
        change(canvas, workspace, in: defaults) { $0[card] = nil }
    }

    private static func change(_ canvas: URL, _ workspace: String, in defaults: UserDefaults,
                               _ edit: (inout [String: String]) -> Void) {
        var all = defaults.dictionary(forKey: defaultsKey) ?? [:]
        let key = key(canvas, workspace)
        var cards = all[key] as? [String: String] ?? [:]
        edit(&cards)
        all[key] = cards.isEmpty ? nil : cards
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
        CanvasSatelliteWindow.open.filter { $0.card?.board === self }
    }

    /// Move a web tile's page into a window of its own. The tile leaves the tiling, so the rest close
    /// up round the gap — unless it is the only one, which a tiling can't lose, so it stays and says
    /// where its page has gone.
    func moveToWindow(_ id: String, frame: NSRect? = nil) {
        guard let card = nodeViews[id] as? CanvasLinkNodeView, card.satellite == nil else { return }
        let home = returnPlacement(for: id)
        // The page goes out first: a tile leaving the tiling is a card the board may stop keeping, and
        // it is being lent out that tells the board to keep it (`isHeldElsewhere`).
        card.moveToSatellite(frame: frame)
        guard card.satellite != nil else { return }
        if let tiling, tiling.cards.contains(id), tiling.cards.count > 1 {
            satelliteHomes[id] = home
            removeFromTiling(id)
        }
    }

    /// A satellite has come home: its tile goes back where it was, beside the tile it was next to.
    func satelliteReturned(_ id: String) {
        let home = satelliteHomes.removeValue(forKey: id)
        guard var session = tiling, !session.cards.contains(id), document.node(id: id) != nil else { return }
        let placement = home.flatMap { session.cards.contains($0.target) ? $0 : nil } ?? nextPlacement
        session.add(id, at: placement)
        tiling = session
        select([id])
        setLayout(session.layout, animated: true)
        onTilingChanged?()
        announceTiling()
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
            let frames = CanvasSatellites.frames(canvas: store.url, workspace: satelliteScope)
            for (id, frame) in frames where document.node(id: id) != nil {
                if nodeViews[id] == nil { refreshNodeViews() }
                moveToWindow(id, frame: frame)
            }
        }
    }

    /// The place a tile would go back to: beside a neighbour in its column, else beside the next column.
    private func returnPlacement(for id: String) -> CanvasTileSession.Placement? {
        guard let tiling, let at = tiling.position(of: id) else { return nil }
        let column = tiling.columns[at.column].tiles
        if at.tile > 0, let above = column[at.tile - 1].cards.first { return .init(target: above, side: .below) }
        if at.tile + 1 < column.count, let below = column[at.tile + 1].cards.first {
            return .init(target: below, side: .above)
        }
        if at.column > 0, let left = tiling.columns[at.column - 1].tiles.first?.cards.first {
            return .init(target: left, side: .right)
        }
        if at.column + 1 < tiling.columns.count, let right = tiling.columns[at.column + 1].tiles.first?.cards.first {
            return .init(target: right, side: .left)
        }
        return nil
    }
}
