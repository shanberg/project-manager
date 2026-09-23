import Foundation

// MARK: - Which projects are moving
//
// The portfolio (docs/views.md D1, Projects): each project with when it was last worked on, what's open
// in it and what's next due. The one question no task list can answer, because a project nobody has
// touched has nothing new in it to list.
//
// **Last activity** is the later of its newest sitting's start and the notes file's last write (D8) — a
// sitting says you sat down to it, and the file says you (or Obsidian, or a sync) changed it since.

/// A project as the portfolio shows it: `project.list`'s entry, and what's been happening in it.
public struct ProjectSummary: Codable, Equatable {
    public let folder: String
    public let name: String
    public let kind: String
    public let scope: String
    public let path: String
    public var projectColor: String? = nil
    public var projectIcon: String? = nil
    /// When it was last worked on, ISO 8601 in UTC. Nil for a project with no notes to read.
    public var lastActivity: String? = nil
    /// Its newest dated sitting, as an ISO day, and what that sitting was about (`sittingLede`).
    public var lastSitting: String? = nil
    public var lastSittingLede: String? = nil
    /// How many of its task lines are open.
    public var open: Int = 0
    /// Its soonest open due date, as the line writes it, and that task's text.
    public var nextDue: String? = nil
    public var nextDueText: String? = nil

    public init(folder: String, name: String, kind: String, scope: String, path: String) {
        self.folder = folder
        self.name = name
        self.kind = kind
        self.scope = scope
        self.path = path
    }
}

/// One project's activity from one read. Pure, so what counts is testable without a vault.
func summarize(_ base: ProjectSummary, notes: ProjectNotes, todos: [Todo], notesModified: Date?,
               calendar: Calendar = .current) -> ProjectSummary {
    var out = base
    var newest: (iso: String, index: Int, start: Date)?
    for (index, session) in notes.sessions.enumerated() {
        guard let iso = sessionISODate(heading: session.date),
              let day = try? DoneRange.localDay(iso, calendar: calendar) else { continue }
        let start = session.startTime.flatMap { clockTime($0, on: day, calendar: calendar) } ?? day
        if newest == nil || start > newest!.start { newest = (iso, index, start) }
    }
    if let newest {
        out.lastSitting = newest.iso
        let session = notes.sessions[newest.index]
        let lede = sittingLede(name: session.name, prose: sittingProse(session.body))
        out.lastSittingLede = lede.isEmpty ? nil : lede
    }
    if let last = [newest?.start, notesModified].compactMap({ $0 }).max() {
        out.lastActivity = DoneLog.timestamp(last)
    }
    let open = todos.filter { $0.state == .open }
    out.open = open.count
    if let soonest = open.filter({ $0.dueDate != nil }).min(by: { $0.dueDate!.prefix(10) < $1.dueDate!.prefix(10) }) {
        out.nextDue = soonest.dueDate
        out.nextDueText = soonest.text
    }
    return out
}

/// Every project in `scopes`, of `kind`, each with its activity — newest first.
///
/// `projects` narrows it the way every query reads the field. Reads every project it lists, so it's
/// asked for (`project.list`'s `activity`) rather than paid on every list.
public func projectSummaries(scopes: [ProjectScope] = [.active, .areas], kind: String? = nil,
                             projects: [String]? = nil) throws -> [ProjectSummary] {
    let (config, paths) = try loadConfigAndPaths(skipPathValidation: true)
    let codes = Array(config.domains.keys)
    let wanted = kind.flatMap(ProjectKind.init(rawValue:))
    let only = try projects.map(projectFolders(named:))
    var out: [ProjectSummary] = []
    for scopeCase in ProjectScope.allCases where scopes.contains(scopeCase) {
        let base = scopeCase.path(in: paths)
        for folder in (try? getFolders(basePath: base, scope: scopeCase, domainCodes: codes)) ?? [] {
            if let only, !only.contains(folder) { continue }
            let projectKind = ProjectKind.of(folderName: folder)
            guard wanted == nil || wanted == projectKind else { continue }
            let projectPath = (base as NSString).appendingPathComponent(folder)
            var summary = ProjectSummary(folder: folder, name: projectTitle(fromFolderName: folder),
                                         kind: projectKind.rawValue, scope: scopeCase.rawValue, path: projectPath)
            if let notesPath = (try? resolveNotesPath(projectPath: projectPath)) ?? nil,
               let rawText = try? String(contentsOfFile: notesPath, encoding: .utf8),
               let read = try? notesShow(rawText: rawText) {
                summary = summarize(summary, notes: read.notes, todos: read.todos,
                                    notesModified: notesLastEdited(path: notesPath))
                summary.projectColor = projectColor(rawText: rawText)?.value
                summary.projectIcon = projectIcon(rawText: rawText, notesPath: notesPath)?.value
            }
            out.append(summary)
        }
    }
    return out.sorted { ($0.lastActivity ?? "") > ($1.lastActivity ?? "") }
}
