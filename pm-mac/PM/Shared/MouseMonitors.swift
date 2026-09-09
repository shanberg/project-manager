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
final class DragEndWatcher: ObservableObject {
    private var timer: Timer?
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

final class LeftMouseUpMonitor: ObservableObject {
    var onMouseUp: (() -> Void)?
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
final class RightMouseDownMonitor: ObservableObject {
    var onRightMouseDown: (() -> Void)?
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
final class ModifierMonitor: ObservableObject {
    @Published var optionDown = false
    private var monitor: Any?

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            // Only publish on a real change. `flagsChanged` fires for *every* modifier, press and
            // release — ⌘ and ⇧ included, which are exactly the keys held while multi-selecting — and
            // an unconditional write to an `@Published` republishes whether or not the value moved.
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