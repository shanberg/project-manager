import Foundation

// MARK: - A day across projects
//
// `task.done` answers "what got finished". This answers "what did I sit down to, and what came of it":
// every sitting dated in a span, across projects, in the order the day went, each with its prose and
// its tasks. It's the read behind the Day and Week views (docs/views.md D5, D8).
//
// Nothing new is stored. The order comes from the time each heading carries (D4), and the rest is joined
// from the two logs PM already keeps. The pick log says which sitting a task was picked up into, by
// name. The done log says only *when* a task was finished, so a completion is given to a sitting by
// time: the latest one in its project that had begun by then, that day. One that falls in no sitting
// (a tick from the menubar in a project you never sat down to) is listed on its own, as `elsewhere`.

/// One task as a sitting shows it.
public struct SittingTask: Codable, Equatable {
    public let text: String
    /// `open`, `done` or `dropped`, as the line reads now.
    public let state: String
    /// Indent within its tree, 0 for a top-level task.
    public let depth: Int
    /// Where the line is now, to act on it. Nil for a finished task whose line has since been deleted:
    /// tidying finished work away doesn't unfinish it.
    public let ref: TaskRefInput?
    /// For a picked-up task, the ISO date of the sitting it was written in.
    public let from: String?
    /// For a finished or dropped task, when that happened; for a picked-up one, when it was picked up.
    /// ISO 8601, UTC.
    public let at: String?
}

/// One sitting, with everything that happened in it.
public struct SittingEntry: Codable, Equatable {
    public let projectFolder: String
    public let projectName: String
    public let isArchived: Bool
    /// The project's `pm-color` and `pm-icon`, as its frontmatter writes them, for the chip a view draws
    /// beside every sitting. Nil when it has none.
    public var projectColor: String? = nil
    public var projectIcon: String? = nil
    /// The sitting as a `SessionRef` names it: its ISO date, which of that date's sittings (0 is the
    /// newest), and the digest of its label.
    public let session: String
    public let sessionOrdinal: Int
    public let sessionDigest: String
    /// When it began, as its heading says (`9:10 AM`). Nil for a sitting started before headings kept
    /// the time; a view draws those under one "Earlier" mark.
    public let startTime: String?
    /// The same moment as ISO 8601 in UTC, for sorting and arithmetic.
    public let startedAt: String?
    /// What someone named it, or empty.
    public let name: String
    /// The sitting's writing with its task lines taken out, whitespace-trimmed.
    public let prose: String
    /// Tasks written in it, in document order, whatever their state.
    public let written: [SittingTask]
    /// Whole trees picked up into it from older sittings.
    public let picked: [SittingTask]
    /// Tasks finished while it was going on, wherever they were written. A task written here and
    /// finished here is listed in both `written` and `finished`.
    public let finished: [SittingTask]
    /// Tasks dropped while it was going on, the same way.
    public let dropped: [SittingTask]
    /// The project's newest sitting, written into within the idle window: still going.
    public let isCurrent: Bool
}

/// A span's sittings, newest day first and in time order within a day, and the completions that fell
/// in none of them.
public struct SittingList: Codable, Equatable {
    public var sittings: [SittingEntry]
    /// Completions and drops in the span that no sitting owns, in time order.
    public var elsewhere: [DoneItem]

    public init(sittings: [SittingEntry] = [], elsewhere: [DoneItem] = []) {
        self.sittings = sittings
        self.elsewhere = elsewhere
    }
}

/// One project's part of the answer, from one read of it.
///
/// Pure, so every rule about which sitting owns what is testable without a vault. `doneEvents` are the
/// standing ones (`DoneLog.standing`); `picks` are resolved against the same read as `notes`.
func sittings(projectFolder: String, isArchived: Bool = false, notes: ProjectNotes, todos: [Todo],
              picks: [PickLog.Resolved], doneEvents: [DoneEvent], in range: DoneRange,
              notesModified: Date? = nil, now: Date = Date(),
              calendar: Calendar = .current) -> SittingList {
    let projectName = projectTitle(fromFolderName: projectFolder)

    // Every dated sitting, not only those in range: a completion just after midnight can belong to the
    // evening before, and a completion's owner has to be found before it can be left out.
    struct Dated {
        let index: Int
        let iso: String
        let day: Date
        let start: Date?
    }
    let dated: [Dated] = notes.sessions.enumerated().compactMap { index, session in
        guard let iso = sessionISODate(heading: session.date),
              let day = try? DoneRange.localDay(iso, calendar: calendar) else { return nil }
        return Dated(index: index, iso: iso, day: day,
                     start: session.startTime.flatMap { clockTime($0, on: day, calendar: calendar) })
    }

    /// The sitting of `day` that had begun by `moment`: the latest timed one that started before it,
    /// else an untimed one (which began at some earlier point nobody wrote down). Sessions are newest
    /// first in the file, so the first untimed one of the day is the latest of them.
    func owner(on day: Date, at moment: Date) -> Dated? {
        let ofDay = dated.filter { $0.day == day }
        if let timed = ofDay.filter({ ($0.start ?? .distantFuture) <= moment })
            .max(by: { $0.start! < $1.start! }) {
            return timed
        }
        return ofDay.first { $0.start == nil }
    }

    // Completions and drops, oldest first, each given to a sitting or to nobody. In time order so that
    // "the sitting's last completion" (the midnight rule) is known by the time the next one is placed.
    var owned: [Int: [DoneEvent]] = [:]
    var lastSeen: [Int: Date] = [:]
    var elsewhere: [DoneItem] = []
    // From the day before the span, so an evening's last tick is known when the first minutes of the
    // span are placed; to an idle window past its end, for the evening at the end of the span.
    let earliest = calendar.date(byAdding: .day, value: -1, to: range.start) ?? range.start
    let latest = range.end.addingTimeInterval(sessionIdleWindow)
    let timed = doneEvents.compactMap { event in DoneLog.date(event.at).map { (event, $0) } }
        .filter { $0.1 >= earliest && $0.1 < latest }
        .sorted { $0.1 < $1.1 }
    for (event, moment) in timed {
        let day = calendar.startOfDay(for: moment)
        var home = owner(on: day, at: moment)
        // Past midnight: the evening's sitting still owns it if the last thing that happened in it was
        // within the idle window. The heading is dated the day before, and so is the work.
        if home == nil, let yesterday = calendar.date(byAdding: .day, value: -1, to: day),
           let evening = owner(on: yesterday, at: moment),
           let seen = [lastSeen[evening.index], evening.start].compactMap({ $0 }).max(),
           moment.timeIntervalSince(seen) <= sessionIdleWindow {
            home = evening
        }
        if let home {
            owned[home.index, default: []].append(event)
            lastSeen[home.index] = moment
        } else if range.contains(moment) {
            elsewhere.append(DoneItem(projectFolder: projectFolder, projectName: projectName,
                                      isArchived: isArchived, at: event.at, text: event.text,
                                      session: event.session, dropped: event.event == .dropped))
        }
    }

    func row(_ todo: Todo, from: String? = nil, at: String? = nil) -> SittingTask {
        SittingTask(text: todo.text, state: todo.state.name, depth: todo.depth,
                    ref: PickLog.task(todo, in: notes).map {
                        TaskRefInput(session: $0.session, sessionOrdinal: $0.ordinal, line: $0.line,
                                     digest: $0.digest)
                    },
                    from: from, at: at)
    }

    var out: [SittingEntry] = []
    for sitting in dated where range.contains(sitting.day) {
        let session = notes.sessions[sitting.index]
        let ref = SessionRef(session: session, at: sitting.index, in: notes)

        let written = todos.filter { $0.sessionIndex == sitting.index }.map { row($0) }

        // A pick names a tree (docs/sessions.md D3), and two picks inside one tree draw it once.
        var picked: [SittingTask] = []
        var roots = Set<String>()
        for pick in picks where pick.intoIndex == sitting.index {
            guard let named = todos.first(where: {
                $0.sessionIndex == pick.sessionIndex && $0.lineIndex == pick.lineIndex
            }) else { continue }
            let root = TaskTree.root(of: named, in: todos)
            guard roots.insert("\(root.sessionIndex):\(root.lineIndex)").inserted else { continue }
            let members = TaskTree.members(of: root, in: todos)
            picked += members.map { row($0, from: $0.sessionISODate, at: pick.event.at) }
        }

        func closed(_ kind: DoneEvent.Kind) -> [SittingTask] {
            (owned[sitting.index] ?? []).filter { $0.event == kind }.map { event in
                let state: TaskState = kind == .dropped ? .dropped : .done
                // The line as it is now, when it's still there: the one of this text in the state the
                // event left it in, preferring this sitting's own.
                let line = todos.filter { ($0.digest ?? taskDigest($0.text)) == event.digest && $0.state == state }
                    .min { ($0.sessionIndex == sitting.index ? 0 : 1) < ($1.sessionIndex == sitting.index ? 0 : 1) }
                if let line { return row(line, at: event.at) }
                return SittingTask(text: event.text, state: state.name, depth: 0, ref: nil, from: nil,
                                   at: event.at)
            }
        }

        let isCurrent = sitting.index == 0
            && notesModified.map { now.timeIntervalSince($0) <= sessionIdleWindow } == true
        out.append(SittingEntry(
            projectFolder: projectFolder, projectName: projectName, isArchived: isArchived,
            session: sitting.iso, sessionOrdinal: ref.ordinal, sessionDigest: ref.digest ?? "",
            startTime: session.startTime, startedAt: sitting.start.map(DoneLog.timestamp),
            name: session.name, prose: sittingProse(session.body),
            written: written, picked: picked,
            finished: closed(.completed), dropped: closed(.dropped), isCurrent: isCurrent))
    }
    return SittingList(sittings: out, elsewhere: elsewhere)
}

extension SittingList {
    /// Several projects' answers as one: newest day first; within a day, the untimed sittings first
    /// (they're "Earlier") by project, then the rest by when they began.
    func merged(with other: SittingList) -> SittingList {
        SittingList(sittings: sittings + other.sittings, elsewhere: elsewhere + other.elsewhere)
    }

    func sorted() -> SittingList {
        let sittings = self.sittings.sorted { a, b in
            if a.session != b.session { return a.session > b.session }
            switch (a.startedAt, b.startedAt) {
            case (nil, .some): return true
            case (.some, nil): return false
            case let (x?, y?) where x != y: return x < y
            default:
                if a.projectName != b.projectName {
                    return a.projectName.localizedCaseInsensitiveCompare(b.projectName) == .orderedAscending
                }
                // Older first, and in a file the older sitting of a day has the higher ordinal.
                return a.sessionOrdinal > b.sessionOrdinal
            }
        }
        let elsewhere = self.elsewhere.sorted { a, b in
            let (x, y) = (DoneLog.date(a.at) ?? .distantPast, DoneLog.date(b.at) ?? .distantPast)
            let (dx, dy) = (Calendar.current.startOfDay(for: x), Calendar.current.startOfDay(for: y))
            return dx != dy ? dx > dy : x < y
        }
        return SittingList(sittings: sittings, elsewhere: elsewhere)
    }
}

/// A heading's `9:10 AM` on a local day, or nil if it doesn't read as one.
func clockTime(_ time: String, on day: Date, calendar: Calendar = .current) -> Date? {
    let reader = DateFormatter()
    reader.locale = Locale(identifier: "en_US_POSIX")
    reader.timeZone = calendar.timeZone
    reader.dateFormat = "h:mm a"
    let compact = time.replacingOccurrences(of: #"\s*([AaPp][Mm])$"#, with: " $1", options: .regularExpression)
    guard let clock = reader.date(from: compact.uppercased()) else { return nil }
    let parts = calendar.dateComponents(in: calendar.timeZone, from: clock)
    return calendar.date(bySettingHour: parts.hour ?? 0, minute: parts.minute ?? 0, second: 0, of: day)
}

/// What a sitting was about, in a line or a paragraph: its name if someone gave it one, else its first
/// subheading, else the first paragraph of its prose. What a week draws for each sitting (docs/views.md
/// D4, D5), since seven days of prose in full is a document rather than a view. Empty for a sitting that
/// is only tasks.
public func sittingLede(name: String, prose: String) -> String {
    if !name.isEmpty { return name }
    let first = prose.components(separatedBy: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    if let first, first.range(of: #"^#{1,6}\s+\S"#, options: .regularExpression) != nil {
        return first.replacingOccurrences(of: #"^#{1,6}\s+"#, with: "", options: .regularExpression)
    }
    let paragraph = prose.components(separatedBy: "\n\n").first {
        !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    return (paragraph ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
}

/// A sitting's writing without its task lines, which the view draws as rows of their own.
func sittingProse(_ body: String) -> String {
    body.components(separatedBy: "\n")
        .filter { $0.range(of: #"^\s*[-*+]\s+\[[ xX-]\]\s"#, options: .regularExpression) == nil }
        .joined(separator: "\n")
        .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

extension TaskState {
    /// The state as one word, for anything reading it over a wire.
    var name: String {
        switch self {
        case .open: return "open"
        case .done: return "done"
        case .dropped: return "dropped"
        }
    }
}

// MARK: - Across the vault

/// The folders a `projects` field names: each by name or prefix, as a `[[link]]` or bare, and a master
/// with its members, since a master already rolls them up. The one reading of the field, for every query
/// that takes it.
public func projectFolders(named projects: [String]) throws -> Set<String> {
    var folders = Set<String>()
    for name in projects {
        let written = ProjectPartOf.writtenName(in: name) ?? name
        folders.insert((try resolveProjectPath(nameOrPrefix: written) as NSString).lastPathComponent)
    }
    for membership in try projectMemberships() {
        if let master = membership.master, folders.contains(master) { folders.insert(membership.member) }
    }
    return folders
}

/// Every sitting dated in `range`, across projects, with its tasks and prose.
///
/// `projects` narrows it to those projects, by name or prefix, as `[[links]]` or bare. A master brings
/// its members with it, since a master already rolls them up. Absent, it's everything, archive
/// included: a project archived today had today's sittings too.
///
/// **Cheap by a rule the files make true.** A project whose notes and logs haven't been written since
/// the span began can't have anything dated in it, so a Today view stats every project and parses only
/// the handful touched today. Each project that is read is looked at first (`DoneLog.observe`), so a
/// tick made in Obsidian an hour ago is in the answer.
public func sessionList(in range: DoneRange, projects: [String]? = nil, now: Date = Date()) throws -> SittingList {
    let (config, paths) = try loadConfigAndPaths(skipPathValidation: true)
    let codes = Array(config.domains.keys)

    let only = try projects.map(projectFolders(named:))

    var answer = SittingList()
    var seen = Set<String>()
    for scope in ProjectScope.allCases {
        let base = scope.path(in: paths)
        for folder in (try? getFolders(basePath: base, scope: scope, domainCodes: codes)) ?? [] {
            if let only, !only.contains(folder) { continue }
            let projectPath = (base as NSString).appendingPathComponent(folder)
            guard seen.insert(projectPath).inserted,
                  let notesPath = (try? resolveNotesPath(projectPath: projectPath)) ?? nil else { continue }
            let modified = notesLastEdited(path: notesPath)
            let touched = ([modified] + [DoneLog.logPath(projectPath: projectPath),
                                         PickLog.logPath(projectPath: projectPath)].map(notesLastEdited))
                .compactMap { $0 }.max()
            guard let touched, touched >= range.start,
                  let rawText = try? String(contentsOfFile: notesPath, encoding: .utf8) else { continue }
            if let modified, modified >= range.start {
                DoneLog.observe(projectPath: projectPath, rawText: rawText, now: now)
            }
            guard let read = try? notesShow(rawText: rawText) else { continue }
            let picks = PickLog.resolved(projectPath: projectPath, notes: read.notes, todos: read.todos)
            var part = sittings(
                projectFolder: folder, isArchived: scope.isArchived, notes: read.notes, todos: read.todos,
                picks: picks, doneEvents: DoneLog.standing(DoneLog.events(projectPath: projectPath)),
                in: range, notesModified: modified, now: now)
            let color = projectColor(rawText: rawText)?.value
            let icon = projectIcon(rawText: rawText)?.value
            for i in part.sittings.indices {
                part.sittings[i].projectColor = color
                part.sittings[i].projectIcon = icon
            }
            answer = answer.merged(with: part)
        }
    }
    return answer.sorted()
}
