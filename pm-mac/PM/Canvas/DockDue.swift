import Foundation
import PmLib

/// Which projects the dock brings forward for tasks coming due, and how urgent each is.
///
/// - The window is a global setting (`horizonKey`): days ahead of today, or off.
/// - Overdue and today count at every window; a project with an open task due in the window qualifies.
/// - Archived projects never do.
/// - Earliest due first; ties by name.
enum DockDue {
    static let horizonKey = "PMDockDueHorizon"
    static let off = -1
    static let defaultHorizon = 2
    /// The setting's choices, in days past today.
    static let choices = [0, 1, 2, 7]

    static var horizon: Int {
        UserDefaults.standard.object(forKey: horizonKey) as? Int ?? defaultHorizon
    }

    enum Level: Equatable { case overdue, today, soon }

    /// How due `raw` is, or nil if it falls past the window (or can't be read, or the window is off).
    static func level(_ raw: String?, horizon: Int, now: Date = Date()) -> Level? {
        guard horizon != off, let raw, let delta = RelativeDue.dayDelta(raw, now: now), delta <= horizon else { return nil }
        // A time today that has passed is overdue, as a task's own badge says.
        if delta < 0 || (delta == 0 && RelativeDue.carriesTime(raw) && RelativeDue.isOverdue(raw, now: now)) { return .overdue }
        return delta == 0 ? .today : .soon
    }

    struct Candidate: Equatable {
        var projectKey: String
        var name: String
        var nextDue: String?
        var isArchived: Bool
    }

    /// The projects due within the window, earliest first.
    static func due(_ candidates: [Candidate], horizon: Int, now: Date = Date()) -> [Candidate] {
        candidates
            .filter { !$0.isArchived && level($0.nextDue, horizon: horizon, now: now) != nil }
            .sorted {
                let a = $0.nextDue.flatMap(RelativeDue.parse) ?? .distantFuture
                let b = $1.nextDue.flatMap(RelativeDue.parse) ?? .distantFuture
                return a != b ? a < b : $0.name < $1.name
            }
    }

    /// One project's open tasks due within the window, earliest first, as (due, text).
    static func tasks(_ tasks: [(due: String?, text: String)], horizon: Int, now: Date = Date()) -> [(due: String, text: String)] {
        tasks.compactMap { task in
            guard let due = task.due, level(due, horizon: horizon, now: now) != nil else { return nil }
            return (due, task.text)
        }
        .sorted { (RelativeDue.parse($0.due) ?? .distantFuture) < (RelativeDue.parse($1.due) ?? .distantFuture) }
    }
}
