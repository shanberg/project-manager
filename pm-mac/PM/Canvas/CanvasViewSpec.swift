import Foundation
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
    /// Which question. The set is closed (D1); Day is the first.
    enum Kind: String, CaseIterable {
        case day
    }

    /// When (D2). A relative period follows the clock, so a Today card left on a board is tomorrow's
    /// today; a date pins it, and it becomes a page of the journal.
    enum Period: Equatable {
        case today, yesterday, week
        /// A local day, `YYYY-MM-DD`.
        case day(String)

        var value: String {
            switch self {
            case .today: return "today"
            case .yesterday: return "yesterday"
            case .week: return "week"
            case .day(let iso): return iso
            }
        }

        init(value: String) {
            switch value.trimmingCharacters(in: .whitespaces).lowercased() {
            case "yesterday": self = .yesterday
            case "week": self = .week
            case let iso where iso.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil:
                self = .day(iso)
            default: self = .today
            }
        }

        /// The span the query is asked for.
        func range(now: Date = Date(), calendar: Calendar = .current) throws -> DoneRange {
            switch self {
            case .today, .yesterday, .week:
                return try DoneRange.resolve(period: value, since: nil, until: nil, now: now, calendar: calendar)
            case .day(let iso):
                return try DoneRange.resolve(period: nil, since: iso, until: iso, now: now, calendar: calendar)
            }
        }

        /// Whether this is more than one day, which is what decides between the day's full prose and a
        /// week's ledes (D5).
        var isSpan: Bool { self == .week }

        /// What the menu calls it.
        var title: String {
            switch self {
            case .today: return "Today"
            case .yesterday: return "Yesterday"
            case .week: return "This Week"
            case .day(let iso): return SessionPicks.day(iso: iso) ?? iso
            }
        }

        /// The relative periods, in the order the menu lists them.
        static let relative: [Period] = [.today, .yesterday, .week]
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

    // MARK: On the node

    static let viewKey = "pmView"
    static let periodKey = "pmPeriod"
    static let projectsKey = "pmProjects"

    /// The view this node is, or nil for a node that isn't one — anything but a text node, a text node
    /// without the key, or one naming a view this build doesn't have.
    static func of(_ node: CanvasNode) -> CanvasViewSpec? {
        guard case .text = node.content,
              case .string(let raw)? = node.extra[viewKey],
              let kind = Kind(rawValue: raw.trimmingCharacters(in: .whitespaces).lowercased()) else { return nil }
        var spec = CanvasViewSpec(kind: kind)
        if case .string(let period)? = node.extra[periodKey] { spec.period = Period(value: period) }
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
        switch spec.projects {
        case .everything: node.extra[projectsKey] = nil
        case .board: node.extra[projectsKey] = .string("board")
        case .named(let names): node.extra[projectsKey] = .array(names.map { .string($0) })
        }
    }

    /// The one line the node's text holds, for Obsidian. Written once, when the card is made.
    var noteText: String {
        switch kind {
        case .day: return "\(period.title), across projects: a Folio view."
        }
    }

    /// A new Day card: today, across everything.
    static let newDay = CanvasViewSpec(kind: .day)

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
                                    pickedUp: pickedUp))
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
