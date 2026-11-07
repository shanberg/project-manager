import AppKit
import PmLib

/// Every space and the window it opens in. docs/spaces.md § Spaces.
///
/// - The list is `~/.config/pm/spaces.json`; each space's board is `~/.config/pm/spaces/<id>.canvas`.
/// - A space opens in the ordinary window on its canvas (`WindowManager.open(canvas:)`), which already
///   leaves the focused project alone and comes back at launch with the other windows.
@MainActor
final class Spaces {
    static let shared = Spaces()

    private(set) var file: SpaceFile
    private var saveQueued = false

    static var fileURL: URL { PMFiles.configDir.appendingPathComponent("spaces.json") }
    static var folder: URL { PMFiles.configDir.appendingPathComponent("spaces", isDirectory: true) }

    private init() {
        file = SpaceFile.read(Self.fileURL)
        Self.carryOverTabs(from: Self.fileURL, into: Self.folder)
    }

    /// Spaces made before they were boards (2026-11-04) kept their pages as tabs in `spaces.json`. A space
    /// with no canvas yet gets those pages as web cards, in a row, once; the old keys go on the next write.
    static func carryOverTabs(from list: URL, into folder: URL) {
        // read: Folio's own spaces.json, in ~/.config/pm: local.
        guard let data = try? Data(contentsOf: list),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let spaces = object["spaces"] as? [[String: Any]] else { return }
        for space in spaces {
            guard let id = space["id"] as? String else { continue }
            let canvas = folder.appendingPathComponent("\(id).canvas")
            guard !FileManager.default.fileExists(atPath: canvas.path) else { continue }
            let tabs = ["favorites", "pinned", "today"].flatMap { space[$0] as? [[String: Any]] ?? [] }
            let urls = tabs.compactMap { $0["url"] as? String }
            guard !urls.isEmpty else { continue }
            let nodes: [[String: Any]] = urls.enumerated().map { index, url in
                ["id": UUID().uuidString.lowercased(), "type": "link", "url": url,
                 "x": index * 440, "y": 0, "width": 400, "height": 400]
            }
            guard let json = try? JSONSerialization.data(withJSONObject: ["nodes": nodes, "edges": []],
                                                         options: [.prettyPrinted]) else { continue }
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? json.write(to: canvas, options: .withoutOverwriting)
            Log.write("spaces: carried \(urls.count) tab(s) into \(id).canvas")
        }
    }

    var all: [Space] { file.spaces }
    func space(_ id: String) -> Space? { file.spaces.first { $0.id == id } }
    func canvas(of id: String) -> URL? { space(id)?.canvas(in: Self.folder) }

    /// The space a window's canvas is, when it is one.
    func space(forCanvas url: URL?) -> Space? {
        url.flatMap { file.space(forCanvas: $0, in: Self.folder) }
    }

    /// The window showing the space, if one is open.
    func window(of id: String) -> ProjectWindowController? {
        guard let canvas = canvas(of: id)?.standardizedFileURL else { return nil }
        return WindowManager.shared.controllers.first { $0.openedCanvas?.standardizedFileURL == canvas && !$0.isCarrier }
    }

    func isOpen(_ id: String) -> Bool { window(of: id)?.isVisible ?? false }

    // MARK: Changing

    func change(_ id: String, _ edit: (inout Space) -> Void) {
        guard let index = file.spaces.firstIndex(where: { $0.id == id }) else { return }
        let before = file.spaces[index]
        edit(&file.spaces[index])
        guard file.spaces[index] != before else { return }
        window(of: id)?.applyTitle()
        window(of: id)?.spaceFrame?.refresh()
        if file.spaces[index].color != before.color { window(of: id)?.spaceAppearanceChanged() }
        CanvasSatelliteDock.shared.refresh()
        save()
    }

    /// The spaces in a new order, as the overview's drags leave them; any not named keep their order
    /// after the rest. The dock and the Spaces menu follow.
    func reorder(_ ids: [String]) {
        let named = ids.compactMap { id in file.spaces.first { $0.id == id } }
        let rest = file.spaces.filter { !ids.contains($0.id) }
        guard named + rest != file.spaces else { return }
        file.spaces = named + rest
        CanvasSatelliteDock.shared.refresh()
        save()
    }

    private func save() {
        guard !saveQueued else { return }
        saveQueued = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            saveQueued = false
            flush()
        }
    }

    func flush() {
        do { try file.write(Self.fileURL) } catch { Log.write("spaces: couldn't write: \(error)") }
    }

    // MARK: Windows

    func show(_ id: String) {
        guard let canvas = canvas(of: id) else { return }
        if !FileManager.default.fileExists(atPath: canvas.path) { try? makeCanvas(at: canvas) }
        WindowManager.shared.open(canvas: canvas)
        CanvasSatelliteDock.shared.refresh()
    }

    func makeCanvas(at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try SpaceCanvas.empty.write(to: url, options: .withoutOverwriting)
    }

    /// The space whose window was last in front, kept between launches.
    var lastUsed: String? {
        get { UserDefaults.standard.string(forKey: "PMLastSpace") }
        set { UserDefaults.standard.set(newValue, forKey: "PMLastSpace") }
    }

    /// Where a link from another app goes (Folio as the default browser): the space whose window is
    /// furthest forward, else the one used last, else the first. Nil with no spaces at all.
    var forIncomingLinks: String? {
        let open = NSApp.orderedWindows.lazy.compactMap { $0.windowController as? ProjectWindowController }
            .compactMap { $0.spaceFrame?.spaceID }.first
        if let open { return open }
        if let last = lastUsed, space(last) != nil { return last }
        return file.spaces.first?.id
    }

    /// ⇧⌘T: a card closed in a space, back in that space.
    func reopen(_ closed: CanvasHistory.Closed) {
        guard let spaceID = closed.spaceID, space(spaceID) != nil else { return }
        show(spaceID)
        DispatchQueue.main.async { [weak self] in
            guard let window = self?.window(of: spaceID) else { return }
            window.window?.makeKeyAndOrderFront(nil)
            window.spaceFrame?.reopen(closed)
        }
    }

    /// A link from another app, in a space: the card already on that address, else a new one in Today.
    func openIncoming(_ url: URL, in id: String) {
        show(id)
        DispatchQueue.main.async { [weak self] in
            guard let window = self?.window(of: id), let frame = window.spaceFrame else {
                return Log.write("incoming link: space \(id) has no window")
            }
            window.window?.makeKeyAndOrderFront(nil)
            frame.openIncoming(url.absoluteString)
        }
    }

    /// Show a card in its space: the window, then the card in it, as a click on its sidebar row.
    func showCard(_ cardID: String, in id: String) {
        show(id)
        DispatchQueue.main.async { [weak self] in self?.window(of: id)?.spaceFrame?.show(cardID) }
    }

    func pause(_ cardID: String, in id: String) {
        guard let canvas = canvas(of: id) else { return }
        CanvasLinkNodeView.pause(card: cardID, onCanvas: canvas)
    }

    // MARK: Moving a card to another space

    /// A card off one space's board and onto another's, right of everything there, as Today.
    func move(_ cardID: String, from id: String, to target: String) {
        guard id != target, let from = canvas(of: id) else { return }
        move(cardID, fromCanvas: from, to: target)
    }

    /// The same from any board, a project's included: a row dropped on a space's dock mark.
    func move(_ cardID: String, fromCanvas from: URL, to target: String, then done: @escaping @MainActor () -> Void = {}) {
        guard let to = canvas(of: target) else { return }
        if !FileManager.default.fileExists(atPath: to.path) { try? makeCanvas(at: to) }
        move([cardID], fromCanvas: from, toCanvas: to, then: done)
    }

    /// Several cards off one board and onto another — a space's or a project's — side by side, right of
    /// everything there, as Today. The lines between them go with them; lines to cards left behind go.
    /// One undo on each board.
    func move(_ cardIDs: [String], fromCanvas from: URL, toCanvas to: URL,
              then done: @escaping @MainActor () -> Void = {}) {
        guard !cardIDs.isEmpty, from.standardizedFileURL != to.standardizedFileURL else { return }
        // Both boards read off main when they aren't open. See `CanvasStoreRegistry.withStores`.
        CanvasStoreRegistry.withStores([from, to]) { [weak self] stores in
            guard let self, stores.count == 2 else { return }
            Self.move(cardIDs, from: stores[0], to: stores[1],
                      names: (from: boardTitle(stores[0]), to: boardTitle(stores[1])))
            CanvasSatelliteDock.shared.refresh()
            done()
        }
    }

    /// Several cards to a project's board, found — or made, as opening the project would — off main.
    func move(_ cardIDs: [String], fromCanvas from: URL, toProject name: String,
              then done: @escaping @MainActor () -> Void = {}) {
        DispatchQueue.global(qos: .userInitiated).async {
            let canvas = Result { () -> String in
                let folder = try resolveProjectPath(nameOrPrefix: name)
                return try resolveProjectCanvasPath(projectPath: folder)
                    ?? createProjectCanvas(projectPath: folder)
            }
            Task { @MainActor [weak self] in
                switch canvas {
                case .success(let path):
                    self?.move(cardIDs, fromCanvas: from, toCanvas: URL(fileURLWithPath: path), then: done)
                case .failure(let error):
                    let alert = NSAlert()
                    alert.messageText = "Couldn't move to \(ProjectCodes.display(name))."
                    alert.informativeText = ApiError.from(error).message
                    alert.runModal()
                }
            }
        }
    }

    /// What a board is called in an undo name: its space's title, else "Project".
    private func boardTitle(_ store: CanvasDocumentStore) -> String {
        space(forCanvas: store.url)?.title ?? "Project"
    }

    /// The move itself, between two open stores. `names` are the boards' titles, for the undo names.
    static func move(_ cardIDs: [String], from source: CanvasDocumentStore, to destination: CanvasDocumentStore,
                     names: (from: String, to: String)) {
        let ids = Set(cardIDs)
        let nodes = cardIDs.compactMap(source.document.node(id:))
        guard !nodes.isEmpty else { return }
        var x = (destination.document.nodes.map { $0.frame.x + $0.frame.width }.max() ?? 0) + 40
        let moved = nodes.map { original -> CanvasNode in
            var node = original
            node.frame = CanvasRect(x: x, y: 0, width: node.frame.width, height: node.frame.height)
            x += node.frame.width + 40
            SpaceCardMarks.setPinned(false, on: &node)
            SpaceCardMarks.setFavorite(false, on: &node)
            node.extra[SpaceCardMarks.orderKey] = nil
            return node
        }
        let lines = source.document.edges.filter { ids.contains($0.fromNode) && ids.contains($0.toNode) }
        destination.change("Move from \(names.from)") {
            $0.nodes.append(contentsOf: moved)
            $0.edges.append(contentsOf: lines)
        }
        destination.save()
        source.change("Move to \(names.to)") { doc in
            doc.nodes.removeAll { ids.contains($0.id) }
            doc.edges.removeAll { ids.contains($0.fromNode) || ids.contains($0.toNode) }
        }
        source.save()
    }

    // MARK: Sending a card to a project

    enum Send { case card, link, task }

    /// From the dock's flyout: a web card to a project — onto its board (and off the space's), into its
    /// `## Links`, or as a task linked to the page.
    func send(_ cardID: String, in id: String, as kind: Send, to project: (key: String, name: String)) {
        guard let canvas = canvas(of: id) else { return }
        // The board read off main when it isn't open. See `CanvasStoreRegistry.withStores`.
        CanvasStoreRegistry.withStores([canvas]) { [weak self] stores in
            guard let self, let store = stores.first else { return }
            send(cardID, on: canvas, document: store.document, as: kind, to: project)
        }
    }

    private func send(_ cardID: String, on canvas: URL, document: CanvasDocument, as kind: Send,
                      to project: (key: String, name: String)) {
        guard let node = document.node(id: cardID), case .link(let address) = node.content,
              let url = URL(string: address) else { return }
        let title = CanvasExistingCards.card(node)?.title ?? url.host() ?? address
        switch kind {
        case .card:
            CanvasIncomingLinks.open(url, inProject: project.key, inNewWindow: false)
            if let store = try? CanvasStoreRegistry.store(for: canvas) {
                store.change("Move to Project") { $0.nodes.removeAll { $0.id == cardID } }
                store.save()
                CanvasStoreRegistry.release(store)
            }
        case .link:
            var input = ApiInput()
            input.project = project.name
            input.text = address
            input.label = title
            perform(.notesAddLink, input)
        case .task:
            perform(.taskAdd, PMContract.input(project: project.name) { $0.text = "[\(title)](\(address))" })
        }
    }

    private func perform(_ action: PMAction, _ input: ApiInput) {
        do { _ = try PMContract.perform(action, input) } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't send the page."
            alert.informativeText = ApiError.from(error).message
            alert.runModal()
        }
    }

    // MARK: Making and removing

    /// File ▸ New Space, Spaces ▸ New Space, the dock's +, the switcher's New Space, the quick bar:
    /// an empty board in its window, untitled unless `name` is given. Returns the space's id.
    @discardableResult
    func newSpace(named name: String = "") -> String {
        var made = Space(color: Self.nextColor(after: file.spaces.count))
        made.name = name.trimmingCharacters(in: .whitespaces)
        file.spaces.append(made)
        flush()
        show(made.id)
        bringForward(made.id)
        return made.id
    }

    /// A new space holding a sidebar row dropped on the dock's +: the card moves off its board.
    func newSpace(moving cardID: String, fromCanvas canvas: URL) {
        let id = newSpace()
        move(cardID, fromCanvas: canvas, to: id) { [weak self] in
            DispatchQueue.main.async { self?.window(of: id)?.spaceFrame?.show(cardID) }
        }
    }

    /// A new space on a link dropped on the dock's +: the page as its first card.
    func newSpace(opening url: URL) {
        let id = newSpace()
        openIncoming(url, in: id)
    }

    /// The space's window in front, Folio active: `show` opens a closed one but leaves an open one where it is.
    func go(to id: String) {
        show(id)
        bringForward(id)
    }

    private func bringForward(_ id: String) {
        DispatchQueue.main.async { [weak self] in
            guard let window = self?.window(of: id)?.window else { return }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
    }

    // MARK: Order

    /// The space whose window is furthest forward, if any window of a space is in front of every other
    /// window of the app; else nil.
    var frontSpace: String? {
        NSApp.orderedWindows.lazy.compactMap { $0.windowController as? ProjectWindowController }.first
            .flatMap { space(forCanvas: $0.openedCanvas)?.id }
    }

    func goToNext(by step: Int) {
        guard let id = SpaceOrder.step(from: frontSpace, by: step, in: all.map(\.id)) else { return }
        go(to: id)
    }

    /// Colours in turn, so two new spaces in a row don't look alike.
    static func nextColor(after count: Int) -> String {
        let names: [ProjectColor.Name] = [.blue, .pink, .teal, .orange, .purple, .green, .indigo, .red, .brown, .mint]
        return ProjectColor.named(names[count % names.count]).value
    }

    func rename(_ id: String) {
        guard let space = space(id) else { return }
        let alert = NSAlert()
        alert.messageText = "Rename Space"
        let field = NSTextField(string: space.name)
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        field.placeholderString = "Untitled Space"
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        // Empty is allowed: it makes the space untitled again.
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        change(id) { $0.name = name }
    }

    func setColor(_ id: String, _ color: ProjectColor) { change(id) { $0.color = color.value } }

    /// Delete a space and its board, behind a confirmation. The board goes to the Trash.
    func delete(_ id: String) {
        guard let space = space(id) else { return }
        let alert = NSAlert()
        alert.messageText = "Delete “\(space.title)”?"
        alert.informativeText = "Its board and everything on it go to the Trash."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        window(of: id)?.close()
        if let canvas = canvas(of: id) { try? FileManager.default.trashItem(at: canvas, resultingItemURL: nil) }
        file.spaces.removeAll { $0.id == id }
        flush()
        CanvasSatelliteDock.shared.refresh()
        SpaceSettings.close(spaceID: id)
    }
}
