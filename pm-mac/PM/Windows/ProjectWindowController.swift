import AppKit
import SwiftUI

/// One project window.
///
/// The chrome follows the window style setting. `.window` is a real Mac window with a hidden titlebar
/// and a full-size content view: the traffic lights float over the sidebar, the content runs to the top
/// of the frame, and the title is still set (invisible) so window tabs, the Window menu and ⌘` all name
/// the project properly. `.panel` is the app's original borderless HUD, with
/// `PanelChromeController` supplying the auto-fit, blur-hide and edge snapping.
@MainActor
final class ProjectWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    /// The project this window shows. Changing it is `retarget(to:)`, not a write.
    private(set) var projectKey: String?
    private(set) var store: PMStore

    let state = ProjectViewState()
    private let chromeStyle: WindowChromeStyle
    private let panelChromeState = PanelChrome()
    private var panelChrome: PanelChromeController?
    private let split: ProjectSplitViewController

    /// Called when the window has closed, so `WindowManager` can drop it.
    var onClose: ((ProjectWindowController) -> Void)?
    /// Asks to open a project — in this window or a new one. Supplied by `WindowManager`.
    var onOpenProject: ((String, Bool) -> Void)?

    init(projectKey: String?, store: PMStore, chromeStyle: WindowChromeStyle, settings: PanelSettings) {
        self.projectKey = projectKey
        self.store = store
        self.chromeStyle = chromeStyle

        split = ProjectSplitViewController(store: store, state: state,
                                           chromeStyle: chromeStyle, chrome: panelChromeState)

        let window: NSWindow
        switch chromeStyle {
        case .window:
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0,
                                    width: ProjectWindow.minContentWidth + ProjectWindow.sidebarWidth,
                                    height: 620),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false)
            // Things' chrome: no toolbar, no visible title, content running under the titlebar. The
            // title is still *set* below — `titleVisibility` only hides it from the titlebar, while
            // tabs, the Window menu and ⌘` all keep reading it.
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.contentMinSize = NSSize(width: ProjectWindow.minContentWidth,
                                           height: ProjectWindow.minWindowHeight)
            window.tabbingIdentifier = ProjectWindow.tabbingIdentifier
            window.tabbingMode = .automatic
        case .panel:
            window = KeyablePanel(
                contentRect: NSRect(x: 0, y: 0,
                                    width: ProjectWindow.minContentWidth
                                        + (ProjectWindow.isSidebarVisible ? ProjectWindow.sidebarWidth : 0),
                                    height: 420),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered, defer: false)
            // A borderless window can't be tabbed; the panel is a single-window affair by nature.
            window.tabbingMode = .disallowed
        }
        super.init(window: window)

        window.contentViewController = split
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.identifier = NSUserInterfaceItemIdentifier(ProjectWindow.windowIdentifier)

        // Wire the content's callbacks now that `self` exists.
        split.onDismiss = { [weak self] in self?.dismiss() }
        split.onContentHeight = { [weak self] height in self?.panelChrome?.fit(toContentHeight: height) }
        split.onResizeBegan = { [weak self] in self?.panelChrome?.resizeBegan() }
        split.onResizeChanged = { [weak self] delta in self?.panelChrome?.resize(byHeightDelta: delta) }
        split.onResizeEnded = { [weak self] in self?.panelChrome?.resizeEnded() }
        state.openProject = { [weak self] key, inNewWindow in
            self?.onOpenProject?(key, inNewWindow)
        }
        state.toggleSidebar = { [weak self] in self?.toggleSidebar() }

        if chromeStyle.isPanel, let panel = window as? NSPanel {
            panelChrome = PanelChromeController(panel: panel, projectKey: projectKey ?? "none",
                                                settings: settings, chrome: panelChromeState)
        } else {
            // Per-project frame memory. `setFrameAutosaveName` has to come after the window exists and
            // before it's shown; with no project (the empty state) all such windows share one frame.
            window.setFrameAutosaveName("PMProject:\(projectKey ?? "none")")
        }

        applyTitle()
        applyWindowSettings()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    // MARK: Presentation

    func show() {
        panelChrome?.prepareToShow()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Escape (panel style) or an explicit hide. A real window closes; a panel just orders out, since
    /// it's summoned rather than opened.
    func dismiss() {
        guard chromeStyle.isPanel else { return }
        panelChrome?.prepareToHide()
        window?.orderOut(nil)
    }

    var isVisible: Bool { window?.isVisible ?? false }

    // MARK: Retargeting

    /// Show a different project in this window. The store is swapped (stores are shared per project),
    /// the title and frame memory follow, and the new project becomes the global focus since this
    /// window is the one in front.
    func retarget(to newStore: PMStore, projectKey newKey: String?) {
        guard newKey != projectKey else { return }
        projectKey = newKey
        store = newStore
        split.retarget(to: newStore)
        if !chromeStyle.isPanel {
            window?.setFrameAutosaveName("PMProject:\(newKey ?? "none")")
        }
        applyTitle()
        pushFocusToDisk()
    }

    /// The window's title — invisible in the titlebar, but what the Window menu, ⌘`, and the tab bar
    /// all show. The subtitle carries progress, which is where the header's "3/8" goes in a window.
    func applyTitle() {
        guard let window else { return }
        let title = store.notes?.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = (title?.isEmpty ?? true) ? store.projectName : title
        window.title = name ?? "PM"
        let p = store.progress
        window.subtitle = p.total > 0 ? "\(p.done) of \(p.total) done" : ""
    }

    // MARK: Settings

    func applyPanelSettings(_ settings: PanelSettings) {
        panelChrome?.applySettings(settings)
    }

    /// Apply the window-behavior settings that aren't chrome-specific. "Show on all Spaces" is
    /// `canJoinAllSpaces`: macOS has no way to put one window on every *display* — a window lives on
    /// one screen — but joining all Spaces is what makes it follow you everywhere, which is what the
    /// setting is for.
    func applyWindowSettings() {
        guard let window else { return }
        var behavior = window.collectionBehavior
        if WindowSettings.shared.showOnAllSpaces {
            behavior.insert(.canJoinAllSpaces)
            behavior.remove(.moveToActiveSpace)
        } else {
            behavior.remove(.canJoinAllSpaces)
        }
        window.collectionBehavior = behavior
        if !chromeStyle.isPanel {
            window.level = WindowSettings.shared.floatAboveOthers ? .floating : .normal
        }
    }

    // MARK: Sidebar

    /// The header's toggle. Goes through the split view (so it animates and persists in one place),
    /// then brings the other windows into line — the preference is app-wide.
    func toggleSidebar() {
        split.toggleSidebar(nil)
        WindowManager.shared.applySidebarPreference()
    }
    func applySidebarPreference() { split.applySidebarPreference() }

    // MARK: NSWindowDelegate

    func windowDidBecomeMain(_ notification: Notification) {
        pushFocusToDisk()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        panelChrome?.cancelPendingHide()
    }

    func windowDidResignKey(_ notification: Notification) {
        panelChrome?.scheduleBlurHide()
    }

    func windowDidMove(_ notification: Notification) {
        panelChrome?.windowDidMove()
    }

    func windowWillClose(_ notification: Notification) {
        panelChrome?.savePosition()
        split.prepareForClose()
        onClose?(self)
    }

    /// ⌘T and the tab bar's `+`. A tab on the project this window already shows would be a duplicate,
    /// so New Tab means "another project alongside this one": the most recent one that isn't open yet,
    /// added to this window's tab group.
    @objc override func newWindowForTab(_ sender: Any?) {
        guard let key = WindowManager.shared.nextUnopenedProjectKey else { return }
        WindowManager.shared.open(projectKey: key, asTabOf: self)
    }

    // MARK: Menu commands answered by this window

    /// File ▸ New Task. The content opens its inline add editor; the window can't do it directly, so it
    /// nudges the shared state and the view responds.
    @objc func newTask(_ sender: Any?) {
        state.requestNewTask()
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(newTask(_:)):
            return store.projectName != nil
        case #selector(newWindowForTab(_:)):
            // Borderless panels can't be tabbed, and there's nothing to open if every project is
            // already on screen.
            return !chromeStyle.isPanel && WindowManager.shared.nextUnopenedProjectKey != nil
        default:
            return true
        }
    }

    /// The frontmost window owns the global focus, so the CLI, Raycast and the menubar all follow
    /// whichever project you're looking at.
    private func pushFocusToDisk() {
        guard let projectKey, projectKey != PMFiles.focusedProjectKey() else { return }
        PMStore.setGlobalFocus(key: projectKey) {
            // The watcher will see the write too, but that's debounced by up to a second; nudging the
            // menubar here makes the switch feel immediate.
            (NSApp.delegate as? AppDelegate)?.syncFocusedStore()
        }
    }
}
