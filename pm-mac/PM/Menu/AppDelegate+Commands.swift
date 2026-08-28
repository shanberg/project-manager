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

    /// Help ▸ PM Help. The documentation lives in the repository and is maintained there; a bundled
    /// help book would be a second copy to keep true.
    @objc func openHelp() {
        guard let url = URL(string: "https://github.com/shanberg/project-manager#readme") else { return }
        NSWorkspace.shared.open(url)
    }

    /// Help ▸ Keyboard Shortcuts. Every global shortcut here is rebindable and most ship unbound, so
    /// the honest answer to "what are the keys" is the pane that holds them rather than a printed list.
    @objc func openShortcutsSettings() {
        SettingsWindowController.shared.show(selecting: .shortcuts)
    }

    @objc func newWindow() {
        WindowManager.shared.open(projectKey: PMFiles.focusedProjectKey())
    }

    @objc func closeAllWindows() {
        for controller in WindowManager.shared.controllers { controller.close() }
    }

    /// Browse every project: bring up a window and open its project list with the keyboard in it. The
    /// sidebar is already the full, filterable list of both folders — this is the command that goes
    /// straight there instead of making you reveal it first.
    @objc func browseAllProjects() {
        WindowManager.shared.openFocusedProject().revealProjectList()
    }

    /// Ask for a domain and a title, create the project, and open it. Runs without a window — it's on
    /// the menu bar item's menu too, and PM keeps running with everything closed.
    @objc func newProject() {
        ProjectPrompts.newProject { key in WindowManager.shared.open(projectKey: key) }
    }

    /// The same, for the other kind of thing PM tracks.
    @objc func newArea() {
        ProjectPrompts.newArea { key in WindowManager.shared.open(projectKey: key) }
    }

    /// For the areas you already had before PM knew the word.
    @objc func adoptArea() {
        ProjectPrompts.adoptArea { key in WindowManager.shared.open(projectKey: key) }
    }

    /// Show (or put away) the cross-project Waiting list.
    @objc func toggleWaiting() { WaitingWindowController.shared.toggle() }

    @objc func quickCapture() { QuickBarController.shared.toggle(mode: .capture) }

    @objc func quickNote() { QuickBarController.shared.toggle(mode: .note) }

    @objc func quickGoToProject() { QuickBarController.shared.toggle(mode: .goToProject) }

    @objc func quickFindTask() { QuickBarController.shared.toggle(mode: .findTask) }

    // MARK: View

    @objc func setTasksMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        UserDefaults.standard.set(raw, forKey: "PMPanelTasksMode")
    }

    @objc func toggleNotes() {
        let key = "PMPanelDetailsExpanded"
        UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: key), forKey: key)
    }

    /// Show or hide the focus panel — the same toggle as ⌃⌥P and `pmpanel://toggle`, so the menu item
    /// and the global shortcut can't drift apart.
    @objc func toggleFocusPanel() {
        FocusPanelController.shared.toggle()
    }

    @objc func setColorMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        UserDefaults.standard.set(raw, forKey: "PMPanelColorMode")
    }

    /// Whether project names are written with their `CODE-NNN` prefix — app-wide, so it's here in View
    /// rather than in the sidebar's own arrange menu, where it used to be. Settings ▸ Projects has the
    /// same switch with the sentence explaining it.
    @objc func toggleProjectCodes() { ProjectCodes.areShown.toggle() }

    // MARK: Task and Project

    /// Every item in the Task and Project menus, run through the one shared dispatcher. The command
    /// rides on `representedObject` as its raw value — see `MainMenu.domainMenuItem`.
    @objc func runCommand(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let command = PMCommand(rawValue: raw) else { return }
        PMCommandRunner.run(command, store: store)
    }

    /// The global shortcuts still bind to named methods rather than to `runCommand`, because a hotkey
    /// has no menu item to carry a `representedObject` on. They go through the same runner, so a
    /// command can't behave one way from the menu and another from the keyboard.
    @objc func completeFocused() { PMCommandRunner.run(.complete, store: store) }

    @objc func undoLastCompletion() { PMCommandRunner.run(.undoLast, store: store) }

    @objc func diveInCommand() { PMCommandRunner.run(.diveIn, store: store) }

    @objc func revealProject() { PMCommandRunner.run(.openInFinder, store: store) }

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
            let current = UserDefaults.standard.string(forKey: "PMPanelColorMode") ?? AppColorMode.system.rawValue
            item.state = (item.representedObject as? String) == current ? .on : .off
            return true
        case #selector(toggleFocusPanel):
            // A checkmark rather than a Show/Hide title swap: the focus panel can be dismissed by clicking
            // away from it, and a title that only updates when the menu opens would read as stale.
            item.state = FocusPanelController.shared.isVisible ? .on : .off
            return true
        case #selector(toggleNotes):
            item.state = UserDefaults.standard.bool(forKey: "PMPanelDetailsExpanded") ? .on : .off
            return store.projectName != nil
        case #selector(toggleProjectCodes):
            item.state = ProjectCodes.areShown ? .on : .off
            return true
        // Every Task and Project item, answered from the one availability table.
        case #selector(runCommand(_:)):
            guard let raw = item.representedObject as? String,
                  let command = PMCommand(rawValue: raw) else { return false }
            return command.isAvailable(in: PMCommand.Context(store: store))
        case #selector(completeFocused):
            return PMCommand.complete.isAvailable(in: PMCommand.Context(store: store))
        case #selector(undoLastCompletion):
            return PMCommand.undoLast.isAvailable(in: PMCommand.Context(store: store))
        case #selector(diveInCommand):
            return PMCommand.diveIn.isAvailable(in: PMCommand.Context(store: store))
        case #selector(revealProject):
            return PMCommand.openInFinder.isAvailable(in: PMCommand.Context(store: store))
        case #selector(closeAllWindows):
            return !WindowManager.shared.controllers.isEmpty
        default:
            return true
        }
    }
}

/// The Task and Project menus, refreshed as they open.
///
/// Only the titles: availability is `validateMenuItem`'s job and AppKit runs that for every item on
/// its own. What needs a delegate is the one command whose *name* depends on the machine — Open in
/// Editor reads whichever app Settings ▸ Projects names, and a menu that said "Open in Editor" would
/// be making you press it to find out which.
///
/// The context is built once here rather than per item, because two of its facts touch the filesystem.
extension AppDelegate: NSMenuDelegate {
    public func menuNeedsUpdate(_ menu: NSMenu) {
        let context = PMCommand.Context(store: store)
        for item in menu.items {
            guard let raw = item.representedObject as? String,
                  let command = PMCommand(rawValue: raw) else { continue }
            item.title = command.title(in: context)
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
