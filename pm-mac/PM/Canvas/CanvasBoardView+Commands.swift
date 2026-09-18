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
    /// The board's own pasteboard flavour. Kept as a name here because `CanvasBoardView+Dropping`
    /// and the drop reader both spell it `Self.pasteboardType`; it belongs to `CanvasClipping`.
    static var pasteboardType: NSPasteboard.PasteboardType { CanvasClipping.pasteboardType }

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
        CanvasClipping.write(selection, from: document, to: .general)
    }

    @objc func cut(_ sender: Any?) {
        copy(sender)
        deleteSelection()
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

    /// Paste whatever is on the pasteboard, as the kind of card it deserves.
    func paste(at where_: CanvasPoint?) {
        _ = accept(NSPasteboard.general, at: where_ ?? centreOfVisibleBoard)
    }

    /// Read `pasteboard` and put whatever is on it on the board, centred at `at`. A drop is a paste
    /// that names its own place, and reads the pasteboard the same way — see `CanvasDrop`, which owns
    /// the order things are recognised in, and `CanvasBoardView+Dropping`.
    @discardableResult
    func accept(_ pasteboard: NSPasteboard, at: CanvasPoint) -> Bool {
        guard let drop = CanvasDrop.read(pasteboard, cardsType: Self.pasteboardType) else { return false }
        return commit(drop, frames: drop.frames(centredOn: at))
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

    /// Which of `files` the vault has no path for — the ones a card can only point at absolutely.
    ///
    /// Pulled out as a static function of the resolver so the decision can be read and tested without
    /// a board: it is `storablePath`'s answer, asked of each, and nothing else.
    static func outside(_ files: [URL], of resolver: CanvasFileResolver) -> [URL] {
        files.filter { resolver.storablePath(for: $0) == nil }
    }

    /// **Ask whether a file from outside the vault should be copied in, or pointed at where it is.**
    ///
    /// A canvas stores a file card's path from the vault root, and a file outside the vault has no such
    /// path — so the card is written with an absolute one. PM reads that back correctly now (see
    /// `CanvasFileResolver`, step 0) and Obsidian never will: it resolves the path against the vault
    /// and finds nothing. Both answers are therefore defensible and they are not the same answer, which
    /// is why this asks rather than deciding.
    ///
    /// **Copying is the default button** because it is the one that makes the card mean the same thing
    /// in both apps, and because it is what the board already does with a pasted picture — into the
    /// attachments folder beside the canvas, under the file's own name. Linking keeps one copy of the
    /// file and is the right answer for something large, something that changes, or something that
    /// lives where it lives on purpose.
    ///
    /// **Once per drop, not once per file**, and the whole drop takes the one answer: a folder of
    /// markdown dragged in is one decision, and being asked six times is being asked to do the work of
    /// the dialog.
    ///
    /// Asked on the next turn of the runloop, which is the part that is not merely tidiness. This is
    /// called from inside `performDragOperation`, where AppKit's own drag loop is still unwinding; a
    /// modal session started there is a nested event loop inside that one. The drop is reported
    /// accepted straight away — it *was* — and the cards go up when there is an answer.
    private func askWhereOutsidersGo(_ files: [URL], frames: [CanvasRect]) -> Bool {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let outsiders = Self.outside(files, of: store.resolver)
            let alert = NSAlert()
            alert.messageText = outsiders.count == 1
                ? "\(outsiders[0].lastPathComponent) is outside your vault"
                : "\(outsiders.count) of these files are outside your vault"
            alert.informativeText = "A card can point at it where it is, which only Folio will be able to "
                + "follow — Obsidian resolves a card's path inside the vault. Copying it in puts it "
                + "beside this board, where both apps can see it."
            alert.addButton(withTitle: "Copy In")
            alert.addButton(withTitle: "Point At It")
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                let moved = Set(outsiders)
                commit(.files(files.map { moved.contains($0) ? self.copyIn($0) ?? $0 : $0 }),
                       frames: frames, asking: false)
            case .alertSecondButtonReturn:
                commit(.files(files), frames: frames, asking: false)
            default:
                break
            }
        }
        return true
    }

    /// Copy a dropped file into the vault, beside this board. Nil when the vault would not take it,
    /// which leaves the card pointing at the original — a worse card than the one that was asked for,
    /// and a better outcome than no card at all.
    private func copyIn(_ file: URL) -> URL? {
        do {
            return try copyNoteAttachment(file, forNoteAt: store.url)
        } catch {
            Log.write("canvas file copy failed: \(error)")
            return nil
        }
    }

    /// Make the cards `drop` describes, at `frames` — one per card, in the order `CanvasDrop` makes
    /// them. False when there turned out to be nothing to make, which for a picture with no file means
    /// the vault would not take it.
    @discardableResult
    func commit(_ drop: CanvasDrop, frames: [CanvasRect], asking: Bool = true) -> Bool {
        // **In a tiled view the drop goes up as tiles**, which is what `addCard` does for every other
        // way of adding a card — a link carried out of one tile and let go in the window is a request
        // to read it beside the others. Until this, it went onto the board behind the tiles, where
        // nothing showed it had arrived. The point you let go at is a region of the board the tiles
        // are drawn over, so the cards are stepped clear of what lives there first — as one set, so
        // several keep their arrangement.
        var frames = frames
        if isTiled, let box = Self.bounds(of: frames) {
            frames = Self.shifted(frames, onto: freeFrame(from: box), from: box)
        }
        func cards(_ contents: [CanvasContent]) -> CanvasDocument {
            CanvasDocument(nodes: zip(contents, frames).map { CanvasNode(content: $0, frame: $1) })
        }
        func file(_ url: URL) -> CanvasContent {
            .file(path: store.resolver.storablePath(for: url) ?? url.path, subpath: nil)
        }
        switch drop {
        case .cards(var copied):
            for index in copied.nodes.indices where index < frames.count {
                copied.nodes[index].frame = frames[index]
            }
            insert(copied, at: nil, actionName: "Paste")
        case .files(let files):
            // **A file from outside the vault is a question, and it is asked here.** See
            // `askWhereOutsidersGo`; `asking` is false on the way back through it with the answer.
            if asking, !Self.outside(files, of: store.resolver).isEmpty {
                return askWhereOutsidersGo(files, frames: frames)
            }
            insert(cards(files.map(file)), at: nil, actionName: files.count > 1 ? "Add Files" : "Add File")
        case .image(let data, let ext):
            guard let saved = save((data: data, ext: ext)) else { return false }
            insert(cards([file(saved)]), at: nil, actionName: "Add File")
        case .links(let links):
            // The name the browser dropped beside the address, before the cards are built — so a card
            // is named on the way up rather than after its page has loaded. Remembered where every
            // card reads names from, so this also names the ones already on the board.
            for link in links {
                if let name = link.name { CanvasPageTitles.remember(name, for: link.address) }
            }
            insert(cards(links.map { .link(url: $0.address) }), at: nil,
                   actionName: links.count > 1 ? "Add Links" : "Add Link")
        case .text(let text):
            insert(cards([.text(text)]), at: nil, actionName: "Paste")
        }
        // `insert` selects what it made. In document order, so several go up in the order they were
        // dropped.
        if isTiled {
            addToTiling(document.nodes.filter { selection.contains($0.id) }.map(\.id))
        }
        return true
    }

    // MARK: Duplicating

    @objc func duplicate(_ sender: Any?) {
        guard !selection.isEmpty else { return }
        insert(CanvasClipping.clipping(of: selection, from: document),
               at: nil, actionName: "Duplicate", offsetBy: 24)
    }

    // MARK: Tidying

    /// Tidy Up (backlog 7): the selection, or the cards in a lone frame, laid out as a clean grid in
    /// one undoable change — see `CanvasTidy`. Already tidy is not an error, so it does nothing quietly.
    @objc func tidyUp(_ sender: Any?) {
        guard !isTiled, let plan = CanvasTidy.plan(selection, in: document) else { return NSSound.beep() }
        guard !plan.isEmpty else { return }
        store.change("Tidy Up") { doc in
            for index in doc.nodes.indices {
                if let frame = plan[doc.nodes[index].id] { doc.nodes[index].frame = frame }
            }
        }
    }

    var canTidy: Bool { !isTiled && CanvasTidy.plan(selection, in: document) != nil }

    // MARK: Sizing

    /// Size ▸ a proportion (backlog 27): each selected card at `CanvasCardSize.ratios[tag]`, its width
    /// and top-left kept — see `CanvasCardSize`.
    @objc func setCardRatio(_ sender: NSMenuItem) {
        guard canSize, CanvasCardSize.ratios.indices.contains(sender.tag) else { return NSSound.beep() }
        let ratio = CanvasCardSize.ratios[sender.tag]
        resizeSelection("Set Size to \(ratio.title)") { CanvasCardSize.frame($0, at: ratio) }
    }

    /// Size ▸ Exact Size…: a width and a height, seeded from the selection where its cards agree and
    /// left blank where they don't, and a blank field leaves that axis of every card alone.
    @objc func setCardSize(_ sender: Any?) {
        guard canSize else { return NSSound.beep() }
        let frames = selectedFrames
        func seed(_ value: (CanvasRect) -> Double) -> String {
            let values = Set(frames.map { Int(value($0).rounded()) })
            return values.count == 1 ? String(values.first!) : ""
        }
        let width = NSTextField(frame: NSRect(x: 0, y: 0, width: 90, height: 22))
        let height = NSTextField(frame: NSRect(x: 118, y: 0, width: 90, height: 22))
        width.stringValue = seed(\.width)
        height.stringValue = seed(\.height)
        width.placeholderString = "Width"
        height.placeholderString = "Height"
        let by = NSTextField(labelWithString: "×")
        by.frame = NSRect(x: 96, y: 2, width: 16, height: 18)
        by.alignment = .center
        let fields = NSView(frame: NSRect(x: 0, y: 0, width: 208, height: 22))
        [width, by, height].forEach(fields.addSubview)

        let alert = NSAlert()
        alert.messageText = frames.count > 1 ? "Size of \(frames.count) Cards" : "Card Size"
        alert.informativeText = "In points. A blank field leaves that side as it is."
        alert.accessoryView = fields
        alert.addButton(withTitle: "Set Size")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = width
        guard let window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            let w = Double(width.stringValue.trimmingCharacters(in: .whitespaces))
            let h = Double(height.stringValue.trimmingCharacters(in: .whitespaces))
            guard w != nil || h != nil else { return }
            self?.resizeSelection("Set Size") { CanvasCardSize.frame($0, width: w, height: h) }
        }
    }

    /// Sizing is the board's: in a tile a card is as big as its slot.
    var canSize: Bool { !isTiled && !selection.isEmpty }

    private var selectedFrames: [CanvasRect] {
        document.nodes.filter { selection.contains($0.id) }.map(\.frame)
    }

    private func resizeSelection(_ name: String, _ resize: (CanvasRect) -> CanvasRect) {
        let plan = CanvasCardSize.plan(selection, in: document, resize)
        guard !plan.isEmpty else { return }
        store.change(name) { doc in
            for index in doc.nodes.indices {
                if let frame = plan[doc.nodes[index].id] { doc.nodes[index].frame = frame }
            }
        }
    }

    /// The Size submenu, for the card menu and the menu bar alike: the proportions, then Exact Size.
    /// Targetless, so whichever board is answering gets it and ticks the proportion its cards share.
    static func sizeMenu() -> NSMenu {
        let menu = NSMenu(title: "Size")
        for (index, ratio) in CanvasCardSize.ratios.enumerated() {
            let item = menu.addItem(withTitle: ratio.title, action: #selector(setCardRatio(_:)), keyEquivalent: "")
            item.tag = index
            // The square divides the landscape proportions from the portrait ones.
            if ratio.width == ratio.height {
                menu.insertItem(.separator(), at: menu.items.count - 1)
                menu.addItem(.separator())
            }
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Exact Size…", action: #selector(setCardSize(_:)), keyEquivalent: "")
        return menu
    }

    /// Copies of the selection exactly on top of it, selected — the start of an ⌥-drag, which then
    /// carries the copies away and leaves the originals where they were.
    func duplicateInPlace() {
        guard !selection.isEmpty else { return }
        insert(CanvasClipping.clipping(of: selection, from: document), at: nil, actionName: "Duplicate")
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
        // Picking cards on the board, a click is a pick and nothing else — including this one.
        guard !isPicking else { return nil }
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
            // **A tab is its card.** Right-clicking one is asking what that card can do, so the menu is
            // the card's, the way a tile's is — with the tab's own verbs where the tile's would be. The
            // tab comes to the front first: every command below acts on the selection, and a card you
            // cannot see is not one to edit an address or reload blind.
            //
            // Asked before the boundary, whose reach laps a few points onto the strip below it: a tab is
            // a control you aimed at, and the boundary is still one point further up.
            if let chip = tabChip(at: where_) {
                showTab(chip.card)
                menuTile = chip.card
                buildCardMenu(menu, id: chip.card, includingTiling: false)
                menu.insertItem(.sectionHeader(title: "Card"), at: 0)
                addTabSection(menu, id: chip.card)
                return menu
            }
            // The rest of the strip — the + included — is the tile's title bar, and its menu is the
            // tile's: what goes into it, and everything a tile can be told.
            if let tile = tabStrip(at: where_) {
                if !selection.contains(tile) { selection = [tile] }
                menuTile = tile
                buildTabStripMenu(menu, tile: tile)
                return menu
            }
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
                buildTileMenu(menu, id: id)
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

    /// A tile's whole menu: the card's commands, then the tile's, each under its own header — see
    /// `addTileSection`. The first header goes in afterwards because `buildCardMenu` is shared with the
    /// untiled board, where there is only one kind of object and a header would be labelling the whole
    /// menu.
    private func buildTileMenu(_ menu: NSMenu, id: String) {
        buildCardMenu(menu, id: id, includingTiling: false)
        menu.insertItem(.sectionHeader(title: "Card"), at: 0)
        addTileSection(menu, id: id)
    }

    /// What the card you are standing in can be told — the focused tile, else the card you have
    /// stepped into — as the header's `…` opens it.
    ///
    /// **The same menu a right-click on it gives, not a list of its own.** The header's menu used to be
    /// written out separately, in SwiftUI, and so knew only what somebody had remembered to copy into
    /// it: the page's commands and four of the tile's. Anything a kind of card added to its contextual
    /// menu — a project card's Shows, a folder card's View — was missing from the one menu that is
    /// always on screen. Built here, a card's commands appear in both places or in neither.
    func cardActionsMenu() -> NSMenu? {
        guard let id = actionsCard else { return nil }
        if !selection.contains(id) { selection = [id] }
        menuPoint = nil
        menuDivider = nil
        let menu = NSMenu()
        if tiling?.ids.contains(id) == true {
            menuTile = id
            buildTileMenu(menu, id: id)
        } else {
            menuTile = nil
            buildCardMenu(menu, id: id)
        }
        return menu
    }

    /// The one card the header's `…` is about: the focused tile, else the page you have stepped into,
    /// else the one card selected. Nil for several, for none, and for a line — a line's menu is about
    /// the line, and the header's is about a card.
    var actionsCard: String? {
        if let id = focusedTile ?? engagedPageCard?.node.id { return id }
        guard selection.count == 1, let id = selection.first, document.node(id: id) != nil else { return nil }
        return id
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
                let fresh = add(menu, "Start a New Session", #selector(startNewSession(_:)))
                key(fresh, "n", modifiers: [.command, .shift, .option])
                fresh.isAlternate = true
                key(add(menu, "New Task", #selector(newTask(_:))), "n")
                // No key, because the window has none for it either — the brief is reached by
                // double-clicking it. This item is for the case that gesture cannot serve: a project
                // with no brief yet draws nothing on a card, so there is nothing to double-click.
                add(menu, "Edit Details\u{2026}", #selector(editProjectDetails(_:)))
                addShowsMenu(menu)
            }
            // A folder card's own two: where it points, and how it lays that out. First, as a project
            // card's are, because they are what this card is rather than what any file card can do.
            if (nodeViews[id] as? CanvasFileNodeView)?.folderURL != nil {
                add(menu, "Change Folder\u{2026}", #selector(changeFolder(_:)))
                addFolderViewMenu(menu)
                menu.addItem(.separator())
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
            if selectedLinkCards.count == 1, let card = nodeViews[id] as? CanvasLinkNodeView,
               card.liveURL != nil {
                add(menu, "Open Page as New Card", #selector(openMenuPageAsNewCard))
            }
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
                // Per site for the same reason: a site that turns Safari away turns away every card on it.
                // A tick only where every selected site already agrees, as Size does.
                let identify = NSMenu(title: "Identify As")
                let identities = Set(selectedLinkCards.map(\.identity))
                for (index, identity) in CanvasBrowserIdentity.allCases.enumerated() {
                    let item = add(identify, identity.title, #selector(setLinkIdentity(_:)))
                    item.tag = index
                    item.state = identities == [identity] ? .on : .off
                }
                menu.addItem(withTitle: "Identify \(site) As", action: nil, keyEquivalent: "").submenu = identify
                // Per card, unlike the three above: what a page is allowed to play is a fact about
                // this card on this board — one embed you want running and the eleven beside it you
                // don't — rather than about the site it happens to be on. See `CanvasCardMedia`.
                let count = selectedLinkCards.count
                let autoplay = add(menu, CanvasCardMedia.autoplayTitle(count), #selector(toggleAutoplay))
                autoplay.state = selectedLinkCards.allSatisfy(\.autoplays) ? .on : .off
                let muted = add(menu, CanvasCardMedia.muteTitle(count), #selector(toggleMuted))
                muted.state = selectedLinkCards.allSatisfy(\.isMuted) ? .on : .off
                let running = add(menu, CanvasCardMedia.keepRunningTitle(count), #selector(toggleKeepRunning))
                running.state = selectedLinkCards.allSatisfy(\.keepsPageRunning) ? .on : .off
                addSessionMenu(menu, card: card)
            }
        case .text where nodeViews[id] is CanvasViewNodeView:
            // A view has no text to edit — its text is the one line Obsidian shows — so its menu is its
            // two settings: when, and which projects (docs/views.md D2).
            addViewMenus(menu)
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
        if canTidy { key(add(menu, "Tidy Up", #selector(tidyUp(_:))), "t", modifiers: [.control, .option]) }
        if canSize {
            let size = Self.sizeMenu()
            size.items.forEach { $0.target = self }
            menu.addItem(withTitle: "Size", action: nil, keyEquivalent: "").submenu = size
        }
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
    ///
    /// **One radio list, and nothing else.** This was three checkboxes and two more settings under two
    /// separators, and the shape lied twice over: Completed Tasks did nothing on a card not showing
    /// tasks, and the twenty-one arrangements those five controls could reach were not twenty-one
    /// cards anybody wanted. Four named cards is the whole vocabulary — see `CanvasCardShows`, which
    /// also explains why `current` and `tasks` are both here rather than one being a filter on the
    /// other.
    private func addShowsMenu(_ menu: NSMenu) {
        let cards = selectedProjectCards
        guard !cards.isEmpty else { return }
        let shows = NSMenu(title: "Shows")
        for preset in CanvasCardShows.menuCases {
            let entry = add(shows, preset.title, #selector(setShowsPreset(_:)))
            entry.representedObject = preset.rawValue
            // Ticked only when every selected card agrees, which is how a mixed selection reads as
            // mixed rather than as whatever the first card happened to say. A radio list showing no
            // tick at all is the honest picture of six cards set six ways.
            entry.state = cards.allSatisfy { $0.shows == preset } ? .on : .off
        }

        let item = menu.addItem(withTitle: "Shows", action: nil, keyEquivalent: "")
        item.submenu = shows
    }

    /// The view cards in the selection — what the Period and Projects menus act on.
    private var selectedViewCards: [CanvasViewNodeView] {
        selection.compactMap { nodeViews[$0] as? CanvasViewNodeView }
    }

    /// A view's two settings, as radio lists — ticked only where every selected view agrees, like Shows.
    private func addViewMenus(_ menu: NSMenu) {
        let cards = selectedViewCards
        guard !cards.isEmpty else { return }
        // Only a Day has a *when*: Waiting is about now, and a search is about words.
        if cards.allSatisfy({ $0.spec.kind.hasPeriod }) { addPeriodMenu(menu, cards) }
        addProjectsMenu(menu, cards)
    }

    private func addPeriodMenu(_ menu: NSMenu, _ cards: [CanvasViewNodeView]) {
        let periods = NSMenu(title: "Period")
        var choices = CanvasViewSpec.Period.relative
        // A card pinned to a date keeps that date on offer, so the tick has somewhere to be.
        for card in cards { if case .day = card.spec.period, !choices.contains(card.spec.period) {
            choices.append(card.spec.period)
        } }
        // A Leftovers card reads the period as a cut-off, and its menu says so — unless it's chosen with a
        // Day card, where one set of words has to mean both.
        let before = cards.allSatisfy { $0.spec.kind == .leftovers }
        for period in choices {
            let item = add(periods, before ? period.beforeTitle : period.title, #selector(setViewPeriod(_:)))
            item.representedObject = period.value
            item.state = cards.allSatisfy { $0.spec.period == period } ? .on : .off
        }
        menu.addItem(withTitle: "Period", action: nil, keyEquivalent: "").submenu = periods
    }

    private func addProjectsMenu(_ menu: NSMenu, _ cards: [CanvasViewNodeView]) {
        let projects = NSMenu(title: "Projects")
        for (title, value) in [(CanvasViewSpec.Projects.everything.title, "everything"),
                               (CanvasViewSpec.Projects.board.title, "board")] {
            let item = add(projects, title, #selector(setViewProjects(_:)))
            item.representedObject = value
            let wanted: CanvasViewSpec.Projects = value == "board" ? .board : .everything
            item.state = cards.allSatisfy { $0.spec.projects == wanted } ? .on : .off
        }
        menu.addItem(withTitle: "Projects", action: nil, keyEquivalent: "").submenu = projects
    }

    @objc func setViewPeriod(_ sender: Any?) {
        guard let value = (sender as? NSMenuItem)?.representedObject as? String else { return }
        let period = CanvasViewSpec.Period(value: value)
        let before = selectedViewCards.allSatisfy { $0.spec.kind == .leftovers }
        changeViews("Show \(before ? period.beforeTitle : period.title)") { $0.period = period }
    }

    @objc func setViewProjects(_ sender: Any?) {
        guard let value = (sender as? NSMenuItem)?.representedObject as? String else { return }
        let projects: CanvasViewSpec.Projects = value == "board" ? .board : .everything
        changeViews("Show \(projects.title)") { $0.projects = projects }
    }

    /// Change a setting on every selected view, as one undoable edit to the document — the settings are
    /// on the node, like Shows.
    private func changeViews(_ actionName: String, _ change: @escaping (inout CanvasViewSpec) -> Void) {
        let ids = Set(selectedViewCards.map(\.node.id))
        guard !ids.isEmpty else { return }
        store.change(actionName) { doc in
            for index in doc.nodes.indices where ids.contains(doc.nodes[index].id) {
                guard var spec = CanvasViewSpec.of(doc.nodes[index]) else { continue }
                change(&spec)
                CanvasViewSpec.set(spec, on: &doc.nodes[index])
            }
        }
    }

    /// The folder cards in the selection — what the View submenu acts on.
    private var selectedFolderCards: [CanvasFileNodeView] {
        selection.compactMap { nodeViews[$0] as? CanvasFileNodeView }.filter { $0.folderURL != nil }
    }

    /// How a folder card lays itself out: the Finder's View menu, cut to what fits a card — as List or
    /// as Icons, then what it sorts by. Ticked only where every selected folder card agrees, as Shows is.
    private func addFolderViewMenu(_ menu: NSMenu) {
        let cards = selectedFolderCards
        guard !cards.isEmpty else { return }
        let options = cards.map { CanvasFolderOptions.of($0.node) }
        let view = NSMenu(title: "View")
        for layout in CanvasFolderView.allCases {
            let entry = add(view, layout.title, #selector(setFolderView(_:)))
            entry.representedObject = layout.rawValue
            entry.state = options.allSatisfy { $0.view == layout } ? .on : .off
        }
        view.addItem(.separator())
        view.addItem(.sectionHeader(title: "Sort By"))
        for sort in CanvasFolderSort.allCases {
            let entry = add(view, sort.title, #selector(setFolderSort(_:)))
            entry.representedObject = sort.rawValue
            entry.state = options.allSatisfy { $0.sort == sort } ? .on : .off
        }
        menu.addItem(withTitle: "View", action: nil, keyEquivalent: "").submenu = view
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
        guard tiling != nil else { return }
        // A boundary between columns is about the two columns, and one between tiles about the two
        // tiles — so the pins say which, rather than naming a card that only happens to be beside it.
        let before = divider.isVertical ? "Left Column" : "Tile Above"
        let after = divider.isVertical ? "Right Column" : "Tile Below"
        add(menu, pinTitle(divider, divider.before, side: before), #selector(pinTileBeforeDivider(_:)))
        add(menu, pinTitle(divider, divider.before + 1, side: after), #selector(pinTileAfterDivider(_:)))

        menu.addItem(.separator())
        add(menu, divider.isVertical ? "Even Out Columns" : "Even Out These Tiles",
            #selector(evenOutTiles(_:)))

        menu.addItem(.separator())
        addArrange(menu)
        add(menu, "Rename Workspace\u{2026}", #selector(renameWorkspace(_:)))
    }

    /// Arrange's commands. None is ticked: an arrangement deals the tiles out into columns and is then
    /// forgotten, and sizing to content sets the widths once, so there is no state for a tick to report
    /// (docs/canvas-workspaces.md §7k).
    private func addArrange(_ menu: NSMenu) {
        let arrange = NSMenu()
        for option in CanvasTiling.Arrangement.allCases {
            add(arrange, option.title, option == .grid ? #selector(arrangeAsGrid(_:))
                                                       : #selector(arrangeAsMasterStack(_:)))
        }
        if isTiled {
            arrange.addItem(.separator())
            add(arrange, "Size Columns to Content", #selector(sizeColumnsToContent(_:)))
        }
        menu.addItem(withTitle: "Arrange", action: nil, keyEquivalent: "").submenu = arrange
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
    ///
    /// `wholeTile` is the strip's menu, which is about the tile and all its tabs rather than the card
    /// showing: what goes into it is already above, under Tabs, and Remove takes every tab.
    private func addTileSection(_ menu: NSMenu, id: String, wholeTile: Bool = false) {
        guard let tiling else { return }
        menu.addItem(.sectionHeader(title: "Tile"))
        // **First, because it is the one you reach for**: fill the room with this tile for a moment and
        // put the workspace back afterwards. The header's tile capsule offers the same item, and the
        // handlebar's double-click is the gesture — see `toggleMaximizeTile`.
        //
        // Absent in a workspace of one tile, which already fills the room. A menu can simply not carry
        // an item; that is the whole reason these verbs are in a menu rather than in a row of buttons
        // that would have to twitch or sit dimmed.
        if tiling.ids.count > 1 {
            let item = add(menu, maximizeTileTitle, #selector(maximizeMenuTile(_:)))
            item.keyEquivalent = "\r"
            item.keyEquivalentModifierMask = [.command, .option]
        }
        // The block `buildCardMenu` was told to skip: the way out, and this tile's pinned length. The
        // header is the separator, so it doesn't want a second one above it.
        addTiling(menu, separated: false)

        // Only where it means something: a workspace not shaped as a master and a stack has no master,
        // and the master is already the master.
        // A tile of several cards can let the one showing go into a tile of its own. See `pullTabOut`.
        if tiling.hasTabs(id), !wholeTile {
            add(menu, "Pull Out of Tabs", #selector(pullMenuTabOut(_:)))
        }
        if tiling.hasTabs(id) { add(menu, tabsOnSideTitle, #selector(toggleMenuTabsOnSide(_:))) }
        if tiling.canPromote(id) {
            let promote = add(menu, "Make This the Master Tile", #selector(promoteMenuTile(_:)))
            promote.keyEquivalent = "\r"
            promote.keyEquivalentModifierMask = [.command, .shift]
        }
        // Here as well as on the board's own menu, because the board's is reached by right-clicking a
        // gap between tiles, and the gaps are four points wide.
        if !wholeTile { addExistingCards(menu); addReplaceWith(menu) }
        add(menu, pickCardsTitle, #selector(pickCardsOnBoard(_:)))

        addArrange(menu)

        add(menu, "Rename Workspace\u{2026}", #selector(renameWorkspace(_:)))

        menu.addItem(.separator())
        if wholeTile {
            add(menu, "Remove Tile from Tiled View", #selector(removeMenuTileWithTabs(_:)))
        } else {
            add(menu, "Remove from Tiled View", #selector(removeMenuTile(_:)))
        }
    }

    /// A tab's own verbs, under the card's: out into a tile of its own, and closed — alone, or leaving it
    /// alone. **Close, here**, where the tile's section says Remove: on a tab the word is the browser's,
    /// and the tab's own button is a ×. It deletes nothing either way (`removeFromTiling`).
    private func addTabSection(_ menu: NSMenu, id: String) {
        guard let tiling else { return }
        menu.addItem(.sectionHeader(title: "Tab"))
        add(menu, "Pull Out of Tabs", #selector(pullMenuTabOut(_:)))
        add(menu, tabsOnSideTitle, #selector(toggleMenuTabsOnSide(_:)))
        addReplaceWith(menu)
        if tiling.tabs(of: id).count > 1 {
            add(menu, "Close Other Tabs", #selector(closeOtherMenuTabs(_:)))
        }
        menu.addItem(.separator())
        add(menu, "Close Tab", #selector(removeMenuTile(_:)))
    }

    /// Right-clicking a strip anywhere but on a tab: the tile's menu. What can go into it first — a new
    /// card, or one already on the board, as a tab — which is the same list the strip's + opens; then
    /// the tile's commands, as a right-click on its card gives them.
    private func buildTabStripMenu(_ menu: NSMenu, tile: String) {
        menu.addItem(.sectionHeader(title: "Tabs"))
        fillNewTabMenu(menu)
        addTileSection(menu, id: tile, wholeTile: true)
    }

    /// Every `CanvasAddCommand` that makes a tile, as a tab of `menuTile`, and Add Card from Canvas into
    /// it. Shared by the strip's right-click and its +, which are two ways into one list.
    func fillNewTabMenu(_ menu: NSMenu) {
        addCommandItems(menu, tabs: true)
        let list = NSMenu()
        fillExistingCardsMenu(list, action: #selector(addExistingCardAsTab(_:)))
        guard !list.items.isEmpty else { return }
        menu.addItem(withTitle: CanvasExistingCards.title, action: nil, keyEquivalent: "").submenu = list
    }

    @objc func newTab(_ sender: Any?) {
        guard let tile = menuTile,
              let command = (sender as? NSMenuItem)?.representedObject as? CanvasAddCommand else { return }
        addingTab(to: tile) { add(command, at: nil) }
    }

    @objc func addExistingCardAsTab(_ sender: Any?) {
        guard let tile = menuTile, let id = (sender as? NSMenuItem)?.representedObject as? String else { return }
        addingTab(to: tile) { addExistingCard(withID: id) }
    }

    /// Every tab in the right-clicked one's tile but it.
    @objc func closeOtherMenuTabs(_ sender: Any?) {
        guard let id = menuTile, let tiling else { return }
        restoringMaximized { removeFromTiling(tiling.tabs(of: id).filter { $0 != id }) }
    }

    /// The right-clicked strip's whole tile, every tab of it, out of the view.
    @objc func removeMenuTileWithTabs(_ sender: Any?) {
        guard let id = menuTile, let tiling else { return }
        restoringMaximized { removeFromTiling(tiling.tabs(of: id)) }
    }

    /// Make the right-clicked tile the master. `promoteTile` is the same command with no pointer
    /// behind it — the difference between a contextual menu, which is about the thing you pointed at,
    /// and the menu bar, which can only be about the thing that is focused.
    /// ⌥B, in the menus: the board, to pick the workspace's cards on — or, while there, the way back.
    @objc func pickCardsOnBoard(_ sender: Any?) { togglePicking() }

    /// What that command is called: which way it goes.
    var pickCardsTitle: String { isPicking ? "Back to Workspace" : "Pick Cards on Board" }

    /// A tile's tabs down its side or across its top — one checked item rather than two, since it is a
    /// setting of the tile's and a check says which it has.
    var tabsOnSideTitle: String { "Tabs on the Side" }

    @objc func toggleMenuTabsOnSide(_ sender: Any?) {
        guard let id = menuTile else { return }
        toggleTabsOnSide(id)
    }

    @objc func pullMenuTabOut(_ sender: Any?) {
        guard let id = menuTile else { return }
        pullTabOut(id)
    }

    @objc func promoteMenuTile(_ sender: Any?) {
        guard let id = menuTile else { return }
        restoringMaximized { promoteInTiling(id) }
    }

    /// What Maximize is called right now: which way the toggle goes.
    var maximizeTileTitle: String {
        if maximizedCard != nil { return "Restore Card" }
        if !isTiled { return "Maximize Card" }
        return maximizedTile == nil ? "Maximize Tile" : "Restore Tile"
    }

    /// ⌥⌘Return — fill the room with the focused tile, or put the workspace back.
    ///
    /// **Restoring does not need a tile named.** Whichever one is filling the room is the one to put
    /// back, and asking for a focused tile first would make the key dead in exactly the state it is
    /// most obviously meant for.
    @objc func maximizeTile(_ sender: Any?) {
        if restoreMaximizedTile() || restoreMaximizedCard() { return }
        // On the board it is the card: the same want as the tile's, and so the same key (backlog 41).
        if !isTiled { return maximizableCard.map(maximizeCard) ?? NSSound.beep() }
        guard let id = focusedTile else { return NSSound.beep() }
        toggleMaximizeTile(id)
    }

    /// The right-clicked tile's half of the same command — see `promoteMenuTile` for why the two exist.
    @objc func maximizeMenuTile(_ sender: Any?) {
        if restoreMaximizedTile() { return }
        guard let id = menuTile else { return }
        toggleMaximizeTile(id)
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
        restoringMaximized { promoteInTiling(id) }
    }

    /// Take the focused tile out of the view — the menu bar's half of `removeMenuTile`.
    @objc func removeTile(_ sender: Any?) {
        guard let id = focusedTile else { return NSSound.beep() }
        restoringMaximized { removeFromTiling(id) }
    }

    /// Take the right-clicked tile out of the view. Like `promoteMenuTile`, it acts on the tile you
    /// pointed at rather than on the selection: right-clicking one of four selected tiles has to be
    /// able to mean that one, and a bulk "remove these four" from a menu whose other items act on all
    /// four is a mistake waiting to be made with no undo behind it (a tiling is a view, so ⌘Z has
    /// nothing to say about it).
    @objc func removeMenuTile(_ sender: Any?) {
        guard let id = menuTile else { return }
        restoringMaximized { removeFromTiling(id) }
    }

    /// **Show the canvas** — the way out of a tiled view, wherever a menu offers one.
    ///
    /// It untiled the board and it does not any more. A workspace is a place the window can be in
    /// (docs/canvas-workspaces.md §7i), so leaving it is going to the other place — the canvas tab —
    /// and the tiles stay exactly as they are behind you.
    @objc func goToCanvasCommand(_ sender: Any?) { onGoToCanvas() }

    private func pinTitle(_ divider: CanvasTileDivider, _ index: Int, side: String) -> String {
        "\(tiling?.isPinned(divider.run, at: index) == true ? "Unpin" : "Pin") \(side)"
    }

    @objc func pinTileBeforeDivider(_ sender: Any?) {
        guard let divider = menuDivider else { return }
        togglePin(divider.run, at: divider.before)
    }

    @objc func pinTileAfterDivider(_ sender: Any?) {
        guard let divider = menuDivider else { return }
        togglePin(divider.run, at: divider.before + 1)
    }

    /// Put this run back to sharing equally — the way out of an arrangement you have over-adjusted,
    /// and the only thing a drag genuinely cannot express.
    @objc func evenOutTiles(_ sender: Any?) {
        guard let divider = menuDivider else { return }
        evenOut(divider.run)
    }

    /// ⌥⇧0's menu item — see `sizeTilesToContent`.
    @objc func sizeColumnsToContent(_ sender: Any?) { sizeTilesToContent() }

    @objc func arrangeAsGrid(_ sender: Any?) { chooseArrangement(.grid) }
    @objc func arrangeAsMasterStack(_ sender: Any?) { chooseArrangement(.masterStack) }

    private func chooseArrangement(_ arrangement: CanvasTiling.Arrangement) {
        if isTiled { setArrangement(arrangement) } else { tile(tileTargets, arrangement: arrangement) }
    }

    private func buildBoardMenu(_ menu: NSMenu) {
        // The same list the toolbar's Add offers, under the same names — see `CanvasAddCommand`.
        // Here so that Add is a convenience rather than the only door: the toolbar is customisable now,
        // and a command reachable from one removable button is a command that can be removed.
        addCommandItems(menu, tabs: false)
        addExistingCards(menu)
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
        // The card's Maximize, beside the workspace it is the temporary version of. A tile's is in its
        // own section, so this is only the board's card and the one filling the window alone.
        if maximizableCard != nil || (maximizedCard != nil && tiling?.ids.count == 1) {
            let maximize = add(menu, maximizeTileTitle, #selector(maximizeTile(_:)))
            maximize.keyEquivalent = "\r"
            maximize.keyEquivalentModifierMask = [.command, .option]
        }
        addWorkspacesHoldingSelection(menu)
        // The deliberate half of pinning, and the only half: a drag can change a pin but never make
        // one, or a layout would stop responding to its window one adjustment at a time without
        // anybody having asked for that. See `togglePinTile`.
        if pinnableTile != nil { add(menu, pinTileTitle, #selector(togglePinTileSize(_:))) }
        // **A separate "Show Canvas" item used to live here**, because ⌘↩ was only the way out when
        // there was nothing left to drill into, and the menu needed one item that always left. ⌘↩ is
        // always the way out now, so a second item saying so would be the menu saying it twice.
    }

    /// The workspaces the selected cards are already in, as a submenu beside the command that makes
    /// a new one — so "make a workspace of these" is asked with the ones that exist in view, and a
    /// duplicate is something you choose rather than something you didn't know you were making.
    ///
    /// Only on the canvas: inside a workspace the command beside it is the way out, not a way to make
    /// one. Left out rather than dimmed when there are none, because an empty submenu is a place to go
    /// that has nothing in it.
    private func addWorkspacesHoldingSelection(_ menu: NSMenu) {
        guard !isTiled else { return }
        let names = workspacesHolding(tileTargets)
        guard !names.isEmpty else { return }
        let list = NSMenu()
        for name in names {
            let entry = add(list, name, #selector(goToListedWorkspace(_:)))
            entry.representedObject = name
        }
        let parent = menu.addItem(withTitle: "Workspaces", action: nil, keyEquivalent: "")
        parent.submenu = list
    }

    /// Add Card from Canvas, as a submenu — the cards on the board this tiled view isn't showing.
    ///
    /// Only in a tiled view, and left out rather than dimmed when every card is already up, for the
    /// reason `addWorkspacesHoldingSelection` gives.
    private func addExistingCards(_ menu: NSMenu) {
        guard isTiled else { return }
        let list = NSMenu()
        fillExistingCardsMenu(list)
        guard !list.items.isEmpty else { return }
        menu.addItem(withTitle: CanvasExistingCards.title, action: nil, keyEquivalent: "").submenu = list
    }

    /// Replace With: the same list, each card going into `menuTile`'s place rather than beside it.
    private func addReplaceWith(_ menu: NSMenu) {
        guard isTiled, menuTile != nil else { return }
        let list = NSMenu()
        fillExistingCardsMenu(list, action: #selector(replaceMenuTile(_:)))
        guard !list.items.isEmpty else { return }
        menu.addItem(withTitle: "Replace With", action: nil, keyEquivalent: "").submenu = list
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

    /// Make what `command` names — at `where_`, or in the middle of what you can see. The one place a
    /// `CanvasAddCommand` becomes a card, so every menu that lists them does the same thing for each.
    func add(_ command: CanvasAddCommand, at where_: CanvasPoint?) {
        switch command {
        case .card: addTextCard(at: where_)
        case .frame: addFrame(at: where_)
        case .link: addLinkCard(at: where_)
        case .file: addFileCard(at: where_)
        case .folder: addFolderCard(at: where_)
        case .projectNote: addProjectNoteCard(at: where_)
        case .dayView: addViewCard(.newDay, at: where_)
        case .leftoversView: addViewCard(.newLeftovers, at: where_)
        case .waitingView: addViewCard(.newWaiting, at: where_)
        case .searchView: addViewCard(.newSearch, at: where_)
        }
    }

    /// The items for `CanvasAddCommand.offered`, each carrying its command. `tabs` is a strip's list,
    /// which leaves out what can't be a tab and adds into `menuTile`.
    private func addCommandItems(_ menu: NSMenu, tabs: Bool) {
        for command in CanvasAddCommand.offered(projectNote: offersProjectNoteCard)
        where !tabs || command.makesTile {
            let item = add(menu, command.title, tabs ? #selector(newTab(_:)) : #selector(newHere(_:)))
            item.representedObject = command
        }
    }

    @objc private func newHere(_ sender: Any?) {
        guard let command = (sender as? NSMenuItem)?.representedObject as? CanvasAddCommand else { return }
        add(command, at: menuPoint)
    }

    /// Adding a link or a file card, wherever the request came from.
    ///
    /// On the board rather than on the window, because the board is what owns cards and what knows
    /// where a click landed. The toolbar's Add calls the same two with no point and gets the middle of
    /// the window; the contextual menu passes where you right-clicked, which is the whole reason to
    /// offer them there.
    func addLinkCard(at where_: CanvasPoint?) {
        promptForAddress(title: "Add a link card",
                         message: "The page is embedded on the board.",
                         initial: "",
                         suggestions: projectLinkSuggestions()) { [weak self] text in
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
    /// The card goes where the next card goes — see `nextPlacement` — and its position *on the board*
    /// is stepped clear of whatever is already there. That second part
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

    /// A view card (docs/views.md): a text node whose text says what it is, for Obsidian, and whose
    /// `pmView` says what Folio draws in its place. Tall, because a day is a column.
    func addViewCard(_ spec: CanvasViewSpec, at where_: CanvasPoint?) {
        let at = where_ ?? centreOfVisibleBoard
        var node = CanvasNode(content: .text(spec.noteText),
                              frame: CanvasRect(x: at.x - 180, y: at.y - 240, width: 360, height: 480))
        CanvasViewSpec.set(spec, on: &node)
        addCard(node, actionName: "Add View")
    }

    /// Ask for a web address, and hand back a usable one or nothing at all.
    ///
    /// Shared by adding a card and editing one, so the two are the same box with different words in it
    /// — including the part nobody thinks about until it is missing, which is that typing
    /// `example.com` gets a scheme put on it rather than producing a card that will never load. That
    /// part is `CanvasAddress.normalized`, shared further still with the header's address field.
    ///
    /// `suggestions` turns the field into a combo box offering them — a pick rather than a paste, for
    /// the nine times in ten the address is already one of the project's own links (backlog item 13).
    /// Empty, the field is exactly what it was before this existed.
    func promptForAddress(title: String, message: String, initial: String,
                          suggestions: [(label: String, url: String)] = [],
                          then use: @escaping (String) -> Void) {
        let field: NSTextField = suggestions.isEmpty
            ? NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 22))
            : NSComboBox(frame: NSRect(x: 0, y: 0, width: 320, height: 22))
        for link in suggestions { (field as? NSComboBox)?.addItem(withObjectValue: link.label) }
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

        let resolved = CanvasLinkSuggestions.resolvedAddress(field.stringValue, against: suggestions)
        guard let text = CanvasAddress.normalized(resolved) else { return }
        use(text)
    }

    func addFileCard(at where_: CanvasPoint?) {
        addFileCard(at: where_, folder: false)
    }

    /// A folder's card: the same file card, pointed at a folder, which `CanvasFileNodeView` draws as a
    /// list of what is in it. Tall, the way a dropped folder is (`CanvasDrop.isTall`), for the rows.
    ///
    /// **On a project's board it is the project's folder, without asking.** That is the folder you
    /// want beside a project nine times in ten, and the tenth is Change Folder… on the card — cheaper
    /// than an open panel every time for the nine. A board that isn't a project's has no such guess
    /// and asks, as it always did.
    func addFolderCard(at where_: CanvasPoint?) {
        if let project = CanvasProjectNoteCard.projectFolder(forCanvasAt: store.url) {
            addFileCard(project, at: where_, folder: true)
        } else {
            addFileCard(at: where_, folder: true)
        }
    }

    private func addFileCard(at where_: CanvasPoint?, folder: Bool) {
        guard let url = chooseFile(folder: folder, from: nil) else { return }
        addFileCard(url, at: where_, folder: folder)
    }

    /// Ask for a file or a folder, starting in `from` when there is somewhere better to start than
    /// wherever the panel was last.
    private func chooseFile(folder: Bool, from: URL?) -> URL? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = !folder
        panel.canChooseDirectories = folder
        panel.message = folder ? "Choose a folder." : "Choose a file from the vault."
        panel.directoryURL = from
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    private func addFileCard(_ url: URL, at where_: CanvasPoint?, folder: Bool) {
        // Stored the way Obsidian stores it — from the vault root — so the card means the same thing
        // in both apps. A file outside the vault has no such path and is stored as it stands.
        let path = store.resolver.storablePath(for: url) ?? url.path
        let at = where_ ?? centreOfVisibleBoard
        let height: Double = folder ? 400 : 350
        addCard(CanvasNode(content: .file(path: path, subpath: nil),
                           frame: CanvasRect(x: at.x - 200, y: at.y - height / 2,
                                             width: 400, height: height)),
                actionName: folder ? "Add Folder" : "Add File")
    }

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

    /// An empty frame, selected. Not through `addCard`: a frame can't be a tile (`makesTile`), which is
    /// why it is only offered untiled.
    func addFrame(at where_: CanvasPoint?) {
        let at = where_ ?? centreOfVisibleBoard
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

    /// New Session's ⌥ alternate, on the same routing: a new sitting even inside the idle window.
    @objc func startNewSession(_ sender: Any?) {
        projectCommandTarget(for: sender)?.projectCommands.requestNewSession(forcingNew: true)
    }

    /// File ▸ New Task (⌘N) on a board, on the same routing as New Session.
    @objc func newTask(_ sender: Any?) {
        projectCommandTarget(for: sender)?.projectCommands.requestNewTask()
    }

    /// Set every selected card to one of the four cards a project card can be.
    ///
    /// **No toggling, and no refusals.** The three-checkbox version had to ask whether a change would
    /// leave a card drawing nothing, and had to decide which direction a mixed selection moved in. A
    /// radio list has neither problem: the item names the card you get, and it means the same thing to
    /// one card and to six.
    @objc func setShowsPreset(_ sender: Any?) {
        guard let raw = (sender as? NSMenuItem)?.representedObject as? String,
              let preset = CanvasCardShows(rawValue: raw) else { return }
        let cards = selectedProjectCards
        guard !cards.isEmpty else { return }
        setShows(cards, actionName: "Show \(preset.title)", preset)
    }

    /// Write a display setting to every one of these cards, as one undoable change — the same shape as
    /// `setMedia`, and undoable for the same reason: it is an edit to the document.
    private func setShows(_ cards: [CanvasFileNodeView], actionName: String,
                          _ wanted: CanvasCardShows) {
        let ids = Set(cards.map(\.node.id))
        store.change(actionName) { doc in
            for index in doc.nodes.indices where ids.contains(doc.nodes[index].id) {
                CanvasCardShows.set(wanted, on: &doc.nodes[index])
            }
        }
    }

    @objc func setFolderView(_ sender: Any?) {
        guard let raw = (sender as? NSMenuItem)?.representedObject as? String,
              let layout = CanvasFolderView(rawValue: raw) else { return }
        setFolderOptions("View \(layout.title)") { $0.view = layout }
    }

    @objc func setFolderSort(_ sender: Any?) {
        guard let raw = (sender as? NSMenuItem)?.representedObject as? String,
              let sort = CanvasFolderSort(rawValue: raw) else { return }
        setFolderOptions("Sort by \(sort.title)") { $0.sort = sort }
    }

    /// Change one of a folder card's view settings on every selected folder card, leaving the other as
    /// each card had it — one undoable edit, like `setShows`.
    private func setFolderOptions(_ actionName: String, _ change: @escaping (inout CanvasFolderOptions) -> Void) {
        let ids = Set(selectedFolderCards.map(\.node.id))
        guard !ids.isEmpty else { return }
        store.change(actionName) { doc in
            for index in doc.nodes.indices where ids.contains(doc.nodes[index].id) {
                var options = CanvasFolderOptions.of(doc.nodes[index])
                change(&options)
                options.set(on: &doc.nodes[index])
            }
        }
    }

    /// Point the folder card you right-clicked at another folder, starting the panel in the one it shows
    /// now. The card keeps its place, size and view settings — it is the same card looking elsewhere.
    @objc func changeFolder(_ sender: Any?) {
        guard let card = selectedFolderCards.first, let current = card.folderURL,
              let url = chooseFile(folder: true, from: current), url != current else { return }
        let id = card.node.id
        let path = store.resolver.storablePath(for: url) ?? url.path
        store.change("Change Folder") { doc in
            guard let index = doc.nodes.firstIndex(where: { $0.id == id }) else { return }
            doc.nodes[index].content = .file(path: path, subpath: nil)
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

    /// Which browser the selected cards' sites are told they are talking to — one change per site.
    @objc private func setLinkIdentity(_ sender: NSMenuItem) {
        guard CanvasBrowserIdentity.allCases.indices.contains(sender.tag) else { return }
        let identity = CanvasBrowserIdentity.allCases[sender.tag]
        var done: Set<String> = []
        for card in selectedLinkCards where done.insert(card.siteName).inserted {
            card.setIdentity(identity)
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

    /// Keep these cards' pages running whatever the budget would rather — or let it decide again.
    @objc func toggleKeepRunning(_ sender: Any?) {
        let cards = selectedLinkCards
        guard !cards.isEmpty else { return }
        setKeepRunning(!cards.allSatisfy(\.keepsPageRunning), on: cards)
    }

    /// The budget is asked again straight away: turning it off is a card that may now be over the count,
    /// and turning it on is a card that may be frozen right now and should not be.
    func setKeepRunning(_ on: Bool, on cards: [CanvasLinkNodeView]) {
        setMedia(cards, actionName: on ? "Keep Running" : "Stop Keeping Running") { node in
            CanvasCardMedia.setKeepRunning(on, on: &node)
        }
        reviewPageBudget()
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
    /// - Parameters:
    ///   - joined: whether an arrow runs from the source to the new card — yes for a link followed out
    ///     of a page, no for a second card on the same page.
    ///   - resuming: a page's `interactionState` for the new card to open with, so it arrives where the
    ///     source was — scrolled, with its Back — rather than at the top.
    func addLinkCard(_ address: String, beside id: String, joined: Bool = true, resuming: Any? = nil) {
        guard let source = document.node(id: id), let normalized = CanvasAddress.normalized(address)
        else { return }
        let frame = freeFrame(rightOf: source.frame)
        let node = CanvasNode(content: .link(url: normalized), frame: frame)
        // Before the card exists, since its view reads the handover as it is built.
        if let resuming {
            CanvasPageHandover.resumes[CanvasPageHandover.key(canvas: store.url, card: node.id)] =
                .init(state: resuming, url: URL(string: normalized))
        }
        // From the source's right to the new card's left: the direction you read the board in, and the
        // direction the page was actually followed in.
        let edge = CanvasEdge(fromNode: id, fromSide: .right, toNode: node.id, toSide: .left)
        store.change(joined ? "Add Link" : "Open Page as New Card") { doc in
            doc.nodes.append(node)
            if joined { doc.edges.append(edge) }
        }
        // Up on screen with the rest, beside the tile it was followed from. This used to report "added to the board,
        // behind this tiled view" — honest about where the card had gone and no use at all, since
        // following a link is a request to *read* the page and the tiled view is what you were reading
        // in. Revealing is the untiled half of the same sentence: put the new card where I can see it.
        // Placed before it is selected, while the tile it came from is still the focused one.
        if isTiled { addToTiling(node.id) }
        select([node.id])
        if !isTiled { (scrollView as? CanvasScrollView)?.reveal(node.id) }
    }

    // MARK: The project this board belongs to

    /// The project whose folder this board's canvas sits in, and what to call it.
    ///
    /// **Not `engagedProjectCard`, which cannot answer this one.** That is the board's answer to "which
    /// project" everywhere else, and it works because the thing you step into on a board is a project
    /// card. This question is asked from *inside a web page*: you have stepped into a card and it is
    /// not that kind of card, so nothing is engaged as a project and the aimed answer is nil at exactly
    /// the moment it is wanted.
    ///
    /// Where the board lives is the answer that is left, and it is a good one — `CanvasProjectNoteCard`
    /// already asks it, once, to decide whether to offer the project's own note back, so a board that
    /// has a project has had one all along. A canvas elsewhere in the vault has none and is offered
    /// nothing, which is right: it is a canvas, not a project's board.
    var boardProject: (key: String, title: String)? {
        guard let notes = CanvasProjectNoteCard.notes(forCanvasAt: store.url),
              let key = CanvasProjectSource.projectKey(for: notes),
              let folder = projectFolder(ofNotesPath: notes.path) else { return nil }
        return (key, projectTitle(fromFolderName: (folder as NSString).lastPathComponent))
    }

    /// The project to suggest links from when adding an address (backlog item 13).
    ///
    /// **Unlike `boardProject`, this one *can* use `engagedProjectCard`** — the add-a-link field is
    /// reached from the board itself, never from inside a web page, so a project card being engaged is
    /// exactly the "which of the six" answer canvas-workspaces.md §5 settled. It only falls back to the
    /// board's own project when nothing is engaged, rather than offering nothing the way §5's aimed
    /// commands do: those *write* to a project and have to be sure, while this only ever offers, and a
    /// board that is a project's board has an obvious project to suggest from even standing on nothing.
    private var linkSuggestionProject: (key: String, title: String)? {
        if let engaged = engagedProjectCard,
           let folder = engaged.projectFolderName,
           let key = ProjectIndex.shared.projectKey(forFolder: folder) {
            return (key, projectTitle(fromFolderName: folder))
        }
        return boardProject
    }

    /// `linkSuggestionProject`'s own links, as `promptForAddress` wants them.
    ///
    /// **Read straight off the store, never waited for.** The project card that makes a project current
    /// has almost always already loaded it to draw itself, so this is usually free; when it isn't, no
    /// suggestions is a fine answer for an offer, and worth it to keep the dialog appearing on the same
    /// turn as the click that asked for it rather than after a read.
    private func projectLinkSuggestions() -> [(label: String, url: String)] {
        guard let project = linkSuggestionProject else { return [] }
        let store = StoreRegistry.shared.acquire(project.key)
        defer { StoreRegistry.shared.release(project.key) }
        guard store.hasLoaded else { return [] }
        return CanvasLinkSuggestions.suggestions(from: store.notes?.links ?? [])
    }

    /// Write an address into this board's project's `## Links`, and say so.
    ///
    /// The other half of what a web card is for. A card is where you *put* a page while you are working
    /// on something; the project's links are where a page goes when it turns out to matter past today,
    /// and until now the only way across was to copy the address, find the project, and open a dialog.
    ///
    /// The project's store is acquired for the length of the write and given straight back — this is
    /// the one thing a board asks of a project it isn't showing, and holding one open for the sake of a
    /// menu item would be a project loaded per board. See `ProjectLinks.add(_:label:toProject:)`.
    func addLinkToProject(_ address: String, named label: String?) {
        guard let project = boardProject, let url = CanvasAddress.normalized(address) else { return }
        ProjectLinks.add(url, label: label, toProject: project.key) { [weak self] added in
            self?.report(added ? "Added to \(project.title)'s links."
                               : "\(project.title) already links to that.")
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

    /// Copy what the card is showing, which on a wandered card is not what the board saved for it —
    /// the same rule Open in Browser follows, two items up the same menu.
    ///
    /// The document is still the answer for a card that isn't built: one scrolled out of view has no
    /// page to ask, and its saved address is the only address anybody has.
    @objc private func copyAddress() {
        let addresses = selection.compactMap { id -> String? in
            if let card = nodeViews[id] as? CanvasLinkNodeView { return card.liveURL?.absoluteString }
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

    /// The same act from the contextual menu's Workspaces submenu. A selector of its own because
    /// `goToWorkspace` is validated by slot — its items are numbered rows of the View menu, retitled
    /// from `tag` — and these are named rows that already say which workspace they are.
    @objc func goToListedWorkspace(_ sender: Any?) {
        goToWorkspace(sender)
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
    /// was every tiled view where the key did nothing at all, not just one of them. It also used to be
    /// the *only* keystroke that reliably left: ⌘↩ was the way out only when there was nothing left to
    /// drill into, which stopped being true the moment you clicked a tile. ⌘↩ always leaves now, so
    /// this is a second door rather than the one that had to work. See `leaveTiling`.
    @objc func zoomOut(_ sender: Any?) {
        guard !zoomEngagedCard(by: -1) else { return }
        if restoreMaximizedCard() { return }
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
    @objc func pageOpenAsNewCard(_ sender: Any?) { _ = openPageAsNewCard() }

    /// Open Page as New Card from a card's own menu: the card the menu is about, which is the
    /// selection rather than whichever page happens to be engaged.
    @objc private func openMenuPageAsNewCard() {
        guard selectedLinkCards.count == 1, let card = selectedLinkCards.first else { return }
        _ = openPageAsNewCard(from: card)
    }

    /// A second card on the page you are on (backlog 40) — the honest version of "this card twice".
    ///
    /// One card is one view, and a web view in two places is two pages (see peek, and 34), so a mirror
    /// is not on offer. What is: a new card at the address the page has *got to*, arriving at the same
    /// scroll position with the same Back, beside the one it came from. No arrow — unlike a link
    /// followed out of a page, nothing was followed. One target only: several pages at once would be
    /// several new cards from one click, which nobody means.
    func openPageAsNewCard() -> Bool {
        guard pageTargets.count == 1, let card = pageTargets.first else { return false }
        return openPageAsNewCard(from: card)
    }

    func openPageAsNewCard(from card: CanvasLinkNodeView) -> Bool {
        guard let address = card.liveURL?.absoluteString else { return false }
        addLinkCard(address, beside: card.node.id, joined: false, resuming: card.liveInteractionState)
        return true
    }

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

    /// ⇧2. Fit what is selected in the window, flown to rather than cut — never past 100%, for the
    /// reason `CanvasScrollView.zoomToFit` gives: fit is seeing all of it, not filling the window with it.
    @objc func zoomToSelection(_ sender: Any?) {
        guard !isTiled, let bounds = selectionBounds else { return NSSound.beep() }
        scrollView?.canvasScroll?.fly(toFit: bounds.inset(by: 60), animated: true)
    }

    /// The smallest rectangle around every selected card, or nil with no card selected.
    var selectionBounds: CanvasRect? {
        selection.compactMap { document.node(id: $0) }.map { layout.frame(of: $0) }
            .reduce(nil) { $0?.union($1) ?? $1 }
    }

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
            // Retitled rather than fixed, because it is two commands in two places: on the canvas it
            // says what it would make and how many cards would be in it, and inside a workspace it is
            // the way out. Dim on a canvas with nothing selected — a workspace is made out of a
            // selection or not at all. See `CanvasTiling.commandTitle`.
            (item as? NSMenuItem)?.title = tileCommandTitle
            return canRunTileCommand
        case #selector(maximizeTile(_:)):
            (item as? NSMenuItem)?.title = maximizeTileTitle
            // Live whenever there is something to put back, or a tile picked out of several to fill
            // the room with. A workspace of one tile already fills it.
            return maximizedTile != nil || maximizedCard != nil || maximizableCard != nil
                || (focusedTile != nil && (tiling?.ids.count ?? 0) > 1)
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
        case #selector(goToListedWorkspace(_:)):
            return (item as? NSMenuItem)?.representedObject is String
        case #selector(setTileArrangement(_:)):
            // Commands, not a setting, so nothing is ticked — see `addArrange`.
            (item as? NSMenuItem)?.state = .off
            return true
        case #selector(sizeColumnsToContent(_:)):
            // One column has the whole width whatever it holds.
            return (tiling?.columns.count ?? 0) > 1
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
        case #selector(tidyUp(_:)):
            return canTidy
        case #selector(setCardRatio(_:)):
            guard canSize, CanvasCardSize.ratios.indices.contains(item.tag) else { return false }
            (item as? NSMenuItem)?.state = CanvasCardSize.all(selectedFrames, at: CanvasCardSize.ratios[item.tag])
                ? .on : .off
            return true
        case #selector(setCardSize(_:)):
            return canSize
        case #selector(paste(_:)), #selector(pasteHere):
            // `pasteHere` is the board menu's own item and was answered by nothing, so it fell to the
            // `default` below and was live over an empty pasteboard. It is the same question as
            // `paste(_:)` and gets the same answer.
            return !isTiled && NSPasteboard.general.types?.isEmpty == false
        case #selector(newHere(_:)):
            // Live while tiled, which they were not, except a frame — see `CanvasAddCommand.makesTile`. The old reason was that a card added through a
            // tiled view would land at a point on a board the lens has moved out from under you — true,
            // and answered by `addCard`, which steps the card clear and puts a tile up for it. The
            // right-click that reaches these while tiled is one on a gap that isn't a divider.
            guard let command = (item as? NSMenuItem)?.representedObject as? CanvasAddCommand else { return true }
            return command.makesTile || !isTiled
        case #selector(addExistingCard(_:)):
            guard let id = (item as? NSMenuItem)?.representedObject as? String else { return false }
            return tiling.map { !$0.cards.contains(id) } ?? false
        case #selector(pickCardsOnBoard(_:)):
            (item as? NSMenuItem)?.title = pickCardsTitle
            return isTiled
        case #selector(setShowsPreset(_:)):
            // Every preset is available on every project card. The old menu had two items that could
            // do nothing from where you were standing and had to be dimmed to say so; naming the four
            // cards outright means there is no such state left to guard against.
            return !selectedProjectCards.isEmpty
        case #selector(newSession(_:)), #selector(startNewSession(_:)), #selector(newTask(_:)),
             #selector(editProjectDetails(_:)):
            return hasProjectCommandTarget
        case #selector(removeMenuTile(_:)):
            return menuTile != nil
        case #selector(toggleMenuTabsOnSide(_:)):
            guard let id = menuTile, let tiling else { return false }
            (item as? NSMenuItem)?.state = tiling.tabsOnSide(id) ? .on : .off
            return true
        case #selector(removeTile(_:)):
            return focusedTile != nil
        case #selector(promoteTile(_:)):
            // Only where it means something, which is what the contextual menu says by leaving the
            // item out altogether: a grid has no master, and the master is already the master.
            guard let id = focusedTile else { return false }
            return tiling?.canPromote(id) == true
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
        case #selector(zoomToSelection(_:)):
            return !isTiled && selectionBounds != nil
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
        case #selector(pageOpenAsNewCard(_:)):
            return pageTargets.count == 1 && pageTargets[0].liveURL != nil
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

    /// Every card whose content mentions `query`, in the order they sit in the file. The rule — what a
    /// card says, a web card's remembered page name included — is `CanvasSearch.matches`.
    func matches(_ query: String) -> [String] {
        CanvasSearch.matches(query, in: document)
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
