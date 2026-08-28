import AppKit
import Combine
import CoreSpotlight
import PmLib

/// Wires the menubar item, the project windows, the global hotkey, the URL scheme, and the config-dir
/// watcher together. PM is a regular app — Dock icon, menu bar, windows — that also keeps a menubar
/// item, so closing every window leaves it running rather than quitting.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The store for whatever project `focused.json` names — what the menubar item, notifications and
    /// Spotlight all follow. Acquired from `StoreRegistry`, so when a window is showing that same
    /// project this *is* that window's store.
    private(set) var store: PMStore = StoreRegistry.shared.emptyStore
    private var storeKey: String?
    private var hasSyncedStore = false
    /// The `store.objectWillChange` subscription, torn down and remade when the store is re-pointed.
    private var storeSubscription: AnyCancellable?

    private var settings = PanelSettings.load()

    private var statusController: StatusItemController!
    private var watcher: ConfigWatcher!
    private var notifier: NotificationManager!
    private var cancellables: Set<AnyCancellable> = []
    private let windows = WindowManager.shared
    /// Fills File ▸ Open Recent on demand; held here so it outlives the menu it serves.
    let recentProjectsMenuDelegate = RecentProjectsMenuDelegate()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.write("=== PM launched (build \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "?")) configDir=\(PMFiles.configDir.path) ===")
        NSApp.setActivationPolicy(.regular)
        // Before the menu is built or a name is written anywhere: a preference that moved keys has to
        // finish moving before anything reads the new one.
        ProjectCodes.migrateLegacyKey()
        MainMenu.install(target: self)

        // Point the menubar at the focused project before anything reads `store`.
        syncFocusedStore()

        FocusPanelController.shared.applyPanelSettings(settings)
        FocusPanelController.shared.syncToFocusedProject()
        statusController = StatusItemController(store: store)
        wireStatusController()

        // Local notifications for stale focused tasks and due dates (asks permission on first launch).
        notifier = NotificationManager(store: store)
        notifier.requestAuthorization()

        // Unconditionally, before anything asks: the folder scan the waits resolve against otherwise
        // only warms as a side effect of a project loading successfully, so a launch with no focused
        // project — or one whose folder has gone — left every `waiting:` token on every row
        // unresolved, and the watcher below with nothing to watch.
        ProjectIndex.shared.warmWaitRoots()

        // The unblock moment. Watches the archive's membership — which the folder scan already
        // reports — and speaks when something a task was waiting on lands there. See `WaitingWatcher`.
        WaitingWatcher.shared.announce = { [weak self] title, count in
            self?.notifier.announceUnblock(target: title, count: count)
        }
        WaitingWatcher.shared.start()

        // Global shortcuts. Only the panel's (⌃⌥P) is bound out of the box — it used to summon the
        // project window, which made it decide between hiding a window and hiding the whole app; a
        // HUD's toggle is just show/hide, and opening a project window is now the Dock icon and ⌥⌘N.
        // The rest are here so they *can* be bound in Settings ▸ Shortcuts, and stay empty until they
        // are. Handlers are the same methods the menu bar targets, so a command can't behave one way
        // from the menu and another from a shortcut.
        HotKeyManager.shared.start(handlers: [
            .quickCapture: { QuickBarController.shared.toggle(mode: .capture) },
            .quickFindTask: { QuickBarController.shared.toggle(mode: .findTask) },
            .quickGoToProject: { QuickBarController.shared.toggle(mode: .goToProject) },
            .quickNote: { QuickBarController.shared.toggle(mode: .note) },
            .writeSessionNoteFullScreen: { SessionNoteController.shared.toggle() },
            .toggleFocusPanel: { FocusPanelController.shared.toggle() },
            .openProjectWindow: { [weak self] in self?.newWindow() },
            .newProject: { [weak self] in self?.newProject() },
            .completeFocusedTask: { [weak self] in self?.completeFocused() },
            .undoLastCompletion: { [weak self] in self?.undoLastCompletion() },
            .diveIn: { [weak self] in self?.diveInCommand() },
            .revealProjectInFinder: { [weak self] in self?.revealProject() },
        ])

        // Watch the config dir (+ every open project's notes file) for CLI/Raycast/Obsidian edits.
        watcher = ConfigWatcher { [weak self] in self?.handleExternalChange() }
        watcher.start()
        // And the PARA roots themselves, so a project archived outside PM is noticed rather than
        // waiting for some unrelated reload to stumble on it. The folder scan already publishes where
        // they are, so this follows it rather than resolving the config a second time.
        ProjectIndex.shared.$waitRoots
            .map { $0.map(\.base) }
            .removeDuplicates()
            .sink { [weak self] bases in
                Task { @MainActor in self?.watcher?.watchRoots(paths: bases) }
            }
            .store(in: &cancellables)

        // Be active for the first protected-folder access so a TCC prompt (if any) can present.
        NSApp.activate(ignoringOtherApps: true)
        reloadAllStores()

        // Reopen the projects that were open when the app was last quit.
        windows.restoreOnLaunch()

        // Index projects and open tasks for Spotlight / Siri semantic search (macOS 15+; no-op below).
        PMSpotlight.reindex()

        // Ask the system to (re)ingest our App Shortcuts. Without this, an in-place app update can
        // leave Siri/Spotlight serving stale or missing shortcuts ("PM doesn't support that").
        PMShortcuts.updateAppShortcutParameters()
    }

    /// Shown at most once per launch if the projects folder can't be read (a Full Disk Access issue).
    private var shownAccessHelp = false

    /// Whether a store error is the projects folder being unreadable, which has its own alert and its
    /// own fix. Anything else is a one-off failure to read or write a file.
    private static func isAccessError(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("couldn't be opened") || lower.contains("cannot list directory")
            || lower.contains("permission")
    }

    /// The last failure announced, so one that persists across republishes is said once.
    private var lastReportedError: String?
    /// The last refused write announced, tracked by token rather than by text: the same refusal twice
    /// is two refusals, and saying it once would be describing only the first.
    private var lastReportedFailure: Int?

    /// Tell the user about a write that didn't land.
    ///
    /// Every surface that edits from outside a window — the quick bar, the menubar item, a
    /// notification's Complete button — deliberately leaves PM in the background, and neither the
    /// refusal banner nor `errorMessage` is rendered anywhere they can be seen from there. So a failed
    /// write from any of them was silent: you typed a task, the bar closed, and the task simply wasn't
    /// there. A notification rather than an alert, because an alert would seize the keyboard back from
    /// whatever you returned to.
    ///
    /// Only while PM is in the background, for exactly that reason. In the foreground the window and
    /// the panel say it themselves, and a banner plus a notification is one refusal reported twice.
    private func reportStoreFailure() {
        if let failure = store.writeFailure, failure.token != lastReportedFailure {
            lastReportedFailure = failure.token
            Log.write("write refused: \(failure.message)")
            if !NSApp.isActive { notifier?.reportFailure(failure.message) }
        }
        let message = store.errorMessage
        defer { lastReportedError = message }
        guard let message, message != lastReportedError,
              !Self.isAccessError(message) else { return }
        Log.write("store failure surfaced: \(message)")
        notifier?.reportFailure(message)
    }

    private func maybeShowAccessHelp() {
        guard !shownAccessHelp, let msg = store.errorMessage else { return }
        guard Self.isAccessError(msg) else { return }
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
        statusController.onShowPanel = { [weak self] in self?.windows.openFocusedProject() }
        statusController.onTogglePanel = { FocusPanelController.shared.toggle() }
        statusController.onSetPinned = { [weak self] on in self?.updateSettings { $0.pinned = on } }
        statusController.onSetFloating = { [weak self] on in self?.updateSettings { $0.floating = on } }
        statusController.onOpenSettings = { SettingsWindowController.shared.show() }
    }

    // MARK: Settings

    private func updateSettings(_ mutate: (inout PanelSettings) -> Void) {
        var s = settings
        mutate(&s)
        guard s != settings else { return }
        settings = s
        s.save()
        FocusPanelController.shared.applyPanelSettings(s)
    }

    // MARK: The focused project's store

    /// Point the menubar (and notifications, and Spotlight follow-ups) at the store for whatever project
    /// `focused.json` currently names. Called on launch, whenever the watcher sees the file change, and
    /// whenever a window becomes main and moves the focus itself.
    ///
    /// The store is acquired from `StoreRegistry`, so if a window already has that project open this
    /// hands back *its* store rather than a second copy — which is what keeps the menubar's undo and
    /// last-completed task in step with what you just did in the window.
    func syncFocusedStore() {
        let key = PMFiles.focusedProjectKey()
        // `hasSyncedStore` distinguishes the first call from a no-op one: on launch with no focused
        // project both `key` and `storeKey` are nil, and the wiring below still has to run once.
        guard key != storeKey || !hasSyncedStore else { return }
        hasSyncedStore = true
        let previous = storeKey
        storeKey = key
        store = StoreRegistry.shared.acquire(key)
        StoreRegistry.shared.release(previous)

        statusController?.store = store
        notifier?.store = store
        // The focus panel reads the focused project too — same store, so the two can't disagree about
        // what's current or diverge on undo history.
        FocusPanelController.shared.syncToFocusedProject()

        // Re-subscribe: the menubar glyph and the notes watch follow whichever store is current.
        storeSubscription = store.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                DispatchQueue.main.async { self?.storeDidChange() }
            }
        storeDidChange()
    }

    /// Reload every live store — the focused one plus any a window is holding.
    private func reloadAllStores() {
        syncFocusedStore()
        for store in StoreRegistry.shared.liveStores { store.reload() }
    }

    /// External change (watcher fired): reload data and re-apply panel settings that Raycast may have
    /// written to panel-settings.json.
    private func handleExternalChange() {
        let disk = PanelSettings.load()
        if disk != settings {
            settings = disk
            FocusPanelController.shared.applyPanelSettings(disk)
        }
        // Force rather than let the TTL decide: an external change is exactly the case where the
        // folder membership may have moved, and the wait roots are what tells a wait it's been
        // released. Three directory listings per debounced external edit is the cost this scan was
        // designed to be affordable at.
        ProjectIndex.shared.warmWaitRoots(force: true)
        reloadAllStores()
    }

    private var watchedNotesPaths: [String] = []

    private func storeDidChange() {
        statusController?.storeChanged()
        // After storeChanged() (which refreshes the focused task's seen-at), reschedule notifications.
        notifier?.sync()
        maybeShowAccessHelp()
        reportStoreFailure()
        // The quick bar names the focused task on its rows; if it's open, that name has just gone stale.
        QuickBarController.shared.focusedStoreChanged()
        windows.refreshTitles()
        // Re-point the notes-file watches only when the set of open projects' notes paths actually
        // changes, using the paths the stores already resolved (no extra protected-directory scan here).
        let paths = StoreRegistry.shared.watchedNotesPaths.sorted()
        if paths != watchedNotesPaths {
            watchedNotesPaths = paths
            watcher?.watchNotes(paths: paths)
        }
    }

    // MARK: App lifecycle

    /// PM keeps its menubar item (and its notifications, and its Shortcuts actions) whether or not a
    /// window is open, so closing the last window is "put the work away", not "quit".
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Coming forward is the moment a stale view is most obvious — you have just been editing the notes
    /// somewhere else — so check the watched files immediately instead of waiting out the poll.
    func applicationDidBecomeActive(_ notification: Notification) {
        watcher?.pokeNow()
    }

    /// Clicking the Dock icon with nothing open brings up a window on the focused project.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { windows.openFocusedProject() }
        return true
    }

    /// The Dock menu mirrors the menubar's core actions, so the app is useful from the Dock without
    /// opening a window first.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        if let focused = store.focusedTodo {
            let complete = NSMenuItem(title: "Complete: \(focused.text.prefix(40))",
                                      action: #selector(completeFocusedTask), keyEquivalent: "")
            complete.target = self
            menu.addItem(complete)
        }
        let diveIn = NSMenuItem(title: "Dive In", action: #selector(diveIn), keyEquivalent: "")
        diveIn.target = self
        menu.addItem(diveIn)
        menu.addItem(.separator())
        let panel = NSMenuItem(title: "Show Focus Panel", action: #selector(showFocusPanel), keyEquivalent: "")
        panel.target = self
        menu.addItem(panel)
        let open = NSMenuItem(title: "Open Window", action: #selector(newWindow), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        return menu
    }

    @objc private func completeFocusedTask() {
        if let focused = store.focusedTodo { store.complete(focused) }
    }

    @objc private func diveIn() { store.diveIn() }

    @objc private func showFocusPanel() { FocusPanelController.shared.show() }

    // MARK: URL scheme
    // pmpanel://toggle | show | hide   → the focus panel
    // pmpanel://capture | goto         → the quick bar, in one of its two modes
    // pmpanel://window | open?project= → a project window
    // pmpanel://pin?on= | float?on=    → the panel's Raycast-shared settings
    // pmpanel://waiting                → the cross-project Waiting list
    // pmpanel://settings               → the Settings window

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "pmpanel" {
            handle(url: url)
        }
    }

    private func handle(url: URL) {
        let host = url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        switch host {
        // `toggle`/`show`/`hide` have always meant "the panel" to Raycast; now there's a panel again.
        case "toggle": FocusPanelController.shared.toggle()
        case "show": FocusPanelController.shared.show()
        case "hide": FocusPanelController.shared.hide()
        // The quick bar's modes, so a script or a launcher can reach them the same way the hotkeys do.
        case "capture": QuickBarController.shared.toggle(mode: .capture)
        case "find": QuickBarController.shared.toggle(mode: .findTask)
        case "goto": QuickBarController.shared.toggle(mode: .goToProject)
        case "command": QuickBarController.shared.toggle(mode: .command)
        case "note": QuickBarController.shared.toggle(mode: .note)
        case "window": windows.openFocusedProject()
        // Every other PM surface is reachable from here; Settings was the one that wasn't, which made
        // it the one thing a script could change the config for but never show anybody.
        case "settings": SettingsWindowController.shared.show()
        case "waiting": WaitingWindowController.shared.show()
        case "open":
            // A blank or unparseable key would otherwise open a second projectless window, which looks
            // like a bug and can't be told from the empty state.
            if let key = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "project" })?.value,
               PMFiles.projectName(fromKey: key) != nil {
                windows.open(projectKey: key)
            } else {
                windows.openFocusedProject()
            }
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

    // MARK: Spotlight — tapping an indexed project/task focuses it and opens its window.

    func application(_ application: NSApplication, continue userActivity: NSUserActivity,
                     restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void) -> Bool {
        guard userActivity.activityType == CSSearchableItemActionType,
              let id = userActivity.userInfo?[CSSearchableItemActivityIdentifier] as? String else { return false }
        focusFromSpotlight(identifier: id)
        return true
    }

    /// A Spotlight identifier is either a task entity id (`session:line␟projectKey`) or a bare project
    /// key. Focus whichever it names, then open its window — a Spotlight hit is a request to go *to*
    /// something, so it earns the full view rather than the focus panel's one-task summary.
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
        reloadAllStores()
        windows.openFocusedProject()
        NSApp.activate(ignoringOtherApps: true)
    }
}
