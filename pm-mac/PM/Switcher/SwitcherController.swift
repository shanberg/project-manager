import AppKit
import Carbon.HIToolbox
import PmLib
import SwiftUI

/// The ⌥Tab switcher: open projects in a row, each with its Notes, workspaces and tiles to jump to.
/// docs/spaces.md § Switcher.
///
/// - Hold ⌥, press Tab: opens on the card after the front window's. Tab again / ⇧Tab, ← →: along the row.
///   ↓ ↑: into a card's list. Let go of ⌥: jump. Return or a click also jumps; Esc stays put.
/// - A quick tap switches to the next window without drawing anything (`SwitcherHold.revealDelay`).
/// - Cards come from the dock's groups, ordered by where their windows are in the stack.
/// - ⌥⇧Tab isn't a hotkey of its own: the panel is key while it's up, so the keystroke reaches it.
@MainActor
final class SwitcherController {
    static let shared = SwitcherController()

    /// What a card shows that the model doesn't need to know about.
    struct Look {
        var color: NSColor
        var icon: ProjectIcon?
    }

    private(set) var model: SwitcherModel?
    private var hold: SwitcherHold?
    private var looks: [String: Look] = [:]
    private var panel: KeyablePanel?
    private var host: NSHostingView<SwitcherView>?
    private var poll: Timer?
    private var keyMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var revealed = false

    /// The hotkey: open held, or step along when already open.
    func trigger() {
        if model != nil {
            model?.move(by: 1)
            render()
            return
        }
        let flags = Self.heldFlags
        open(held: !flags.isEmpty && NSEvent.modifierFlags.isSuperset(of: flags))
    }

    /// The modifiers the switcher's shortcut is held by — ⌥ for ⌥Tab — without ⇧, which steps back.
    static var heldFlags: NSEvent.ModifierFlags {
        guard let combo = HotKeyManager.shared.bindings[.showSwitcher] else { return [] }
        let carbon = Int(combo.carbonModifiers)
        var flags: NSEvent.ModifierFlags = []
        if carbon & optionKey != 0 { flags.insert(.option) }
        if carbon & cmdKey != 0 { flags.insert(.command) }
        if carbon & controlKey != 0 { flags.insert(.control) }
        return flags
    }

    /// Open without a held key: a command bar or menu asked for it.
    func showUnheld() {
        guard model == nil else { return }
        open(held: false)
    }

    // MARK: Opening

    private func open(held: Bool) {
        let built = buildCards()
        guard !built.isEmpty else { return NSSound.beep() }
        model = SwitcherModel(cards: built)
        hold = SwitcherHold(held: held, at: Date())
        revealed = false
        let panel = self.panel ?? makePanel()
        self.panel = panel
        render()
        place(panel)
        panel.alphaValue = 0
        panel.acceptsKey = true
        panel.makeKeyAndOrderFront(nil)
        installMonitors()
        tick()
    }

    /// One card per dock group, front window first.
    private func buildCards() -> [SwitcherModel.Card] {
        let dock = CanvasSatelliteDock.shared
        let stack = NSApp.orderedWindows
        func depth(_ group: CanvasSatelliteDock.Group) -> Int {
            let windows = [group.project?.window].compactMap { $0 }
                + group.workspaces.flatMap(\.satellites).compactMap(\.window)
            return windows.compactMap { window in stack.firstIndex { $0 === window } }.min() ?? Int.max
        }
        // Open projects front window first, then open spaces the same way (docs/spaces.md).
        let open = dock.groups.filter { !$0.isClosed }
        let groups = open.filter { $0.space == nil }.sorted { depth($0) < depth($1) }
            + open.filter { $0.space != nil }.sorted { depth($0) < depth($1) }
        let focusedKey = PMFiles.focusedProjectKey()
        looks = [:]
        return groups.map { group in
            looks[group.key] = Look(color: group.color ?? .systemGray, icon: group.icon)
            let controller = Self.controller(for: group)
            var card = SwitcherModel.Card(key: group.key, title: group.title)
            card.isFocused = group.projectKey != nil && group.projectKey == focusedKey
            card.isSpace = group.space != nil
            if let store = controller?.store, group.projectKey != nil {
                if let latest = store.notes?.sessions.first {
                    card.session = latest.label.isEmpty ? latest.date : "\(latest.label) · \(latest.date)"
                }
                card.focusedTask = store.focusedTodo?.text
            }
            let names = controller?.workspaceTabNames ?? group.workspaces.map(\.name)
            let canvas = controller?.workspaceCanvas ?? group.canvas
            card.entries = SwitcherModel.entries(workspaces: Self.workspaces(names, of: canvas))
            return card
        }
    }

    /// Each workspace with its tiles, named the way a tile's tab names its card.
    private static func workspaces(_ names: [String], of canvas: URL?) -> [(name: String, tiles: [(id: String, title: String)])] {
        guard let canvas else { return names.map { ($0, []) } }
        let document = try? CanvasDocument.read(contentsOf: canvas)
        return names.map { name in
            let ids = CanvasWorkspaces.tiling(named: name, of: canvas)?.ids ?? []
            let tiles = ids.compactMap { id -> (id: String, title: String)? in
                guard let node = document?.node(id: id) else { return nil }
                return (id, CanvasExistingCards.card(node)?.title ?? "Card")
            }
            return (name, tiles)
        }
    }

    private static func controller(for group: CanvasSatelliteDock.Group) -> ProjectWindowController? {
        guard let window = group.project?.window else { return nil }
        return WindowManager.shared.controllers.first { $0.window === window }
    }

    // MARK: Watching ⌥

    private func installMonitors() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self, self.model != nil else { return event }
            return self.handle(event) ? nil : event
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
        // The flag can come up while another app's window has the event: polled as well as watched.
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        poll = timer
    }

    private func tick() {
        guard model != nil, var hold else { return }
        if !NSEvent.modifierFlags.isSuperset(of: Self.heldFlags), hold.released() {
            self.hold = hold
            return commit()
        }
        if !revealed, hold.shouldReveal(at: Date()) {
            revealed = true
            panel?.alphaValue = 1
        }
    }

    /// True when the event was the switcher's.
    private func handle(_ event: NSEvent) -> Bool {
        if event.type == .flagsChanged {
            tick()
            return false
        }
        switch Int(event.keyCode) {
        case 48: model?.move(by: event.modifierFlags.contains(.shift) ? -1 : 1)       // Tab
        case 123: model?.move(by: -1)                                                  // ←
        case 124: model?.move(by: 1)                                                   // →
        case 125: model?.moveEntry(by: 1)                                              // ↓
        case 126: model?.moveEntry(by: -1)                                             // ↑
        case 36, 76: commit(); return true                                             // Return
        case 53: close(); return true                                                  // Esc
        default: return true
        }
        render()
        return true
    }

    // MARK: Going

    private func commit() {
        guard let model, let card = model.selectedCard else { return close() }
        let entry = model.selectedEntry
        close()
        guard let group = CanvasSatelliteDock.shared.groups.first(where: { $0.key == card.key }) else { return }
        Log.write("switcher: \(card.title)\(entry.map { " · \($0.title)" } ?? "")")
        let controller = Self.controller(for: group)
        switch entry?.target {
        case nil:
            CanvasSatelliteDock.shared.show(group)
        case .notes:
            if let controller { controller.show(workspace: nil) } else { CanvasSatelliteDock.shared.show(group) }
        case .workspace(let name):
            if let controller { controller.show(workspace: name) } else { CanvasSatelliteDock.shared.show(group) }
        case .tile(let name, let id):
            if let controller { controller.show(workspace: name, tile: id) } else { CanvasSatelliteDock.shared.show(group) }
        }
    }

    func close() {
        poll?.invalidate()
        poll = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        model = nil
        hold = nil
        panel?.acceptsKey = false
        panel?.orderOut(nil)
    }

    // MARK: The panel

    private func makePanel() -> KeyablePanel {
        let panel = KeyablePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        let glass = NSGlassEffectView()
        glass.cornerRadius = 22
        glass.style = .regular
        let host = NSHostingView(rootView: SwitcherView(model: nil, looks: [:], point: { _, _ in }, go: {}))
        host.sizingOptions = [.intrinsicContentSize]
        glass.contentView = host
        panel.contentView = glass
        self.host = host
        return panel
    }

    private func render() {
        guard let host, let model else { return }
        host.rootView = SwitcherView(model: model, looks: looks,
                                     point: { [weak self] card, entry in
                                         self?.model?.point(at: card, entry: entry)
                                         self?.render()
                                     },
                                     go: { [weak self] in self?.commit() })
        if let panel { place(panel) }
    }

    /// Centred on the screen with the pointer, as wide as its cards up to that screen.
    private func place(_ panel: NSPanel) {
        guard let host else { return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        var size = host.fittingSize
        size.width = min(size.width, visible.width - 80)
        size.height = min(size.height, visible.height - 80)
        let origin = NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }
}

/// The row of cards.
struct SwitcherView: View {
    let model: SwitcherModel?
    let looks: [String: SwitcherController.Look]
    let point: (Int, Int?) -> Void
    let go: () -> Void

    static let cardWidth: CGFloat = 208

    @Environment(\.colorScheme) private var scheme


    var body: some View {
        if let model {
            VStack(spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(Array(model.cards.enumerated()), id: \.element.key) { index, card in
                            if card.isSpace, index > 0, !model.cards[index - 1].isSpace {
                                Divider().frame(height: 120)
                            }
                            cardView(card, index: index, model: model)
                        }
                    }
                    .padding(.horizontal, 2)
                }
                .scrollDisabled(false)
                Text("Tab, ⇧Tab ← →  projects   ↓ ↑  workspaces   let go of ⌥ to jump   Esc stays")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .fixedSize()
        }
    }

    @ViewBuilder
    private func cardView(_ card: SwitcherModel.Card, index: Int, model: SwitcherModel) -> some View {
        let look = looks[card.key] ?? .init(color: .systemGray, icon: nil)
        let color = Color(nsColor: look.color)
        let inkColor = SwitcherInk.legible(look.color, dark: scheme == .dark)
        let ink = Color(nsColor: inkColor)
        let onInk = SwitcherInk.onFillIsDark(inkColor) ? Color.black : Color.white
        let picked = index == model.index
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 9) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(LinearGradient(colors: [color.mix(with: .white, by: 0.25), color],
                                             startPoint: .top, endPoint: .bottom))
                    if let icon = look.icon {
                        ProjectIconMark(icon: icon, size: 17, tint: .white)
                    } else {
                        Text(String(card.title.prefix(1)).uppercased())
                            .font(.system(size: 16, weight: .bold, design: .rounded)).foregroundStyle(.white)
                    }
                }
                .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text(card.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(card.isFocused ? "Focused" : card.isSpace ? "Space" : "Project")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(card.isFocused ? ink : .secondary)
                }
            }
            if card.session != nil || card.focusedTask != nil {
                VStack(alignment: .leading, spacing: 2) {
                    if let session = card.session {
                        Text(session).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if let task = card.focusedTask {
                        Text("@ \(task)").font(.system(size: 11.5, weight: .medium)).lineLimit(2)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(card.entries.enumerated()), id: \.offset) { row, entry in
                    let on = picked && model.entry == row
                    HStack(spacing: 6) {
                        Text(entry.title).lineLimit(1)
                        Spacer(minLength: 4)
                        if entry.count > 0 {
                            Text(entry.count == 1 ? "1 tile" : "\(entry.count) tiles")
                                .font(.system(size: 10))
                                .foregroundStyle(on ? onInk.opacity(0.8) : .secondary)
                        }
                    }
                    .font(.system(size: 11.5))
                    .foregroundStyle(on ? onInk : (entry.isTile ? Color.secondary : Color.primary))
                    .padding(.leading, entry.isTile ? 18 : 6)
                    .padding(.trailing, 6)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 6).fill(on ? ink : .clear))
                    .contentShape(Rectangle())
                    .onHover { if $0 { point(index, row) } }
                    .onTapGesture { point(index, row); go() }
                }
            }
        }
        .padding(10)
        .frame(width: Self.cardWidth, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(picked ? ink.opacity(0.16) : .clear)
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(picked ? ink.opacity(0.7) : .clear, lineWidth: 2))
        )
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .onHover { if $0, model.index != index { point(index, nil) } }
        .onTapGesture { point(index, nil); go() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(card.title)\(card.isFocused ? ", focused" : "")")
        .accessibilityAddTraits(picked ? .isSelected : [])
    }
}
