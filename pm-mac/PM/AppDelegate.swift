import AppKit
import Combine
import CoreSpotlight
import PmLib

/// Wires the menubar item, the panel, the global hotkey, the URL scheme, and the config-dir watcher
/// around a single `PMStore`. The app is a resident menubar-only agent (`.accessory` policy).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = PMStore()
    private var settings = PanelSettings.load()

    private var statusController: StatusItemController!
    private var panelController: PanelController!
    private var hotKey: HotKey?
    private var watcher: ConfigWatcher!
    private var notifier: NotificationManager!
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.write("=== PM launched (build \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "?")) configDir=\(PMFiles.configDir.path) ===")
        NSApp.setActivationPolicy(.accessory)
        installMainMenu()

        panelController = PanelController(store: store, settings: settings)
        statusController = StatusItemController(store: store)
        wireStatusController()

        // Local notifications for stale focused tasks and due dates (asks permission on first launch).
        notifier = NotificationManager(store: store)
        notifier.requestAuthorization()

        // Keep the menubar glyph and the notes-file watch in sync with store state.
        store.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                DispatchQueue.main.async { self?.storeDidChange() }
            }
            .store(in: &cancellables)

        // Global summon shortcut (Ctrl+Alt+P), matching the retired Tauri panel.
        hotKey = HotKey { [weak self] in self?.panelController.toggle() }

        // Watch the config dir (+ focused notes file) for CLI/Raycast/Obsidian edits.
        watcher = ConfigWatcher { [weak self] in self?.handleExternalChange() }
        watcher.start()

        // Be active for the first protected-folder access so a TCC prompt (if any) can present.
        NSApp.activate(ignoringOtherApps: true)
        store.reload()

        // Reopen the panel if it was open when the app was last quit.
        panelController.restoreIfNeeded()

        // Index projects and open tasks for Spotlight / Siri semantic search (macOS 15+; no-op below).
        PMSpotlight.reindex()

        // Ask the system to (re)ingest our App Shortcuts. Without this, an in-place app update can
        // leave Siri/Spotlight serving stale or missing shortcuts ("PM doesn't support that").
        PMShortcuts.updateAppShortcutParameters()
    }

    /// Shown at most once per launch if the projects folder can't be read (a Full Disk Access issue).
    private var shownAccessHelp = false

    private func maybeShowAccessHelp() {
        guard !shownAccessHelp, let msg = store.errorMessage else { return }
        let lower = msg.lowercased()
        guard lower.contains("couldn't be opened") || lower.contains("cannot list directory")
                || lower.contains("permission") else { return }
        shownAccessHelp = true
        Log.write("access help shown for: \(msg)")
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "PM needs Full Disk Access"
        alert.informativeText = """
            PM couldn't read your projects folder:

            \(msg)

            Grant Full Disk Access to /Applications/PM.app in System Settings, then quit and reopen PM.
            """
        alert.addButton(withTitle: "Open Full Disk Access…")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Install a minimal main menu carrying the standard Edit items. An `.accessory` / `LSUIElement`
    /// app never displays the system menu bar, so without this there is no Edit menu — and the standard
    /// text-editing shortcuts (⌘A Select All, ⌘C/⌘X/⌘V, ⌘Z/⇧⌘Z) are delivered *as key equivalents from
    /// that menu*, so they simply do nothing in the panel's inline text fields. `NSApplication` still
    /// dispatches a main menu's key equivalents down the responder chain even when the bar is hidden,
    /// so installing the menu restores those shortcuts. Items use first-responder selectors so they
    /// route to whichever field editor is focused, enabling/disabling themselves automatically.
    private func installMainMenu() {
        let mainMenu = NSMenu()

        // A menu bar needs a (conventionally hidden) app menu as its first item to behave correctly.
        let appItem = NSMenuItem()
        appItem.submenu = NSMenu()
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        NSApp.mainMenu = mainMenu
    }

    private func wireStatusController() {
        statusController.settings = { [weak self] in self?.settings ?? .default }
        statusController.onShowPanel = { [weak self] in self?.panelController.show() }
        statusController.onTogglePanel = { [weak self] in self?.panelController.toggle() }
        statusController.onSetPinned = { [weak self] on in self?.updateSettings { $0.pinned = on } }
        statusController.onSetFloating = { [weak self] on in self?.updateSettings { $0.floating = on } }
    }

    // MARK: Settings

    private func updateSettings(_ mutate: (inout PanelSettings) -> Void) {
        var s = settings
        mutate(&s)
        guard s != settings else { return }
        settings = s
        s.save()
        panelController.applySettings(s)
    }

    /// External change (watcher fired): reload data and re-apply panel settings that Raycast may have
    /// written to panel-settings.json.
    private func handleExternalChange() {
        let disk = PanelSettings.load()
        if disk != settings {
            settings = disk
            panelController.applySettings(disk)
        }
        store.reload()
    }

    private var watchedNotesPath: String?

    private func storeDidChange() {
        statusController.storeChanged()
        // After storeChanged() (which refreshes the focused task's seen-at), reschedule notifications.
        notifier.sync()
        maybeShowAccessHelp()
        // Re-point the notes-file watch only when the focused project's notes path actually changes,
        // using the path the store already resolved (no extra protected-directory scan here).
        if store.notesPath != watchedNotesPath {
            watchedNotesPath = store.notesPath
            watcher.watchNotes(at: store.notesPath)
        }
    }

    // MARK: URL scheme — pmpanel://toggle | show | hide | pin?on=… | float?on=…

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "pmpanel" {
            handle(url: url)
        }
    }

    private func handle(url: URL) {
        let host = url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        switch host {
        case "toggle": panelController.toggle()
        case "show": panelController.show()
        case "hide": panelController.hide()
        case "pin": updateSettings { $0.pinned = boolParam(url) ?? !$0.pinned }
        case "float": updateSettings { $0.floating = boolParam(url) ?? !$0.floating }
        default: break
        }
    }

    /// Read `?on=true|false|1|0` from a control URL; nil means "toggle".
    private func boolParam(_ url: URL) -> Bool? {
        guard let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "on" })?.value?.lowercased() else { return nil }
        return value == "true" || value == "1" || value == "yes" || value == "on"
    }

    // MARK: Spotlight — tapping an indexed project/task focuses it and shows the panel.

    func application(_ application: NSApplication, continue userActivity: NSUserActivity,
                     restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void) -> Bool {
        guard userActivity.activityType == CSSearchableItemActionType,
              let id = userActivity.userInfo?[CSSearchableItemActivityIdentifier] as? String else { return false }
        focusFromSpotlight(identifier: id)
        return true
    }

    /// A Spotlight identifier is either a task entity id (`session:line␟projectKey`) or a bare project
    /// key. Focus whichever it names, then surface the panel.
    private func focusFromSpotlight(identifier id: String) {
        if let task = TaskEntity.decode(id: id), let folder = PMFiles.projectName(fromKey: task.projectKey) {
            try? PMFiles.setFocusedProjectKey(task.projectKey)
            try? focusTodo(project: folder, sessionIndex: task.sessionIndex, lineIndex: task.lineIndex)
            PMFiles.recordRecent(projectKey: task.projectKey, name: folder)
        } else if let folder = PMFiles.projectName(fromKey: id) {
            try? PMFiles.setFocusedProjectKey(id)
            PMFiles.recordRecent(projectKey: id, name: folder)
        } else {
            return
        }
        store.reload()
        panelController.show()
        NSApp.activate(ignoringOtherApps: true)
    }
}
