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
        case .leftovers:
            guard tasks > 0 else { return "Nothing left open" }
            let projects = Set(groups.compactMap(\.folder)).count
            var parts = ["\(tasks) task\(tasks == 1 ? "" : "s")",
                         "\(groups.count) sitting\(groups.count == 1 ? "" : "s")"]
            if projects > 1 { parts.append("\(projects) projects") }
            return parts.joined(separator: " · ")
        case .day:
            return ""
        }
    }
}

extension TaskSearchHit {
    /// Which row this is on a view card — `CanvasTaskLists.key`.
    var viewKey: String { CanvasTaskLists.key(self) }
}
