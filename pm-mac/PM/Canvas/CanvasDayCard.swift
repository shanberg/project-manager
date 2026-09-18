import AppKit
import PmLib
import SwiftUI

/// The answer a Day card draws, kept current while the card is up.
///
/// **Its own scan, like the Waiting window's.** `session.list` is the same walk the CLI and a model
/// make, which is the point: one answer, every surface (docs/views.md, rule 1). The scan is cheap by a
/// rule the files make true: a project nothing has written to since the span began is only stat'd.
///
/// **Polled, not watched.** A day moves in files the app never opens: a tick in Obsidian, a capture
/// from Raycast, a sitting in another project's window. There's no one place all of those announce
/// themselves, and a poll every little while is a few hundred `stat`s, so the card just looks again.
/// The same poll is what rolls a Today card over at midnight and takes "now" off a sitting that has
/// gone quiet.
@MainActor
@Observable
final class CanvasDayModel {
    private(set) var list: SittingList?
    private(set) var range: DoneRange?
    private(set) var failure: String?

    /// What the card is set to, from the node.
    var spec: CanvasViewSpec { didSet { if spec != oldValue { reload() } } }
    /// The projects with a card on the board, for a card set to show only those.
    var boardProjects: [String] = [] {
        didSet { if boardProjects != oldValue, spec.projects == .board { reload() } }
    }

    /// Told when an answer lands, for the zoomed-out summary the node view draws itself.
    @ObservationIgnored var onChange: (() -> Void)?

    /// Rows acted on whose write hasn't come back through a scan yet, drawn in the state they're going
    /// to: a tick shows as ticked on the click, not a scan later. Keyed by `CanvasDayRows.key`.
    private(set) var pending: [String: TaskState] = [:]

    /// The rows picked, all in one sitting (`CanvasDaySelection`).
    var selection = CanvasDaySelection()
    /// Whether the card is stepped into — a selection there is the one you're working in, and drawn so.
    var isEngaged = false
    /// Rows whose act has settled, so the next answer to land has seen it.
    @ObservationIgnored private var settled: Set<String> = []

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private let queue = DispatchQueue(label: "com.stuarthanberg.pm.dayview", qos: .utility)
    /// Rising, so a slow scan can't land over a newer one.
    @ObservationIgnored private var generation = 0

    /// How often the card looks again.
    static let interval: TimeInterval = 20

    init(spec: CanvasViewSpec) {
        self.spec = spec
    }

    /// A model holding an answer already in hand, which never looks: for drawing the card in a test.
    init(spec: CanvasViewSpec, showing list: SittingList, for range: DoneRange) {
        self.spec = spec
        self.list = list
        self.range = range
    }

    /// Start looking, now and every `interval`.
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

    /// Stop looking. The card calls this when it goes.
    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Show `row` as `state` until its write has been read back.
    func expect(_ state: TaskState, for row: String) {
        pending[row] = state
    }

    /// `row`'s write has landed or been refused: look again, and draw what's there once that answer is
    /// in. A scan already under way began before the write, so it's overtaken rather than believed.
    func settle(_ row: String) {
        settled.insert(row)
        reload()
    }

    var summary: String {
        list.map(CanvasDayRows.summary) ?? ""
    }

    func reload() {
        generation += 1
        let mine = generation
        let spec = self.spec
        let projects: [String]?
        switch spec.projects {
        case .everything: projects = nil
        case .board: projects = boardProjects
        case .named(let names): projects = names
        }
        queue.async { [weak self] in
            let result = Result { () throws -> (DoneRange, SittingList) in
                // A week or a month laid out asks about the whole of it, not only the period's days.
                let range = try spec.calendarSpan()?.range ?? spec.period.range()
                // An empty board asks about no projects, and the answer to that is nothing, not everything.
                if projects?.isEmpty == true { return (range, SittingList()) }
                return (range, try sessionList(in: range, projects: projects))
            }
            Task { @MainActor in
                guard let self, mine == self.generation else { return }
                switch result {
                case .success(let (range, list)):
                    self.failure = nil
                    if range != self.range { self.range = range }
                    if list != self.list {
                        self.list = list
                        self.selection.keep(within: Dictionary(
                            list.sittings.map { ($0.id, CanvasDayRows.rows($0).map(\.id)) },
                            uniquingKeysWith: { a, _ in a }))
                    }
                    for row in self.settled { self.pending[row] = nil }
                    self.settled = []
                case .failure(let error):
                    self.failure = String(describing: error)
                    for row in self.settled { self.pending[row] = nil }
                    self.settled = []
                }
                self.onChange?()
            }
        }
    }
}

/// A Day card: the sittings of a day across projects, in the order the day went (docs/views.md D5).
///
/// A sitting is the time it began, the project chip, its prose in full and its tasks. The rail shows
/// only when a sitting began, never how long it ran: a column of durations reads as a timesheet. Over a
/// week, each sitting is drawn as its lede and what came of it, under a caption per day.
struct CanvasDayCard: View {
    let model: CanvasDayModel
    /// The card's zoom, applied to the type, as a text card's is.
    var zoom: Double = 1
    var onOpenProject: (String) -> Void = { _ in }
    /// Do something to a row, in its sitting's project (docs/views.md D6). Nil draws the card read-only.
    var onAct: ((CanvasDayAction, [CanvasDayRow], SittingEntry) -> Void)?
    /// The card a sitting dragged off this one makes (D7). Nil: sittings don't drag.
    var sittingCard: ((SittingEntry) -> NSItemProvider?)?
    /// Set the card's period — a week or a month paged back and on, and Today. Nil: no paging.
    var onSetPeriod: ((CanvasViewSpec.Period) -> Void)?
    /// Open a day of a week or month as a Day card of its own. Nil: days don't open.
    var onOpenDay: ((String) -> Void)?

    /// The row being retyped, and what it says so far.
    @State private var editing: String?
    @State private var draft = ""
    @State private var hover = RowHoverTracker()
    @State private var rightClick = RightMouseDownMonitor()

    private static let gutter: CGFloat = 62

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
        }
        .onAppear {
            rightClick.onRightMouseDown = { [model, hover] in
                // Only on the card you're in, as on a project card: a highlight moving in a card across
                // the board from the one you right-clicked is a selection changing where you aren't.
                guard model.isEngaged, let key = hover.key else { return }
                let (sitting, row) = Self.split(key)
                model.selection.revealForContextMenu(row, in: sitting)
            }
            rightClick.start()
        }
        .onDisappear { rightClick.stop() }
    }

    /// The hover tracker's key for a row: its sitting and its id, which is unique only within one.
    private static func hoverKey(_ row: String, _ sitting: String) -> String { sitting + "\u{1}" + row }
    private static func split(_ key: String) -> (String, String) {
        let parts = key.split(separator: "\u{1}", maxSplits: 1).map(String.init)
        return (parts.first ?? "", parts.count > 1 ? parts[1] : "")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(.system(size: 13 * zoom, weight: .semibold))
                    .lineLimit(1)
                if span != nil, onSetPeriod != nil { pager }
                Spacer(minLength: 4)
                // Not on an empty day, where the card's body already says so in words.
                Text(model.list.map { $0.sittings.isEmpty && $0.elsewhere.isEmpty } == true ? "" : model.summary)
                    .font(.system(size: 11 * zoom))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            // Said only when it's narrowed: across everything is what a Day card is unless told.
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

    /// What a week or month layout covers, or nil for the list and the rail.
    private var span: CanvasCalendarSpan? { try? model.spec.calendarSpan() }

    private var title: String {
        if let span { return span.title }
        return model.range.map { model.spec.caption(for: $0) } ?? model.spec.period.title
    }

    /// Back a week or month, on one, and Today when it isn't the one today is in. Each is a change to
    /// the node, as the Period menu's are: paging a journal is choosing which page it shows.
    private var pager: some View {
        HStack(spacing: 2) {
            ForEach([-1, 1], id: \.self) { step in
                Button {
                    if let period = try? model.spec.stepped(by: step) { onSetPeriod?(period) }
                } label: {
                    Image(systemName: step < 0 ? "chevron.left" : "chevron.right")
                        .font(.system(size: 10 * zoom, weight: .semibold))
                        .frame(width: 16 * zoom, height: 16 * zoom)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(step < 0 ? "Previous \(model.spec.shownLayout.title)" : "Next \(model.spec.shownLayout.title)")
            }
            if !model.spec.showsToday() {
                Button("Today") { onSetPeriod?(.today) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11 * zoom))
                    .foregroundStyle(Color.accentColor)
                    .padding(.leading, 2)
            }
        }
    }

    @ViewBuilder private var content: some View {
        if let failure = model.failure, model.list == nil {
            quiet(failure)
        } else if let list = model.list, let span {
            // A week or a month is drawn even when it's empty: an empty week is still seven days.
            if model.spec.shownLayout == .week {
                CanvasDayWeek(span: span, list: list, zoom: zoom, onOpenProject: onOpenProject,
                              onOpenDay: onOpenDay, sittingCard: sittingCard)
            } else {
                CanvasMonthGrid(span: span, zoom: zoom, isQuiet: { !$0.hasPrefix(span.month ?? $0) },
                                onOpenDay: onOpenDay) { day, _ in
                    CanvasDayMonthCell(sittings: CanvasTimeGrid.ordered(list.sittings.filter { $0.session == day }), zoom: zoom)
                }
            }
        } else if let list = model.list {
            if list.sittings.isEmpty && list.elsewhere.isEmpty {
                quiet(emptyMessage)
            } else {
                ScrollView(.vertical) {
                    if model.spec.shownLayout == .rail {
                        rail(list)
                    } else {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(days(list), id: \.self) { day in
                                dayBlock(day, in: list)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                }
            }
        } else {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// An empty day says so quietly, the way an empty session does, and offers nothing: starting work
    /// is done in a project, not here.
    private var emptyMessage: String {
        switch model.spec.projects {
        case .board where model.boardProjects.isEmpty: return "No project cards on this board."
        default:
            switch model.spec.period {
            case .today: return "Nothing written today."
            case .yesterday: return "Nothing written yesterday."
            case .week: return "Nothing written this week."
            case .day: return "Nothing written that day."
            }
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

    // MARK: Days

    /// The days in the answer, newest first — each sitting's own, and each day something was finished
    /// in no sitting.
    private func days(_ list: SittingList) -> [String] {
        var days = Set(list.sittings.map(\.session))
        for item in list.elsewhere { if let day = Self.localISO(item.at) { days.insert(day) } }
        return days.sorted(by: >)
    }

    @ViewBuilder private func dayBlock(_ day: String, in list: SittingList) -> some View {
        let sittings = list.sittings.filter { $0.session == day }
        let elsewhere = list.elsewhere.filter { Self.localISO($0.at) == day }
        if model.spec.period.isSpan {
            Text(Self.dayCaption(day))
                .font(.system(size: 11 * zoom, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 2)
        }
        ForEach(sittings, id: \.id) { sitting in
            sittingBlock(sitting)
        }
        if !elsewhere.isEmpty { alsoFinished(elsewhere) }
    }

    // MARK: The rail

    /// One day down its time gutter (D9): each sitting at least as far below the last as the time
    /// between them, and each completion from no sitting at its own time, so a tick from the menubar at
    /// 4:02 is on the rail at 4:02. A faint line runs down the gutter's edge, which is the rail.
    private func rail(_ list: SittingList) -> some View {
        let entries = CanvasTimeGrid.railEntries(list)
        return CanvasRailLayout(perMinute: 0.8 * zoom, gap: 0) {
            ForEach(entries) { entry in
                Group {
                    switch entry.kind {
                    case .sitting(let sitting): sittingBlock(sitting)
                    case .done(let item): railDone(item)
                    }
                }
                .layoutValue(key: CanvasRailLayout.Minute.self, value: entry.minute)
            }
        }
        .background(alignment: .leading) {
            Rectangle().fill(.quaternary).frame(width: 1).padding(.leading, 4 + Self.gutter * zoom + 3.5)
        }
        .padding(.vertical, 6)
    }

    /// A completion on the rail: its time in the gutter, then what it was and where.
    private func railDone(_ item: DoneItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(Self.clock(item.at) ?? "")
                .font(.system(size: 11 * zoom).monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: Self.gutter * zoom, alignment: .trailing)
                .lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                TaskStatusIcon(state: item.dropped ? .dropped : .done, size: 12 * zoom)
                Text(item.text)
                    .font(.system(size: 12.5 * zoom))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
                Spacer(minLength: 4)
                Text(item.projectName)
                    .font(.system(size: 10 * zoom))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .padding(.leading, 4)
        .padding(.trailing, 12)
        .padding(.vertical, 3)
    }

    // MARK: A sitting

    private func sittingBlock(_ sitting: SittingEntry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            // The time is the sitting's handle: dragged off, it makes a card of this one sitting (D7).
            Text(sitting.startTime ?? "Earlier")
                .font(.system(size: 11 * zoom).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: Self.gutter * zoom, alignment: .trailing)
                .lineLimit(1)
                .contentShape(Rectangle())
                .ifCondition(sittingCard != nil) { view in view.onDrag { sittingCard?(sitting) ?? NSItemProvider() } }
                .help(sittingCard == nil ? "" : "Drag to make a card of this sitting")
            VStack(alignment: .leading, spacing: 3) {
                chip(sitting)
                    .ifCondition(sittingCard != nil) { view in view.onDrag { sittingCard?(sitting) ?? NSItemProvider() } }
                if model.spec.period.isSpan {
                    // The chip already says the sitting's name, so the lede is what it says.
                    let lede = sittingLede(name: "", prose: sitting.prose)
                    if !lede.isEmpty, lede != sitting.name {
                        Text(lede)
                            .font(.system(size: 12 * zoom))
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    let counts = CanvasDayRows.counts(sitting)
                    if !counts.isEmpty {
                        Text(counts)
                            .font(.system(size: 11 * zoom))
                            .foregroundStyle(.tertiary)
                    }
                } else {
                    if !sitting.prose.isEmpty {
                        RenderedNote(prose: sitting.prose, font: .systemFont(ofSize: 12.5 * zoom),
                                     noteURL: nil, maxImageHeight: 240)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    let rows = CanvasDayRows.rows(sitting)
                    if !rows.isEmpty {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(rows) { row($0, in: sitting, among: rows) }
                        }
                        .padding(.top, sitting.prose.isEmpty ? 0 : 3)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, 4)
        .padding(.trailing, 12)
        .padding(.vertical, 6)
    }

    /// The project chip (views.md rule 3): its icon, else its colour as a dot, then its name — and the
    /// sitting's own name after it, and *now* on one still going.
    private func chip(_ sitting: SittingEntry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
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
            if !sitting.name.isEmpty {
                Text(sitting.name)
                    .font(.system(size: 12 * zoom))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if sitting.isCurrent {
                Text("now")
                    .font(.system(size: 10 * zoom, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.accentColor.opacity(0.12)))
            }
        }
    }

    // MARK: Rows

    private func row(_ row: CanvasDayRow, in sitting: SittingEntry, among rows: [CanvasDayRow]) -> some View {
        let state = model.pending[CanvasDayRows.key(row, in: sitting)] ?? row.state
        let order = rows.map(\.id)
        let acts = onAct == nil ? [] : CanvasDayAction.offered(for: row, in: sitting)
        return CanvasViewRow(
            row: row, state: state,
            isSelected: model.selection.contains(row.id, in: sitting.id),
            isEngaged: model.isEngaged, zoom: zoom,
            // The box ticks and unticks that row alone; the selection is the menu's.
            toggle: acts.contains(.complete) ? .complete : acts.contains(.reopen) ? .reopen : nil,
            onToggle: { perform(state == .open ? .complete : .reopen, [row], in: sitting) },
            isEditing: editing == row.id, draft: $draft,
            onSubmitEdit: {
                onAct?(.edit(draft), [row], sitting)
                editing = nil
            },
            onCancelEdit: { editing = nil },
            onOpenProject: onOpenProject,
            onHover: { hover.set(Self.hoverKey(row.id, sitting.id), inside: $0) },
            // `clickCount` rather than a double-tap gesture, which would hold every single click for the
            // double-click interval — the project card's reason, and its gesture: the first click
            // selects, the second opens (focus an open task, retype a closed one or with ⌥).
            onClick: {
                guard onAct != nil, editing == nil else { return }
                if NSApp.currentEvent?.clickCount == 2 {
                    if NSEvent.modifierFlags.contains(.option) || state != .open { beginEditing(row) }
                    else { perform(.focus, [row], in: sitting) }
                } else {
                    model.selection.click(row.id, in: sitting.id, modifiers: NSEvent.modifierFlags, order: order)
                }
            },
            // A task dragged off is its markdown, and lands as a text card — what a task dragged off a
            // project card does. The selection goes with it when the row is in it.
            drag: {
                NSItemProvider(object: CanvasDayRows.markdown(targets(row, in: sitting, among: rows)) as NSString)
            },
            trailing: {
                if let origin = row.origin {
                    Text(row.pickedUp ? "\(origin) · picked up" : origin)
                        .font(.system(size: 10 * zoom))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.primary.opacity(0.06)))
                        .fixedSize()
                }
            },
            menu: { menu(row, in: sitting, among: rows) })
    }

    /// The rows a command on `row` acts on, in the order they're drawn: the selection when the row is in
    /// it, else the row alone (Finder's rule, and `RowSelection.targets`).
    private func targets(_ row: CanvasDayRow, in sitting: SittingEntry, among rows: [CanvasDayRow]) -> [CanvasDayRow] {
        let ids = model.selection.targets(clicked: row.id, in: sitting.id)
        return rows.filter { ids.contains($0.id) }
    }

    /// The project card's menu for a row or a selection, as far as rows alone can answer it, and Go to
    /// Project. Counts say how many rows each item touches, when that's more than one.
    @ViewBuilder
    private func menu(_ row: CanvasDayRow, in sitting: SittingEntry, among rows: [CanvasDayRow]) -> some View {
        let scope = targets(row, in: sitting, among: rows)
        if onAct != nil {
            let acts = CanvasDayAction.offered(for: scope, in: sitting)
            ForEach(acts, id: \.title) { act in
                Button { perform(act, scope, in: sitting) } label: {
                    Label(act.title(count: act.count(of: scope, among: rows)), systemImage: act.symbol)
                }
            }
            if scope.count == 1, row.ref != nil {
                Button { beginEditing(row) } label: {
                    Label(CanvasDayAction.edit("").title, systemImage: CanvasDayAction.edit("").symbol)
                }
            }
            if !acts.isEmpty { Divider() }
        }
        Button { TaskPasteboard.copy(markdown: CanvasDayRows.markdown(scope)) } label: {
            Label(scope.count > 1 ? "Copy \(scope.count) Tasks" : "Copy", systemImage: "doc.on.doc")
        }
        Divider()
        Button { onOpenProject(sitting.projectFolder) } label: {
            Label("Go to \(sitting.projectName)", systemImage: "arrow.turn.down.right")
        }
    }

    private func beginEditing(_ row: CanvasDayRow) {
        guard row.ref != nil else { return }
        draft = row.text
        editing = row.id
    }

    /// Act, drawing the rows as they're about to be where that's certain.
    private func perform(_ act: CanvasDayAction, _ rows: [CanvasDayRow], in sitting: SittingEntry) {
        for row in rows {
            let key = CanvasDayRows.key(row, in: sitting)
            switch act {
            case .complete where row.state == .open: model.expect(.done, for: key)
            case .reopen where row.state != .open: model.expect(.open, for: key)
            case .drop where row.state == .open: model.expect(.dropped, for: key)
            default: break
            }
        }
        onAct?(act, rows, sitting)
    }

    // MARK: Also finished

    /// Completions that fell in no sitting — a tick from the menubar in a project you never sat down to.
    /// Each carries its project and its time.
    private func alsoFinished(_ items: [DoneItem]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Also finished")
                .font(.system(size: 11 * zoom))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 1)
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    TaskStatusIcon(state: item.dropped ? .dropped : .done, size: 12 * zoom)
                    Text(item.text)
                        .font(.system(size: 12.5 * zoom))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .layoutPriority(1)
                    Spacer(minLength: 4)
                    Text([item.projectName, Self.clock(item.at)].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 10 * zoom))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
        }
        .padding(.leading, 12 + Self.gutter * zoom - 8)
        .padding(.trailing, 12)
        .padding(.vertical, 6)
    }

    // MARK: Dates

    private static let isoInstant: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// The local day an instant fell on, as `YYYY-MM-DD`.
    static func localISO(_ instant: String) -> String? {
        guard let date = isoInstant.date(from: instant) else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    static func clock(_ instant: String) -> String? {
        guard let date = isoInstant.date(from: instant) else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "h:mm a"
        return f.string(from: date)
    }

    /// A week's caption for one of its days: "Thu, Sep 17".
    static func dayCaption(_ iso: String) -> String {
        let reader = DateFormatter()
        reader.locale = Locale(identifier: "en_US_POSIX")
        reader.dateFormat = "yyyy-MM-dd"
        guard let date = reader.date(from: iso) else { return iso }
        let f = DateFormatter()
        f.dateFormat = "EEE, MMM d"
        return f.string(from: date)
    }
}
