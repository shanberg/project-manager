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
    /// to: a tick shows as ticked on the click, not a scan later.
    private(set) var pending: [String: TaskState] = [:]
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
                let range = try spec.period.range()
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
                    if list != self.list { self.list = list }
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
    var onAct: ((CanvasDayAction, CanvasDayRow, SittingEntry) -> Void)?

    /// The row being retyped, and what it says so far.
    @State private var editing: String?
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    private static let gutter: CGFloat = 62

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(model.range.map { model.spec.caption(for: $0) } ?? model.spec.period.title)
                    .font(.system(size: 13 * zoom, weight: .semibold))
                    .lineLimit(1)
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

    @ViewBuilder private var content: some View {
        if let failure = model.failure, model.list == nil {
            quiet(failure)
        } else if let list = model.list {
            if list.sittings.isEmpty && list.elsewhere.isEmpty {
                quiet(emptyMessage)
            } else {
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(days(list), id: \.self) { day in
                            dayBlock(day, in: list)
                        }
                    }
                    .padding(.vertical, 6)
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

    // MARK: A sitting

    private func sittingBlock(_ sitting: SittingEntry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(sitting.startTime ?? "Earlier")
                .font(.system(size: 11 * zoom).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: Self.gutter * zoom, alignment: .trailing)
                .lineLimit(1)
            VStack(alignment: .leading, spacing: 3) {
                chip(sitting)
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
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(rows) { row($0, in: sitting) }
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
                    mark(sitting)
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

    /// The project's icon where it has one it can draw, else its colour as a dot — what the sidebar
    /// shows for it, so a project looks like itself here too.
    @ViewBuilder private func mark(_ sitting: SittingEntry) -> some View {
        let color = sitting.projectColor.flatMap(ProjectColor.init(value:)).map { Color(nsColor: $0.nsColor) }
        if let icon = sitting.projectIcon.flatMap(ProjectIcon.init(value:)), ProjectIconMark.canDraw(icon) {
            ProjectIconMark(icon: icon, size: 11 * zoom, tint: color)
        } else {
            Circle()
                .fill(color ?? Color.secondary.opacity(0.5))
                .frame(width: 7 * zoom, height: 7 * zoom)
        }
    }

    // MARK: Rows

    private func row(_ row: CanvasDayRow, in sitting: SittingEntry) -> some View {
        let state = model.pending[row.id] ?? row.state
        let acts = onAct == nil ? [] : CanvasDayAction.offered(for: row, in: sitting)
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            checkbox(row, state: state, in: sitting, acts: acts)
            if editing == row.id {
                TextField("Task", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5 * zoom))
                    .focused($fieldFocused)
                    .onAppear { fieldFocused = true }
                    .onSubmit {
                        onAct?(.edit(draft), row, sitting)
                        editing = nil
                    }
                    .onExitCommand { editing = nil }
            } else {
                Text(row.text)
                    .font(.system(size: 12.5 * zoom))
                    .foregroundStyle(state == .open ? .primary : .secondary)
                    .strikethrough(state == .dropped, color: .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
            }
            Spacer(minLength: 4)
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
        }
        .padding(.leading, Double(row.depth) * 11 * zoom)
        .contentShape(Rectangle())
        .contextMenu {
            // The project card's menu for a row, as far as a row alone can answer it, and Go to Project.
            if row.ref != nil, onAct != nil {
                ForEach(acts, id: \.title) { act in
                    Button { perform(act, row, in: sitting) } label: { Label(act.title, systemImage: act.symbol) }
                }
                Button {
                    draft = row.text
                    editing = row.id
                } label: { Label(CanvasDayAction.edit("").title, systemImage: CanvasDayAction.edit("").symbol) }
                Divider()
            }
            Button { onOpenProject(sitting.projectFolder) } label: {
                Label("Go to \(sitting.projectName)", systemImage: "arrow.turn.down.right")
            }
        }
    }

    /// The row's box, which ticks and unticks it where it can be acted on, and is only a picture where
    /// it can't — a line that's gone, or a card drawn for a test.
    @ViewBuilder
    private func checkbox(_ row: CanvasDayRow, state: TaskState, in sitting: SittingEntry,
                          acts: [CanvasDayAction]) -> some View {
        let toggle: CanvasDayAction? = acts.contains(.complete) ? .complete : acts.contains(.reopen) ? .reopen : nil
        if let toggle {
            Button { perform(toggle, row, in: sitting) } label: {
                TaskStatusIcon(state: state, size: 12 * zoom).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(toggle.title)
        } else {
            TaskStatusIcon(state: state, size: 12 * zoom)
        }
    }

    /// Act, drawing the row as it's about to be where that's certain.
    private func perform(_ act: CanvasDayAction, _ row: CanvasDayRow, in sitting: SittingEntry) {
        switch act {
        case .complete: model.expect(.done, for: row.id)
        case .reopen: model.expect(.open, for: row.id)
        case .drop: model.expect(.dropped, for: row.id)
        default: break
        }
        onAct?(act, row, sitting)
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

extension SittingEntry {
    /// Which sitting this is, across projects.
    var id: String { "\(projectFolder)/\(session)/\(sessionOrdinal)/\(sessionDigest)" }
}
