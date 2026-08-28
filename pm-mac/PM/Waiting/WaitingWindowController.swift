import AppKit
import SwiftUI

/// The window the Waiting list lives in. One, for the app's lifetime.
///
/// A window rather than a panel, unlike the focus panel it sits next to in the View menu. The focus
/// panel is a glance you keep in the corner of a screen; this is a list you sit down with, scroll,
/// and act on — so it wants a title bar, a resize handle, and a remembered frame, which is what an
/// ordinary window is for.
///
/// It doesn't own a project and never writes the focused one. Like the focus panel and the menubar
/// item, it reads across everything and points you somewhere.
@MainActor
final class WaitingWindowController: NSObject, NSWindowDelegate {
    static let shared = WaitingWindowController()

    private var window: NSWindow?

    private override init() { super.init() }

    var isVisible: Bool { window?.isVisible ?? false }

    func toggle() { isVisible ? hide() : show() }

    func show() {
        let window = ensureWindow()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        Log.write("waiting window shown frame=\(window.frame)")
    }

    func hide() { window?.orderOut(nil) }

    private func ensureWindow() -> NSWindow {
        if let window { return window }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Waiting"
        window.delegate = self
        // Closing puts it away rather than tearing it down: the list is cheap to keep and expensive
        // to rebuild, and reopening should show what was there while the rescan runs.
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: WaitingView())
        window.setFrameAutosaveName("PMWaitingWindow")
        if window.frame.origin == .zero { window.center() }
        self.window = window
        return window
    }
}
