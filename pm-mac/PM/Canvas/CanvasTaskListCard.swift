import AppKit
import PmLib
import SwiftUI

// MARK: - The model

/// The answer a Waiting, Search or Leftovers card draws, kept current while the card is up.
///
/// **Its own scan, like the Waiting window's and the Day card's.** `task.waiting`, `task.search` and
/// `task.leftovers` are the walks the CLI and a model make, which is the point: one answer, every surface (rule 1). Their
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
    /// The same answer as markdown, for Copy as Text (docs/views.md D10) — PmLib's words for it, made
    /// from the contract's answer in the same look.
    private(set) var text: String?

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
        // Coming up laid out as a week or a month looks as far ahead as it draws.
        let span = spec.kind == .comingUp ? ((try? spec.calendarSpan()) ?? nil) : nil
        let before = span?.days.last ?? spec.period.value
        let beforeTitle = spec.period.beforeTitle.lowercased()
        let query = self.query.trimmingCharacters(in: .whitespaces)
        let projects: [String]?
        switch spec.projects {
        case .everything: projects = nil
        case .board: projects = boardProjects
        case .named(let names): projects = names
        }
        queue.async { [weak self] in
            let result = Result { () throws -> ([CanvasTaskGroup], String) in
                let none = projects?.isEmpty == true
                switch kind {
                case .waiting:
                    let buckets = none ? [] : try waitingBuckets(projects: projects)
                    return (CanvasTaskLists.groups(waiting: buckets), ViewMarkdown.waiting(buckets))
                case .search:
                    // Nothing typed asks nothing, and walking every project to answer it would be waste.
                    if query.isEmpty || none { return ([], ViewMarkdown.search([], query: query)) }
                    let groups = CanvasTaskLists.groups(search: try searchableTasks(projects: projects), query: query)
                    return (groups, ViewMarkdown.search(groups.flatMap(\.hits), query: query))
                case .leftovers:
                    let list = none ? LeftoverList() : try leftoverTasks(before: before, projects: projects)
                    return (CanvasTaskLists.groups(leftovers: list), ViewMarkdown.leftovers(list, before: beforeTitle))
                case .comingUp:
                    let due = none ? [] : try dueTasks(until: before, projects: projects)
                    return (CanvasTaskLists.groups(due: due), ViewMarkdown.due(due))
                case .day, .projects:
                    return ([], "")
                }
            }
            Task { @MainActor in
                guard let self, mine == self.generation else { return }
                switch result {
                case .success(let (groups, text)):
                    self.failure = nil
                    self.text = text
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

/// A Waiting, Search or Leftovers card: tasks from across projects, each with its project's chip, acted
/// on as the same task on its project card is (docs/views.md D6, steps 5 and 6).
///
/// Waiting draws `task.waiting`'s groups — what's being waited on as the heading, released first — as
/// the Waiting window does. Search draws `task.search`'s ranking for the words in its field. Leftovers
/// draws `task.leftovers`' pile: each project, and under it each sitting that left something open, oldest
/// first, with what that sitting was about — and Pick Up, which takes a task into its own project's
/// current sitting.
struct CanvasTaskListCard: View {
    let model: CanvasTaskListModel
    var zoom: Double = 1
    /// How large the card is on screen, which Coming up's month says less at when it's small.
    var onScreen = CanvasOnScreen()
    var onOpenProject: (String) -> Void = { _ in }
    /// Do something to rows, all in the project in `folder`. Nil draws the card read-only.
    var onAct: ((CanvasDayAction, [CanvasDayRow], _ folder: String) -> Void)?
    /// Keep what the search field says, on the node.
    var onKeepQuery: (String) -> Void = { _ in }
    /// The card a Leftovers sitting dragged off this one makes (D7). Nil: sittings don't drag.
    var sittingCard: ((CanvasLeftoverSitting) -> NSItemProvider?)?

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
                Text(title)
                    .font(.system(size: 13 * zoom, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(showsSummary ? model.summary : "")
                    .font(.system(size: 11 * zoom))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if model.spec.kind == .search { searchField }
            if let caption {
                Text(caption)
                    .font(.system(size: 11 * zoom))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var title: String {
        switch model.spec.kind {
        case .search: return "Search"
        case .leftovers: return "Left Open"
        case .comingUp: return "Coming Up"
        case .waiting, .day, .projects: return "Waiting On"
        }
    }

    /// Which projects, when it isn't all of them — and for Leftovers, how old a sitting has to be.
    private var caption: String? {
        var parts: [String] = []
        if let span { parts.append(span.title) }
        else if model.spec.kind.hasPeriod { parts.append(model.spec.kind.title(of: model.spec.period)) }
        if model.spec.projects != .everything { parts.append(model.spec.projects.title) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
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

    /// What Coming up laid out as a week or a month covers, or nil for a list.
    private var span: CanvasCalendarSpan? {
        model.spec.kind == .comingUp ? ((try? model.spec.calendarSpan()) ?? nil) : nil
    }

    @ViewBuilder private var content: some View {
        if let failure = model.failure, model.groups == nil {
            quiet(failure)
        } else if let groups = model.groups, let span {
            if model.spec.shownLayout == .week { dueWeek(span, groups) } else { dueMonth(span, groups) }
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
        case .leftovers: return "Nothing left open \(model.spec.period.beforeTitle.lowercased())."
        case .comingUp:
            return model.spec.period == .today ? "Nothing due today." : "Nothing due \(model.spec.period.dueTitle.lowercased())."
        case .day, .projects: return ""
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

    // MARK: Coming up, on the calendar

    /// Coming up's rows by the day they're due — and what's overdue, which is drawn on today.
    private func dueDays(_ groups: [CanvasTaskGroup]) -> (byDay: [String: [CanvasTaskItem]], overdue: [CanvasTaskItem]) {
        var byDay: [String: [CanvasTaskItem]] = [:]
        var overdue: [CanvasTaskItem] = []
        for group in groups {
            if group.state == "overdue" { overdue += group.items; continue }
            for item in group.items { byDay[String((item.hit.due ?? "").prefix(10)), default: []].append(item) }
        }
        return (byDay, overdue)
    }

    /// The next seven days as columns (D9), what's due pinned to the top of its day and what's overdue
    /// on today, in red. Rows are the list's rows — they tick, drop and open as they do there — with
    /// only the project's mark after them while a column is narrow, and full size with its project's
    /// name, as the list has them, once the card is wide enough. See `CanvasCalendarDetail.column`.
    private func dueWeek(_ span: CanvasCalendarSpan, _ groups: [CanvasTaskGroup]) -> some View {
        GeometryReader { geometry in
            dueWeek(span, groups, column: CanvasCalendarDetail.column(width: (geometry.size.width / 7 - 6) / zoom))
        }
    }

    private func dueWeek(_ span: CanvasCalendarSpan, _ groups: [CanvasTaskGroup],
                         column: CanvasCalendarDetail.Column) -> some View {
        let (byDay, overdue) = dueDays(groups)
        let today = CanvasTaskLists.todayISO()
        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(span.days, id: \.self) { day in
                    VStack(spacing: 0) {
                        Text(day == today ? "Today" : CanvasCalendarCells.weekday(day))
                            .font(.system(size: 9.5 * zoom, weight: day == today ? .semibold : .regular))
                            .foregroundStyle(day == today ? Color.accentColor : .secondary)
                        Text(CanvasCalendarCells.dayNumber(day))
                            .font(.system(size: 13 * zoom, weight: day == today ? .bold : .regular))
                            .foregroundStyle(day == today ? Color.accentColor : .primary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, 4)
            Divider()
            ScrollView(.vertical) {
                HStack(alignment: .top, spacing: 0) {
                    ForEach(span.days, id: \.self) { day in
                        VStack(alignment: .leading, spacing: 2) {
                            if day == today, !overdue.isEmpty {
                                Text("Overdue")
                                    .font(.system(size: 10 * zoom, weight: .semibold))
                                    .foregroundStyle(Color.red)
                                ForEach(overdue, id: \.key) { item in row(item, among: groups, column: column) }
                                if !(byDay[day] ?? []).isEmpty { Divider().padding(.vertical, 2) }
                            }
                            ForEach(byDay[day] ?? [], id: \.key) { item in row(item, among: groups, column: column) }
                        }
                        .padding(.horizontal, 3)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                }
            }
            // The column rules run the card's height, however long each day's list is.
            .background {
                HStack(spacing: 0) {
                    ForEach(span.days.indices, id: \.self) { index in
                        Rectangle().fill(index == 0 ? Color.clear : Color.primary.opacity(0.08)).frame(width: 0.5)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    /// Five weeks from the start of this one (D9): each day with what falls due on it, as many as fit,
    /// and today with what's overdue in red above them. Days already past are drawn faint. A task's
    /// line goes to its project; its words are in the help when they don't fit, and run to a second
    /// line when the day is wide and has the room. Too small on screen to read, a day is a dot per
    /// task in its project's colour.
    private func dueMonth(_ span: CanvasCalendarSpan, _ groups: [CanvasTaskGroup]) -> some View {
        let (byDay, overdue) = dueDays(groups)
        let today = CanvasTaskLists.todayISO()
        return CanvasMonthGrid(span: span, zoom: zoom, today: today, isQuiet: { $0 < today }) { day, room in
            let items = byDay[day] ?? []
            let late = day == today ? overdue : []
            let lines = room.lines
            if !onScreen.finePrintReadable {
                CanvasDotsCell(colors: (late + items).map(\.hit.projectColor), zoom: zoom, large: true)
                    .help((late + items).map { "\($0.hit.text) · \($0.hit.projectName)" }.joined(separator: "\n"))
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    if !late.isEmpty {
                        Text("\(late.count) overdue")
                            .font(.system(size: 9.5 * zoom, weight: .semibold))
                            .foregroundStyle(Color.red)
                            .help(late.map { "\($0.hit.text) · \($0.hit.projectName)" }.joined(separator: "\n"))
                    }
                    let left = max(0, lines - (late.isEmpty ? 0 : 1))
                    // The last line says how many more, rather than one more task.
                    let shown = items.count > left ? max(0, left - 1) : items.count
                    // Two lines each, when the day is wide and every one of them has them.
                    let wrap = room.width >= 120 && shown == items.count && items.count * 2 <= left
                    ForEach(items.prefix(shown), id: \.key) { item in
                        Button { onOpenProject(item.hit.projectFolder) } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 3) {
                                CanvasProjectMark(color: item.hit.projectColor, icon: item.hit.projectIcon, zoom: zoom * 0.8)
                                Text(item.hit.text)
                                    .font(.system(size: 9.5 * zoom))
                                    .lineLimit(wrap ? 2 : 1)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("\(item.hit.text) · \(item.hit.projectName)")
                    }
                    if items.count > shown {
                        Text(shown == 0 ? "\(items.count) due" : "+\(items.count - shown) more")
                            .font(.system(size: 9 * zoom))
                            .foregroundStyle(.secondary)
                            .help(items.dropFirst(shown).map { "\($0.hit.text) · \($0.hit.projectName)" }.joined(separator: "\n"))
                    }
                }
            }
        }
    }

    // MARK: A group

    @ViewBuilder private func groupBlock(_ group: CanvasTaskGroup, among groups: [CanvasTaskGroup]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let title = group.title { heading(title, group) }
            if let sitting = group.sitting { sittingHeading(sitting) }
            ForEach(group.items, id: \.key) { item in row(item, among: groups) }
        }
        .padding(.horizontal, 12)
        .padding(.top, group.sitting.map { $0.startsProject ? 10 : 4 } ?? 6)
        .padding(.bottom, group.sitting == nil ? 6 : 2)
    }

    /// A Leftovers sitting: its project above the first of them, then when it was and what it was about.
    /// The sitting drags off as a card of its own, as a Day card's does.
    @ViewBuilder private func sittingHeading(_ sitting: CanvasLeftoverSitting) -> some View {
        if sitting.startsProject {
            Button { onOpenProject(sitting.projectFolder) } label: {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    CanvasProjectMark(color: sitting.projectColor, icon: sitting.projectIcon, zoom: zoom)
                    Text(sitting.projectName)
                        .font(.system(size: 12 * zoom, weight: .semibold))
                        .lineLimit(1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Go to \(sitting.projectName)")
            .padding(.bottom, 2)
        }
        VStack(alignment: .leading, spacing: 1) {
            Text(sitting.dateLabel)
                .font(.system(size: 11 * zoom, weight: .medium))
                .foregroundStyle(.secondary)
            if !sitting.lede.isEmpty {
                Text(sitting.lede)
                    .font(.system(size: 11 * zoom))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .ifCondition(sittingCard != nil) { view in view.onDrag { sittingCard?(sitting) ?? NSItemProvider() } }
        .help(sittingCard == nil ? "" : "Drag to make a card of this sitting")
        .padding(.bottom, 1)
    }

    /// What's being waited on, as the Waiting window heads it: released in green with the news, a
    /// project you can go to, or a name as written.
    @ViewBuilder private func heading(_ title: String, _ group: CanvasTaskGroup) -> some View {
        if model.spec.kind == .comingUp {
            dayHeading(title, overdue: group.state == "overdue")
        } else {
            waitingHeading(title, group)
        }
    }

    /// A day on Coming up, and what's past due in red above them all.
    private func dayHeading(_ title: String, overdue: Bool) -> some View {
        Text(title)
            .font(.system(size: 12 * zoom, weight: .semibold))
            .foregroundStyle(overdue ? Color.red : .primary)
            .padding(.bottom, 2)
    }

    private func waitingHeading(_ title: String, _ group: CanvasTaskGroup) -> some View {
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

    /// A row of the list, or of a week's `column`.
    private func row(_ item: CanvasTaskItem, among groups: [CanvasTaskGroup],
                     column: CanvasCalendarDetail.Column? = nil) -> some View {
        let compact = column == .compact
        let hit = item.hit
        let row = item.row()
        let folder = hit.projectFolder
        let state = model.pending[item.key] ?? row.state
        let acts = onAct == nil ? [] : offered([row])
        return CanvasViewRow(
            row: row, state: state,
            isSelected: model.selection.contains(row.id, in: folder),
            // A column is narrow, so its rows are a size down.
            isEngaged: model.isEngaged, zoom: compact ? zoom * 0.88 : zoom,
            toggle: acts.contains(.complete) ? .complete : acts.contains(.reopen) ? .reopen : nil,
            onToggle: { perform(state == .open ? .complete : .reopen, [item]) },
            isEditing: editing == item.key, draft: $draft,
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
                    if NSEvent.modifierFlags.contains(.option) || state != .open { beginEditing(item) }
                    else { perform(.focus, [item]) }
                } else {
                    model.selection.click(row.id, in: folder, modifiers: NSEvent.modifierFlags,
                                          order: CanvasTaskLists.order(groups)[folder] ?? [row.id])
                }
            },
            drag: {
                NSItemProvider(object: CanvasDayRows.markdown(targets(item, among: groups).map { $0.row() }) as NSString)
            },
            trailing: { if column == nil || column == .named { chip(item) } else { compactChip(item) } },
            menu: { menu(item, among: groups) })
    }

    /// What `rows` offer here: Pick Up and Put Back on Leftovers, where there's an older sitting to pick
    /// up from.
    private func offered(_ rows: [CanvasDayRow]) -> [CanvasDayAction] {
        CanvasDayAction.offered(forTasks: rows, picking: model.spec.kind == .leftovers)
    }

    /// What follows the task: when it's due, and where it lives and a way there — or, on Leftovers, whose
    /// heading already says where, when it was last picked up.
    private func chip(_ item: CanvasTaskItem) -> some View {
        let hit = item.hit
        return HStack(alignment: .firstTextBaseline, spacing: 4) {
            // On Coming up the day is the heading, so only what's past it says its date — in red.
            let overdue = hit.due.map { String($0.prefix(10)) < CanvasTaskLists.todayISO() } ?? false
            if let due = hit.due, let label = SessionPicks.day(iso: String(due.prefix(10))),
               model.spec.kind != .comingUp || overdue {
                Text(label)
                    .font(.system(size: 10 * zoom))
                    .foregroundStyle(model.spec.kind == .comingUp ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))
            }
            if model.spec.kind == .leftovers {
                if item.depth == 0, let picked = item.picked, let day = SessionPicks.day(iso: picked.into) {
                    Text(item.row().pickedUp ? "picked up today" : "picked up \(day)")
                        .font(.system(size: 10 * zoom))
                        .foregroundStyle(.tertiary)
                }
            } else {
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
        }
        .fixedSize()
    }

    /// A column's chip: only the project's mark, which goes there, and its name on hover.
    private func compactChip(_ item: CanvasTaskItem) -> some View {
        Button { onOpenProject(item.hit.projectFolder) } label: {
            CanvasProjectMark(color: item.hit.projectColor, icon: item.hit.projectIcon, zoom: zoom).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Go to \(item.hit.projectName)")
        .fixedSize()
    }

    /// The rows a command on `item` acts on: the selection when it's in it, else the row alone.
    private func targets(_ item: CanvasTaskItem, among groups: [CanvasTaskGroup]) -> [CanvasTaskItem] {
        let folder = item.hit.projectFolder
        let ids = model.selection.targets(clicked: CanvasTaskLists.rowID(item.hit), in: folder)
        return groups.flatMap(\.items).filter {
            $0.hit.projectFolder == folder && ids.contains(CanvasTaskLists.rowID($0.hit))
        }
    }

    @ViewBuilder private func menu(_ item: CanvasTaskItem, among groups: [CanvasTaskGroup]) -> some View {
        let scope = targets(item, among: groups)
        let rows = scope.map { $0.row() }
        let hit = item.hit
        if onAct != nil {
            let acts = offered(rows)
            ForEach(acts, id: \.title) { act in
                Button { perform(act, scope) } label: {
                    Label(act.title(count: act.count(of: rows, among: rows)), systemImage: act.symbol)
                }
            }
            if scope.count == 1 {
                Button { beginEditing(item) } label: {
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

    private func beginEditing(_ item: CanvasTaskItem) {
        draft = item.hit.text
        editing = item.key
    }

    /// Act, drawing the rows as they're about to be where that's certain. Every item is one project's.
    private func perform(_ act: CanvasDayAction, _ items: [CanvasTaskItem]) {
        guard let folder = items.first?.hit.projectFolder else { return }
        for item in items {
            switch act {
            case .complete: model.expect(.done, for: item.key)
            case .drop: model.expect(.dropped, for: item.key)
            default: break
            }
        }
        onAct?(act, items.map { $0.row() }, folder)
    }
}
