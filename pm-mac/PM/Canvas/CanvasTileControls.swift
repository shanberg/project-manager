import AppKit
import SwiftUI

/// The tile grip's controls, on every board's layouts: a capsule that unfolds from the middle, under the grip.
/// Decided in `.claude/mocks/folio-tile-grip.html`; docs/spaces.md § The frame.
///
/// - Opens when the pointer rests on the grip for 0.3s, or on a click on it. A click never closes it.
/// - A tile with tabs across its top has no grip: its showing tab is the handle, and the capsule drops
///   from under that tab instead (`CanvasBoardView.showingTopTab`; `.claude/mocks/folio-tab-handle.html`).
/// - The grip stays above it and still drags the tile.
/// - Back, Forward, Reload, the site (click to edit the address, with the address field's suggestions),
///   then Pin, Favourite (in a space only), Maximize, Out of the layout, More (the tile's menu). A tile
///   that isn't a web page has the second half only.
/// - Closes 0.45s after the pointer leaves both grip and capsule (never while editing), when its tile
///   leaves the layout, and when the window resizes.
/// - Motion (`.claude/mocks/folio-spaces-motion.html`): drops 4pt into place with a fade (0.16s); going
///   after the pointer leaves, it rises back and fades quicker (0.12s), and every other close is a cut.
///   Widens and narrows round the address field (0.18s). Pin and Favourite replace their symbols and
///   bounce once turning on; Maximize replaces; Reload is Stop while the page loads; a press shrinks a
///   control to 92%.
@MainActor
final class CanvasTileControls {
    static let shared = CanvasTileControls()

    static let restDelay = 0.3
    static let leaveDelay = 0.45

    let model = Model()
    private weak var board: CanvasBoardView?
    private(set) var tile: String?
    private var host: Host?
    private var rest: DispatchWorkItem?
    private var leave: DispatchWorkItem?
    private var pointerInCapsule = false
    private var pointerOnGrip = false
    /// The tile whose handle — grip or showing tab — the pointer is resting on.
    private var restingOn: String?
    private var resizeWatch: NSObjectProtocol?

    func isOpen(on board: CanvasBoardView, tile id: String) -> Bool { self.board === board && tile == id && host != nil }

    // MARK: The grip

    func gripEntered(_ board: CanvasBoardView, tile id: String) {
        pointerOnGrip = true
        restingOn = id
        leave?.cancel()
        guard board.gripOpensControls, !isOpen(on: board, tile: id) else { return }
        rest?.cancel()
        let work = DispatchWorkItem { [weak self, weak board] in
            guard let self, let board, self.pointerOnGrip, self.restingOn == id else { return }
            self.open(on: board, tile: id)
        }
        rest = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.restDelay, execute: work)
    }

    func gripExited() {
        pointerOnGrip = false
        restingOn = nil
        rest?.cancel()
        scheduleLeave()
    }

    /// The pointer left a tile's handle — said by a tab strip about one tab, so it only counts when that
    /// tab is the handle the pointer was resting on.
    func handleExited(_ id: String) {
        guard restingOn == id else { return }
        gripExited()
    }

    func gripClicked(_ board: CanvasBoardView, tile id: String) {
        guard board.gripOpensControls else { return }
        rest?.cancel()
        // Only ever opens: a click on the grip of an open capsule leaves it open. The press hid the grips
        // (it began a tile drag in case); the release puts them back.
        if !isOpen(on: board, tile: id) { open(on: board, tile: id) }
        board.refreshTileHandles()
        board.tileGripView.needsDisplay = true
    }

    // MARK: Opening and closing

    func open(on board: CanvasBoardView, tile id: String) {
        close()
        guard let content = board.window?.contentView else { return }
        self.board = board
        tile = id
        model.editing = false
        model.presented = false
        refresh()
        let made = Host(controls: self)
        content.addSubview(made, positioned: .above, relativeTo: nil)
        host = made
        place()
        board.refreshTileHandles()
        resizeWatch = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification,
                                                             object: board.window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    func close() {
        rest?.cancel()
        leave?.cancel()
        if let resizeWatch { NotificationCenter.default.removeObserver(resizeWatch) }
        resizeWatch = nil
        host?.removeFromSuperview()
        host = nil
        pointerInCapsule = false
        model.editing = false
        let board = self.board
        tile = nil
        self.board = nil
        board?.refreshTileHandles()
    }

    /// The pointer left it: back up into the grip with a fade, then gone. Quicker than it came.
    private func dismiss() {
        guard let leaving = host else { return }
        rest?.cancel()
        leave?.cancel()
        withAnimation(.easeIn(duration: Motion.Tempo.exit)) { model.presented = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + Motion.Tempo.exit) { [weak self] in
            guard let self, self.host === leaving, !self.model.presented else { return }
            self.close()
        }
    }

    private func scheduleLeave() {
        guard host != nil else { return }
        leave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.pointerInCapsule, !self.pointerOnGrip, !self.model.editing else { return }
            self.dismiss()
        }
        leave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.leaveDelay, execute: work)
    }

    fileprivate func capsuleHover(_ inside: Bool) {
        pointerInCapsule = inside
        if inside { leave?.cancel() } else { scheduleLeave() }
    }

    /// The board laid out or redrew: keep the capsule under its handle, or close it if the handle has gone.
    func follow(_ board: CanvasBoardView) {
        guard self.board === board, host != nil else { return }
        guard let tile, board.tiling?.ids.contains(tile) == true, board.tileControlsAnchor(tile) != nil else { return close() }
        place()
    }

    private func place() {
        guard let board, let tile, let host, let content = host.superview,
              let anchor = board.tileControlsAnchor(tile), let frame = board.tiling?.layout.frames[tile] else { return }
        let grips = board.tileGripView
        let bar = content.convert(grips.convert(board.viewRect(anchor), to: nil), from: nil)
        let tileRect = content.convert(grips.convert(board.viewRect(frame), to: nil), from: nil)
        let size = host.measure()
        let margin = Host.margin
        var x = bar.midX - size.width / 2
        x = min(max(x, tileRect.minX + 6 - margin), tileRect.maxX - 6 + margin - size.width)
        // The capsule's top 4pt under the grip's mark or the tab, whichever way up the content view is.
        let y = content.isFlipped ? bar.maxY + 4 - margin : bar.minY - 4 + margin - size.height
        let next = NSRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
        if host.frame != next { host.frame = next }
    }

    // MARK: What it shows

    private var card: CanvasLinkNodeView? {
        guard let board, let tile else { return nil }
        return board.nodeViews[tile] as? CanvasLinkNodeView
    }

    private var frame: SpaceFrame? { (board?.window?.windowController as? ProjectWindowController)?.spaceFrame }

    /// Read the tile's state again: on opening, after an action, and when its page changes.
    func refresh() {
        guard let board, let tile, let node = board.document.node(id: tile) else { return }
        let card = self.card
        model.isWeb = card != nil
        model.loading = card?.isLoading ?? false
        model.canBack = card?.canGoBack ?? false
        model.canForward = card?.canGoForward ?? false
        let url = card?.liveURL
        model.site = url.map { CanvasAddressSuggestions.bare($0.host() ?? $0.absoluteString) } ?? ""
        model.secure = url?.scheme == "https"
        model.address = url?.absoluteString ?? ""
        model.inSpace = frame != nil
        model.pinned = SpaceCardMarks.isPinned(node)
        model.favorite = SpaceCardMarks.isFavorite(node)
        model.maximized = board.tiling?.maximized == tile
        model.canMaximize = (board.tiling?.ids.count ?? 0) > 1
        if host != nil { DispatchQueue.main.async { [weak self] in self?.place() } }
    }

    // MARK: Actions

    func back() { card?.goBack(); later() }
    func forward() { card?.goForward(); later() }
    func reload() {
        card?.reload()
        model.loading = true
    }

    func stop() {
        card?.stopLoading()
        model.loading = false
    }

    func editAddress() {
        guard let board else { return }
        model.candidates = CanvasHistory.candidates(board: board.document.nodes, back: card?.backSteps ?? [])
        model.draft = model.address
        model.editing = true
        model.focusToken &+= 1
        DispatchQueue.main.async { [weak self] in self?.place() }
    }

    func go(_ address: String?) {
        model.editing = false
        if let address { card?.go(to: address) }
        later()
        DispatchQueue.main.async { [weak self] in self?.place() }
        if !pointerInCapsule { scheduleLeave() }
    }

    func togglePinned() {
        guard let tile, let frame else { return }
        frame.setPinned(tile, !model.pinned)
        model.pinned.toggle()   // at once, so the symbol answers the click rather than the refresh
        later()
    }

    func toggleFavorite() {
        guard let tile, let frame else { return }
        frame.setFavorite(tile, !model.favorite)
        model.favorite.toggle()
        later()
    }

    func toggleMaximize() {
        guard let board, let tile else { return }
        board.toggleMaximizeTile(tile)
        model.maximized = board.tiling?.maximized == tile
        later()
    }

    /// Out of the layout, as ⌘W: the card stays on the board (and a space's sidebar); ⌘Z or ⇧⌘T puts
    /// it back.
    func outOfLayout() {
        guard let board, let tile else { return }
        let frame = self.frame
        close()
        if let frame { frame.closeTile(tile) } else { board.closeTileRemembering(tile, inSpace: nil) }
    }

    func more(from view: NSView) {
        guard let board, let tile else { return }
        board.select([tile])
        guard let menu = board.cardActionsMenu() else { return }
        leave?.cancel()
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height + 4), in: view)
        later()
    }

    private func later() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.refresh() }
    }

    // MARK: -

    @Observable
    final class Model {
        var isWeb = false
        var inSpace = false
        var canBack = false
        var canForward = false
        var site = ""
        var secure = true
        var address = ""
        var pinned = false
        var favorite = false
        var maximized = false
        var canMaximize = true
        var editing = false
        /// Down and in place; false while arriving and while going.
        var presented = false
        var loading = false
        var draft = ""
        var focusToken = 0
        var candidates: [CanvasAddressSuggestions.Candidate] = []
    }

    /// The capsule's view: a control, so the titlebar band over a top tile doesn't take its presses for
    /// a window drag (`WindowDragBlocker`), holding the SwiftUI capsule with room round it for the shadow.
    final class Host: WindowDragBlocker {
        static let margin: CGFloat = 10
        private let hosting: NSHostingView<CanvasTileControlsView>
        private weak var controls: CanvasTileControls?

        init(controls: CanvasTileControls) {
            self.controls = controls
            hosting = NSHostingView(rootView: CanvasTileControlsView(controls: controls, model: controls.model))
            super.init(frame: .zero)
            // Sized by `measure`, not by the hosting view's own constraints, which report a provisional
            // size before SwiftUI has laid out and then change it.
            hosting.sizingOptions = []
            // It sits in the titlebar's band over a top tile, and a hosting view there pushes its content
            // down out of the titlebar's safe area — 28pt lower than its frame, which is where it was.
            hosting.safeAreaRegions = []
            hosting.autoresizingMask = [.width, .height]
            addSubview(hosting)
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                           owner: self))
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        /// The capsule's row is a fixed height; only its width depends on what's in it.
        static let height: CGFloat = 32 + 2 * margin

        /// Asked of a hosting controller, which answers for the current model straight away; the view's
        /// own size settles a pass later, which is what moved the capsule after it appeared.
        private lazy var measurer: NSHostingController<CanvasTileControlsView>? = controls.map {
            NSHostingController(rootView: CanvasTileControlsView(controls: $0, model: $0.model))
        }

        func measure() -> NSSize {
            let width = measurer?.sizeThatFits(in: NSSize(width: 4000, height: Self.height)).width ?? 300
            return NSSize(width: ceil(width), height: Self.height)
        }

        override func setFrameSize(_ size: NSSize) {
            super.setFrameSize(size)
            hosting.frame = bounds
        }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseEntered(with event: NSEvent) { controls?.capsuleHover(true) }
        override func mouseExited(with event: NSEvent) { controls?.capsuleHover(false) }

        /// Only the capsule takes the pointer, not the room round it for the shadow.
        override func hitTest(_ point: NSPoint) -> NSView? {
            let local = convert(point, from: superview)
            guard controls?.model.presented ?? false,
                  bounds.insetBy(dx: Self.margin, dy: Self.margin).contains(local) else { return nil }
            return super.hitTest(point)
        }
    }
}

struct CanvasTileControlsView: View {
    let controls: CanvasTileControls
    @Bindable var model: CanvasTileControls.Model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        capsule
            // Drops 4pt into place with a fade; rises back the same way when it goes. Chosen over
            // scaling up out of its middle, which in a narrow tile isn't under the grip at all. Under
            // Reduce Motion, the fade alone.
            .offset(y: model.presented || reduceMotion ? 0 : -4)
            .opacity(model.presented ? 1 : 0)
            .padding(CanvasTileControls.Host.margin)
            .frame(height: CanvasTileControls.Host.height, alignment: .top)
            .ignoresSafeArea()
            .fixedSize(horizontal: true, vertical: false)
            .onAppear {
                withAnimation(.easeOut(duration: reduceMotion ? Motion.Tempo.quick : 0.16)) { model.presented = true }  // motion: fade-only under Reduce Motion
            }
    }

    private var capsule: some View {
        HStack(spacing: 2) {
            if model.isWeb {
                icon("chevron.left", "Back") { controls.back() }.disabled(!model.canBack)
                icon("chevron.right", "Forward") { controls.forward() }.disabled(!model.canForward)
                // Stop while the page loads, as Safari's: one control, so the symbol replaces in place.
                icon(model.loading ? "xmark" : "arrow.clockwise", model.loading ? "Stop" : "Reload") {
                    if model.loading { controls.stop() } else { controls.reload() }
                }
                address
                Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1, height: 16).padding(.horizontal, 2)
            }
            if model.inSpace {
                icon("pin", model.pinned ? "Unpin" : "Pin", on: model.pinned, bounces: true) { controls.togglePinned() }
                icon("star", model.favorite ? "Remove from Favourites" : "Add to Favourites", on: model.favorite, bounces: true) {
                    controls.toggleFavorite()
                }
            }
            if model.canMaximize {
                icon(model.maximized ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                     model.maximized ? "Restore (⌥⌘↩)" : "Maximize (⌥⌘↩)") { controls.toggleMaximize() }
            }
            icon("xmark", "Out of the Layout (⌘W)") { controls.outOfLayout() }
            MoreButton(controls: controls)
                .frame(width: 26, height: 26)
                .help("More")
        }
        .padding(3)
        // Widening round the address field and narrowing back, rather than jumping.
        .animation(Motion.animation(.easeOut(duration: 0.18)), value: model.editing)
        .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 7, y: 3)
        .frame(height: 32)
    }

    @ViewBuilder
    private var address: some View {
        if model.editing {
            CanvasAddressTextField(
                text: $model.draft, focusToken: model.focusToken,
                engine: CanvasSearchEngine.current,
                candidates: model.candidates, originalAddress: model.address, boxWidth: 260,
                placeholder: CanvasSearchEngine.current != .none ? "Search or enter address"
                                                                                  : "Enter an address"
            ) { destination in
                controls.go(destination)
            } onCancel: {
                controls.go(nil)
            }
            .frame(width: 260, height: 22)
            .padding(.horizontal, 6)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.07)))
        } else {
            Button { controls.editAddress() } label: {
                HStack(spacing: 4) {
                    if !model.secure {
                        Image(systemName: "exclamationmark.triangle").font(.system(size: 9.5)).foregroundStyle(.secondary)
                    }
                    Text(model.site.isEmpty ? "Address" : model.site).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: 200)
                .padding(.horizontal, 7).frame(height: 26)
                .contentShape(Rectangle())
            }
            .buttonStyle(TileControlStyle())
            .help("Edit the address (⌘L)")
        }
    }

    private func icon(_ symbol: String, _ help: String, on: Bool = false, bounces: Bool = false,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            TileControlSymbol(name: on ? symbol + ".fill" : symbol, on: on, bounces: bounces)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(TileControlStyle())
        .help(help)
        .accessibilityLabel(help)
    }
}

/// A control's symbol: SF Symbols' own replace when it changes (outline to filled, maximize to restore),
/// and one bounce when a mark turns on. Under Reduce Motion it just changes.
private struct TileControlSymbol: View {
    let name: String
    let on: Bool
    let bounces: Bool
    @State private var bounce = 0

    var body: some View {
        Image(systemName: name)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(on ? Color.accentColor : .primary)
            .contentTransition(.symbolEffect(.replace))
            .symbolEffect(.bounce, value: bounce)
            .animation(Motion.animation(.snappy(duration: Motion.Tempo.standard)), value: name)
            .onChange(of: on) { _, now in
                if bounces, now, !Motion.isReduced { bounce &+= 1 }
            }
    }
}

private struct TileControlStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Inner(configuration: configuration) }

    private struct Inner: View {
        let configuration: ButtonStyleConfiguration
        @State private var hover = false
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            configuration.label
                // Shrinks to 92% while held: the press answers before the action does.
                .scaleEffect(configuration.isPressed && !Motion.isReduced ? 0.92 : 1)
                .animation(Motion.animation(.easeOut(duration: 0.09)), value: configuration.isPressed)
                .opacity(enabled ? 1 : 0.35)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.14 : hover && enabled ? 0.08 : 0)))
                .onHover { hover = $0 }
        }
    }
}

/// More: the tile's own menu (the same one a right-click gives), popped from the button itself.
private struct MoreButton: NSViewRepresentable {
    let controls: CanvasTileControls

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "More")!,
                              target: context.coordinator, action: #selector(Coordinator.press(_:)))
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.contentTintColor = .labelColor
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) { context.coordinator.controls = controls }
    func makeCoordinator() -> Coordinator { Coordinator(controls: controls) }

    @MainActor
    final class Coordinator: NSObject {
        var controls: CanvasTileControls
        init(controls: CanvasTileControls) { self.controls = controls }
        @objc func press(_ sender: NSButton) { controls.more(from: sender) }
    }
}
