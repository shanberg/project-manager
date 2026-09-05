import AppKit

/// The app's menu bar.
///
/// This used to be a single hidden Edit menu: an `.accessory` app never shows the menu bar, but
/// `NSApplication` still dispatches a main menu's key equivalents down the responder chain, and without
/// that menu ⌘A/⌘C/⌘X/⌘V/⌘Z simply did nothing in the window text fields. Now that PM is a regular app
/// the bar is visible, so it has to be a real command model rather than a keyboard shim.
///
/// Two routing rules run through the whole thing:
///
///   * Text-editing items keep their **first-responder selectors** (`undo:`, `copy:`, `selectAll:`), so
///     while a text field is focused they route to its field editor and edit the text. That only
///     happens if nothing in the key window claims the keystroke first: AppKit offers a key equivalent
///     to the key *window* before this menu, and a SwiftUI `.keyboardShortcut` is exactly such a claim.
///     So the content's own ⌘C / ⌘A stand down while a field has the keyboard rather than merely
///     sitting behind these — see `ProjectView.keyboardShortcuts` and `ProjectViewState.isEditingText`.
///   * Everything window-shaped targets `nil` too, so it walks the responder chain and lands on the
///     `ProjectWindowController` of whichever window is in front — `toggleSidebar:` is answered by the
///     split view controller, the rest by the window controller. App-wide items target the delegate.
@MainActor
enum MainMenu {
    static func install(target: AppDelegate) {
        let mainMenu = NSMenu()
        mainMenu.addItem(appMenuItem(target: target))
        mainMenu.addItem(fileMenuItem(target: target))
        mainMenu.addItem(editMenuItem())
        mainMenu.addItem(viewMenuItem(target: target))
        mainMenu.addItem(domainMenuItem(.task, title: "Task", target: target))
        mainMenu.addItem(domainMenuItem(.project, title: "Project", target: target))

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)

        let helpItem = NSMenuItem()
        let helpMenu = NSMenu(title: "Help")
        fillHelpMenu(helpMenu, target: target)
        helpItem.submenu = helpMenu
        mainMenu.addItem(helpItem)

        NSApp.mainMenu = mainMenu
        // AppKit fills these in itself — Minimize/Zoom/Bring All to Front and the window list, plus the
        // tab items (Show Next Tab, Move Tab to New Window…) once a window declares a tabbing identifier.
        NSApp.windowsMenu = windowMenu
        NSApp.helpMenu = helpMenu
    }

    // MARK: PM

    private static func appMenuItem(target: AppDelegate) -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "PM")

        menu.addItem(withTitle: "About PM", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                     keyEquivalent: "")
        menu.addItem(.separator())
        add(menu, "Settings…", #selector(AppDelegate.openSettings), target: target, key: ",")
        menu.addItem(.separator())

        let services = NSMenu(title: "Services")
        let servicesItem = menu.addItem(withTitle: "Services", action: nil, keyEquivalent: "")
        servicesItem.submenu = services
        NSApp.servicesMenu = services
        menu.addItem(.separator())

        menu.addItem(withTitle: "Hide PM", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = menu.addItem(withTitle: "Hide Others",
                                      action: #selector(NSApplication.hideOtherApplications(_:)),
                                      keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)),
                     keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit PM", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        item.submenu = menu
        return item
    }

    // MARK: File

    private static func fileMenuItem(target: AppDelegate) -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "File")

        // ⌘N makes the app's primary content, ⌥⌘N makes a window — Mail's split, and the one that keeps
        // ⌘T free for the standard New Tab.
        add(menu, "New Task", #selector(ProjectWindowController.newTask), target: nil, key: "n")
        // ⇧⌘N opens the current session's note, starting a session first when there isn't one to
        // continue — the sibling of New Task one level up, and
        // what replaced the "New session" button that used to sit in the list.
        add(menu, "New Session", #selector(ProjectWindowController.newSession), target: nil, key: "n",
            modifiers: [.command, .shift])
        // ⌃⌘N: the third "new" in the File menu, after the task and the session it sits above in scale.
        track(.quickCapture,
              add(menu, "Quick Add Task…", #selector(AppDelegate.quickCapture), target: target, key: ""))
        // Under it, because it's the same summon with the other kind of thing to say: one files a line,
        // one opens somewhere to write.
        track(.quickNote,
              add(menu, "Write a Session Note…", #selector(AppDelegate.quickNote), target: target, key: ""))
        add(menu, "New Project…", #selector(AppDelegate.newProject), target: target, key: "n",
            modifiers: [.command, .control])
        // Directly under New Project, and without a shortcut of its own: it's the same errand for the
        // other kind of thing, and it's reached far less often than the project it sits beneath.
        add(menu, "New Area…", #selector(AppDelegate.newArea), target: target, key: "")
        // Under New Area because it makes the same thing by the other route: one starts a folder, the
        // other takes on a folder you already keep.
        add(menu, "Take On a Folder…", #selector(AppDelegate.adoptArea), target: target, key: "")
        add(menu, "New Window", #selector(AppDelegate.newWindow), target: target, key: "n",
            modifiers: [.command, .option])
        add(menu, "New Tab", #selector(ProjectWindowController.newWindowForTab(_:)), target: nil, key: "t")
        menu.addItem(.separator())

        let recents = NSMenu(title: "Open Recent")
        let recentsItem = menu.addItem(withTitle: "Open Recent", action: nil, keyEquivalent: "")
        recentsItem.submenu = recents
        recents.delegate = target.recentProjectsMenuDelegate
        track(.quickGoToProject,
              add(menu, "Go to Project…", #selector(AppDelegate.quickGoToProject), target: target, key: ""))
        // Beside it, because it's the same errand at a finer grain: the two ways of going somewhere
        // without knowing which window you'd have to open to get there.
        track(.quickFindTask,
              add(menu, "Find a Task…", #selector(AppDelegate.quickFindTask), target: target, key: ""))
        add(menu, "All Projects…", #selector(AppDelegate.browseAllProjects), target: target, key: "o")
        // The project's own board, above the file-picker version, because it's the one you want
        // nearly every time — going looking for a canvas is the rarer errand of the two.
        add(menu, "Project Canvas", #selector(AppDelegate.projectCanvas), target: target, key: "c",
            modifiers: [.command, .shift])
        // ⇧⌘O rather than the ⌘O a document app would use: in PM, "open" already means a project, and
        // a canvas is a document you reach *from* a project far more often than you go looking for one.
        add(menu, "Open Canvas…", #selector(AppDelegate.openCanvas), target: target, key: "o",
            modifiers: [.command, .shift])
        menu.addItem(.separator())

        menu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let closeAll = menu.addItem(withTitle: "Close All Windows",
                                    action: #selector(AppDelegate.closeAllWindows), keyEquivalent: "w")
        closeAll.keyEquivalentModifierMask = [.command, .option]
        closeAll.target = target

        item.submenu = menu
        return item
    }

    // MARK: Edit

    /// Standard first-responder text editing. `undo:` / `redo:` reach the focused field editor's own
    /// undo while one is up, and the content's document-level ⌘Z otherwise (its hidden button sits
    /// behind these).
    private static func editMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Edit")
        menu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = menu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(.separator())
        menu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        // Answered by a canvas board and by nothing else, so it stays dim everywhere it means nothing.
        // Here rather than in a canvas-only menu because ⌘D belongs in Edit wherever it appears.
        menu.addItem(withTitle: "Duplicate", action: Selector(("duplicate:")), keyEquivalent: "d")
        menu.addItem(.separator())
        menu.addItem(findMenuItem())
        item.submenu = menu
        return item
    }

    /// Edit ▸ Find — the submenu Mac users open looking for search. Flattening ⌘F up into Edit would
    /// put it somewhere nobody looks for it.
    ///
    /// `performFindPanelAction:` is the standard Find selector, so all four items share it and are
    /// told apart by their `tag`, which is an `NSTextFinder.Action` raw value. That's AppKit's own
    /// convention for this menu, and it's what lets a focused text view claim ⌘E for its own selection
    /// before the window ever sees it. The action routes through the responder chain to whichever
    /// window is front (see `ProjectWindowController`), which validates each item for itself — Next and
    /// Previous stay dim until a search is actually narrowing the list.
    private static func findMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Find")
        let action = Selector(("performFindPanelAction:"))

        func add(_ title: String, _ finderAction: NSTextFinder.Action, key: String,
                 modifiers: NSEvent.ModifierFlags = [.command]) {
            let entry = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
            entry.tag = finderAction.rawValue
            entry.keyEquivalentModifierMask = modifiers
        }

        add("Find…", .showFindInterface, key: "f")
        // The find bar filters rather than highlighting in place, so "next match" means the next row
        // of the narrowed list — see `ProjectView.stepFind`. ⌘G / ⇧⌘G either way: what the keys mean
        // to the person pressing them is "show me the next one", and that's what they do.
        add("Find Next", .nextMatch, key: "g")
        add("Find Previous", .previousMatch, key: "g", modifiers: [.command, .shift])
        menu.addItem(.separator())
        // ⌘E. In a text field the field editor answers this and searches for what's selected there; in
        // the task list the window answers and searches for the selected task's text.
        add("Use Selection for Find", .setSearchString, key: "e")

        item.submenu = menu
        item.title = "Find"
        return item
    }

    // MARK: Help

    /// Help ▸. It held nothing at all — so the menu contained only the system's search field, which
    /// had no items to search and no help book behind it, and an app with a CLI, a URL scheme, an
    /// Obsidian convention and a domain-numbering scheme is not one with nothing to explain.
    ///
    /// Two items rather than a help book: the documentation already exists and is already maintained
    /// in the repository, and a bundled copy would be a second one to keep true. The shortcuts item is
    /// here because every global shortcut in this app is rebindable, so "what are the keys" is a
    /// question only the Shortcuts pane can answer.
    private static func fillHelpMenu(_ menu: NSMenu, target: AppDelegate) {
        let help = menu.addItem(withTitle: "PM Help", action: #selector(AppDelegate.openHelp),
                                keyEquivalent: "?")
        help.keyEquivalentModifierMask = [.command]
        help.target = target
        menu.addItem(.separator())
        let shortcuts = menu.addItem(withTitle: "Keyboard Shortcuts",
                                     action: #selector(AppDelegate.openShortcutsSettings),
                                     keyEquivalent: "")
        shortcuts.target = target
    }

    /// The four zoom commands a canvas window answers, routed through the responder chain so they are
    /// live when a board is in front and dim when it isn't.
    private static func canvasZoomItems(_ menu: NSMenu) {
        menu.addItem(.separator())
        let inn = menu.addItem(withTitle: "Zoom In", action: #selector(CanvasBoardView.zoomIn(_:)),
                               keyEquivalent: "+")
        inn.keyEquivalentModifierMask = [.command]
        let alt = menu.addItem(withTitle: "Zoom In", action: #selector(CanvasBoardView.zoomIn(_:)),
                               keyEquivalent: "=")
        alt.isAlternate = true
        alt.isHidden = true
        menu.addItem(withTitle: "Zoom Out", action: #selector(CanvasBoardView.zoomOut(_:)),
                     keyEquivalent: "-")
        menu.addItem(withTitle: "Actual Size", action: #selector(CanvasBoardView.zoomActualSize(_:)),
                     keyEquivalent: "0")
        menu.addItem(withTitle: "Zoom to Fit", action: #selector(CanvasBoardView.zoomToFit(_:)),
                     keyEquivalent: "9")
        menu.addItem(.separator())
    }

    /// The board's mode, as a checkmark.
    ///
    /// A checked item rather than two — "View Mode" and "Edit Mode" as a radio pair would be the same
    /// fact written twice, and this is a switch, not a choice between destinations. Routed to the board
    /// like the zoom items, so it is dim in a project window and its checkmark reflects the board in
    /// front of you rather than a global setting.
    ///
    /// ⇧⌘E, because plain ⌘E is Use Selection for Find, which every Mac text app has and this app has
    /// too — see the Find submenu.
    private static func canvasModeItem(_ menu: NSMenu) {
        let item = menu.addItem(withTitle: "Edit Mode",
                                action: #selector(CanvasBoardView.toggleEditMode(_:)),
                                keyEquivalent: "e")
        item.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(.separator())
    }

    // MARK: View

    private static func viewMenuItem(target: AppDelegate) -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "View")

        for (index, mode) in [TasksMode.incomplete, .all].enumerated() {
            let entry = add(menu, mode.menuTitle, #selector(AppDelegate.setTasksMode(_:)),
                            target: target, key: "\(index + 1)")
            entry.representedObject = mode.rawValue
        }
        menu.addItem(.separator())
        // The focus panel is a window, not a view mode — but this is where you'd look for it, next to
        // the list filters it replaced.
        // No key equivalent here: this item mirrors the *global* shortcut, which is rebindable, so
        // `syncGlobalShortcuts()` fills it in and keeps it current.
        track(.toggleFocusPanel,
              add(menu, "Show Focus Panel", #selector(AppDelegate.toggleFocusPanel),
                  target: target, key: ""))
        // Beside the focus panel because they are the app's two cross-project windows, answering the
        // same question from opposite ends: one is what you can do now, the other is what you can't
        // and who has it. ⌃⌘W rather than the ⌥⌘W the name asks for — that one is already File ▸
        // Close All Windows, and ⌃⌘ is where this app puts a third command on a taken letter (⌃⌘N is
        // New Project).
        add(menu, "Show Waiting", #selector(AppDelegate.toggleWaiting), target: target, key: "w",
            modifiers: [.command, .control])
        menu.addItem(.separator())
        add(menu, "Show Notes", #selector(AppDelegate.toggleNotes), target: target, key: "")
        // ⌥⌘S is the Finder/Mail "Show Sidebar" shortcut. `toggleSidebar:` is answered by the front
        // window's split view controller, so it animates and persists in one place.
        // Zoom, answered only by a canvas window — dim in a project window, where there is nothing to
        // zoom. ⌘= as well as ⌘+ because the plus is a shifted equals on most layouts and AppKit
        // matches the literal character.
        canvasZoomItems(menu)
        canvasModeItem(menu)
        add(menu, "Show Projects", #selector(NSSplitViewController.toggleSidebar(_:)), target: nil,
            key: "s", modifiers: [.command, .option])
        // With the other two "show me this" checkmarks rather than in the sidebar's arrange menu: it's
        // how the whole app writes a project's name, not how one list is arranged. See `ProjectCodes`.
        add(menu, "Show Project Codes", #selector(AppDelegate.toggleProjectCodes), target: target, key: "")
        menu.addItem(.separator())

        let appearance = NSMenu(title: "Appearance")
        let appearanceItem = menu.addItem(withTitle: "Appearance", action: nil, keyEquivalent: "")
        appearanceItem.submenu = appearance
        for mode in [AppColorMode.system, .light, .dark] {
            let entry = add(appearance, mode.menuTitle, #selector(AppDelegate.setColorMode(_:)),
                            target: target, key: "")
            entry.representedObject = mode.rawValue
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)),
                     keyEquivalent: "f").keyEquivalentModifierMask = [.command, .control]

        item.submenu = menu
        return item
    }

    // MARK: Task and Project

    /// The two domain menus, generated from `PMCommand`.
    ///
    /// They used to be one four-item Task menu written out by hand, while the menu extra's submenus and
    /// the quick bar's `>` list each declared their own — so eleven commands the other two surfaces
    /// offered had no home in the menu bar at all, and there was no Project menu despite a fully-formed
    /// `Project ▸` submenu existing in the dropdown. Reading the table means a command added there
    /// appears here without anyone remembering to come and add it, and means the name it appears under
    /// is the same name every other surface uses.
    private static func domainMenuItem(_ section: PMCommand.MenuSection, title: String,
                                       target: AppDelegate) -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: title)
        // Validation and titles are live — see `AppDelegate.menuNeedsUpdate` — because a command's
        // availability, and the editor command's name, depend on what's focused right now.
        menu.delegate = target
        for command in PMCommand.menu(section) {
            if command.startsMenuGroup, menu.numberOfItems > 0 { menu.addItem(.separator()) }
            let entry = add(menu, command.title, #selector(AppDelegate.runCommand(_:)), target: target,
                            key: command.keyEquivalent?.key ?? "",
                            modifiers: command.keyEquivalent?.modifiers ?? [.command])
            entry.representedObject = command.rawValue
        }
        item.submenu = menu
        return item
    }

    // MARK: Global shortcuts

    /// The menu items that mirror a global shortcut, held so their key equivalents can follow the
    /// bindings. Weak: the menu owns them, and this outlives a rebuilt menu bar.
    private static var mirroredItems: [HotKeyAction: WeakMenuItem] = [:]

    private struct WeakMenuItem {
        weak var item: NSMenuItem?
    }

    @discardableResult
    private static func track(_ action: HotKeyAction, _ item: NSMenuItem) -> NSMenuItem {
        mirroredItems[action] = WeakMenuItem(item: item)
        return item
    }

    /// Show whatever each of these commands is currently bound to next to its menu item.
    ///
    /// A global hotkey fires whether or not PM is in front, so while PM *is* in front the menu item and
    /// the shortcut are the same gesture — and a menu that still advertised ⌃⌥P after you rebound it
    /// would be telling you something untrue about your own keyboard. An unbound command shows no
    /// shortcut at all rather than a stale one.
    static func syncGlobalShortcuts() {
        for (action, box) in mirroredItems {
            guard let item = box.item else { continue }
            if let equivalent = HotKeyManager.shared.binding(for: action)?.menuKeyEquivalent {
                item.keyEquivalent = equivalent.key
                item.keyEquivalentModifierMask = equivalent.modifiers
            } else {
                item.keyEquivalent = ""
                item.keyEquivalentModifierMask = []
            }
        }
    }

    // MARK: Helper

    @discardableResult
    private static func add(_ menu: NSMenu, _ title: String, _ action: Selector, target: AnyObject?,
                            key: String, modifiers: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        if !key.isEmpty { item.keyEquivalentModifierMask = modifiers }
        item.target = target
        return item
    }
}

extension TasksMode {
    var menuTitle: String {
        switch self {
        case .incomplete: return "Incomplete Tasks"
        case .all: return "All Tasks"
        }
    }
}

extension AppColorMode {
    var menuTitle: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}
