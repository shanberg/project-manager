import AppKit
import SwiftUI
import ServiceManagement
import PmLib

/// The single consolidated menubar item, replacing the two Raycast menu-bar commands
/// (`focused-project` + `focused-project-status`). The button shows a drawn progress ring plus the
/// project code and next task; the ring tints yellow/red when the focused task has been open a while
/// (stale). The dropdown lists open tasks (click to focus), light in-process actions, and Raycast
/// deep-links for heavier edits, with ⌥ alternates (Complete→Undo, Add After→Add Before).
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    /// The store for whatever project is focused. Re-pointed (rather than reloaded) when the focus
    /// moves, so the menubar shares one store — and therefore one undo history and one
    /// last-completed task — with any window showing that same project.
    var store: PMStore { didSet { updateButton() } }
    private let statusItem: NSStatusItem
    private let menu = NSMenu()

    var onShowPanel: () -> Void = {}
    var onTogglePanel: () -> Void = {}
    var settings: () -> PanelSettings = { .default }
    var onSetPinned: (Bool) -> Void = { _ in }
    var onSetFloating: (Bool) -> Void = { _ in }

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

    /// Hosts the button's content (ring + task + project) as SwiftUI so only the task element animates
    /// when the focused task moves. Kept across updates (its `rootView` is reassigned) so SwiftUI can
    /// diff and run the scoped transition rather than rebuilding from scratch.
    private var titleHost: PassthroughHostingView<AnyView>?

    // MARK: Button (icon + title)

    /// Custom menu rows are sized to this width, which also sets the menu's minimum width.
    static let menuWidth: CGFloat = 300
    /// Max task rows shown inline before overflowing to "Show all in panel", so a big project can't
    /// make the menu unwieldy.
    static let menuTaskCap = 8

    func updateButton() {
        guard let button = statusItem.button else { return }
        button.image = nil            // content is drawn by the hosted SwiftUI view below
        button.toolTip = tooltipText()

        let p = store.progress
        let fraction = p.total > 0 ? Double(p.done) / Double(p.total) : 0
        let ring = MenubarRing.image(fraction: fraction, hasProject: store.projectName != nil, tint: staleTint())
        let content = MenubarTitleContent(
            ring: ring,
            task: currentTaskGlyph(),
            project: store.projectName.map { truncate(projectTitle($0), 24) } ?? "",
            move: store.focusMove,
            moveToken: store.focusMoveToken
        )
        let root = AnyView(content)

        let host: PassthroughHostingView<AnyView>
        if let existing = titleHost {
            host = existing
            host.rootView = root       // reassign so SwiftUI diffs and runs the scoped task transition
        } else {
            host = PassthroughHostingView(rootView: root)   // ignores hits so the button still opens the menu
            button.addSubview(host)
            titleHost = host
        }

        // Size the status item to the content and vertically center it in the bar.
        host.layoutSubtreeIfNeeded()
        let fit = host.fittingSize
        let width = max(1, ceil(fit.width))
        statusItem.length = width
        let barHeight = button.bounds.height
        host.frame = NSRect(x: 0, y: ((barHeight - ceil(fit.height)) / 2).rounded(),
                            width: width, height: ceil(fit.height))
    }

    /// The focused (or first open) task reduced to what the bar shows, or nil when everything's done.
    /// `key` + `text` give the hosted task view its transition identity so a move animates just it.
    private func currentTaskGlyph() -> MenubarTitleContent.Task? {
        guard let next = store.focusedTodo ?? store.openTodos.first else { return nil }
        let due = next.dueDate ?? next.effectiveDueDate
        return MenubarTitleContent.Task(
            key: PMStore.key(for: next),
            text: truncate(next.text, 30),
            due: due.map { RelativeDue.short($0) },
            overdue: due.map(RelativeDue.isOverdue) ?? false
        )
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
        let recents = store.recents   // mtime-ordered, focused project already excluded, capped
        for recent in recents {
            let r = actionItem(truncate(recent.name, 40), #selector(switchProject(_:)))
            if recent.total > 0 {
                r.image = MenubarRing.image(fraction: recent.fraction, hasProject: true, tint: nil)
            } else {
                r.image = NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: nil)
            }
            Self.forceImageVisible(r)
            if #available(macOS 14.4, *) { r.subtitle = recentSubtitle(recent) }
            r.toolTip = recentTooltip(recent)
            r.representedObject = recent.projectKey
            sub.addItem(r)
        }
        if !recents.isEmpty { sub.addItem(.separator()) }
        sub.addItem(raycastItem("All Projects…", command: "list-projects", symbol: "magnifyingglass"))
        sub.addItem(raycastItem("New Project…", command: "new-project", symbol: "plus.square"))
        sub.addItem(raycastItem("Configure…", command: "configure", symbol: "gearshape"))
        return item
    }

    /// The recent row's second line: its focused (or next) task, with the "next due" hint appended.
    /// Nil when the project has neither, so the row stays a single line.
    private func recentSubtitle(_ recent: PMStore.Recent) -> String? {
        var parts: [String] = []
        if let task = recent.focusedText { parts.append(truncate(task, 40)) }
        if let due = recent.nextDue { parts.append("next \(RelativeDue.short(due))") }
        return parts.isEmpty ? nil : parts.joined(separator: "  ·  ")
    }

    private func recentTooltip(_ recent: PMStore.Recent) -> String {
        var parts = [recent.total > 0 ? "\(recent.name): \(recent.done)/\(recent.total) done" : recent.name]
        if let due = recent.nextDue { parts.append("Next due: \(RelativeDue.short(due))") }
        if let summary = recent.summary { parts.append(String(summary.prefix(120))) }
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

    // MARK: Async enrichment (link favicons)

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

/// DIAGNOSTIC ONLY: traces submenu lifecycle to pm-mac.log to pin down the menu-close-on-hover bug.
final class SubmenuLogger: NSObject, NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) { Log.write("SUB willOpen \(menu.title)") }
    func menuDidClose(_ menu: NSMenu) { Log.write("SUB didClose \(menu.title)") }
    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        Log.write("SUB highlight \(menu.title) -> \(item?.title ?? "nil")")
    }
}
