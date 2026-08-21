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
        mainMenu.addItem(taskMenuItem(target: target))

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)

        let helpItem = NSMenuItem()
        let helpMenu = NSMenu(title: "Help")
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
        // ⇧⌘N starts today's session and opens its note — the sibling of New Task one level up, and
        // what replaced the "New session" button that used to sit in the list.
        add(menu, "New Session", #selector(ProjectWindowController.newSession), target: nil, key: "n",
            modifiers: [.command, .shift])
        // ⌃⌘N: the third "new" in the File menu, after the task and the session it sits above in scale.
        track(.quickCapture,
              add(menu, "Quick Add Task…", #selector(AppDelegate.quickCapture), target: target, key: ""))
        add(menu, "New Project…", #selector(AppDelegate.newProject), target: target, key: "n",
            modifiers: [.command, .control])
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
        add(menu, "All Projects…", #selector(AppDelegate.browseAllProjects), target: target, key: "o")
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
        menu.addItem(.separator())
        menu.addItem(findMenuItem())
        item.submenu = menu
        return item
    }

    /// Edit ▸ Find. A submenu with one item today, but it's the submenu Mac users open looking for
    /// search — flattening ⌘F up into Edit would put it somewhere nobody looks for it.
    ///
    /// `performFindPanelAction:` is the standard Find selector, so it routes through the responder
    /// chain to whichever window is front (see `ProjectWindowController`) and disables itself when no
    /// window can answer it.
    private static func findMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Find")
        menu.addItem(withTitle: "Find…", action: Selector(("performFindPanelAction:")), keyEquivalent: "f")
        item.submenu = menu
        item.title = "Find"
        return item
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
        menu.addItem(.separator())
        add(menu, "Show Notes", #selector(AppDelegate.toggleNotes), target: target, key: "")
        // ⌥⌘S is the Finder/Mail "Show Sidebar" shortcut. `toggleSidebar:` is answered by the front
        // window's split view controller, so it animates and persists in one place.
        add(menu, "Show Projects", #selector(NSSplitViewController.toggleSidebar(_:)), target: nil,
            key: "s", modifiers: [.command, .option])
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

    // MARK: Task

    /// The domain menu — the actions the menubar item and the row context menus already offer, given a
    /// home in the menu bar where they're discoverable and carry their shortcuts.
    private static func taskMenuItem(target: AppDelegate) -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Task")
        add(menu, "Complete Focused Task", #selector(AppDelegate.completeFocused), target: target,
            key: "\r", modifiers: [.command, .shift])
        add(menu, "Undo Last Completion", #selector(AppDelegate.undoLastCompletion), target: target, key: "")
        menu.addItem(.separator())
        add(menu, "Dive In", #selector(AppDelegate.diveInCommand), target: target, key: "d",
            modifiers: [.command, .shift])
        menu.addItem(.separator())
        add(menu, "Reveal Project in Finder", #selector(AppDelegate.revealProject), target: target,
            key: "r", modifiers: [.command, .shift])
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
