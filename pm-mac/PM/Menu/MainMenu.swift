import AppKit
import PmLib

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
///     while a text field is focused they route to its field editor and edit the text. Nothing in a
///     project window claims those keys ahead of the menu any more: the board answers them from the
///     responder chain (`CanvasBoardView+Commands`), which a focused text view is already ahead of.
///     A SwiftUI `.keyboardShortcut` would not be — AppKit offers a key equivalent to the key *window*
///     before this menu — which is why the task column had to be told to stand down by hand, and why
///     nothing here should grow one.
///   * Everything window-shaped targets `nil` too, so it walks the responder chain and lands on the
///     `ProjectWindowController` of whichever window is in front — `toggleSidebar:` is answered by the
///     split view controller, the rest by the window controller. App-wide items target the delegate.
@MainActor
enum MainMenu {
    static func install(target: AppDelegate) {
        // `PageFirstMenu`, not `NSMenu`: while you are standing in a web card the page is offered a
        // keystroke before this bar claims it, so ⌘Z is the page's undo rather than the board's.
        // Everything the page doesn't want comes straight back here, and Reload waits for a second
        // press — see `CanvasPageKeys` and `DoubleTap`.
        let mainMenu = PageFirstMenu()
        mainMenu.addItem(appMenuItem(target: target))
        mainMenu.addItem(fileMenuItem(target: target))
        mainMenu.addItem(editMenuItem())
        mainMenu.addItem(formatMenuItem())
        mainMenu.addItem(viewMenuItem(target: target))
        mainMenu.addItem(goMenuItem(target: target))
        mainMenu.addItem(canvasMenuItem())
        mainMenu.addItem(domainMenuItem(.task, title: "Task", target: target))
        mainMenu.addItem(domainMenuItem(.project, title: "Project", target: target))

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        fillWindowMenu(windowMenu, target: target)
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

    // MARK: Folio

    private static func appMenuItem(target: AppDelegate) -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Folio")

        menu.addItem(withTitle: "About Folio", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                     keyEquivalent: "")
        menu.addItem(.separator())
        add(menu, "Settings…", #selector(AppDelegate.openSettings), target: target, key: ",")
        menu.addItem(.separator())

        let services = NSMenu(title: "Services")
        let servicesItem = menu.addItem(withTitle: "Services", action: nil, keyEquivalent: "")
        servicesItem.submenu = services
        NSApp.servicesMenu = services
        menu.addItem(.separator())

        menu.addItem(withTitle: "Hide Folio", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = menu.addItem(withTitle: "Hide Others",
                                      action: #selector(NSApplication.hideOtherApplications(_:)),
                                      keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)),
                     keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Folio", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        item.submenu = menu
        return item
    }

    // MARK: File

    /// Things you make, then things you open, then closing. Summoning the quick bar is Go's and Task's,
    /// and a project's canvas in a window of its own is ⇧ on Go ▸ Canvas.
    private static func fileMenuItem(target: AppDelegate) -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "File")

        // ⌘N makes the app's primary content, ⌥⌘N makes a window — Mail's split, and the one that keeps
        // ⌘T free for the standard New Tab.
        add(menu, "New Task", #selector(ProjectWindowController.newTask), target: nil, key: "n")
        // ⇧⌘N opens the current session's note, starting a session first when there isn't one to
        // continue. Under ⌥, a new sitting outright (docs/tile-sessions.md D1).
        add(menu, "New Session", #selector(ProjectWindowController.newSession), target: nil, key: "n",
            modifiers: [.command, .shift])
        add(menu, "Start a New Session", #selector(ProjectWindowController.startNewSession), target: nil,
            key: "n", modifiers: [.command, .shift, .option]).isAlternate = true
        // The front canvas's add commands, filled as the menu opens — see `CanvasNewCardMenu`.
        let cards = NSMenu(title: "New Card")
        cards.delegate = CanvasNewCardMenu.shared
        menu.addItem(withTitle: "New Card", action: nil, keyEquivalent: "").submenu = cards
        menu.addItem(.separator())
        add(menu, "New Project…", #selector(AppDelegate.newProject), target: target, key: "n",
            modifiers: [.command, .control])
        add(menu, "New Area…", #selector(AppDelegate.newArea), target: target, key: "")
        add(menu, "Take On a Folder…", #selector(AppDelegate.adoptArea), target: target, key: "")
        menu.addItem(.separator())
        add(menu, "New Window", #selector(AppDelegate.newWindow), target: target, key: "n",
            modifiers: [.command, .option])
        // Another view of the project this window is showing — see `ProjectTab`.
        add(menu, "New Tab", #selector(ProjectWindowController.newProjectTab(_:)), target: nil, key: "t")
        menu.addItem(.separator())

        // ⌘O is a project: in Folio, "open" means a project, and a canvas file is the rarer errand.
        add(menu, "Open Project…", #selector(AppDelegate.browseAllProjects), target: target, key: "o")
        let recents = NSMenu(title: "Open Recent")
        menu.addItem(withTitle: "Open Recent", action: nil, keyEquivalent: "").submenu = recents
        recents.delegate = target.recentProjectsMenuDelegate
        add(menu, "Open Canvas File…", #selector(AppDelegate.openCanvas), target: target, key: "o",
            modifiers: [.command, .shift])
        menu.addItem(.separator())

        // ⌘W is the tab you are in, and the window once that was the last one — see
        // `TextFocusWindow.performClose`. ⇧⌘W is the window whatever it holds; ⌥ closes them all.
        menu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let closeAll = add(menu, "Close All", #selector(AppDelegate.closeAllWindows), target: target,
                           key: "w", modifiers: [.command, .option])
        closeAll.isAlternate = true
        add(menu, "Close Window", #selector(ProjectWindowController.closeProjectWindow(_:)),
            target: nil, key: "w", modifiers: [.command, .shift])

        item.submenu = menu
        return item
    }

    // MARK: Edit

    /// Standard first-responder text editing. `undo:` / `redo:` reach the focused field editor's own
    /// undo while one is up, and the content's document-level ⌘Z otherwise. What a canvas does to its
    /// cards is in Canvas.
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
        // Answered by a canvas and by nothing else, so dim everywhere it means nothing. ⌘D is Edit's
        // wherever it appears.
        menu.addItem(withTitle: "Duplicate", action: Selector(("duplicate:")), keyEquivalent: "d")
        menu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        menu.addItem(.separator())
        menu.addItem(findMenuItem())
        item.submenu = menu
        return item
    }

    /// Format: the note editor's line commands, where a Mac user looks for them. See `EditorLineCommand`.
    ///
    /// **It shows keys it doesn't claim.** A main-menu item takes its key equivalent even while it is
    /// disabled, so a menu here holding ⌥↑ would swallow ⌥↑ everywhere no editor has the caret — on the
    /// board, in a list. The editor handles these keys itself; this menu is where they are written down
    /// (see `EditorMenuKeys`), and a click on an item still reaches the editor through the responder chain.
    private static func formatMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Format")
        menu.delegate = EditorMenuKeys.shared
        func add(_ command: EditorLineCommand, to menu: NSMenu) {
            // No key here — `EditorMenuKeys` writes it in while the menu is open.
            let entry = menu.addItem(withTitle: command.title, action: command.action, keyEquivalent: "")
            if case .heading(let level) = command { entry.tag = level }
        }
        for command: EditorLineCommand in [.bold, .italic, .link] { add(command, to: menu) }
        menu.addItem(.separator())
        let headings = NSMenu(title: "Heading")
        headings.delegate = EditorMenuKeys.shared
        for level in 0...6 { add(.heading(level), to: headings) }
        menu.addItem(withTitle: "Heading", action: nil, keyEquivalent: "").submenu = headings
        add(.toggleTask, to: menu)
        menu.addItem(.separator())
        for command: EditorLineCommand in [.moveUp, .moveDown, .copyUp, .copyDown, .delete,
                                           .insertBelow, .insertAbove, .join] {
            add(command, to: menu)
        }
        menu.addItem(.separator())
        add(.expandSelection, to: menu)
        add(.shrinkSelection, to: menu)
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
        // of the narrowed list — see `CanvasProjectNote.stepFind`. ⌘G / ⇧⌘G either way: what the keys mean
        // to the person pressing them is "show me the next one", and that's what they do.
        add("Find Next", .nextMatch, key: "g")
        add("Find Previous", .previousMatch, key: "g", modifiers: [.command, .shift])
        menu.addItem(.separator())
        // ⌘E. In a text field the field editor answers this and searches for what's selected there; in
        // a web card the board's pane answers with the page's selected text.
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
        let help = menu.addItem(withTitle: "Folio Help", action: #selector(AppDelegate.openHelp),
                                keyEquivalent: "?")
        help.keyEquivalentModifierMask = [.command]
        help.target = target
        menu.addItem(.separator())
        let shortcuts = menu.addItem(withTitle: "Keyboard Shortcuts",
                                     action: #selector(AppDelegate.openShortcutsSettings),
                                     keyEquivalent: "")
        shortcuts.target = target
    }

    // MARK: View

    /// How things are shown, and nothing else: places are Go's, what you do to cards is Canvas's, the
    /// panels are windows and are Window's, and Appearance is in Settings ▸ General.
    private static func viewMenuItem(target: AppDelegate) -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "View")

        // ⌃⌘S, the HIG's Show Sidebar. `toggleSidebar:` is answered by the front window's split view
        // controller, so it animates and persists in one place.
        add(menu, "Show Sidebar", #selector(NSSplitViewController.toggleSidebar(_:)), target: nil,
            key: "s", modifiers: [.command, .control])
        // How the whole app writes a project's name. See `ProjectCodes`.
        add(menu, "Show Project Codes", #selector(AppDelegate.toggleProjectCodes), target: target, key: "")
        menu.addItem(.separator())

        // How the canvas is drawn (docs/items.md D5). ⌥⌘1…3: the Finder spends ⌘1…4 on the same
        // question, and here ⌘1…9 are Go's tabs. Answered by the pane showing the canvas, so the tick
        // is that canvas's lens.
        menu.addItem(.sectionHeader(title: "Show Canvas As"))
        for lens in CanvasPresentation.allCases {
            let entry = menu.addItem(withTitle: lens.name,
                                     action: #selector(CanvasPaneController.showCanvasAs(_:)),
                                     keyEquivalent: lens.keyEquivalent)
            entry.keyEquivalentModifierMask = [.command, .option]
            entry.representedObject = lens
        }
        // The order a list or grid reads in (docs/items.md D4); dim while the canvas is freeform.
        let sorts = NSMenu(title: "Sort By")
        menu.addItem(withTitle: "Sort By", action: nil, keyEquivalent: "").submenu = sorts
        for order in CanvasItemSort.allCases {
            let entry = sorts.addItem(withTitle: order.title,
                                      action: #selector(CanvasPaneController.sortCanvasBy(_:)),
                                      keyEquivalent: "")
            entry.representedObject = order
        }
        menu.addItem(.separator())

        // Answered only by a canvas. ⌘= as well as ⌘+ because the plus is a shifted equals on most
        // layouts and AppKit matches the literal character. ⇧1 and ⇧2 are the board's own keys for
        // the two fits — see `CanvasBoardKeys.fit`.
        menu.addItem(withTitle: "Zoom In", action: #selector(CanvasBoardView.zoomIn(_:)), keyEquivalent: "+")
        let alt = menu.addItem(withTitle: "Zoom In", action: #selector(CanvasBoardView.zoomIn(_:)),
                               keyEquivalent: "=")
        alt.isAlternate = true
        alt.isHidden = true
        menu.addItem(withTitle: "Zoom Out", action: #selector(CanvasBoardView.zoomOut(_:)), keyEquivalent: "-")
        menu.addItem(withTitle: "Actual Size", action: #selector(CanvasBoardView.zoomActualSize(_:)),
                     keyEquivalent: "0")
        menu.addItem(withTitle: "Zoom to Fit", action: #selector(CanvasBoardView.zoomToFit(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Zoom to Selection", action: #selector(CanvasBoardView.zoomToSelection(_:)),
                     keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)),
                     keyEquivalent: "f").keyEquivalentModifierMask = [.command, .control]

        item.submenu = menu
        return item
    }

    // MARK: Go

    /// Places: a project, a task, this window's tabs, a frame on its canvas — the Finder's and
    /// Safari's menu for going somewhere.
    ///
    /// **The tabs are one list.** A workspace is a tab, so it is here once, by name, and not again
    /// under a Workspace ▸. The slots are built once and retitled on validation; the ones with nothing
    /// behind them are hidden while the menu is open — see `SlotMenu`.
    private static func goMenuItem(target: AppDelegate) -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Go")
        menu.delegate = SlotMenu.shared

        // The quick bar's two ways of going somewhere. Their keys are the global shortcuts, which are
        // rebindable, so `syncGlobalShortcuts()` writes them in.
        track(.quickGoToProject,
              add(menu, "Project…", #selector(AppDelegate.quickGoToProject), target: target, key: ""))
        track(.quickFindTask, add(menu, "Task…", #selector(AppDelegate.quickFindTask), target: target, key: ""))
        // The project the menu bar extra, the CLI and the focus panel are on.
        let focused = add(menu, "Focused Project", #selector(AppDelegate.runCommand(_:)),
                          target: target, key: "")
        focused.representedObject = PMCommand.openWindow.rawValue
        menu.addItem(.separator())

        // The canvas tab, and the way out of a workspace: ⌥⌘C from anywhere else goes to it, and from
        // the canvas back to the notes. ⇧ swaps in a window of its own.
        add(menu, "Canvas", #selector(ProjectWindowController.toggleCanvasRenderer(_:)),
            target: nil, key: "c", modifiers: [.command, .option])
        add(menu, "Canvas in New Window", #selector(AppDelegate.projectCanvas), target: target,
            key: "c", modifiers: [.command, .shift]).isAlternate = true
        // ⌘1…⌘9, which every browser on this Mac spends on exactly this; ⌘9 is the last tab however
        // long the row is. See `ProjectWindowController.selectProjectTabByIndex`.
        for index in 0..<9 {
            let entry = add(menu, index == 8 ? "Last Tab" : "Tab \(index + 1)",
                            #selector(ProjectWindowController.selectProjectTabByIndex(_:)),
                            target: nil, key: "\(index + 1)")
            entry.tag = index
        }
        // ⌃⇥ and ⌃⇧⇥ are the standard pair, free since project windows turned native tabbing off.
        add(menu, "Next Tab", #selector(ProjectWindowController.selectNextProjectTab(_:)),
            target: nil, key: "\t", modifiers: [.control])
        add(menu, "Previous Tab", #selector(ProjectWindowController.selectPreviousProjectTab(_:)),
            target: nil, key: "\t", modifiers: [.control, .shift])
        menu.addItem(.separator())

        // ⌃1…9 goes to a frame — somewhere on the canvas, fitted in the window. ⌃ rather than ⌘ is what
        // tells a frame from a tab.
        let frames = NSMenu(title: "Frame")
        frames.delegate = SlotMenu.shared
        for index in 0..<9 {
            let entry = frames.addItem(withTitle: "Frame \(index + 1)",
                                       action: #selector(CanvasBoardView.goToFrame(_:)),
                                       keyEquivalent: "\(index + 1)")
            entry.keyEquivalentModifierMask = [.control]
            entry.tag = index
        }
        menu.addItem(withTitle: "Frame", action: nil, keyEquivalent: "").submenu = frames

        item.submenu = menu
        return item
    }

    // MARK: Canvas

    /// What you do to cards, to a workspace, and to a web card's page, under three headers. Every item
    /// is answered by the canvas in front, so the whole menu is dim in a window showing notes. The
    /// contextual menus call the same selectors (docs: the menu bar is the complete command list).
    private static func canvasMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Canvas")

        menu.addItem(.sectionHeader(title: "Cards"))
        // The selected cards' contextual menu, opened under the header's `…` — see `showCardActions`.
        let actions = menu.addItem(withTitle: "Card Actions",
                                   action: #selector(CanvasBoardView.showCardActions(_:)), keyEquivalent: "\r")
        actions.keyEquivalentModifierMask = [.control]
        // Figma's Tidy Up key.
        let tidy = menu.addItem(withTitle: "Tidy Up", action: Selector(("tidyUp:")), keyEquivalent: "t")
        tidy.keyEquivalentModifierMask = [.control, .option]
        menu.addItem(withTitle: "Size", action: nil, keyEquivalent: "").submenu = CanvasBoardView.sizeMenu()
        // The canvas's one mode, as a checkmark. ⇧⌘E kept from when it was Edit Mode.
        let connect = menu.addItem(withTitle: "Connect Cards",
                                   action: #selector(CanvasBoardView.toggleConnectMode(_:)), keyEquivalent: "e")
        connect.keyEquivalentModifierMask = [.command, .shift]

        menu.addItem(.sectionHeader(title: "Workspace"))
        workspaceItems(menu)

        menu.addItem(.sectionHeader(title: "Page"))
        pageItems(menu)

        item.submenu = menu
        return item
    }

    /// Making a workspace, arranging it, and what its focused tile can be told. Each tile command acts
    /// on the focused tile, so each is dim unless exactly one is focused — see `focusedTile`.
    private static func workspaceItems(_ menu: NSMenu) {
        menu.addItem(withTitle: "New Workspace", action: #selector(CanvasBoardView.tileSelection(_:)),
                     keyEquivalent: "")
        let arrange = NSMenu(title: "Arrange")
        for arrangement in CanvasTiling.Arrangement.allCases {
            let entry = arrange.addItem(withTitle: arrangement.title,
                                        action: #selector(CanvasBoardView.setTileArrangement(_:)),
                                        keyEquivalent: "")
            entry.representedObject = arrangement.rawValue
        }
        // ⌥⇧0 is the board's key rather than this item's — see `CanvasBoardView.tilingTakes`.
        arrange.addItem(.separator())
        arrange.addItem(withTitle: "Size Columns to Content",
                        action: #selector(CanvasBoardView.sizeColumnsToContent(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Arrange", action: nil, keyEquivalent: "").submenu = arrange
        // Fill the room with one tile and put the workspace back after. The ⌥ layer is one pages don't
        // claim, which matters when the tiles are web apps.
        let maximize = menu.addItem(withTitle: "Maximize Tile", action: #selector(CanvasBoardView.maximizeTile(_:)),
                                    keyEquivalent: "\r")
        maximize.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(withTitle: "Make Master Tile", action: #selector(CanvasBoardView.promoteTile(_:)),
                     keyEquivalent: "")
        menu.addItem(withTitle: "Pin Tile Width", action: #selector(CanvasBoardView.togglePinTileSize(_:)),
                     keyEquivalent: "")
        // Remove's other half; the board's list, filled as it opens — see `CanvasExistingCardsMenu`.
        let existing = NSMenu(title: CanvasExistingCards.title)
        existing.delegate = CanvasExistingCardsMenu.shared
        menu.addItem(withTitle: CanvasExistingCards.title, action: nil, keyEquivalent: "").submenu = existing
        // The same, by where the cards sit — ⌥B on the canvas. Retitled while it is up.
        menu.addItem(withTitle: "Pick Cards on Canvas", action: #selector(CanvasBoardView.pickCardsOnBoard(_:)),
                     keyEquivalent: "")
        // Rename with no Name beside it: a workspace is made named (docs/canvas-workspaces.md §7i).
        menu.addItem(withTitle: "Rename Workspace\u{2026}", action: #selector(CanvasBoardView.renameWorkspace(_:)),
                     keyEquivalent: "")
        menu.addItem(withTitle: "Duplicate Workspace\u{2026}",
                     action: #selector(CanvasBoardView.duplicateWorkspace(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Remove from Workspace", action: #selector(CanvasBoardView.removeTile(_:)),
                     keyEquivalent: "")
        menu.addItem(withTitle: "Delete Workspace", action: #selector(CanvasBoardView.deleteWorkspace(_:)),
                     keyEquivalent: "")
    }

    /// A web card's page. The browser keys stay at the top level — ⌘[ ⌘] ⌘R ⌘L are what every browser
    /// on this Mac uses — and the rest go one level down.
    private static func pageItems(_ menu: NSMenu) {
        menu.addItem(withTitle: "Back", action: #selector(CanvasBoardView.pageBack(_:)), keyEquivalent: "[")
        menu.addItem(withTitle: "Forward", action: #selector(CanvasBoardView.pageForward(_:)), keyEquivalent: "]")
        menu.addItem(withTitle: "Reload Page", action: #selector(CanvasBoardView.pageReload(_:)), keyEquivalent: "r")
        // Under ⌥: revalidate everything rather than trust the cache — the button's ⌥-click too.
        let hardReload = menu.addItem(withTitle: "Hard Reload", action: #selector(CanvasBoardView.pageHardReload(_:)),
                                      keyEquivalent: "r")
        hardReload.keyEquivalentModifierMask = [.command, .option]
        hardReload.isAlternate = true
        menu.addItem(withTitle: "Open Address\u{2026}", action: #selector(CanvasBoardView.pageOpenAddress(_:)),
                     keyEquivalent: "l")

        let more = NSMenu(title: "More Page Commands")
        // Back to the address the canvas saved for this card, which is not "what was I looking at before".
        more.addItem(withTitle: "Back to Card\u{2019}s Address", action: #selector(CanvasBoardView.pageHome(_:)),
                     keyEquivalent: "")
        more.addItem(withTitle: "Open in Browser", action: #selector(CanvasBoardView.pageOpenInBrowser(_:)),
                     keyEquivalent: "")
        more.addItem(withTitle: "Open Page as New Card", action: #selector(CanvasBoardView.pageOpenAsNewCard(_:)),
                     keyEquivalent: "")
        more.addItem(.separator())
        // How stale the canvas may get — a property of the canvas, not of a card.
        let refresh = NSMenu(title: "Refresh Pages")
        refresh.addItem(withTitle: "Never", action: #selector(CanvasBoardView.setPageRefresh(_:)),
                        keyEquivalent: "").representedObject = 0.0
        refresh.addItem(.separator())
        for seconds in CanvasBoardView.refreshChoices {
            let minutes = Int(seconds / 60)
            refresh.addItem(withTitle: minutes == 1 ? "Every Minute" : "Every \(minutes) Minutes",
                            action: #selector(CanvasBoardView.setPageRefresh(_:)),
                            keyEquivalent: "").representedObject = seconds
        }
        more.addItem(withTitle: "Refresh Pages", action: nil, keyEquivalent: "").submenu = refresh
        menu.addItem(withTitle: "More Page Commands", action: nil, keyEquivalent: "").submenu = more
    }

    // MARK: Window

    /// The two panels are windows, so they are listed here with a checkmark, the way Mail lists
    /// Activity. AppKit adds Minimize, Zoom, Bring All to Front and the window list around them.
    private static func fillWindowMenu(_ menu: NSMenu, target: AppDelegate) {
        // The focus panel's key is the global shortcut, which is rebindable — `syncGlobalShortcuts()`.
        track(.toggleFocusPanel, add(menu, "Focus Panel", #selector(AppDelegate.toggleFocusPanel),
                                     target: target, key: ""))
        // ⌃⌘W: ⌥⌘W is Close All.
        add(menu, "Waiting", #selector(AppDelegate.toggleWaiting), target: target, key: "w",
            modifiers: [.command, .control])
        menu.addItem(.separator())
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
        // Each menu opens with the quick bar's way in to it: a line for a task, prose for the project's
        // session. Their keys are the global shortcuts — see `syncGlobalShortcuts()`.
        switch section {
        case .task:
            track(.quickCapture, add(menu, "Quick Add Task…", #selector(AppDelegate.quickCapture),
                                     target: target, key: ""))
        case .project:
            track(.quickNote, add(menu, "Write Session Note…", #selector(AppDelegate.quickNote),
                                  target: target, key: ""))
        }
        menu.addItem(.separator())
        for command in PMCommand.menu(section) {
            if command.startsMenuGroup { menu.addItem(.separator()) }
            let entry = add(menu, command.title, #selector(AppDelegate.runCommand(_:)), target: target,
                            key: command.keyEquivalent?.key ?? "",
                            modifiers: command.keyEquivalent?.modifiers ?? [.command])
            entry.representedObject = command.rawValue
            // Add Before is ⌥ on Add After, as Finder's Close All is ⌥ on Close.
            if command == .addBefore {
                entry.keyEquivalentModifierMask = [.command, .option]
                entry.isAlternate = true
            }
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

extension AppColorMode {
    var menuTitle: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

/// Go's numbered slots — tabs and frames — show only the ones with something behind them.
///
/// The slots are built once and retitled by validation, so their keys are always registered. Hiding
/// happens only while the menu is open and is undone as it closes: a hidden item takes no key
/// equivalent, and ⌘3 has to work for a third tab opened since the menu was last looked at.
@MainActor
final class SlotMenu: NSObject, NSMenuDelegate {
    static let shared = SlotMenu()

    private static let slotActions: Set<Selector> = [
        #selector(ProjectWindowController.selectProjectTabByIndex(_:)),
        #selector(CanvasBoardView.goToFrame(_:)),
    ]

    func menuWillOpen(_ menu: NSMenu) {
        menu.update()
        for item in menu.items where item.action.map(Self.slotActions.contains) == true {
            item.isHidden = !item.isEnabled
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        for item in menu.items where item.action.map(Self.slotActions.contains) == true {
            item.isHidden = false
        }
    }
}

/// File ▸ New Card: the front canvas's add commands, the list its `+` and a right-click offer.
@MainActor
final class CanvasNewCardMenu: NSObject, NSMenuDelegate {
    static let shared = CanvasNewCardMenu()

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let board = NSApp.target(forAction: #selector(CanvasBoardView.tidyUp(_:)), to: nil, from: nil)
            as? CanvasBoardView
        board?.fillNewCardMenu(menu)
        // The menu bar can't leave the item out the way a contextual menu does, so it says why.
        if menu.items.isEmpty {
            menu.addItem(withTitle: "No Canvas in Front", action: nil, keyEquivalent: "")
        }
    }
}
