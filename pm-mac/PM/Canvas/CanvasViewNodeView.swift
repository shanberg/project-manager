import AppKit
import PmLib
import SwiftUI

/// A view card on a board: a text node carrying `pmView`, drawn as the answer it names rather than as
/// its text (docs/views.md D3). See `CanvasViewSpec`.
///
/// **A place you work** (D6). A row ticks, drops, picks up and retypes the way the same row does on a
/// project card, through its own project's store — taken when you act, not for every project in view.
/// See `CanvasDayActions`.
final class CanvasViewNodeView: CanvasNodeView {
    /// What the card draws: a Day's sittings, or a list of tasks (Waiting, Search).
    enum Model {
        case day(CanvasDayModel)
        case tasks(CanvasTaskListModel)

        @MainActor init(_ spec: CanvasViewSpec) {
            switch spec.kind {
            case .day: self = .day(CanvasDayModel(spec: spec))
            case .waiting, .search: self = .tasks(CanvasTaskListModel(spec: spec))
            }
        }

        @MainActor var spec: CanvasViewSpec {
            switch self {
            case .day(let model): return model.spec
            case .tasks(let model): return model.spec
            }
        }
    }

    private(set) var model: Model
    let actions: CanvasDayActions

    /// What the node says this card is.
    var spec: CanvasViewSpec { model.spec }

    override init(node: CanvasNode, board: CanvasBoardView, scale: Double) {
        model = Model(CanvasViewSpec.of(node) ?? .newDay)
        actions = CanvasDayActions { ProjectIndex.shared.projectKey(forFolder: $0) }
        super.init(node: node, board: board, scale: scale)
        // The act is now the thing ⌘Z takes back — `CanvasUndoRoute`'s project route, as a tick on a
        // project card is.
        actions.onActed = { [weak self] store in self?.board.lastEditedProject = store }
        startModel()
        contentChanged()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func startModel() {
        let changed: () -> Void = { [weak self] in
            // The zoomed-out face is one label, built from the summary rather than observing it.
            guard let self, self.isSimplified else { return }
            self.contentChanged()
            self.refreshAccessibility()
        }
        switch model {
        case .day(let day):
            day.boardProjects = boardProjectFolders()
            day.onChange = changed
            day.start()
        case .tasks(let tasks):
            tasks.boardProjects = boardProjectFolders()
            tasks.onChange = changed
            tasks.start()
        }
    }

    private func stopModel() {
        switch model {
        case .day(let day): day.stop()
        case .tasks(let tasks): tasks.stop()
        }
    }

    /// The node's settings live in `extra`, which the base class doesn't watch; a change there is a new
    /// question for the same card, not a rebuild — unless it's a different view altogether, which a
    /// hand-edited file can make it. The board's own project cards are read again on every pass too,
    /// since a card set to this board's projects follows the board.
    override func update(node: CanvasNode, scale: Double) {
        super.update(node: node, scale: scale)
        if let spec = CanvasViewSpec.of(node), spec != self.spec {
            switch model {
            case .day(let day) where spec.kind == .day: day.spec = spec
            case .tasks(let tasks) where spec.kind != .day: tasks.spec = spec
            default:
                stopModel()
                model = Model(spec)
                startModel()
                contentChanged()
            }
        }
        if spec.projects == .board {
            let folders = boardProjectFolders()
            switch model {
            case .day(let day): if folders != day.boardProjects { day.boardProjects = folders }
            case .tasks(let tasks): if folders != tasks.boardProjects { tasks.boardProjects = folders }
            }
        }
    }

    private var summary: String {
        switch model {
        case .day(let day): return day.summary
        case .tasks(let tasks): return tasks.summary
        }
    }

    /// What the card is called in one word or two: its period for a Day, else its kind.
    private var name: String {
        switch spec.kind {
        case .day: return spec.period.title
        case .waiting: return "Waiting"
        case .search: return spec.query.isEmpty ? "Search" : "Search “\(spec.query)”"
        }
    }

    private var symbol: String {
        switch spec.kind {
        case .day: return "calendar"
        case .waiting: return "clock"
        case .search: return "magnifyingglass"
        }
    }

    override func contentChanged() {
        if isSimplified {
            let summary = self.summary
            return setContent(summaryView(summary.isEmpty ? name : "\(name): \(summary)", symbol: symbol))
        }
        let root: AnyView
        switch model {
        case .day(let day):
            root = AnyView(CanvasDayCard(
                model: day, zoom: contentZoom,
                onOpenProject: { folder in WindowManager.shared.open(named: folder) },
                onAct: { [weak self] act, rows, sitting in
                    guard let self else { return }
                    self.actions.perform(act, on: rows, inProject: sitting.projectFolder) { [weak self] in
                        guard case .day(let day)? = self?.model else { return }
                        for row in rows { day.settle(CanvasDayRows.key(row, in: sitting)) }
                    }
                },
                sittingCard: { [weak self] sitting in self?.sittingCardProvider(sitting) }))
        case .tasks(let tasks):
            root = AnyView(CanvasTaskListCard(
                model: tasks, zoom: contentZoom,
                onOpenProject: { folder in WindowManager.shared.open(named: folder) },
                onAct: { [weak self] act, rows, folder in
                    guard let self else { return }
                    self.actions.perform(act, on: rows, inProject: folder) { [weak self] in
                        guard case .tasks(let tasks)? = self?.model else { return }
                        for row in rows { tasks.settle("\(folder)/\(row.id)") }
                    }
                },
                onKeepQuery: { [weak self] query in self?.keepQuery(query) }))
        }
        let view = NSHostingView(rootView: root.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top))
        view.setAccessibilityLabel(accessibilityFallback)
        setContent(view)
    }

    /// What a Search card's field says, kept on the node as one undoable change — when it's different.
    private func keepQuery(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard spec.kind == .search, trimmed != spec.query.trimmingCharacters(in: .whitespaces) else { return }
        let id = node.id
        board.store.change(trimmed.isEmpty ? "Clear Search" : "Search") { doc in
            guard let index = doc.nodes.firstIndex(where: { $0.id == id }),
                  var spec = CanvasViewSpec.of(doc.nodes[index]) else { return }
            spec.query = trimmed
            CanvasViewSpec.set(spec, on: &doc.nodes[index])
        }
    }

    override var scrollsItsContent: Bool { true }
    override var zoomsItsContent: Bool { true }
    override func contentZoomChanged() { contentChanged() }

    /// A row takes its own click, as a project card's does: the box ticks on the first one.
    override var engagesOnClick: Bool { !isSimplified }

    /// Stepping in hands the keyboard to the card, for a row being retyped; stepping out takes it back.
    /// Nothing is rebuilt, which would only interrupt the scroll.
    override func engagementChanged() {
        switch model {
        case .day(let day):
            day.isEngaged = isEngaged
            if !isEngaged { day.selection.clear() }
        case .tasks(let tasks):
            tasks.isEngaged = isEngaged
            if !isEngaged { tasks.selection.clear() }
        }
        guard let content = subviews.first else { return }
        if isEngaged {
            window?.makeFirstResponder(content)
        } else if (window?.firstResponder as? NSView)?.isDescendant(of: content) == true {
            window?.makeFirstResponder(board)
        }
    }

    override var accessibilityFallback: String {
        let summary = self.summary
        return summary.isEmpty ? "\(name) view" : "\(name): \(summary)"
    }

    override func prepareForRemoval() {
        stopModel()
        if let store = board.lastEditedProject,
           actions.heldStores.contains(where: { $0 === store }) { board.lastEditedProject = nil }
        actions.releaseAll()
    }

    /// What a sitting dragged off this card carries: a project card of that one sitting (docs/views.md
    /// D7), in the board's own clipping flavour, so the board makes exactly that card where it lands —
    /// and its name as text for anywhere else.
    private func sittingCardProvider(_ sitting: SittingEntry) -> NSItemProvider? {
        guard let document = CanvasSittingPin.card(for: sitting, resolver: board.store.resolver) else { return nil }
        let data = Data(document.serialized().utf8)
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: CanvasClipping.pasteboardType.rawValue,
                                            visibility: .ownProcess) { done in
            done(data, nil)
            return nil
        }
        let title = [sitting.projectName, sitting.name].filter { !$0.isEmpty }.joined(separator: " — ")
        provider.registerObject(title as NSString, visibility: .all)
        return provider
    }

    /// The file paths on the board when `boardProjectFolders` last resolved them. `update` runs on every
    /// layout pass — every frame of a zoom flight — and resolving a path can touch the disk, so the
    /// answer is kept until the board's files change.
    private var resolvedPaths: [String]?
    private var resolvedFolders: [String] = []

    /// The folders of the projects with a card on this board — the project notes cards, by where their
    /// file is.
    private func boardProjectFolders() -> [String] {
        let paths = board.document.nodes.compactMap { node -> String? in
            if case .file(let path, _) = node.content { return path }
            return nil
        }
        if paths == resolvedPaths { return resolvedFolders }
        var folders: [String] = []
        for path in paths {
            guard let url = board.store.resolver.resolve(path).url,
                  let folder = projectFolder(ofNotesPath: url.path) else { continue }
            let name = (folder as NSString).lastPathComponent
            if !folders.contains(name) { folders.append(name) }
        }
        resolvedPaths = paths
        resolvedFolders = folders.sorted()
        return resolvedFolders
    }
}
