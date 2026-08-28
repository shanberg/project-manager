import AppKit
import SwiftUI

/// How dark the screen goes behind a surface that dims it, and which surfaces do.
///
/// `UserDefaults` rather than `PanelSettings`, which is the Raycast-shared file: these are answers
/// about how PM draws itself on this Mac, and nothing outside the app has an opinion about them. The
/// same reasoning the panel's colour mode already follows.
enum ScreenDimSettings {
    /// How dark the quick bar's own scrim goes, as an alpha.
    ///
    /// The quick bar's, and *only* the quick bar's. It used to be one number feeding both surfaces, on
    /// the reasoning that the dim is one effect at two intensities — which was true right up until the
    /// immersive surface's ground became a designed thing with a colour, a blur behind it and an
    /// opacity that trades against that blur. Those are decisions, not preferences, and they live in
    /// `ImmersiveTuning`. Leaving this pointed at both would have been two controls for one value.
    static let strengthKey = "PMScreenDimStrength"
    /// Whether the quick bar dims the screen behind it. Off by default: the bar's whole manner is to
    /// sit over the work you're doing rather than in place of it.
    static let quickBarDimsKey = "PMQuickBarDimsScreen"

    /// Gentle by default. A bar you summon over your work has to leave the work legible; past about a
    /// half this stops being a scrim and starts being a wall with a bar on it, which is the other
    /// surface's job.
    static let defaultStrength: Double = 0.40

    static var strength: Double {
        get {
            guard UserDefaults.standard.object(forKey: strengthKey) != nil else { return defaultStrength }
            return min(1, max(0, UserDefaults.standard.double(forKey: strengthKey)))
        }
        set { UserDefaults.standard.set(min(1, max(0, newValue)), forKey: strengthKey) }
    }

    static var quickBarDims: Bool {
        get { UserDefaults.standard.bool(forKey: quickBarDimsKey) }
        set { UserDefaults.standard.set(newValue, forKey: quickBarDimsKey) }
    }

    /// The dim the quick bar uses, when it's on at all.
    static var quickBarStrength: Double { strength }

    /// Reduce Transparency asks for solid surfaces, and a translucent scrim is exactly what it's
    /// asking about: someone who can't read text over a partly visible desktop can't read it over a
    /// 45%-visible one either. Taken most of the way to opaque rather than all of it, so the backdrop
    /// still reads as something laid over the screen.
    static func honouringAccessibility(_ value: Double) -> Double {
        NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency ? max(value, 0.97) : value
    }
}

/// A black scrim over every screen, at a level of the caller's choosing.
///
/// One window per display, because a window lives on one display and "dim the screen" means all of
/// them — a focus mode that leaves a second monitor at full brightness has dimmed the wrong half of
/// what you can see. They fade together, on the caller's curve, so the dim reads as one event.
///
/// Click-through, always (`ignoresMouseEvents`). The scrim is a thing you look past, not a thing you
/// hit: for the quick bar that keeps clicking away working exactly as it did before this existed —
/// the click lands in the app underneath, PM resigns key, and the bar's own blur-hide runs. A scrim
/// that swallowed the click would have quietly disabled the bar's main way out. A surface that *does*
/// want the click (the immersive presenter) puts its own window above this one and takes it there.
@MainActor
final class ScreenDimmer {
    private var windows: [NSWindow] = []
    private let level: NSWindow.Level
    private var screenObserver: Any?
    /// The strength currently being shown, so a screen arriving mid-dim can be brought up to match.
    private var shownStrength: Double?
    /// A display this scrim leaves alone, because something else is already dimming it.
    ///
    /// The immersive presenter draws the dim for the screen it's centred on *inside its own SwiftUI
    /// stage*, so that the darkening and the content's blur-and-settle are one transaction on one
    /// curve — the thing the transition most has to get right. The other displays have no content to
    /// stay in step with, so they get scrim windows like anything else.
    private var excluded: NSScreen?

    init(level: NSWindow.Level) {
        self.level = level
    }

    var isShowing: Bool { shownStrength != nil }

    /// Fade the scrim in. Idempotent: called again while up, it retargets the strength on the same
    /// curve rather than starting a second one.
    func show(strength: Double, duration: TimeInterval, excluding screen: NSScreen? = nil) {
        let target = ScreenDimSettings.honouringAccessibility(strength)
        shownStrength = target
        excluded = screen
        rebuildWindows()
        observeScreenChanges()
        animate(to: target, duration: duration, thenOrderOut: false)
    }

    /// Fade it out and put the windows away when the fade lands.
    func hide(duration: TimeInterval) {
        guard shownStrength != nil else { return }
        shownStrength = nil
        animate(to: 0, duration: duration, thenOrderOut: true)
    }

    /// Take the scrim down at once, with no fade — for a teardown that isn't a dismissal.
    func hideImmediately() {
        shownStrength = nil
        excluded = nil
        stopObservingScreenChanges()
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
    }

    // MARK: Windows

    private func rebuildWindows() {
        let screens = NSScreen.screens.filter { $0 !== excluded }
        // Rebuilt wholesale rather than diffed: the set changes only when a display is plugged or
        // unplugged, and matching old windows to new screen frames is more bookkeeping than making
        // three windows costs.
        let existingAlpha = windows.first?.alphaValue ?? 0
        windows.forEach { $0.orderOut(nil) }
        windows = screens.map { screen in
            let window = DimWindow(contentRect: screen.frame, styleMask: [.borderless],
                                   backing: .buffered, defer: false)
            window.setFrame(screen.frame, display: false)
            window.isOpaque = false
            window.backgroundColor = .black
            window.hasShadow = false
            window.ignoresMouseEvents = true
            window.isMovable = false
            window.level = level
            window.alphaValue = existingAlpha
            window.tabbingMode = .disallowed
            window.hidesOnDeactivate = false
            // Present on whichever Space you're on, and never in ⌘⇥ or the window cycle: the scrim is
            // an effect, not a window anybody navigates to.
            window.collectionBehavior = [.ignoresCycle, .canJoinAllSpaces, .fullScreenAuxiliary,
                                         .stationary]
            // No implicit fade of its own — every alpha change here is one we're timing deliberately
            // against the content's, and an implicit animation underneath would be a second curve.
            window.animationBehavior = .none
            window.orderFrontRegardless()
            return window
        }
    }

    private func animate(to alpha: Double, duration: TimeInterval, thenOrderOut: Bool) {
        let windows = self.windows
        guard duration > 0 else {
            windows.forEach { $0.alphaValue = alpha }
            if thenOrderOut { finishHiding() }
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            windows.forEach { $0.animator().alphaValue = alpha }
        } completionHandler: { [weak self] in
            guard thenOrderOut else { return }
            // Only if nothing re-showed it in the meantime; a summon that interrupts a fade-out keeps
            // its windows.
            guard let self, self.shownStrength == nil else { return }
            self.finishHiding()
        }
    }

    private func finishHiding() {
        excluded = nil
        stopObservingScreenChanges()
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
    }

    /// A display plugged in or unplugged while the scrim is up leaves a bright rectangle otherwise.
    private func observeScreenChanges() {
        guard screenObserver == nil else { return }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let strength = self.shownStrength else { return }
                    self.rebuildWindows()
                    self.animate(to: strength, duration: 0, thenOrderOut: false)
                }
            }
    }

    private func stopObservingScreenChanges() {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
    }
}

/// A window that exists to be looked past: it never takes key or main, so nothing about the scrim can
/// move the keyboard away from the surface it's sitting behind.
private final class DimWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
