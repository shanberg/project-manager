import AppKit

/// The menu bar's app-level actions. Window-shaped commands (New Task, Show Projects, Close) are
/// answered further down the responder chain by `ProjectWindowController` and the split view
/// controller; what's left here is either app-wide (Settings, New Window) or acts on the focused
/// project's store, which is the delegate's to hold.
extension AppDelegate: NSMenuItemValidation {
    // MARK: App

    @objc func openSettings() {
        SettingsWindowController.shared.show()
    }

    @objc func newWindow() {
        WindowManager.shared.open(projectKey: PMFiles.focusedProjectKey())
    }

    @objc func closeAllWindows() {
        for controller in WindowManager.shared.controllers { controller.close() }
    }

    /// Everything beyond the recents lives in Raycast's searchable list, which is where project
    /// browsing already lives for the menubar item too.
    @objc func browseAllProjects() {
        guard let url = URL(string: "raycast://extensions/shanberg/project-manager/list-projects") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: View

    @objc func setTasksMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        UserDefaults.standard.set(raw, forKey: "PMPanelTasksMode")
    }

    @objc func toggleNotes() {
        let key = "PMPanelDetailsExpanded"
        UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: key), forKey: key)
    }

    @objc func setColorMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        UserDefaults.standard.set(raw, forKey: "PMPanelColorMode")
    }

    // MARK: Task

    @objc func completeFocused() {
        guard let focused = store.focusedTodo else { return }
        store.complete(focused)
    }

    @objc func undoLastCompletion() {
        store.undoLast()
    }

    @objc func diveInCommand() {
        store.diveIn()
    }

    @objc func revealProject() {
        guard let path = store.projectPath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    // MARK: Validation

    /// Enable/disable and check the delegate's own items. Items answered elsewhere in the responder
    /// chain validate themselves there.
    public func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(setTasksMode(_:)):
            let current = UserDefaults.standard.string(forKey: "PMPanelTasksMode") ?? TasksMode.incomplete.rawValue
            item.state = (item.representedObject as? String) == current ? .on : .off
            return store.projectName != nil
        case #selector(setColorMode(_:)):
            let current = UserDefaults.standard.string(forKey: "PMPanelColorMode") ?? PanelColorMode.system.rawValue
            item.state = (item.representedObject as? String) == current ? .on : .off
            return true
        case #selector(toggleNotes):
            item.state = UserDefaults.standard.bool(forKey: "PMPanelDetailsExpanded") ? .on : .off
            return store.projectName != nil
        case #selector(completeFocused):
            return store.focusedTodo != nil
        case #selector(undoLastCompletion):
            return store.lastCompletedKey != nil
        case #selector(diveInCommand):
            return store.nextTodo != nil
        case #selector(revealProject):
            return store.projectPath != nil
        case #selector(closeAllWindows):
            return !WindowManager.shared.controllers.isEmpty
        default:
            return true
        }
    }
}

/// Fills File ▸ Open Recent with the recency-ordered projects, rebuilt each time the menu opens so it
/// never goes stale. Opening one focuses it in the front window, matching a double-click in the sidebar.
@MainActor
final class RecentProjectsMenuDelegate: NSObject, NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let recents = ProjectIndex.shared.recents
        guard !recents.isEmpty else {
            let empty = menu.addItem(withTitle: "No Recent Projects", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            return
        }
        for recent in recents {
            let item = menu.addItem(withTitle: recent.name, action: #selector(open(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = recent.projectKey
        }
    }

    @objc private func open(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        if let front = WindowManager.shared.frontmost {
            WindowManager.shared.retarget(front, to: key)
        } else {
            WindowManager.shared.open(projectKey: key)
        }
    }
}
