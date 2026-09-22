import Foundation

// MARK: - Where the time went, per project
//
// `task.done` answers "what got finished" and `session.list` answers "what did I sit down to". This
// answers "where did the day go": every project that had your attention in a span, how long it had it,
// and what came of that time. See docs/time-tracking.md D5.
//
// **Nothing new is read.** The spans come from the attention log and the rest is `sessionList`, over
// the same range — which already sweeps each project's done log and resolves its picks. A number on
// its own is a timesheet; a number with what came of it is a record of a day, and the second costs
// nothing once the first has been asked for.
//
// A project with changes but no time on record is still listed, with no time against it. That is worth
// saying rather than hiding: it means work happened somewhere PM was never told you were.

/// One project's share of a period.
public struct TimeSpentItem: Codable, Equatable, Sendable {
    public let projectFolder: String
    public let projectName: String
    public let isArchived: Bool
    /// The project's `pm-color` and `pm-icon`, for the chip a view draws. Nil when it has none.
    public var projectColor: String? = nil
    public var projectIcon: String? = nil
    /// How long it had your attention in the period. Zero for a project that only shows changes.
    public var seconds: Double = 0
    /// The spans that add up to it, oldest first.
    public var spans: [AttentionSpan] = []
    /// Any span whose end was worked out rather than recorded (D4). A report marks these; it doesn't
    /// leave them out, and it doesn't quietly total them as if they were measured.
    public var inferred: Bool = false
    /// What came of the period, from the same read `session.list` does.
    public var sittings: Int = 0
    public var done: Int = 0
    public var dropped: Int = 0
    public var picked: Int = 0

    public init(projectFolder: String, projectName: String, isArchived: Bool) {
        self.projectFolder = projectFolder
        self.projectName = projectName
        self.isArchived = isArchived
    }
}

/// A period's time, longest first.
public struct TimeSpentReport: Codable, Equatable, Sendable {
    /// Every project's seconds added up.
    public var seconds: Double = 0
    public var projects: [TimeSpentItem] = []

    public init(seconds: Double = 0, projects: [TimeSpentItem] = []) {
        self.seconds = seconds
        self.projects = projects
    }
}

/// How long, as a report says it: `2h 10m`, `40m`, `<1m`.
///
/// Minutes, never seconds. The measurement is a stretch of attention bounded by a ten-minute pause,
/// and a seconds figure on it would claim a precision the thing being measured doesn't have.
public func durationLabel(_ seconds: Double) -> String {
    let minutes = Int((seconds / 60).rounded())
    if minutes < 1 { return "<1m" }
    if minutes < 60 { return "\(minutes)m" }
    let (hours, rest) = (minutes / 60, minutes % 60)
    return rest == 0 ? "\(hours)h" : "\(hours)h \(rest)m"
}

/// The spans and the period's changes, added up per project — pure, so what counts is testable
/// without a vault.
///
/// `folders` names each project that should appear even with no time against it, mapped to what a
/// report prints it as.
func tallying(spans: [AttentionSpan], sittings: SittingList,
              named folders: [String: (name: String, archived: Bool)]) -> TimeSpentReport {
    var items: [String: TimeSpentItem] = [:]

    func item(_ folder: String, archived: Bool = false) -> TimeSpentItem {
        items[folder] ?? TimeSpentItem(projectFolder: folder,
                                       projectName: folders[folder]?.name
                                           ?? projectTitle(fromFolderName: folder),
                                       isArchived: folders[folder]?.archived ?? archived)
    }

    for span in spans {
        var out = item(span.project)
        out.seconds += span.seconds
        out.spans.append(span)
        out.inferred = out.inferred || span.basis == .inferred
        items[span.project] = out
    }
    for sitting in sittings.sittings {
        var out = item(sitting.projectFolder, archived: sitting.isArchived)
        out.sittings += 1
        out.done += sitting.finished.count
        out.dropped += sitting.dropped.count
        out.picked += sitting.picked.count
        out.projectColor = out.projectColor ?? sitting.projectColor
        out.projectIcon = out.projectIcon ?? sitting.projectIcon
        items[sitting.projectFolder] = out
    }
    // A tick from the menubar in a project you never sat down to is still something that got done in
    // the period, and `session.list` hands it over separately for exactly that reason.
    for stray in sittings.elsewhere {
        var out = item(stray.projectFolder, archived: stray.isArchived)
        if stray.dropped { out.dropped += 1 } else { out.done += 1 }
        items[stray.projectFolder] = out
    }

    // Longest first: the question is where the time went, and the answer starts with where most of it
    // went. Projects with no time fall to the end, in name order, rather than in dictionary order.
    let projects = items.values.sorted {
        $0.seconds != $1.seconds ? $0.seconds > $1.seconds : $0.projectName < $1.projectName
    }
    return TimeSpentReport(seconds: projects.reduce(0) { $0 + $1.seconds }, projects: projects)
}

/// Every span in `range`, clipped to it and cut at midnight — the attention log, closed against the
/// evidence in the other three (docs/time-tracking.md D4).
///
/// `now` bounds the span still running, so a read of a past day doesn't grow every time anybody asks
/// for it.
public func attentionSpans(in range: DoneRange, projects: [String]? = nil, now: Date = Date(),
                           calendar: Calendar = .current) throws -> [AttentionSpan] {
    let only = try projects.map(projectFolders(named:))
    let events = AttentionLog.events().filter { only == nil || only!.contains($0.project) }

    // Only the projects the log actually mentions are looked up — never every project in the vault.
    // Every mentioned one, though, and not only those with a span in the range: a span that began
    // yesterday evening runs into this morning, so the events outside the range are what place the
    // ones inside it.
    let (config, paths) = try loadConfigAndPaths(skipPathValidation: true)
    let codes = Array(config.domains.keys)
    var projectPaths: [String: String] = [:]
    let mentioned = Set(events.map(\.project))
    for scope in ProjectScope.allCases {
        let base = scope.path(in: paths)
        for folder in (try? getFolders(basePath: base, scope: scope, domainCodes: codes)) ?? [] {
            guard mentioned.contains(folder), projectPaths[folder] == nil else { continue }
            projectPaths[folder] = (base as NSString).appendingPathComponent(folder)
        }
    }

    // The journal is read once and handed to every project, rather than re-read per project — it's one
    // file covering all of them, and `SessionTimes.evidence` would otherwise parse it again each time.
    let journal = ApiJournal.entries(limit: 0)
    var evidence: [String: [Date]] = [:]
    for (folder, path) in projectPaths {
        evidence[folder] = SessionTimes.evidence(projectPath: path, journal: journal).map(\.at)
    }

    let horizon = min(now, range.end)
    let spans = AttentionLog.splittingAtMidnight(
        AttentionLog.spans(from: events, evidence: evidence, now: horizon), calendar: calendar)
    return AttentionLog.clipped(spans, to: range)
}

/// Where the time went in `range`, across every project.
public func timeSpent(in range: DoneRange, projects: [String]? = nil, now: Date = Date(),
                      calendar: Calendar = .current) throws -> TimeSpentReport {
    // The sittings first, and the spans after: `sessionList` sweeps each project's done log, so a tick
    // made in Obsidian an hour ago is on record *before* the spans go looking for evidence to close
    // themselves against. The other way round it would only count from the next report on.
    let sittings = try sessionList(in: range, projects: projects, now: now)
    let spans = try attentionSpans(in: range, projects: projects, now: now, calendar: calendar)

    // Each project the spans name, as a report prints it. Only the ones with time against them need
    // looking up; the rest arrive named by `sessionList`.
    let (config, paths) = try loadConfigAndPaths(skipPathValidation: true)
    let codes = Array(config.domains.keys)
    let mentioned = Set(spans.map(\.project))
    var folders: [String: (name: String, archived: Bool)] = [:]
    for scope in ProjectScope.allCases {
        let base = scope.path(in: paths)
        for folder in (try? getFolders(basePath: base, scope: scope, domainCodes: codes)) ?? [] {
            guard mentioned.contains(folder), folders[folder] == nil else { continue }
            folders[folder] = (projectTitle(fromFolderName: folder), scope.isArchived)
        }
    }

    return tallying(spans: spans, sittings: sittings, named: folders)
}

/// The sittings with each one's duration filled in (D6): the attention spans of its project that
/// began while it was the current one.
///
/// **Never wall-clock from one heading to the next.** A sitting at 9:00 and the next at 14:00 is not a
/// five-hour sitting; four of those hours were spent in other projects, or not at the desk at all. A
/// sitting is worth the attention that was actually on it.
///
/// The rule for which sitting a span belongs to is the one completions already follow: the latest
/// sitting of that project that had begun by the moment it started.
public func withDurations(_ list: SittingList, spans: [AttentionSpan]) -> SittingList {
    var out = list
    // Each project's sittings, newest first, with the moment each began.
    var starts: [String: [(index: Int, at: Date)]] = [:]
    for (index, sitting) in out.sittings.enumerated() {
        guard let at = sitting.startedAt.flatMap(DoneLog.date) else { continue }
        starts[sitting.projectFolder, default: []].append((index, at))
    }
    for key in starts.keys { starts[key]?.sort { $0.at > $1.at } }

    var seconds: [Int: Double] = [:]
    for span in spans {
        guard let start = span.startDate,
              // Newest first, so the first that had begun by then is the latest that had.
              let home = starts[span.project]?.first(where: { $0.at <= start }) else { continue }
        seconds[home.index, default: 0] += span.seconds
    }
    for (index, total) in seconds { out.sittings[index].seconds = total }
    return out
}
