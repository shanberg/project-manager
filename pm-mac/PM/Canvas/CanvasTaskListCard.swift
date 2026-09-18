import AppKit
import PmLib
import SwiftUI

// MARK: - The model

/// The answer a Waiting or Search card draws, kept current while the card is up.
///
/// **Its own scan, like the Waiting window's and the Day card's.** `task.waiting` and `task.search` are
/// the walks the CLI and a model make, which is the point: one answer, every surface (rule 1). Their
/// rows carry whole refs, so everything drawn can be acted on.
///
/// **Polled**, for the Day card's reason: a wait lands, or a task is ticked, in files the app never
/// opens. These walks read every project rather than only the ones touched in a span, so the card looks
/// less often than a Day does.
@MainActor
@Observable
final class CanvasTaskListModel {
    private(set) var groups: [CanvasTaskGroup]?
    private(set) var failure: String?

    /// What the card is set to, from the node.
    var spec: CanvasViewSpec { didSet { if spec != oldValue { query = spec.query; reload() } } }
    /// What a search looks for right now: the node's query, or what's being typed before it's kept.
    private(set) var query: String
    var boardProjects: [String] = [] {
        didSet { if boardProjects != oldValue, spec.projects == .board { reload() } }
    }

    @ObservationIgnored var onChange: (() -> Void)?

    /// Rows acted on whose write hasn't been read back, drawn as they're going to be. Keyed by
    /// `CanvasTaskLists.key`.
    private(set) var pending: [String: TaskState] = [:]
    /// The rows picked, all in one project (`CanvasDaySelection`, locked by project folder here).
    var selection = CanvasDaySelection()
    var isEngaged = false
    @ObservationIgnored private var settled: Set<String> = []

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var typing: DispatchWorkItem?
    @ObservationIgnored private let queue = DispatchQueue(label: "com.stuarthanberg.pm.tasklistview", qos: .utility)
    @ObservationIgnored private var generation = 0

    static let interval: TimeInterval = 30
    /// How long typing rests before the search runs.
    static let typingPause: TimeInterval = 0.25

    init(spec: CanvasViewSpec) {
        self.spec = spec
        self.query = spec.query
    }

    /// A model holding an answer already in hand, which never looks: for drawing the card in a test.
    init(spec: CanvasViewSpec, showing groups: [CanvasTaskGroup]) {
        self.spec = spec
        self.query = spec.query
        self.groups = groups
    }

    func start() {
        reload()
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        timer.tolerance = Self.interval / 4
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        typing?.cancel()
    }

    /// Search for `text` as it's typed, once typing rests — without writing it to the node, which
    /// happens when it's kept (Return, or leaving the field).
    func type(_ text: String) {
        guard text != query else { return }
        query = text
        typing?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.reload() } }
        typing = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.typingPause, execute: work)
    }

    func expect(_ state: TaskState, for row: String) { pending[row] = state }

    func settle(_ row: String) {
        settled.insert(row)
        reload()
    }

    var summary: String {
        groups.map { CanvasTaskLists.summary(spec.kind, $0) } ?? ""
    }

    func reload() {
        generation += 1
        let mine = generation
        let kind = spec.kind
        let query = self.query.trimmingCharacters(in: .whitespaces)
        let projects: [String]?
        switch spec.projects {
        case .everything: projects = nil
        case .board: projects = boardProjects
        case .named(let names): projects = names
        }
        queue.async { [weak self] in
            let result = Result { () throws -> [CanvasTaskGroup] in
                if projects?.isEmpty == true { return [] }
                switch kind {
                case .waiting:
                    return CanvasTaskLists.groups(waiting: try waitingBuckets(projects: projects))
                case .search:
                    // Nothing typed asks nothing, and walking every project to answer it would be waste.
                    if query.isEmpty { return [] }
                    return CanvasTaskLists.groups(search: try searchableTasks(projects: projects), query: query)
                case .day:
                    return []
                }
            }
            Task { @MainActor in
                guard let self, mine == self.generation else { return }
                switch result {
                case .success(let groups):
                    self.failure = nil
                    if groups != self.groups {
                        self.groups = groups
                        self.selection.keep(within: CanvasTaskLists.order(groups))
                    }
                case .failure(let error):
                    self.failure = String(describing: error)
                }
                for row in self.settled { self.pending[row] = nil }
                self.settled = []
                self.onChange?()
            }
        }
    }
}

// MARK: - The card

/// A Waiting or Search card: tasks from across projects, each with its project's chip, acted on as the
/// same task on its project card is (docs/views.md D6, step 5).
///
/// Waiting draws `task.waiting`'s groups — what's being waited on as the heading, released first — as
/// the Waiting window does. Search draws `task.search`'s ranking for the words in its field.
struct CanvasTaskListCard: View {
    let model: CanvasTaskListModel
    var zoom: Double = 1
    var onOpenProject: (String) -> Void = { _ in }
    /// Do something to rows, all in the project in `folder`. Nil draws the card read-only.
    var onAct: ((CanvasDayAction, [CanvasDayRow], _ folder: String) -> Void)?
    /// Keep what the search field says, on the node.
    var onKeepQuery: (String) -> Void = { _ in }

    @State private var editing: String?
    @State private var draft = ""
    @State private var searchText = ""
    @FocusState private var searchFocused: Bool
    @State private var hover = RowHoverTracker()
    @State private var rightClick = RightMouseDownMonitor()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
        }
        .onAppear {
            searchText = model.spec.query
            rightClick.onRightMouseDown = { [model, hover] in
                guard model.isEngaged, let key = hover.key else { return }
                let (folder, row) = Self.split(key)
                model.selection.revealForContextMenu(row, in: folder)
            }
            rightClick.start()
        }
        .onDisappear { rightClick.stop() }
        .onChange(of: model.spec.query) { _, query in if !searchFocused { searchText = query } }
    }

    private static func hoverKey(_ row: String, _ folder: String) -> String { folder + "\u{1}" + row }
    private static func split(_ key: String) -> (String, String) {
        let parts = key.split(separator: "\u{1}", maxSplits: 1).map(String.init)
        return (parts.first ?? "", parts.count > 1 ? parts[1] : "")
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(model.spec.kind == .search ? "Search" : "Waiting On")
                    .font(.system(size: 13 * zoom, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(showsSummary ? model.summary : "")
                    .font(.system(size: 11 * zoom))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if model.spec.kind == .search { searchField }
            if model.spec.projects != .everything {
                Text(model.spec.projects.title)
                    .font(.system(size: 11 * zoom))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    /// Not where the body already says so in words.
    private var showsSummary: Bool {
        guard let groups = model.groups, !groups.isEmpty else { return false }
        return true
    }

    /// What to look for. Searched as it's typed; kept on the node when you press Return or leave it, so
    /// a keystroke isn't a step on the board's history.
    private var searchField: some View {
        TextField("Look for words in any task", text: $searchText)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 12 * zoom))
            .focused($searchFocused)
            .onChange(of: searchText) { _, text in model.type(text) }
            .onSubmit { onKeepQuery(searchText) }
            .onChange(of: searchFocused) { _, focused in if !focused { onKeepQuery(searchText) } }
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if let failure = model.failure, model.groups == nil {
            quiet(failure)
        } else if let groups = model.groups {
            if groups.isEmpty {
                quiet(emptyMessage)
            } else {
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(groups) { group in groupBlock(group, among: groups) }
                    }
                    .padding(.vertical, 6)
                }
            }
        } else {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var emptyMessage: String {
        if case .board = model.spec.projects, model.boardProjects.isEmpty { return "No project cards on this board." }
        switch model.spec.kind {
        case .waiting: return "Nothing is waiting."
        case .search:
            let query = model.query.trimmingCharacters(in: .whitespaces)
            return query.isEmpty ? "Type the words you remember." : "Nothing matches “\(query)”."
        case .day: return ""
        }
    }

    private func quiet(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12 * zoom))
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: A group

    @ViewBuilder private func groupBlock(_ group: CanvasTaskGroup, among groups: [CanvasTaskGroup]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let title = group.title { heading(title, group) }
            ForEach(group.hits, id: \.viewKey) { hit in row(hit, among: groups) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    /// What's being waited on, as the Waiting window heads it: released in green with the news, a
    /// project you can go to, or a name as written.
    private func heading(_ title: String, _ group: CanvasTaskGroup) -> some View {
        let released = group.state == "released"
        return VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Image(systemName: released ? "checkmark.circle.fill" : group.state == "pending" ? "clock" : "person")
                    .font(.system(size: 10 * zoom))
                    .foregroundStyle(released ? Color.green : .secondary)
                if let folder = group.folder {
                    Button { onOpenProject(folder) } label: {
                        Text(title).font(.system(size: 12 * zoom, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(released ? Color.green : .primary)
                    .help("Go to \(title)")
                } else {
                    Text(title).font(.system(size: 12 * zoom, weight: .semibold))
                }
            }
            if released {
                Text(group.hits.count == 1 ? "This landed. 1 task is free to move."
                                           : "This landed. \(group.hits.count) tasks are free to move.")
                    .font(.system(size: 11 * zoom))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.bottom, 2)
    }

    // MARK: A row

    private func row(_ hit: TaskSearchHit, among groups: [CanvasTaskGroup]) -> some View {
        let row = CanvasTaskLists.row(hit)
        let folder = hit.projectFolder
        let state = model.pending[CanvasTaskLists.key(hit)] ?? row.state
        let acts = onAct == nil ? [] : CanvasDayAction.offered(forTasks: [row])
        return CanvasViewRow(
            row: row, state: state,
            isSelected: model.selection.contains(row.id, in: folder),
            isEngaged: model.isEngaged, zoom: zoom,
            toggle: acts.contains(.complete) ? .complete : acts.contains(.reopen) ? .reopen : nil,
            onToggle: { perform(state == .open ? .complete : .reopen, [hit]) },
            isEditing: editing == CanvasTaskLists.key(hit), draft: $draft,
            onSubmitEdit: {
                onAct?(.edit(draft), [row], folder)
                editing = nil
            },
            onCancelEdit: { editing = nil },
            onOpenProject: onOpenProject,
            onHover: { hover.set(Self.hoverKey(row.id, folder), inside: $0) },
            onClick: {
                guard onAct != nil, editing == nil else { return }
                if NSApp.currentEvent?.clickCount == 2 {
                    if NSEvent.modifierFlags.contains(.option) || state != .open { beginEditing(hit) }
                    else { perform(.focus, [hit]) }
                } else {
                    model.selection.click(row.id, in: folder, modifiers: NSEvent.modifierFlags,
                                          order: CanvasTaskLists.order(groups)[folder] ?? [row.id])
                }
            },
            drag: {
                NSItemProvider(object: CanvasDayRows.markdown(targets(hit, among: groups).map(CanvasTaskLists.row)) as NSString)
            },
            trailing: { chip(hit) },
            menu: { menu(hit, among: groups) })
    }

    /// The project chip, after the task: where it lives, and a way there.
    private func chip(_ hit: TaskSearchHit) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            if let due = hit.due, let label = SessionPicks.day(iso: due) {
                Text(label)
                    .font(.system(size: 10 * zoom))
                    .foregroundStyle(.secondary)
            }
            Button { onOpenProject(hit.projectFolder) } label: {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    CanvasProjectMark(color: hit.projectColor, icon: hit.projectIcon, zoom: zoom)
                    Text(hit.projectName)
                        .font(.system(size: 10 * zoom))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Go to \(hit.projectName)")
        }
        .fixedSize()
    }

    /// The rows a command on `hit` acts on: the selection when it's in it, else the row alone.
    private func targets(_ hit: TaskSearchHit, among groups: [CanvasTaskGroup]) -> [TaskSearchHit] {
        let ids = model.selection.targets(clicked: CanvasTaskLists.rowID(hit), in: hit.projectFolder)
        return groups.flatMap(\.hits).filter { $0.projectFolder == hit.projectFolder && ids.contains(CanvasTaskLists.rowID($0)) }
    }

    @ViewBuilder private func menu(_ hit: TaskSearchHit, among groups: [CanvasTaskGroup]) -> some View {
        let scope = targets(hit, among: groups)
        let rows = scope.map(CanvasTaskLists.row)
        if onAct != nil {
            let acts = CanvasDayAction.offered(forTasks: rows)
            ForEach(acts, id: \.title) { act in
                Button { perform(act, scope) } label: {
                    Label(act.title(count: act.count(of: rows, among: rows)), systemImage: act.symbol)
                }
            }
            if scope.count == 1 {
                Button { beginEditing(hit) } label: {
                    Label(CanvasDayAction.edit("").title, systemImage: CanvasDayAction.edit("").symbol)
                }
            }
            if !acts.isEmpty { Divider() }
        }
        Button { TaskPasteboard.copy(markdown: CanvasDayRows.markdown(rows)) } label: {
            Label(scope.count > 1 ? "Copy \(scope.count) Tasks" : "Copy", systemImage: "doc.on.doc")
        }
        Divider()
        Button { onOpenProject(hit.projectFolder) } label: {
            Label("Go to \(hit.projectName)", systemImage: "arrow.turn.down.right")
        }
    }

    private func beginEditing(_ hit: TaskSearchHit) {
        draft = hit.text
        editing = CanvasTaskLists.key(hit)
    }

    /// Act, drawing the rows as they're about to be where that's certain. Every hit is one project's.
    private func perform(_ act: CanvasDayAction, _ hits: [TaskSearchHit]) {
        guard let folder = hits.first?.projectFolder else { return }
        for hit in hits {
            switch act {
            case .complete: model.expect(.done, for: CanvasTaskLists.key(hit))
            case .drop: model.expect(.dropped, for: CanvasTaskLists.key(hit))
            default: break
            }
        }
        onAct?(act, hits.map(CanvasTaskLists.row), folder)
    }
}
