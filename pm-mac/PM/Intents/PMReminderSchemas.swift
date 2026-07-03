// NOTE: This file adopts the `.reminders` App Schema domain, which exists only in the macOS 27
// (Xcode 27) SDK. It cannot compile against earlier SDKs — the schema symbols (`.reminders.list`,
// `.reminders.createReminder`, …) are resolved at COMPILE time, so a runtime `@available(macOS 27)`
// gate is not enough; the whole file must be excluded until the SDK provides them. It is therefore
// wrapped in the custom `PM_REMINDERS_SCHEMAS` compilation condition, which is OFF by default.
//
// To activate once building with Xcode 27+: add `PM_REMINDERS_SCHEMAS` to the PM target's
// SWIFT_ACTIVE_COMPILATION_CONDITIONS (Build Settings → "Active Compilation Conditions"). Verify
// first that this SDK's AppIntents actually vends the `.reminders` domain:
//   grep -h 'static var reminders' \
//     "$(xcrun --sdk macosx --show-sdk-path)"/System/Library/Frameworks/AppIntents.framework/*/Modules/AppIntents.swiftmodule/*-macos.swiftinterface
#if PM_REMINDERS_SCHEMAS
import AppIntents
import Foundation
import GeoToolbox
import PmLib

// Reminders App Schema adoption (macOS 27+). Apple's new Siri understands a fixed catalog of
// "app schema" domains deeply, from years of language-model training. A to-do/project app maps onto
// the `.reminders` domain: a PM project ≈ a reminders *list*, a PM task ≈ a *reminder*. Conforming to
// these schemas (via the `@AppEntity(schema:)` / `@AppIntent(schema:)` macros) gives Siri native
// language understanding of "add buy milk to Groceries", "mark the design task done", etc. — no
// hand-written phrases — and cross-app orchestration, which the custom entities in PMEntities.swift
// can only approximate.
//
// This layer is gated to macOS 27 (where the schemas exist) and sits ALONGSIDE the custom entities,
// which remain the integration for macOS 13–26 and for PM-specific actions (Dive In, Focus, progress)
// that have no schema equivalent. Apple supports mixing schema and non-schema intents. Everything
// resolves through PmLib, reusing the id encoding and lookups from PMEntities.swift.
//
// Deliberately partial: the `.reminders` domain also defines deleteReminders/sections/groups/location
// triggers. PM has no delete-task API and no notion of sections/groups/geofences, so those schemas are
// left unadopted (schema adoption is per-schema, not all-or-nothing).

// MARK: - Due-date conversion (PM stores "yyyy-MM-dd"; schemas use DateComponents)

private func pmDueString(from dc: DateComponents?) -> String? {
    guard let dc, let y = dc.year, let m = dc.month, let d = dc.day else { return nil }
    return String(format: "%04d-%02d-%02d", y, m, d)
}

private func dueComponents(from pm: String?) -> DateComponents? {
    guard let pm else { return nil }
    let parts = pm.split(separator: "-").compactMap { Int($0) }
    guard parts.count == 3 else { return nil }
    var dc = DateComponents()
    dc.year = parts[0]; dc.month = parts[1]; dc.day = parts[2]
    return dc
}

private enum PMSchemaError: Error, CustomLocalizedStringResourceConvertible {
    case noFocusedProject, noDomains, taskNotFound
    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .noFocusedProject: return "No project is focused. Focus one first."
        case .noDomains: return "No domains are configured."
        case .taskNotFound: return "That task no longer exists."
        }
    }
}

/// Resolve an optional list parameter to a PM project (key, folder), defaulting to the focused project.
@available(macOS 27.0, *)
private func listTarget(_ list: PMListEntity?) throws -> (key: String, folder: String) {
    if let list, let folder = PMFiles.projectName(fromKey: list.id) { return (list.id, folder) }
    guard let key = PMFiles.focusedProjectKey(), let folder = PMFiles.projectName(fromKey: key) else {
        throw PMSchemaError.noFocusedProject
    }
    return (key, folder)
}

// MARK: - List type enum (.reminders.listType)

@available(macOS 27.0, *)
@AppEnum(schema: .reminders.listType)
enum PMListType: String {
    case standard
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [.standard: "Standard"]
}

// MARK: - List entity (.reminders.list) ≈ PM project

@available(macOS 27.0, *)
@AppEntity(schema: .reminders.list)
struct PMListEntity {
    static let defaultQuery = PMListEntityQuery()

    let id: String            // the project key "<basePath>:<folderName>"
    var name: String
    var type: PMListType

    init(id: String, name: String, type: PMListType = .standard) {
        self.id = id
        self.name = name
        self.type = type
    }

    init(project p: ProjectEntity) { self.init(id: p.id, name: p.name) }

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

@available(macOS 27.0, *)
struct PMListEntityQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [PMListEntity] {
        let wanted = Set(identifiers)
        return (try ProjectEntity.all()).filter { wanted.contains($0.id) }.map(PMListEntity.init(project:))
    }
    func entities(matching string: String) async throws -> [PMListEntity] {
        let q = string.lowercased()
        return (try ProjectEntity.all())
            .filter { $0.name.lowercased().contains(q) || $0.folder.lowercased().contains(q) }
            .map(PMListEntity.init(project:))
    }
    func suggestedEntities() async throws -> [PMListEntity] {
        (try ProjectEntity.all()).map(PMListEntity.init(project:))
    }
}

// MARK: - Inert stub schemas (section / location trigger)

// The createReminder/updateReminder schemas *require* `section` and `locationTrigger` parameters, and
// the reminder entity requires a `locationTrigger` property — the App Intents metadata processor
// enforces this even though the Swift compiler doesn't. PM has no list sections and no geofenced
// reminders, so these entities exist only to satisfy the required shape: they're never constructed and
// their queries return nothing.

@available(macOS 27.0, *)
@AppEnum(schema: .reminders.locationTriggerEvent)
enum PMLocationTriggerEvent: String {
    case arrive, depart
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [.arrive: "Arrive", .depart: "Depart"]
}

@available(macOS 27.0, *)
@AppEntity(schema: .reminders.locationTrigger)
struct PMLocationTriggerEntity {
    static let defaultQuery = PMLocationTriggerEntityQuery()
    let id: String
    var place: GeoToolbox.PlaceDescriptor
    var event: PMLocationTriggerEvent
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(id)") }
}

@available(macOS 27.0, *)
struct PMLocationTriggerEntityQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [PMLocationTriggerEntity] { [] }
    func entities(matching string: String) async throws -> [PMLocationTriggerEntity] { [] }
    func suggestedEntities() async throws -> [PMLocationTriggerEntity] { [] }
}

@available(macOS 27.0, *)
@AppEntity(schema: .reminders.section)
struct PMSectionEntity {
    static let defaultQuery = PMSectionEntityQuery()
    let id: String
    var name: String
    var list: PMListEntity
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

@available(macOS 27.0, *)
struct PMSectionEntityQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [PMSectionEntity] { [] }
    func entities(matching string: String) async throws -> [PMSectionEntity] { [] }
    func suggestedEntities() async throws -> [PMSectionEntity] { [] }
}

// MARK: - Reminder entity (.reminders.reminder) ≈ PM task

@available(macOS 27.0, *)
@AppEntity(schema: .reminders.reminder)
struct PMReminderEntity {
    static let defaultQuery = PMReminderEntityQuery()

    let id: String            // "<sessionIndex>:<lineIndex>\u{1F}<projectKey>" — same as TaskEntity
    var title: String
    var note: AttributedString?
    var tags: Set<String>
    var urls: [URL]
    var dueDate: DateComponents?
    var recurrence: Calendar.RecurrenceRule?
    var isCompleted: Bool
    var isFlagged: Bool?
    var creationDate: Date?
    var completionDate: Date?
    var list: PMListEntity
    var locationTrigger: PMLocationTriggerEntity?   // required by the schema; always nil for PM

    init(id: String, title: String, isCompleted: Bool, list: PMListEntity, dueDate: DateComponents? = nil) {
        self.id = id
        self.title = title
        self.tags = []
        self.urls = []
        self.isCompleted = isCompleted
        self.dueDate = dueDate
        self.list = list
    }

    /// Build from a PM task in a project.
    init(projectKey: String, folder: String, todo: Todo) {
        self.init(id: "\(todo.sessionIndex):\(todo.lineIndex)\(TaskEntity.idSeparator)\(projectKey)",
                  title: todo.text,
                  isCompleted: todo.checked,
                  list: PMListEntity(id: projectKey, name: projectTitle(fromFolderName: folder)),
                  dueDate: dueComponents(from: todo.dueDate ?? todo.effectiveDueDate))
    }

    /// Bridge from the custom TaskEntity (shares the same id encoding).
    init(task t: TaskEntity) {
        self.init(id: t.id,
                  title: t.text,
                  isCompleted: t.isCompleted,
                  list: PMListEntity(id: t.projectKey, name: projectTitle(fromFolderName: t.projectFolder)),
                  dueDate: dueComponents(from: t.due))
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(list.name)")
    }
}

@available(macOS 27.0, *)
struct PMReminderEntityQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [PMReminderEntity] {
        var coordsByProject: [String: [(session: Int, line: Int)]] = [:]
        for id in identifiers {
            guard let d = TaskEntity.decode(id: id) else { continue }
            coordsByProject[d.projectKey, default: []].append((d.sessionIndex, d.lineIndex))
        }
        var result: [PMReminderEntity] = []
        for (key, coords) in coordsByProject {
            guard let folder = PMFiles.projectName(fromKey: key), let out = try? notesShow(project: folder) else { continue }
            for c in coords {
                if let todo = out.todos.first(where: { $0.sessionIndex == c.session && $0.lineIndex == c.line }) {
                    result.append(PMReminderEntity(projectKey: key, folder: folder, todo: todo))
                }
            }
        }
        return result
    }
    func entities(matching string: String) async throws -> [PMReminderEntity] {
        let q = string.lowercased()
        guard let p = ProjectEntity.focused() else { return [] }
        let tasks = (try? TaskEntity.inProject(folder: p.folder, projectKey: p.id, openOnly: false)) ?? []
        return tasks.filter { $0.text.lowercased().contains(q) }.map(PMReminderEntity.init(task:))
    }
    func suggestedEntities() async throws -> [PMReminderEntity] {
        guard let p = ProjectEntity.focused() else { return [] }
        return ((try? TaskEntity.inProject(folder: p.folder, projectKey: p.id, openOnly: true)) ?? [])
            .map(PMReminderEntity.init(task:))
    }
}

// MARK: - Intents

/// Create a reminder ≈ add a task to a PM project. PM-unsupported inputs (tags, urls, flags,
/// recurrence, images) are accepted by the schema but ignored.
@available(macOS 27.0, *)
@AppIntent(schema: .reminders.createReminder)
struct PMCreateReminderIntent {
    var title: String
    var list: PMListEntity?
    var note: AttributedString?
    var isFlagged: Bool?
    var images: [IntentFile]
    var tags: Set<String>
    var urls: [URL]
    var dueDate: DateComponents?
    var recurrence: Calendar.RecurrenceRule?
    var locationTrigger: PMLocationTriggerEntity?
    var section: PMSectionEntity?

    func perform() async throws -> some ReturnsValue<PMReminderEntity> {
        let (key, folder) = try listTarget(list)
        try addTodo(project: folder, text: title, due: pmDueString(from: dueDate), position: nil)
        PMSpotlight.reindex()
        let out = try notesShow(project: folder)
        // addTodo appends; the created task is the last open line matching the title.
        if let created = out.todos.last(where: { $0.text == title && !$0.checked }) {
            return .result(value: PMReminderEntity(projectKey: key, folder: folder, todo: created))
        }
        return .result(value: PMReminderEntity(id: "0:0\(TaskEntity.idSeparator)\(key)",
                                               title: title, isCompleted: false,
                                               list: PMListEntity(id: key, name: projectTitle(fromFolderName: folder)),
                                               dueDate: dueDate))
    }
}

/// Update a reminder ≈ complete/reopen, retitle, or reschedule a PM task.
@available(macOS 27.0, *)
@AppIntent(schema: .reminders.updateReminder)
struct PMUpdateReminderIntent {
    var target: PMReminderEntity
    var title: String?
    var note: AttributedString?
    var tags: Set<String>?
    var urls: [URL]?
    var dueDate: DateComponents?
    var recurrence: Calendar.RecurrenceRule?
    var isCompleted: Bool?
    var isFlagged: Bool?
    var list: PMListEntity?
    var locationTrigger: PMLocationTriggerEntity?

    func perform() async throws -> some ReturnsValue<PMReminderEntity> {
        guard let d = TaskEntity.decode(id: target.id), let folder = PMFiles.projectName(fromKey: d.projectKey) else {
            throw PMSchemaError.taskNotFound
        }
        if let title { try setTodoText(project: folder, sessionIndex: d.sessionIndex, lineIndex: d.lineIndex, text: title) }
        if let dueDate { try setDueOnTodo(project: folder, sessionIndex: d.sessionIndex, lineIndex: d.lineIndex, due: pmDueString(from: dueDate)) }
        if let isCompleted {
            if isCompleted {
                try completeTodo(project: folder, sessionIndex: d.sessionIndex, lineIndex: d.lineIndex, advanceFocus: false)
            } else {
                try undoTodo(project: folder, sessionIndex: d.sessionIndex, lineIndex: d.lineIndex)
            }
        }
        PMSpotlight.reindex()
        let out = try notesShow(project: folder)
        guard let todo = out.todos.first(where: { $0.sessionIndex == d.sessionIndex && $0.lineIndex == d.lineIndex }) else {
            return .result(value: target)
        }
        return .result(value: PMReminderEntity(projectKey: d.projectKey, folder: folder, todo: todo))
    }
}

/// Create a list ≈ create a new PM project (in the first configured domain).
@available(macOS 27.0, *)
@AppIntent(schema: .reminders.createList)
struct PMCreateListIntent {
    var type: PMListType
    var name: String?

    func perform() async throws -> some ReturnsValue<PMListEntity> {
        let (config, paths) = try loadConfigAndPaths()
        guard let code = Array(config.domains.keys).first else { throw PMSchemaError.noDomains }
        let path = try createProject(config: config, paths: paths, domainCode: code, title: name ?? "New List")
        let folder = (path as NSString).lastPathComponent
        let key = "\((path as NSString).deletingLastPathComponent):\(folder)"
        PMFiles.recordRecent(projectKey: key, name: folder)
        PMSpotlight.reindex()
        return .result(value: PMListEntity(id: key, name: projectTitle(fromFolderName: folder)))
    }
}

/// Update a list ≈ rename a PM project.
@available(macOS 27.0, *)
@AppIntent(schema: .reminders.updateList)
struct PMUpdateListIntent {
    var target: PMListEntity
    var name: String?
    var type: PMListType?

    func perform() async throws -> some ReturnsValue<PMListEntity> {
        guard let folder = PMFiles.projectName(fromKey: target.id) else { throw PMSchemaError.taskNotFound }
        guard let name else { return .result(value: target) }
        _ = try renameProjectTitle(nameOrPrefix: folder, newTitle: name)
        PMSpotlight.reindex()
        // Renaming changes the folder (and therefore the key); re-resolve for the returned entity.
        if let newPath = try? resolveProjectPath(nameOrPrefix: name) {
            let nf = (newPath as NSString).lastPathComponent
            let nk = "\((newPath as NSString).deletingLastPathComponent):\(nf)"
            return .result(value: PMListEntity(id: nk, name: projectTitle(fromFolderName: nf)))
        }
        return .result(value: PMListEntity(id: target.id, name: name))
    }
}

#endif // PM_REMINDERS_SCHEMAS
