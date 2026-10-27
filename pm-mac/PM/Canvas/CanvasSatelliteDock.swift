import AppKit
import PmLib
import SwiftUI

/// The open projects, and where their satellites are: a column at the screen's edge, one mark per
/// project.
///
/// **One for the app, not one per window.** Satellites stay out when their window goes on to another
/// workspace or project (`CanvasSatelliteKeeper`), and a popped-out workspace puts its window away
/// (`popOutWorkspace`), so a project's windows are not always where its window is. The dock lists every
/// open project — each project window, and any project with windows out and no window of its own — and
/// says where its windows are and how to get them back.
///
/// **A mark per project, folded.** The mark is dressed as the project — its colour, its icon. Hovering
/// opens a flyout to the mark's right: the project and Show Window on one row, then a row per workspace
/// with windows out — its name, a button per window, Gather. Out to the side and over the screen, so
/// the column itself never changes size and nothing in it moves under the pointer. Clicking the mark
/// shows the project's window.
///
/// **Dressed as the Mac's own Dock**: a column of Liquid Glass, and each project an app icon — a
/// squircle in the project's colour, lit from above, with its icon in white — so a row of them reads as
/// things you go to, not controls. The flyout is glass too, tinted toward the project.
///
/// **A panel, as a palette is**: floating, and never taking the app's focus. It stays up while another
/// app is in front and on every Space: satellites are windows you keep beside other apps' work, and the
/// dock is how you find them again from there.
@MainActor
final class CanvasSatelliteDock: NSObject {
    static let shared = CanvasSatelliteDock()

    /// A project window, as the dock needs it — handed over by whoever keeps the windows
    /// (`WindowManager`), so the dock asks for them rather than knowing that type.
    @MainActor struct OpenProject {
        var canvas: URL?
        var title: String
        var color: NSColor?
        var icon: ProjectIcon?
        weak var window: NSWindow?
        var show: () -> Void
    }

    /// The project windows open, in the order they opened. Set by `WindowManager`.
    var openProjects: () -> [OpenProject] = { [] }

    /// One workspace's windows out: where they came from, and the windows.
    @MainActor struct Workspace {
        var name: String
        var satellites: [CanvasSatelliteWindow]
        var board: CanvasBoardView? { satellites.first?.board }
    }

    /// One project: its window if it has one, and its workspaces with windows out.
    @MainActor struct Group {
        var key: String
        var canvas: URL?
        var title: String
        var color: NSColor?
        var icon: ProjectIcon?
        var project: OpenProject?
        var workspaces: [Workspace] = []
        var windowCount: Int { workspaces.reduce(0) { $0 + $1.satellites.count } }
    }

    private(set) var groups: [Group] = []
    private var panel: NSPanel?
    private let column = NSStackView()
    private var flyout: NSPanel?
    private var flyoutKey: String?
    private var hideFlyout: DispatchWorkItem?
    private var refreshQueued = false

    static let margin: CGFloat = 6
    /// An icon is drawn 2 points in from its mark on every side, for its shadow.
    static let markSize: CGFloat = 44
    static let markSpacing: CGFloat = 4
    static let dockInset: CGFloat = 6
    /// Concentric with the icons: an icon's own corner, plus the distance from its edge to the dock's —
    /// the 2 points its mark leaves for its shadow and the dock's inset.
    static var dockRadius: CGFloat { DockMark.cornerRadius + 2 + dockInset }
    static let flyoutRadius: CGFloat = 16
    private var flyoutSize = NSSize.zero

    /// Satellites have come or gone, or changed what they show: rebuilt on the next turn, once for any
    /// number of asks in this one.
    func refresh() {
        guard !refreshQueued else { return }
        refreshQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            refreshQueued = false
            rebuild()
        }
    }

    /// A group per open project, in the order the windows opened, then one for each project with
    /// windows out and no window of its own; each with its workspaces' satellites, in the order their
    /// first window came out.
    static func groups(projects: [OpenProject], open: [CanvasSatelliteWindow]) -> [Group] {
        func key(_ url: URL?) -> String? { url?.standardizedFileURL.path }
        var groups = projects.enumerated().map { index, project in
            Group(key: key(project.canvas) ?? "window \(index)", canvas: project.canvas, title: project.title,
                  color: project.color, icon: project.icon, project: project)
        }
        for satellite in open where satellite.board != nil && !satellite.cards.isEmpty {
            let canvas = key(satellite.canvas)
            var index = groups.firstIndex { $0.key == canvas }
            if index == nil {
                groups.append(Group(key: canvas ?? satellite.canvas.path, canvas: satellite.canvas,
                                    title: satellite.projectTitle ?? satellite.canvas.deletingPathExtension().lastPathComponent,
                                    color: satellite.projectColor, icon: satellite.projectMarkIcon))
                index = groups.count - 1
            }
            guard let index else { continue }
            if let at = groups[index].workspaces.firstIndex(where: { $0.name == satellite.workspace }) {
                groups[index].workspaces[at].satellites.append(satellite)
            } else {
                groups[index].workspaces.append(Workspace(name: satellite.workspace, satellites: [satellite]))
            }
        }
        return groups
    }

    /// A project's window forward: the workspace Pop Out put away, if one did — its window comes back at
    /// that workspace — else the window as it is; else, for a project whose window went on to another,
    /// a window opened on it (`CanvasBoardView.showWorkspaceWindow`).
    func show(_ group: Group) {
        let away = group.workspaces.first { $0.board?.window.map { !$0.isVisible } ?? false }
        if let board = away?.board { return board.showWorkspaceWindow() }
        if let project = group.project { return project.show() }
        group.workspaces.first?.board?.showWorkspaceWindow()
    }

    private func rebuild() {
        groups = Self.groups(projects: openProjects(), open: CanvasSatelliteWindow.open)
        guard !groups.isEmpty else {
            closeFlyout()
            panel?.orderOut(nil)
            return
        }
        let panel = self.panel ?? makePanel()
        column.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for group in groups {
            let mark = DockMark(group: group)
            mark.onHover = { [weak self, weak mark] over in
                guard let self, let mark else { return }
                over ? openFlyout(for: mark.groupKey, beside: mark) : scheduleFlyoutHide()
            }
            mark.onClick = { [weak self] key in
                guard let self, let found = self.group(key) else { return }
                show(found)
            }
            column.addArrangedSubview(mark)
        }
        place(panel)
        panel.orderFront(nil)
        if let flyoutKey {
            if group(flyoutKey) == nil { closeFlyout() } else { fillFlyout(flyoutKey) }
        }
    }

    private func group(_ key: String) -> Group? { groups.first { $0.key == key } }

    // MARK: The column

    private func makePanel() -> NSPanel {
        let panel = Self.floatingPanel()
        // Dragged by any mark, or the glass between them; where it is left is remembered (`Place`).
        panel.isMovableByWindowBackground = true
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.remember() }
        }
        // A display plugged in, unplugged or rearranged: the dock checks it is still somewhere it can be
        // seen, on the screen it was left on if that is still here.
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel, panel.isVisible else { return }
                self.closeFlyout()
                self.place(panel)
            }
        }
        column.orientation = .vertical
        column.spacing = Self.markSpacing
        let inset = Self.dockInset
        column.edgeInsets = NSEdgeInsets(top: inset, left: inset, bottom: inset, right: inset)
        panel.contentView = Self.glass(radius: Self.dockRadius, holding: column)
        panel.setAccessibilityLabel("Satellite windows")
        self.panel = panel
        return panel
    }

    /// Where the dock was dragged to: which screen, how far in from its leading edge, and where its
    /// middle sits as a fraction of the screen's height — so a screen of another size, or the same one
    /// arranged differently, keeps it roughly where it was put.
    struct Place: Codable, Equatable {
        var screen: String
        var x: Double
        var middle: Double
    }

    static let placeKey = "PMSatelliteDockPlace"
    /// Set while the dock moves itself, which is not a place to remember.
    private var placing = false

    static func id(of screen: NSScreen) -> String {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { "\($0)" }
            ?? screen.localizedName
    }

    /// Where it was put, if that screen is here; else at the leading edge of the screen the pointer is
    /// on, halfway down. Always wholly inside the screen's visible frame.
    private func place(_ panel: NSPanel) {
        let size = column.fittingSize
        let saved = UserDefaults.standard.data(forKey: Self.placeKey).flatMap { try? JSONDecoder().decode(Place.self, from: $0) }
        var frame: NSRect
        if let saved, let screen = NSScreen.screens.first(where: { Self.id(of: $0) == saved.screen }) {
            let visible = screen.visibleFrame
            let middle = visible.minY + visible.height * saved.middle
            frame = NSRect(x: visible.minX + saved.x, y: middle - size.height / 2, width: size.width, height: size.height)
            frame = Self.clamp(frame, into: visible)
        } else {
            let pointer = NSEvent.mouseLocation
            guard let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? NSScreen.main else { return }
            let visible = screen.visibleFrame
            // Grown about its middle while it is up on a screen still here; sent to the edge otherwise.
            if panel.isVisible, let current = panel.screen, NSScreen.screens.contains(current) {
                frame = NSRect(x: panel.frame.minX, y: panel.frame.midY - size.height / 2, width: size.width, height: size.height)
                frame = Self.clamp(frame, into: current.visibleFrame)
            } else {
                frame = NSRect(x: visible.minX + Self.margin, y: visible.midY - size.height / 2,
                               width: size.width, height: size.height)
            }
        }
        frame.origin.y = frame.origin.y.rounded()
        placing = true
        panel.setFrame(frame, display: true)
        placing = false
    }

    /// The dock has been dragged: remember where, on the screen it was left on.
    private func remember() {
        guard !placing, let panel, let screen = panel.screen else { return }
        let visible = screen.visibleFrame
        let place = Place(screen: Self.id(of: screen), x: Double(panel.frame.minX - visible.minX),
                          middle: Double((panel.frame.midY - visible.minY) / max(1, visible.height)))
        if let data = try? JSONEncoder().encode(place) { UserDefaults.standard.set(data, forKey: Self.placeKey) }
        closeFlyout()
    }

    static func clamp(_ frame: NSRect, into visible: NSRect) -> NSRect {
        var frame = frame
        frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        return frame
    }

    // MARK: The flyout

    private func openFlyout(for key: String, beside mark: NSView) {
        hideFlyout?.cancel()
        guard let anchor = mark.window, group(key) != nil else { return }
        let flyout = self.flyout ?? makeFlyout()
        if flyoutKey != key {
            flyoutKey = key
            fillFlyout(key)
        }
        let markOnScreen = anchor.convertToScreen(mark.convert(mark.bounds, to: nil))
        let size = flyoutSize
        // To the right of the dock, unless the dock has been dragged to where there is no room there.
        let visible = anchor.screen?.visibleFrame ?? .infinite
        let right = anchor.frame.maxX + 6
        let x = right + size.width <= visible.maxX ? right : anchor.frame.minX - 6 - size.width
        let origin = NSPoint(x: x, y: (markOnScreen.maxY - size.height + 2).rounded())
        flyout.setFrame(NSRect(origin: origin, size: size), display: true)
        flyout.orderFront(nil)
    }

    private func scheduleFlyoutHide() {
        hideFlyout?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.closeFlyout() }
        hideFlyout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func closeFlyout() {
        hideFlyout?.cancel()
        CanvasFocusHint.shared.hide()
        CanvasWindowGhost.shared.end()
        CanvasDockTip.shared.hide()
        flyout?.orderOut(nil)
        flyoutKey = nil
    }

    private func makeFlyout() -> NSPanel {
        let panel = Self.floatingPanel()
        let hover = CanvasHoverView()
        hover.onHover = { [weak self] over in
            if over { self?.hideFlyout?.cancel() } else { self?.scheduleFlyoutHide() }
        }
        panel.contentView = hover
        flyout = panel
        return panel
    }

    /// The project and Show Window; then, for each workspace with windows out, its name, a button per
    /// window, and Gather.
    private func fillFlyout(_ key: String) {
        guard let flyout, let content = flyout.contentView, let group = group(key) else { return }
        content.subviews.forEach { $0.removeFromSuperview() }

        let name = NSTextField(labelWithString: group.title)
        name.font = .systemFont(ofSize: 13, weight: .semibold)
        Self.fitted(name, upTo: 260)
        let show = Self.button("macwindow", "Show Window") { [weak self] in self?.show(group) }
        let header = NSStackView(views: [name, Self.spacer(), show])
        header.spacing = 6

        let rows = NSStackView(views: [header] + group.workspaces.map(Self.row))
        rows.orientation = .vertical
        rows.alignment = .width
        rows.spacing = 2
        rows.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 6, right: 10)
        let fitted = rows.fittingSize
        flyoutSize = NSSize(width: max(220, fitted.width), height: fitted.height)
        // Glass tinted toward the project's colour: a flavour of its board, as its windows' headers lie
        // on its wash.
        // The window takes its new size first, keeping its top where it was, and only then the glass is
        // laid in, filling it. The other way round, the glass went in at the new size inside a content
        // view still at the old one, and the resize after added the difference to it a second time — a
        // flyout refilled at another size drew its contents too big, clipped at its edges.
        var frame = flyout.frame
        frame.origin.y += frame.height - flyoutSize.height
        frame.size = flyoutSize
        flyout.setFrame(frame, display: false)
        let glass = Self.glass(radius: Self.flyoutRadius, tint: group.color, holding: rows)
        glass.frame = content.bounds
        glass.autoresizingMask = [.width, .height]
        content.addSubview(glass)
    }

    /// A workspace with windows out: its name, a button per window — ringing that window on the screen
    /// while the pointer is on it (`CanvasFocusHint`) — and Gather.
    private static func row(_ workspace: Workspace) -> NSView {
        let label = NSTextField(labelWithString: workspace.name.isEmpty ? "Canvas" : workspace.name)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        Self.fitted(label, upTo: 140)
        let buttons: [NSView] = workspace.satellites.map { satellite in
            let id = satellite.shownCard?.node.id
            let described = id.flatMap { satellite.board?.describeCard($0) }
            let title = described?.title ?? "Card"
            let more = satellite.cards.count > 1 ? " and \(satellite.cards.count - 1) more" : ""
            let button = Self.button(nil, title + more) { [weak satellite] in
                CanvasFocusHint.shared.hide()
                CanvasWindowGhost.shared.keep()
                guard let satellite, let card = satellite.shownCard else { return }
                satellite.reveal(card)
            }
            // Which window it is: a ring round it, and — if other windows are over it — the window
            // itself brought up, faintly, until the pointer leaves.
            button.onHover = { [weak satellite] over in
                if over, let window = satellite?.window {
                    CanvasWindowGhost.shared.show(window)
                    CanvasFocusHint.shared.show(around: window, color: satellite?.projectColor)
                } else {
                    CanvasFocusHint.shared.hide()
                    CanvasWindowGhost.shared.end()
                }
            }
            button.image = CanvasSatelliteWindow.symbol(for: described?.kind)?
                .withSymbolConfiguration(.init(pointSize: 15, weight: .regular))
            button.setAccessibilityLabel(title)
            return button
        }
        let board = workspace.board
        let gather = Self.button("rectangle.grid.2x2", "Gather \(label.stringValue)") { board?.gatherWorkspace() }
        let row = NSStackView(views: [label] + buttons + [Self.spacer(), gather])
        row.spacing = 2
        row.setCustomSpacing(8, after: label)
        return row
    }

    /// A label measured at its full width, up to `limit`, past which it truncates. The flyout is sized
    /// by its fitting size, the smallest its constraints allow, and a label that was allowed to give way
    /// was measured narrower than its words and drawn clipped.
    private static func fitted(_ label: NSTextField, upTo limit: CGFloat) {
        label.lineBreakMode = .byTruncatingTail
        let width = label.widthAnchor.constraint(equalToConstant: min(limit, ceil(label.intrinsicContentSize.width)))
        width.priority = .init(999)
        width.isActive = true
    }

    private static func spacer() -> NSView {
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        return spacer
    }

    // MARK: Pieces

    private static func floatingPanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        return panel
    }

    /// Liquid Glass round `content`, as the Dock is made of — tinted toward `tint`, faintly, when there
    /// is one. Responding to the pointer where the system's glass does (macOS 27).
    private static func glass(radius: CGFloat, tint: NSColor? = nil, holding content: NSView) -> NSGlassEffectView {
        let glass = NSGlassEffectView()
        glass.cornerRadius = radius
        glass.style = .regular
        glass.tintColor = tint?.withAlphaComponent(0.22)
        if #available(macOS 27.0, *) { glass.effectIsInteractive = true }
        content.translatesAutoresizingMaskIntoConstraints = true
        content.autoresizingMask = [.width, .height]
        content.frame = NSRect(origin: .zero, size: content.fittingSize)
        glass.frame = content.frame
        glass.contentView = content
        return glass
    }

    private static func button(_ symbol: String?, _ label: String, _ action: @escaping () -> Void) -> DockButton {
        let button = DockButton(action: action)
        if let symbol {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        }
        // Kept as the tip's text, and as AppKit's own tooltip for whenever Folio is the active app —
        // `CanvasDockTip` stands aside then rather than showing a second one.
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.isBordered = false
        button.bezelStyle = .accessoryBarAction
        button.imagePosition = .imageOnly
        button.contentTintColor = .secondaryLabelColor
        button.widthAnchor.constraint(equalToConstant: 28).isActive = true
        button.heightAnchor.constraint(equalToConstant: 26).isActive = true
        return button
    }
}

/// A borderless button that runs a closure, highlighting on hover as the system's accessory buttons do,
/// with its tooltip drawn by the dock (`CanvasDockTip`): the panel never makes Folio the active app, and
/// AppKit shows tooltips only for the active one.
@MainActor
private final class DockButton: NSButton {
    private let run: () -> Void
    var onHover: (Bool) -> Void = { _ in }

    init(action: @escaping () -> Void) {
        run = action
        super.init(frame: .zero)
        target = self
        self.action = #selector(fire)
        wantsLayer = true
        layer?.cornerRadius = 6
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func fire() {
        CanvasDockTip.shared.hide()
        run()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.1).cgColor
        contentTintColor = .labelColor
        if let toolTip { CanvasDockTip.shared.show(toolTip, below: self) }
        onHover(true)
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = nil
        contentTintColor = .secondaryLabelColor
        CanvasDockTip.shared.hide()
        onHover(false)
    }
}

/// One project's mark in the dock, drawn as a Mac app icon: a squircle in the project's colour, lit
/// from above and set off by a rim and a soft shadow, with the project's icon in white — or its
/// initial, for a project with none. No badge: the flyout lists the windows, and a count on
/// every mark was a number to read that told you nothing you'd act on. VoiceOver still hears it.
@MainActor
private final class DockMark: NSView {
    let groupKey: String
    var onHover: (Bool) -> Void = { _ in }
    var onClick: (String) -> Void = { _ in }
    private let color: NSColor
    private let glyph: NSImage?
    private let initial: String
    private var hovered = false { didSet { needsDisplay = true } }

    /// The icon's corner: a Mac app icon's proportion of corner to side.
    static var cornerRadius: CGFloat { (CanvasSatelliteDock.markSize - 4) * 0.225 }

    init(group: CanvasSatelliteDock.Group) {
        groupKey = group.key
        color = (group.color ?? .systemGray).usingColorSpace(.sRGB) ?? .systemGray
        glyph = group.icon.flatMap { ProjectIconMark.canDraw($0) ? $0 : nil }.flatMap(Self.white)
        initial = String(group.title.prefix(1)).uppercased()
        let side = CanvasSatelliteDock.markSize
        super.init(frame: NSRect(x: 0, y: 0, width: side, height: side))
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: side),
                                     heightAnchor.constraint(equalToConstant: side)])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        let count = group.windowCount
        setAccessibilityLabel(count == 0 ? group.title
            : "\(group.title), \(count) \(count == 1 ? "window" : "windows") out")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The project's icon in white, at the size an app icon's glyph is drawn: a symbol takes the white,
    /// an emoji or a picture keeps its own colours.
    private static func white(_ icon: ProjectIcon) -> NSImage? {
        let renderer = ImageRenderer(content: ProjectIconMark(icon: icon, size: 21, tint: .white).frame(width: 26, height: 26))
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        return renderer.nsImage
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirty: NSRect) {
        let tile = bounds.insetBy(dx: 2, dy: 2)
        let radius = Self.cornerRadius
        let shape = NSBezierPath(roundedRect: tile, xRadius: radius, yRadius: radius)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
        shadow.shadowBlurRadius = 2.5
        shadow.shadowOffset = .zero
        shadow.set()
        color.setFill()
        shape.fill()
        NSGraphicsContext.restoreGraphicsState()

        // Lit from above. In a flipped view 90° runs top to bottom, so the lighter colour is the top.
        let top = color.blended(withFraction: 0.28, of: .white) ?? color
        let bottom = color.blended(withFraction: 0.18, of: .black) ?? color
        NSGradient(starting: top, ending: bottom)?.draw(in: shape, angle: 90)
        if hovered {
            NSColor.white.withAlphaComponent(0.12).setFill()
            shape.fill()
        }
        // A light rim inside, a dark hairline outside: the edge an icon has against any ground.
        let rim = NSBezierPath(roundedRect: tile.insetBy(dx: 0.75, dy: 0.75), xRadius: radius - 0.75, yRadius: radius - 0.75)
        rim.lineWidth = 1
        NSColor.white.withAlphaComponent(0.25).setStroke()
        rim.stroke()
        shape.lineWidth = 0.5
        NSColor.black.withAlphaComponent(0.18).setStroke()
        shape.stroke()

        if let glyph {
            let side: CGFloat = 26
            glyph.draw(in: NSRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side),
                       from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        } else {
            let base = NSFont.systemFont(ofSize: 19, weight: .bold)
            let font = base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: 19) } ?? base
            let text = NSAttributedString(string: initial, attributes: [.font: font, .foregroundColor: NSColor.white])
            let size = text.size()
            text.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2))
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        onHover(true)
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        onHover(false)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// A press that moves more than a few points drags the dock — the marks are most of it — and one
    /// that doesn't is a click.
    private var press: NSEvent?
    private var dragging = false

    override func mouseDown(with event: NSEvent) {
        press = event
        dragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !dragging, let press, let window else { return }
        let start = press.locationInWindow, now = event.locationInWindow
        guard hypot(now.x - start.x, now.y - start.y) > 3 else { return }
        dragging = true
        onHover(false)
        window.performDrag(with: press)
    }

    override func mouseUp(with event: NSEvent) {
        defer { press = nil }
        if !dragging, bounds.contains(convert(event.locationInWindow, from: nil)) { onClick(groupKey) }
    }
}

/// A tooltip for the dock's buttons, drawn by the dock: its panel never makes Folio the active app, and
/// AppKit shows tooltips only for the active app. After the system's own delay, under the button, in the
/// system's tooltip material. Not while Folio is active, where AppKit's own is already coming.
@MainActor
final class CanvasDockTip {
    static let shared = CanvasDockTip()
    private var panel: NSPanel?
    private let label = NSTextField(labelWithString: "")
    private var pending: DispatchWorkItem?

    func show(_ text: String, below view: NSView) {
        hide()
        guard !NSApp.isActive else { return }
        let work = DispatchWorkItem { [weak self, weak view] in
            guard let self, let view, let anchor = view.window else { return }
            let panel = self.panel ?? self.makePanel()
            label.stringValue = text
            let size = panel.contentView?.fittingSize ?? .zero
            let box = anchor.convertToScreen(view.convert(view.bounds, to: nil))
            panel.setFrame(NSRect(x: (box.midX - size.width / 2).rounded(), y: box.minY - size.height - 4,
                                  width: size.width, height: size.height), display: true)
            panel.orderFront(nil)
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func hide() {
        pending?.cancel()
        pending = nil
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let ground = NSVisualEffectView()
        ground.material = .toolTip
        ground.state = .active
        ground.wantsLayer = true
        ground.layer?.cornerRadius = 5
        ground.layer?.masksToBounds = true
        label.font = .toolTipsFont(ofSize: 0)
        label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        ground.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: ground.topAnchor, constant: 3),
            label.bottomAnchor.constraint(equalTo: ground.bottomAnchor, constant: -3),
            label.leadingAnchor.constraint(equalTo: ground.leadingAnchor, constant: 7),
            label.trailingAnchor.constraint(equalTo: ground.trailingAnchor, constant: -7),
        ])
        panel.contentView = ground
        self.panel = panel
        return panel
    }
}

/// The focus hint: a ring round a satellite on the screen while the pointer is on its button in the
/// dock's flyout — which window that button is, before you choose it. Only there, and only while the
/// pointer stays: it says where, and changes nothing.
///
/// A window of its own over the satellite, ringed in the project's colour, at the floating level so it
/// shows even where other windows cover the satellite — which is when it is most wanted.
@MainActor
final class CanvasFocusHint {
    static let shared = CanvasFocusHint()
    private var panel: NSPanel?
    private let ring = CAShapeLayer()

    static let outset: CGFloat = 4
    static let lineWidth: CGFloat = 3
    /// Room round the ring for its glow, which was cut off flat at the overlay's edges when the overlay
    /// was only as big as the ring.
    static let glow: CGFloat = 12
    /// A plain titled window's corner (a satellite has no toolbar). The ring follows it, concentric.
    static let windowRadius: CGFloat = 16

    /// Not for a window on another Space: there is nothing here to ring, and the ring would sit round
    /// wherever its frame falls on this one.
    func show(around window: NSWindow, color: NSColor?) {
        guard window.isOnActiveSpace else { return hide() }
        let panel = self.panel ?? makePanel()
        let margin = Self.outset + Self.glow
        let frame = window.frame.insetBy(dx: -margin, dy: -margin)
        panel.setFrame(frame, display: false)
        let inset = Self.glow + Self.lineWidth / 2
        let bounds = CGRect(origin: .zero, size: frame.size).insetBy(dx: inset, dy: inset)
        let radius = Self.windowRadius + Self.outset - Self.lineWidth / 2
        ring.frame = CGRect(origin: .zero, size: frame.size)
        ring.path = CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
        let tint = color ?? .controlAccentColor
        ring.strokeColor = tint.cgColor
        ring.shadowColor = tint.cgColor
        panel.alphaValue = 0
        panel.orderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        let view = NSView()
        view.wantsLayer = true
        ring.fillColor = nil
        ring.lineWidth = Self.lineWidth
        ring.shadowOpacity = 0.6
        ring.shadowRadius = 6
        ring.shadowOffset = .zero
        view.layer?.addSublayer(ring)
        panel.contentView = view
        self.panel = panel
        return panel
    }
}

/// A window under others, brought up for as long as the pointer is on its button in the dock's flyout —
/// faint, a ghost of itself — and put back exactly where it was in the stack when the pointer leaves.
/// Clicking the button keeps it up, as the window it is (`keep`).
///
/// Only for a window that is hidden on this Space: wholly covered, or with as much as 40% of it under windows above
/// it. One you can already see is shown by the ring alone (`CanvasFocusHint`).
@MainActor
final class CanvasWindowGhost {
    static let shared = CanvasWindowGhost()
    private weak var window: NSWindow?
    /// The window that was just above it, to put it back under.
    private var above: Int?
    private var alpha: CGFloat = 1

    static let opacity: CGFloat = 0.85
    static let coveredEnough: CGFloat = 0.4

    var ghosted: NSWindow? { window }

    func show(_ window: NSWindow) {
        end()
        // Not one on another Space, which reads as hidden too: ordering it front takes the screen there.
        guard window.isVisible, window.isOnActiveSpace, Self.isHidden(window) else { return }
        self.window = window
        above = Self.windowJustAbove(window)
        alpha = window.alphaValue
        window.alphaValue = Self.opacity
        window.orderFrontRegardless()
    }

    /// Back where it was, as it was.
    func end() {
        guard let window else { return }
        window.alphaValue = alpha
        if let above { window.order(.below, relativeTo: above) }
        self.window = nil
        above = nil
    }

    /// Chosen: it stays up, solid.
    func keep() {
        window?.alphaValue = alpha
        window = nil
        above = nil
    }

    /// The windows over this one, front to back, as the window server has them: other apps' too.
    private static func windowsAbove(_ window: NSWindow) -> [[String: Any]] {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenAboveWindow, .excludeDesktopElements],
                                              CGWindowID(window.windowNumber)) as? [[String: Any]] ?? []
        // Ordinary windows only: not the menu bar, the dock's own panels, or anything else floating.
        return list.filter { ($0[kCGWindowLayer as String] as? Int) == 0 && ($0[kCGWindowAlpha as String] as? Double ?? 1) > 0 }
    }

    static func isHidden(_ window: NSWindow) -> Bool {
        if !window.occlusionState.contains(.visible) { return true }
        guard let primary = NSScreen.screens.first?.frame.height else { return false }
        let frame = window.frame
        let area = frame.width * frame.height
        guard area > 0 else { return false }
        // The window server measures from the top of the primary screen; AppKit from the bottom.
        let covered = windowsAbove(window).compactMap { info -> CGFloat? in
            guard let bounds = info[kCGWindowBounds as String] as? [String: Double],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return nil }
            let flipped = NSRect(x: rect.minX, y: primary - rect.maxY, width: rect.width, height: rect.height)
            let overlap = flipped.intersection(frame)
            return overlap.isNull ? 0 : overlap.width * overlap.height
        }.max() ?? 0
        return covered >= area * coveredEnough
    }

    private static func windowJustAbove(_ window: NSWindow) -> Int? {
        windowsAbove(window).last?[kCGWindowNumber as String] as? Int
    }
}
