import Foundation

// MARK: - What's coming up
//
// `task.whatsDue` answers for one project, as `Todo`s. This is the same question across projects — the
// deadline horizon (docs/views.md D1, Coming up) — so each task carries its project, the way every
// other cross-project list does (`TaskSearchHit`).
//
// **A line's own date.** A subtask under a dated task inherits its date (`effectiveDueDate`), and
// listing the task and all five of its steps as five things due Friday would be one deadline said six
// times. A line is listed when it says a date itself; what's under it comes with it on the project card.
//
// **Overdue is always in.** A horizon that forgot yesterday's deadline because it's past would be the
// wrong way round.

/// The end of the horizon `until` names, exclusive: a task due before this is in.
///
/// `today` is the end of today. `week` is the next seven days, today included, and `month` five rolling
/// weeks from the start of this one — a horizon rolls, where a report's week or month is the calendar's,
/// because what's due on the 2nd matters on the 30th. A date is the end of that day. Absent is `week`.
public func dueCutoff(until: String?, now: Date = Date(), calendar: Calendar = .current) throws -> Date {
    let today = calendar.startOfDay(for: now)
    switch until?.trimmingCharacters(in: .whitespaces).lowercased() {
    case "today":
        return calendar.date(byAdding: .day, value: 1, to: today) ?? today
    case nil, "", "week":
        return calendar.date(byAdding: .day, value: 7, to: today) ?? today
    case "month":
        let start = calendar.dateInterval(of: .weekOfYear, for: today)?.start ?? today
        return calendar.date(byAdding: .day, value: 35, to: start) ?? start
    case let date?:
        let day = try DoneRange.localDay(date, calendar: calendar)
        return calendar.date(byAdding: .day, value: 1, to: day) ?? day
    }
}

/// `hits` due before `cutoff`, soonest first: each line that says a date itself, overdue included. Ties
/// by project, then as the file has them. Pure, so the rules are testable without a vault.
func dueHits(_ tasks: [(hit: TaskSearchHit, todo: Todo)], before cutoff: Date,
             calendar: Calendar = .current) -> [TaskSearchHit] {
    let due = tasks.enumerated().compactMap { index, task -> (hit: TaskSearchHit, day: String, index: Int)? in
        guard let own = task.todo.dueDate else { return nil }
        let day = String(own.prefix(10))
        guard let date = try? DoneRange.localDay(day, calendar: calendar), date < cutoff else { return nil }
        let hit = task.hit
        // The line's own date, not the one it would inherit.
        return (TaskSearchHit(projectFolder: hit.projectFolder, projectName: hit.projectName,
                              projectKey: hit.projectKey, isArchived: hit.isArchived, text: hit.text, due: own,
                              waiting: hit.waiting, effectiveWaiting: hit.effectiveWaiting,
                              isFocused: hit.isFocused, session: hit.session,
                              sessionOrdinal: hit.sessionOrdinal, line: hit.line, digest: hit.digest,
                              projectColor: hit.projectColor, projectIcon: hit.projectIcon), day, index)
    }
    return due.sorted { a, b in
        if a.day != b.day { return a.day < b.day }
        if a.hit.projectName != b.hit.projectName {
            return a.hit.projectName.localizedCaseInsensitiveCompare(b.hit.projectName) == .orderedAscending
        }
        return a.index < b.index
    }
    .map(\.hit)
}

/// Open tasks due by `until`, across projects, soonest first — overdue first of all.
///
/// `projects` narrows it the way every query reads the field. Absent, it's the projects and areas in
/// hand: an archived project's deadlines were put down with it.
public func dueTasks(until: String? = nil, projects: [String]? = nil, now: Date = Date(),
                     calendar: Calendar = .current) throws -> [TaskSearchHit] {
    let cutoff = try dueCutoff(until: until, now: now, calendar: calendar)
    let tasks = try openTasks(includeArchived: projects != nil, includeActive: true, projects: projects)
    return dueHits(tasks, before: cutoff, calendar: calendar)
}

/// A local day as a due date and a sitting's heading write it, `YYYY-MM-DD`.
public func isoDay(_ date: Date, calendar: Calendar = .current) -> String {
    let parts = calendar.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
}
