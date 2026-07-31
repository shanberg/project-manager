import AppKit
import SwiftUI

/// One project window: a real Mac window with a hidden titlebar and a full-size content view. The
/// traffic lights float over the sidebar, the content runs to the top of the frame, and the title is
/// still set (invisible) so window tabs, the Window menu and ⌘` all name the project properly.
///
/// This used to have a second chrome — the app's original borderless HUD, offered as a window-style
/// setting. That chrome now belongs to the focus panel, which is the surface it was always describing,
/// so a project window is unconditionally a window.
@MainActor
final class ProjectWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    /// The project this window shows. Changing it is `retarget(to:)`, not a write.
    private(set) var projectKey: String?
    private(set) var store: PMStore

    let state = ProjectViewState()
    private let split: ProjectSplitViewController

    /// Called when the window has closed, so `WindowManager` can drop it.
    var onClose: ((ProjectWindowController) -> Void)?
    /// Asks to open a project — in this window or a new one. Supplied by `WindowManager`.
    var onOpenProject: ((String, Bool) -> Void)?

    init(projectKey: String?, store: PMStore, startsWithSidebar: Bool) {
        self.projectKey = projectKey
        self.store = store

        split = ProjectSplitViewController(store: store, state: state,
                                           startsWithSidebar: startsWithSidebar)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0,
                                width: ProjectWindow.minContentWidth + ProjectWindow.sidebarWidth,
                                height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        // Things' chrome: no toolbar, no visible title, content running under the titlebar. The title
        // is still *set* below — `titleVisibility` only hides it from the titlebar, while tabs, the
        // Window menu and ⌘` all keep reading it.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.contentMinSize = NSSize(width: ProjectWindow.minContentWidth,
                                       height: ProjectWindow.minWindowHeight)
        window.tabbingIdentifier = ProjectWindow.tabbingIdentifier
        window.tabbingMode = .automatic
        super.init(window: window)

        window.contentViewController = split
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.identifier = NSUserInterfaceItemIdentifier(ProjectWindow.windowIdentifier)

        // Wire the content's callbacks now that `self` exists.
        state.openProject = { [weak self] key, inNewWindow in
            self?.onOpenProject?(key, inNewWindow)
        }
        state.toggleSidebar = { [weak self] in self?.toggleSidebar() }

        // Per-project frame memory. `setFrameAutosaveName` has to come after the window exists and
        // before it's shown; with no project (the empty state) all such windows share one frame.
        window.setFrameAutosaveName("PMProject:\(projectKey ?? "none")")

        applyTitle()
        applyWindowSettings()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    // MARK: Presentation

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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
        window?.setFrameAutosaveName("PMProject:\(newKey ?? "none")")
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

    /// Float project windows above other apps' windows, if the user asked for it. "Show on all Spaces"
    /// is deliberately *not* here — it belongs to the focus panel, which is the surface that's meant to
    /// follow you around. A full editor window that shadows you onto every desktop is a nuisance, not a
    /// feature.
    func applyWindowSettings() {
        window?.level = WindowSettings.shared.floatAboveOthers ? .floating : .normal
    }

    // MARK: Sidebar

    /// The header's toggle, routed through the split view so it animates and persists in one place.
    func toggleSidebar() {
        split.toggleSidebar(nil)
    }

    var isSidebarVisible: Bool { !split.isSidebarCollapsed }

    // MARK: NSWindowDelegate

    func windowDidBecomeMain(_ notification: Notification) {
        pushFocusToDisk()
    }

    func windowWillClose(_ notification: Notification) {
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
            // Nothing to open if every project is already on screen.
            return WindowManager.shared.nextUnopenedProjectKey != nil
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
