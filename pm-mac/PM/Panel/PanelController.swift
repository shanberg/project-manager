import AppKit
import SwiftUI
import QuartzCore

/// SwiftUI-observable panel chrome state. Currently tracks whether a resize animation is in flight so
/// the content view can hide its scrollbar for the duration (avoiding a flash mid-animation).
final class PanelChrome: ObservableObject {
    @Published var isResizing = false
}

/// Owns the floating PM Panel window (an `NSPanel` hosting `PanelView`). Reproduces the retired Tauri
/// panel's behavior: fixed 380 pt width with auto-fitting height, summon/dismiss, blur-to-hide with a
/// grace period (suppressed when pinned), and float-above-others when the float setting is on.
@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    private let store: PMStore
    private let panel: NSPanel
    private var settings: PanelSettings

    /// Fixed panel width (the content lays out to this; height auto-fits).
    static let width: CGFloat = 420
    /// Window identifier so the panel's outside-click monitor can scope to this window.
    static let windowIdentifier = "PMPanel"
    /// Max height as a Tarot-card proportion of the width (~2.75×4.75). Content beyond this scrolls;
    /// below it, the panel fits exactly.
    static let maxHeightRatio: CGFloat = 4.75 / 2.75

    /// SwiftUI-observable chrome shared with `PanelView` (hides the scrollbar during a resize).
    private let chrome: PanelChrome

    /// Grace period before a blurred (unpinned) panel hides — long enough to ride out transient focus
    /// blips (a popover, a quick app switch, the summon shortcut itself).
    private let blurHideDelay: TimeInterval = 0.2
    private var pendingHide: DispatchWorkItem?
    /// Set on summon so the first auto-fit after showing snaps instead of animating a grow-on-open.
    private var suppressNextFitAnimation = false

    private let hosting: NSHostingController<PanelView>

    init(store: PMStore, settings: PanelSettings) {
        self.store = store
        self.settings = settings

        self.chrome = PanelChrome()
        hosting = NSHostingController(rootView: PanelView(store: store, chrome: PanelChrome()))
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 420),
            styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        super.init()

        // Inject panel callbacks now that `self` exists: Escape-to-hide and content-driven auto-fit.
        hosting.rootView = PanelView(
            store: store,
            chrome: chrome,
            onDismiss: { [weak self] in self?.hide() },
            onContentHeight: { [weak self] height in self?.fit(toContentHeight: height) }
        )

        // The hosting controller owns content sizing (reliable auto-fit); the glass/vibrant material
        // is a SwiftUI background inside PanelView, so it fills the content's layout rather than
        // fighting it. The window is non-opaque so that material shows through.
        panel.contentViewController = hosting

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        // Tag the window so PanelView's outside-click monitor can tell our clicks from other windows'.
        panel.identifier = NSUserInterfaceItemIdentifier(Self.windowIdentifier)
        // Dismissal is via Escape / blur / hotkey / menu, so hide all traffic-light buttons — this
        // also removes the close button that was overlapping the title.
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        applySettings(settings)
        restorePosition()
    }

    // MARK: Show / hide

    var isVisible: Bool { panel.isVisible }

    func toggle() { isVisible ? hide() : show() }

    func show() {
        pendingHide?.cancel()
        suppressNextFitAnimation = true
        Self.wasOpen = true
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func hide() {
        pendingHide?.cancel()
        Self.wasOpen = false
        panel.orderOut(nil)
    }

    // MARK: Open-state restore

    /// Whether the panel was open (user intent, not transient visibility) when the app last ran, so it
    /// can reopen on relaunch. Set by the explicit summon/dismiss paths (`show`/`hide`); the blur
    /// auto-hide deliberately leaves it set, since an unpinned panel that hid on blur is still "open".
    /// App-local (`UserDefaults`) rather than in the Raycast-shared settings file.
    static var wasOpen: Bool {
        get { UserDefaults.standard.bool(forKey: wasOpenKey) }
        set { UserDefaults.standard.set(newValue, forKey: wasOpenKey) }
    }
    private static let wasOpenKey = "PMPanelWasOpen"

    /// Reopen the panel on launch if it was open when the app was last quit.
    func restoreIfNeeded() {
        if Self.wasOpen { show() }
    }

    // MARK: Settings

    func applySettings(_ new: PanelSettings) {
        settings = new
        panel.level = new.floating ? .floating : .normal
    }

    // MARK: Window position persistence

    /// Persisted position, anchored to whichever corner is nearest a screen edge. Storing offsets
    /// from the near edges (rather than an absolute point) keeps the panel the same distance from
    /// that edge across resolution/display changes, and the vertical anchor also drives which edge
    /// the auto-fit grows from — see `verticalAnchorNearTop` / `fit(toContentHeight:)`.
    private struct SavedPosition: Codable {
        var fromRight: Bool     // horizontal anchor: nearer the right screen edge?
        var xOffset: CGFloat    // distance from that edge to the panel's near vertical side
        var fromTop: Bool       // vertical anchor: nearer the top screen edge?
        var yOffset: CGFloat    // distance from that edge to the panel's near horizontal side
    }
    private static let positionKey = "PMPanelAnchor"

    private var visibleFrame: NSRect? { (panel.screen ?? NSScreen.main)?.visibleFrame }

    /// Whether the panel's top edge is currently the nearer of the two horizontal screen edges. The
    /// auto-fit keeps this edge fixed so growth happens away from the nearby edge. Defaults to top.
    private var verticalAnchorNearTop: Bool {
        guard let vf = visibleFrame else { return true }
        return (vf.maxY - panel.frame.maxY) <= (panel.frame.minY - vf.minY)
    }

    private func savePosition() {
        guard let vf = visibleFrame else { return }
        let f = panel.frame
        let fromRight = (vf.maxX - f.maxX) < (f.minX - vf.minX)
        let fromTop = verticalAnchorNearTop
        let pos = SavedPosition(
            fromRight: fromRight,
            xOffset: fromRight ? vf.maxX - f.maxX : f.minX - vf.minX,
            fromTop: fromTop,
            yOffset: fromTop ? vf.maxY - f.maxY : f.minY - vf.minY
        )
        if let data = try? JSONEncoder().encode(pos) {
            UserDefaults.standard.set(data, forKey: Self.positionKey)
        }
    }

    /// Restore the panel relative to its nearest-edge corner, or center on first run. A later auto-fit
    /// keeps the anchored vertical edge fixed, preserving the position.
    ///
    /// This runs in `init`, before the hosting controller has laid out the SwiftUI content, so at this
    /// point `panel.frame.size` is still `.zero`. We must therefore anchor off the panel's known fixed
    /// width (`Self.width`) rather than the not-yet-measured `frame.width`: a right-anchored panel sets
    /// its left edge here, and the auto-fit grows width from that left edge, so using a zero width would
    /// leave the panel one full width too far right. Height needs no such care — the top-anchored case
    /// cancels height out (top edge = origin.y + height), and the bottom-anchored case ignores it.
    private func restorePosition() {
        guard let data = UserDefaults.standard.data(forKey: Self.positionKey),
              let pos = try? JSONDecoder().decode(SavedPosition.self, from: data),
              let vf = visibleFrame else {
            panel.center()
            return
        }
        let height = panel.frame.height
        let x = pos.fromRight ? vf.maxX - pos.xOffset - Self.width : vf.minX + pos.xOffset
        let y = pos.fromTop ? vf.maxY - pos.yOffset - height : vf.minY + pos.yOffset
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    /// Auto-fit the panel height to its content (width stays 380), clamped to a sane min and 95% of
    /// the screen — the native equivalent of the old panel's double-click "fit to content".
    private func fit(toContentHeight height: CGFloat) {
        let screenMax = (panel.screen ?? NSScreen.main)?.visibleFrame.height ?? 900
        let maxHeight = min(Self.width * Self.maxHeightRatio, floor(screenMax * 0.95))
        let target = min(max(ceil(height), 120), maxHeight)
        guard abs(panel.frame.height - target) > 1 else { return }
        var frame = panel.frame
        // Grow/shrink from whichever horizontal screen edge the panel is anchored to: keep the top
        // edge fixed when anchored near the top (grows downward), else keep the bottom edge fixed
        // (grows upward). Either way the panel expands away from the nearby edge, not across it.
        if verticalAnchorNearTop { frame.origin.y += frame.height - target }
        frame.size = NSSize(width: Self.width, height: target)

        // Animate the resize, except for the first fit right after summon and while hidden, which
        // should snap. The scrollbar is hidden for the duration so it doesn't flash while the viewport
        // and content are briefly mismatched mid-animation.
        let animate = panel.isVisible && !suppressNextFitAnimation
        suppressNextFitAnimation = false
        if animate {
            chrome.isResizing = true
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.24
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                ctx.allowsImplicitAnimation = true
                panel.animator().setFrame(frame, display: true)
            } completionHandler: { [weak self] in
                self?.chrome.isResizing = false
            }
        } else {
            panel.setFrame(frame, display: true, animate: false)
        }
    }

    // MARK: NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        // Pinned panels stay open on blur; otherwise hide after a short grace period unless focus
        // returns (a later becomeKey cancels the pending hide).
        guard !settings.pinned else { return }
        pendingHide?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.panel.isKeyWindow else { return }
            self.panel.orderOut(nil)
        }
        pendingHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + blurHideDelay, execute: work)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        pendingHide?.cancel()
    }

    func windowDidMove(_ notification: Notification) {
        // Fires on user drags (and on the auto-fit reposition, which leaves the top-left unchanged).
        savePosition()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Closing hides rather than destroying the panel; it's summoned again later.
        hide()
        return false
    }
}
