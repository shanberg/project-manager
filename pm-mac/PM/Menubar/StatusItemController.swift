import AppKit
import SwiftUI
import ServiceManagement
import PmLib

/// The single consolidated menubar item, replacing the two Raycast menu-bar commands
/// (`focused-project` + `focused-project-status`). The button shows a drawn progress ring plus the
/// project code and next task; the ring tints yellow/red when the focused task has been open a while
/// (stale). The dropdown lists open tasks (click to focus) and the project's own commands, with ⌥
/// alternates (Complete→Undo, Add After→Add Before); the task editors summon the focus panel, which is
/// where typing happens without pulling you out of the app you're in.
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
    var onOpenSettings: () -> Void = {}

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
    /// Max task rows shown inline before overflowing to "Show all in the window", so a big project can't
    /// make the menu unwieldy.
    static let menuTaskCap = 8

    func updateButton() {
        guard let button = statusItem.button else { return }
        button.image = nil            // content is drawn by the hosted SwiftUI view below
        button.toolTip = tooltipText()

        let p = store.progress
        let fraction = p.total > 0 ? Double(p.done) / Double(p.total) : 0
        let ring = MenubarRing.image(fraction: fraction, hasProject: store.projectName != nil,
                                     showsProgress: store.kind.showsProgress, tint: staleTint())
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

    /// Lightweight delegate for submenus so their open/close/highlight can be traced in the log
    /// without the controller's own menu-lifecycle side effects (rebuild, button update). Silent
    /// unless the log is switched on — see `Log.isEnabled`.
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
            menu.addItem(actionItem("Show Focus Panel", #selector(togglePanel), symbol: "scope", key: "p",
                                   modifiers: [.control, .option]))
            menu.addItem(actionItem("Open Window", #selector(showPanel), symbol: "macwindow", key: ""))
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
            menu.addItem(actionItem("Complete: \(truncate(focused.text, 34))", #selector(completeFocused),
                                    symbol: PMCommand.complete.symbol))
            if store.lastCompletedKey != nil {
                // The table's name, not a shorter one of this menu's own — "Undo Last Complete" here
                // against "Undo Last Completion" in the menu bar was two names for one command.
                let undo = actionItem(PMCommand.undoLast.title, #selector(undoLast),
                                      symbol: PMCommand.undoLast.symbol)
                undo.isAlternate = true
                undo.keyEquivalentModifierMask = .option
                menu.addItem(undo)
            }
        }

        // Open tasks grouped by context (custom rows). Click focuses; ⌥-click completes; the focused
        // row completes on click. Capped at `menuTaskCap` rows — the rest live in the window — so a
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
            menu.addItem(actionItem("Show all \(open.count) tasks…", #selector(showPanel), symbol: "ellipsis"))
        }

        // Constant actions inline; less-frequent actions collapsed into submenus (Balanced layout).
        menu.addItem(.separator())
        menu.addItem(actionItem(PMCommand.diveIn.title, #selector(diveIn), symbol: PMCommand.diveIn.symbol))
        menu.addItem(addMenuItem())
        menu.addItem(projectMenuItem())

        menu.addItem(.separator())
        menu.addItem(switchProjectMenuItem())
        // ⌃⌥P is the focus panel's global shortcut, shown here so the menu teaches it. Opening a window has
        // no single key of its own — it's the Dock icon, ⌥⌘N, and this.
        menu.addItem(actionItem("Show Focus Panel", #selector(togglePanel), symbol: "scope", key: "p",
                                   modifiers: [.control, .option]))
        menu.addItem(actionItem("Open Window", #selector(showPanel), symbol: "macwindow", key: ""))

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
        sub.delegate = submenuLogger   // traces open/close/highlight when the log is on
        item.submenu = sub
        return (item, sub)
    }

    /// "Add ▸" and "Project ▸", both built from `PMCommand`.
    ///
    /// These used to be two hand-written lists, which is how the dropdown came to offer Rename and
    /// Archive while the menu bar offered neither, and to call one action "Open in Finder" here and
    /// "Reveal Project in Finder" there. Same table now, same names, same availability — only the
    /// grouping is this surface's own, because a dropdown read at a glance wants fewer, fatter
    /// submenus than a menu bar browsed by name.
    private func commandSubmenu(_ group: PMCommand.StatusMenuGroup, title: String,
                                symbol: String) -> NSMenuItem {
        let (item, sub) = submenu(title, symbol: symbol)
        let context = PMCommand.Context(store: store)
        for command in PMCommand.statusMenu(group) {
            guard command.isAvailable(in: context) else { continue }
            if command.startsMenuGroup, sub.numberOfItems > 0 { sub.addItem(.separator()) }
            let entry = actionItem(command.title(in: context), #selector(runCommand(_:)),
                                   symbol: command.symbol)
            entry.representedObject = command.rawValue
            // The apps get their own icons where we can find them — a Finder or Obsidian item reads
            // faster with the app's face on it than with a generic glyph.
            if let icon = appIcon(for: command) { entry.image = icon }
            Self.forceImageVisible(entry)
            // Add Before rides under Add After on ⌥, as it always has: same gesture, opposite
            // direction, and the pair reads as one choice rather than two items.
            if command == .addBefore {
                entry.isAlternate = true
                entry.keyEquivalentModifierMask = .option
            }
            sub.addItem(entry)
        }
        return item
    }

    /// The Project submenu, plus the focused project's own links underneath it (already loaded, so no
    /// extra IO).
    private func projectMenuItem() -> NSMenuItem {
        let item = commandSubmenu(.project, title: "Project", symbol: "folder")
        let links = linkItems()
        if !links.isEmpty, let sub = item.submenu {
            sub.addItem(.separator())
            sub.addItem(disabledItem("Links"))
            links.forEach { sub.addItem($0) }
        }
        return item
    }

    private func addMenuItem() -> NSMenuItem {
        commandSubmenu(.add, title: "Add", symbol: "plus")
    }

    /// The real app's icon for the commands that hand off to one.
    private func appIcon(for command: PMCommand) -> NSImage? {
        switch command {
        case .openInFinder: return AppIcons.menuIcon(.finder)
        case .openInObsidian: return AppIcons.menuIcon(.obsidian)
        case .openInEditor:
            guard let bundleID = CodeEditor.resolvedBundleID,
                  let url = CodeEditor.url(for: bundleID) else { return nil }
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 16, height: 16)
            return icon
        default: return nil
        }
    }

    /// "Switch Project ▸" — a few recents for quick switching, then out to the project window's own
    /// searchable list for everything else, so the menu stays the same height as the project count grows.
    private func switchProjectMenuItem() -> NSMenuItem {
        let (item, sub) = submenu("Switch Project", symbol: "arrow.left.arrow.right")
        let recents = store.recents   // mtime-ordered, focused project already excluded, capped
        for recent in recents {
            let r = actionItem(truncate(recent.name, 40), #selector(switchProject(_:)))
            if recent.total > 0 {
                r.image = MenubarRing.image(fraction: recent.fraction, hasProject: true,
                                            showsProgress: recent.kind.showsProgress, tint: nil)
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
        sub.addItem(actionItem("All Projects…", #selector(browseAllProjects), symbol: "magnifyingglass"))
        sub.addItem(actionItem(PMCommand.newProject.title, #selector(newProject), symbol: PMCommand.newProject.symbol))
        sub.addItem(actionItem(PMCommand.settings.title, #selector(openSettings), symbol: PMCommand.settings.symbol))
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

    /// "Settings…" — the app's real Settings window. The two window-behavior toggles stay here as
    /// well, because they're the ones Raycast can flip too and it's useful to see their state without
    /// opening a window.
    private func settingsMenuItem() -> NSMenuItem {
        let (item, sub) = submenu("Settings", symbol: "gearshape")
        let s = settings()
        let pin = actionItem("Keep Open When Unfocused", #selector(togglePin))
        pin.state = s.pinned ? .on : .off
        sub.addItem(pin)
        let float = actionItem("Float Above Other Windows", #selector(toggleFloat))
        float.state = s.floating ? .on : .off
        sub.addItem(float)
        sub.addItem(.separator())
        sub.addItem(actionItem("All Settings…", #selector(openSettings), symbol: "gearshape", key: ","))
        return item
    }

    @objc private func openSettings() { onOpenSettings() }

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
                // Whatever's arrived; anything still in flight keeps the link glyph until next open.
                if let favicon = FaviconLoader.shared.menuIcon(for: host) { item.image = favicon }
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

    /// Ask `FaviconLoader` for the focused project's link hosts, so the icons are in hand by the time
    /// the menu is built.
    ///
    /// This used to be a second fetcher living here, with its own cache, its own five-second timeout
    /// and its own record of what had already failed — which meant the menu and the project window
    /// could disagree about which links had icons, and each one's misses taught the other nothing. The
    /// menu can't await anything (`menuNeedsUpdate` is synchronous), so the split is warm here, read
    /// the cache there.
    private func warmFavicons() {
        FaviconLoader.shared.warm(hosts: linkHosts())
    }

    /// Every distinct host named by the focused project's links.
    private func linkHosts() -> Set<String> {
        guard let links = store.notes?.links else { return [] }
        var hosts = Set<String>()
        for link in links {
            for entry in [link] + (link.children ?? []) {
                guard let raw = entry.url?.trimmingCharacters(in: .whitespaces),
                      raw.lowercased().hasPrefix("http") else { continue }
                let host = prettyHost(raw)
                if !host.isEmpty { hosts.insert(host) }
            }
        }
        return hosts
    }

    // MARK: Item builders

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func actionItem(_ title: String, _ action: Selector, symbol: String? = nil, key: String = "",
                            modifiers: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        if !key.isEmpty { item.keyEquivalentModifierMask = modifiers }
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

    // MARK: Actions

    /// Every command item in the dropdown, through the one dispatcher the menu bar uses. The command
    /// rides on `representedObject` as its raw value — see `commandSubmenu`.
    @objc private func runCommand(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let command = PMCommand(rawValue: raw) else { return }
        PMCommandRunner.run(command, store: store)
    }

    @objc private func openLink(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { NSWorkspace.shared.open(url) }
    }

    @objc private func browseAllProjects() {
        WindowManager.shared.openFocusedProject().revealProjectList()
    }

    @objc private func newProject() { PMCommandRunner.run(.newProject, store: store) }

    @objc private func diveIn() { PMCommandRunner.run(.diveIn, store: store) }
    @objc private func completeFocused() { PMCommandRunner.run(.complete, store: store) }
    @objc private func undoLast() { PMCommandRunner.run(.undoLast, store: store) }
    @objc private func focusTask(_ sender: NSMenuItem) { if let t = sender.representedObject as? Todo { store.focus(t) } }
    @objc private func switchProject(_ sender: NSMenuItem) { if let k = sender.representedObject as? String { store.setFocusedProject(key: k) } }
    @objc private func showPanel() { onShowPanel() }
    @objc private func togglePanel() { onTogglePanel() }
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

/// Traces submenu lifecycle to pm-mac.log — the menu-close-on-hover class of bug is invisible without
/// it, since the thing that goes wrong is a menu that has already closed by the time you could look.
///
/// Every one of these is per *highlight*, so it writes a line for each row the pointer crosses. That's
/// the right granularity for the bug and the wrong one for a log that's always on, which is why `Log`
/// is switched off unless a debug build, `PM_LOG` or `PMLogEnabled` asks for it — see `Log.isEnabled`.
final class SubmenuLogger: NSObject, NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) { Log.write("SUB willOpen \(menu.title)") }
    func menuDidClose(_ menu: NSMenu) { Log.write("SUB didClose \(menu.title)") }
    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        Log.write("SUB highlight \(menu.title) -> \(item?.title ?? "nil")")
    }
}
