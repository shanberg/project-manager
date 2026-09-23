import Foundation
import PmLib

// MARK: - What a task-list view draws

/// One group on a view that lists tasks: a Waiting target and everything waiting on it, a search's one
/// ranked list, or one sitting's leftovers.
struct CanvasTaskGroup: Equatable, Identifiable {
    let id: String
    /// The heading, or nil for a list that has none (a search is one list, best first).
    let title: String?
    /// A Waiting group's resolution: `released`, `pending` or `unresolved`.
    let state: String?
    /// The project a Waiting target names, when it names one — a heading you can go to.
    let folder: String?
    let items: [CanvasTaskItem]
    /// A Leftovers group's sitting, which its heading draws.
    var sitting: CanvasLeftoverSitting? = nil

    init(id: String, title: String?, state: String?, folder: String?, items: [CanvasTaskItem],
         sitting: CanvasLeftoverSitting? = nil) {
        self.id = id
        self.title = title
        self.state = state
        self.folder = folder
        self.items = items
        self.sitting = sitting
    }

    init(id: String, title: String?, state: String?, folder: String?, hits: [TaskSearchHit]) {
        self.init(id: id, title: title, state: state, folder: folder, items: hits.map { CanvasTaskItem(hit: $0) })
    }

    var hits: [TaskSearchHit] { items.map(\.hit) }
}

/// One task on a task-list view: the hit, and what only Leftovers knows about it.
struct CanvasTaskItem: Equatable {
    let hit: TaskSearchHit
    /// Indent among the listed tasks. A search and Waiting list tasks flat.
    var depth = 0
    /// The latest sitting it was picked up into.
    var picked: PickMark? = nil

    /// The row `CanvasViewRow` draws and `CanvasDayActions` acts on.
    func row(today: String = CanvasTaskLists.todayISO()) -> CanvasDayRow {
        CanvasDayRow(id: CanvasTaskLists.rowID(hit), text: hit.text, state: .open, depth: depth, origin: nil,
                     pickedUp: picked?.into == today, ref: hit.ref, declaresWait: hit.waiting != nil)
    }

    var key: String { hit.viewKey }
}

/// The sitting a Leftovers group is, for its heading and for dragging it off as a card of its own (D7).
struct CanvasLeftoverSitting: Equatable {
    let projectFolder: String
    let projectName: String
    let projectColor: String?
    let projectIcon: String?
    /// Whether this is the project's first (oldest) sitting in the list, which heads the project.
    let startsProject: Bool
    let session: String
    let sessionOrdinal: Int
    let sessionDigest: String
    let startTime: String?
    let lede: String

    var ref: SessionRef {
        SessionRef(date: session, ordinal: sessionOrdinal, digest: sessionDigest.isEmpty ? nil : sessionDigest)
    }

    /// "Wed, Sep 16 · 2:15 PM", or the day alone for a sitting without a time.
    var dateLabel: String {
        let day = SessionPicks.day(iso: session) ?? session
        return startTime.map { "\(day) · \($0)" } ?? day
    }
}

/// The pure half of the Waiting, Search and Leftovers views (docs/views.md steps 5 and 6): from the contract's answer to
/// groups and rows, and back from rows to what an act or a drag needs.
enum CanvasTaskLists {
    /// How many a search draws. It's ranked, so the ones past this are the ones least like what you
    /// typed, and a card is not the place to page through them.
    static let searchLimit = 50

    /// `task.waiting`'s buckets, one group each, in the contract's order: released first.
    static func groups(waiting buckets: [WaitingBucket]) -> [CanvasTaskGroup] {
        buckets.map { bucket in
            CanvasTaskGroup(id: "waiting/" + (bucket.folder ?? bucket.target.lowercased()), title: bucket.title,
                            state: bucket.state, folder: bucket.folder, hits: bucket.tasks)
        }
    }

    /// A search's matches, best first, as one list without a heading.
    static func groups(search hits: [TaskSearchHit], query: String) -> [CanvasTaskGroup] {
        let ranked = Array(TaskSearch.rank(hits, query: query, focusedProjectKey: nil).prefix(searchLimit))
        return ranked.isEmpty ? [] : [CanvasTaskGroup(id: "search", title: nil, state: nil, folder: nil, hits: ranked)]
    }

    /// `task.leftovers`' answer, one group per sitting, a project's sittings together and oldest first,
    /// the first of each heading its project.
    static func groups(leftovers list: LeftoverList) -> [CanvasTaskGroup] {
        list.projects.flatMap { project in
            project.sittings.enumerated().map { index, sitting in
                CanvasTaskGroup(
                    id: "leftovers/\(project.projectFolder)/\(sitting.session):\(sitting.sessionOrdinal)",
                    title: nil, state: nil, folder: project.projectFolder,
                    items: sitting.tasks.map { task in
                        CanvasTaskItem(hit: project.hit(task), depth: task.depth, picked: task.picked)
                    },
                    sitting: CanvasLeftoverSitting(
                        projectFolder: project.projectFolder, projectName: project.projectName,
                        projectColor: project.projectColor, projectIcon: project.projectIcon,
                        startsProject: index == 0, session: sitting.session,
                        sessionOrdinal: sitting.sessionOrdinal, sessionDigest: sitting.sessionDigest,
                        startTime: sitting.startTime, lede: sitting.lede))
            }
        }
    }

    /// Today as a sitting's heading dates it, which is how a pick names the sitting it went into.
    static func todayISO(now: Date = Date(), calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: now)
    }

    /// `task.due`'s answer by day: everything overdue under one heading, then a heading per day — "Today",
    /// "Tomorrow", then the date.
    static func groups(due hits: [TaskSearchHit], now: Date = Date(), calendar: Calendar = .current) -> [CanvasTaskGroup] {
        let today = isoDay(now, calendar: calendar)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now).map { isoDay($0, calendar: calendar) }
        var groups: [(id: String, title: String, overdue: Bool, hits: [TaskSearchHit])] = []
        for hit in hits {
            let day = String((hit.due ?? "").prefix(10))
            let id = day < today ? "overdue" : day
            if groups.last?.id != id {
                let title: String
                switch day {
                case _ where day < today: title = "Overdue"
                case today: title = "Today"
                case tomorrow: title = "Tomorrow"
                default: title = longDay(day, calendar: calendar)
                }
                groups.append((id, title, day < today, []))
            }
            groups[groups.count - 1].hits.append(hit)
        }
        return groups.map {
            CanvasTaskGroup(id: "due/\($0.id)", title: $0.title, state: $0.overdue ? "overdue" : nil, folder: nil,
                            hits: $0.hits)
        }
    }

    /// "Tue, Sep 22" — a day ahead is near enough that its year goes without saying.
    private static func longDay(_ iso: String, calendar: Calendar) -> String {
        guard let day = try? DoneRange.localDay(iso, calendar: calendar) else { return iso }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "EEE, MMM d"
        return formatter.string(from: day)
    }

    /// A hit as a view's row: what `CanvasViewRow` draws and `CanvasDayActions` acts on. Unique within
    /// its project, which is as far as a selection reaches.
    static func row(_ hit: TaskSearchHit) -> CanvasDayRow { CanvasTaskItem(hit: hit).row() }

    static func rowID(_ hit: TaskSearchHit) -> String {
        "\(hit.session ?? ""):\(hit.sessionOrdinal ?? 0):\(hit.line)"
    }

    /// A row across the whole card, as `CanvasDayRows.key` is on a Day.
    static func key(_ hit: TaskSearchHit) -> String { "\(hit.projectFolder)/\(rowID(hit))" }

    /// Each project's rows in the order they're drawn — the order ⇧ extends a selection through, since
    /// a selection is one project's (`CanvasDaySelection`).
    static func order(_ groups: [CanvasTaskGroup]) -> [String: [String]] {
        var out: [String: [String]] = [:]
        for hit in groups.flatMap(\.hits) { out[hit.projectFolder, default: []].append(rowID(hit)) }
        return out
    }

    /// The card's one line: how much is listed. Also what it says zoomed out, and to VoiceOver.
    static func summary(_ kind: CanvasViewSpec.Kind, _ groups: [CanvasTaskGroup]) -> String {
        let tasks = groups.reduce(0) { $0 + $1.hits.count }
        switch kind {
        case .waiting:
            guard tasks > 0 else { return "Nothing waiting" }
            var parts = ["\(tasks) task\(tasks == 1 ? "" : "s")",
                         "\(groups.count) thing\(groups.count == 1 ? "" : "s")"]
            let released = groups.filter { $0.state == "released" }.count
            if released > 0 { parts.append("\(released) released") }
            return parts.joined(separator: " · ")
        case .search:
            return tasks == 0 ? "No matches" : "\(tasks) match\(tasks == 1 ? "" : "es")"
        case .comingUp:
            guard tasks > 0 else { return "Nothing due" }
            let overdue = groups.filter { $0.state == "overdue" }.reduce(0) { $0 + $1.hits.count }
            var parts = ["\(tasks) due"]
            if overdue > 0 { parts.append("\(overdue) overdue") }
            return parts.joined(separator: " · ")
        case .leftovers:
            guard tasks > 0 else { return "Nothing left open" }
            let projects = Set(groups.compactMap(\.folder)).count
            var parts = ["\(tasks) task\(tasks == 1 ? "" : "s")",
                         "\(groups.count) sitting\(groups.count == 1 ? "" : "s")"]
            if projects > 1 { parts.append("\(projects) projects") }
            return parts.joined(separator: " · ")
        // Each draws its own summary: a Day counts sittings, and Projects and Time count projects.
        case .day, .projects, .time:
            return ""
        }
    }
}

extension TaskSearchHit {
    /// Which row this is on a view card — `CanvasTaskLists.key`.
    var viewKey: String { CanvasTaskLists.key(self) }
}

// MARK: - What the Projects view draws

/// The pure half of the Projects view (docs/views.md step 7): which projects are moving, and how long
/// each has been left.
enum CanvasProjectRows {
    /// When a project was last worked on, as a person says it: "Today", "Yesterday", "3 days ago",
    /// "5 weeks ago", and past a year the date. "Never" for a project with nothing to go by.
    static func lastWorked(_ summary: ProjectSummary, now: Date = Date(), calendar: Calendar = .current) -> String {
        guard let last = summary.lastActivity.flatMap(DoneLog.date) else { return "Never" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: last),
                                           to: calendar.startOfDay(for: now)).day ?? 0
        switch days {
        case ..<1: return "Today"
        case 1: return "Yesterday"
        case 2..<14: return "\(days) days ago"
        case 14..<60: return "\(days / 7) weeks ago"
        case 60..<365: return "\(days / 30) months ago"
        default:
            let formatter = DateFormatter()
            formatter.dateFormat = "MMM yyyy"
            return formatter.string(from: last)
        }
    }

    /// The line under a project's name: what's open, what's next due.
    static func detail(_ summary: ProjectSummary) -> String {
        var parts = [summary.open == 0 ? "Nothing open" : "\(summary.open) open"]
        if let due = summary.nextDue, let day = SessionPicks.day(iso: String(due.prefix(10))) {
            parts.append("next due \(day)")
        }
        return parts.joined(separator: " · ")
    }

    /// The card's one line.
    static func summary(_ summaries: [ProjectSummary], now: Date = Date()) -> String {
        guard !summaries.isEmpty else { return "No projects" }
        let (moving, quiet) = ViewMarkdown.split(summaries, now: now)
        var parts: [String] = []
        if !moving.isEmpty { parts.append("\(moving.count) moving") }
        if !quiet.isEmpty { parts.append("\(quiet.count) quiet") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - What the Time view draws

/// The pure half of the Time view, so what the card says is testable without a vault.
enum CanvasTimeRows {
    /// The card's one line: the total, and how much of it was worked out rather than recorded. Also
    /// what it says zoomed out, and to VoiceOver.
    static func summary(_ report: TimeSpentReport) -> String {
        let tracked = report.projects.filter { $0.seconds > 0 }
        guard !tracked.isEmpty else { return "No time" }
        var parts = [durationLabel(report.seconds)]
        if tracked.count > 1 { parts.append("\(tracked.count) projects") }
        // "Estimated" on screen for what the contract calls `inferred` (docs/away-time.md).
        let estimated = tracked.filter(\.inferred).count
        if estimated > 0 { parts.append("\(estimated) estimated") }
        return parts.joined(separator: " · ")
    }

    /// The projects with time against them, and the ones that only have something to show for the
    /// period. Kept apart rather than sorted together: a list where half the rows have no number reads
    /// as a broken table, and "you worked here without telling PM" is a different fact from "40m".
    static func split(_ report: TimeSpentReport) -> (tracked: [TimeSpentItem], untracked: [TimeSpentItem]) {
        (report.projects.filter { $0.seconds > 0 },
         report.projects.filter { $0.seconds == 0 && !ViewMarkdown.changes($0).isEmpty })
    }

    /// How wide a project's bar is, as a fraction of the longest one — never of the total.
    ///
    /// **Against the longest, so the top row is always full.** Against the total, a day split evenly
    /// across five projects would draw five stubs and look like a day where nothing happened. The bar
    /// is there to be compared with the row above it, which is the only comparison a reader makes.
    static func share(_ project: TimeSpentItem, of projects: [TimeSpentItem]) -> Double {
        guard let longest = projects.map(\.seconds).max(), longest > 0 else { return 0 }
        return project.seconds / longest
    }
}

// MARK: - Answering for time on a Time card (docs/away-time.md)

/// A stretch of a period someone can answer for: an away nobody's answered, or one span of a
/// project's time. What a Time card's rows select, and what an answer is written against.
enum CanvasTimeStretch: Equatable {
    case away(AttentionAway)
    case span(AttentionSpan)

    /// The row's key for `RowSelection` — stable across the card's polls, since both halves are
    /// written into the log rather than worked out fresh.
    var key: String {
        switch self {
        case .away(let away): return "away|\(away.from)"
        case .span(let span): return "span|\(span.key)|\(span.start)"
        }
    }

    var from: String {
        switch self {
        case .away(let away): return away.from
        case .span(let span): return span.start
        }
    }

    var to: String {
        switch self {
        case .away(let away): return away.to
        case .span(let span): return span.end
        }
    }

    var seconds: Double {
        switch self {
        case .away(let away): return away.seconds
        case .span(let span): return span.seconds
        }
    }

    /// The project it belongs to as things stand: the one an away interrupted, a span's own.
    var project: String {
        switch self {
        case .away(let away): return away.project
        case .span(let span): return span.project
        }
    }

    var isAway: Bool { if case .away = self { return true } else { return false } }
}

/// What the answers menu offers for a selection of stretches.
///
/// **One menu for aways and spans alike**, because both answers are the same event: "this stretch was
/// that project's, or wasn't work". Counting an away fills a gap; counting a span moves it.
struct CanvasTimeAnswers: Equatable {
    /// The project offered first, at the top of the menu: the one every away in the selection
    /// interrupted, when the selection is only aways and they agree. Nil otherwise.
    let suggested: String?
    /// Every project it could be counted for, in the order given, less any it would be a no-op for.
    let projects: [String]
    /// How many stretches the answer is for — what the titles say when it's more than one.
    let count: Int

    /// `candidates` is the card's own projects, in its order; the aways' projects are added to them.
    static func offered(for stretches: [CanvasTimeStretch], candidates: [String]) -> CanvasTimeAnswers {
        var projects: [String] = []
        for folder in candidates + stretches.filter(\.isAway).map(\.project) where !projects.contains(folder) {
            projects.append(folder)
        }
        // A project every selected stretch already is — spans of it, nothing else — has nothing to gain.
        projects.removeAll { folder in
            !stretches.isEmpty && stretches.allSatisfy { !$0.isAway && $0.project == folder }
        }
        let interrupted = Set(stretches.map(\.project))
        let suggested = stretches.allSatisfy(\.isAway) && interrupted.count == 1 ? interrupted.first : nil
        return CanvasTimeAnswers(suggested: suggested.flatMap { projects.contains($0) ? $0 : nil },
                                 projects: projects, count: stretches.count)
    }

    /// "Count for Website", or "Count 3 for Website".
    func countTitle(for title: String) -> String {
        count > 1 ? "Count \(count) for \(title)" : "Count for \(title)"
    }

    /// The submenu of every project.
    var countSubmenuTitle: String { count > 1 ? "Count \(count) For" : "Count For" }

    var notWorkTitle: String { count > 1 ? "Mark \(count) as Not Work" : "Not Work" }

    /// The Edit menu's name for the answer, for ⌘Z.
    static func undoName(notWork: Bool) -> String { notWork ? "Mark Not Work" : "Count Time" }
}
