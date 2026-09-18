import Foundation
import PmLib

// MARK: - What a task-list view draws

/// One group on a view that lists tasks: a Waiting target and everything waiting on it, or a search's
/// one ranked list.
struct CanvasTaskGroup: Equatable, Identifiable {
    let id: String
    /// The heading, or nil for a list that has none (a search is one list, best first).
    let title: String?
    /// A Waiting group's resolution: `released`, `pending` or `unresolved`.
    let state: String?
    /// The project a Waiting target names, when it names one — a heading you can go to.
    let folder: String?
    let hits: [TaskSearchHit]
}

/// The pure half of the Waiting and Search views (docs/views.md step 5): from the contract's answer to
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

    /// A hit as a view's row: what `CanvasViewRow` draws and `CanvasDayActions` acts on. Unique within
    /// its project, which is as far as a selection reaches.
    static func row(_ hit: TaskSearchHit) -> CanvasDayRow {
        CanvasDayRow(id: rowID(hit), text: hit.text, state: .open, depth: 0, origin: nil, pickedUp: false,
                     ref: hit.ref, declaresWait: hit.waiting != nil)
    }

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
        case .day:
            return ""
        }
    }
}

extension TaskSearchHit {
    /// Which row this is on a view card — `CanvasTaskLists.key`.
    var viewKey: String { CanvasTaskLists.key(self) }
}
