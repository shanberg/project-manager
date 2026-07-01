import AppIntents
import AppKit
import Foundation
import PmLib

// App Intents expose PM's full knowledge + lifecycle to Shortcuts, Spotlight, and Siri — a native
// automation layer alongside Raycast. Everything operates on the pm files via PmLib/PMFiles (no
// dependency on the running UI), so the system can run them by launching the agent in the background.
// Every intent is available in the Shortcuts app; the curated subset in `PMShortcuts` also gets
// spoken phrases for Siri/Spotlight.

// MARK: - Shared helpers

/// Formats a date as the `YYYY-MM-DD` string pm stores for due dates.
private func dueString(from date: Date) -> String {
    let f = DateFormatter()
    f.calendar = Calendar(identifier: .gregorian)
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd"
    return f.string(from: date)
}

/// The focused project's folder name, or nil if none is focused.
private func focusedProjectName() -> String? {
    guard let key = PMFiles.focusedProjectKey() else { return nil }
    return PMFiles.projectName(fromKey: key)
}

/// The display title for a focused project's notes (falls back to the folder name).
private func displayTitle(_ output: NotesShowOutput, folder: String) -> String {
    let t = output.notes.title.trimmingCharacters(in: .whitespaces)
    return t.isEmpty ? folder : t
}

private enum PMIntentError: Error, CustomLocalizedStringResourceConvertible {
    case noFocusedProject
    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .noFocusedProject: return "No project is focused. Focus one first."
        }
    }
}

// MARK: - Knowledge (queries)

/// Reports the currently focused project and task.
struct FocusedProjectInfoIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Focused Project"
    static var description = IntentDescription("Reports the currently focused project and task.")

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        guard let name = focusedProjectName() else { return .result(value: "None", dialog: "No project is focused.") }
        let output = try notesShow(project: name)
        let title = displayTitle(output, folder: name)
        var line = "The focused project is \(title)."
        if let key = output.focusedKey {
            let p = key.split(separator: ":").compactMap { Int($0) }
            if p.count == 2, let task = output.todos.first(where: { $0.sessionIndex == p[0] && $0.lineIndex == p[1] }) {
                line = "In \(title), you're focused on “\(task.text)”."
            }
        }
        return .result(value: title, dialog: IntentDialog(stringLiteral: line))
    }
}

/// Lists the open (incomplete) tasks in the focused project.
struct ListOpenTasksIntent: AppIntent {
    static var title: LocalizedStringResource = "List Open Tasks"
    static var description = IntentDescription("Lists the open tasks in the focused project.")

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<[String]> {
        guard let name = focusedProjectName() else { return .result(value: [], dialog: "No project is focused.") }
        let output = try notesShow(project: name)
        let open = output.todos.filter { !$0.checked }.map { $0.text }
        guard !open.isEmpty else {
            return .result(value: [], dialog: "All tasks are complete in \(displayTitle(output, folder: name)).")
        }
        let spoken = open.prefix(8).joined(separator: ", ")
        let more = open.count > 8 ? ", and \(open.count - 8) more" : ""
        return .result(value: open, dialog: IntentDialog(stringLiteral: "Open tasks: \(spoken)\(more)."))
    }
}

/// Reports completion progress (done of total) for the focused project.
struct ProjectProgressIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Project Progress"
    static var description = IntentDescription("Reports how many tasks are done in the focused project.")

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        guard let name = focusedProjectName() else { return .result(value: "0/0", dialog: "No project is focused.") }
        let output = try notesShow(project: name)
        let total = output.todos.count
        let done = output.todos.filter { $0.checked }.count
        let title = displayTitle(output, folder: name)
        return .result(value: "\(done)/\(total)", dialog: IntentDialog(stringLiteral: "\(done) of \(total) tasks done in \(title)."))
    }
}

/// Reports overdue and upcoming due tasks in the focused project.
struct WhatsDueIntent: AppIntent {
    static var title: LocalizedStringResource = "What's Due"
    static var description = IntentDescription("Reports overdue and upcoming due tasks in the focused project.")

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<[String]> {
        guard let name = focusedProjectName() else { return .result(value: [], dialog: "No project is focused.") }
        let output = try notesShow(project: name)
        let dued = output.todos.filter { !$0.checked && ($0.dueDate ?? $0.effectiveDueDate) != nil }
        guard !dued.isEmpty else { return .result(value: [], dialog: "Nothing due in \(displayTitle(output, folder: name)).") }
        let items = dued.map { todo -> String in
            let due = todo.dueDate ?? todo.effectiveDueDate!
            return "\(todo.text) (\(RelativeDue.short(due)))"
        }
        let overdue = dued.filter { RelativeDue.isOverdue($0.dueDate ?? $0.effectiveDueDate!) }.count
        let prefix = overdue > 0 ? "\(overdue) overdue. " : ""
        return .result(value: items, dialog: IntentDialog(stringLiteral: "\(prefix)\(items.prefix(6).joined(separator: ", "))."))
    }
}

/// Lists all active projects.
struct ListProjectsIntent: AppIntent {
    static var title: LocalizedStringResource = "List Projects"
    static var description = IntentDescription("Lists your active projects.")

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<[String]> {
        let (config, paths) = try loadConfigAndPaths()
        let folders = try getProjectFolders(basePath: paths.activePath, domainCodes: Array(config.domains.keys))
        let titles = folders.map { projectTitle(fromFolderName: $0) }
        guard !titles.isEmpty else { return .result(value: [], dialog: "You have no active projects.") }
        return .result(value: titles, dialog: IntentDialog(stringLiteral: "\(titles.count) projects: \(titles.prefix(10).joined(separator: ", "))."))
    }
}

// MARK: - Task lifecycle

/// Completes the focused task and advances focus.
struct CompleteFocusedTaskIntent: AppIntent {
    static var title: LocalizedStringResource = "Complete Focused Task"
    static var description = IntentDescription("Marks the focused task complete and advances focus.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let name = focusedProjectName() else { throw PMIntentError.noFocusedProject }
        let output = try notesShow(project: name)
        guard let key = output.focusedKey else { return .result(dialog: "No focused task.") }
        let p = key.split(separator: ":").compactMap { Int($0) }
        guard p.count == 2 else { return .result(dialog: "No focused task.") }
        let text = output.todos.first { $0.sessionIndex == p[0] && $0.lineIndex == p[1] }?.text ?? "the task"
        try completeTodo(project: name, sessionIndex: p[0], lineIndex: p[1], advanceFocus: true)
        return .result(dialog: IntentDialog(stringLiteral: "Completed “\(text)”."))
    }
}

/// Adds a task to the focused project, optionally with a due date.
struct AddTaskIntent: AppIntent {
    static var title: LocalizedStringResource = "Add Task to Focused Project"
    static var description = IntentDescription("Adds a task to the currently focused project.")

    @Parameter(title: "Task") var text: String
    @Parameter(title: "Due date") var due: Date?

    static var parameterSummary: some ParameterSummary { Summary("Add \(\.$text) to the focused project due \(\.$due)") }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let name = focusedProjectName() else { throw PMIntentError.noFocusedProject }
        try addTodo(project: name, text: text, due: due.map(dueString(from:)), position: nil)
        return .result(dialog: IntentDialog(stringLiteral: "Added “\(text)”."))
    }
}

/// Moves focus to the first open leaf under the focused task (else the first open leaf anywhere) —
/// mirrors the "Dive In" command.
struct DiveInIntent: AppIntent {
    static var title: LocalizedStringResource = "Dive In"
    static var description = IntentDescription("Moves focus to the next actionable leaf task.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let name = focusedProjectName() else { throw PMIntentError.noFocusedProject }
        let list = try notesShow(project: name).todos
        guard !list.isEmpty else { return .result(dialog: "No tasks.") }
        func isLeaf(_ i: Int) -> Bool {
            let n = i + 1
            return n >= list.count || list[n].sessionIndex != list[i].sessionIndex || list[n].depth <= list[i].depth
        }
        func focus(_ t: Todo) throws -> String {
            try focusTodo(project: name, sessionIndex: t.sessionIndex, lineIndex: t.lineIndex)
            return "Focused on “\(t.text)”."
        }
        if let fi = list.firstIndex(where: { $0.isFocused }) {
            let fd = list[fi].depth
            var j = fi + 1
            while j < list.count, list[j].sessionIndex == list[fi].sessionIndex, list[j].depth > fd {
                if !list[j].checked && isLeaf(j) { return .result(dialog: IntentDialog(stringLiteral: try focus(list[j]))) }
                j += 1
            }
        }
        for i in list.indices where !list[i].checked && isLeaf(i) {
            return .result(dialog: IntentDialog(stringLiteral: try focus(list[i])))
        }
        return .result(dialog: "No open leaf task to dive into.")
    }
}

/// Sets (or updates) the due date on the focused task.
struct SetDueOnFocusedTaskIntent: AppIntent {
    static var title: LocalizedStringResource = "Set Due Date on Focused Task"
    static var description = IntentDescription("Sets the due date on the focused task.")

    @Parameter(title: "Due date") var due: Date

    static var parameterSummary: some ParameterSummary { Summary("Set the focused task due \(\.$due)") }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let name = focusedProjectName() else { throw PMIntentError.noFocusedProject }
        let output = try notesShow(project: name)
        guard let key = output.focusedKey else { return .result(dialog: "No focused task.") }
        let p = key.split(separator: ":").compactMap { Int($0) }
        guard p.count == 2 else { return .result(dialog: "No focused task.") }
        let value = dueString(from: due)
        try setDueOnTodo(project: name, sessionIndex: p[0], lineIndex: p[1], due: value)
        return .result(dialog: IntentDialog(stringLiteral: "Due \(value) set on the focused task."))
    }
}

// MARK: - Project lifecycle

/// Focuses a project by name or prefix (fuzzy-resolved by PmLib, same as the CLI/Raycast).
struct FocusProjectIntent: AppIntent {
    static var title: LocalizedStringResource = "Focus Project"
    static var description = IntentDescription("Sets the focused project by name or prefix.")

    @Parameter(title: "Project") var project: String

    static var parameterSummary: some ParameterSummary { Summary("Focus \(\.$project)") }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let path = try resolveProjectPath(nameOrPrefix: project)
        let folder = (path as NSString).lastPathComponent
        let key = "\((path as NSString).deletingLastPathComponent):\(folder)"
        try PMFiles.setFocusedProjectKey(key)
        PMFiles.recordRecent(projectKey: key, name: folder)
        return .result(dialog: IntentDialog(stringLiteral: "Focused \(projectTitle(fromFolderName: folder))."))
    }
}

/// Creates a new project and focuses it.
struct NewProjectIntent: AppIntent {
    static var title: LocalizedStringResource = "New Project"
    static var description = IntentDescription("Creates a new project and focuses it.")

    @Parameter(title: "Title") var projectTitleParam: String
    @Parameter(title: "Domain code") var domain: String?

    static var parameterSummary: some ParameterSummary { Summary("Create project \(\.$projectTitleParam) in \(\.$domain)") }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let (config, paths) = try loadConfigAndPaths()
        guard let code = domain ?? Array(config.domains.keys).first else {
            return .result(dialog: "No domains are configured.")
        }
        let path = try createProject(config: config, paths: paths, domainCode: code, title: projectTitleParam)
        let folder = (path as NSString).lastPathComponent
        let key = "\((path as NSString).deletingLastPathComponent):\(folder)"
        try? PMFiles.setFocusedProjectKey(key)
        PMFiles.recordRecent(projectKey: key, name: folder)
        return .result(dialog: IntentDialog(stringLiteral: "Created and focused “\(projectTitleParam)”."))
    }
}

// MARK: - Panel

/// Summons the PM panel (via the app's URL scheme, launching it if needed).
struct ShowPanelIntent: AppIntent {
    static var title: LocalizedStringResource = "Show PM Panel"
    static var description = IntentDescription("Opens the PM panel.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        if let url = URL(string: "pmpanel://show") { NSWorkspace.shared.open(url) }
        return .result()
    }
}

// MARK: - Siri / Spotlight phrases

/// Curated spoken phrases so the key intents surface in Spotlight and Siri without setup. (Every
/// intent above is also usable in the Shortcuts app regardless of whether it appears here.)
struct PMShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: FocusedProjectInfoIntent(),
                    phrases: ["What am I working on in \(.applicationName)",
                              "What's the focused project in \(.applicationName)"],
                    shortTitle: "Focused Project", systemImageName: "scope")
        AppShortcut(intent: ListOpenTasksIntent(),
                    phrases: ["List my \(.applicationName) tasks", "What are my open tasks in \(.applicationName)"],
                    shortTitle: "Open Tasks", systemImageName: "checklist")
        AppShortcut(intent: WhatsDueIntent(),
                    phrases: ["What's due in \(.applicationName)"],
                    shortTitle: "What's Due", systemImageName: "calendar")
        AppShortcut(intent: ProjectProgressIntent(),
                    phrases: ["What's my progress in \(.applicationName)"],
                    shortTitle: "Progress", systemImageName: "chart.pie")
        AppShortcut(intent: CompleteFocusedTaskIntent(),
                    phrases: ["Complete my \(.applicationName) task", "Complete the focused task in \(.applicationName)"],
                    shortTitle: "Complete Task", systemImageName: "checkmark.circle")
        AppShortcut(intent: AddTaskIntent(),
                    phrases: ["Add a task to \(.applicationName)"],
                    shortTitle: "Add Task", systemImageName: "plus.circle")
        AppShortcut(intent: DiveInIntent(),
                    phrases: ["Dive in with \(.applicationName)"],
                    shortTitle: "Dive In", systemImageName: "arrow.down.to.line")
        AppShortcut(intent: FocusProjectIntent(),
                    phrases: ["Focus a project in \(.applicationName)"],
                    shortTitle: "Focus Project", systemImageName: "target")
        AppShortcut(intent: NewProjectIntent(),
                    phrases: ["Create a project in \(.applicationName)"],
                    shortTitle: "New Project", systemImageName: "folder.badge.plus")
        AppShortcut(intent: ShowPanelIntent(),
                    phrases: ["Show \(.applicationName) panel", "Open \(.applicationName)"],
                    shortTitle: "Show Panel", systemImageName: "sidebar.right")
    }
}
