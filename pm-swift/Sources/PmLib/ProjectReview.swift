import Foundation

// MARK: - Reviewing a project
//
// A project goes creaky without anything being wrong with it on any one day: tasks age past three weeks,
// a due date slips by, the summary stops describing what the work has become, a wait outlives the project
// it was waiting on. A review is a sitting you sit down to on purpose to put that right: what happened
// since last time, is the brief still true, what's still meant, and what you think now. See
// docs/project-review.md.
//
// **A review is a sitting.** It's a sitting named "Review", started like any other, so the prose you write
// is its note, the old tasks you pick up are drawn under it, its time is counted, and Day shows it. That's
// also how "last reviewed" is known: it's the newest sitting with that name. Nothing new is stored.
//
// **Creaky is read, not stored.** Everything `ProjectHealth` reports is already on disk — the notes, the
// pick log's picks and keeps, the done log — so a surface can ask on every draw and nothing has to be kept
// in step with anything.

/// The name a review sitting is given, and the name that marks a sitting as one.
public let reviewSessionName = "Review"

/// How long a project can go between sittings before it counts as gone quiet, for a review: as long as a
/// task takes to go stale, so the two kinds of neglect are measured in the same weeks.
public let reviewQuietAfter: TimeInterval = taskStaleAfter

public enum ProjectReview {
    /// Whether `session` is a review: its name is "Review", or begins with it ("Review · Q4"), in any case.
    /// A sitting merely mentioning a review in its note isn't one; only the name counts.
    public static func isReview(_ session: Session) -> Bool {
        let name = session.name.lowercased()
        let word = reviewSessionName.lowercased()
        guard name.hasPrefix(word) else { return false }
        let rest = name.dropFirst(word.count)
        return rest.isEmpty || !(rest.first?.isLetter ?? false)
    }

    /// The local day a sitting's heading names, or nil for a heading PM can't date.
    public static func day(of session: Session, calendar: Calendar = .current) -> Date? {
        guard let iso = sessionISODate(heading: session.date) else { return nil }
        return try? DoneRange.localDay(iso, calendar: calendar)
    }

    /// The newest review sitting, by its index in `notes.sessions` (newest first), or nil if the project
    /// has never had one. An empty review sitting isn't counted. `after` skips the sittings up to and including that index: the review in
    /// progress, when what's wanted is the one before it.
    public static func lastReviewIndex(in notes: ProjectNotes, after current: Int? = nil) -> Int? {
        let start = current.map { $0 + 1 } ?? 0
        guard start < notes.sessions.count else { return nil }
        return notes.sessions[start...].firstIndex { isReview($0) && !isEmpty($0) }
    }

    /// A heading with nothing under it: a review that was opened and left without a word written, which
    /// doesn't count as having been reviewed.
    static func isEmpty(_ session: Session) -> Bool {
        session.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The day of the newest review, or nil if there's never been one.
    public static func lastReviewed(_ notes: ProjectNotes, calendar: Calendar = .current) -> Date? {
        lastReviewIndex(in: notes).flatMap { day(of: notes.sessions[$0], calendar: calendar) }
    }

    /// The sittings since the last review, newest first, by index: those after it, or those within three
    /// weeks for a project never reviewed. Review sittings themselves aren't in it. `current` is the review
    /// in progress, so "the last review" means the one before it.
    public static func sittingsSince(_ notes: ProjectNotes, current: Int? = nil, now: Date = Date(),
                                     calendar: Calendar = .current) -> [Int] {
        if let last = lastReviewIndex(in: notes, after: current) {
            return Array(0..<last).filter { !isReview(notes.sessions[$0]) }
        }
        let since = calendar.startOfDay(for: now.addingTimeInterval(-taskStaleAfter))
        return notes.sessions.indices.filter { i in
            !isReview(notes.sessions[i]) && (day(of: notes.sessions[i], calendar: calendar).map { $0 >= since } ?? false)
        }
    }
}

/// What a review would find in a project right now: the reasons it's creaky, each one a count of a thing
/// a review step can put right.
public struct ProjectHealth: Equatable, Sendable {
    /// Trees untouched for three weeks (`TaskStaleness`).
    public var staleTrees: Int
    /// Open tasks whose own date has gone by. A subtask that only inherits its parent's date isn't counted
    /// again: redating the parent answers it.
    public var overdue: Int
    /// Open tasks waiting on a project or area that's since been archived: what they waited for landed.
    public var releasedWaits: Int
    /// The focused task, when it's gone untouched for three weeks: the thing you said you're on, and aren't.
    public var focusGoneQuiet: Bool
    /// The brief's slots that are empty, by name: "Summary", "Problem", "Goals", "Approach". An area is
    /// only asked for a Summary and Goals, which is all its template has.
    public var emptyBrief: [String]
    /// Whole days since the newest sitting began, or nil for a project that's never had a dated one.
    public var daysSinceLastSitting: Int?
    /// Whole days since the last review, or nil for one never reviewed.
    public var daysSinceReview: Int?

    public init(staleTrees: Int = 0, overdue: Int = 0, releasedWaits: Int = 0, focusGoneQuiet: Bool = false,
                emptyBrief: [String] = [], daysSinceLastSitting: Int? = nil, daysSinceReview: Int? = nil) {
        self.staleTrees = staleTrees
        self.overdue = overdue
        self.releasedWaits = releasedWaits
        self.focusGoneQuiet = focusGoneQuiet
        self.emptyBrief = emptyBrief
        self.daysSinceLastSitting = daysSinceLastSitting
        self.daysSinceReview = daysSinceReview
    }

    /// Read a project's health from what a notes read already carries.
    ///
    /// - `todos`: the read's tasks, with `picked` and `kept` filled in, as a store holds them.
    /// - `isReleased`: whether a wait target names something archived — the store's `waitTargets`. A
    ///   surface that hasn't resolved waits passes nothing, and no wait counts.
    public init(notes: ProjectNotes, todos: [Todo], kind: ProjectKind = .project,
                isReleased: (String) -> Bool = { _ in false },
                now: Date = Date(), calendar: Calendar = .current) {
        staleTrees = TaskStaleness.staleRoots(in: todos, now: now, calendar: calendar).count
        overdue = todos.filter { todo in
            todo.state == .open && todo.dueDate.map { RelativeDue.isOverdue($0, now: now) } == true
        }.count
        releasedWaits = todos.filter { $0.state == .open && $0.waiting.map(isReleased) == true }.count
        focusGoneQuiet = todos.first(where: { $0.isFocused && $0.state == .open }).flatMap {
            TaskStaleness.lastTouched($0, calendar: calendar)
        }.map { now.timeIntervalSince($0) > taskStaleAfter } ?? false

        var empty: [String] = []
        func blank(_ s: String) -> Bool { s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if blank(notes.summary) { empty.append("Summary") }
        if kind == .project, blank(notes.problem) { empty.append("Problem") }
        if notes.goals.allSatisfy(blank) { empty.append("Goals") }
        if kind == .project, blank(notes.approach) { empty.append("Approach") }
        emptyBrief = empty

        func days(since day: Date?) -> Int? {
            day.flatMap { calendar.dateComponents([.day], from: $0, to: calendar.startOfDay(for: now)).day }
        }
        let newestDated = notes.sessions.lazy.compactMap { ProjectReview.day(of: $0, calendar: calendar) }.first
        daysSinceLastSitting = days(since: newestDated)
        daysSinceReview = days(since: ProjectReview.lastReviewed(notes, calendar: calendar))
    }

    /// Whether the project has gone quiet: no sitting for three weeks.
    public var hasGoneQuiet: Bool {
        (daysSinceLastSitting ?? 0) >= Int(reviewQuietAfter / 86_400)
    }

    /// Whether a review has anything to put right. An empty brief on its own doesn't count: plenty of
    /// small projects never fill one in, and nagging about it would make the list noise.
    public var isCreaky: Bool {
        staleTrees > 0 || overdue > 0 || releasedWaits > 0 || focusGoneQuiet || hasGoneQuiet
    }

    /// How creaky, for putting the creakiest first in a queue of reviews. Overdue work weighs most, since
    /// it's the one that's already cost something; then a wait that's released, which is a free win; then
    /// stale work and silence.
    public var score: Int {
        overdue * 4 + releasedWaits * 3 + staleTrees * 2 + (focusGoneQuiet ? 3 : 0)
            + (hasGoneQuiet ? 2 + min((daysSinceLastSitting ?? 0) / 7, 8) : 0)
    }

    /// The reasons, worst first, in the words a queue row shows: "2 overdue", "12 stale tasks", "no
    /// sitting for 5 weeks". Empty when the project is fine.
    public var reasons: [String] {
        var out: [String] = []
        if overdue > 0 { out.append("\(overdue) overdue") }
        if releasedWaits > 0 { out.append("\(releasedWaits) \(releasedWaits == 1 ? "wait" : "waits") released") }
        if staleTrees > 0 { out.append("\(staleTrees) stale \(staleTrees == 1 ? "task" : "tasks")") }
        if focusGoneQuiet { out.append("focus untouched for 3+ weeks") }
        if hasGoneQuiet, let d = daysSinceLastSitting { out.append("no sitting for \(Self.span(days: d))") }
        return out
    }

    /// "5 weeks", "2 months", for a count of days at least three weeks long.
    static func span(days: Int) -> String {
        if days >= 60 { return "\(days / 30) months" }
        return "\(max(days / 7, 1)) weeks"
    }
}
