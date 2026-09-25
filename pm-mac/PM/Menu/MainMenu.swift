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
        // Under ⌥, a new sitting outright rather than the one the idle window would join
        // (docs/tile-sessions.md D1).
        add(menu, "Start a New Session", #selector(ProjectWindowController.startNewSession), target: nil,
            key: "n", modifiers: [.command, .shift, .option]).isAlternate = true
        // ⌃⌘N: the third "new" in the File menu, after the task and the session it sits above in scale.
        track(.quickCapture,
              add(menu, "Quick Add Task…", #selector(AppDelegate.quickCapture), target: target, key: ""))
        // Under it, because it's the same summon with the other kind of thing to say: one files a line,
        // one opens somewhere to write.
        track(.quickNote,
              add(menu, "Write a Session Note…", #selector(AppDelegate.quickNote), target: target, key: ""))
        // Three groups, not one run of nine. Above: the things you put *into* a project. Here: the
        // containers themselves. Below: the windows you look at them through. The order inside each
        // group is the one the comments above argue for; the separators only say where one errand
        // stops and the next begins, which nine consecutive "new"s could not.
        menu.addItem(.separator())
        add(menu, "New Project…", #selector(AppDelegate.newProject), target: target, key: "n",
            modifiers: [.command, .control])
        // Directly under New Project, and without a shortcut of its own: it's the same errand for the
        // other kind of thing, and it's reached far less often than the project it sits beneath.
        add(menu, "New Area…", #selector(AppDelegate.newArea), target: target, key: "")
        // Under New Area because it makes the same thing by the other route: one starts a folder, the
        // other takes on a folder you already keep.
        add(menu, "Take On a Folder…", #selector(AppDelegate.adoptArea), target: target, key: "")
        menu.addItem(.separator())
        add(menu, "New Window", #selector(AppDelegate.newWindow), target: target, key: "n",
            modifiers: [.command, .option])
        // Beside New Window, and still ⌘T. What changed is what a tab *is*: another view of the
        // project this window is showing — its notes, its board, a frame on that board, an arrangement
        // of it — rather than another project in a native window tab. See `ProjectTab`.
        add(menu, "New Tab", #selector(ProjectWindowController.newProjectTab(_:)), target: nil, key: "t")
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
        //
        // Named for the window it makes. View ▸ Show Canvas puts the same board in the window you are
        // already in, and the two commands are a keystroke apart; before, both were called some form of
        // "canvas" and nothing in either name said which one you were about to get. Whether a command
        // makes a window is the whole of what distinguishes them, so it is what the names say.
        add(menu, "Open Project Canvas in New Window", #selector(AppDelegate.projectCanvas),
            target: target, key: "c", modifiers: [.command, .shift])
        // ⇧⌘O rather than the ⌘O a document app would use: in PM, "open" already means a project, and
        // a canvas is a document you reach *from* a project far more often than you go looking for one.
        add(menu, "Open Canvas…", #selector(AppDelegate.openCanvas), target: target, key: "o",
            modifiers: [.command, .shift])
        menu.addItem(.separator())

        // ⌘W is the tab you are in, and the window once that was the last one — see
        // `TextFocusWindow.performClose`, which is where the narrowing happens, since a second item
        // with the same key would never be reached past this one.
        menu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        // The window in one keystroke, whatever it is holding — the pair every Mac app with tabs
        // offers, and the reason ⌘W is safe to narrow.
        add(menu, "Close Window", #selector(ProjectWindowController.closeProjectWindow(_:)),
            target: nil, key: "w", modifiers: [.command, .shift])
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
        // Answered by a canvas board and by nothing else, so it stays dim everywhere it means nothing.
        // Here rather than in a canvas-only menu because ⌘D belongs in Edit wherever it appears — and
        // above Select All, which every Mac app puts last in this group.
        menu.addItem(withTitle: "Duplicate", action: Selector(("duplicate:")), keyEquivalent: "d")
        // Figma's Tidy Up key, and the same answerer: a board with a selection to lay out, dim elsewhere.
        let tidy = menu.addItem(withTitle: "Tidy Up", action: Selector(("tidyUp:")), keyEquivalent: "t")
        tidy.keyEquivalentModifierMask = [.control, .option]
        // Same answerer again; the menu is the board's own, so the two lists can't drift apart.
        menu.addItem(withTitle: "Size", action: nil, keyEquivalent: "").submenu = CanvasBoardView.sizeMenu()
        // The selected cards' contextual menu, opened under the header's `…` — see
        // `CanvasBoardView.showCardActions` for the key.
        let actions = menu.addItem(withTitle: "Show Card Actions",
                                   action: #selector(CanvasBoardView.showCardActions(_:)), keyEquivalent: "\r")
        actions.keyEquivalentModifierMask = [.control]
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

    /// The five zoom commands a board answers, routed through the responder chain so they are live when
    /// one is in front and dim when it isn't.
    private static func canvasZoomItems(_ menu: NSMenu) {
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
        // ⇧1 and ⇧2 are the board's keys rather than these items' equivalents — a shifted digit is a
        // character a card types. See `CanvasBoardKeys.fit`. ⌘9 was here, and was View ▸ Go to Tab's
        // Last Tab too, which sits above and took it.
        menu.addItem(withTitle: "Zoom to Fit", action: #selector(CanvasBoardView.zoomToFit(_:)),
                     keyEquivalent: "")
        menu.addItem(withTitle: "Zoom to Selection", action: #selector(CanvasBoardView.zoomToSelection(_:)),
                     keyEquivalent: "")
        menu.addItem(.separator())
    }

    /// Filling the window with a card, or with a handful of them.
    ///
    /// One command at both ends: with one card selected New Workspace is "show me this properly",
    /// which otherwise means zooming in and hunting for it, and with six it is a tiled view of the six.
    /// Escape backs out.
    private static func canvasTilingItems(_ menu: NSMenu) {
        // **No key equivalent, and it had ⌘↩.** Removed 2026-09-23: moving to and from the canvas is the
        // tab bar's, ⌘− and ⌥⌘C, and ⌘↩ goes back to the page in a web card.
        menu.addItem(withTitle: "New Workspace",
                     action: #selector(CanvasBoardView.tileSelection(_:)),
                     keyEquivalent: "")
        // **The temporary one.** New Workspace makes a workspace; this fills the room with a single
        // tile for as long as you want it and puts the workspace back afterwards — maximizing a window
        // rather than narrowing the view. The ⌥ layer is one of the few web pages do not claim, which
        // matters on a board whose tiles are web apps.
        let maximize = menu.addItem(withTitle: "Maximize Tile",
                                    action: #selector(CanvasBoardView.maximizeTile(_:)),
                                    keyEquivalent: "\r")
        maximize.keyEquivalentModifierMask = [.command, .option]
        let arrange = NSMenu(title: "Arrange Tiles")
        for arrangement in CanvasTiling.Arrangement.allCases {
            let entry = arrange.addItem(withTitle: arrangement.title,
                                        action: #selector(CanvasBoardView.setTileArrangement(_:)),
                                        keyEquivalent: "")
            entry.representedObject = arrangement.rawValue
        }
        // ⌥⇧0 is the board's key rather than this item's equivalent, for the reason every ⌥ tiling key
        // is — see `CanvasBoardView.tilingTakes`.
        arrange.addItem(.separator())
        arrange.addItem(withTitle: "Size Columns to Content",
                        action: #selector(CanvasBoardView.sizeColumnsToContent(_:)), keyEquivalent: "")
        let arrangeItem = menu.addItem(withTitle: "Arrange Tiles", action: nil, keyEquivalent: "")
        arrangeItem.submenu = arrange

        // **What a tile can be told, with no pointer involved.** These four were reachable only by
        // right-clicking a tile's handlebar — a 3.5pt bar out in the gap, which you had to already know
        // was a menu. The handlebar drags and does nothing else; the commands live here, where a menu
        // bar can be read through, and on the tile's own contextual menu. Each acts on the focused
        // tile, so each is dim unless exactly one is focused — see `CanvasBoardView.focusedTile`.
        // No key: ⇧⌘↩ is Task ▸ Complete, and View comes first in the bar, so this item held it.
        menu.addItem(withTitle: "Make This the Master Tile",
                     action: #selector(CanvasBoardView.promoteTile(_:)),
                     keyEquivalent: "")
        menu.addItem(withTitle: "Pin Tile Width",
                     action: #selector(CanvasBoardView.togglePinTileSize(_:)),
                     keyEquivalent: "")
        menu.addItem(withTitle: "Remove from Workspace",
                     action: #selector(CanvasBoardView.removeTile(_:)),
                     keyEquivalent: "")
        // Remove's other half. Its list is the board's, so it is filled as it opens rather than here —
        // see `CanvasExistingCardsMenu`.
        let existing = NSMenu(title: CanvasExistingCards.title)
        existing.delegate = CanvasExistingCardsMenu.shared
        menu.addItem(withTitle: CanvasExistingCards.title, action: nil, keyEquivalent: "").submenu = existing
        // The same, by where the cards sit rather than by name — ⌥B on the board itself. Retitled by
        // `validateUserInterfaceItem` to be the way back while it is up.
        menu.addItem(withTitle: "Pick Cards on Canvas",
                     action: #selector(CanvasBoardView.pickCardsOnBoard(_:)),
                     keyEquivalent: "")
        // No "Show Canvas" here: View ▸ Show Canvas (⌥⌘C) is the one, and it leaves a workspace too.

        // **The workspace's home that a menu bar can be read through.**
        //
        // Beside "Go to Frame" and out of the tile commands, which is where it used to sit. A tile's
        // menu is for what you do to a tile — promote it, pin it, drop it — and naming or deleting a
        // workspace is not one of those: it acts on the identity of the whole set. The two were one
        // group, and separating them is the boundary docs/canvas-workspaces.md §7c draws. Its
        // neighbour now is the other "go to a named set of cards", which is the thing it is actually
        // like.
        //
        // The chip in the tab bar is a workspace's real home — right-click is where a Mac keeps the
        // verbs for the thing under the pointer — and the pill's readout stands in for the chip in a
        // window with one tab. This is the copy that is always there, on the same principle as the tile
        // commands: the contextual surface for the thing you pointed at, the menu bar for the thing you
        // look up.
        //
        // Nine slots, retitled and dimmed on validation, exactly as "Go to Frame" below does it — a
        // menu bar is built once and the list it names changes under it.
        let workspaces = NSMenu(title: "Workspace")
        for index in 0..<9 {
            let entry = workspaces.addItem(withTitle: "Workspace \(index + 1)",
                                           action: #selector(CanvasBoardView.goToWorkspace(_:)),
                                           keyEquivalent: "")
            entry.tag = index
        }
        workspaces.addItem(.separator())
        // Rename, with no Name beside it: a workspace is made named (docs/canvas-workspaces.md §7i),
        // so there is never one in front of you waiting to be given a name.
        workspaces.addItem(withTitle: "Rename Workspace\u{2026}",
                           action: #selector(CanvasBoardView.renameWorkspace(_:)),
                           keyEquivalent: "")
        // Directly under it, because it is the item you wanted when Name would have been wrong: on a
        // named workspace Name renames, and making a second one is this.
        workspaces.addItem(withTitle: "Duplicate Workspace\u{2026}",
                           action: #selector(CanvasBoardView.duplicateWorkspace(_:)),
                           keyEquivalent: "")
        workspaces.addItem(.separator())
        workspaces.addItem(withTitle: "Delete Workspace",
                           action: #selector(CanvasBoardView.deleteWorkspace(_:)),
                           keyEquivalent: "")
        let workspacesItem = menu.addItem(withTitle: "Workspace", action: nil, keyEquivalent: "")
        workspacesItem.submenu = workspaces

        // ⌃1…9 goes to a frame — a region of the board, fitted in the window. Nine, because that is how
        // many a row of number keys holds and how many every manager that does this offers.
        //
        // ⌃ and not ⌘, and this is the one place the two words are told apart by a modifier: a frame is
        // somewhere on the board, a workspace is a way of looking at it. ⌘1…9 went to the tabs, which
        // is what it was being held for: backlog 17 said settle the navigation grammar first, and §7c
        // settled it when it decided a tab is where an open workspace lives — "go to workspace n" and
        // "go to tab n" stopped being two claimants on one key. See View ▸ Go to Tab.
        let frames = NSMenu(title: "Go to Frame")
        for index in 0..<9 {
            let entry = frames.addItem(withTitle: "Frame \(index + 1)",
                                       action: #selector(CanvasBoardView.goToFrame(_:)),
                                       keyEquivalent: "\(index + 1)")
            entry.keyEquivalentModifierMask = [.control]
            entry.tag = index
        }
        let framesItem = menu.addItem(withTitle: "Go to Frame", action: nil, keyEquivalent: "")
        framesItem.submenu = frames
        menu.addItem(.separator())
    }

    /// A web card's page: where it goes, and how often it goes back for more.
    ///
    /// **Every one of these existed only in a contextual menu or in a capsule that appears once you
    /// have already stepped into a card.** On a Mac, ⌘R meaning nothing while you are looking at a page
    /// is a genuine surprise — and the keys are the whole point of the submenu, since the items
    /// themselves were reachable. Back and Forward take ⌘[ and ⌘], Reload takes ⌘R and Open Address
    /// takes ⌘L, which is what every browser on the machine uses and none of which this app had spoken
    /// for.
    ///
    /// A submenu rather than a top-level Page menu: a page is one kind of card's content, and a menu
    /// bar that grew a whole heading for it would be claiming the app is a browser. Routed to the
    /// board, like the zoom and tiling items above, so all of it is dim in a project window showing a
    /// task list.
    private static func canvasPageItems(_ menu: NSMenu) {
        let page = NSMenu(title: "Page")
        let back = page.addItem(withTitle: "Back", action: #selector(CanvasBoardView.pageBack(_:)),
                                keyEquivalent: "[")
        back.keyEquivalentModifierMask = [.command]
        let forward = page.addItem(withTitle: "Forward",
                                   action: #selector(CanvasBoardView.pageForward(_:)),
                                   keyEquivalent: "]")
        forward.keyEquivalentModifierMask = [.command]
        page.addItem(withTitle: "Reload Page", action: #selector(CanvasBoardView.pageReload(_:)),
                     keyEquivalent: "r")
        // Under ⌥: revalidate everything rather than trust the cache — the button's ⌥-click too.
        let hardReload = page.addItem(withTitle: "Hard Reload",
                                      action: #selector(CanvasBoardView.pageHardReload(_:)),
                                      keyEquivalent: "r")
        hardReload.keyEquivalentModifierMask = [.command, .option]
        hardReload.isAlternate = true
        // The button a browser doesn't have: back to the address the *board* saved for this card,
        // which is a different question from "what was I looking at before".
        page.addItem(withTitle: "Back to Card\u{2019}s Address",
                     action: #selector(CanvasBoardView.pageHome(_:)), keyEquivalent: "")
        page.addItem(.separator())
        page.addItem(withTitle: "Open Address\u{2026}",
                     action: #selector(CanvasBoardView.pageOpenAddress(_:)), keyEquivalent: "l")
        page.addItem(withTitle: "Open in Browser",
                     action: #selector(CanvasBoardView.pageOpenInBrowser(_:)), keyEquivalent: "")
        page.addItem(withTitle: "Open Page as New Card",
                     action: #selector(CanvasBoardView.pageOpenAsNewCard(_:)), keyEquivalent: "")
        page.addItem(.separator())

        // How stale you are willing to let a board get. Here rather than on a card, because it is a
        // property of the board — a dashboard refreshes or it doesn't.
        let refresh = NSMenu(title: "Refresh Pages")
        let never = refresh.addItem(withTitle: "Never",
                                    action: #selector(CanvasBoardView.setPageRefresh(_:)),
                                    keyEquivalent: "")
        never.representedObject = 0.0
        refresh.addItem(.separator())
        for seconds in CanvasBoardView.refreshChoices {
            let minutes = Int(seconds / 60)
            let entry = refresh.addItem(withTitle: minutes == 1 ? "Every Minute"
                                                                : "Every \(minutes) Minutes",
                                        action: #selector(CanvasBoardView.setPageRefresh(_:)),
                                        keyEquivalent: "")
            entry.representedObject = seconds
        }
        let refreshItem = page.addItem(withTitle: "Refresh Pages", action: nil, keyEquivalent: "")
        refreshItem.submenu = refresh

        let item = menu.addItem(withTitle: "Page", action: nil, keyEquivalent: "")
        item.submenu = page
    }

    /// The board's one remaining mode, as a checkmark.
    ///
    /// Named for what it does rather than for a whole category of activity. It used to be "Edit Mode"
    /// and to gate colour, resizing, the ring and the grips as well as the connection dots; everything
    /// but the dots has since left, so the name was promising a great deal more than the switch
    /// delivered. See `CanvasMode`.
    ///
    /// A checked item rather than two — "View Mode" and "Connect Mode" as a radio pair would be the
    /// same fact written twice, and this is a switch, not a choice between destinations. Routed to the
    /// board like the zoom items, so it is dim in a project window and its checkmark reflects the board
    /// in front of you rather than a global setting.
    ///
    /// ⇧⌘E kept, though the name has changed: it is in people's hands, and the two commands are the
    /// same switch.
    /// View ▸ as Board / as List / as Grid: how the canvas is drawn (docs/items.md D5).
    ///
    /// **⌥⌘1…3, and the Finder's words.** It is the Finder's question — the same three shapes for the
    /// same contents — and the Finder spends ⌘1…4 on it. Here ⌘1…9 is Go to Tab, a reservation that is
    /// kept by somebody now, so the nod is the modifier the tabs left.
    ///
    /// Routed to the first responder like the zoom items, which means the pane showing the board:
    /// dim in a project window's task list, dim in a workspace, and its checkmark says which lens the
    /// board in front of you is being read through rather than a global setting.
    private static func canvasPresentationItems(_ menu: NSMenu) {
        for lens in CanvasPresentation.allCases {
            let item = menu.addItem(withTitle: lens.title,
                                    action: #selector(CanvasPaneController.showCanvasAs(_:)),
                                    keyEquivalent: lens.keyEquivalent)
            item.keyEquivalentModifierMask = [.command, .option]
            item.representedObject = lens
        }
        // The order the lenses read in (docs/items.md D4), in a submenu because it is four answers to
        // one question and because it is dimmed whole while a board is up.
        let sorts = NSMenu(title: "Sort Cards By")
        menu.addItem(withTitle: "Sort Cards By", action: nil, keyEquivalent: "").submenu = sorts
        for order in CanvasItemSort.allCases {
            let item = sorts.addItem(withTitle: order.title,
                                     action: #selector(CanvasPaneController.sortCanvasBy(_:)),
                                     keyEquivalent: "")
            item.representedObject = order
        }
        menu.addItem(.separator())
    }

    private static func canvasModeItem(_ menu: NSMenu) {
        let item = menu.addItem(withTitle: "Connect Cards",
                                action: #selector(CanvasBoardView.toggleConnectMode(_:)),
                                keyEquivalent: "e")
        item.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(.separator())
    }

    // MARK: View

    private static func viewMenuItem(target: AppDelegate) -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "View")

        // **Incomplete / All and Show Notes used to head this menu, on ⌘1, ⌘2 and no key.** All three
        // were switches on the task column, and the column went (§7f) — their defaults keys had no
        // reader left anywhere in the app, so the items toggled a checkmark and changed nothing. Two of
        // them were also sitting on ⌘1 and ⌘2 while the tiling work was carefully leaving ⌘1…9 unspent
        // for the tabs, which is a reservation kept by nobody. Go to Tab has them now.
        //
        // The focus panel is a window, not a view mode — but this is where you'd look for it.
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
        // Render the project window's content column as the project's board instead of its task list.
        // Routed to the window rather than the app, because it is a property of the window you are in.
        //
        // ⌥⌘C, not the ⇧⌘C on File ▸ Open Project Canvas in New Window: that one makes a second window,
        // and the two are genuinely different requests. Both can be up at once, on one shared document.
        add(menu, "Show Canvas", #selector(ProjectWindowController.toggleCanvasRenderer(_:)),
            target: nil, key: "c", modifiers: [.command, .option])
        menu.addItem(.separator())
        // A project window's tabs: the notes, the board, a frame on it, an arrangement of it — several
        // views of one project side by side. Routed to the window, like Show Canvas above and for the
        // same reason: it is a property of the window you are in.
        //
        // New Tab itself is in the File menu beside New Window, where a Mac app puts it. These three
        // are here because they are about the window in front of you rather than about making
        // something. ⌃⇥ and ⌃⇧⇥ are the standard pair and are free now that project windows have
        // turned native tabbing off — see `ProjectWindowController`.
        // No Close Tab: File ▸ Close (⌘W) closes the tab — see `TextFocusWindow.performClose`.
        add(menu, "Next Tab", #selector(ProjectWindowController.selectNextProjectTab(_:)),
            target: nil, key: "\t", modifiers: [.control])
        add(menu, "Previous Tab", #selector(ProjectWindowController.selectPreviousProjectTab(_:)),
            target: nil, key: "\t", modifiers: [.control, .shift])
        // ⌘1…⌘9, which every browser on this Mac spends on exactly this. Nine slots retitled on
        // validation, the way Go to Frame does it; ⌘9 is the last tab however long the row is. See
        // `ProjectWindowController.selectProjectTabByIndex` for why the reservation on these keys is
        // over.
        let goToTab = NSMenu(title: "Go to Tab")
        for index in 0..<9 {
            let entry = goToTab.addItem(
                withTitle: index == 8 ? "Last Tab" : "Tab \(index + 1)",
                action: #selector(ProjectWindowController.selectProjectTabByIndex(_:)),
                keyEquivalent: "\(index + 1)")
            entry.keyEquivalentModifierMask = [.command]
            entry.tag = index
        }
        let goToTabItem = menu.addItem(withTitle: "Go to Tab", action: nil, keyEquivalent: "")
        goToTabItem.submenu = goToTab
        menu.addItem(.separator())
        // ⌥⌘S is the Finder/Mail "Show Sidebar" shortcut. `toggleSidebar:` is answered by the front
        // window's split view controller, so it animates and persists in one place.
        add(menu, "Show Projects", #selector(NSSplitViewController.toggleSidebar(_:)), target: nil,
            key: "s", modifiers: [.command, .option])
        // With the other two "show me this" checkmarks rather than in the sidebar's arrange menu: it's
        // how the whole app writes a project's name, not how one list is arranged. See `ProjectCodes`.
        add(menu, "Show Project Codes", #selector(AppDelegate.toggleProjectCodes), target: target, key: "")
        menu.addItem(.separator())

        // Everything a canvas answers and a project window doesn't, in one block at the foot of the
        // menu. It sits below the "Show" toggles rather than among them because in a project window
        // the whole block is dim, and a run of grey items reads as the end of a menu rather than as a
        // hole punched through the middle of it. Each group ends with its own separator, so the block
        // delimits itself — do not add another before Appearance or at the start of a group.
        //
        // Zoom is answered only by a board. ⌘= as well as ⌘+ because the plus is a shifted equals on
        // most layouts and AppKit matches the literal character.
        canvasPresentationItems(menu)
        canvasZoomItems(menu)
        canvasTilingItems(menu)
        canvasPageItems(menu)
        canvasModeItem(menu)

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

extension AppColorMode {
    var menuTitle: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}
