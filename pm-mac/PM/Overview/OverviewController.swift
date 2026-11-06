import AppKit
import PmLib
import SwiftUI

/// The overview: every project and space at once, as live pictures of their windows. docs/spaces.md
/// § Overview.
///
/// - Opened by Space in the ⌥Tab switcher (its cards grow into the grid), or Spaces ▸ Overview
///   and Window ▸ Overview (the window in front zooms into its tile). No key of its own.
/// - One grid in the dock's order: projects, a divider, every space (closed ones dimmed, with the
///   picture they were closed on), then +. A place's windows out sit with its own, as on screen. Over the desktop, dimmed and blurred; the dock stays above it.
/// - Click, or Return: go there (the tile zooms into its window). + makes a space and goes to it.
///   Drag a tile among its kind to reorder the dock. Type to find. Esc, or a click off the tiles: back.
/// - Letting go of ⌥ does nothing here: it was a switcher gesture, and the overview is for looking.
@MainActor
final class OverviewController: NSObject {
    static let shared = OverviewController()

    private(set) var isOpen = false
    private var model = OverviewModel(tiles: [], selected: nil)
    private var groups: [String: CanvasSatelliteDock.Group] = [:]
    /// Each place's windows: its own, then its windows out.
    private var pictures: [String: [OverviewShot]] = [:]
    private var frontKey: String?
    /// Windows made see-through while their picture stands in for them.
    private var hidden: [NSWindow] = []
    private var panel: KeyablePanel?
    private var view: OverviewView?
    private var resignObserver: NSObjectProtocol?
    private var leaving = false

    private static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    // MARK: Menu

    @objc func showOverview(_ sender: Any?) { isOpen ? leave(to: nil) : show() }

    // MARK: Opening

    /// Open, selecting `key` (the switcher's pick), the tiles flying from `cards` (the switcher's cards,
    /// in screen coordinates) when given, else the front window zooming into its tile.
    func show(selecting key: String? = nil, from cards: [String: NSRect] = [:]) {
        guard !isOpen else { return }
        let dock = CanvasSatelliteDock.shared
        let stack = NSApp.orderedWindows
        let focusedKey = PMFiles.focusedProjectKey()
        groups = Dictionary(dock.groups.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        frontKey = dock.groups.min { a, b in
            Self.depth(a, in: stack) < Self.depth(b, in: stack)
        }.flatMap { Self.window(of: $0) == nil ? nil : $0.key }
        model = OverviewModel(tiles: dock.groups.map { group in
            OverviewModel.Tile(key: group.key, title: group.title, isSpace: group.space != nil,
                               isClosed: group.isClosed,
                               isFocused: group.projectKey != nil && group.projectKey == focusedKey,
                               isPlaying: group.isPlaying)
        }, selected: key ?? frontKey)

        // Pictures: the front place's windows now, for the zoom; the rest as last seen, then fresh.
        pictures = [:]
        for group in dock.groups {
            let windows = Self.windows(of: group)
            guard !windows.isEmpty else {
                let image = WindowSnapshot.last(group.key)
                pictures[group.key] = [OverviewShot(id: 0, window: nil, frame: NSRect(x: 0, y: 0, width: 1280, height: 800),
                                                    image: image, isMain: true)]
                continue
            }
            pictures[group.key] = windows.enumerated().map { index, window in
                OverviewShot(id: window.windowNumber, window: window, frame: window.frame,
                             image: WindowSnapshot.last(Self.snapshotKey(group.key, window, main: index == 0)),
                             isMain: index == 0)
            }
        }
        if let frontKey {
            for shot in pictures[frontKey] ?? [] { if let window = shot.window { picture(window, of: frontKey, main: shot.isMain) } }
        }
        // After the entrance: each picture is tens of milliseconds on the main thread, which the
        // animation would stutter through.
        var delay = 0.36
        for group in dock.groups where group.key != frontKey {
            for shot in pictures[group.key] ?? [] {
                guard let window = shot.window else { continue }
                delay += 0.04
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self, self.isOpen, window.isVisible else { return }
                    self.picture(window, of: group.key, main: shot.isMain)
                }
            }
        }

        let screen = frontKey.flatMap { groups[$0] }.flatMap(Self.window(of:))?.screen
            ?? NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let screen else { return }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let frame = NSRect(x: screen.frame.minX, y: screen.frame.minY, width: screen.frame.width,
                           height: screen.visibleFrame.maxY - screen.frame.minY)
        panel.setFrame(frame, display: false)
        let view = self.view ?? OverviewView(controller: self)
        self.view = view
        panel.contentView = view
        view.frame = NSRect(origin: .zero, size: frame.size)
        view.insets = Self.insets(on: screen, panel: frame)
        view.rebuild(model: model, groups: groups, pictures: pictures, front: frontKey)

        isOpen = true
        leaving = false
        panel.acceptsKey = true
        panel.alphaValue = 1
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(view)
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isOpen, !self.leaving else { return }
                self.finish()
            }
        }
        Log.write("overview: open\(cards.isEmpty ? "" : " from the switcher")")
        arrive(from: cards)
    }

    /// The entrance: the switcher's cards grow into their tiles, or the front window zooms into its own.
    private func arrive(from cards: [String: NSRect]) {
        guard let view else { return }
        if Self.reduceMotion {
            view.alphaValue = 0
            NSAnimationContext.runAnimationGroup { $0.duration = 0.18; view.animator().alphaValue = 1 }
            return
        }
        view.fadeInBackdrop()
        for key in view.tileKeys {
            guard let to = view.pictureRectOnScreen(key) else { continue }
            let main = pictures[key]?.first { $0.isMain }
            if key == frontKey {
                // Every one of its windows into its place in the tile.
                view.hideTile(key, until: 0.32)
                for shot in pictures[key] ?? [] {
                    guard let window = shot.window, let rect = view.rectOnScreen(key, window: shot.id) else { continue }
                    view.fly(shot.image, fill: view.fill(for: key), from: window.frame, radius: 16, to: rect, radiusTo: 10)
                    window.alphaValue = 0
                    hidden.append(window)
                }
            } else if let from = cards[key] {
                view.hideTile(key, until: 0.32)
                view.fly(main?.image, fill: view.fill(for: key), from: from, radius: 14, to: to, radiusTo: 10)
            } else {
                view.fadeInTile(key, delay: cards.isEmpty ? 0.06 : 0.12)
            }
        }
    }

    /// A window's picture taken, kept, and put in its tile.
    private func picture(_ window: NSWindow, of key: String, main: Bool) {
        let id = window.windowNumber
        WindowSnapshot.refresh(window, key: Self.snapshotKey(key, window, main: main)) { [weak self] image in
            guard let self, let index = self.pictures[key]?.firstIndex(where: { $0.id == id }) else { return }
            self.pictures[key]?[index].image = image
            guard self.isOpen else { return }
            self.view?.setPicture(image, for: key, window: id)
        }
    }

    /// A place's own window is kept under its key, so a closed space shows how it was left.
    private static func snapshotKey(_ key: String, _ window: NSWindow, main: Bool) -> String {
        main ? key : "\(key)#\(window.windowNumber)"
    }

    // MARK: Going

    /// A tile clicked, Return, or a dock mark clicked while open: every window of the place, or only
    /// `window` (its number) when one of its pictures was clicked.
    func go(to key: String, window: Int? = nil) {
        guard isOpen, !leaving else { return }
        if key == OverviewModel.plusKey { return newSpace() }
        leave(to: key, window: window)
    }

    private func newSpace() {
        leaving = true
        Log.write("overview: new space")
        fadeOut { Spaces.shared.newSpace() }
    }

    /// Back to `key`'s window, or to the one in front when nil: its tile zooms into it.
    func leave(to key: String?, window picked: Int? = nil) {
        guard isOpen, !leaving, let view else { return }
        leaving = true
        let target = key ?? frontKey
        let group = target.flatMap { groups[$0] }
        Log.write("overview: \(group.map { "go to \($0.title)\(picked == nil ? "" : ", one window")" } ?? "back")")
        let open = (target.flatMap { pictures[$0] } ?? []).filter { $0.window?.isVisible == true }
        let shots = picked.map { id in open.filter { $0.id == id } } ?? open
        let bringForward = {
            guard key != nil else { return }
            // One window picked: that one, key. The place: its own window as the dock shows it, then its
            // windows out over it.
            if let window = shots.first?.window, picked != nil {
                NSApp.activate()
                return window.makeKeyAndOrderFront(nil)
            }
            if let group { CanvasSatelliteDock.shared.show(group) }
            for shot in open where !shot.isMain { shot.window?.orderFront(nil) }
        }
        guard !Self.reduceMotion, let target, !shots.isEmpty else { bringForward(); return fadeOut {} }
        // The windows come forward once the flights land: activating mid-flight stutters them.
        view.hideTile(target, until: .infinity)
        view.fadeOutAllButFlights(duration: 0.24)
        var landing = shots.count
        for shot in shots {
            guard let window = shot.window, let from = view.rectOnScreen(target, window: shot.id) else { landing -= 1; continue }
            if !hidden.contains(window) {
                window.alphaValue = 0
                hidden.append(window)
            }
            view.fly(shot.image, fill: view.fill(for: target), from: from, radius: 10, to: window.frame, radiusTo: 16) { [weak self] in
                landing -= 1
                guard landing == 0 else { return }
                bringForward()
                self?.finish()
            }
        }
        if landing == 0 { bringForward(); finish() }
    }

    private func fadeOut(then done: @escaping () -> Void) {
        guard let panel else { return finish() }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                self?.finish()
                done()
            }
        })
    }

    /// Gone: windows back as they were, the panel away.
    private func finish() {
        for window in hidden { window.alphaValue = 1 }
        hidden = []
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        isOpen = false
        leaving = false
        panel?.acceptsKey = false
        panel?.orderOut(nil)
        view?.reset()
    }

    // MARK: Keys

    /// True when the overview took the key.
    func key(_ event: NSEvent) -> Bool {
        guard isOpen, !leaving else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) || flags.contains(.control) { return false }
        switch Int(event.keyCode) {
        case 53:                                                                // Esc
            if model.query.isEmpty { leave(to: nil) } else { model.clearQuery(); refresh(animated: true) }
        case 36, 76:                                                            // Return
            if let selected = model.selected { go(to: selected) }
        case 48: view?.clearHover(); model.move(by: flags.contains(.shift) ? -1 : 1); refresh(animated: false)   // Tab
        case 123: view?.clearHover(); model.move(by: -1); refresh(animated: false)                 // ←
        case 124: view?.clearHover(); model.move(by: 1); refresh(animated: false)                  // →
        case 125, 126:                                                          // ↓ ↑
            view?.clearHover()
            if let key = view?.vertical(from: model.selected, by: event.keyCode == 125 ? 1 : -1) {
                model.select(key)
                refresh(animated: false)
            }
        case 51:                                                                // Delete
            model.deleteBackward()
            refresh(animated: true)
        default:
            // ⌥ still held from the switcher types symbols, not names.
            guard !flags.contains(.option), let text = event.characters,
                  !text.isEmpty, text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && !(0xF700...0xF8FF).contains($0.value) })
            else { return true }
            model.type(text)
            refresh(animated: true)
        }
        return true
    }

    /// A tile under the pointer, or a click on it.
    func select(_ key: String) {
        model.select(key)
        refresh(animated: false)
    }

    private func refresh(animated: Bool) {
        view?.update(model: model, animated: animated)
    }

    // MARK: Reordering

    /// A tile let go before or after another of its kind: the dock follows.
    func reorder(_ key: String, to target: String, after: Bool) {
        let before = model.tiles
        model.move(key, to: target, after: after)
        guard model.tiles != before, let group = groups[key] else { return }
        if group.space != nil {
            Spaces.shared.reorder(model.tiles.filter(\.isSpace).compactMap { groups[$0.key]?.space })
        } else {
            CanvasSatelliteDock.shared.setProjectOrder(model.tiles.filter { !$0.isSpace }.map(\.key))
        }
        Log.write("overview: moved \(group.title)")
        refresh(animated: true)
    }

    // MARK: Helpers

    /// The window a group's tile stands for: its own, else its first window out.
    static func window(of group: CanvasSatelliteDock.Group) -> NSWindow? { windows(of: group).first }

    /// A group's windows on screen: its own first, then its windows out.
    static func windows(of group: CanvasSatelliteDock.Group) -> [NSWindow] {
        var found: [NSWindow] = []
        if let window = group.project?.window, window.isVisible { found.append(window) }
        for window in group.workspaces.flatMap(\.satellites).compactMap(\.window)
        where window.isVisible && !found.contains(where: { $0 === window }) {
            found.append(window)
        }
        return found
    }

    private static func depth(_ group: CanvasSatelliteDock.Group, in stack: [NSWindow]) -> Int {
        guard let window = window(of: group) else { return Int.max }
        return stack.firstIndex { $0 === window } ?? Int.max
    }

    /// Room for the dock on its side and the Mac's Dock at the foot.
    private static func insets(on screen: NSScreen, panel: NSRect) -> NSEdgeInsets {
        var insets = NSEdgeInsets(top: 52, left: 28, bottom: 24 + (screen.visibleFrame.minY - screen.frame.minY), right: 28)
        if let dock = CanvasSatelliteDock.shared.frame, dock.intersects(panel) {
            if dock.midX < panel.midX {
                insets.left = max(insets.left, dock.maxX - panel.minX + 24)
            } else {
                insets.right = max(insets.right, panel.maxX - dock.minX + 24)
            }
        }
        return insets
    }

    private func makePanel() -> KeyablePanel {
        let panel = KeyablePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        // Over every window, under the dock (`.floating`), which stays out and follows reordering.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient]
        return panel
    }

    /// A place's mark, as the switcher draws it: its colour, its icon or initial in white.
    static func mark(color: NSColor, icon: ProjectIcon?, title: String, side: CGFloat) -> NSImage? {
        let fill = Color(nsColor: color)
        let content = ZStack {
            RoundedRectangle(cornerRadius: side * 0.24, style: .continuous)
                .fill(LinearGradient(colors: [fill.mix(with: .white, by: 0.25), fill], startPoint: .top, endPoint: .bottom))
            if let icon, ProjectIconMark.canDraw(icon) {
                ProjectIconMark(icon: icon, size: side * 0.5, tint: .white)
            } else {
                Text(String(title.prefix(1)).uppercased())
                    .font(.system(size: side * 0.47, weight: .bold, design: .rounded)).foregroundStyle(.white)
            }
        }
        .frame(width: side, height: side)
        let renderer = ImageRenderer(content: content)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        return renderer.nsImage
    }
}

// MARK: - The view

/// The overview's content: the backdrop, the grid, and the pictures in flight.
@MainActor
final class OverviewView: NSView {
    private unowned let controller: OverviewController
    var insets = NSEdgeInsets()
    private let backdrop = NSVisualEffectView()
    private let dim = NSView()
    private let header = NSTextField(labelWithString: "")
    private let grid = FlippedView()
    private let divider = NSView()
    private let dropMark = NSView()
    private let flights = FlightView()
    private var tiles: [String: OverviewTileView] = [:]
    private var model = OverviewModel(tiles: [], selected: nil)
    private var layout = OverviewLayout.Result(cells: [], divider: nil, columns: 1, height: 0)
    /// The order the cells were laid out in.
    private var laidOut: [String] = []
    private var hovered: String?
    private var press: (key: String, part: OverviewTilePart?, at: NSPoint)?
    private var dragging: (key: String, proxy: NSImageView, drop: (target: String, after: Bool)?)?

    init(controller: OverviewController) {
        self.controller = controller
        super.init(frame: .zero)
        wantsLayer = true
        backdrop.material = .fullScreenUI
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.autoresizingMask = [.width, .height]
        addSubview(backdrop)
        dim.wantsLayer = true
        dim.autoresizingMask = [.width, .height]
        addSubview(dim)
        header.font = .systemFont(ofSize: 12, weight: .medium)
        header.textColor = NSColor.white.withAlphaComponent(0.8)
        addSubview(header)
        grid.wantsLayer = true
        addSubview(grid)
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.22).cgColor
        grid.addSubview(divider)
        dropMark.wantsLayer = true
        dropMark.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        dropMark.layer?.cornerRadius = 1.5
        dropMark.isHidden = true
        grid.addSubview(dropMark)
        flights.autoresizingMask = [.width, .height]
        addSubview(flights)
        let tracking = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect, .mouseEnteredAndExited],
                                      owner: self, userInfo: nil)
        addTrackingArea(tracking)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        dim.layer?.backgroundColor = NSColor.black.withAlphaComponent(dark ? 0.38 : 0.22).cgColor
    }

    // MARK: Building

    func rebuild(model: OverviewModel, groups: [String: CanvasSatelliteDock.Group], pictures: [String: [OverviewShot]], front: String?) {
        tiles.values.forEach { $0.removeFromSuperview() }
        tiles = [:]
        backdrop.frame = bounds
        dim.frame = bounds
        viewDidChangeEffectiveAppearance()
        for tile in model.tiles {
            guard let group = groups[tile.key] else { continue }
            let view = OverviewTileView(tile: tile, color: group.color ?? .systemGray, icon: group.icon,
                                        shots: pictures[tile.key] ?? [])
            view.isFront = tile.key == front
            grid.addSubview(view, positioned: .below, relativeTo: dropMark)
            tiles[tile.key] = view
        }
        let plus = OverviewTileView(plus: ())
        grid.addSubview(plus, positioned: .below, relativeTo: dropMark)
        tiles[OverviewModel.plusKey] = plus
        update(model: model, animated: false)
    }

    var tileKeys: [String] { laidOut }

    func update(model: OverviewModel, animated: Bool) {
        self.model = model
        header.stringValue = model.query.isEmpty ? "Overview  ·  type to find" : "Find:  \(model.query)"
        header.sizeToFit()
        header.setFrameOrigin(NSPoint(x: insets.left, y: 22))
        let area = NSRect(x: insets.left, y: insets.top, width: bounds.width - insets.left - insets.right,
                          height: bounds.height - insets.top - insets.bottom)
        grid.frame = area
        let projects = model.projects, spaces = model.spaces
        let others = spaces.count + (model.showsPlus ? 1 : 0)
        layout = OverviewLayout.filling(projects: projects.count, others: others, width: area.width, height: area.height)
        // Centred top to bottom in the room left.
        let drop = max(0, (area.height - layout.height) / 2)
        layout.cells = layout.cells.map { $0.offsetBy(dx: 0, dy: drop) }
        layout.divider = layout.divider?.offsetBy(dx: 0, dy: drop)
        laidOut = projects.map(\.key) + spaces.map(\.key) + (model.showsPlus ? [OverviewModel.plusKey] : [])
        let shown = Set(laidOut)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.22 : 0
            context.allowsImplicitAnimation = animated
            for (index, key) in laidOut.enumerated() where layout.cells.indices.contains(index) {
                guard let tile = tiles[key] else { continue }
                let cell = layout.cells[index]
                if tile.isHidden || !animated { tile.frame = cell } else { tile.animator().frame = cell }
                tile.isHidden = false
            }
        }
        for (key, tile) in tiles where !shown.contains(key) { tile.isHidden = true }
        for (key, tile) in tiles {
            tile.isSelected = key == model.selected
        }
        if let line = layout.divider { divider.frame = line; divider.isHidden = false } else { divider.isHidden = true }
    }

    func setPicture(_ image: NSImage, for key: String, window id: Int) { tiles[key]?.setPicture(image, window: id) }

    func fill(for key: String) -> NSColor { tiles[key]?.placeholderColor ?? .windowBackgroundColor }

    func reset() {
        flights.layer?.sublayers?.forEach { $0.removeFromSuperlayer() }
        alphaValue = 1
        for view in [backdrop, dim, grid, header] { view.alphaValue = 1 }
        hovered = nil
        press = nil
        dragging?.proxy.removeFromSuperview()
        dragging = nil
        dropMark.isHidden = true
    }

    // MARK: Geometry

    func pictureRectOnScreen(_ key: String) -> NSRect? {
        guard let tile = tiles[key], !tile.isHidden, let window else { return nil }
        return window.convertToScreen(tile.convert(tile.pictureRect, to: nil))
    }

    /// One of a place's windows in its tile, on screen.
    func rectOnScreen(_ key: String, window id: Int) -> NSRect? {
        guard let tile = tiles[key], !tile.isHidden, let window else { return nil }
        return window.convertToScreen(tile.convert(tile.rect(of: id), to: nil))
    }

    func vertical(from key: String?, by step: Int) -> String? {
        guard let key, let index = laidOut.firstIndex(of: key),
              let next = OverviewLayout.vertical(from: index, by: step, in: Array(layout.cells.prefix(laidOut.count)))
        else { return nil }
        return laidOut[next]
    }

    // MARK: Motion

    func fadeInBackdrop() {
        for view in [backdrop, dim, header] {
            view.alphaValue = 0
            NSAnimationContext.runAnimationGroup { $0.duration = 0.22; view.animator().alphaValue = 1 }
        }
    }

    func fadeInTile(_ key: String, delay: TimeInterval) {
        guard let tile = tiles[key] else { return }
        tile.alphaValue = 0
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            NSAnimationContext.runAnimationGroup { $0.duration = 0.24; tile.animator().alphaValue = 1 }
        }
    }

    func hideTile(_ key: String, until delay: TimeInterval) {
        guard let tile = tiles[key] else { return }
        tile.alphaValue = 0
        guard delay.isFinite else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { tile.alphaValue = 1 }
    }

    func fadeOutAllButFlights(duration: TimeInterval) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            for view in [backdrop, dim, grid, header] { view.animator().alphaValue = 0 }
        }
    }

    /// A picture flying between two screen rectangles, over everything.
    func fly(_ image: NSImage?, fill: NSColor, from: NSRect, radius: CGFloat, to: NSRect, radiusTo: CGFloat,
             duration: CFTimeInterval = 0.32, done: (() -> Void)? = nil) {
        guard let window else { done?(); return }
        let start = flights.convert(window.convertFromScreen(from), from: nil)
        let end = flights.convert(window.convertFromScreen(to), from: nil)
        flights.fly(image, fill: fill, from: start, radius: radius, to: end, radiusTo: radiusTo, duration: duration, done: done)
    }

    // MARK: Pointer

    private func tileKey(at point: NSPoint) -> String? {
        let local = grid.convert(point, from: self)
        return laidOut.first { key in
            guard let tile = tiles[key], !tile.isHidden else { return false }
            return tile.frame.contains(local)
        }
    }

    /// Which part of a tile is under a point: one of its windows, or the place behind them.
    private func part(at point: NSPoint, of key: String?) -> OverviewTilePart? {
        guard let key, let tile = tiles[key] else { return nil }
        return tile.part(at: tile.convert(point, from: self))
    }

    /// One selection, as the switcher has: the pointer over a tile selects it, and only the selected
    /// tile shows what's under the pointer.
    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let key = tileKey(at: point)
        hovered = key
        if let key, key != model.selected { controller.select(key) }
        for (k, tile) in tiles { tile.hoverPart = k == key ? part(at: point, of: key) : nil }
    }

    /// The keyboard has moved the selection: the pointer's marks go until it moves again.
    func clearHover() {
        hovered = nil
        tiles.values.forEach { $0.hoverPart = nil }
    }

    override func mouseExited(with event: NSEvent) {
        hovered = nil
        tiles.values.forEach { $0.hoverPart = nil }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let key = tileKey(at: point)
        press = (key ?? "", part(at: point, of: key), point)
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let press, !press.key.isEmpty, press.key != OverviewModel.plusKey else { return }
        if dragging == nil {
            guard hypot(point.x - press.at.x, point.y - press.at.y) > 4, let tile = tiles[press.key] else { return }
            let proxy = NSImageView(image: tile.image() ?? NSImage())
            proxy.frame = grid.convert(tile.frame, to: self)
            proxy.alphaValue = 0.9
            proxy.wantsLayer = true
            proxy.layer?.shadowOpacity = 0.35
            proxy.layer?.shadowRadius = 14
            addSubview(proxy, positioned: .below, relativeTo: flights)
            tile.alphaValue = 0.35
            dragging = (press.key, proxy, nil)
        }
        guard var drag = dragging, let source = model.tiles.first(where: { $0.key == drag.key }) else { return }
        drag.proxy.setFrameOrigin(NSPoint(x: drag.proxy.frame.minX + event.deltaX, y: drag.proxy.frame.minY + event.deltaY))
        // The nearest tile of its kind: before or after it by which half the pointer is over.
        let local = grid.convert(point, from: self)
        let kin = laidOut.filter { key in model.tiles.first { $0.key == key }?.isSpace == source.isSpace }
        let nearest = kin.compactMap { key -> (String, NSRect)? in tiles[key].map { (key, $0.frame) } }
            .min { hypot($0.1.midX - local.x, $0.1.midY - local.y) < hypot($1.1.midX - local.x, $1.1.midY - local.y) }
        if let (target, frame) = nearest, target != drag.key {
            let after = local.x > frame.midX
            drag.drop = (target, after)
            let thumb = OverviewLayout.thumb(of: frame)
            let x = after ? thumb.maxX + OverviewLayout.gap / 2 - 1.5 : thumb.minX - OverviewLayout.gap / 2 - 1.5
            dropMark.frame = NSRect(x: x, y: thumb.minY, width: 3, height: thumb.height)
            dropMark.isHidden = false
        } else {
            drag.drop = nil
            dropMark.isHidden = true
        }
        dragging = drag
    }

    override func mouseUp(with event: NSEvent) {
        defer { press = nil }
        if let drag = dragging {
            dragging = nil
            drag.proxy.removeFromSuperview()
            dropMark.isHidden = true
            tiles[drag.key]?.alphaValue = 1
            if let drop = drag.drop { controller.reorder(drag.key, to: drop.target, after: drop.after) }
            return
        }
        guard let press else { return }
        let point = convert(event.locationInWindow, from: nil)
        let key = tileKey(at: point)
        if press.key.isEmpty, key == nil { return controller.leave(to: nil) }
        guard let key, key == press.key, let part = part(at: point, of: key), part == press.part else { return }
        if case .window(let id) = part { controller.go(to: key, window: id) } else { controller.go(to: key) }
    }

    override func keyDown(with event: NSEvent) {
        if !controller.key(event) { super.keyDown(with: event) }
    }

    override func cancelOperation(_ sender: Any?) {}
}

/// A flipped plain view: the grid's cells are laid out top-down.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Where pictures fly, over everything; takes no clicks.
private final class FlightView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func fly(_ image: NSImage?, fill: NSColor, from: NSRect, radius: CGFloat, to: NSRect, radiusTo: CGFloat,
             duration: CFTimeInterval, done: (() -> Void)?) {
        guard let host = layer else { done?(); return }
        let flight = CALayer()
        flight.contents = image
        flight.contentsGravity = .resizeAspectFill
        flight.contentsScale = window?.backingScaleFactor ?? 2
        flight.backgroundColor = fill.cgColor
        flight.masksToBounds = true
        flight.cornerCurve = .continuous
        flight.cornerRadius = radiusTo
        flight.frame = to
        host.addSublayer(flight)
        let timing = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
        CATransaction.begin()
        CATransaction.setCompletionBlock {
            MainActor.assumeIsolated {
                flight.removeFromSuperlayer()
                done?()
            }
        }
        for (path, value) in [("bounds", NSValue(rect: NSRect(origin: .zero, size: from.size))),
                              ("position", NSValue(point: NSPoint(x: from.midX, y: from.midY))),
                              ("cornerRadius", NSNumber(value: Double(radius)))] as [(String, Any)] {
            let animation = CABasicAnimation(keyPath: path)
            animation.fromValue = value
            animation.duration = duration
            animation.timingFunction = timing
            flight.add(animation, forKey: path)
        }
        CATransaction.commit()
    }
}

// MARK: - A tile

/// One of a place's windows in its tile.
struct OverviewShot {
    /// The window's number; 0 for a closed place's last picture.
    var id: Int
    weak var window: NSWindow?
    /// Where the window is on screen, for the tile's arrangement.
    var frame: NSRect
    var image: NSImage?
    /// The place's own window, which zooms; the rest are its windows out.
    var isMain: Bool
}

/// What's under the pointer in a tile: one of the place's windows (its number), or the place behind them.
enum OverviewTilePart: Equatable {
    case place
    case window(Int)
}

/// One window's picture: its shadow, the picture clipped to its corners, and a hairline round it that
/// keeps a light window off a light desktop and a dark one off a dark desktop.
@MainActor
private final class WindowPicture: NSView {
    let content = NSView()
    let mark = NSImageView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.3
        layer?.shadowRadius = 12
        layer?.shadowOffset = CGSize(width: 0, height: -6)
        content.wantsLayer = true
        content.layer?.cornerRadius = 10
        content.layer?.cornerCurve = .continuous
        content.layer?.masksToBounds = true
        content.layer?.contentsGravity = .resizeAspectFill
        outline(front: false)
        addSubview(content)
        content.addSubview(mark)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Mid-grey, faint and a pixel wide, reads on light and dark alike; the window in front's is a little
    /// brighter.
    func outline(front: Bool) {
        content.layer?.borderWidth = 1 / max(1, window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2)
        content.layer?.borderColor = (front ? NSColor.white.withAlphaComponent(0.45)
                                            : NSColor(white: 0.5, alpha: 0.3)).cgColor
    }

    /// Under the pointer, in a tile with windows out: picked out by itself in the accent colour.
    func highlight(_ on: Bool) {
        layer?.borderWidth = on ? 2 : 0
        layer?.borderColor = NSColor.controlAccentColor.cgColor
    }

    override func layout() {
        super.layout()
        content.frame = bounds
        let radius = min(10, bounds.width / 8)
        layer?.cornerRadius = radius
        layer?.cornerCurve = .continuous
        content.layer?.cornerRadius = radius
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
        let side = min(44, bounds.width / 3, bounds.height / 2)
        mark.frame = NSRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side)
    }
}

/// One place in the grid: its windows' pictures, arranged as they stand on screen (or its colour and
/// mark, with no picture yet), its name under them.
@MainActor
private final class OverviewTileView: FlippedTile {
    let key: String
    private let isPlus: Bool
    private let color: NSColor
    private let stack = FlippedView()
    private var pictures: [WindowPicture] = []
    private var bigMark: NSImage?
    /// The place behind its windows: shows on hover, and a click on it brings them all forward.
    private let plate = NSView()
    private let mark = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let meta = NSTextField(labelWithString: "")

    private(set) var shots: [OverviewShot] = []
    var isSelected = false { didSet { showPlate() } }
    var hoverPart: OverviewTilePart? {
        didSet {
            guard oldValue != hoverPart else { return }
            showPlate()
            for (shot, picture) in zip(shots, pictures) { picture.highlight(hoverPart == .window(shot.id) && shots.count > 1) }
        }
    }
    /// The selection is the plate: shown only on the selected tile (the pointer over a tile selects it).
    private func showPlate() {
        plate.isHidden = !isSelected
        plate.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.14).cgColor
    }
    var isFront = false { didSet { pictures.first?.outline(front: isFront) } }

    var placeholderColor: NSColor {
        color.blended(withFraction: 0.78, of: .windowBackgroundColor) ?? color
    }

    init(tile: OverviewModel.Tile, color: NSColor, icon: ProjectIcon?, shots: [OverviewShot]) {
        key = tile.key
        isPlus = false
        self.color = color
        super.init(frame: .zero)
        setUp()
        mark.image = OverviewController.mark(color: color, icon: icon, title: tile.title, side: 18)
        bigMark = OverviewController.mark(color: color, icon: icon, title: tile.title, side: 44)
        title.stringValue = tile.title
        meta.stringValue = tile.isFocused ? "Focused" : tile.isClosed ? "Closed" : tile.isPlaying ? "Playing" : ""
        if tile.isClosed {
            stack.alphaValue = 0.62
            stack.layerUsesCoreImageFilters = true
            if let gray = CIFilter(name: "CIColorControls", parameters: [kCIInputSaturationKey: 0.35]) {
                stack.contentFilters = [gray]
            }
        }
        setAccessibilityLabel("\(tile.title)\(meta.stringValue.isEmpty ? "" : ", \(meta.stringValue)")")
        self.shots = shots
        for _ in shots {
            let picture = WindowPicture()
            stack.addSubview(picture)
            pictures.append(picture)
        }
        applyPictures()
    }

    init(plus: Void) {
        key = OverviewModel.plusKey
        isPlus = true
        color = .white
        super.init(frame: .zero)
        setUp()
        let picture = WindowPicture()
        picture.layer?.shadowOpacity = 0.12
        picture.content.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.2).cgColor
        picture.content.layer?.borderWidth = 0
        picture.mark.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New Space")?
            .withSymbolConfiguration(.init(pointSize: 26, weight: .medium))
        picture.mark.contentTintColor = NSColor.white.withAlphaComponent(0.85)
        stack.addSubview(picture)
        pictures = [picture]
        title.stringValue = "New Space"
        setAccessibilityLabel("New Space")
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setUp() {
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        plate.wantsLayer = true
        plate.layer?.cornerRadius = 12
        plate.layer?.cornerCurve = .continuous
        plate.isHidden = true
        addSubview(plate)
        stack.wantsLayer = true
        addSubview(stack)
        for field in [title, meta] {
            field.textColor = .white
            field.lineBreakMode = .byTruncatingTail
            let shade = NSShadow()
            shade.shadowColor = NSColor.black.withAlphaComponent(0.4)
            shade.shadowBlurRadius = 2
            shade.shadowOffset = NSSize(width: 0, height: -1)
            field.shadow = shade
            addSubview(field)
        }
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        meta.font = .systemFont(ofSize: 11)
        meta.textColor = NSColor.white.withAlphaComponent(0.75)
        addSubview(mark)
    }

    func setPicture(_ image: NSImage, window id: Int) {
        guard let index = shots.firstIndex(where: { $0.id == id }) else { return }
        shots[index].image = image
        applyPictures()
        needsLayout = true
    }

    private func applyPictures() {
        let scale = window?.backingScaleFactor ?? 2
        for (shot, picture) in zip(shots, pictures) {
            picture.content.layer?.contents = shot.image
            picture.content.layer?.contentsScale = scale
            picture.content.layer?.backgroundColor = shot.image == nil ? placeholderColor.cgColor : nil
            picture.mark.image = shot.isMain && shot.image == nil ? bigMark : nil
            picture.mark.isHidden = picture.mark.image == nil
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// A window under `point` (the topmost: windows out are drawn over the place's own), else the place:
    /// the picture area round them, or the name.
    func part(at point: NSPoint) -> OverviewTilePart? {
        guard bounds.contains(point) else { return nil }
        guard !isPlus, shots.count > 1 else { return .place }
        let rects = shotRects
        for index in rects.indices.reversed() where rects[index].contains(point) {
            return shots[index].window == nil ? .place : .window(shots[index].id)
        }
        return .place
    }

    /// Each window's rectangle in the tile, in `shots`' order.
    private var shotRects: [NSRect] {
        let area = OverviewLayout.thumb(of: bounds)
        guard !isPlus else { return [area] }
        // A picture's own shape stands for a closed place's window; an open one's is its frame.
        let frames = shots.map { shot -> NSRect in
            guard shot.window == nil, let size = shot.image?.size else { return shot.frame }
            return NSRect(origin: .zero, size: size)
        }
        return OverviewLayout.cluster(frames, in: area)
    }

    /// The place's own window's rectangle: where the zoom lands.
    var pictureRect: NSRect { rect(of: nil) }

    /// A window's rectangle in the tile; the place's own for nil.
    func rect(of id: Int?) -> NSRect {
        let rects = shotRects
        let index = id.flatMap { id in shots.firstIndex { $0.id == id } } ?? shots.firstIndex(where: \.isMain) ?? 0
        return rects.indices.contains(index) ? rects[index] : OverviewLayout.thumb(of: bounds)
    }

    override func layout() {
        super.layout()
        stack.frame = bounds
        let rects = shotRects
        for (picture, rect) in zip(pictures, rects) { picture.frame = rect }
        // The selection: the plate behind the windows.
        plate.frame = OverviewLayout.thumb(of: bounds).insetBy(dx: -6, dy: -6)
        let y = OverviewLayout.thumb(of: bounds).maxY + 8
        var x: CGFloat = 0
        if !isPlus {
            mark.frame = NSRect(x: 0, y: y, width: 18, height: 18)
            x = 24
        }
        meta.sizeToFit()
        let metaWidth = meta.stringValue.isEmpty ? 0 : min(meta.frame.width, bounds.width / 3)
        title.frame = NSRect(x: x, y: y, width: max(0, bounds.width - x - metaWidth - 6), height: 17)
        title.sizeToFit()
        title.frame.size.width = min(title.frame.width, bounds.width - x - metaWidth - 6)
        meta.frame = NSRect(x: title.frame.maxX + 6, y: y + 1, width: metaWidth, height: 16)
    }

    /// The tile as a picture, for its proxy while it's dragged.
    func image() -> NSImage? {
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        cacheDisplay(in: bounds, to: rep)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
        return image
    }
}

/// A tile's base: top-down, like the grid.
private class FlippedTile: NSView {
    override var isFlipped: Bool { true }
}
