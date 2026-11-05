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
