import AppKit
import Combine
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
}
