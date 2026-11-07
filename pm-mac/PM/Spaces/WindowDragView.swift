import AppKit
import SwiftUI

/// A patch of window that moves the window, as a title bar does: drag to move, double-click to zoom.
/// Used for a space's frame (docs/spaces.md § The frame) — the gutters round the tiles and the empty
/// sidebar, which in Arc are the window's own ground.
///
/// A plain view, never an `NSControl`: in the window's titlebar band an `NSControl` carves its rect
/// out of the band's own drag (`WindowDragBlocker`), and the press then went to the titlebar's views
/// rather than here — so a gutter in the band moved nothing (2026-11-04). In the band the window's own
/// drag answers; below it, this does.
final class WindowDragView: NSView {
    /// What a right-click here offers (the sidebar's add list); nil for nothing.
    var contextMenu: (() -> NSMenu)?

    override var mouseDownCanMoveWindow: Bool { true }

    override func menu(for event: NSEvent) -> NSMenu? { contextMenu?() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        if event.clickCount == 2 {
            Self.titleBarDoubleClick(window)
        } else {
            Log.write("window drag from \(frame.width < 20 || frame.height < 20 ? "gutter" : "sidebar")")
            window.performDrag(with: event)
        }
    }

    /// What System Settings says a title bar's double-click does: zoom (Fill), minimize, or nothing.
    static func titleBarDoubleClick(_ window: NSWindow) {
        switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
        case "Minimize": window.performMiniaturize(nil)
        case "None": break
        default: window.performZoom(nil)
        }
    }
}

/// `WindowDragView` behind SwiftUI rows: what isn't a row moves the window.
struct WindowDragArea: NSViewRepresentable {
    var menu: (() -> NSMenu)?

    init(menu: (() -> NSMenu)? = nil) { self.menu = menu }

    func makeNSView(context: Context) -> WindowDragView { WindowDragView() }
    func updateNSView(_ nsView: WindowDragView, context: Context) { nsView.contextMenu = menu }
}

/// The gutter between a space's sidebar and its tiles, as the sidebar's edge: drag it to make the
/// sidebar wider or narrower (docs/spaces.md § The frame). The split's own divider has no width there.
final class SidebarEdgeHandle: NSControl {
    /// The sidebar's width now, and what to do with a new one. Set by the pane from the window's split.
    var width: () -> CGFloat = { 0 }
    var resize: (CGFloat) -> Void = { _ in }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .columnResize)
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let startX = event.locationInWindow.x
        let startWidth = width()
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            resize(startWidth + next.locationInWindow.x - startX)
            if next.type == .leftMouseUp { break }
        }
    }
}

/// Middle-click on whatever it is placed behind. SwiftUI has no gesture for the middle button, and a
/// view that took the press itself would steal the row's left clicks and drags — so this one never
/// takes a hit and listens to the window's events instead, answering only a middle-button release
/// that lands inside its own bounds.
struct MiddleClickArea: NSViewRepresentable {
    var enabled = true
    var action: () -> Void

    func makeNSView(context: Context) -> MiddleClickView { MiddleClickView() }
    func updateNSView(_ nsView: MiddleClickView, context: Context) {
        nsView.enabled = enabled
        nsView.action = action
    }
}

final class MiddleClickView: NSView {
    var enabled = true
    var action: () -> Void = {}
    private var monitor: Any?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .otherMouseUp) { [weak self] event in
            guard let self, self.handle(button: event.buttonNumber, in: event.window,
                                        at: event.locationInWindow) else { return event }
            return nil
        }
    }

    /// A button release at `point` (window coordinates) in `eventWindow`. True when it was ours: the
    /// middle button, over this view, in this view's window — the event is then consumed.
    func handle(button: Int, in eventWindow: NSWindow?, at point: NSPoint) -> Bool {
        guard enabled, button == 2, let window, eventWindow === window,
              bounds.contains(convert(point, from: nil)) else { return false }
        action()
        return true
    }

    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
}

/// How big a sidebar's rows are: System Settings ▸ Appearance ▸ Sidebar icon size, which every Mac
/// sidebar follows (`NSTableViewDefaultSizeMode`: 1 small, 2 medium, 3 large).
struct SidebarMetrics: Equatable {
    var rowHeight: CGFloat
    var font: CGFloat
    var glyph: CGFloat
    var favoriteHeight: CGFloat
    var favoriteGlyph: CGFloat

    static let small = SidebarMetrics(rowHeight: 28, font: 12, glyph: 14, favoriteHeight: 38, favoriteGlyph: 18)
    static let medium = SidebarMetrics(rowHeight: 32, font: 13, glyph: 16, favoriteHeight: 42, favoriteGlyph: 20)
    static let large = SidebarMetrics(rowHeight: 38, font: 15, glyph: 19, favoriteHeight: 48, favoriteGlyph: 23)

    static var current: SidebarMetrics {
        switch UserDefaults.standard.integer(forKey: "NSTableViewDefaultSizeMode") {
        case 1: return .small
        case 3: return .large
        default: return .medium
        }
    }
}

private struct SidebarMetricsKey: EnvironmentKey {
    static let defaultValue = SidebarMetrics.medium
}

extension EnvironmentValues {
    var sidebarMetrics: SidebarMetrics {
        get { self[SidebarMetricsKey.self] }
        set { self[SidebarMetricsKey.self] = newValue }
    }
}

/// Keys and swipes over a sidebar that SwiftUI can't give it without taking the keyboard from the page:
/// Esc (when no field is being typed in) and a sideways two-finger swipe over the sidebar. Never takes a
/// hit; listens to its window's events like `MiddleClickView`.
struct SidebarEventCatcher: NSViewRepresentable {
    /// Esc: true when it was used (the event is then consumed).
    var onEscape: () -> Bool
    /// A sideways swipe: +1 for the next (swiping left, content moving left), -1 for the previous.
    var onSwipe: ((Int) -> Void)?

    func makeNSView(context: Context) -> SidebarEventView { SidebarEventView() }
    func updateNSView(_ view: SidebarEventView, context: Context) {
        view.onEscape = onEscape
        view.onSwipe = onSwipe
    }
}

final class SidebarEventView: NSView {
    var onEscape: () -> Bool = { false }
    var onSwipe: ((Int) -> Void)?
    private var monitor: Any?
    /// The swipe under way: its sideways and upright travel, and whether it already went.
    private var swipe: (dx: CGFloat, dy: CGFloat, fired: Bool)?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .scrollWheel]) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            switch event.type {
            case .keyDown: return self.key(event) ? nil : event
            case .scrollWheel: self.scroll(event); return event
            default: return event
            }
        }
    }

    private func key(_ event: NSEvent) -> Bool {
        guard event.keyCode == 53, event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
              !(window?.firstResponder is NSText) else { return false }
        return onEscape()
    }

    /// Precise (trackpad) scrolls only, inside this view, mostly sideways: one space per gesture.
    func scroll(_ event: NSEvent) {
        guard let onSwipe, event.hasPreciseScrollingDeltas,
              bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        if event.phase.contains(.began) { swipe = (0, 0, false) }
        guard var current = swipe else { return }
        current.dx += event.scrollingDeltaX
        current.dy += abs(event.scrollingDeltaY)
        if !current.fired, abs(current.dx) > 70, abs(current.dx) > current.dy * 2 {
            current.fired = true
            onSwipe(current.dx < 0 ? 1 : -1)
        }
        swipe = event.phase.contains(.ended) || event.phase.contains(.cancelled) ? nil : current
    }

    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
}
