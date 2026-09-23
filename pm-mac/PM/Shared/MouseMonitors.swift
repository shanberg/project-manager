import AppKit
import SwiftUI

/// The window's small monitors: things AppKit will tell you and SwiftUI will not.
///
/// They were written for the task column's rows and outlived it — every one of them is now used by
/// the project-note card, which needs the same answers for the same reason. Nothing here is about a
/// column; it is about the gap between a gesture recogniser and a real mouse.

// MARK: Helpers

/// Fires on any left mouse-up in the app while the window is shown. Used as a reliable end signal for a
/// *no-move* drag press: SwiftUI starts a drag (setting the drag key) but if the pointer never moves,
/// the release is an ordinary click whose mouse-up is delivered here — a real drag's concluding mouse-up
/// is consumed by the drag loop instead, and handled by the item-provider sentinel / the drop itself.
/// A backstop for the end of a *real* drag.
///
/// Neither existing end signal covers one on its own. `LeftMouseUpMonitor` sees only a press that never
/// moved — a real drag's concluding mouse-up is consumed by the drag loop, as its own note says. And
/// `DragEndSentinel` fires when ARC releases the drag's item provider, which is the right moment but
/// not a guarantee the framework makes. Left to those two, a release the sentinel is late for strands
/// the list: rows stay dimmed under a drag that has already finished, and only another drag clears it.
///
/// So while a drag is in flight, poll for the button coming up. Same technique and the same reason as
/// `FocusPanelChrome.startDragTracking` — inside AppKit's drag loop, a timer in `.common` modes is the
/// thing that still runs. Whichever signal arrives first wins and disarms the rest, so in the ordinary
/// case this ticks a few times during the drag and stops without ever being the one to act.
@MainActor
@Observable
final class DragEndWatcher {
    @ObservationIgnored
    private var timer: Timer?
    @ObservationIgnored
    private var onEnd: (() -> Void)?

    func arm(onEnd: @escaping () -> Void) {
        guard timer == nil else { return }
        self.onEnd = onEnd
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, NSEvent.pressedMouseButtons & 0x1 == 0 else { return }
                let end = self.onEnd
                self.disarm()
                end?()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func disarm() {
        timer?.invalidate()
        timer = nil
        onEnd = nil
    }
}

@Observable
final class LeftMouseUpMonitor {
    @ObservationIgnored
    var onMouseUp: (() -> Void)?
    @ObservationIgnored
    private var monitor: Any?

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            self?.onMouseUp?()
            return event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

/// Which task row the pointer is over. A plain reference box rather than `@State` on purpose: nothing
/// on screen depends on it, so moving between rows shouldn't cost a render. Only the right-click
/// monitor reads it, at the moment of the click.
final class RowHoverTracker {
    private(set) var key: String?

    /// `inside` false only clears the key when it's still *this* row's — rows can report leaving after
    /// the next one reports entering, which would otherwise blank a key that had just been set.
    func set(_ key: String, inside: Bool) {
        if inside { self.key = key } else if self.key == key { self.key = nil }
    }
}

/// Fires on any right mouse-down in the app while the window is shown, so the task list can move its
/// highlight onto the row whose context menu is about to open.
///
/// This is an event monitor rather than something computed while the menu is built because SwiftUI
/// builds a row's `.contextMenu` content during the row's body pass, not on the click — so anything
/// that mutates state from there runs once per row per render (see `CanvasProjectNote.contextTargets`). A
/// local monitor sees the event before it reaches the view, so the selection is committed by the time
/// the menu appears.
@Observable
final class RightMouseDownMonitor {
    @ObservationIgnored
    var onRightMouseDown: (() -> Void)?
    @ObservationIgnored
    private var monitor: Any?

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
            self?.onRightMouseDown?()
            return event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

/// Publishes whether ⌥ is currently held, so a button can swap its icon/action live (as macOS menus
/// do for alternate items). Backed by a local `flagsChanged` monitor active while the window is key.
@Observable
final class ModifierMonitor {
    var optionDown = false
    @ObservationIgnored
    private var monitor: Any?

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            // Only publish on a real change. `flagsChanged` fires for *every* modifier, press and
            // release — ⌘ and ⇧ included, which are exactly the keys held while multi-selecting — and
            // an unconditional write to an observed property announces whether or not the value moved.
            // That rebuilt the whole view body, sidebar list and all, several times per click.
            let down = event.modifierFlags.contains(.option)
            if let self, self.optionDown != down { self.optionDown = down }
            return event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        optionDown = false
    }
}
/// Logs where every click in the app lands, for chasing a region that stops taking them.
///
/// Only while the log is on (`Log.isEnabled`). Per press: the window the event was routed to, the
/// window on top at that point on screen (ours or another app's), the view chain `hitTest` answers
/// with, and the window's child windows. A dead region with no line at all never reached this process.
@MainActor
enum ClickTrace {
    private static var monitor: Any?

    static func install() {
        guard Log.isEnabled, monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
            trace(event)
            return event
        }
    }

    private static func trace(_ event: NSEvent) {
        let screen = NSEvent.mouseLocation
        let top = NSWindow.windowNumber(at: screen, belowWindowWithWindowNumber: 0)
        let topWindow = NSApp.window(withWindowNumber: top)
        var lines = ["CLICK at screen \(point(screen)) routed to \(describe(event.window)); on top: #\(top) \(topWindow.map(describe) ?? "another app's window")"]
        if let window = event.window, let content = window.contentView {
            let local = event.locationInWindow
            // From the theme frame, so titlebar views count too.
            var view = content.superview?.hitTest(local) ?? content.hitTest(local)
            var depth = 0
            while let current = view, depth < 14 {
                let frame = current.convert(current.bounds, to: nil)
                lines.append("  \(type(of: current)) \(rect(frame))\(current.alphaValue < 1 ? " alpha=\(current.alphaValue)" : "")")
                view = current.superview
                depth += 1
            }
            for child in window.childWindows ?? [] {
                lines.append("  child \(describe(child)) \(rect(child.frame)) visible=\(child.isVisible) alpha=\(child.alphaValue) ignoresMouse=\(child.ignoresMouseEvents)")
            }
        }
        Log.write(lines.joined(separator: "\n"))
    }

    private static func describe(_ window: NSWindow?) -> String {
        guard let window else { return "nil" }
        return "\(type(of: window)) #\(window.windowNumber) '\(window.title)'"
    }

    private static func point(_ p: NSPoint) -> String { "(\(Int(p.x)), \(Int(p.y)))" }
    private static func rect(_ r: NSRect) -> String {
        "(\(Int(r.minX)), \(Int(r.minY)) \(Int(r.width))×\(Int(r.height)))"
    }
}
