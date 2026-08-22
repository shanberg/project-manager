import AppIntents
import CoreSpotlight
import Foundation
import PmLib
import UniformTypeIdentifiers

// PM's domain modeled as App Intents *entities* rather than opaque strings. This is what lets the
// new (Apple Intelligence) Siri and Spotlight semantic search resolve, disambiguate, and reference
// projects and tasks by name in natural language ("focus Redesign", "complete buy milk in PM"),
// chain intents together (a query returns entities that a later action consumes), and index content
// for semantic search. Everything resolves through PmLib/PMFiles, so queries run headless.

// MARK: - Shared

/// The human-readable domain name for a project folder (e.g. "W-1 Redesign" → "Work"), choosing the
/// longest matching domain code so "WK" wins over "W".
func domainName(ofFolder folder: String, config: PmConfig) -> String? {
    var best: (code: String, name: String)?
    for (code, name) in config.domains where folder.hasPrefix("\(code)-") {
        if best == nil || code.count > best!.code.count { best = (code, name) }
    }
    return best?.name
}

// MARK: - Project entity

/// A PM project. `id` is the project key `"<basePath>:<folderName>"` that PMFiles uses for focus and
/// recents, so an entity round-trips to the same identity the rest of the app already stores.
struct ProjectEntity: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Project")
    static var defaultQuery = ProjectEntityQuery()

    var id: String
    /// Folder name on disk, e.g. "W-1 Redesign" — what PmLib's `notesShow(project:)` accepts.
    var folder: String
    /// Human-facing title (folder name with the domain/number prefix stripped).
    var name: String
    /// Domain display name, e.g. "Work" (nil if not resolvable).
    var domainDisplayName: String?

    var displayRepresentation: DisplayRepresentation {
        if let domainDisplayName {
            return DisplayRepresentation(title: "\(name)", subtitle: "\(domainDisplayName)")
        }
        return DisplayRepresentation(title: "\(name)")
    }
}

extension ProjectEntity {
    /// All active projects as entities (same enumeration the CLI/Raycast use).
    static func all() throws -> [ProjectEntity] {
        let (config, paths) = try loadConfigAndPaths()
        let folders = try getProjectFolders(basePath: paths.activePath, domainCodes: Array(config.domains.keys))
        return folders.map { folder in
            ProjectEntity(id: "\(paths.activePath):\(folder)",
                          folder: folder,
                          name: projectTitle(fromFolderName: folder),
                          domainDisplayName: domainName(ofFolder: folder, config: config))
        }
    }

    /// The currently focused project, if any.
    static func focused() -> ProjectEntity? {
        guard let key = PMFiles.focusedProjectKey(), let folder = PMFiles.projectName(fromKey: key) else { return nil }
        let config = (try? loadConfig()) ?? nil
        return ProjectEntity(id: key,
                             folder: folder,
                             name: projectTitle(fromFolderName: folder),
                             domainDisplayName: config.flatMap { domainName(ofFolder: folder, config: $0) })
    }
}

struct ProjectEntityQuery: EntityStringQuery {
    func entities(for identifiers: [ProjectEntity.ID]) async throws -> [ProjectEntity] {
        let wanted = Set(identifiers)
        return (try ProjectEntity.all()).filter { wanted.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [ProjectEntity] {
        let q = string.lowercased()
        return (try ProjectEntity.all()).filter {
            $0.name.lowercased().contains(q) || $0.folder.lowercased().contains(q)
        }
    }

    func suggestedEntities() async throws -> [ProjectEntity] {
        try ProjectEntity.all()
    }
}

// MARK: - Task entity

/// A single task within a project. Identity mirrors the app's existing `focusedKey` model
/// (`sessionIndex:lineIndex` within a project), namespaced by the project key so ids are globally
/// unique: `"<sessionIndex>:<lineIndex>\u{1F}<projectKey>"`.
struct TaskEntity: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Task")
    static var defaultQuery = TaskEntityQuery()

    var id: String
    var text: String
    var isCompleted: Bool
    var projectKey: String
    var projectFolder: String
    var sessionIndex: Int
    var lineIndex: Int
    var due: String?
    /// The ISO date of the task's session and the digest of its text — how the contract names a task.
    ///
    /// Not part of `id`, deliberately. Shortcuts persists the id and re-resolves through the query,
    /// so a digest baked into it would make a saved shortcut fail to resolve at all rather than
    /// refuse clearly — and the id format is one saved shortcuts already hold. Carried alongside, it
    /// still catches a task changing between an intent resolving it and acting on it.
    var sessionDate: String?
    var digest: String?

    var displayRepresentation: DisplayRepresentation {
        var subtitle = projectTitle(fromFolderName: projectFolder)
        if let due { subtitle += " · due \(due)" }
        return DisplayRepresentation(title: "\(text)", subtitle: "\(subtitle)")
    }
}

extension TaskEntity {
    /// This task as the contract names it.
    var reference: TaskRefInput {
        TaskRefInput(session: sessionDate ?? String(sessionIndex), line: lineIndex, digest: digest)
    }

    /// Separator between the task's in-project coordinate and its project key. A control character
    /// (ASCII unit separator) that cannot occur in a filesystem path or task text.
    static let idSeparator = "\u{1F}"

    static func make(projectKey: String, folder: String, todo: Todo) -> TaskEntity {
        TaskEntity(id: "\(todo.sessionIndex):\(todo.lineIndex)\(idSeparator)\(projectKey)",
                   text: todo.text,
                   isCompleted: todo.checked,
                   projectKey: projectKey,
                   projectFolder: folder,
                   sessionIndex: todo.sessionIndex,
                   lineIndex: todo.lineIndex,
                   due: todo.dueDate ?? todo.effectiveDueDate,
                   sessionDate: todo.sessionISODate,
                   digest: todo.digest)
    }

    /// Decode an id back into (project key, sessionIndex, lineIndex).
    static func decode(id: String) -> (projectKey: String, sessionIndex: Int, lineIndex: Int)? {
        guard let sep = id.range(of: idSeparator) else { return nil }
        let coord = id[..<sep.lowerBound].split(separator: ":").compactMap { Int($0) }
        guard coord.count == 2 else { return nil }
        return (String(id[sep.upperBound...]), coord[0], coord[1])
    }

    /// Tasks in a project, optionally only the open (incomplete) ones.
    static func inProject(folder: String, projectKey: String, openOnly: Bool) throws -> [TaskEntity] {
        try notesShow(project: folder).todos
            .filter { openOnly ? !$0.checked : true }
            .map { make(projectKey: projectKey, folder: folder, todo: $0) }
    }

    /// The currently focused task, if any.
    static func focused() -> TaskEntity? {
        guard let key = PMFiles.focusedProjectKey(), let folder = PMFiles.projectName(fromKey: key),
              let output = try? notesShow(project: folder), let fk = output.focusedKey else { return nil }
        let p = fk.split(separator: ":").compactMap { Int($0) }
        guard p.count == 2,
              let todo = output.todos.first(where: { $0.sessionIndex == p[0] && $0.lineIndex == p[1] }) else { return nil }
        return make(projectKey: key, folder: folder, todo: todo)
    }
}

struct TaskEntityQuery: EntityStringQuery {
    func entities(for identifiers: [TaskEntity.ID]) async throws -> [TaskEntity] {
        // Group ids by project so each project's notes file is read at most once.
        var coordsByProject: [String: [(session: Int, line: Int)]] = [:]
        for id in identifiers {
            guard let d = TaskEntity.decode(id: id) else { continue }
            coordsByProject[d.projectKey, default: []].append((d.sessionIndex, d.lineIndex))
        }
        var result: [TaskEntity] = []
        for (key, coords) in coordsByProject {
            guard let folder = PMFiles.projectName(fromKey: key), let output = try? notesShow(project: folder) else { continue }
            for c in coords where output.todos.contains(where: { $0.sessionIndex == c.session && $0.lineIndex == c.line }) {
                let todo = output.todos.first { $0.sessionIndex == c.session && $0.lineIndex == c.line }!
                result.append(TaskEntity.make(projectKey: key, folder: folder, todo: todo))
            }
        }
        return result
    }

    func entities(matching string: String) async throws -> [TaskEntity] {
        let q = string.lowercased()
        return try candidateTasks().filter { $0.text.lowercased().contains(q) }
    }

    func suggestedEntities() async throws -> [TaskEntity] {
        guard let p = ProjectEntity.focused() else { return [] }
        return try TaskEntity.inProject(folder: p.folder, projectKey: p.id, openOnly: true)
    }

    /// Open tasks in the focused project; if there is none (or it has no open tasks), open tasks
    /// across all active projects, bounded so a huge workspace can't stall resolution.
    private func candidateTasks() throws -> [TaskEntity] {
        if let p = ProjectEntity.focused() {
            let focused = (try? TaskEntity.inProject(folder: p.folder, projectKey: p.id, openOnly: true)) ?? []
            if !focused.isEmpty { return focused }
        }
        var all: [TaskEntity] = []
        for p in (try? ProjectEntity.all()) ?? [] {
            all += (try? TaskEntity.inProject(folder: p.folder, projectKey: p.id, openOnly: true)) ?? []
            if all.count >= 200 { break }
        }
        return all
    }
}

// MARK: - Spotlight indexing (semantic search)

// `IndexedEntity` (macOS 15+) ties each Spotlight hit back to its App Intents entity, which is what
// feeds the semantic search behind the new Siri. Gated by availability so the app keeps deploying to
// macOS 13; systems older than 15 predate that Siri anyway, so they simply aren't indexed.

@available(macOS 15.0, *)
extension ProjectEntity: IndexedEntity {
    var attributeSet: CSSearchableItemAttributeSet {
        let attrs = CSSearchableItemAttributeSet(contentType: .content)
        attrs.title = name
        attrs.displayName = name
        attrs.contentDescription = domainDisplayName.map { "\($0) project" } ?? "PM project"
        if let domainDisplayName { attrs.kind = domainDisplayName }
        attrs.keywords = [name, folder]
        return attrs
    }
}

@available(macOS 15.0, *)
extension TaskEntity: IndexedEntity {
    var attributeSet: CSSearchableItemAttributeSet {
        let attrs = CSSearchableItemAttributeSet(contentType: .content)
        attrs.title = text
        attrs.displayName = text
        var parts = [projectTitle(fromFolderName: projectFolder)]
        if let due { parts.append("due \(due)") }
        parts.append(isCompleted ? "done" : "open")
        attrs.contentDescription = parts.joined(separator: " · ")
        attrs.keywords = [text]
        return attrs
    }
}
