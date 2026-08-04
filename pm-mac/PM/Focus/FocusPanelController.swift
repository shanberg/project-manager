import AppKit
import SwiftUI

/// The focus panel: one small always-on-top window showing the focused project's current task.
///
/// There is exactly one, for the app's lifetime — `shared`. That's the whole model: it isn't opened
/// per project, it doesn't own a project, and it never writes the focused project the way a project
/// window does on becoming main. It *reads* whatever is focused, which is what keeps it, the menubar
/// item and the CLI permanently in agreement.
///
/// It is deliberately non-activating: clicking it to tick a task off doesn't pull focus out of the
/// editor you were working in. Typing still works when you want it (see `KeyablePanel`) — ⌃⌥P makes it
/// key on the way up, so show → ⏎ → Escape completes a task without touching the mouse.
@MainActor
final class FocusPanelController: NSObject, NSWindowDelegate {
    static let shared = FocusPanelController()

    private var panel: KeyablePanel?
    private var chrome: FocusPanelChrome?
    private var hosting: NSHostingController<FocusPanelView>?

    /// The store for whatever project is focused. Shared with the menubar through `StoreRegistry`, so
    /// the two can't drift apart on undo history or completion state.
    private var store: PMStore = StoreRegistry.shared.emptyStore

    /// Panel settings (the Raycast-shared `{pinned, floating}` file). Held so a panel built later
    /// starts with the current values.
    private var settings: PanelSettings = .default

    private override init() { super.init() }

    // MARK: Presentation

    var isVisible: Bool { panel?.isVisible ?? false }

    /// Show the panel and give it key focus, so its ⏎ / Escape shortcuts are live immediately.
    ///
    /// Key focus without app activation is the point: `.nonactivatingPanel` means the app you were in
    /// keeps its active state and its menu bar, while the keystrokes go to the panel in front of it.
    func show() {
        let panel = ensurePanel()
        chrome?.prepareToShow()
        // Force the SwiftUI layout before the window is on screen. The panel takes its size from the
        // content's measured height, and on the very first show that measurement hasn't happened yet —
        // ordering front first would flash a zero-sized window for a frame before the fit lands.
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.orderFrontRegardless()
        // Every path here is an explicit summon — the hotkey, the menubar item, `pmpanel://show` — so
        // taking the keyboard is what was asked for. Nothing else opens the panel on the user's behalf.
        panel.takeKey()
        Log.write("focus panel shown: \(store.boundKey ?? "no project") frame=\(panel.frame)")
    }

    func hide() {
        guard let panel else { return }
        chrome?.prepareToHide()
        chrome?.savePosition()
        panel.orderOut(nil)
        Log.write("focus panel hidden")
    }

    /// ⌃⌥P and `pmpanel://toggle`. A HUD's toggle is simply show/hide — unlike the old panel's, it never
    /// has to decide whether "hide" means the window or the whole app, because it isn't the app.
    func toggle() {
        if isVisible { hide() } else { show() }
    }

    // MARK: Focus tracking

    /// Point the panel at the currently-focused project. Called on launch and whenever `focused.json`
    /// changes — the same signal that re-points the menubar.
    func syncToFocusedProject() {
        let key = PMFiles.focusedProjectKey()
        guard key != store.boundKey else {
            store.reload()
            return
        }
        let previous = store
        store = StoreRegistry.shared.acquire(key)
        rebuildContent()
        if previous !== store { StoreRegistry.shared.release(previous.boundKey) }
    }

    /// Re-apply the Raycast-shared pin/float settings.
    func applyPanelSettings(_ new: PanelSettings) {
        settings = new
        chrome?.applySettings(new)
    }

    /// Re-apply "Show on all Spaces" after a Settings change, without needing the panel reopened.
    func applyWindowSettings() {
        chrome?.applyWindowSettings()
    }

    // MARK: Construction

    private func ensurePanel() -> KeyablePanel {
        if let panel { return panel }

        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: ProjectWindow.focusPanelWidth, height: 160),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        // Borderless windows can't be tabbed, and a singleton has nothing to tab with anyway.
        panel.tabbingMode = .disallowed
        panel.identifier = NSUserInterfaceItemIdentifier(Self.windowIdentifier)

        self.panel = panel
        // Before the content, not after. Installing the hosting controller triggers the first layout,
        // and that layout's measured height is the only one the panel will ever get for a task whose
        // text doesn't change — so a chrome that doesn't exist yet drops the sole fit and leaves the
        // panel at its nominal size forever.
        self.chrome = FocusPanelChrome(panel: panel, settings: settings)

        let hosting = NSHostingController(rootView: makeView())
        // The panel sizes itself to the content's *measured* height (see `FocusPanelChrome.fit`).
        // Left on the default, AppKit would also resize the window to the hosting controller's ideal
        // size, which closes a loop with that auto-fit.
        hosting.sizingOptions = []
        panel.contentViewController = hosting
        self.hosting = hosting
        return panel
    }

    private func makeView() -> FocusPanelView {
        FocusPanelView(
            store: store,
            onDismiss: { [weak self] in self?.hide() },
            onContentHeight: { [weak self] height in self?.chrome?.fit(toContentHeight: height) },
            onOpenProject: { [weak self] in
                guard let self else { return }
                WindowManager.shared.open(projectKey: self.store.boundKey)
            },
            // The click that opens one of the panel's editors no longer makes the panel key on its own
            // (see `KeyablePanel`), so the content asks for the keyboard when it has somewhere to put it.
            onNeedsKeyboard: { [weak self] in self?.panel?.takeKey() }
        )
    }

    private func rebuildContent() {
        hosting?.rootView = makeView()
    }

    /// Marks the focus panel, for the places that need to tell it from a project window.
    static let windowIdentifier = "PMFocusPanel"

    // MARK: NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        chrome?.cancelPendingHide()
    }

    func windowDidResignKey(_ notification: Notification) {
        // Shut the gate behind it. From here a click on the panel — ticking a task off, dragging it out
        // of the way — leaves the keyboard where it is, which is the window you were typing in.
        panel?.acceptsKey = false
        chrome?.scheduleBlurHide()
    }

    func windowDidMove(_ notification: Notification) {
        chrome?.windowDidMove()
    }
}
