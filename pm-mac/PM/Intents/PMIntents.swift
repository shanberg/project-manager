import AppIntents
import AppKit
import Foundation
import PmLib

// App Intents expose PM's full knowledge + lifecycle to Shortcuts, Spotlight, and Siri — a native
// automation layer alongside Raycast. Projects and tasks are modeled as App Intents *entities*
// (see PMEntities.swift), so the new Apple Intelligence Siri can reference them by name, disambiguate
// them, and chain intents (a query returns entities a later action consumes) rather than treating
// everything as an opaque string bound to "the focused thing". Every intent still defaults to the
// focused project/task when no entity is supplied, so the original spoken phrases keep working.
// Everything operates on the pm files via PmLib/PMFiles (no dependency on the running UI), so the
// system can run these by launching the agent in the background.

// MARK: - Shared helpers

/// Formats a date as the `YYYY-MM-DD` string pm stores for due dates.
private func dueString(from date: Date) -> String {
    let f = DateFormatter()
    f.calendar = Calendar(identifier: .gregorian)
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd"
    return f.string(from: date)
}

/// The display title for a focused project's notes (falls back to the folder name).
private func displayTitle(_ output: NotesShowOutput, folder: String) -> String {
    let t = output.notes.title.trimmingCharacters(in: .whitespaces)
    return t.isEmpty ? folder : t
}

/// Resolve a project parameter to (key, folder), falling back to the focused project. Throws when
/// neither is available — used by mutating intents that need a definite target.
private func resolveProject(_ entity: ProjectEntity?) throws -> (key: String, folder: String) {
    if let entity { return (entity.id, entity.folder) }
    guard let key = PMFiles.focusedProjectKey(), let folder = PMFiles.projectName(fromKey: key) else {
        throw PMIntentError.noFocusedProject
    }
    return (key, folder)
}

/// Resolve a task parameter, falling back to the focused task. Throws when neither is available.
private func resolveTask(_ entity: TaskEntity?) throws -> TaskEntity {
    if let entity { return entity }
    guard let focused = TaskEntity.focused() else { throw PMIntentError.noFocusedTask }
    return focused
}

private enum PMIntentError: Error, CustomLocalizedStringResourceConvertible {
    case noFocusedProject
    case noFocusedTask
    case noDomains
    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .noFocusedProject: return "No project is focused. Focus one first."
        case .noFocusedTask: return "No task is focused. Focus one first."
        case .noDomains: return "No domains are configured."
        }
    }
}

// MARK: - Knowledge (queries)

/// Reports the currently focused project and task.
struct FocusedProjectInfoIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Focused Project"
    static var description = IntentDescription("Reports the currently focused project and task.")

    func perform() async throws -> some IntentResult & ReturnsValue<ProjectEntity?> & ProvidesDialog {
        guard let project = ProjectEntity.focused() else {
            return .result(value: nil, dialog: "No project is focused.")
        }
        let output = try notesShow(project: project.folder)
        let title = displayTitle(output, folder: project.folder)
        var line = "The focused project is \(title)."
        if let key = output.focusedKey {
            let p = key.split(separator: ":").compactMap { Int($0) }
            if p.count == 2, let task = output.todos.first(where: { $0.sessionIndex == p[0] && $0.lineIndex == p[1] }) {
                line = "In \(title), you're focused on “\(task.text)”."
            }
        }
        return .result(value: project, dialog: IntentDialog(stringLiteral: line))
    }
}

/// Lists the open (incomplete) tasks in a project (defaults to the focused one).
struct ListOpenTasksIntent: AppIntent {
    static var title: LocalizedStringResource = "List Open Tasks"
    static var description = IntentDescription("Lists the open tasks in a project (defaults to the focused project).")

    @Parameter(title: "Project") var project: ProjectEntity?

    static var parameterSummary: some ParameterSummary { Summary("List open tasks in \(\.$project)") }

    func perform() async throws -> some IntentResult & ReturnsValue<[TaskEntity]> & ProvidesDialog {
        guard let p = project ?? ProjectEntity.focused() else { return .result(value: [], dialog: "No project is focused.") }
        let output = try notesShow(project: p.folder)
        let open = output.todos.filter { !$0.checked }
        guard !open.isEmpty else {
            return .result(value: [], dialog: "All tasks are complete in \(displayTitle(output, folder: p.folder)).")
        }
        let entities = open.map { TaskEntity.make(projectKey: p.id, folder: p.folder, todo: $0) }
        let spoken = open.prefix(8).map(\.text).joined(separator: ", ")
        let more = open.count > 8 ? ", and \(open.count - 8) more" : ""
        return .result(value: entities, dialog: IntentDialog(stringLiteral: "Open tasks: \(spoken)\(more)."))
    }
}

/// Reports completion progress (done of total) for a project (defaults to the focused one).
struct ProjectProgressIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Project Progress"
    static var description = IntentDescription("Reports how many tasks are done in a project (defaults to the focused project).")

    @Parameter(title: "Project") var project: ProjectEntity?

    static var parameterSummary: some ParameterSummary { Summary("Get progress for \(\.$project)") }

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        guard let p = project ?? ProjectEntity.focused() else { return .result(value: "0/0", dialog: "No project is focused.") }
        let output = try notesShow(project: p.folder)
        let total = output.todos.count
        let done = output.todos.filter { $0.checked }.count
        let title = displayTitle(output, folder: p.folder)
        return .result(value: "\(done)/\(total)", dialog: IntentDialog(stringLiteral: "\(done) of \(total) tasks done in \(title)."))
    }
}

/// Reports overdue and upcoming due tasks in a project (defaults to the focused one).
struct WhatsDueIntent: AppIntent {
    static var title: LocalizedStringResource = "What's Due"
    static var description = IntentDescription("Reports overdue and upcoming due tasks in a project (defaults to the focused project).")

    @Parameter(title: "Project") var project: ProjectEntity?

    static var parameterSummary: some ParameterSummary { Summary("What's due in \(\.$project)") }

    func perform() async throws -> some IntentResult & ReturnsValue<[TaskEntity]> & ProvidesDialog {
        guard let p = project ?? ProjectEntity.focused() else { return .result(value: [], dialog: "No project is focused.") }
        let output = try notesShow(project: p.folder)
        let dued = output.todos.filter { !$0.checked && ($0.dueDate ?? $0.effectiveDueDate) != nil }
        guard !dued.isEmpty else { return .result(value: [], dialog: "Nothing due in \(displayTitle(output, folder: p.folder)).") }
        let entities = dued.map { TaskEntity.make(projectKey: p.id, folder: p.folder, todo: $0) }
        let items = dued.map { todo -> String in
            let due = todo.dueDate ?? todo.effectiveDueDate!
            return "\(todo.text) (\(RelativeDue.short(due)))"
        }
        let overdue = dued.filter { RelativeDue.isOverdue($0.dueDate ?? $0.effectiveDueDate!) }.count
        let prefix = overdue > 0 ? "\(overdue) overdue. " : ""
        return .result(value: entities, dialog: IntentDialog(stringLiteral: "\(prefix)\(items.prefix(6).joined(separator: ", "))."))
    }
}

/// Lists all active projects.
struct ListProjectsIntent: AppIntent {
    static var title: LocalizedStringResource = "List Projects"
    static var description = IntentDescription("Lists your active projects.")

    func perform() async throws -> some IntentResult & ReturnsValue<[ProjectEntity]> & ProvidesDialog {
        let projects = try ProjectEntity.all()
        guard !projects.isEmpty else { return .result(value: [], dialog: "You have no active projects.") }
        let titles = projects.map(\.name)
        return .result(value: projects, dialog: IntentDialog(stringLiteral: "\(projects.count) projects: \(titles.prefix(10).joined(separator: ", "))."))
    }
}

// MARK: - Task lifecycle

/// Completes a task (defaults to the focused task) and advances focus.
struct CompleteTaskIntent: AppIntent {
    static var title: LocalizedStringResource = "Complete Task"
    static var description = IntentDescription("Marks a task complete (defaults to the focused task) and advances focus.")

    @Parameter(title: "Task") var task: TaskEntity?

    static var parameterSummary: some ParameterSummary { Summary("Complete \(\.$task)") }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let t = try resolveTask(task)
        try PMContract.perform("task.complete", PMContract.input(project: t.projectFolder) {
            $0.task = t.reference
            $0.advanceFocus = true
        })
        PMSpotlight.reindex()
        return .result(dialog: IntentDialog(stringLiteral: "Completed “\(t.text)”."))
    }
}

/// Reopens (un-checks) a completed task.
struct ReopenTaskIntent: AppIntent {
    static var title: LocalizedStringResource = "Reopen Task"
    static var description = IntentDescription("Marks a completed task as open again.")

    @Parameter(title: "Task") var task: TaskEntity

    static var parameterSummary: some ParameterSummary { Summary("Reopen \(\.$task)") }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        try PMContract.perform("task.reopen", PMContract.input(project: task.projectFolder) {
            $0.task = task.reference
        })
        PMSpotlight.reindex()
        return .result(dialog: IntentDialog(stringLiteral: "Reopened “\(task.text)”."))
    }
}

/// Adds a task to a project (defaults to the focused one), optionally with a due date.
struct AddTaskIntent: AppIntent {
    static var title: LocalizedStringResource = "Add Task"
    static var description = IntentDescription("Adds a task to a project (defaults to the focused project).")

    @Parameter(title: "Task") var text: String
    @Parameter(title: "Project") var project: ProjectEntity?
    @Parameter(title: "Due date") var due: Date?

    static var parameterSummary: some ParameterSummary { Summary("Add \(\.$text) to \(\.$project) due \(\.$due)") }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let (_, folder) = try resolveProject(project)
        try PMContract.perform("task.add", PMContract.input(project: folder) {
            $0.text = text
            $0.due = due.map(dueString(from:))
        })
        PMSpotlight.reindex()
        return .result(dialog: IntentDialog(stringLiteral: "Added “\(text)”."))
    }
}

/// Renames a task's text.
struct RenameTaskIntent: AppIntent {
    static var title: LocalizedStringResource = "Rename Task"
    static var description = IntentDescription("Changes a task's text.")

    @Parameter(title: "Task") var task: TaskEntity
    @Parameter(title: "New text") var text: String

    static var parameterSummary: some ParameterSummary { Summary("Rename \(\.$task) to \(\.$text)") }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        try PMContract.perform("task.setText", PMContract.input(project: task.projectFolder) {
            $0.task = task.reference
            $0.text = text
        })
        PMSpotlight.reindex()
        return .result(dialog: IntentDialog(stringLiteral: "Renamed to “\(text)”."))
    }
}

/// Sets (or updates) the due date on a task (defaults to the focused task).
struct SetDueDateIntent: AppIntent {
    static var title: LocalizedStringResource = "Set Due Date"
    static var description = IntentDescription("Sets the due date on a task (defaults to the focused task).")

    @Parameter(title: "Task") var task: TaskEntity?
    @Parameter(title: "Due date") var due: Date

    static var parameterSummary: some ParameterSummary { Summary("Set \(\.$task) due \(\.$due)") }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let t = try resolveTask(task)
        let value = dueString(from: due)
        try PMContract.perform("task.setDue", PMContract.input(project: t.projectFolder) {
            $0.task = t.reference
            $0.due = value
        })
        PMSpotlight.reindex()
        return .result(dialog: IntentDialog(stringLiteral: "Set due \(value) on “\(t.text)”."))
    }
}

/// Focuses a specific task (and its project).
struct FocusTaskIntent: AppIntent {
    static var title: LocalizedStringResource = "Focus Task"
    static var description = IntentDescription("Focuses a specific task.")

    @Parameter(title: "Task") var task: TaskEntity

    static var parameterSummary: some ParameterSummary { Summary("Focus \(\.$task)") }

    func perform() async throws -> some IntentResult & ReturnsValue<TaskEntity> & ProvidesDialog {
        try PMFiles.setFocusedProjectKey(task.projectKey)
        PMFiles.recordRecent(projectKey: task.projectKey, name: task.projectFolder)
        try PMContract.perform("task.focus", PMContract.input(project: task.projectFolder) {
            $0.task = task.reference
        })
        return .result(value: task, dialog: IntentDialog(stringLiteral: "Focused “\(task.text)”."))
    }
}

/// Moves focus to the first open leaf under the focused task (else the first open leaf anywhere) —
/// mirrors the "Dive In" command. Defaults to the focused project.
struct DiveInIntent: AppIntent {
    static var title: LocalizedStringResource = "Dive In"
    static var description = IntentDescription("Moves focus to the next actionable leaf task.")

    @Parameter(title: "Project") var project: ProjectEntity?

    static var parameterSummary: some ParameterSummary { Summary("Dive in to \(\.$project)") }

    func perform() async throws -> some IntentResult & ReturnsValue<TaskEntity?> & ProvidesDialog {
        let (key, folder) = try resolveProject(project)
        let list = try notesShow(project: folder).todos
        guard !list.isEmpty else { return .result(value: nil, dialog: "No tasks.") }
        guard let target = nextDiveInLeaf(todos: list) else {
            return .result(value: nil, dialog: "No open leaf task to dive into.")
        }
        try PMContract.perform("task.focus", PMContract.input(project: folder) {
            $0.task = target.reference
        })
        let entity = TaskEntity.make(projectKey: key, folder: folder, todo: target)
        return .result(value: entity, dialog: IntentDialog(stringLiteral: "Focused on “\(target.text)”."))
    }
}

// MARK: - Project lifecycle

/// Focuses a project (resolved from the entity, which the system disambiguates by name/prefix).
struct FocusProjectIntent: AppIntent {
    static var title: LocalizedStringResource = "Focus Project"
    static var description = IntentDescription("Sets the focused project.")

    @Parameter(title: "Project") var project: ProjectEntity

    static var parameterSummary: some ParameterSummary { Summary("Focus \(\.$project)") }

    func perform() async throws -> some IntentResult & ReturnsValue<ProjectEntity> & ProvidesDialog {
        try PMFiles.setFocusedProjectKey(project.id)
        PMFiles.recordRecent(projectKey: project.id, name: project.folder)
        return .result(value: project, dialog: IntentDialog(stringLiteral: "Focused \(project.name)."))
    }
}

/// Creates a new project and focuses it.
struct NewProjectIntent: AppIntent {
    static var title: LocalizedStringResource = "New Project"
    static var description = IntentDescription("Creates a new project and focuses it.")

    @Parameter(title: "Title") var projectTitleParam: String
    @Parameter(title: "Domain code") var domain: String?

    static var parameterSummary: some ParameterSummary { Summary("Create project \(\.$projectTitleParam) in \(\.$domain)") }

    func perform() async throws -> some IntentResult & ReturnsValue<ProjectEntity> & ProvidesDialog {
        let (config, paths) = try loadConfigAndPaths()
        guard let code = domain ?? Array(config.domains.keys).first else { throw PMIntentError.noDomains }
        let path = try createProject(config: config, paths: paths, domainCode: code, title: projectTitleParam)
        let folder = (path as NSString).lastPathComponent
        let key = "\((path as NSString).deletingLastPathComponent):\(folder)"
        try? PMFiles.setFocusedProjectKey(key)
        PMFiles.recordRecent(projectKey: key, name: folder)
        PMSpotlight.reindex()
        let entity = ProjectEntity(id: key, folder: folder, name: projectTitle(fromFolderName: folder), domainDisplayName: config.domains[code])
        return .result(value: entity, dialog: IntentDialog(stringLiteral: "Created and focused “\(projectTitleParam)”."))
    }
}

// MARK: - Opening PM

/// Opens a project in PM: focuses it and opens its window (launching the app if needed).
///
/// A window, not the focus panel: "open this project" is a request for the whole project, and the
/// panel only ever shows one task of it.
struct OpenProjectIntent: OpenIntent {
    static var title: LocalizedStringResource = "Open Project in PM"
    static var description = IntentDescription("Focuses a project and opens its window.")
    static var openAppWhenRun = true

    @Parameter(title: "Project") var target: ProjectEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        try PMFiles.setFocusedProjectKey(target.id)
        PMFiles.recordRecent(projectKey: target.id, name: target.folder)
        // Name the project explicitly rather than relying on the focus write above having landed and
        // been noticed by the time the URL is handled. Built through `URLComponents` because a project
        // key is a filesystem path — it carries slashes, spaces and whatever else the folder is named.
        var components = URLComponents()
        components.scheme = "pmpanel"
        components.host = "open"
        components.queryItems = [URLQueryItem(name: "project", value: target.id)]
        if let url = components.url { NSWorkspace.shared.open(url) }
        return .result()
    }
}

/// Summons the focus panel (via the app's URL scheme, launching it if needed).
struct ShowPanelIntent: AppIntent {
    static var title: LocalizedStringResource = "Show PM Panel"
    static var description = IntentDescription("Shows the floating focus panel.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        if let url = URL(string: "pmpanel://show") { NSWorkspace.shared.open(url) }
        return .result()
    }
}

// MARK: - Siri / Spotlight phrases

/// Curated spoken phrases so the key intents surface in Spotlight and Siri without setup. Phrases
/// that interpolate a parameter (e.g. `\(\.$project)`) let the new Siri fill it from the entity's
/// suggested values; the same intents also work with no entity (defaulting to the focused one). Every
/// intent above is additionally usable in the Shortcuts app regardless of whether it appears here.
struct PMShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: FocusedProjectInfoIntent(),
                    phrases: ["What am I working on in \(.applicationName)",
                              "What's the focused project in \(.applicationName)"],
                    shortTitle: "Focused Project", systemImageName: "scope")
        AppShortcut(intent: ListOpenTasksIntent(),
                    phrases: ["List my \(.applicationName) tasks",
                              "What are my open tasks in \(.applicationName)",
                              "List open tasks in \(\.$project) in \(.applicationName)"],
                    shortTitle: "Open Tasks", systemImageName: "checklist")
        AppShortcut(intent: WhatsDueIntent(),
                    phrases: ["What's due in \(.applicationName)",
                              "What's due in \(\.$project) in \(.applicationName)"],
                    shortTitle: "What's Due", systemImageName: "calendar")
        AppShortcut(intent: ProjectProgressIntent(),
                    phrases: ["What's my progress in \(.applicationName)",
                              "What's my progress on \(\.$project) in \(.applicationName)"],
                    shortTitle: "Progress", systemImageName: "chart.pie")
        AppShortcut(intent: CompleteTaskIntent(),
                    phrases: ["Complete my \(.applicationName) task",
                              "Complete the focused task in \(.applicationName)",
                              "Complete \(\.$task) in \(.applicationName)"],
                    shortTitle: "Complete Task", systemImageName: "checkmark.circle")
        AppShortcut(intent: AddTaskIntent(),
                    phrases: ["Add a task to \(.applicationName)",
                              "Add a task to \(\.$project) in \(.applicationName)"],
                    shortTitle: "Add Task", systemImageName: "plus.circle")
        AppShortcut(intent: DiveInIntent(),
                    phrases: ["Dive in with \(.applicationName)"],
                    shortTitle: "Dive In", systemImageName: "arrow.down.to.line")
        AppShortcut(intent: FocusProjectIntent(),
                    phrases: ["Focus \(\.$project) in \(.applicationName)"],
                    shortTitle: "Focus Project", systemImageName: "target")
        AppShortcut(intent: OpenProjectIntent(),
                    phrases: ["Open \(\.$target) in \(.applicationName)"],
                    shortTitle: "Open Project", systemImageName: "folder")
        AppShortcut(intent: NewProjectIntent(),
                    phrases: ["Create a project in \(.applicationName)"],
                    shortTitle: "New Project", systemImageName: "folder.badge.plus")
    }
}
