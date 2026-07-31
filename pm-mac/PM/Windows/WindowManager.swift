import AppKit

/// Owns the app's project windows: opening, focusing, retargeting, closing, and remembering which
/// projects were open across launches.
///
/// The unit is a project, not a window: asking to open a project that already has a window brings that
/// window forward rather than opening a second one on the same thing.
@MainActor
final class WindowManager {
    static let shared = WindowManager()

    private(set) var controllers: [ProjectWindowController] = []

    /// Panel settings, kept here so a newly-opened window starts with the current values.
    var panelSettings: PanelSettings = .default

    // MARK: Opening

    /// Bring up a window for `projectKey`, or focus the one already showing it.
    ///
    /// Pass `asTabOf` to have the new window join that window's tab group rather than stand alone —
    /// AppKit only tabs windows you explicitly add, even when they share a tabbing identifier.
    @discardableResult
    func open(projectKey: String?, asTabOf sibling: ProjectWindowController? = nil) -> ProjectWindowController {
        if let existing = controllers.first(where: { $0.projectKey == projectKey }) {
            existing.show()
            return existing
        }
        let controller = makeController(projectKey: projectKey)
        controllers.append(controller)
        Log.write("window opened: \(projectKey ?? "no project") (\(controllers.count) open)")
        rememberOpenProjects()
        if let host = sibling?.window, let new = controller.window {
            host.addTabbedWindow(new, ordered: .above)
            new.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            controller.show()
        }
        return controller
    }

    /// The project ⌘T should open: the most recently edited one that doesn't already have a window.
    /// A tab on the project you're already in would just be a duplicate, so "New Tab" means "another
    /// project alongside this one".
    var nextUnopenedProjectKey: String? {
        let open = Set(controllers.compactMap(\.projectKey))
        return ProjectIndex.shared.recents.first { !open.contains($0.projectKey) }?.projectKey
    }

    /// Show `projectKey` in `controller` — the sidebar's plain double-click / Return. If another window
    /// already has that project, that window comes forward instead: two windows on one project would
    /// show the same store twice with nothing to tell them apart.
    func retarget(_ controller: ProjectWindowController, to projectKey: String) {
        if let existing = controllers.first(where: { $0.projectKey == projectKey }), existing !== controller {
            existing.show()
            return
        }
        let previous = controller.projectKey
        let store = StoreRegistry.shared.acquire(projectKey)
        controller.retarget(to: store, projectKey: projectKey)
        StoreRegistry.shared.release(previous)
        rememberOpenProjects()
    }

    /// The window a command should act on: the main one, else the key one, else the first open.
    var frontmost: ProjectWindowController? {
        if let main = NSApp.mainWindow?.windowController as? ProjectWindowController { return main }
        if let key = NSApp.keyWindow?.windowController as? ProjectWindowController { return key }
        return controllers.first
    }

    /// Open (or focus) a window for whatever project is currently focused — the menubar's "Open
    /// Window", the ⌃⌥P hotkey, the Dock icon, and the Spotlight/Siri hand-offs all land here.
    @discardableResult
    func openFocusedProject() -> ProjectWindowController {
        open(projectKey: PMFiles.focusedProjectKey())
    }

    /// The hotkey's toggle. Summon a window if PM isn't already in front; if it is, get out of the way
    /// — which for a panel means hiding it (it's summoned, not opened) and for a real window means
    /// hiding the app. Never *closing* it: ⌃⌥P is a "show me / not now" toggle, and losing a window
    /// (and its size, its position, its place in the reopen list) to a glance would be a poor trade.
    func toggleFocusedProject() {
        guard let front = frontmost, front.isVisible, NSApp.isActive else {
            openFocusedProject()
            return
        }
        front.dismiss()
        if front.isVisible { NSApp.hide(nil) }
    }

    // MARK: Lifecycle

    private func makeController(projectKey: String?) -> ProjectWindowController {
        let store = StoreRegistry.shared.acquire(projectKey)
        // Only a session's first window opens with the sidebar; the rest are opened to see another
        // project beside it, not to carry a second copy of the project list.
        let controller = ProjectWindowController(projectKey: projectKey,
                                                 store: store,
                                                 chromeStyle: WindowSettings.shared.chromeStyle,
                                                 settings: panelSettings,
                                                 startsWithSidebar: controllers.isEmpty
                                                    && ProjectWindow.isSidebarVisible)
        controller.onClose = { [weak self] closed in self?.windowClosed(closed) }
        controller.onOpenProject = { [weak self, weak controller] key, inNewWindow in
            guard let self else { return }
            if inNewWindow || controller == nil {
                self.open(projectKey: key)
            } else if let controller {
                self.retarget(controller, to: key)
            }
        }
        return controller
    }

    private func windowClosed(_ controller: ProjectWindowController) {
        controllers.removeAll { $0 === controller }
        Log.write("window closed: \(controller.projectKey ?? "no project") (\(controllers.count) open)")
        StoreRegistry.shared.release(controller.projectKey)
        rememberOpenProjects()
    }

    /// Reopen what was open last time. A regular app that launches with no window at all reads as
    /// broken, so anything that leaves us with nothing — restore turned off, a first run, a stale list
    /// — falls back to one window on the focused project.
    func restoreOnLaunch() {
        if WindowSettings.shared.restoreWindows {
            // Skip keys that no longer name a project — a renamed or deleted folder, or a bad key that
            // got saved — rather than reopening a window that can only show the empty state. Dropping
            // them here also cleans them out of the saved list on the next write.
            for key in WindowSettings.shared.openProjectKeys where PMFiles.projectName(fromKey: key) != nil {
                open(projectKey: key)
            }
        }
        guard !controllers.isEmpty else {
            openFocusedProject()
            Log.write("launch: opened a window on the focused project")
            return
        }
        Log.write("launch: restored \(controllers.count) window(s)")
        // Leave the focused project's window in front, so launching lands where the menubar points.
        if let focused = PMFiles.focusedProjectKey(),
           let controller = controllers.first(where: { $0.projectKey == focused }) {
            controller.show()
        }
    }

    private func rememberOpenProjects() {
        WindowSettings.shared.openProjectKeys = controllers.compactMap(\.projectKey)
    }

    // MARK: Broadcasts

    /// Re-apply the panel settings (Raycast can change them behind our back) to every open window.
    func applyPanelSettings(_ settings: PanelSettings) {
        panelSettings = settings
        for controller in controllers { controller.applyPanelSettings(settings) }
    }

    /// Re-apply the window-behavior settings — all-Spaces, floating — to every open window, so a
    /// Settings change takes effect without reopening anything.
    func applyWindowSettings() {
        for controller in controllers { controller.applyWindowSettings() }
    }

    /// Refresh window titles/subtitles after a store change (the project's name or progress moved).
    func refreshTitles() {
        for controller in controllers { controller.applyTitle() }
    }
}
