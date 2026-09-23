import AppKit
import PmLib

/// A card that draws the answer to a question about the backbone rather than a document — a *view*
/// (docs/views.md). This is what the node says about which one, and for what.
///
/// **A text node, carrying keys.** JSON Canvas has four node types and a fifth would be a bet on what
/// Obsidian does with one it doesn't know, so a view is a text card with `pmView` on it (D3). Its text
/// is one line written when the card is made and never touched again, so a board opened in Obsidian shows
/// a card that says what it is. The answer itself is never written anywhere: a Today card rewriting the
/// `.canvas` on every tick would be churn in a file that syncs, and a second truth about the day.
///
/// **Forgiving, like `CanvasCardShows`.** An unknown `pmView` (a typo, or a view from a newer build) is
/// not a view, and the card draws its text as the text card it also is. An unknown period or projects
/// value falls back to the default rather than to nothing.
struct CanvasViewSpec: Equatable {
    /// Which question. The set is closed (D1).
    ///
    /// **The kind itself lives in PmLib** as `CanvasViewKind`, with its name and its symbol, because a
    /// board is read by things that are not this app (docs/items.md D2). What stays here is what only a
    /// card has an opinion about: which periods its menu offers, and which layouts answer it.
    typealias Kind = CanvasViewKind

    /// When (D2). A relative period follows the clock, so a Today card left on a board is tomorrow's
    /// today; a date pins it, and it becomes a page of the journal.
    enum Period: Equatable {
        case today, yesterday, week, month
        /// A local day, `YYYY-MM-DD`.
        case day(String)

        var value: String {
            switch self {
            case .today: return "today"
            case .yesterday: return "yesterday"
            case .week: return "week"
            case .month: return "month"
            case .day(let iso): return iso
            }
        }

        init(value: String) {
            switch value.trimmingCharacters(in: .whitespaces).lowercased() {
            case "yesterday": self = .yesterday
            case "week": self = .week
            case "month": self = .month
            case let iso where iso.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil:
                self = .day(iso)
            default: self = .today
            }
        }

        /// The span the query is asked for.
        func range(now: Date = Date(), calendar: Calendar = .current) throws -> DoneRange {
            switch self {
            case .today, .yesterday, .week, .month:
                return try DoneRange.resolve(period: value, since: nil, until: nil, now: now, calendar: calendar)
            case .day(let iso):
                return try DoneRange.resolve(period: nil, since: iso, until: iso, now: now, calendar: calendar)
            }
        }

        /// Whether this is more than one day, which is what decides between the day's full prose and a
        /// week's ledes (D5).
        var isSpan: Bool { self == .week || self == .month }

        /// What the menu calls it.
        var title: String {
            switch self {
            case .today: return "Today"
            case .yesterday: return "Yesterday"
            case .week: return "This Week"
            case .month: return "This Month"
            case .day(let iso): return SessionPicks.day(iso: iso) ?? iso
            }
        }

        /// What the menu calls it on a Leftovers card, which reads it as a cut-off: "Before Today".
        var beforeTitle: String {
            switch self {
            case .today: return "Before Today"
            case .yesterday: return "Before Yesterday"
            case .week: return "Before This Week"
            case .month: return "Before This Month"
            case .day: return "Before \(title)"
            }
        }

        /// What the menu calls it on a Coming up card, which reads it as a horizon: `week` is the next
        /// seven days and `month` five rolling weeks (`dueCutoff`), where a Day's week or month is the
        /// calendar's.
        var dueTitle: String {
            switch self {
            case .today, .yesterday: return "Due Today"
            case .week: return "Next 7 Days"
            case .month: return "Next 5 Weeks"
            case .day: return "Through \(title)"
            }
        }

        /// The relative periods, in the order the menu lists them.
        static let relative: [Period] = [.today, .yesterday, .week, .month]
    }

    /// How time is laid out (D9). Only some fit a view, and the rail only one day — see `shownLayout`.
    enum Layout: String, CaseIterable {
        /// Grouped, in order: every view's.
        case list
        /// One day down a time gutter, each sitting placed at when it began.
        case rail
        /// Seven columns, a sitting a block at its start time, what's due at the top of its day.
        case week
        /// A grid of days, each marked with its sittings and what falls due.
        case month

        var title: String {
            switch self {
            case .list: return "List"
            case .rail: return "Rail"
            case .week: return "Week"
            case .month: return "Month"
            }
        }

        /// The least a card needs to draw it, grown to when the layout is chosen: seven columns don't
        /// fit in a day's column.
        var minimumSize: CGSize? {
            switch self {
            case .list, .rail: return nil
            case .week: return CGSize(width: 780, height: 480)
            case .month: return CGSize(width: 560, height: 500)
            }
        }
    }

    /// Which projects (D2).
    enum Projects: Equatable {
        /// Every project and area — and the archive, for what was archived in the span.
        case everything
        /// The projects with a card on this board, following the board as cards come and go.
        case board
        /// These, by name, prefix or `[[link]]`. A master brings its members.
        case named([String])

        var title: String {
            switch self {
            case .everything: return "All Projects"
            case .board: return "Projects on This Board"
            case .named(let names):
                return names.count == 1
                    ? (ProjectPartOf.writtenName(in: names[0]) ?? names[0])
                    : "\(names.count) Projects"
            }
        }
    }

    var kind: Kind
    var period: Period = .today
    var projects: Projects = .everything
    /// What a Search view looks for. Empty until it's told.
    var query: String = ""
    var layout: Layout = .list

    /// The layout drawn: the one set, when this view offers it and it fits the period — the rail is one
    /// day's, so a Day set to This Week draws its list — else the list. What's set is kept either way,
    /// so a card set back to one day is back on its rail.
    var shownLayout: Layout {
        guard kind.layouts.contains(layout) else { return .list }
        if layout == .rail && period.isSpan { return .list }
        return layout
    }

    // MARK: How the card names itself

    /// What the card is called in one word or two: its period for a Day, else its kind — and for
    /// Leftovers the cut-off, when it isn't today.
    ///
    /// The one answer for every place the card is named: its zoomed-out face, and — through
    /// `CanvasExistingCards.card` — a tile's tab, Add Card from Canvas and a dragged tile's proxy.
    var cardName: String {
        switch kind {
        // A week or a month says which: "September 2026".
        case .day: return ((try? calendarSpan()) ?? nil)?.title ?? period.title
        case .waiting: return "Waiting"
        case .search: return query.isEmpty ? "Search" : "Search “\(query)”"
        case .leftovers: return period == .today ? "Leftovers" : "Leftovers \(period.beforeTitle)"
        case .comingUp: return "Coming Up"
        case .projects: return "Projects"
        // Which span, the way Day says it: a Time card pinned to a date is that day's.
        case .time: return period == .today ? "Time" : "Time · \(period.title)"
        }
    }

    /// The SF Symbol that stands for the card wherever it is one line — see `cardName`. The kind's
    /// own, since nothing a card is set to changes what question it asks.
    var symbol: String { kind.symbol }

    // MARK: On the node

    static let viewKey = CanvasViewKind.nodeKey
    static let periodKey = "pmPeriod"
    static let projectsKey = "pmProjects"
    static let queryKey = "pmQuery"
    static let layoutKey = "pmLayout"

    /// The view this node is, or nil for a node that isn't one — anything but a text node, a text node
    /// without the key, or one naming a view this build doesn't have.
    static func of(_ node: CanvasNode) -> CanvasViewSpec? {
        guard let kind = CanvasViewKind.of(node) else { return nil }
        var spec = CanvasViewSpec(kind: kind)
        if case .string(let period)? = node.extra[periodKey] { spec.period = Period(value: period) }
        if case .string(let query)? = node.extra[queryKey] { spec.query = query }
        if case .string(let layout)? = node.extra[layoutKey],
           let known = Layout(rawValue: layout.trimmingCharacters(in: .whitespaces).lowercased()) { spec.layout = known }
        switch node.extra[projectsKey] {
        case .string(let value)? where value.trimmingCharacters(in: .whitespaces).lowercased() == "board":
            spec.projects = .board
        case .string(let value)? where !value.trimmingCharacters(in: .whitespaces).isEmpty:
            spec.projects = .named([value])
        case .array(let items)?:
            let names = items.compactMap { item -> String? in
                if case .string(let name) = item, !name.trimmingCharacters(in: .whitespaces).isEmpty { return name }
                return nil
            }
            if !names.isEmpty { spec.projects = .named(names) }
        default:
            break
        }
        return spec
    }

    /// Write this onto a node, leaving out what is the default — so a card set back to Today across
    /// everything carries only `pmView`.
    static func set(_ spec: CanvasViewSpec, on node: inout CanvasNode) {
        node.extra[viewKey] = .string(spec.kind.rawValue)
        node.extra[periodKey] = spec.period == .today ? nil : .string(spec.period.value)
        let query = spec.query.trimmingCharacters(in: .whitespaces)
        node.extra[queryKey] = query.isEmpty ? nil : .string(query)
        node.extra[layoutKey] = spec.layout == .list ? nil : .string(spec.layout.rawValue)
        switch spec.projects {
        case .everything: node.extra[projectsKey] = nil
        case .board: node.extra[projectsKey] = .string("board")
        case .named(let names): node.extra[projectsKey] = .array(names.map { .string($0) })
        }
    }

    /// The one line the node's text holds, for Obsidian. Written once, when the card is made.
    var noteText: String {
        let scope = projects == .board ? "across this board's projects" : "across projects"
        switch kind {
        case .day: return "\(period.title), \(scope): a Folio view."
        case .waiting: return "What I'm waiting on, \(scope): a Folio view."
        case .search: return "A search of \(projects == .board ? "this board's" : "every project's") tasks: a Folio view."
        case .leftovers: return "Tasks left open \(period.beforeTitle.lowercased()), \(scope): a Folio view."
        case .comingUp: return "What's due, \(scope): a Folio view."
        case .projects: return "\(projects == .board ? "This board's projects" : "Every project"), and when it was last worked on: a Folio view."
        case .time: return "Where the time went \(period.title.lowercased()), \(scope): a Folio view."
        }
    }

    /// A new view card starts across the projects on the board it is put on (Day here, and each of the
    /// others below). A card left on a board is about that board's work, so that is where it starts; "All Projects" is one menu item away, and
    /// a card already stored without the key still reads as everything (`of`).
    static let newDay = CanvasViewSpec(kind: .day, projects: .board)
    static let newWaiting = CanvasViewSpec(kind: .waiting, projects: .board)
    static let newSearch = CanvasViewSpec(kind: .search, projects: .board)
    static let newLeftovers = CanvasViewSpec(kind: .leftovers, projects: .board)
    /// Coming up starts a week out: today alone is a to-do list, and the horizon is the point.
    static let newComingUp = CanvasViewSpec(kind: .comingUp, period: .week, projects: .board)
    static let newProjects = CanvasViewSpec(kind: .projects, projects: .board)
    static let newTime = CanvasViewSpec(kind: .time, projects: .board)

    /// The card's caption for a period: "Today · Fri, Sep 18", or the week it covers.
    func caption(for range: DoneRange, calendar: Calendar = .current) -> String {
        let day = DateFormatter()
        day.dateFormat = "EEE, MMM d"
        switch period {
        case .today, .yesterday:
            return "\(period.title) · \(day.string(from: range.start))"
        case .week:
            let last = calendar.date(byAdding: .day, value: -1, to: range.end) ?? range.end
            let short = DateFormatter()
            short.dateFormat = "MMM d"
            return "This Week · \(short.string(from: range.start))–\(short.string(from: last))"
        case .month:
            let long = DateFormatter()
            long.dateFormat = "LLLL yyyy"
            return "This Month · \(long.string(from: range.start))"
        case .day:
            return day.string(from: range.start)
        }
    }
}

// MARK: - What a sitting draws

/// One line under a sitting on a Day card.
struct CanvasDayRow: Identifiable, Equatable {
    let id: String
    let text: String
    let state: TaskState
    let depth: Int
    /// The quiet chip after the text: where a picked-up tree came from, or which sitting a task finished
    /// here was written in. Nil for the sitting's own tasks.
    let origin: String?
    /// Whether this row is a picked-up tree's root, which says so beside its chip.
    let pickedUp: Bool
    /// Where the line is, for acting on it. Nil for a line that's gone, which can only be read.
    var ref: TaskRefInput? = nil
    /// Whether the line itself says what it's waiting on — so Stop Waiting has a token to clear.
    var declaresWait = false
}

enum CanvasDayRows {
    /// A sitting's tasks as one list, each line once: what was written in it, then the trees picked up
    /// into it, then anything finished or dropped while it was going on that was written elsewhere.
    ///
    /// `session.list` lists a task by every role it has, so one written and ticked in the same sitting is
    /// in both `written` and `finished`. Here it's the one row, drawn in the state its line is in.
    static func rows(_ sitting: SittingEntry) -> [CanvasDayRow] {
        var seen = Set<String>()
        var out: [CanvasDayRow] = []
        func add(_ task: SittingTask, role: String, depth: Int, origin: String?, pickedUp: Bool = false) {
            let key = task.ref.map { "\($0.session ?? ""):\($0.sessionOrdinal ?? 0):\($0.line)" }
            if let key { guard seen.insert(key).inserted else { return } }
            out.append(CanvasDayRow(id: key ?? "\(role)/\(out.count)/\(task.text)", text: task.text,
                                    state: state(task.state), depth: depth, origin: origin,
                                    pickedUp: pickedUp, ref: task.ref))
        }
        for task in sitting.written { add(task, role: "written", depth: task.depth, origin: nil) }
        for task in sitting.picked {
            let isRoot = task.depth == 0
            add(task, role: "picked", depth: task.depth,
                origin: isRoot ? SessionPicks.day(iso: task.from) : nil, pickedUp: isRoot)
        }
        for task in sitting.finished + sitting.dropped {
            let from = task.ref?.session
            add(task, role: "closed", depth: 0,
                origin: from == sitting.session ? nil : SessionPicks.day(iso: from))
        }
        return out
    }

    /// A row across the whole card — its id is unique only within its project, and one line can be drawn
    /// in two sittings of that project (written in one, finished in another), which are the same line.
    static func key(_ row: CanvasDayRow, in sitting: SittingEntry) -> String {
        "\(sitting.projectFolder)/\(row.id)"
    }

    /// The rows of `selected` that no other selected row is above — the trees a selection is, in the
    /// order they're drawn. `all` is the sitting's rows as drawn, whose depths say what's under what.
    static func roots(of selected: [CanvasDayRow], in all: [CanvasDayRow]) -> [CanvasDayRow] {
        let picked = Set(selected.map(\.id))
        var out: [CanvasDayRow] = []
        // The chain of rows above the current one, by depth.
        var above: [CanvasDayRow] = []
        for row in all {
            while let last = above.last, last.depth >= row.depth { above.removeLast() }
            if picked.contains(row.id), !above.contains(where: { picked.contains($0.id) }) { out.append(row) }
            above.append(row)
        }
        return out
    }

    /// Rows as the markdown they'd be in a note — what a drag off a Day card carries, and so what it
    /// lands as: a text card, the way a task dragged off a project card does. Indented from the
    /// shallowest row dragged, so a subtask dragged alone is a task of its own.
    static func markdown(_ rows: [CanvasDayRow]) -> String {
        let base = rows.map(\.depth).min() ?? 0
        return rows.map { row in
            let box: String
            switch row.state {
            case .open: box = "[ ]"
            case .done: box = "[x]"
            case .dropped: box = "[-]"
            }
            return String(repeating: "  ", count: max(0, row.depth - base)) + "- \(box) \(row.text)"
        }
        .joined(separator: "\n")
    }

    /// What a week draws in place of a sitting's tasks: how much came of it.
    static func counts(_ sitting: SittingEntry) -> String {
        var parts: [String] = []
        if !sitting.finished.isEmpty { parts.append("\(sitting.finished.count) done") }
        if !sitting.dropped.isEmpty { parts.append("\(sitting.dropped.count) dropped") }
        let picked = sitting.picked.filter { $0.depth == 0 }.count
        if picked > 0 { parts.append("\(picked) picked up") }
        let open = sitting.written.filter { $0.state == "open" }.count
        if open > 0 { parts.append("\(open) open") }
        return parts.joined(separator: " · ")
    }

    /// The card's one line: its sittings and what came of them. Also what it says zoomed out, and to
    /// VoiceOver.
    static func summary(_ list: SittingList) -> String {
        let sittings = list.sittings.count
        let done = list.sittings.reduce(0) { $0 + $1.finished.count } + list.elsewhere.filter { !$0.dropped }.count
        let dropped = list.sittings.reduce(0) { $0 + $1.dropped.count } + list.elsewhere.filter(\.dropped).count
        var parts = [sittings == 0 ? "No sittings" : "\(sittings) sitting\(sittings == 1 ? "" : "s")"]
        if done > 0 { parts.append("\(done) done") }
        if dropped > 0 { parts.append("\(dropped) dropped") }
        return parts.joined(separator: " · ")
    }

    private static func state(_ name: String) -> TaskState {
        switch name {
        case "done": return .done
        case "dropped": return .dropped
        default: return .open
        }
    }
}

/// Which rows of a Day card are selected: one sitting's, never more (docs/views.md D6).
///
/// **Locked to a sitting**, because a sitting is one project and so one store: whatever a selection is
/// told to do is one write and one step on that project's history, and ⌘Z takes all of it back. A
/// selection across projects would be several writes on several stores, and several ⌘Zs for one
/// gesture. So a click in another sitting starts over there, whatever keys are held.
///
/// The picking itself is `RowSelection`'s — the project card's and the window's rules for ⇧ and ⌘ —
/// over the sitting's rows. Row ids are unique within a sitting, which is all they need to be here.
struct CanvasDaySelection: Equatable {
    /// The sitting the selection is in, by `SittingEntry.id`.
    private(set) var sitting: String?
    private(set) var rows = RowSelection()

    var isEmpty: Bool { rows.isEmpty }
    var count: Int { rows.count }

    func contains(_ row: String, in sitting: String) -> Bool {
        self.sitting == sitting && rows.contains(row)
    }

    /// A click on `row` in `sitting`, whose rows are `order` as drawn.
    mutating func click(_ row: String, in sitting: String, modifiers: NSEvent.ModifierFlags, order: [String]) {
        if self.sitting != sitting {
            self.sitting = sitting
            rows = RowSelection()
            rows.click(row, modifiers: [], in: order)
        } else {
            rows.click(row, modifiers: modifiers, in: order)
        }
        if rows.isEmpty { self.sitting = nil }
    }

    /// Finder's rule for a right-click: onto the row, unless it's already in the selection.
    mutating func revealForContextMenu(_ row: String, in sitting: String) {
        if self.sitting != sitting {
            self.sitting = sitting
            rows = RowSelection()
        }
        rows.revealForContextMenu(row)
    }

    /// What a command on `row` acts on: the selection when the row is in it, else the row alone.
    func targets(clicked row: String, in sitting: String) -> Set<String> {
        self.sitting == sitting ? rows.targets(clicked: row) : [row]
    }

    mutating func clear() {
        sitting = nil
        rows.clear()
    }

    /// Drop what's no longer drawn, after the card looks again. `drawn` is each sitting's row ids.
    mutating func keep(within drawn: [String: [String]]) {
        guard let sitting else { return }
        guard let order = drawn[sitting] else { return clear() }
        rows.keep(within: order)
        if rows.isEmpty { self.sitting = nil }
    }
}

/// What only a card has an opinion about: which periods its menu offers, and which layouts answer its
/// question. The kind itself, its name and its symbol are `CanvasViewKind` in PmLib — see the
/// typealias above.
extension CanvasViewKind {
    /// Whether *when* means anything to it. Waiting and Projects are about now, and a search is about
    /// words.
    var hasPeriod: Bool { self == .day || self == .leftovers || self == .comingUp || self == .time }

    /// The periods its menu offers, in order: Coming up looks ahead, so it has no yesterday.
    var periods: [CanvasViewSpec.Period] {
        self == .comingUp ? [.today, .week] : CanvasViewSpec.Period.relative
    }

    /// The layouts that answer its question (D9): a Day can be read down a rail, across a week or as a
    /// month, and Coming up across a week or a month. A list of tasks from anywhere has no shape in time.
    var layouts: [CanvasViewSpec.Layout] {
        switch self {
        case .day: return [.list, .rail, .week, .month]
        case .comingUp: return [.list, .week, .month]
        // Time is a list and only a list. Its answer is one row per project, and a rail, a week or a
        // month would be laying out *sittings* — which is the Day card's question, already answered
        // beside it (docs/time-tracking.md D7).
        case .waiting, .search, .leftovers, .projects, .time: return [.list]
        }
    }

    /// What its menu calls `period`: a Day's span, Leftovers' cut-off, Coming up's horizon.
    func title(of period: CanvasViewSpec.Period) -> String {
        switch self {
        case .leftovers: return period.beforeTitle
        case .comingUp: return period.dueTitle
        default: return period.title
        }
    }
}
