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

    override func selectAll(_ sender: Any?) {
        selection = Set(document.nodes.map(\.id))
    }

    // MARK: Copying

    @objc func copy(_ sender: Any?) {
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

    @objc func paste(_ sender: Any?) {
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

    private func buildCardMenu(_ menu: NSMenu, id: String) {
        guard let node = document.node(id: id) else { return }

        switch node.content {
        case .file(let path, _):
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
            add(menu, "Open in Browser", #selector(openLinkInBrowser))
            add(menu, "Copy Address", #selector(copyAddress))
            // Where a page's navigation lives. Not in the card's header, which is a caption and has
            // no room to become a toolbar, and not on a swipe, which on a trackpad is indistinguishable
            // from scrolling a page sideways.
            if (nodeViews[id] as? CanvasLinkNodeView)?.canGoBack == true {
                add(menu, "Back", #selector(goBackInLink))
            }
            add(menu, "Reload", #selector(reloadLink))
            if let card = nodeViews[id] as? CanvasLinkNodeView {
                menu.addItem(.separator())
                add(menu, "Sign In to \(card.siteName)…", #selector(signInToLink))
                // Signing in is per site, so signing out is too — and it reaches every card on every
                // board that shows that site, because they were all one session to begin with.
                add(menu, "Sign Out of \(card.siteName)", #selector(signOutOfLink))
                add(menu, "Sign Out of All Sites…", #selector(signOutEverywhere))
                menu.addItem(.separator())
                // Per site, because that is the granularity at which blocking breaks a page: when a
                // card comes up empty the question is always "is it this site?", and the answer has to
                // be one click away from the card that is wrong.
                let filtering = add(menu, "Block Ads on \(card.siteName)", #selector(toggleLinkFiltering))
                filtering.state = card.isFiltered ? .on : .off
            }
        case .text:
            add(menu, "Edit", #selector(editSelected))
        case .group:
            add(menu, "Rename Frame…", #selector(renameSelectedFrame))
        }

        menu.addItem(.separator())
        add(menu, "Cut", #selector(cut(_:)))
        add(menu, "Copy", #selector(copy(_:)))
        add(menu, "Duplicate", #selector(duplicate(_:)))
        menu.addItem(.separator())
        menu.addItem(colourItem())
        menu.addItem(.separator())
        add(menu, selection.count > 1 ? "Delete Cards" : "Delete Card", #selector(deleteSelected))
    }

    private func buildLineMenu(_ menu: NSMenu, id: String) {
        add(menu, "Reverse Direction", #selector(reverseSelectedLines))
        menu.addItem(colourItem())
        menu.addItem(.separator())
        add(menu, "Delete Line", #selector(deleteSelected))
    }

    private func buildBoardMenu(_ menu: NSMenu) {
        add(menu, "New Card", #selector(newCardHere))
        add(menu, "New Frame", #selector(newFrameHere))
        // The same four the toolbar's Add offers. Here so that Add is a convenience rather than the
        // only door — the toolbar is customisable now, and a command reachable from one removable
        // button is a command that can be removed.
        add(menu, "New Link…", #selector(newLinkHere))
        add(menu, "New File…", #selector(newFileHere))
        menu.addItem(.separator())
        let paste = add(menu, "Paste", #selector(pasteHere))
        paste.isEnabled = NSPasteboard.general.types?.isEmpty == false
        menu.addItem(.separator())
        add(menu, "Select All", #selector(selectAll(_:)))
    }

    private func colourItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Colour", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for index in 0...CanvasPalette.presets.count {
            let entry = submenu.addItem(withTitle: index == 0 ? "None" : "Colour \(index)",
                                        action: #selector(setColourFromMenu(_:)), keyEquivalent: "")
            entry.target = self
            entry.tag = index
        }
        item.submenu = submenu
        return item
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    // MARK: What the menu items do

    /// Adding a link or a file card, wherever the request came from.
    ///
    /// On the board rather than on the window, because the board is what owns cards and what knows
    /// where a click landed. The toolbar's Add calls the same two with no point and gets the middle of
    /// the window; the contextual menu passes where you right-clicked, which is the whole reason to
    /// offer them there.
    func addLinkCard(at where_: CanvasPoint?) {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 22))
        field.placeholderString = "https://"
        let alert = NSAlert()
        alert.messageText = "Add a link card"
        alert.informativeText = "The page is embedded on the board."
        alert.accessoryView = field
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        var text = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        if !text.contains("://") { text = "https://" + text }
        let at = where_ ?? centreOfVisibleBoard
        let node = CanvasNode(content: .link(url: text),
                              frame: CanvasRect(x: at.x - 200, y: at.y - 200,
                                                width: 400, height: 400))
        store.change("Add Link") { $0.nodes.append(node) }
        select([node.id])
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
        let node = CanvasNode(content: .file(path: path, subpath: nil),
                              frame: CanvasRect(x: at.x - 200, y: at.y - 175,
                                                width: 400, height: 350))
        store.change("Add File") { $0.nodes.append(node) }
        select([node.id])
    }

    @objc private func newLinkHere() { addLinkCard(at: menuPoint) }
    @objc private func newFileHere() { addFileCard(at: menuPoint) }

    @objc private func newCardHere() {
        let at = menuPoint ?? centreOfVisibleBoard
        let node = CanvasNode(content: .text(""),
                              frame: CanvasRect(x: at.x - 125, y: at.y - 30, width: 250, height: 60))
        store.change("Add Card") { $0.nodes.append(node) }
        selection = [node.id]
        beginEditing(node.id)
    }

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

    @objc private func openSelected() {
        for id in selection { nodeViews[id]?.beginEditing() }
    }

    @objc private func revealSelected() {
        let urls = selection.compactMap { id -> URL? in
            guard case .file(let path, _)? = document.node(id: id)?.content else { return nil }
            return store.resolver.resolve(path).url
        }
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
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

    @objc private func setColourFromMenu(_ sender: NSMenuItem) {
        let token: String? = sender.tag == 0 ? nil : String(sender.tag)
        let ids = selection
        store.change("Change Colour") { doc in
            for index in doc.nodes.indices where ids.contains(doc.nodes[index].id) {
                doc.nodes[index].color = token
            }
            for index in doc.edges.indices where ids.contains(doc.edges[index].id) {
                doc.edges[index].color = token
            }
        }
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
    @objc func zoomIn(_ sender: Any?) { scrollView?.canvasScroll?.zoom(by: 1.25) }
    @objc func zoomOut(_ sender: Any?) { scrollView?.canvasScroll?.zoom(by: 1 / 1.25) }
    @objc func zoomActualSize(_ sender: Any?) { scrollView?.canvasScroll?.zoomToActualSize() }
    @objc func zoomToFit(_ sender: Any?) { scrollView?.canvasScroll?.zoomToFit() }

    @objc func toggleEditMode(_ sender: Any?) { mode = mode == .edit ? .view : .edit }

    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(toggleEditMode(_:)):
            // The validated item *is* the menu item, which is the only chance to tick it — this
            // object answers `validateUserInterfaceItem`, so AppKit never asks `validateMenuItem`.
            (item as? NSMenuItem)?.state = mode == .edit ? .on : .off
            return true
        case #selector(copy(_:)), #selector(cut(_:)), #selector(duplicate(_:)):
            return !selection.isEmpty
        case #selector(paste(_:)):
            return NSPasteboard.general.types?.isEmpty == false
        case #selector(selectAll(_:)), #selector(zoomIn(_:)), #selector(zoomOut(_:)),
             #selector(zoomActualSize(_:)), #selector(zoomToFit(_:)):
            return true
        default:
            return true
        }
    }
}

private extension NSScrollView {
    /// This scroll view, if it is a canvas's. The board holds its scroller as an `NSScrollView` so the
    /// two aren't mutually dependent at construction; the zoom commands need the canvas one.
    var canvasScroll: CanvasScrollView? { self as? CanvasScrollView }
}


// MARK: - Finding a card

extension CanvasBoardView {

    /// Every card whose content mentions `query`, in the order they sit in the file.
    ///
    /// Searches what a card *says* rather than what it stores where the two differ: a file card
    /// matches on its path, so "Flexcompute" finds it, and on its basename, so "Notes.md" does too. A
    /// board of 117 cards is several screens, and the alternative to this is panning until you spot it.
    func matches(_ query: String) -> [String] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return [] }
        return document.nodes.filter { node in
            switch node.content {
            case .text(let text): return text.localizedCaseInsensitiveContains(needle)
            case .link(let url): return url.localizedCaseInsensitiveContains(needle)
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
