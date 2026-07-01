import AppKit
import ServiceManagement
import PmLib

/// The single consolidated menubar item, replacing the two Raycast menu-bar commands
/// (`focused-project` + `focused-project-status`). The button shows a drawn progress ring plus the
/// project code and next task; the ring tints yellow/red when the focused task has been open a while
/// (stale). The dropdown lists open tasks (click to focus), light in-process actions, and Raycast
/// deep-links for heavier edits, with ⌥ alternates (Complete→Undo, Add After→Add Before).
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let store: PMStore
    private let statusItem: NSStatusItem
    private let menu = NSMenu()

    var onShowPanel: () -> Void = {}
    var onTogglePanel: () -> Void = {}
    var settings: () -> PanelSettings = { .default }
    var onSetPinned: (Bool) -> Void = { _ in }
    var onSetFloating: (Bool) -> Void = { _ in }

    /// Recent projects (derived from notes-file mtime, like the Raycast status command) plus their
    /// cached progress/due, so the submenu can render rings + due without protected-folder reads while
    /// the menu opens. The whole set is recomputed in the background on store changes (30s TTL).
    private struct RecentInfo { let done: Int; let total: Int; let nextDue: String?; let summary: String? }
    private var recentList: [PMFiles.RecentProject] = []
    private var recentInfo: [String: RecentInfo] = [:]
    private var recentsWarmedAt: Date = .distantPast
    private var recentsWarmedForKey: String?
    private let recentsQueue = DispatchQueue(label: "com.stuarthanberg.pm.recents")

    /// Cached favicons for project links, keyed by host. Fetched once per host in the background.
    private var faviconCache: [String: NSImage] = [:]
    private var faviconTried: Set<String> = []

    init(store: PMStore) {
        self.store = store
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        menu.delegate = self
        statusItem.menu = menu
        updateButton()
    }

    // MARK: Button (icon + title)

    /// Custom menu rows are sized to this width, which also sets the menu's minimum width.
    static let menuWidth: CGFloat = 300
    /// Max task rows shown inline before overflowing to "Show all in panel", so a big project can't
    /// make the menu unwieldy.
    static let menuTaskCap = 8

    func updateButton() {
        guard let button = statusItem.button else { return }
        let p = store.progress
        let fraction = p.total > 0 ? Double(p.done) / Double(p.total) : 0
        button.image = MenubarRing.image(fraction: fraction, hasProject: store.projectName != nil, tint: staleTint())
        button.imagePosition = .imageLeading
        button.attributedTitle = titleAttributed()
        button.toolTip = tooltipText()
    }

    /// "next task  2d · H-005" — task first (with its relative due if any), a dimmed dot, then the
    /// project code. Attributed so the due can tint red when overdue and the code/dot read as
    /// secondary, packing more signal into the bar than a plain string.
    private func titleAttributed() -> NSAttributedString {
        guard let name = store.projectName else { return NSAttributedString(string: "") }
        let project = truncate(projectTitle(name), 24)
        let font = NSFont.menuBarFont(ofSize: 0)
        let smallFont = NSFont.menuBarFont(ofSize: NSFont.systemFontSize - 2)
        func seg(_ s: String, _ color: NSColor, _ f: NSFont = font) -> NSAttributedString {
            NSAttributedString(string: s, attributes: [.font: f, .foregroundColor: color])
        }
        let result = NSMutableAttributedString()
        if let next = store.focusedTodo ?? store.openTodos.first {
            result.append(seg(" " + truncate(next.text, 30), .labelColor))
            if let due = next.dueDate ?? next.effectiveDueDate {
                let overdue = RelativeDue.isOverdue(due)
                result.append(seg("  " + RelativeDue.short(due), overdue ? .systemRed : .secondaryLabelColor))
            }
            result.append(seg("  ·  ", .tertiaryLabelColor, smallFont))
            result.append(seg(project, .secondaryLabelColor))
        } else {
            result.append(seg(" " + project, .labelColor))  // all tasks done
        }
        return result
    }

    private func tooltipText() -> String? {
        guard let name = store.projectName else { return nil }
        var parts: [String] = []
        let p = store.progress
        parts.append(p.total > 0 ? "\(store.notes?.title ?? name): \(p.done)/\(p.total) done" : (store.notes?.title ?? name))
        if let focused = store.focusedTodo, let due = focused.effectiveDueDate ?? focused.dueDate {
            parts.append("Next due: \(RelativeDue.short(due))")
        }
        if let summary = store.notes?.summary.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
            parts.append(String(summary.prefix(140)))
        }
        return parts.joined(separator: "\n")
    }

    /// The project's human title (notes title), falling back to the folder name.
    private func projectTitle(_ name: String) -> String {
        let t = store.notes?.title.trimmingCharacters(in: .whitespaces) ?? ""
        return t.isEmpty ? name : t
    }

    /// Yellow after 1h on the focused task, red after 2h — from `task-timing.json` in the config dir.
    private func staleTint() -> NSColor? {
        guard let focused = store.focusedTodo, let notesPath = store.notesPath else { return nil }
        let key = "\(notesPath)::\(focused.sessionIndex):\(focused.lineIndex)"
        let nowMs = Date().timeIntervalSince1970 * 1000
        let stored = TaskTiming.load()
        guard stored?.taskKey == key else {
            TaskTiming.save(taskKey: key, seenAt: nowMs)  // newly focused → reset the clock
            return nil
        }
        let hours = (nowMs - stored!.seenAt) / 3_600_000
        if hours >= 2 { return .systemRed }
        if hours >= 1 { return .systemYellow }
        return nil
    }

    private func truncate(_ s: String, _ n: Int) -> String {
        s.count <= n ? s : String(s.prefix(n - 1)) + "…"
    }

    // MARK: Menu

    /// True while the dropdown is open (its modal tracking loop is running). Used to hold off any
    /// mutation of the status button, which would cancel that loop and dismiss the menu.
    private var menuIsOpen = false

    /// DIAGNOSTIC: lightweight delegate for submenus so we can trace their open/close/highlight in the
    /// log without the controller's own menu-lifecycle side effects (rebuild, button update).
    private let submenuLogger = SubmenuLogger()

    func menuWillOpen(_ menu: NSMenu) {
        menuIsOpen = true
        Log.write("MENU willOpen top")
        // Refresh from disk so the *next* open is current. While the menu is open its tracking loop is
        // modal (you can't edit elsewhere), so there's no live external edit to show — and we don't
        // touch the status button until it closes.
        store.reload()
    }

    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
        Log.write("MENU didClose top")
        updateButton()  // apply anything that changed while the menu was open
    }

    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        Log.write("MENU highlight top -> \(item?.title ?? "nil")\(item?.submenu != nil ? " [submenu]" : "")")
    }

    /// Called when the store's data changes: refresh the status-bar glyph and warm the submenu caches.
    /// While the menu is open we skip the button update: reconfiguring an NSStatusItem's button (image/
    /// title) — and the `task-timing.json` write behind `staleTint()` — while its menu is in the modal
    /// tracking loop cancels tracking and dismisses the menu (the cold first-open reload landing ~1–2s
    /// in was doing exactly that). menuDidClose reapplies the update.
    func storeChanged() {
        if !menuIsOpen { updateButton() }
        warmRecents()
        warmFavicons()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        Log.write("MENU needsUpdate \(menu === self.menu ? "top" : "OTHER:\(menu.title)")")
        menu.removeAllItems()

        guard let name = store.projectName else {
            menu.addItem(disabledItem("No focused project"))
            menu.addItem(.separator())
            menu.addItem(switchProjectMenuItem())
            menu.addItem(actionItem("Show Panel", #selector(showPanel), symbol: "sidebar.right", key: "p"))
            menu.addItem(.separator())
            menu.addItem(settingsMenuItem())
            menu.addItem(actionItem("Quit PM", #selector(quit), key: "q"))
            return
        }

        // Glance: title + progress bar (custom view — the native menu can't draw one).
        let p = store.progress
        menu.addItem(headerHostItem(title: store.notes?.title ?? name, done: p.done, total: p.total))

        // Constant action: complete the focused task, with ⌥ Undo.
        if let focused = store.focusedTodo {
            menu.addItem(.separator())
            menu.addItem(actionItem("Complete: \(truncate(focused.text, 34))", #selector(completeFocused), symbol: "checkmark.circle"))
            if store.lastCompletedKey != nil {
                let undo = actionItem("Undo Last Complete", #selector(undoLast), symbol: "arrow.uturn.backward")
                undo.isAlternate = true
                undo.keyEquivalentModifierMask = .option
                menu.addItem(undo)
            }
        }

        // Open tasks grouped by context (custom rows). Click focuses; ⌥-click completes; the focused
        // row completes on click. Capped at `menuTaskCap` rows — the rest live in the panel — so a
        // large project can't blow out the menu.
        let open = store.openTodos
        var shown = 0
        for (context, todos) in contextGroups() {
            let slice = todos.prefix(max(0, Self.menuTaskCap - shown))
            if slice.isEmpty { continue }
            menu.addItem(.separator())
            let overdue = todos.filter { ($0.dueDate ?? $0.effectiveDueDate).map(RelativeDue.isOverdue) ?? false }.count
            menu.addItem(contextHeaderItem(context, overdue: overdue))
            for todo in slice { menu.addItem(taskRowItem(todo)); shown += 1 }
            if shown >= Self.menuTaskCap { break }
        }
        if open.count > shown {
            menu.addItem(actionItem("Show all \(open.count) tasks in panel…", #selector(showPanel), symbol: "ellipsis"))
        }

        // Constant actions inline; less-frequent actions collapsed into submenus (Balanced layout).
        menu.addItem(.separator())
        menu.addItem(actionItem("Dive In", #selector(diveIn), symbol: "arrow.down.to.line"))
        menu.addItem(addMenuItem())
        menu.addItem(projectMenuItem())

        menu.addItem(.separator())
        menu.addItem(switchProjectMenuItem())
        menu.addItem(actionItem("Show Panel", #selector(showPanel), symbol: "sidebar.right", key: "p"))

        menu.addItem(.separator())
        menu.addItem(settingsMenuItem())
        menu.addItem(actionItem("Quit PM", #selector(quit), key: "q"))
    }

    // MARK: Submenus (Balanced collapse)

    /// A titled submenu item carrying an SF Symbol.
    private func submenu(_ title: String, symbol: String?) -> (item: NSMenuItem, menu: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        if let symbol {
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            Self.forceImageVisible(item)
        }
        let sub = NSMenu(title: title)
        sub.delegate = submenuLogger   // DIAGNOSTIC: trace submenu open/close/highlight
        item.submenu = sub
        return (item, sub)
    }

    /// "Add ▸" — the task add/edit commands (Raycast stays the main add/edit surface).
    private func addMenuItem() -> NSMenuItem {
        let (item, sub) = submenu("Add", symbol: "plus")
        sub.addItem(raycastItem("Narrow Focus…", command: "add-focused-todo", symbol: "arrow.turn.down.right"))
        sub.addItem(raycastItem("Add After…", command: "add-focused-after-todo", symbol: "arrow.down"))
        let before = raycastItem("Add Before…", command: "add-focused-prior-todo", symbol: "arrow.up")
        before.isAlternate = true
        before.keyEquivalentModifierMask = .option
        sub.addItem(before)
        sub.addItem(.separator())
        sub.addItem(raycastItem("Edit Task…", command: "edit-focused-task", symbol: "pencil"))
        sub.addItem(raycastItem("Wrap Task…", command: "wrap-focused-task", symbol: "arrow.up.and.down.and.arrow.left.and.right"))
        return item
    }

    /// "Project ▸" — open/view/edit the project, plus its links (already loaded, no extra IO).
    private func projectMenuItem() -> NSMenuItem {
        let (item, sub) = submenu("Project", symbol: "folder")
        let finder = actionItem("Open in Finder", #selector(openInFinder), symbol: "folder")
        if let icon = AppIcons.menuIcon(.finder) { finder.image = icon }
        sub.addItem(finder)
        let obsidian = raycastItem("Open in Obsidian", command: "open-focused-in-obsidian", symbol: "book.closed")
        if let icon = AppIcons.menuIcon(.obsidian) { obsidian.image = icon }
        sub.addItem(obsidian)
        // Open in Cursor, only for code projects (a `src/` dir), matching the old Raycast behavior.
        if let path = store.projectPath,
           FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent("src")) {
            sub.addItem(actionItem("Open in Cursor", #selector(openInCursor), symbol: "chevron.left.forwardslash.chevron.right"))
        }
        sub.addItem(.separator())
        sub.addItem(raycastItem("View Project…", command: "view-focused-project", symbol: "doc.text"))
        sub.addItem(raycastItem("Edit Project…", command: "edit-focused-project", symbol: "square.and.pencil"))
        sub.addItem(raycastItem("Add Session Note…", command: "add-focused-session-note", symbol: "note.text"))
        sub.addItem(raycastItem("Add Link…", command: "add-focused-link", symbol: "link"))
        let links = linkItems()
        if !links.isEmpty {
            sub.addItem(.separator())
            sub.addItem(disabledItem("Links"))
            links.forEach { sub.addItem($0) }
        }
        return item
    }

    /// "Switch Project ▸" — a few recents for quick switching, then hand off to Raycast's searchable
    /// list for everything else so the menu stays the same height as the project count grows.
    private func switchProjectMenuItem() -> NSMenuItem {
        let (item, sub) = submenu("Switch Project", symbol: "arrow.left.arrow.right")
        let recents = recentList   // mtime-ordered, focused project already excluded, capped
        for recent in recents {
            let r = actionItem(truncate(recent.name, 40), #selector(switchProject(_:)))
            let info = recentInfo[recent.projectKey]
            if let info, info.total > 0 {
                r.image = MenubarRing.image(fraction: Double(info.done) / Double(info.total), hasProject: true, tint: nil)
            } else {
                r.image = NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: nil)
            }
            Self.forceImageVisible(r)
            if #available(macOS 14.4, *), let due = info?.nextDue { r.subtitle = "next \(RelativeDue.short(due))" }
            r.toolTip = recentTooltip(name: recent.name, info: info)
            r.representedObject = recent.projectKey
            sub.addItem(r)
        }
        if !recents.isEmpty { sub.addItem(.separator()) }
        sub.addItem(raycastItem("All Projects…", command: "list-projects", symbol: "magnifyingglass"))
        sub.addItem(raycastItem("New Project…", command: "new-project", symbol: "plus.square"))
        sub.addItem(raycastItem("Configure…", command: "configure", symbol: "gearshape"))
        warmRecents()   // ensure warming if the cache is cold/stale when the menu is built
        return item
    }

    private func recentTooltip(name: String, info: RecentInfo?) -> String {
        guard let info else { return name }
        var parts = [info.total > 0 ? "\(name): \(info.done)/\(info.total) done" : name]
        if let due = info.nextDue { parts.append("Next due: \(RelativeDue.short(due))") }
        if let summary = info.summary { parts.append(String(summary.prefix(120))) }
        return parts.joined(separator: "\n")
    }

    /// "Settings ▸" — window behavior + launch at login.
    private func settingsMenuItem() -> NSMenuItem {
        let (item, sub) = submenu("Settings", symbol: "gearshape")
        let s = settings()
        let pin = actionItem("Keep Open When Unfocused", #selector(togglePin))
        pin.state = s.pinned ? .on : .off
        sub.addItem(pin)
        let float = actionItem("Float Above Other Windows", #selector(toggleFloat))
        float.state = s.floating ? .on : .off
        sub.addItem(float)
        let login = actionItem("Launch at Login", #selector(toggleLoginItem))
        login.state = isLoginItemEnabled ? .on : .off
        sub.addItem(login)
        return item
    }

    // MARK: Custom row / header items

    private func headerHostItem(title: String, done: Int, total: Int) -> NSMenuItem {
        let item = NSMenuItem()
        item.view = MenuStaticView(width: Self.menuWidth, fallbackHeight: 30) {
            MenuHeaderContent(title: title, done: done, total: total)
        }
        return item
    }

    /// Open tasks in first-appearance order, grouped by their context string (matching the Raycast
    /// menu-bar item's grouping).
    private func contextGroups() -> [(context: String, todos: [Todo])] {
        var order: [String] = []
        var map: [String: [Todo]] = [:]
        for t in store.openTodos {
            if map[t.context] == nil { order.append(t.context) }
            map[t.context, default: []].append(t)
        }
        return order.map { (context: $0, todos: map[$0] ?? []) }
    }

    private func contextHeaderItem(_ context: String, overdue: Int) -> NSMenuItem {
        let title = context.isEmpty ? "Tasks" : context
        let item: NSMenuItem
        if #available(macOS 14.0, *) {
            item = NSMenuItem.sectionHeader(title: title)
        } else {
            item = disabledItem(title)
        }
        if overdue > 0, #available(macOS 14.0, *) {
            item.badge = NSMenuItemBadge(string: "\(overdue) overdue")
        }
        return item
    }

    private func taskRowItem(_ todo: Todo) -> NSMenuItem {
        let item = NSMenuItem()
        let row = MenuRowView(width: Self.menuWidth, onSelect: { [weak self] optionHeld in
            guard let self else { return }
            if todo.isFocused || optionHeld {
                self.store.complete(todo)
            } else {
                self.store.focus(todo)
            }
        }) {
            TaskMenuRowContent(todo: todo)
        }
        item.view = row
        item.target = row
        item.action = #selector(MenuRowView.fire)  // Return key selects the row too
        item.representedObject = todo
        return item
    }

    // MARK: Links

    private func linkItems() -> [NSMenuItem] {
        guard let links = store.notes?.links else { return [] }
        var items: [NSMenuItem] = []
        for link in links {
            for entry in [link] + (link.children ?? []) {
                guard let raw = entry.url?.trimmingCharacters(in: .whitespaces), !raw.isEmpty,
                      raw.lowercased().hasPrefix("http"), let url = URL(string: raw) else { continue }
                let label = (entry.label ?? link.label ?? "").trimmingCharacters(in: .whitespaces)
                let host = prettyHost(raw)
                let item = actionItem(truncate(label.isEmpty ? host : label, 40), #selector(openLink(_:)), symbol: "link")
                if let favicon = faviconCache[host] { item.image = favicon }   // cached; else keeps the link glyph
                item.representedObject = url
                if #available(macOS 14.4, *), !label.isEmpty, host != label { item.subtitle = host }
                items.append(item)
            }
        }
        return items
    }

    private func prettyHost(_ urlStr: String) -> String {
        var s = urlStr
        for scheme in ["https://", "http://"] where s.lowercased().hasPrefix(scheme) {
            s = String(s.dropFirst(scheme.count)); break
        }
        if let slash = s.firstIndex(of: "/") { s = String(s[..<slash]) }
        return s
    }

    // MARK: Async enrichment (recent-project rings + link favicons)

    /// Rebuilds the recent-projects list (ordered by notes-file mtime, like the Raycast status
    /// command's `getRecentProjectsByEdit`) and their progress/due/summary, in the background. This
    /// derives recents purely from the filesystem — no shared write is needed, so they populate even
    /// on a fresh install. Respects a 30s TTL, re-running immediately when the focused project changes.
    private func warmRecents() {
        let excludeKey = store.projectKey
        if recentsWarmedForKey == excludeKey, Date().timeIntervalSince(recentsWarmedAt) < 30 { return }
        recentsWarmedAt = Date()          // debounce concurrent triggers (menu-open + storeChanged)
        recentsWarmedForKey = excludeKey
        recentsQueue.async { [weak self] in
            guard let list = Self.recentsByEdit(excludeKey: excludeKey, limit: 8) else { return }
            var info: [String: RecentInfo] = [:]
            for r in list {
                guard let out = try? notesShow(project: r.name) else { continue }
                let summary = out.notes.summary.trimmingCharacters(in: .whitespacesAndNewlines)
                info[r.projectKey] = RecentInfo(done: out.todos.filter { $0.checked }.count,
                                                total: out.todos.count,
                                                nextDue: Self.earliestDue(out.todos),
                                                summary: summary.isEmpty ? nil : summary)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.recentList = list
                self.recentInfo = info
                // Don't rebuild the menu here even if it's open: recents live in the Switch Project
                // submenu (not visible at the top level), and swapping the top menu's custom view
                // items mid-track ends tracking and closes the menu. The warmed data appears on the
                // next open — warming is proactive on store changes, so it's ready by then.
            }
        }
    }

    /// All projects across the active + archive folders, ordered by notes-file mtime (newest first,
    /// falling back to folder mtime), excluding the focused project, capped at `limit`. Does protected-
    /// folder IO, so only ever call this off the main thread.
    private static func recentsByEdit(excludeKey: String?, limit: Int) -> [PMFiles.RecentProject]? {
        guard let (config, paths) = try? loadConfigAndPaths() else { return nil }
        let codes = Array(config.domains.keys)
        var entries: [(project: PMFiles.RecentProject, mtime: Date)] = []
        for base in [paths.activePath, paths.archivePath] {
            guard let folders = try? getProjectFolders(basePath: base, domainCodes: codes) else { continue }
            for name in folders {
                let key = "\(base):\(name)"
                if key == excludeKey { continue }
                let projectPath = (base as NSString).appendingPathComponent(name)
                let notesPath = (try? resolveNotesPath(projectPath: projectPath)) ?? nil
                let attrs = try? FileManager.default.attributesOfItem(atPath: notesPath ?? projectPath)
                let mtime = (attrs?[.modificationDate] as? Date) ?? .distantPast
                entries.append((PMFiles.RecentProject(projectKey: key, name: name), mtime))
            }
        }
        return entries.sorted { $0.mtime > $1.mtime }.prefix(limit).map(\.project)
    }

    /// Earliest due (own or inherited) among open todos, for the recent-project "next due" hint.
    private static func earliestDue(_ todos: [Todo]) -> String? {
        todos.filter { !$0.checked }
            .compactMap { $0.dueDate ?? $0.effectiveDueDate }
            .min { (RelativeDue.parse($0) ?? .distantFuture) < (RelativeDue.parse($1) ?? .distantFuture) }
    }

    /// Fetches favicons for the focused project's link hosts once each, from the linked host's own
    /// `/favicon.ico` (no third-party favicon service). Cached for the app's lifetime.
    private func warmFavicons() {
        guard let links = store.notes?.links else { return }
        var hosts = Set<String>()
        for link in links {
            for entry in [link] + (link.children ?? []) {
                guard let raw = entry.url?.trimmingCharacters(in: .whitespaces), raw.lowercased().hasPrefix("http") else { continue }
                let host = prettyHost(raw)
                if !host.isEmpty { hosts.insert(host) }
            }
        }
        for host in hosts where !faviconTried.contains(host) {
            faviconTried.insert(host)
            guard let url = URL(string: "https://\(host)/favicon.ico") else { continue }
            var request = URLRequest(url: url)
            request.timeoutInterval = 5
            URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
                guard let data, !data.isEmpty, let image = NSImage(data: data) else { return }
                image.size = NSSize(width: 16, height: 16)
                DispatchQueue.main.async { Log.write("MENU favicon done \(host)"); self?.faviconCache[host] = image }
            }.resume()
        }
    }

    // MARK: Item builders

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func actionItem(_ title: String, _ action: Selector, symbol: String? = nil, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        if let symbol {
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            Self.forceImageVisible(item)
        }
        return item
    }

    /// macOS 27 hides menu-item *symbol* images by default (`NSMenuItem.preferredImageVisibility`
    /// defaults to `.automatic`). Opt back in so our SF Symbol action icons render. The Xcode SDK
    /// (26.5) predates this API, so set it through the runtime; `responds(to:)` makes it a no-op on
    /// earlier macOS. `1` == `NSMenuItemImageVisibilityVisible`.
    private static func forceImageVisible(_ item: NSMenuItem) {
        let selector = NSSelectorFromString("setPreferredImageVisibility:")
        guard item.responds(to: selector) else { return }
        item.setValue(NSNumber(value: 1), forKey: "preferredImageVisibility")
    }

    private func raycastItem(_ title: String, command: String, symbol: String? = nil) -> NSMenuItem {
        let item = actionItem(title, #selector(openRaycast(_:)), symbol: symbol)
        item.representedObject = Self.raycastBase + command
        return item
    }

    // MARK: Actions

    private static let raycastBase = "raycast://extensions/shanberg/project-manager/"

    @objc private func openRaycast(_ sender: NSMenuItem) {
        if let str = sender.representedObject as? String, let url = URL(string: str) {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openLink(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { NSWorkspace.shared.open(url) }
    }

    @objc private func openInFinder() {
        guard let path = store.projectPath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    @objc private func openInCursor() {
        guard let path = store.projectPath else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-a", "Cursor", path]
        try? p.run()
    }

    @objc private func diveIn() { store.diveIn() }
    @objc private func completeFocused() { if let f = store.focusedTodo { store.complete(f) } }
    @objc private func undoLast() { store.undoLast() }
    @objc private func focusTask(_ sender: NSMenuItem) { if let t = sender.representedObject as? Todo { store.focus(t) } }
    @objc private func switchProject(_ sender: NSMenuItem) { if let k = sender.representedObject as? String { store.setFocusedProject(key: k) } }
    @objc private func showPanel() { onShowPanel() }
    @objc private func togglePin() { onSetPinned(!settings().pinned) }
    @objc private func toggleFloat() { onSetFloating(!settings().floating) }
    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: Launch at Login (SMAppService, macOS 13+)

    private var isLoginItemEnabled: Bool { SMAppService.mainApp.status == .enabled }

    @objc private func toggleLoginItem() {
        do {
            if isLoginItemEnabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            NSLog("PM: failed to toggle login item: \(error)")
        }
    }
}

// MARK: - Drawn progress ring (finer-grained than Raycast's 5-step CircleProgress)

private enum MenubarRing {
    static func image(fraction: Double, hasProject: Bool, tint: NSColor?) -> NSImage {
        let size = NSSize(width: 15, height: 15)
        let img = NSImage(size: size, flipped: false) { rect in
            let lineWidth: CGFloat = 1.6
            let inset = rect.insetBy(dx: lineWidth, dy: lineWidth)
            let color = tint ?? .black  // black draws as a template that the menubar recolors
            let center = NSPoint(x: inset.midX, y: inset.midY)
            let radius = min(inset.width, inset.height) / 2

            // Track ring.
            let track = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius,
                                                    width: radius * 2, height: radius * 2))
            track.lineWidth = lineWidth
            color.withAlphaComponent(0.35).setStroke()
            track.stroke()

            // Progress arc (clockwise from 12 o'clock).
            let clamped = min(max(fraction, 0), 1)
            if hasProject && clamped > 0 {
                let arc = NSBezierPath()
                arc.appendArc(withCenter: center, radius: radius,
                              startAngle: 90, endAngle: 90 - 360 * clamped, clockwise: true)
                arc.lineWidth = lineWidth
                color.setStroke()
                arc.stroke()
            }
            return true
        }
        img.isTemplate = (tint == nil)  // colored (stale) rings must not be template-recolored
        return img
    }
}

/// DIAGNOSTIC ONLY: traces submenu lifecycle to pm-mac.log to pin down the menu-close-on-hover bug.
final class SubmenuLogger: NSObject, NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) { Log.write("SUB willOpen \(menu.title)") }
    func menuDidClose(_ menu: NSMenu) { Log.write("SUB didClose \(menu.title)") }
    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        Log.write("SUB highlight \(menu.title) -> \(item?.title ?? "nil")")
    }
}
