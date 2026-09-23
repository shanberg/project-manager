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
    /// What the card draws: a Day's sittings, a list of tasks (Waiting, Search, Leftovers, Coming up), or
    /// the projects themselves.
    enum Model {
        case day(CanvasDayModel)
        case tasks(CanvasTaskListModel)
        case projects(CanvasProjectsModel)
        case time(CanvasTimeModel)

        @MainActor init(_ spec: CanvasViewSpec) {
            switch spec.kind {
            case .day: self = .day(CanvasDayModel(spec: spec))
            case .waiting, .search, .leftovers, .comingUp: self = .tasks(CanvasTaskListModel(spec: spec))
            case .projects: self = .projects(CanvasProjectsModel(spec: spec))
            case .time: self = .time(CanvasTimeModel(spec: spec))
            }
        }

        @MainActor var spec: CanvasViewSpec {
            switch self {
            case .day(let model): return model.spec
            case .tasks(let model): return model.spec
            case .projects(let model): return model.spec
            case .time(let model): return model.spec
            }
        }

        /// Which model a kind is drawn by — a change of kind within one keeps the model.
        static func family(_ kind: CanvasViewSpec.Kind) -> Int {
            switch kind {
            case .day: return 0
            case .waiting, .search, .leftovers, .comingUp: return 1
            case .projects: return 2
            case .time: return 3
            }
        }
    }

    private(set) var model: Model
    let actions: CanvasDayActions
    /// How large the card is on screen, kept current as the board zooms.
    private let onScreen = CanvasOnScreen()

    /// What the node says this card is.
    var spec: CanvasViewSpec { model.spec }

    override init(node: CanvasNode, board: CanvasBoardView, scale: Double) {
        model = Model(CanvasViewSpec.of(node) ?? .newDay)
        actions = CanvasDayActions { ProjectIndex.shared.projectKey(forFolder: $0) }
        super.init(node: node, board: board, scale: scale)
        onScreen.finePrintReadable = CanvasCalendarDetail.finePrintReadable(zoom: contentZoom, scale: scale)
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
        case .projects(let projects):
            projects.boardProjects = boardProjectFolders()
            projects.onChange = changed
            projects.start()
        case .time(let time):
            time.boardProjects = boardProjectFolders()
            time.onChange = changed
            time.start()
        }
    }

    private func stopModel() {
        switch model {
        case .day(let day): day.stop()
        case .tasks(let tasks): tasks.stop()
        case .projects(let projects): projects.stop()
        case .time(let time): time.stop()
        }
    }

    /// The node's settings live in `extra`, which the base class doesn't watch; a change there is a new
    /// question for the same card, not a rebuild — unless it's a different view altogether, which a
    /// hand-edited file can make it. The board's own project cards are read again on every pass too,
    /// since a card set to this board's projects follows the board.
    override func update(node: CanvasNode, scale: Double) {
        super.update(node: node, scale: scale)
        // Every frame of a zoom passes here; the card hears of it only when its small print crosses
        // from readable to not, or back.
        let readable = CanvasCalendarDetail.finePrintReadable(zoom: contentZoom, scale: scale)
        if readable != onScreen.finePrintReadable { onScreen.finePrintReadable = readable }
        if let spec = CanvasViewSpec.of(node), spec != self.spec {
            switch model {
            case .day(let day) where spec.kind == .day: day.spec = spec
            case .tasks(let tasks) where Model.family(spec.kind) == 1: tasks.spec = spec
            case .projects(let projects) where spec.kind == .projects: projects.spec = spec
            case .time(let time) where spec.kind == .time: time.spec = spec
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
            case .projects(let projects): if folders != projects.boardProjects { projects.boardProjects = folders }
            case .time(let time): if folders != time.boardProjects { time.boardProjects = folders }
            }
        }
    }

    private var summary: String {
        switch model {
        case .day(let day): return day.summary
        case .tasks(let tasks): return tasks.summary
        case .projects(let projects): return projects.summary
        case .time(let time): return time.summary
        }
    }

    /// The card's answer as markdown, for Copy as Text (docs/views.md D10), or nil before it has one.
    var text: String? {
        switch model {
        case .day(let day): return day.list.map { ViewMarkdown.day($0) }
        case .tasks(let tasks): return tasks.text
        case .projects(let projects): return projects.text
        case .time(let time): return time.text
        }
    }

    override func contentChanged() {
        if isSimplified {
            let summary = self.summary
            return setContent(summaryView(summary.isEmpty ? spec.cardName : "\(spec.cardName): \(summary)", symbol: spec.symbol))
        }
        let root: AnyView
        switch model {
        case .day(let day):
            root = AnyView(CanvasDayCard(
                model: day, zoom: contentZoom, onScreen: onScreen,
                onOpenProject: { folder in WindowManager.shared.open(named: folder) },
                onAct: { [weak self] act, rows, sitting in
                    guard let self else { return }
                    self.actions.perform(act, on: rows, inProject: sitting.projectFolder) { [weak self] in
                        guard case .day(let day)? = self?.model else { return }
                        for row in rows { day.settle(CanvasDayRows.key(row, in: sitting)) }
                    }
                },
                sittingCard: { [weak self] sitting in
                    self?.sittingCardProvider(project: sitting.projectFolder,
                                              session: SessionRef(date: sitting.session, ordinal: sitting.sessionOrdinal,
                                                                  digest: sitting.sessionDigest.isEmpty ? nil : sitting.sessionDigest),
                                              title: [sitting.projectName, sitting.name])
                },
                onSetPeriod: { [weak self] period in self?.setPeriod(period) },
                onOpenDay: { [weak self] day in
                    guard let self else { return }
                    self.board.addDayCard(pinnedTo: day, beside: self.node.id)
                }))
        case .tasks(let tasks):
            root = AnyView(CanvasTaskListCard(
                model: tasks, zoom: contentZoom, onScreen: onScreen,
                onOpenProject: { folder in WindowManager.shared.open(named: folder) },
                onAct: { [weak self] act, rows, folder in
                    guard let self else { return }
                    self.actions.perform(act, on: rows, inProject: folder) { [weak self] in
                        guard case .tasks(let tasks)? = self?.model else { return }
                        for row in rows { tasks.settle("\(folder)/\(row.id)") }
                    }
                },
                onKeepQuery: { [weak self] query in self?.keepQuery(query) },
                sittingCard: { [weak self] sitting in
                    self?.sittingCardProvider(project: sitting.projectFolder, session: sitting.ref,
                                              title: [sitting.projectName, sitting.dateLabel])
                }))
        case .projects(let projects):
            root = AnyView(CanvasProjectsCard(
                model: projects, zoom: contentZoom,
                onOpenProject: { folder in WindowManager.shared.open(named: folder) },
                projectCard: { [weak self] project in
                    self?.sittingCardProvider(project: project.folder, session: nil, title: [project.name])
                }))
        case .time(let time):
            root = AnyView(CanvasTimeCard(
                model: time, zoom: contentZoom,
                onOpenProject: { folder in WindowManager.shared.open(named: folder) },
                projectCard: { [weak self] project in
                    self?.sittingCardProvider(project: project.projectFolder, session: nil,
                                              title: [project.projectName])
                },
                onAnswer: { [weak self] stretches, project in
                    self?.count(stretches.map { ($0.from, $0.to) }, for: project)
                }))
        }
        let view = NSHostingView(rootView: root.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top))
        view.setAccessibilityLabel(accessibilityFallback)
        setContent(view)
    }

    // MARK: Answering for time (docs/away-time.md)

    /// Write one answer per stretch through `time.count`, and make the lot one step of the board's
    /// history — ⌘Z takes them back together, ⇧⌘Z writes them again.
    ///
    /// **On the board's history, and it becomes the last thing edited.** The answers belong to no
    /// project's file, so a project's stack is the wrong place; and clearing `lastEditedProject` is
    /// what makes ⌘Z, pressed right after, take back the answer rather than an earlier tick — the
    /// same thing a canvas edit does (`CanvasPaneController.documentChanged`).
    private func count(_ ranges: [(from: String, to: String)], for project: String?) {
        var ids: [String] = []
        for range in ranges {
            var input = ApiInput()
            input.from = range.from
            input.to = range.to
            if let project { input.project = project } else { input.notWork = true }
            do {
                let result = try PMContract.perform(.timeCount, input)
                if let data = result.data,
                   let event = try? JSONDecoder().decode(AttentionEvent.self, from: JSONEncoder().encode(data)) {
                    ids.append(event.id)
                }
            } catch {
                Log.write("time answer refused: \(ApiError.from(error).message)")
                NSSound.beep()
            }
        }
        reloadTime()
        guard !ids.isEmpty else { return }
        let undo = board.store.undoManager
        undo.registerUndo(withTarget: self) { target in target.withdraw(ids, ranges: ranges, for: project) }
        undo.setActionName(CanvasTimeAnswers.undoName(notWork: project == nil))
        board.lastEditedProject = nil
    }

    /// Take the answers back. The log is never rewritten: a `withdrawn` for each, and the ranges read
    /// as they did before (AttentionLog.applyingCounts).
    private func withdraw(_ ids: [String], ranges: [(from: String, to: String)], for project: String?) {
        for id in ids { AttentionLog.withdraw(id, source: "app") }
        reloadTime()
        let undo = board.store.undoManager
        undo.registerUndo(withTarget: self) { target in target.count(ranges, for: project) }
        undo.setActionName(CanvasTimeAnswers.undoName(notWork: project == nil))
        board.lastEditedProject = nil
    }

    private func reloadTime() {
        guard case .time(let time) = model else { return }
        time.reload()
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

    /// A week or month paged back or on, or back to today: one undoable change to the node, named for
    /// where it went.
    private func setPeriod(_ period: CanvasViewSpec.Period) {
        guard period != spec.period else { return }
        let id = node.id
        let name = period == .today ? "Show Today" : "Show \(spec.shownLayout.title)"
        board.store.change(name) { doc in
            guard let index = doc.nodes.firstIndex(where: { $0.id == id }),
                  var spec = CanvasViewSpec.of(doc.nodes[index]) else { return }
            spec.period = period
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
        // Neither has rows that can be selected: both list projects, and a project row is a link.
        case .projects, .time:
            break
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
        return summary.isEmpty ? "\(spec.cardName) view" : "\(spec.cardName): \(summary)"
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
    private func sittingCardProvider(project folder: String, session: SessionRef?, title: [String]) -> NSItemProvider? {
        guard let document = CanvasSittingPin.card(project: folder, session: session,
                                                   resolver: board.store.resolver) else { return nil }
        let data = Data(document.serialized().utf8)
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: CanvasClipping.pasteboardType.rawValue,
                                            visibility: .ownProcess) { done in
            done(data, nil)
            return nil
        }
        let name = title.filter { !$0.isEmpty }.joined(separator: " — ")
        provider.registerObject(name as NSString, visibility: .all)
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
