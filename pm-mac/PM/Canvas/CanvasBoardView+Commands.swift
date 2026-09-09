import AppKit
import UniformTypeIdentifiers
import PmLib

/// The commands a board answers: select all, duplicate, the clipboard, and the menu you get on a
/// right-click.
///
/// Cards are copied as **canvas** — the same JSON the file is written in, on a private pasteboard type
/// — so a copy carries colours, sizes, subpaths, the lines between the copied cards, and every plugin
/// key PM doesn't model. Alongside it goes plain text, so pasting into a note or another app gives
/// something readable rather than nothing.
extension CanvasBoardView {

    /// The private type a copied selection travels on.
    static let pasteboardType = NSPasteboard.PasteboardType("com.stuarthanberg.pm.canvas-nodes")

    // MARK: Selecting

    /// ⌘A — every card, or every row of the project card you are standing in.
    ///
    /// The same rule the zoom commands and find already follow: inside a card, a command means the
    /// card. See `CanvasProjectCardCommands`, and `projectCardTakes(_:)` for the two keys that arrive
    /// as key events rather than through the responder chain.
    override func selectAll(_ sender: Any?) {
        if let card = engagedProjectCard { return card.projectCommands.requestSelectAllRows() }
        selection = Set(document.nodes.map(\.id))
    }

    // MARK: Copying

    @objc func copy(_ sender: Any?) {
        // Inside a project card with rows picked out, ⌘C is those rows as markdown — the same bytes
        // the window's column puts on the pasteboard. With nothing picked out it is the card, which is
        // what the board would have copied anyway.
        if let card = engagedProjectCard, card.projectCommands.selectedRows > 0 {
            return card.projectCommands.requestCopyRows()
        }
        guard !selection.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(Data(extracted(selection).serialized().utf8), forType: Self.pasteboardType)
        pasteboard.setString(plainText(for: selection), forType: .string)
    }

    @objc func cut(_ sender: Any?) {
        copy(sender)
        deleteSelection()
    }

    /// The cards, as a canvas of their own.
    ///
    /// Lines are carried only when **both** ends were copied. A line to a card you didn't copy has
    /// nowhere to land on paste, and the format has no way to express one — so it is dropped here
    /// rather than pasted as a dangling edge that nothing will ever draw.
    private func extracted(_ ids: Set<String>) -> CanvasDocument {
        CanvasDocument(nodes: document.nodes.filter { ids.contains($0.id) },
                       edges: document.edges.filter {
                           ids.contains($0.fromNode) && ids.contains($0.toNode)
                       })
    }

    /// What a card is worth outside a canvas: its prose, its address, its path.
    private func plainText(for ids: Set<String>) -> String {
        document.nodes.filter { ids.contains($0.id) }.map { node in
            switch node.content {
            case .text(let text): return text
            case .link(let url): return url
            case .file(let path, let subpath): return path + (subpath ?? "")
            case .group(let label, _, _): return label ?? ""
            }
        }
        .filter { !$0.isEmpty }
        .joined(separator: "\n\n")
    }

    // MARK: Pasting

    /// ⌘V — cards onto the board, or **text as tasks** into the project card you are standing in.
    ///
    /// Only for text, and that is the whole rule: a copied card, file or image has no meaning inside a
    /// task list, and a copied paragraph has none on a board that would rather make it a card. So the
    /// pasteboard decides, and each surface takes what it can use.
    @objc func paste(_ sender: Any?) {
        // Cards first: copying cards also puts their text down, so a board's own clipping has to be
        // recognised as one wherever you happen to be standing.
        let copiedCards = NSPasteboard.general.types?.contains(Self.pasteboardType) == true
        if let card = engagedProjectCard, !copiedCards, TaskPasteboard.hasTasksToPaste {
            return card.projectCommands.requestPasteRows()
        }
        paste(at: nil)
    }

    // MARK: Dropping

    /// A drop is a paste that names its own place, so it goes through the same reading of the
    /// pasteboard. Registering for the types here rather than in the board's initialiser keeps the
    /// list beside the code that interprets it.
    func registerForDrops() {
        registerForDraggedTypes([.fileURL, .string, .URL] + NoteImagePasteboard.imageTypes)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        canAccept(sender.draggingPasteboard) ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        canAccept(sender.draggingPasteboard) ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let at = canvasPoint(convert(sender.draggingLocation, from: nil))
        return accept(sender.draggingPasteboard, at: at)
    }

    private func canAccept(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.availableType(from: [.fileURL, .string, .URL] + NoteImagePasteboard.imageTypes) != nil
            || pasteboard.data(forType: Self.pasteboardType) != nil
    }

    /// Paste whatever is on the pasteboard, as the kind of card it deserves.
    ///
    /// The order is most-specific first, and it matters at every step: a copied *image file* has to be
    /// caught before the image bytes some apps put down beside it, or the board gets a second copy of
    /// a picture already in the vault; a file URL has to be caught before the string form of that URL,
    /// or a dragged note becomes a card containing the text `file:///Users/…`.
    func paste(at where_: CanvasPoint?) {
        _ = accept(NSPasteboard.general, at: where_ ?? centreOfVisibleBoard)
    }

    /// Read `pasteboard` and put whatever is on it on the board at `at`.
    ///
    /// The order is most-specific first, and it matters at every step: a copied *image file* has to be
    /// caught before the image bytes some apps put down beside it, or the board gets a second copy of
    /// a picture already in the vault; a file URL has to be caught before the string form of that URL,
    /// or a dragged note becomes a card containing the text `file:///Users/…`.
    @discardableResult
    func accept(_ pasteboard: NSPasteboard, at: CanvasPoint) -> Bool {
        if let data = pasteboard.data(forType: Self.pasteboardType),
           let copied = try? CanvasDocument.parse(data) {
            insert(copied, at: at, actionName: "Paste")
            return true
        }
        if let files = NoteImagePasteboard.imageFiles(on: pasteboard) {
            addFileCards(for: files, at: at)
            return true
        }
        if let image = NoteImagePasteboard.imageData(on: pasteboard), let saved = save(image) {
            addFileCards(for: [saved], at: at)
            return true
        }
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        if let files = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL],
           !files.isEmpty {
            addFileCards(for: files, at: at)
            return true
        }
        if let text = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            addCard(for: text, at: at)
            return true
        }
        return false
    }

    /// Write a pasted picture into the vault's attachments folder, beside where a note's would go.
    ///
    /// The same `saveNoteAttachment` the note editor uses, given the canvas as the document it belongs
    /// to — so a screenshot dropped on a board lands where the vault has been told to put attachments,
    /// not somewhere PM invented.
    private func save(_ image: (data: Data, ext: String)) -> URL? {
        do {
            return try saveNoteAttachment(image.data, ext: image.ext, forNoteAt: store.url)
        } catch {
            Log.write("canvas attachment write failed: \(error)")
            return nil
        }
    }

    private func addFileCards(for files: [URL], at where_: CanvasPoint) {
        var nodes: [CanvasNode] = []
        for (index, url) in files.enumerated() {
            let path = store.resolver.storablePath(for: url) ?? url.path
            let tall = isMarkdownImagePath(url.path) || url.pathExtension.lowercased() == "pdf"
            nodes.append(CanvasNode(content: .file(path: path, subpath: nil),
                                    frame: CanvasRect(x: where_.x + Double(index) * 30,
                                                      y: where_.y + Double(index) * 30,
                                                      width: 400, height: tall ? 400 : 300)))
        }
        insert(CanvasDocument(nodes: nodes), at: nil,
               actionName: files.count > 1 ? "Add Files" : "Add File")
    }

    /// A pasted string: an address becomes a link card, anything else becomes prose.
    private func addCard(for text: String, at where_: CanvasPoint) {
        let looksLikeAddress = !text.contains(where: \.isWhitespace)
            && (text.hasPrefix("http://") || text.hasPrefix("https://"))
        let content: CanvasContent = looksLikeAddress ? .link(url: text) : .text(text)
        let size = looksLikeAddress
            ? CanvasRect(x: where_.x - 200, y: where_.y - 200, width: 400, height: 400)
            : CanvasRect(x: where_.x - 125, y: where_.y - 60, width: 250, height: 120)
        insert(CanvasDocument(nodes: [CanvasNode(content: content, frame: size)]), at: nil,
               actionName: "Paste")
    }

    // MARK: Duplicating

    @objc func duplicate(_ sender: Any?) {
        guard !selection.isEmpty else { return }
        insert(extracted(selection), at: nil, actionName: "Duplicate", offsetBy: 24)
    }

    /// Put a small canvas into this one: new identities, moved to where it's going, and selected.
    ///
    /// Every id is minted fresh and the copied lines are rewritten to the new ids. Reusing the
    /// originals would give the document two cards with the same id — which the format permits to
    /// exist and gives no meaning to, so every lookup after it would answer with whichever came first.
    private func insert(_ incoming: CanvasDocument,
                        at where_: CanvasPoint?,
                        actionName: String,
                        offsetBy offset: Double = 0) {
        guard !incoming.nodes.isEmpty else { return }

        var identities: [String: String] = [:]
        for node in incoming.nodes { identities[node.id] = CanvasID.make() }

        var dx = offset, dy = offset
        if let where_, let bounds = incoming.bounds {
            dx = where_.x - bounds.midX
            dy = where_.y - bounds.midY
        }

        var nodes = incoming.nodes
        for index in nodes.indices {
            nodes[index].id = identities[nodes[index].id]!
            nodes[index].frame.x += dx
            nodes[index].frame.y += dy
        }
        var edges = incoming.edges
        for index in edges.indices {
            guard let from = identities[edges[index].fromNode],
                  let to = identities[edges[index].toNode] else { continue }
            edges[index].id = CanvasID.make()
            edges[index].fromNode = from
            edges[index].toNode = to
        }

        store.change(actionName) { doc in
            doc.nodes.append(contentsOf: nodes)
            doc.edges.append(contentsOf: edges.filter {
                identities.values.contains($0.fromNode) && identities.values.contains($0.toNode)
            })
        }
        selection = Set(nodes.map(\.id))
    }

    var centreOfVisibleBoard: CanvasPoint {
        let visible = visibleRect
        return canvasPoint(NSPoint(x: visible.midX, y: visible.midY))
    }

    // MARK: The right-click menu

    override func menu(for event: NSEvent) -> NSMenu? {
        let where_ = canvasPoint(convert(event.locationInWindow, from: nil))
        let menu = NSMenu()
        // Where a "Paste" or a "New Card" from this menu should land. Kept because the menu is
        // dismissed by the time the item fires, and by then the pointer has moved.
        menuPoint = where_
        menuDivider = nil
        menuTile = nil

        // In a tiled view the arrangement's own chrome answers first — the boundaries are in the gaps,
        // and a menu about a card there would be a menu about whichever card the gap happened to be
        // beside.
        if isTiled {
            // The boundary first, and that is not a new precedence — it has always been asked before
            // the card, because `dividerReach` is wider than the gap and so laps onto the tiles either
            // side of it. A right-click in that strip is about the pair, not about one.
            if let divider = tileDivider(at: where_) {
                menuDivider = divider
                buildDividerMenu(menu, divider)
                return menu
            }
            // **Any part of a tile, not only its handlebar.** The tile block used to hang off the
            // handlebar alone — a hairline bar out in the gap, which you had to know was a menu before you
            // could find the menu. The handlebar's whole job is the drag; every command a tile has is
            // here, on the tile itself, and in the View menu. Asked of the card first and the bar
            // second, so the gap the bar sits in still answers for the tile it belongs to.
            if let id = tiledMenuTarget(at: where_) {
                // The same rule the board's own path below follows, and it was the one line that
                // didn't: right-clicking one of four selected tiles has to leave the four selected, or
                // every command in the menu quietly means one card. A tiled view is where a bulk
                // command — reload these six — is most likely to be what you wanted.
                if !selection.contains(id) { selection = [id] }
                menuTile = id
                buildCardMenu(menu, id: id, includingTiling: false)
                // The card's commands, then the tile's, each under its own header — see
                // `addTileSection`. The first header goes in afterwards because `buildCardMenu` is
                // shared with the untiled board, where there is only one kind of object and a header
                // would be labelling the whole menu.
                menu.insertItem(.sectionHeader(title: "Card"), at: 0)
                addTileSection(menu, id: id)
                return menu
            }
        }

        switch hitTester.hit(where_) {
        case .node(let id), .handle(let id, _), .anchor(let id, _):
            if !selection.contains(id) { selection = [id] }
            buildCardMenu(menu, id: id)
        case .edge(let id):
            if !selection.contains(id) { selection = [id] }
            buildLineMenu(menu, id: id)
        case .board:
            buildBoardMenu(menu)
        }
        return menu
    }

    /// The tile a right-click in a tiled view is about: the one it landed on, else the one whose
    /// handlebar it landed on.
    ///
    private func tiledMenuTarget(at where_: CanvasPoint) -> String? {
        switch hitTester.hit(where_) {
        case .node(let id), .handle(let id, _), .anchor(let id, _):
            return tiling?.ids.contains(id) == true ? id : nil
        case .edge, .board:
            return tileHandle(at: where_)
        }
    }

    /// `includingTiling` is false for the one caller that groups the tiling commands itself under a
    /// header of their own — see `addTileSection`. Everywhere else they belong in the run of the
    /// menu, because everywhere else there is only one kind of object to act on.
    private func buildCardMenu(_ menu: NSMenu, id: String, includingTiling: Bool = true) {
        guard let node = document.node(id: id) else { return }

        switch node.content {
        case .file(let path, _):
            // A project's notes card opens the project, and that item comes first: it is a card
            // *showing* a project (see `CanvasProjectNote`), and the board is read-only, so this is the
            // way in to actually doing something about what it says.
            if (nodeViews[id] as? CanvasFileNodeView)?.projectFolderName != nil {
                // "Go to" and not "Open", because from a board rendered inside a project window this
                // retargets the window you are in — the same thing clicking the sidebar does. The
                // alternate is the other verb, said out loud. See `openProjectForCard`.
                add(menu, "Go to Project", #selector(openProjectForCard))
                let newWindow = add(menu, "Open Project in New Window",
                                    #selector(openProjectInNewWindowForCard))
                newWindow.keyEquivalentModifierMask = [.option]
                newWindow.isAlternate = true
                // The board is the one surface that shows several projects at once, which makes it the
                // natural place to say which one you are on — and, until now, the only surface that
                // couldn't. This is what the CLI, Raycast, the menu bar and the focus panel all read.
                //
                // An explicit command rather than a side effect of clicking. Focus reaches outside this
                // app, and a look across a board should not quietly repoint the things on the other end
                // of it.
                add(menu, "Focus This Project", #selector(focusProjectForCard))
                menu.addItem(.separator())
                // The two writes, carrying the keys they answer to. This is where somebody looks when
                // they wonder what a card can be told to do, and the keys work from here whether or not
                // the card has been stepped into — see `newSessionOnCard`, which steps in on your
                // behalf, because that is what clicking the item would have done anyway.
                key(add(menu, "New Session", #selector(newSession(_:))), "n", modifiers: [.command, .shift])
                key(add(menu, "New Task", #selector(newTask(_:))), "n")
                // No key, because the window has none for it either — the brief is reached by
                // double-clicking it. This item is for the case that gesture cannot serve: a project
                // with no brief yet draws nothing on a card, so there is nothing to double-click.
                add(menu, "Edit Details\u{2026}", #selector(editProjectDetails(_:)))
                addShowsMenu(menu)
            }
            add(menu, "Open in Obsidian", #selector(openSelected))
            if case .moved = store.resolver.resolve(path) {
                add(menu, "Repair Stored Path", #selector(repairSelectedPaths))
            }
            if store.resolver.resolve(path).url != nil {
                add(menu, "Reveal in Finder", #selector(revealSelected))
            }
        case .link:
            // Not `openSelected`, which is "step into the card" — this item said Browser and stepped
            // into the card, and the method that opens the browser was never called by anything.
            //
            // Every one of these already acted on the whole selection and every one of them was named
            // as though it acted on one card, so a right-click on four selected cards said "Reload"
            // and reloaded four. The count is said out loud for the same reason "Fill Window with
            // These 6 Cards" says it: the hazard of a bulk command is doing more than you meant, and
            // that is worth knowing before you commit rather than after.
            add(menu, many("Open in Browser", "Open %d in Browser"), #selector(openLinkInBrowser))
            add(menu, many("Copy Address", "Copy %d Addresses"), #selector(copyAddress))
            menu.addItem(.separator())
            // The two ways a card's address changes, and they are genuinely different errands. One is
            // "I navigated somewhere better and the card should point here now", which needs no typing
            // and is only offered when the page has actually gone somewhere else. The other is "this
            // address is wrong", which is a text edit and is always available.
            if (nodeViews[id] as? CanvasLinkNodeView)?.hasWandered == true {
                add(menu, "Set as This Card\u{2019}s Address", #selector(adoptCurrentAddress))
            }
            add(menu, "Edit Address\u{2026}", #selector(editLinkAddress))
            menu.addItem(.separator())
            // Where a page's navigation lives. Not in the card's header, which is a caption and has
            // no room to become a toolbar, and not on a swipe, which on a trackpad is indistinguishable
            // from scrolling a page sideways.
            if (nodeViews[id] as? CanvasLinkNodeView)?.canGoBack == true {
                add(menu, many("Back", "Back on %d Cards"), #selector(goBackInLink))
            }
            add(menu, many("Reload", "Reload %d Cards"), #selector(reloadLink))
            if let card = nodeViews[id] as? CanvasLinkNodeView {
                menu.addItem(.separator())
                // These three are per *site*, not per card, so they count sites: four cards on one
                // tracker are one sign-in, and naming the site is more use than naming the number
                // whenever there is only one of it.
                let sites = selectedSites()
                let site = sites.count == 1 ? sites[0] : "\(sites.count) Sites"
                add(menu, "Sign In to \(site)…", #selector(signInToLink))
                // Signing in is per site, so signing out is too — and it reaches every card on every
                // board that shows that site, because they were all one session to begin with.
                add(menu, "Sign Out of \(site)", #selector(signOutOfLink))
                add(menu, "Sign Out of All Sites…", #selector(signOutEverywhere))
                menu.addItem(.separator())
                // Per site, because that is the granularity at which blocking breaks a page: when a
                // card comes up empty the question is always "is it this site?", and the answer has to
                // be one click away from the card that is wrong.
                let filtering = add(menu, "Block Ads on \(site)", #selector(toggleLinkFiltering))
                filtering.state = card.isFiltered ? .on : .off
                // Per card, unlike the three above: what a page is allowed to play is a fact about
                // this card on this board — one embed you want running and the eleven beside it you
                // don't — rather than about the site it happens to be on. See `CanvasCardMedia`.
                let count = selectedLinkCards.count
                let autoplay = add(menu, CanvasCardMedia.autoplayTitle(count), #selector(toggleAutoplay))
                autoplay.state = selectedLinkCards.allSatisfy(\.autoplays) ? .on : .off
                let muted = add(menu, CanvasCardMedia.muteTitle(count), #selector(toggleMuted))
                muted.state = selectedLinkCards.allSatisfy(\.isMuted) ? .on : .off
                addSessionMenu(menu, card: card)
            }
        case .text:
            // Named for what it edits, like every sibling in this switch — "Edit Address…" on a link,
            // "Rename Frame…" below. A bare "Edit" was the only item in the menu that made you work
            // out its object from where you had clicked, and it sat two lines above "Edit Address…",
            // which does not.
            add(menu, "Edit Text\u{2026}", #selector(editSelected))
        case .group:
            add(menu, "Rename Frame…", #selector(renameSelectedFrame))
            // **The second way to get a second tab**, and it had no menu item: this command has existed
            // since tabs did, is named in two places as one of the two ways a tab gets made, and had
            // no callers anywhere in the app. A frame is a named region of the board, which is the
            // thing you most want beside the board — see `ProjectTab`.
            add(menu, "Open Frame in New Tab", #selector(openSelectedFrameInTab))
        }

        if includingTiling { addTiling(menu) }
        menu.addItem(.separator())
        // All four carry their keys, for the reason Fill Window does — see `addTiling`. A contextual
        // menu draws a key equivalent exactly as the menu bar does, and it is the one place a person
        // is already looking when they wonder what else they can do to a card. Teaching one shortcut
        // here and hiding the four beneath it was the odd arrangement: these are the commands somebody
        // uses often enough to want the key for.
        //
        // Display, not dispatch. Only the main menu is searched for key equivalents, so nothing here
        // claims a keystroke — which is what makes a bare ⌫ safe to print on Delete.
        key(add(menu, "Cut", #selector(cut(_:))), "x")
        key(add(menu, "Copy", #selector(copy(_:))), "c")
        key(add(menu, "Duplicate", #selector(duplicate(_:))), "d")
        menu.addItem(.separator())
        key(add(menu, selection.count > 1 ? "Delete Cards" : "Delete Card", #selector(deleteSelected)),
            "\u{8}", modifiers: [])
    }

    /// The project cards in the selection — what every project command acts on.
    private var selectedProjectCards: [CanvasFileNodeView] {
        selection.compactMap { nodeViews[$0] as? CanvasFileNodeView }.filter(\.isProjectCard)
    }

    /// How much of its project a card draws — see `CanvasCardShows`.
    ///
    /// A submenu, and last on the card's own block, following the link card's Session for the same
    /// reason: the whole project is right for nearly every card ever made, and this is the setting for
    /// the boards where it isn't — six projects up at once, or two cards on one project showing
    /// different halves of it.
    private func addShowsMenu(_ menu: NSMenu) {
        let cards = selectedProjectCards
        guard !cards.isEmpty else { return }
        let shows = NSMenu(title: "Shows")
        for part in CanvasCardShows.Part.allCases {
            let entry = add(shows, part.title, #selector(toggleShownPart(_:)))
            entry.representedObject = part.rawValue
            // Ticked only when every selected card agrees, which is how a mixed selection reads as
            // mixed rather than as whatever the first card happened to say.
            entry.state = cards.allSatisfy { $0.shows.shows(part) } ? .on : .off
        }
        shows.addItem(.separator())
        let completed = add(shows, "Completed Tasks", #selector(toggleCompletedTasks(_:)))
        completed.state = cards.allSatisfy(\.shows.completed) ? .on : .off
        shows.addItem(.separator())
        // A pair rather than one "Latest Session Only" tick, because this is a choice between two
        // scopes and a checkbox would leave the unticked state unnamed.
        let all = add(shows, "All Sessions", #selector(setSessionScope(_:)))
        all.representedObject = "all"
        all.state = cards.allSatisfy { !$0.shows.latestOnly } ? .on : .off
        let latest = add(shows, "Latest Session Only", #selector(setSessionScope(_:)))
        latest.representedObject = "latest"
        latest.state = cards.allSatisfy(\.shows.latestOnly) ? .on : .off

        let item = menu.addItem(withTitle: "Shows", action: nil, keyEquivalent: "")
        item.submenu = shows
    }

    /// The link cards in the selection — what every command in the link block above acts on.
    private var selectedLinkCards: [CanvasLinkNodeView] {
        selection.compactMap { nodeViews[$0] as? CanvasLinkNodeView }
    }

    /// A menu item's title, singular or with the count in it. `%d` in `plural` is where the number goes.
    ///
    /// One card is named without a number — "Reload", not "Reload 1 Card" — because the number is only
    /// worth saying when it might be more than you meant.
    private func many(_ single: String, _ plural: String) -> String {
        let count = selectedLinkCards.count
        return count > 1 ? plural.replacingOccurrences(of: "%d", with: "\(count)") : single
    }

    /// The distinct sites the selected link cards show, in the order the cards sit in the file.
    private func selectedSites() -> [String] {
        var seen: Set<String> = []
        return selectedLinkCards.map(\.siteName).filter { seen.insert($0).inserted }
    }

    /// Which browser session this card uses.
    ///
    /// Deliberately the last thing on a card's menu and deliberately a submenu: the shared session is
    /// right for nearly every card ever made, and this is the escape hatch for the case it cannot
    /// express — the second account. See `CanvasCardSession`.
    private func addSessionMenu(_ menu: NSMenu, card: CanvasLinkNodeView) {
        let sessions = NSMenu(title: "Session")
        let shared = add(sessions, "Shared", #selector(useSharedSession))
        shared.state = card.profile == nil ? .on : .off
        sessions.addItem(.separator())
        for name in CanvasWebSession.profileNames {
            let entry = add(sessions, name, #selector(useNamedSession))
            entry.representedObject = name
            entry.state = card.profile == name ? .on : .off
        }
        // Never written to disk, gone when PM quits — the card you open a link in when you would
        // rather the jar didn't remember it.
        let private_ = add(sessions, CanvasWebSession.ephemeralName, #selector(usePrivateSession))
        private_.state = card.profile == CanvasWebSession.ephemeralName ? .on : .off
        sessions.addItem(.separator())
        add(sessions, "New Session\u{2026}", #selector(useNewSession))

        let item = menu.addItem(withTitle: "Session", action: nil, keyEquivalent: "")
        item.submenu = sessions
    }

    private func buildLineMenu(_ menu: NSMenu, id: String) {
        add(menu, "Reverse Direction", #selector(reverseSelectedLines))
        menu.addItem(.separator())
        add(menu, "Delete Line", #selector(deleteSelected))
    }

    /// Right-clicking a boundary: what this divider can be told to do.
    ///
    /// **The boundary is the object here, not the card.** Dragging one is a continuous adjustment, and
    /// everything a continuous adjustment cannot say belongs in a menu on the thing being adjusted:
    /// hold this side still, put these back to even, lay them out the other way entirely. It is the
    /// same argument as a right-click on a window divider anywhere else — the divider is a control, and
    /// controls have menus.
    private func buildDividerMenu(_ menu: NSMenu, _ divider: CanvasTileDivider) {
        guard let tiling, let sides = tiles(of: divider) else { return }
        let before = divider.isVertical ? "Left" : "Above"
        let after = divider.isVertical ? "Right" : "Below"

        // The master's boundary has a tile on one side and the whole stack on the other, and the stack
        // is not a tile — pinning "the right-hand side" of it would mean pinning a column's width by
        // way of one of the cards in it, which is not what the click said.
        add(menu, pinTitle(sides.before, side: divider.isMasterSplit ? "Master" : before),
            #selector(pinTileBeforeDivider(_:)))
        if !divider.isMasterSplit {
            add(menu, pinTitle(sides.after, side: after), #selector(pinTileAfterDivider(_:)))
        }

        menu.addItem(.separator())
        add(menu, divider.isMasterSplit ? "Reset Split" : "Even Out These Tiles",
            #selector(evenOutTiles(_:)))

        menu.addItem(.separator())
        let arrange = NSMenu()
        for option in CanvasTiling.Arrangement.allCases {
            let item = add(arrange, option.title, option == .grid ? #selector(arrangeAsGrid(_:))
                                                                  : #selector(arrangeAsMasterStack(_:)))
            item.state = tiling.arrangement == option ? .on : .off
        }
        let item = menu.addItem(withTitle: "Arrange", action: nil, keyEquivalent: "")
        item.submenu = arrange
        add(menu, "Rename Workspace\u{2026}", #selector(renameWorkspace(_:)))
    }

    /// What a right-click on a *tile* can say about the tile, as opposed to about the card in it.
    ///
    /// **Both, and in that order, because a tile is two things at once.** Right-clicking one used to
    /// build the card menu and stop, so everything about the arrangement was reachable only by
    /// right-clicking a *boundary* — a control you have to know exists, three points wide, in the gap
    /// between two tiles. The card's own commands are still first: a tile is mostly a card, and the
    /// thing you most often want from one is to open it, reload it or copy its address.
    ///
    /// Under a section header, which is what the header is for: the two blocks act on different objects
    /// and "Delete Card" sitting a line above "Leave Tiled View" without one is a menu inviting the
    /// mistake. `buildCardMenu` gets the matching header inserted above it by the caller.
    ///
    /// **Remove, not close**, and it is the last item for the same reason Delete is last everywhere
    /// else: it is the one that takes something away. A tile is a view of a card, so "close" would be
    /// the ambiguous word — half of what a person means by closing something is destroying it, and
    /// this destroys nothing. See `removeFromTiling`.
    private func addTileSection(_ menu: NSMenu, id: String) {
        guard let tiling else { return }
        menu.addItem(.sectionHeader(title: "Tile"))
        // The block `buildCardMenu` was told to skip: fill the window with this one, pin its length,
        // and — since ⌘↩ means the first of those here rather than the last — leave. The header is the
        // separator, so it doesn't want a second one above it.
        addTiling(menu, separated: false)

        // Only where it means something: a grid has no master, and the master is already the master.
        if tiling.arrangement == .masterStack, tiling.ids.first != id {
            let promote = add(menu, "Make This the Master Tile", #selector(promoteMenuTile(_:)))
            promote.keyEquivalent = "\r"
            promote.keyEquivalentModifierMask = [.command, .shift]
        }

        let arrange = NSMenu()
        for option in CanvasTiling.Arrangement.allCases {
            let item = add(arrange, option.title, option == .grid ? #selector(arrangeAsGrid(_:))
                                                                  : #selector(arrangeAsMasterStack(_:)))
            item.state = tiling.arrangement == option ? .on : .off
        }
        let item = menu.addItem(withTitle: "Arrange", action: nil, keyEquivalent: "")
        item.submenu = arrange

        add(menu, "Rename Workspace\u{2026}", #selector(renameWorkspace(_:)))

        menu.addItem(.separator())
        add(menu, "Remove from Tiled View", #selector(removeMenuTile(_:)))
    }

    /// Make the right-clicked tile the master. `promoteTile` is the same command with no pointer
    /// behind it — the difference between a contextual menu, which is about the thing you pointed at,
    /// and the menu bar, which can only be about the thing that is focused.
    @objc func promoteMenuTile(_ sender: Any?) {
        guard let id = menuTile else { return }
        promoteInTiling(id)
    }

    /// The tile a menu-bar command acts on: the focused one, and only when it is on its own.
    ///
    /// A menubar item has nothing under a pointer to mean, so "this tile" has to mean the selection —
    /// and a selection of four tiles cannot promote or be removed without picking one of the four for
    /// you. Dim rather than guess.
    var focusedTile: String? {
        guard let tiling, selection.count == 1, let id = selection.first,
              tiling.ids.contains(id) else { return nil }
        return id
    }

    /// ⌘⇧Return. Documented on `promoteInTiling` from the day it was written and never actually
    /// wired to anything: the key equivalent it carried was on a contextual-menu item, and nothing in
    /// a contextual menu is searched for key equivalents — it was drawn and never dispatched.
    @objc func promoteTile(_ sender: Any?) {
        guard let id = focusedTile else { return NSSound.beep() }
        promoteInTiling(id)
    }

    /// Take the focused tile out of the view — the menu bar's half of `removeMenuTile`.
    @objc func removeTile(_ sender: Any?) {
        guard let id = focusedTile else { return NSSound.beep() }
        removeFromTiling(id)
    }

    /// Take the right-clicked tile out of the view. Like `promoteMenuTile`, it acts on the tile you
    /// pointed at rather than on the selection: right-clicking one of four selected tiles has to be
    /// able to mean that one, and a bulk "remove these four" from a menu whose other items act on all
    /// four is a mistake waiting to be made with no undo behind it (a tiling is a view, so ⌘Z has
    /// nothing to say about it).
    @objc func removeMenuTile(_ sender: Any?) {
        guard let id = menuTile else { return }
        removeFromTiling(id)
    }

    /// **Show the canvas** — the way out of a tiled view, wherever a menu offers one.
    ///
    /// It untiled the board and it does not any more. A workspace is a place the window can be in
    /// (docs/canvas-workspaces.md §7i), so leaving it is going to the other place — the canvas tab —
    /// and the tiles stay exactly as they are behind you.
    @objc func goToCanvasCommand(_ sender: Any?) { onGoToCanvas() }

    private func pinTitle(_ id: String, side: String) -> String {
        "\(isTilePinned(id) ? "Unpin" : "Pin") \(side) Tile"
    }

    /// The two tiles a boundary separates.
    func tiles(of divider: CanvasTileDivider) -> (before: String, after: String)? {
        guard let tiling, divider.before + 1 < divider.run.count else { return nil }
        return (tiling.ids[divider.run[divider.before]], tiling.ids[divider.run[divider.before + 1]])
    }

    @objc func pinTileBeforeDivider(_ sender: Any?) {
        guard let divider = menuDivider, let sides = tiles(of: divider) else { return }
        togglePinTile(sides.before)
    }

    @objc func pinTileAfterDivider(_ sender: Any?) {
        guard let divider = menuDivider, let sides = tiles(of: divider) else { return }
        togglePinTile(sides.after)
    }

    /// Put this run back to sharing equally — the way out of an arrangement you have over-adjusted,
    /// and the only thing a drag genuinely cannot express.
    @objc func evenOutTiles(_ sender: Any?) {
        guard let divider = menuDivider, var session = tiling else { return }
        if divider.isMasterSplit {
            session.sizes[session.ids[0]] = nil
            session.masterFraction = CanvasTiling.savedMasterFraction
        } else {
            for index in divider.run { session.sizes[session.ids[index]] = nil }
        }
        tiling = session
        setLayout(session.layout, animated: true)
        onTilingChanged?()
    }

    @objc func arrangeAsGrid(_ sender: Any?) { chooseArrangement(.grid) }
    @objc func arrangeAsMasterStack(_ sender: Any?) { chooseArrangement(.masterStack) }

    private func chooseArrangement(_ arrangement: CanvasTiling.Arrangement) {
        if isTiled { setArrangement(arrangement) } else { tile(tileTargets, arrangement: arrangement) }
    }

    private func buildBoardMenu(_ menu: NSMenu) {
        // The same four the toolbar's Add offers, under the same four names — see `CanvasAddCommand`.
        // Here so that Add is a convenience rather than the only door: the toolbar is customisable now,
        // and a command reachable from one removable button is a command that can be removed.
        add(menu, CanvasAddCommand.card.title, #selector(newCardHere))
        add(menu, CanvasAddCommand.frame.title, #selector(newFrameHere))
        add(menu, CanvasAddCommand.link.title, #selector(newLinkHere))
        add(menu, CanvasAddCommand.file.title, #selector(newFileHere))
        // Fifth, and only sometimes: the one document this board is *about*, when it has been deleted
        // off it. See `CanvasProjectNoteCard`.
        if offersProjectNoteCard {
            add(menu, CanvasAddCommand.projectNote.title, #selector(newProjectNoteHere))
        }
        menu.addItem(.separator())
        // Enabled or not is `validateUserInterfaceItem`'s answer, not one set here: this menu
        // autoenables, so anything written onto `isEnabled` at build time is overwritten before the
        // menu is drawn. Setting it here was how Paste came to be live over an empty pasteboard.
        add(menu, "Paste", #selector(pasteHere))
        addTiling(menu)
        menu.addItem(.separator())
        add(menu, "Select All", #selector(selectAll(_:)))
    }

    /// ⌘Return, in the menu you get to by right-clicking.
    ///
    /// The command was reachable from the View menu and from a key you had to already know, and from
    /// nowhere a pointer could find it — which for the board's largest gesture is the wrong way round.
    /// Right-clicking a selection is where a Mac says "what can I do with these", and until now this
    /// board's answer was cut, copy, duplicate, delete: four things you can do to a card's *contents*
    /// and nothing about how you are looking at it.
    ///
    /// Carrying the key equivalent so the menu teaches it. A contextual menu draws one exactly as the
    /// menu bar does, which makes this the cheapest possible way to hand somebody a shortcut they were
    /// never going to find in the View menu.
    private func addTiling(_ menu: NSMenu, separated: Bool = true) {
        // Its own separator rather than one from each caller, so that bailing out on an empty board
        // leaves the menu with one divider rather than two stacked on each other. `separated` is for
        // the one caller that has already drawn a line of its own — a section header.
        guard isTiled || document.nodes.contains(where: { !$0.isGroup }) else { return }
        if separated { menu.addItem(.separator()) }
        let item = add(menu, tileCommandTitle, #selector(tileSelection(_:)))
        item.keyEquivalent = "\r"
        item.keyEquivalentModifierMask = [.command]
        // The deliberate half of pinning, and the only half: a drag can change a pin but never make
        // one, or a layout would stop responding to its window one adjustment at a time without
        // anybody having asked for that. See `togglePinTile`.
        if pinnableTile != nil { add(menu, pinTileTitle, #selector(togglePinTileSize(_:))) }
        addLeaveTiling(menu)
    }

    /// The way out, wherever a tiled view offers a menu at all.
    ///
    /// ⌘↩ above is the way out *only when there is nothing left to narrow to* — with one tile of six
    /// picked it reads "Fill Window with This Tile", and while that is what it says there was no item
    /// anywhere on this menu that left the tiled view. Escape used to cover for that and deliberately
    /// no longer does (see `CanvasBoardView.untile`), which makes this the item that has to exist.
    ///
    /// Skipped when ⌘↩ *is* already the way out, so the menu never says it twice.
    private func addLeaveTiling(_ menu: NSMenu) {
        guard isTiled, tileCommandTitle != "Show Canvas" else { return }
        add(menu, "Show Canvas", #selector(goToCanvasCommand(_:)))
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    /// Print a shortcut beside an item. Nothing in a contextual menu is searched for key equivalents,
    /// so this only ever draws one — the keystroke itself is claimed by the menu bar or by `keyDown`.
    private func key(_ item: NSMenuItem, _ equivalent: String,
                     modifiers: NSEvent.ModifierFlags = [.command]) {
        item.keyEquivalent = equivalent
        item.keyEquivalentModifierMask = modifiers
    }

    // MARK: What the menu items do

    /// Adding a link or a file card, wherever the request came from.
    ///
    /// On the board rather than on the window, because the board is what owns cards and what knows
    /// where a click landed. The toolbar's Add calls the same two with no point and gets the middle of
    /// the window; the contextual menu passes where you right-clicked, which is the whole reason to
    /// offer them there.
    func addLinkCard(at where_: CanvasPoint?) {
        promptForAddress(title: "Add a link card",
                         message: "The page is embedded on the board.",
                         initial: "") { [weak self] text in
            guard let self else { return }
            let at = where_ ?? centreOfVisibleBoard
            addCard(CanvasNode(content: .link(url: text),
                               frame: CanvasRect(x: at.x - 200, y: at.y - 200,
                                                 width: 400, height: 400)),
                    actionName: "Add Link")
        }
    }

    /// Put a new card on the board — and, while tiled, up on the screen with the rest.
    ///
    /// **Every add command ends here**, which is what makes "adding a card works while tiled" one
    /// change rather than five. It used to be five copies of `store.change` and `select`, and a tiled
    /// view was handled by dimming four of them and having the fifth apologise.
    ///
    /// The card goes on the end of the tiling — see `CanvasTileSession.add`, which argues that — and
    /// its position *on the board* is stepped clear of whatever is already there. That second part
    /// matters only while tiled, and only because of what tiled means: the point you appear to be
    /// looking at is a region of the board the tiles are drawn over, so a card dropped at it would land
    /// on top of the cards that live there — damage you cannot see, done to the layout you cannot see.
    /// Untiled, where you land it is where you asked for it, so nothing steps it anywhere.
    @discardableResult
    func addCard(_ node: CanvasNode, actionName: String) -> String {
        var node = node
        if isTiled { node.frame = freeFrame(from: node.frame) }
        store.change(actionName) { $0.nodes.append(node) }
        addToTiling(node.id)
        select([node.id])
        return node.id
    }

    /// An empty text card, ready to be typed into. The board's own New Card and the header's Add both
    /// mean this — they had a copy each, and the copies had already drifted apart on which point they
    /// centred the card at.
    func addTextCard(at where_: CanvasPoint?) {
        let at = where_ ?? centreOfVisibleBoard
        let id = addCard(CanvasNode(content: .text(""),
                                    frame: CanvasRect(x: at.x - 125, y: at.y - 30,
                                                      width: 250, height: 60)),
                         actionName: "Add Card")
        beginEditing(id)
    }

    /// Ask for a web address, and hand back a usable one or nothing at all.
    ///
    /// Shared by adding a card and editing one, so the two are the same box with different words in it
    /// — including the part nobody thinks about until it is missing, which is that typing
    /// `example.com` gets a scheme put on it rather than producing a card that will never load. That
    /// part is `CanvasAddress.normalized`, shared further still with the header's address field.
    func promptForAddress(title: String, message: String, initial: String,
                          then use: @escaping (String) -> Void) {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 22))
        field.placeholderString = "https://"
        field.stringValue = initial
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.accessoryView = field
        alert.addButton(withTitle: initial.isEmpty ? "Add" : "Change")
        alert.addButton(withTitle: "Cancel")
        // Selected rather than merely present: editing an address is far more often replacing it than
        // amending it, and a field you have to select before you can type is a field that has put the
        // work back on you.
        alert.window.initialFirstResponder = field
        field.selectText(nil)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        guard let text = CanvasAddress.normalized(field.stringValue) else { return }
        use(text)
    }

    func addFileCard(at where_: CanvasPoint?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.message = "Choose a file from the vault."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // Stored the way Obsidian stores it — from the vault root — so the card means the same thing
        // in both apps. A file outside the vault has no such path and is stored as it stands.
        let path = store.resolver.storablePath(for: url) ?? url.path
        let at = where_ ?? centreOfVisibleBoard
        addCard(CanvasNode(content: .file(path: path, subpath: nil),
                           frame: CanvasRect(x: at.x - 200, y: at.y - 175,
                                             width: 400, height: 350)),
                actionName: "Add File")
    }

    @objc private func newLinkHere() { addLinkCard(at: menuPoint) }
    @objc private func newFileHere() { addFileCard(at: menuPoint) }
    @objc private func newProjectNoteHere() { addProjectNoteCard(at: menuPoint) }

    /// Put the project's note back on its board.
    ///
    /// Selected afterwards, the way every other add command leaves its card, but not opened for
    /// editing: this card is a whole document that arrives with its own contents, and there is nothing
    /// waiting to be typed. A new *text* card is an empty rectangle and would be pointless without the
    /// caret in it.
    ///
    /// Nothing happens on a board that hasn't got a project, which is the same answer the menu gives
    /// by not offering the item — but this is reachable from the header too, and a command whose
    /// enabled state is computed in one place and acted on in another has to check twice.
    @discardableResult
    func addProjectNoteCard(at where_: CanvasPoint?) -> String? {
        guard let notes = CanvasProjectNoteCard.notes(forCanvasAt: store.url) else { return nil }
        let node = CanvasProjectNoteCard.node(for: notes, at: where_ ?? centreOfVisibleBoard,
                                              resolver: store.resolver)
        return addCard(node, actionName: "Add Project Note")
    }

    @objc private func newCardHere() { addTextCard(at: menuPoint) }

    @objc private func newFrameHere() {
        let at = menuPoint ?? centreOfVisibleBoard
        let node = CanvasNode(content: .group(label: "Frame", background: nil, backgroundStyle: nil),
                              frame: CanvasRect(x: at.x - 300, y: at.y - 200, width: 600, height: 400))
        store.change("Add Frame") { $0.nodes.append(node) }
        selection = [node.id]
    }

    @objc private func pasteHere() { paste(at: menuPoint) }
    @objc private func deleteSelected() { deleteSelection() }

    @objc private func editSelected() {
        guard let id = selection.first else { return }
        beginEditing(id)
    }

    /// The file card menu's "Open in Obsidian". Not `beginEditing`, which is what a click means and no
    /// longer the same errand: on a project card a click steps into the project, and this item says
    /// Obsidian and has to mean it.
    @objc private func openSelected() {
        for id in selection { (nodeViews[id] as? CanvasFileNodeView)?.openInOwningApp() }
    }

    @objc private func revealSelected() {
        let urls = selection.compactMap { id -> URL? in
            guard case .file(let path, _)? = document.node(id: id)?.content else { return nil }
            return store.resolver.resolve(path).url
        }
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    /// Make the page the card is showing the address the card is for.
    @objc private func adoptCurrentAddress() {
        for id in selection { (nodeViews[id] as? CanvasLinkNodeView)?.adoptCurrentAddress() }
    }

    /// Retype a card's address.
    ///
    /// The same prompt `addLinkCard` puts up, prefilled and with the text selected, because they are
    /// the same question asked at two moments and answering it should feel identical.
    @objc private func editLinkAddress() {
        guard let id = selection.first, let card = nodeViews[id] as? CanvasLinkNodeView else { return }
        promptForAddress(title: "Edit Address",
                         message: "Where should this card point?",
                         initial: card.address) { [weak card] entered in
            card?.setAddress(entered)
        }
    }

    /// Make this card's project the app's focused one.
    @objc private func focusProjectForCard() {
        guard let id = selection.first,
              let folder = (nodeViews[id] as? CanvasFileNodeView)?.projectFolderName,
              let key = ProjectIndex.shared.projectKey(forFolder: folder) else { return }
        PMStore.setGlobalFocus(key: key) {
            (NSApp.delegate as? AppDelegate)?.syncFocusedStore()
        }
    }

    /// File ▸ New Session (⇧⌘N) on a board.
    ///
    /// **Aimed at the card you are standing in.** A board can hold six projects, so a command that acts
    /// on "the project" has to say which — and this is the kind you do *to* one, not the kind that
    /// remembers (⌘Z takes `lastEditedProject` for exactly the opposite reason). With nothing stepped
    /// into, the item is dim rather than guessing.
    ///
    /// Reached from a card's own contextual menu, it steps that card in first. Right-clicking a card is
    /// pointing at it, and dimming an item on the very card it names — because you had not clicked it
    /// first — would be the command refusing an aim it had already been given.
    @objc func newSession(_ sender: Any?) {
        projectCommandTarget(for: sender)?.projectCommands.requestNewSession()
    }

    /// File ▸ New Task (⌘N) on a board, on the same routing as New Session.
    @objc func newTask(_ sender: Any?) {
        projectCommandTarget(for: sender)?.projectCommands.requestNewTask()
    }

    /// Show or hide one part of the project on every selected card.
    ///
    /// One direction for the whole selection, on the media toggles' rule: a mixed selection turns *on*,
    /// because the tick was off and the item said so. A card that cannot take the change — the part
    /// being turned off is the last one it draws — keeps what it had rather than going blank.
    @objc func toggleShownPart(_ sender: Any?) {
        guard let raw = (sender as? NSMenuItem)?.representedObject as? String,
              let part = CanvasCardShows.Part(rawValue: raw) else { return }
        let cards = selectedProjectCards
        guard !cards.isEmpty else { return }
        let on = !cards.allSatisfy { $0.shows.shows(part) }
        setShows(cards, actionName: on ? "Show \(part.title)" : "Hide \(part.title)") { current in
            current.setting(part, to: on) ?? current
        }
    }

    @objc func toggleCompletedTasks(_ sender: Any?) {
        let cards = selectedProjectCards
        guard !cards.isEmpty else { return }
        let on = !cards.allSatisfy(\.shows.completed)
        setShows(cards, actionName: on ? "Show Completed Tasks" : "Hide Completed Tasks") { current in
            var out = current
            out.completed = on
            return out
        }
    }

    @objc func setSessionScope(_ sender: Any?) {
        guard let raw = (sender as? NSMenuItem)?.representedObject as? String else { return }
        let latest = raw == "latest"
        let cards = selectedProjectCards
        guard !cards.isEmpty else { return }
        setShows(cards, actionName: latest ? "Show Latest Session" : "Show All Sessions") { current in
            var out = current
            out.latestOnly = latest
            return out
        }
    }

    /// Write a display setting to every one of these cards, as one undoable change — the same shape as
    /// `setMedia`, and undoable for the same reason: it is an edit to the document.
    private func setShows(_ cards: [CanvasFileNodeView], actionName: String,
                          _ change: (CanvasCardShows) -> CanvasCardShows) {
        let ids = Set(cards.map(\.node.id))
        store.change(actionName) { doc in
            for index in doc.nodes.indices where ids.contains(doc.nodes[index].id) {
                let wanted = change(CanvasCardShows.of(doc.nodes[index]))
                CanvasCardShows.set(wanted, on: &doc.nodes[index])
            }
        }
    }

    /// Open the brief on a card for editing, revealing it first when the project hasn't got one — the
    /// same errand as the window's `editDetails`, which also reveals before it edits.
    @objc func editProjectDetails(_ sender: Any?) {
        projectCommandTarget(for: sender)?.projectCommands.requestEditDetails()
    }

    /// Which card a project command is about, engaging it when the aim came from its own menu.
    ///
    /// The engagement matters beyond tidiness: the card's editors are gated on it, and a card told to
    /// start a session while stepped out would open a note takeover and then close it again the moment
    /// the step-out was noticed.
    private func projectCommandTarget(for sender: Any?) -> CanvasFileNodeView? {
        if let engaged = engagedProjectCard { return engaged }
        guard sender is NSMenuItem, let id = selection.first,
              let card = nodeViews[id] as? CanvasFileNodeView, card.isProjectCard else { return nil }
        selection = [id]
        card.engage(true)
        return card
    }

    /// Whether a project command has anything to act on: the card you are in, or — from a card's own
    /// menu — the card you right-clicked.
    private var hasProjectCommandTarget: Bool {
        if engagedProjectCard != nil { return true }
        guard let id = selection.first else { return false }
        return (nodeViews[id] as? CanvasFileNodeView)?.isProjectCard == true
    }

    /// Go to the project a card's notes belong to.
    ///
    /// Where that lands depends on where you asked from, which is the Mac's own rule and was the one
    /// thing this app's several "open" commands disagreed about. A board rendered inside a project
    /// window retargets *that* window, exactly as clicking its sidebar does — it is the same errand
    /// reached from a card instead of a row. Asked for a new window, it opens one instead.
    @objc private func openProjectForCard() { goToProjectForCard(inNewWindow: false) }

    @objc private func openProjectInNewWindowForCard() { goToProjectForCard(inNewWindow: true) }

    /// The same errand a card asks for itself, when it is opened rather than picked from a menu.
    func goToProject(_ card: CanvasFileNodeView) {
        guard let key = card.projectFolderName
            .flatMap(ProjectIndex.shared.projectKey(forFolder:)) else { return }
        if let host = window?.windowController as? ProjectWindowController {
            return WindowManager.shared.retarget(host, to: key)
        }
        WindowManager.shared.open(projectKey: key)
    }

    private func goToProjectForCard(inNewWindow: Bool) {
        let folders = selection.compactMap { (nodeViews[$0] as? CanvasFileNodeView)?.projectFolderName }
        guard let folder = folders.first,
              let key = ProjectIndex.shared.projectKey(forFolder: folder) else { return }
        if !inNewWindow, let host = window?.windowController as? ProjectWindowController {
            return WindowManager.shared.retarget(host, to: key)
        }
        // In a new window when that is what was asked for, even if this project already has one —
        // otherwise the item brings forward the window you right-clicked in, which is most of the time
        // on a board showing its own project's notes card. Without the flag it reads as doing nothing.
        WindowManager.shared.open(projectKey: key, reusingExistingWindow: !inNewWindow)
    }

    @objc private func openLinkInBrowser() {
        for id in selection { (nodeViews[id] as? CanvasLinkNodeView)?.openInBrowser() }
    }

    @objc private func goBackInLink() {
        for id in selection { (nodeViews[id] as? CanvasLinkNodeView)?.goBack() }
    }

    /// Filtering is a property of the site, so this reaches every selected card showing it — the
    /// same rule sign-in and sign-out already follow.
    @objc private func toggleLinkFiltering() {
        for id in selection {
            guard let card = nodeViews[id] as? CanvasLinkNodeView else { continue }
            card.setFiltered(!card.isFiltered)
        }
    }

    @objc private func signInToLink() {
        for id in selection { (nodeViews[id] as? CanvasLinkNodeView)?.signIn() }
    }

    @objc private func signOutOfLink() {
        for id in selection { (nodeViews[id] as? CanvasLinkNodeView)?.signOut() }
    }

    /// Everything, everywhere, behind a confirmation — it is the one action here that cannot be
    /// undone by clicking something, and the number it costs you is however many sites you use.
    @objc private func signOutEverywhere() {
        let alert = NSAlert()
        alert.messageText = "Sign out of every site?"
        alert.informativeText = "Web cards on every board will forget who you are, and each site will "
            + "ask you to sign in again. Nothing on the boards themselves changes."
        alert.addButton(withTitle: "Sign Out")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { @MainActor in
            await CanvasWebSession.forgetEverything()
            for view in nodeViews.values { (view as? CanvasLinkNodeView)?.reload() }
        }
    }

    // MARK: Which jar a card drinks from

    @objc private func useSharedSession() { setSession(nil) }
    @objc private func usePrivateSession() { setSession(CanvasWebSession.ephemeralName) }

    @objc private func useNamedSession(_ sender: Any?) {
        guard let name = (sender as? NSMenuItem)?.representedObject as? String else { return }
        setSession(name)
    }

    /// A profile named on the spot, which is the only way a first one ever gets made.
    @objc private func useNewSession() {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 22))
        field.placeholderString = "Work"
        let alert = NSAlert()
        alert.messageText = "Name this session"
        alert.informativeText = "Cards on the same session share their sign-ins. Cards on different "
            + "sessions can be signed in to the same site as different people."
        alert.accessoryView = field
        alert.addButton(withTitle: "Use")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != CanvasWebSession.ephemeralName else { return }
        setSession(name)
    }

    /// Let these cards' pages start on their own — or stop letting them.
    ///
    /// Off unless every selected card is already on, which is the rule a checkmark on a mixed
    /// selection has to follow: the box is unticked, so ticking it turns them all on.
    @objc func toggleAutoplay(_ sender: Any?) {
        let cards = selectedLinkCards
        guard !cards.isEmpty else { return }
        let on = !cards.allSatisfy(\.autoplays)
        setMedia(cards, actionName: on ? "Autoplay Media" : "Stop Autoplaying") { node in
            CanvasCardMedia.setAutoplay(on, on: &node)
        }
    }

    /// Hold these cards silent — or let them be heard again.
    @objc func toggleMuted(_ sender: Any?) {
        let cards = selectedLinkCards
        guard !cards.isEmpty else { return }
        let on = !cards.allSatisfy(\.isMuted)
        setMedia(cards, actionName: on ? "Mute Card" : "Unmute Card") { node in
            CanvasCardMedia.setMuted(on, on: &node)
        }
    }

    /// Write a media setting to every one of these cards, as one undoable change — the same shape as
    /// `setSession`, and undoable for the same reason: it is an edit to the document.
    private func setMedia(_ cards: [CanvasLinkNodeView], actionName: String,
                          _ change: (inout CanvasNode) -> Void) {
        let ids = Set(cards.map(\.node.id))
        store.change(actionName) { doc in
            for index in doc.nodes.indices where ids.contains(doc.nodes[index].id) {
                change(&doc.nodes[index])
            }
        }
    }

    /// Put every selected link card on `name`. Undoable, because it is an edit to the document — and
    /// one whose effect is a card signed in as somebody else, which is worth being able to take back.
    private func setSession(_ name: String?) {
        let ids = Set(selectedLinkCards.map(\.node.id))
        guard !ids.isEmpty else { return }
        store.change(name == nil ? "Use Shared Session" : "Change Session") { doc in
            for index in doc.nodes.indices where ids.contains(doc.nodes[index].id) {
                CanvasCardSession.set(name, on: &doc.nodes[index])
            }
        }
    }

    // MARK: A link that becomes a card

    /// Put `address` on the board next to the card it came out of, joined to it by a line.
    ///
    /// ⌘-clicking a link inside a card lands here. A browser answers that gesture with a tab you then
    /// have to go and find; a board can answer it with the page itself, in the place it belongs, still
    /// attached to where it came from — which is the thing a canvas can do that a window full of tabs
    /// cannot, and a fortnight later the line is what says where this came from.
    ///
    /// Placed to the right and nudged down past anything already there, rather than dropped on top of
    /// a card that was in the way.
    func addLinkCard(_ address: String, beside id: String) {
        guard let source = document.node(id: id), let normalized = CanvasAddress.normalized(address)
        else { return }
        let frame = freeFrame(rightOf: source.frame)
        let node = CanvasNode(content: .link(url: normalized), frame: frame)
        // From the source's right to the new card's left: the direction you read the board in, and the
        // direction the page was actually followed in.
        let edge = CanvasEdge(fromNode: id, fromSide: .right, toNode: node.id, toSide: .left)
        store.change("Add Link") { doc in
            doc.nodes.append(node)
            doc.edges.append(edge)
        }
        // Up on screen with the rest, on the end of the order. This used to report "added to the board,
        // behind this tiled view" — honest about where the card had gone and no use at all, since
        // following a link is a request to *read* the page and the tiled view is what you were reading
        // in. Revealing is the untiled half of the same sentence: put the new card where I can see it.
        select([node.id])
        if isTiled {
            addToTiling(node.id)
        } else {
            (scrollView as? CanvasScrollView)?.reveal(node.id)
        }
    }

    /// The first empty spot to the right of `frame`, at the same size.
    private func freeFrame(rightOf frame: CanvasRect) -> CanvasRect {
        freeFrame(from: CanvasRect(x: frame.maxX + 40, y: frame.minY,
                                   width: frame.width, height: frame.height))
    }

    /// The first spot from `start` downwards that nothing is already sitting in.
    private func freeFrame(from start: CanvasRect) -> CanvasRect {
        let gap = 40.0
        var candidate = start
        // Nine tries and then take what you get: a board dense enough to defeat this is one where any
        // answer is a compromise, and a card you can see and drag beats a search that never ends.
        for _ in 0..<9 {
            let clash = document.nodes.contains { !$0.isGroup && $0.frame.intersects(candidate) }
            guard clash else { return candidate }
            candidate = CanvasRect(x: candidate.x, y: candidate.maxY + gap,
                                   width: candidate.width, height: candidate.height)
        }
        return candidate
    }

    @objc private func reloadLink() {
        for id in selection { (nodeViews[id] as? CanvasLinkNodeView)?.reload() }
    }

    @objc private func copyAddress() {
        let addresses = selection.compactMap { id -> String? in
            guard case .link(let url)? = document.node(id: id)?.content else { return nil }
            return url
        }
        guard !addresses.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(addresses.joined(separator: "\n"), forType: .string)
    }

    @objc private func repairSelectedPaths() {
        let ids = selection
        let resolver = store.resolver
        store.change("Repair Card Path") { doc in
            for index in doc.nodes.indices where ids.contains(doc.nodes[index].id) {
                guard case .file(let path, let subpath) = doc.nodes[index].content,
                      case .moved(let url, _) = resolver.resolve(path),
                      let corrected = resolver.storablePath(for: url) else { continue }
                doc.nodes[index].content = .file(path: corrected, subpath: subpath)
            }
        }
    }

    /// Turn a line round. The ends swap, and so do the sides they leave and arrive on — otherwise a
    /// line drawn right-to-left becomes one that leaves the left edge going right and loops back.
    @objc private func reverseSelectedLines() {
        let ids = selection
        store.change("Reverse Line") { doc in
            for index in doc.edges.indices where ids.contains(doc.edges[index].id) {
                let edge = doc.edges[index]
                doc.edges[index].fromNode = edge.toNode
                doc.edges[index].toNode = edge.fromNode
                doc.edges[index].fromSide = edge.toSide
                doc.edges[index].toSide = edge.fromSide
                doc.edges[index].fromEnd = edge.toEnd
                doc.edges[index].toEnd = edge.fromEnd
            }
        }
    }

    /// Open the selected frame as a tab of its own — see `ProjectTab`.
    @objc func openSelectedFrameInTab() {
        guard let id = selection.first, document.node(id: id)?.isGroup == true else { return }
        onOpenInTab(.frame(id))
    }

    /// Rename the workspace that is up.
    ///
    /// **Routed out to the window**, which is what makes this cheaper than §7b said it was. A rename
    /// used to be a remove and a save here, and a tab pinned to the old name simply stopped resolving.
    /// Now that a tab *is* where a workspace lives, the window renames the store and carries its chips
    /// across in the same act, and only pins in other windows are left behind — see
    /// `ProjectSplitViewController.renameWorkspace(named:)`.
    @objc func renameWorkspace(_ sender: Any?) {
        let name = (sender as? NSMenuItem)?.representedObject as? String ?? workspaceName
        guard let name else { return }
        onRenameWorkspace(name)
    }

    /// Forget a named workspace. The tiling stays up — you are still looking at exactly what you were
    /// looking at, it has simply stopped being a thing with a name, which is what deleting one means.
    @objc func deleteWorkspace(_ sender: Any?) {
        let name = (sender as? NSMenuItem)?.representedObject as? String ?? workspaceName
        guard let name else { return }
        onRemoveWorkspace(name)
    }

    /// Switch to a named workspace — the menu's own act, and the reason the list is worth having.
    @objc func goToWorkspace(_ sender: Any?) {
        guard let name = (sender as? NSMenuItem)?.representedObject as? String else { return }
        onGoToWorkspace(name)
    }

    /// Duplicate a named workspace — **the ordinary way a second one comes to exist**.
    ///
    /// You have built a six-tile workspace and want a variant of it. Before this the only answer was
    /// to build the variant from scratch, and §7b made that worse rather than better: a named
    /// workspace is adjusted *live*, so "let me try something without wrecking this" had nowhere left
    /// to go. This is where it goes.
    ///
    /// Routed out to the window rather than done here, because the copy wants a tab: duplicating is
    /// making a thing, and a workspace that exists and is open is a chip (docs/canvas-workspaces.md
    /// §7c). The board's own state is untouched — you keep looking at the original until you click
    /// the copy.
    @objc func duplicateWorkspace(_ sender: Any?) {
        let name = (sender as? NSMenuItem)?.representedObject as? String ?? workspaceName
        guard let name else { return }
        onDuplicateWorkspace(name)
    }

    @objc private func renameSelectedFrame() {
        guard let id = selection.first,
              case .group(let label, let background, let style)? = document.node(id: id)?.content
        else { return }

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 22))
        field.stringValue = label ?? ""
        let alert = NSAlert()
        alert.messageText = "Name this frame"
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        store.change("Rename Frame") { doc in
            guard let index = doc.nodes.firstIndex(where: { $0.id == id }) else { return }
            doc.nodes[index].content = .group(label: name.isEmpty ? nil : name,
                                              background: background, backgroundStyle: style)
        }
    }
}

// MARK: - Zoom, and which commands are live

/// Zoom answered by the board rather than by the window controller, because the board is the first
/// responder — so the menu items reach it directly, and `validateUserInterfaceItem` on the same object
/// is what dims them in every window that isn't a canvas.
extension CanvasBoardView: NSUserInterfaceValidations {
    /// ⌘+ / ⌘− / ⌘0. The board, unless you have stepped into a card that has a size of its own.
    ///
    /// Stepping into a card is saying "I am working in here now", and inside a web page or a card of
    /// prose ⌘+ has a well-known meaning that is not "move the camera". It is also the only meaning
    /// available in a tiled view, where the board's zoom is fixed at 100% and the card's frame belongs
    /// to the arrangement — which is exactly where an 11px page is most likely to be in front of you.
    @objc func zoomIn(_ sender: Any?) {
        guard !zoomEngagedCard(by: 1) else { return }
        scrollView?.canvasScroll?.zoom(by: 1.25)
    }

    /// **And out of any workspace, to the board.**
    ///
    /// A project's notes are its own card tiled alone, so the thing one step further out from them is
    /// the board — which is exactly what ⌘− means everywhere else, said about a workspace instead of a
    /// plane. That argument was written for the note view and was never about the note view: a tiling
    /// of six cards is a workspace too, and the board is one step further out from it in exactly the
    /// same sense.
    ///
    /// It costs nothing to say it for all of them, because a tiled board's own zoom is fixed — so this
    /// was every tiled view where the key did nothing at all, not just one of them. And it buys the
    /// thing a tiled view most needed: **a way out that is always a keystroke.** ⌘↩ is the way out only
    /// when there is nothing left to narrow to, which stops being true the moment you click a tile
    /// (a click selects it, so ⌘↩ then means "fill the window with this one"); Escape unwinds the
    /// drill-in and deliberately stops at the root; and the pill's ✕ needs a pointer. See `untile`
    /// and `leaveTiling`.
    @objc func zoomOut(_ sender: Any?) {
        guard !zoomEngagedCard(by: -1) else { return }
        guard !isTiled else { return onGoToCanvas() }
        scrollView?.canvasScroll?.zoom(by: 1 / 1.25)
    }

    @objc func zoomActualSize(_ sender: Any?) {
        if let card = zoomableEngagedCard { return setContentZoom(CanvasCardZoom.normal, on: card) }
        scrollView?.canvasScroll?.zoomToActualSize()
    }

    /// Hold this tile's size against the window, or let it go back to sharing. See `togglePinTile`.
    @objc func togglePinTileSize(_ sender: Any?) {
        guard let id = pinnableTile else { return NSSound.beep() }
        togglePinTile(id)
    }

    /// The tile a pin would act on: one selected tile, in a tiled view that has a run to pin along.
    var pinnableTile: String? {
        guard let tiling, tiling.ids.count > 1, selection.count == 1, let id = selection.first,
              tiling.ids.contains(id) else { return nil }
        // A grid of rows *and* columns has no run: a width there belongs to a column, shared with
        // tiles nobody selected. See `CanvasTiling.grid`.
        if tiling.arrangement == .grid, gridRunIsHorizontal == nil { return nil }
        return id
    }

    /// What the pin command is called: which way it goes, and which dimension it holds.
    var pinTileTitle: String {
        guard let id = pinnableTile else { return "Pin Tile Width" }
        let dimension = tileRunIsVertical(id) ? "Height" : "Width"
        return isTilePinned(id) ? "Unpin \(dimension)" : "Pin \(dimension)"
    }

    /// The card ⌘+ would act on: the one you are stepped into, if its kind has an answer.
    var zoomableEngagedCard: CanvasNodeView? {
        nodeViews.values.first { $0.isEngaged && $0.zoomsItsContent }
    }

    private func zoomEngagedCard(by direction: Int) -> Bool {
        guard let card = zoomableEngagedCard else { return false }
        let next = CanvasCardZoom.stepped(card.contentZoom, by: direction)
        guard next != card.contentZoom else { return true }  // at the end of the ladder; not the board's
        setContentZoom(next, on: card)
        return true
    }

    /// Written to the document, so it is still there tomorrow — see `CanvasCardZoom`.
    ///
    /// Quietly, though. It saves but registers no undo: a zoom is how you are looking at a card rather
    /// than an edit to it, and four presses of ⌘+ should not put four steps on the stack between you
    /// and the last thing you actually changed.
    private func setContentZoom(_ zoom: Double, on card: CanvasNodeView) {
        let id = card.node.id
        store.changeQuietly { doc in
            guard let index = doc.nodes.firstIndex(where: { $0.id == id }) else { return }
            CanvasCardZoom.set(zoom, on: &doc.nodes[index])
        }
    }
    // MARK: The page commands, from the menu bar

    /// What a Page command acts on: the card you are inside, or everything selected.
    ///
    /// The same rule the zoom commands already follow — inside a card they mean the card — extended to
    /// the case a board has that a browser doesn't: several pages selected at once. Reload on four
    /// selected cards reloads four, which is the bulk gesture the contextual menu has always had and
    /// the menu bar never offered.
    private var pageTargets: [CanvasLinkNodeView] {
        if let engaged = engagedPageCard as? CanvasLinkNodeView { return [engaged] }
        return selectedLinkCards
    }

    @objc func pageBack(_ sender: Any?) { pageTargets.forEach { $0.goBack() } }
    @objc func pageForward(_ sender: Any?) { pageTargets.forEach { $0.goForward() } }
    @objc func pageReload(_ sender: Any?) { pageTargets.forEach { $0.reload() } }
    @objc func pageHome(_ sender: Any?) { pageTargets.forEach { $0.goHome() } }
    @objc func pageOpenInBrowser(_ sender: Any?) { pageTargets.forEach { $0.openInBrowser() } }

    /// ⌘L. The address of the card you are inside, ready to be typed over.
    ///
    /// It puts the keyboard in the header's field rather than opening a box, because that field *is*
    /// this window's address bar and ⌘L has meant "go to the address bar" for thirty years. On a card
    /// you have merely selected there is no address bar up, and the honest equivalent is the edit —
    /// which is a different act, and is named differently on the menu.
    @objc func pageOpenAddress(_ sender: Any?) {
        if engagedPageCard is CanvasLinkNodeView { onFocusAddress?() }
        else if selectedLinkCards.count == 1 { editLinkAddress() }
    }

    /// How often this board reloads its pages. The item carries the interval in seconds, or 0 for
    /// never — see `CanvasBoardView.refreshChoices`.
    @objc func setPageRefresh(_ sender: Any?) {
        guard let seconds = (sender as? NSMenuItem)?.representedObject as? Double else { return }
        refreshInterval = seconds > 0 ? seconds : nil
    }

    @objc func zoomToFit(_ sender: Any?) { scrollView?.canvasScroll?.zoomToFit() }

    @objc func toggleConnectMode(_ sender: Any?) { mode = mode == .connect ? .view : .connect }

    @objc func setTileArrangement(_ sender: Any?) {
        guard let raw = (sender as? NSMenuItem)?.representedObject as? String,
              let arrangement = CanvasTiling.Arrangement(rawValue: raw) else { return }
        // Choosing an arrangement with nothing tiled is a request to tile — otherwise the item is a
        // setting for a state you have to already be in to reach it.
        if isTiled { setArrangement(arrangement) } else { tileSelection(nil) }
    }

    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(toggleConnectMode(_:)):
            // The validated item *is* the menu item, which is the only chance to tick it — this
            // object answers `validateUserInterfaceItem`, so AppKit never asks `validateMenuItem`.
            (item as? NSMenuItem)?.state = mode == .connect ? .on : .off
            return true
        case #selector(tileSelection(_:)):
            // The one command that says what it will do rather than being dimmed when it can't: with a
            // selection it tiles that, with none it tiles what you can see, and once tiled it is the way
            // back out. Only a board with nothing on it has nothing for it to mean.
            (item as? NSMenuItem)?.title = tileCommandTitle
            return isTiled || document.nodes.contains { !$0.isGroup }
        case #selector(renameWorkspace(_:)), #selector(deleteWorkspace(_:)),
             #selector(duplicateWorkspace(_:)):
            // All three act on the workspace you are in, so all three want one with a name. Retitled
            // with it, because "Delete Workspace" under a list of five is a fair question to have
            // answered.
            if let entry = item as? NSMenuItem {
                switch entry.action {
                case #selector(deleteWorkspace(_:)):
                    entry.title = workspaceName.map { "Delete “\($0)”" } ?? "Delete Workspace"
                case #selector(duplicateWorkspace(_:)):
                    entry.title = workspaceName.map { "Duplicate “\($0)”\u{2026}" }
                        ?? "Duplicate Workspace\u{2026}"
                default: break
                }
            }
            return workspaceName != nil
        case #selector(goToWorkspace(_:)):
            guard let entry = item as? NSMenuItem else { return false }
            let names = workspaceNames()
            guard entry.tag < names.count else {
                // Past the end: named for its slot, dim, and pointing at nothing — the same answer
                // "Go to Frame" gives, so nine empty rows never look like nine broken commands.
                entry.title = "Workspace \(entry.tag + 1)"
                entry.representedObject = nil
                entry.state = .off
                return false
            }
            entry.title = names[entry.tag]
            entry.representedObject = names[entry.tag]
            entry.state = names[entry.tag] == workspaceName ? .on : .off
            return true
        case #selector(setTileArrangement(_:)):
            (item as? NSMenuItem).map { entry in
                entry.state = (entry.representedObject as? String) == tiling?.arrangement.rawValue
                    ? .on : .off
            }
            return true
        case #selector(goToFrame(_:)):
            guard let entry = item as? NSMenuItem else { return false }
            let frames = self.frames
            guard entry.tag < frames.count else {
                entry.title = "Frame \(entry.tag + 1)"
                return false
            }
            // Named, so the menu is a list of this board's frames rather than nine numbers.
            if case .group(let label, _, _) = frames[entry.tag].content, let label, !label.isEmpty {
                entry.title = label
            } else {
                entry.title = "Frame \(entry.tag + 1)"
            }
            return true
        case #selector(copy(_:)), #selector(cut(_:)), #selector(duplicate(_:)):
            // Not while tiled: a tiled view is a way of looking, and cutting a card out of one would be
            // editing the board through a lens that has moved everything.
            return !selection.isEmpty && !isTiled
        case #selector(paste(_:)), #selector(pasteHere):
            // `pasteHere` is the board menu's own item and was answered by nothing, so it fell to the
            // `default` below and was live over an empty pasteboard. It is the same question as
            // `paste(_:)` and gets the same answer.
            return !isTiled && NSPasteboard.general.types?.isEmpty == false
        case #selector(newCardHere), #selector(newLinkHere), #selector(newFileHere):
            // Live while tiled, which they were not. The old reason was that a card added through a
            // tiled view would land at a point on a board the lens has moved out from under you — true,
            // and answered by `addCard`, which steps the card clear and puts a tile up for it. The
            // right-click that reaches these while tiled is one on a gap that isn't a divider.
            return true
        case #selector(newFrameHere):
            // Still not, and alone in that. A frame is a container of cards rather than a card, so
            // there is no tile it could become — it would be an edit made entirely behind the view.
            return !isTiled
        case #selector(toggleShownPart(_:)):
            guard let raw = (item as? NSMenuItem)?.representedObject as? String,
                  let part = CanvasCardShows.Part(rawValue: raw) else { return false }
            let cards = selectedProjectCards
            guard !cards.isEmpty else { return false }
            let on = !cards.allSatisfy { $0.shows.shows(part) }
            // Dim rather than a click that does nothing. The last part a card draws cannot be turned
            // off, and an item that would refuse should look like it will.
            return cards.contains { $0.shows.setting(part, to: on) != nil }
        case #selector(toggleCompletedTasks(_:)):
            // Nothing to filter on a card that isn't showing tasks at all.
            return selectedProjectCards.contains(where: \.shows.tasks)
        case #selector(setSessionScope(_:)):
            return !selectedProjectCards.isEmpty
        case #selector(newSession(_:)), #selector(newTask(_:)), #selector(editProjectDetails(_:)):
            return hasProjectCommandTarget
        case #selector(removeMenuTile(_:)):
            return menuTile != nil
        case #selector(removeTile(_:)):
            return focusedTile != nil
        case #selector(promoteTile(_:)):
            // Only where it means something, which is what the contextual menu says by leaving the
            // item out altogether: a grid has no master, and the master is already the master.
            guard let id = focusedTile, tiling?.arrangement == .masterStack else { return false }
            return tiling?.ids.first != id
        case #selector(goToCanvasCommand(_:)):
            return isTiled
        case #selector(togglePinTileSize(_:)):
            (item as? NSMenuItem)?.title = pinTileTitle
            return pinnableTile != nil
        case #selector(zoomIn(_:)), #selector(zoomActualSize(_:)):
            // Live while a zoomable card is engaged even in a tiled view, because there they mean the
            // card and not the board — see `zoomIn`.
            return !isTiled || zoomableEngagedCard != nil
        case #selector(zoomOut(_:)):
            // Live everywhere, unlike its siblings: in a tiled view zooming out of a workspace is the
            // board, which is the one thing ⌘− can always mean here. See `zoomOut`.
            return true
        case #selector(zoomToFit(_:)):
            // A tiled view is a fixed view: the tiles were laid out to fill this window at this zoom,
            // and changing it would slide them out of it. Dim rather than ignored, so the menu says so.
            return !isTiled
        case #selector(pageBack(_:)):
            return pageTargets.contains { $0.canGoBack }
        case #selector(pageForward(_:)):
            return pageTargets.contains { $0.canGoForward }
        case #selector(pageReload(_:)):
            // Named for what it will do to how many, like the tiling command above it.
            (item as? NSMenuItem)?.title = pageTargets.count > 1 ? "Reload \(pageTargets.count) Pages"
                                                                 : "Reload Page"
            return !pageTargets.isEmpty
        case #selector(pageHome(_:)):
            // Only when there is somewhere to go back to: a card sitting on its own address is already
            // home, and an item that is always live and usually does nothing teaches nothing.
            return pageTargets.contains { $0.hasWandered }
        case #selector(pageOpenInBrowser(_:)):
            return !pageTargets.isEmpty
        case #selector(pageOpenAddress(_:)):
            return engagedPageCard is CanvasLinkNodeView || selectedLinkCards.count == 1
        case #selector(setPageRefresh(_:)):
            (item as? NSMenuItem).map { entry in
                let seconds = entry.representedObject as? Double ?? 0
                entry.state = (seconds > 0 ? seconds : nil) == refreshInterval ? .on : .off
            }
            // A board with no web cards on it has nothing to refresh, and says so rather than keeping
            // a setting nothing will ever read.
            return document.nodes.contains { if case .link = $0.content { return true }; return false }
        case #selector(selectAll(_:)):
            return true
        default:
            return true
        }
    }
}

extension NSScrollView {
    /// This scroll view, if it is a canvas's. The board holds its scroller as an `NSScrollView` so the
    /// two aren't mutually dependent at construction; the zoom commands, the focus moves and the tiling
    /// all need the canvas one.
    var canvasScroll: CanvasScrollView? { self as? CanvasScrollView }
}


// MARK: - Finding a card

extension CanvasBoardView {

    /// Every card whose content mentions `query`, in the order they sit in the file.
    ///
    /// Searches what a card *says* rather than what it stores where the two differ: a file card
    /// matches on its path, so "Flexcompute" finds it, and on its basename, so "Notes.md" does too. A
    /// board of 117 cards is several screens, and the alternative to this is panning until you spot it.
    ///
    /// A web card matches on its address **and on the name of the page at it**, which is the half a
    /// person actually remembers. Eleven cards reading `jira.example.com/browse/PM-4127` are eleven
    /// cards nobody can search; the same eleven are findable the moment "billing" matches the one
    /// called "Billing rollover fails on renewal". The name comes from `CanvasPageTitles`, so it is
    /// there for cards that have never been loaded in this window — which are most of them, on a board
    /// you have just opened.
    func matches(_ query: String) -> [String] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return [] }
        return document.nodes.filter { node in
            switch node.content {
            case .text(let text): return text.localizedCaseInsensitiveContains(needle)
            case .link(let url):
                return url.localizedCaseInsensitiveContains(needle)
                    || CanvasPageTitles.of(url)?.localizedCaseInsensitiveContains(needle) == true
            case .file(let path, let subpath):
                return path.localizedCaseInsensitiveContains(needle)
                    || (subpath?.localizedCaseInsensitiveContains(needle) ?? false)
            case .group(let label, _, _):
                return label?.localizedCaseInsensitiveContains(needle) ?? false
            }
        }
        .map(\.id)
    }

    /// Select what `query` finds and frame the first of them.
    ///
    /// Selecting *all* the matches rather than stepping through one at a time, because on a board the
    /// useful answer to "where is X" is usually "in these four places" — and the selection is already
    /// the board's way of saying that. Stepping is `findNext`.
    @discardableResult
    func find(_ query: String) -> [String] {
        let found = matches(query)
        selection = Set(found)
        findCursor = 0
        if let first = found.first { revealCard(first) }
        return found
    }

    /// Move to the next match, wrapping. Return in the search field.
    func findNext(_ query: String) {
        let found = matches(query)
        guard !found.isEmpty else { return }
        findCursor = (findCursor + 1) % found.count
        revealCard(found[findCursor])
    }

    private func revealCard(_ id: String) {
        (scrollView as? CanvasScrollView)?.reveal(id)
    }
}
