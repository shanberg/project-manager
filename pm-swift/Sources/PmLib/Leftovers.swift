import Foundation

// MARK: - What's been left open
//
// `session.list` is the journal read across projects; this is the pile read across projects (docs/views.md
// D1). A task is left over when it's still open in a sitting older than the cut-off: you wrote it down,
// sat down to other things since, and it's still there. Where you wrote it is half the answer, so each
// task comes with its sitting and what that sitting was about.
//
// A picked-up task is still listed. Picking something up says you're working on it, not that it's done,
// and the pile is the place to see that you picked it up three sittings running.

/// One open task, left in an older sitting.
public struct LeftoverTask: Codable, Equatable {
    public let text: String
    /// Indent among the listed tasks: a subtask whose parent is listed too sits under it; one whose
    /// parent was finished starts a tree of its own.
    public let depth: Int
    public let due: String?
    /// What its own line says it's waiting on — the token Stop Waiting clears. See `TaskSearchHit.waiting`.
    public let waiting: String?
    /// What it waits on in practice: its own token, else the nearest waiting ancestor's.
    public let effectiveWaiting: String?
    public let isFocused: Bool
    /// Where the line is, to act on it.
    public let ref: TaskRefInput
    /// The latest sitting it was picked up into, when it has been.
    public let picked: PickMark?

    public init(text: String, depth: Int, due: String?, waiting: String?, effectiveWaiting: String?,
                isFocused: Bool, ref: TaskRefInput, picked: PickMark?) {
        self.text = text
        self.depth = depth
        self.due = due
        self.waiting = waiting
        self.effectiveWaiting = effectiveWaiting
        self.isFocused = isFocused
        self.ref = ref
        self.picked = picked
    }
}

/// One sitting's leftovers.
public struct LeftoverSitting: Codable, Equatable {
    /// The sitting as a `SessionRef` names it.
    public let session: String
    public let sessionOrdinal: Int
    public let sessionDigest: String
    /// When it began, as its heading says, or nil for a sitting from before headings kept the time.
    public let startTime: String?
    /// What someone named it, or empty.
    public let name: String
    /// What it was about in a line: its name, else its first subheading, else its first paragraph
    /// (`sittingLede`). Empty for a sitting that is only tasks.
    public let lede: String
    /// Its open tasks, in document order.
    public let tasks: [LeftoverTask]

    public init(session: String, sessionOrdinal: Int, sessionDigest: String, startTime: String?, name: String,
                lede: String, tasks: [LeftoverTask]) {
        self.session = session
        self.sessionOrdinal = sessionOrdinal
        self.sessionDigest = sessionDigest
        self.startTime = startTime
        self.name = name
        self.lede = lede
        self.tasks = tasks
    }
}

/// One project's leftovers, oldest sitting first.
public struct LeftoverProject: Codable, Equatable {
    public let projectFolder: String
    public let projectName: String
    public let isArchived: Bool
    public var projectColor: String? = nil
    public var projectIcon: String? = nil
    public let sittings: [LeftoverSitting]

    public init(projectFolder: String, projectName: String, isArchived: Bool, projectColor: String? = nil,
                projectIcon: String? = nil, sittings: [LeftoverSitting]) {
        self.projectFolder = projectFolder
        self.projectName = projectName
        self.isArchived = isArchived
        self.projectColor = projectColor
        self.projectIcon = projectIcon
        self.sittings = sittings
    }
}

/// The pile: projects in the order their oldest leftover was written, oldest first.
public struct LeftoverList: Codable, Equatable {
    public var projects: [LeftoverProject]

    public init(projects: [LeftoverProject] = []) {
        self.projects = projects
    }

    public var taskCount: Int { projects.reduce(0) { $0 + $1.sittings.reduce(0) { $0 + $1.tasks.count } } }
    public var sittingCount: Int { projects.reduce(0) { $0 + $1.sittings.count } }
}

/// The start of the day `before` names: sittings dated earlier than it are old enough to leave things in.
///
/// `today` (the default) is midnight, so everything before today; `yesterday` is the day before that;
/// `week` is the start of this week, the reader's first weekday — so a Leftovers card set to it and a
/// Day card set to This Week split the time between them, which is the weekly review. A date is that day.
public func leftoversCutoff(before: String?, now: Date = Date(), calendar: Calendar = .current) throws -> Date {
    switch before?.trimmingCharacters(in: .whitespaces).lowercased() {
    case nil, "", "today":
        return try DoneRange.resolve(period: "today", since: nil, until: nil, now: now, calendar: calendar).start
    case let relative? where relative == "yesterday" || relative == "week":
        return try DoneRange.resolve(period: relative, since: nil, until: nil, now: now, calendar: calendar).start
    case let date?:
        return try DoneRange.localDay(date, calendar: calendar)
    }
}

/// One project's leftovers from one read, or nil when it has none. Pure, so what counts is testable
/// without a vault. `todos` are the read's, with its picks attached.
func leftovers(projectFolder: String, isArchived: Bool = false, notes: ProjectNotes, todos: [Todo],
               before cutoff: Date, calendar: Calendar = .current) -> LeftoverProject? {
    let todos = todosWithEffectiveWaiting(todosWithEffectiveDueDates(todos))
    var sittings: [LeftoverSitting] = []
    for (index, session) in notes.sessions.enumerated() {
        guard let iso = sessionISODate(heading: session.date),
              let day = try? DoneRange.localDay(iso, calendar: calendar), day < cutoff else { continue }
        // The chain of lines above the current one, and whether each is listed — a subtask's depth is
        // how many of its listed ancestors there are.
        var above: [(depth: Int, listed: Bool)] = []
        var tasks: [LeftoverTask] = []
        for todo in todos where todo.sessionIndex == index {
            while let last = above.last, last.depth >= todo.depth { above.removeLast() }
            let listed = todo.state == .open
            if listed, let ref = PickLog.task(todo, in: notes) {
                tasks.append(LeftoverTask(
                    text: todo.text, depth: above.filter(\.listed).count,
                    due: todo.effectiveDueDate ?? todo.dueDate, waiting: todo.waiting,
                    effectiveWaiting: todo.effectiveWaiting, isFocused: todo.isFocused,
                    ref: TaskRefInput(session: ref.session, sessionOrdinal: ref.ordinal, line: ref.line,
                                      digest: ref.digest),
                    picked: todo.picked))
            }
            above.append((todo.depth, listed))
        }
        guard !tasks.isEmpty else { continue }
        let ref = SessionRef(session: session, at: index, in: notes)
        sittings.append(LeftoverSitting(
            session: iso, sessionOrdinal: ref.ordinal, sessionDigest: ref.digest ?? "",
            startTime: session.startTime, name: session.name,
            lede: sittingLede(name: session.name, prose: sittingProse(session.body)), tasks: tasks))
    }
    guard !sittings.isEmpty else { return nil }
    // The file is newest first; the pile is read oldest first. Within a day the higher ordinal is older.
    sittings.sort { $0.session != $1.session ? $0.session < $1.session : $0.sessionOrdinal > $1.sessionOrdinal }
    return LeftoverProject(projectFolder: projectFolder, projectName: projectTitle(fromFolderName: projectFolder),
                           isArchived: isArchived, sittings: sittings)
}

extension LeftoverList {
    /// Projects by their oldest leftover, oldest first — the one you've left longest leads — then by name.
    func sorted() -> LeftoverList {
        LeftoverList(projects: projects.sorted { a, b in
            let (x, y) = (a.sittings.first?.session ?? "", b.sittings.first?.session ?? "")
            if x != y { return x < y }
            return a.projectName.localizedCaseInsensitiveCompare(b.projectName) == .orderedAscending
        })
    }
}

/// Every open task left in a sitting older than `before`, across projects.
///
/// `projects` narrows it the way every query reads the field (`projectFolders`). Absent, it's the
/// projects and areas in hand: an archived project's open tasks were put down, not left. Named, an
/// archived project is read too, since you asked for it.
///
/// Unlike `session.list` there's no cheap rule to skip a project by — a leftover is old by definition —
/// so this reads every project, as `task.waiting` does.
public func leftoverTasks(before: String? = nil, projects: [String]? = nil, now: Date = Date(),
                          calendar: Calendar = .current) throws -> LeftoverList {
    let cutoff = try leftoversCutoff(before: before, now: now, calendar: calendar)
    let (config, paths) = try loadConfigAndPaths(skipPathValidation: true)
    let codes = Array(config.domains.keys)
    let only = try projects.map(projectFolders(named:))
    let scopes: [ProjectScope] = only == nil ? [.active, .areas] : ProjectScope.allCases

    var answer = LeftoverList()
    var seen = Set<String>()
    for scope in scopes {
        let base = scope.path(in: paths)
        for folder in (try? getFolders(basePath: base, scope: scope, domainCodes: codes)) ?? [] {
            if let only, !only.contains(folder) { continue }
            let projectPath = (base as NSString).appendingPathComponent(folder)
            guard seen.insert(projectPath).inserted,
                  let notesPath = (try? resolveNotesPath(projectPath: projectPath)) ?? nil,
                  let rawText = try? String(contentsOfFile: notesPath, encoding: .utf8),
                  let read = try? notesShow(rawText: rawText).attachingPicks(projectPath: projectPath),
                  var part = leftovers(projectFolder: folder, isArchived: scope.isArchived, notes: read.notes,
                                       todos: read.todos, before: cutoff, calendar: calendar) else { continue }
            part.projectColor = projectColor(rawText: rawText)?.value
            part.projectIcon = projectIcon(rawText: rawText, notesPath: notesPath)?.value
            answer.projects.append(part)
        }
    }
    return answer.sorted()
}

public extension LeftoverProject {
    /// One of its leftovers as a search hit — the one shape every task-list surface draws and acts on.
    func hit(_ task: LeftoverTask) -> TaskSearchHit {
        TaskSearchHit(projectFolder: projectFolder, projectName: projectName, projectKey: projectFolder,
                      isArchived: isArchived, text: task.text, due: task.due, waiting: task.waiting,
                      effectiveWaiting: task.effectiveWaiting, isFocused: task.isFocused,
                      session: task.ref.session, sessionOrdinal: task.ref.sessionOrdinal, line: task.ref.line,
                      digest: task.ref.digest, projectColor: projectColor, projectIcon: projectIcon)
    }
}
