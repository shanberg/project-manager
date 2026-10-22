import AppKit
import PmLib
import SwiftUI

/// Where the satellites are: a column at the screen's edge, one mark per workspace with windows out.
///
/// **One for the app, not one per window.** Satellites stay out when their window goes on to another
/// workspace (`CanvasBoardView.viewWillMove`), and a popped-out workspace puts its window away
/// (`popOutWorkspace`), so workspaces with windows out outnumber the windows showing them. Something
/// has to say where they all are and how to get them back, whichever project they belong to.
///
/// **A mark per workspace, folded.** The mark is dressed as the project — its colour, its icon — with
/// the number of windows out. Hovering opens a flyout to the mark's right: the workspace and the
/// project on one row, a button per window on the next, and Show Window and Gather. Out to the side and
/// over the screen, so the column itself never changes size and nothing in it moves under the pointer.
/// Clicking the mark shows the workspace's window.
///
/// **Dressed as the Mac's own Dock**: a column of Liquid Glass, and each workspace an app icon — a
/// squircle in the project's colour, lit from above, with its icon in white — so a row of them reads as
/// things you go to, not controls. The flyout is glass too, tinted toward the project.
///
/// **A panel, as a palette is**: floating, and never taking the app's focus. It stays up while another
/// app is in front and on every Space: satellites are windows you keep beside other apps' work, and the
/// dock is how you find them again from there.
@MainActor
final class CanvasSatelliteDock: NSObject {
    static let shared = CanvasSatelliteDock()

    /// One workspace's windows out: where they came from, and the windows.
    @MainActor struct Group {
        var canvas: URL
        var workspace: String
        var satellites: [CanvasSatelliteWindow]
        var board: CanvasBoardView? { satellites.first?.board }
        var key: String { canvas.path + "\u{1F}" + workspace }
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
    static let dockRadius: CGFloat = 22
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

    /// The satellites up, by workspace, in the order their first window came out.
    static func groups(of open: [CanvasSatelliteWindow]) -> [Group] {
        var groups: [Group] = []
        for satellite in open where satellite.board != nil && !satellite.cards.isEmpty {
            if let index = groups.firstIndex(where: { $0.canvas == satellite.canvas && $0.workspace == satellite.workspace }) {
                groups[index].satellites.append(satellite)
            } else {
                groups.append(Group(canvas: satellite.canvas, workspace: satellite.workspace, satellites: [satellite]))
            }
        }
        return groups
    }

    private func rebuild() {
        groups = Self.groups(of: CanvasSatelliteWindow.open)
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
            mark.onClick = { [weak self] key in self?.group(key)?.board?.showWorkspaceWindow() }
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
        column.orientation = .vertical
        column.spacing = Self.markSpacing
        let inset = Self.dockInset
        column.edgeInsets = NSEdgeInsets(top: inset, left: inset, bottom: inset, right: inset)
        panel.contentView = Self.glass(radius: Self.dockRadius, holding: column)
        panel.setAccessibilityLabel("Satellite windows")
        self.panel = panel
        return panel
    }

    /// At the leading edge of the screen the pointer is on, halfway down.
    private func place(_ panel: NSPanel) {
        let size = column.fittingSize
        let pointer = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? NSScreen.main
        else { return }
        let visible = screen.visibleFrame
        let origin = NSPoint(x: visible.minX + Self.margin, y: (visible.midY - size.height / 2).rounded())
        // Not moved for a change of size alone once it is up: it grows about its middle, and only a
        // first showing or a change of screen sends it to the edge again.
        if panel.isVisible, let current = panel.screen, current == screen {
            let middle = panel.frame.midY
            panel.setFrame(NSRect(x: panel.frame.minX, y: (middle - size.height / 2).rounded(),
                                  width: size.width, height: size.height), display: true)
        } else {
            panel.setFrame(NSRect(origin: origin, size: size), display: true)
        }
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
        let origin = NSPoint(x: anchor.frame.maxX + 6, y: (markOnScreen.maxY - size.height + 2).rounded())
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

    /// Two rows: the workspace and its project, with Show Window and Gather; then a button per window.
    private func fillFlyout(_ key: String) {
        guard let flyout, let content = flyout.contentView, let group = group(key) else { return }
        content.subviews.forEach { $0.removeFromSuperview() }

        let name = NSTextField(labelWithString: group.workspace.isEmpty ? "Canvas" : group.workspace)
        name.font = .systemFont(ofSize: 13, weight: .semibold)
        let project = NSTextField(labelWithString: group.satellites.first?.projectTitle ?? "")
        project.font = .systemFont(ofSize: 11)
        project.textColor = .secondaryLabelColor
        project.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let show = Self.button("macwindow", "Show Window") { group.board?.showWorkspaceWindow() }
        let gather = Self.button("rectangle.grid.2x2", "Gather \(name.stringValue)") { group.board?.gatherWorkspace() }
        let label = NSStackView(views: [name, project, spacer, show, gather])
        label.spacing = 6
        label.setCustomSpacing(12, after: spacer)
        label.setCustomSpacing(0, after: show)

        let windows = NSStackView(views: group.satellites.map { satellite in
            let id = satellite.shownCard?.node.id
            let described = id.flatMap { satellite.board?.describeCard($0) }
            let title = described?.title ?? "Card"
            let more = satellite.cards.count > 1 ? " and \(satellite.cards.count - 1) more" : ""
            let button = Self.button(nil, title + more) { [weak satellite] in
                CanvasFocusHint.shared.hide()
                guard let satellite, let card = satellite.shownCard else { return }
                satellite.reveal(card)
            }
            // Which window it is, on the screen: a ring round it while the pointer is on its button.
            button.onHover = { [weak satellite] over in
                if over, let window = satellite?.window {
                    CanvasFocusHint.shared.show(around: window, color: satellite?.projectColor)
                } else {
                    CanvasFocusHint.shared.hide()
                }
            }
            button.image = CanvasSatelliteWindow.symbol(for: described?.kind)?
                .withSymbolConfiguration(.init(pointSize: 15, weight: .regular))
            button.setAccessibilityLabel(title)
            return button
        })
        windows.spacing = 2

        let rows = NSStackView(views: [label, windows])
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 4
        rows.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 8, right: 12)
        let fitted = rows.fittingSize
        flyoutSize = NSSize(width: max(220, fitted.width), height: fitted.height)
        // Glass tinted toward the project's colour: a flavour of its board, as its windows' headers lie
        // on its wash.
        let glass = Self.glass(radius: Self.flyoutRadius, tint: group.satellites.first?.projectColor, holding: rows)
        glass.frame = NSRect(origin: .zero, size: flyoutSize)
        glass.autoresizingMask = [.width, .height]
        content.addSubview(glass)
        if flyout.isVisible {
            var frame = flyout.frame
            frame.origin.y += frame.height - flyoutSize.height
            frame.size = flyoutSize
            flyout.setFrame(frame, display: true)
        }
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

/// One workspace's mark in the dock, drawn as a Mac app icon: a squircle in the project's colour, lit
/// from above and set off by a rim and a soft shadow, with the project's icon in white — or the
/// workspace's initial, for a project with none — and the count of windows out as a badge.
@MainActor
private final class DockMark: NSView {
    let groupKey: String
    var onHover: (Bool) -> Void = { _ in }
    var onClick: (String) -> Void = { _ in }
    private let color: NSColor
    private let glyph: NSImage?
    private let initial: String
    private let count: Int
    private var hovered = false { didSet { needsDisplay = true } }

    init(group: CanvasSatelliteDock.Group) {
        groupKey = group.key
        let first = group.satellites.first
        color = (first?.projectColor ?? .systemGray).usingColorSpace(.sRGB) ?? .systemGray
        glyph = first?.projectMarkIcon.flatMap(Self.white)
        initial = String((group.workspace.isEmpty ? first?.projectTitle ?? "C" : group.workspace).prefix(1)).uppercased()
        count = group.satellites.count
        let side = CanvasSatelliteDock.markSize
        super.init(frame: NSRect(x: 0, y: 0, width: side, height: side))
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: side),
                                     heightAnchor.constraint(equalToConstant: side)])
        let workspace = group.workspace.isEmpty ? "Canvas" : group.workspace
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("\(workspace), \(first?.projectTitle ?? ""), \(count) \(count == 1 ? "window" : "windows")")
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
        // The proportion of a Mac app icon's corner to its side.
        let radius = tile.width * 0.225
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

        guard count > 1 else { return }
        let badge = NSAttributedString(string: "\(count)", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold), .foregroundColor: NSColor.white,
        ])
        let size = badge.size()
        let width = max(16, size.width + 8)
        let pill = NSRect(x: bounds.maxX - width, y: 0, width: width, height: 16)
        let capsule = NSBezierPath(roundedRect: pill, xRadius: 8, yRadius: 8)
        NSColor(white: 0.22, alpha: 0.95).setFill()
        capsule.fill()
        NSColor.white.withAlphaComponent(0.85).setStroke()
        capsule.lineWidth = 1
        capsule.stroke()
        badge.draw(at: NSPoint(x: pill.midX - size.width / 2, y: pill.midY - size.height / 2))
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
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick(groupKey) }
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

    func show(around window: NSWindow, color: NSColor?) {
        let panel = self.panel ?? makePanel()
        let frame = window.frame.insetBy(dx: -Self.outset, dy: -Self.outset)
        panel.setFrame(frame, display: false)
        let bounds = CGRect(origin: .zero, size: frame.size).insetBy(dx: Self.lineWidth / 2, dy: Self.lineWidth / 2)
        let radius = 12 + Self.outset
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
