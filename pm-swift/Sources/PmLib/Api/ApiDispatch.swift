import CryptoKit
import Foundation

// MARK: - The dispatcher
//
// One entry point for every surface. The panel and App Intents call it with native types; the CLI
// and anything over stdio call it with JSON that decodes to the same types. What each adapter adds is
// transport, not behaviour.
//
// Document mutations are composed here from the *pure* transforms in `NotesTodos` and `NotesRawEdit`,
// not from the service layer in `NotesService`. The service layer reads, mutates and writes in one
// step, which is right for a caller that wants the write; the dispatcher needs the middle of that
// sandwich on its own, because that is what makes a dry run the same code path as the write rather
// than a description of it.

/// Run an action.
///
/// - Throws: `ApiError` — every failure, including those the domain throws, mapped onto one set of
///   codes a client can branch on.
public func performApi(_ action: String, _ input: ApiInput = ApiInput(),
                       options: ApiOptions = ApiOptions()) throws -> ApiResult {
    guard let spec = ApiRegistry.spec(action) else {
        throw ApiError(.unknownAction, "No such action: \(action)")
    }
    try validate(input, against: spec)
    guard spec.tier != .affordance else {
        throw ApiError(.unsupportedAction,
                       "\(action) is a request to a running app, which this adapter can't make.",
                       detail: .string(spec.tier.rawValue))
    }
    do {
        return try run(spec, input, options)
    } catch {
        throw ApiError.from(error)
    }
}

// MARK: - Validation

/// Check the input against the same table the schema is published from.
private func validate(_ input: ApiInput, against spec: ApiActionSpec) throws {
    let values = fieldValues(input)
    for field in spec.fields {
        let value = values[field.name] ?? nil
        if field.required, value == nil {
            throw ApiError(.missingField, "\(spec.name) needs \(field.name): \(field.description)",
                           detail: .string(field.name))
        }
        if field.name == "tasks", let list = input.tasks, list.isEmpty {
            throw ApiError(.invalidField, "tasks was empty — there's nothing to act on.",
                           detail: .string("tasks"))
        }
        if let allowed = field.allowed, let given = value?.stringValue, !allowed.contains(given) {
            throw ApiError(.invalidField,
                           "\(field.name) must be one of \(allowed.joined(separator: ", ")), not \(given)",
                           detail: .string(field.name))
        }
    }
    guard spec.oneOf.isEmpty || spec.oneOf.filter({ values[$0] ?? nil != nil }).count == 1 else {
        throw ApiError(.missingField,
                       "\(spec.name) needs exactly one of: \(spec.oneOf.joined(separator: ", "))",
                       detail: .array(spec.oneOf.map { .string($0) }))
    }
}

/// The input as a bag of values, so validation reads it the same way the schema describes it.
private func fieldValues(_ input: ApiInput) -> [String: JSONValue?] {
    [
        "project": input.project.map(JSONValue.string),
        "task": input.task.map { _ in JSONValue.bool(true) },
        "tasks": input.tasks.map { _ in JSONValue.bool(true) },
        "revision": input.revision.map(JSONValue.string),
        "anchor": input.anchor.map { _ in JSONValue.bool(true) },
        "position": input.position.map(JSONValue.string),
        "session": input.session.map(JSONValue.string),
        "text": input.text.map(JSONValue.string),
        "due": input.due.map(JSONValue.string),
        "label": input.label.map(JSONValue.string),
        "prose": input.prose.map(JSONValue.string),
        "title": input.title.map(JSONValue.string),
        "domain": input.domain.map(JSONValue.string),
        "scope": input.scope.map(JSONValue.string),
        "key": input.key.map(JSONValue.string),
        "value": input.value,
        "limit": input.limit.map { JSONValue.number(Double($0)) },
        "sessionOrdinal": input.sessionOrdinal.map { JSONValue.number(Double($0)) },
        "advanceFocus": input.advanceFocus.map(JSONValue.bool),
        "clearDue": input.clearDue.map(JSONValue.bool),
        "includeCompleted": input.includeCompleted.map(JSONValue.bool),
        "query": input.query.map(JSONValue.string),
        "entry": input.entry.map(JSONValue.string),
        "now": input.now.map(JSONValue.string),
    ]
}

// MARK: - Running

private func run(_ spec: ApiActionSpec, _ input: ApiInput, _ options: ApiOptions) throws -> ApiResult {
    switch spec.name {
    // MARK: Task mutations
    case "task.add":
        return try document(spec, input, options) { rawText in
            guard let text = input.text else { throw PmError.emptyTodoText }
            if let d = input.due, !isValidTodoDue(d) { throw PmError.invalidTodoDue(d) }
            if let anchor = input.anchor {
                let at = try resolveTaskRef(anchor.ref, rawText: rawText)
                let kind: TaskInsertPosition = {
                    switch input.position {
                    case "before": return .before
                    case "child": return .child
                    default: return .after
                    }
                }()
                guard let out = insertTaskRelative(rawText: rawText, anchorSessionIndex: at.sessionIndex,
                                                   anchorLineIndex: at.lineIndex, text: text,
                                                   due: input.due, position: kind) else {
                    throw ApiError(.writeFailed, "Couldn't insert beside that task.")
                }
                let focused = kind == .child
                    ? try focusing(out.rawText, sessionIndex: out.sessionIndex, lineIndex: out.lineIndex)
                    : out.rawText
                return Outcome(rawText: focused, relocated: at.relocated)
            }
            let (withSession, sessionIndex) = try todaySession(in: rawText)
            guard let out = appendTaskToSession(rawText: withSession, sessionIndex: sessionIndex,
                                                text: text, due: input.due) else {
                throw ApiError(.writeFailed, "Couldn't add to today's session.")
            }
            return Outcome(rawText: try focusing(out.rawText, sessionIndex: out.sessionIndex,
                                                 lineIndex: out.lineIndex))
        }

    case "task.complete":
        return try editing(spec, input, options) { notes, at in
            try completeTodoWithDescendants(notes: notes, sessionIndex: at.sessionIndex,
                                            lineIndex: at.lineIndex,
                                            advanceFocus: input.advanceFocus ?? true)
        }
    case "task.reopen":
        return try editing(spec, input, options) { notes, at in
            try undoTodoAt(notes: notes, sessionIndex: at.sessionIndex, lineIndex: at.lineIndex)
        }
    case "task.focus":
        return try editing(spec, input, options) { notes, at in
            applyFocusToTodoAt(notes: notes, sessionIndex: at.sessionIndex, lineIndex: at.lineIndex)
        }
    case "task.setText":
        return try editing(spec, input, options) { notes, at in
            guard let text = input.text, !text.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw PmError.emptyTodoText
            }
            return setTextOnTodoAt(notes: notes, sessionIndex: at.sessionIndex,
                                   lineIndex: at.lineIndex, text: text)
        }
    case "task.setDue":
        return try editing(spec, input, options) { notes, at in
            let due = (input.clearDue == true) ? nil : input.due
            if let d = due, !isValidTodoDue(d) { throw PmError.invalidTodoDue(d) }
            return setDueOnTodoAt(notes: notes, sessionIndex: at.sessionIndex,
                                  lineIndex: at.lineIndex, due: due)
        }
    case "task.diveIn":
        return try document(spec, input, options) { rawText in
            let todos = try parseTodos(notes: normalizeFocusMarker(notes: parseNotes(markdown: rawText)))
            guard let next = nextDiveInLeaf(todos: todos) else { return Outcome(rawText: rawText) }
            return Outcome(rawText: try focusing(rawText, sessionIndex: next.sessionIndex,
                                                 lineIndex: next.lineIndex))
        }

    case "task.wrap":
        return try document(spec, input, options) { rawText in
            guard let text = input.text, !text.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw PmError.emptyTodoText
            }
            let at = try resolveTaskRef(try taskRef(input), rawText: rawText)
            guard let out = wrapTaskPreservingFormat(rawText: rawText, sessionIndex: at.sessionIndex,
                                                     lineIndex: at.lineIndex, parentText: text) else {
                throw ApiError(.writeFailed, "Couldn't wrap that task.")
            }
            return Outcome(rawText: out, relocated: at.relocated)
        }
    case "task.unwrap":
        return try document(spec, input, options) { rawText in
            let at = try resolveTaskRef(try taskRef(input), rawText: rawText)
            guard let out = unwrapTaskPreservingFormat(rawText: rawText, sessionIndex: at.sessionIndex,
                                                       lineIndex: at.lineIndex) else {
                throw ApiError(.writeFailed, "That task has no children to promote.")
            }
            return Outcome(rawText: out, relocated: at.relocated)
        }
    case "task.delete":
        return try document(spec, input, options) { rawText in
            var text = rawText
            var relocated = false
            for reference in try references(input) {
                guard let at = try resolve(reference, in: text, batch: input.tasks != nil) else { continue }
                relocated = relocated || at.relocated
                guard let out = deleteSubtreePreservingFormat(rawText: text, sessionIndex: at.sessionIndex,
                                                              lineIndex: at.lineIndex) else {
                    throw ApiError(.writeFailed, "Couldn't delete that task.")
                }
                text = out
            }
            return Outcome(rawText: text, relocated: relocated)
        }

    // MARK: Sessions
    case "session.start":
        return try document(spec, input, options) { rawText in
            let today = formatSessionDate()
            let notes = try parseNotes(markdown: rawText)
            // Reported either way, so a caller can ask for today's session and use the answer without
            // knowing whether it had to be made — and without formatting today's date to find it.
            func describe(_ markdown: String) throws -> JSONValue {
                let sessions = try parseNotes(markdown: markdown).sessions
                guard let index = sessions.firstIndex(where: { $0.date == today }) else { return .null }
                return .object([
                    "date": .string(sessions[index].date),
                    "isoDate": sessionISODate(heading: sessions[index].date).map(JSONValue.string) ?? .null,
                    "label": .string(sessions[index].label),
                    "index": .number(Double(index)),
                ])
            }
            if notes.sessions.contains(where: { $0.date == today }) {
                return Outcome(rawText: rawText, note: .statement("Today's session was already there"),
                               data: try describe(rawText))
            }
            guard let out = sessionAddPreservingFormat(rawText: rawText, label: input.label ?? "",
                                                       date: Date()) else {
                throw PmError.notesNotFound("## Sessions")
            }
            return Outcome(rawText: out,
                           note: Phrase(past: "Started today's session", future: "start today's session"),
                           data: try describe(out))
        }
    case "session.note":
        return try document(spec, input, options) { rawText in
            guard let prose = input.prose, !prose.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw PmError.emptySessionNote
            }
            guard let out = try appendSessionNotePreservingFormat(rawText: rawText, prose: prose) else {
                throw PmError.notesNotFound("## Sessions")
            }
            return Outcome(rawText: out, note: Phrase(past: "Added a note to today's session", future: "add a note to today's session"))
        }
    case "session.rename":
        return try document(spec, input, options) { rawText in
            let notes = try parseNotes(markdown: rawText)
            let index = try sessionIndex(input, in: notes)
            guard let out = renameSessionPreservingFormat(rawText: rawText, sessionIndex: index,
                                                          label: input.label ?? "") else {
                throw ApiError(.writeFailed, "Couldn't rename that session.")
            }
            return Outcome(rawText: out, note: Phrase(past: "Renamed the session", future: "rename the session"))
        }
    case "session.delete":
        return try document(spec, input, options) { rawText in
            let notes = try parseNotes(markdown: rawText)
            let index = try sessionIndex(input, in: notes)
            guard let out = deleteSessionPreservingFormat(rawText: rawText, sessionIndex: index) else {
                throw ApiError(.writeFailed, "That session still has tasks in it.")
            }
            return Outcome(rawText: out, note: Phrase(past: "Deleted the session", future: "delete the session"))
        }

    // MARK: Notes
    case "notes.setDetail":
        return try document(spec, input, options) { rawText in
            var notes = try parseNotes(markdown: rawText)
            try setDetail(&notes, key: input.key ?? "", value: input.value)
            guard let out = try writeNotesPreservingFormat(rawText: rawText, incoming: notes) else {
                throw ApiError(.writeFailed, "Couldn't splice that section.")
            }
            return Outcome(rawText: out, note: Phrase(past: "Updated \(input.key ?? "the notes")", future: "update \(input.key ?? "the notes")"))
        }
    case "notes.addLink":
        return try document(spec, input, options) { rawText in
            guard let url = input.text, !url.isEmpty else { throw PmError.emptyTodoText }
            var notes = try parseNotes(markdown: rawText)
            notes.links.append(LinkEntry(label: input.label ?? url, url: url))
            guard let out = try writeNotesPreservingFormat(rawText: rawText, incoming: notes) else {
                throw ApiError(.writeFailed, "Couldn't add the link.")
            }
            return Outcome(rawText: out, note: Phrase(past: "Added the link", future: "add the link"))
        }

    // MARK: Projects
    case "project.create":
        let (config, paths) = try loadConfigAndPaths()
        guard let domain = input.domain, config.domains[domain] != nil else {
            throw ApiError(.invalidField, "Unknown domain: \(input.domain ?? "")", detail: .string("domain"))
        }
        let path = try createProject(config: config, paths: paths, domainCode: domain,
                                     title: input.title ?? "")
        let summary = "Created \((path as NSString).lastPathComponent)."
        ApiJournal.recordMetadata(action: spec.name, project: path, summary: summary, source: options.source)
        return ApiResult(action: spec.name, summary: summary, data: .string(path))
    case "project.rename":
        let path = try renameProjectTitle(nameOrPrefix: input.project ?? "", newTitle: input.title ?? "")
        let summary = "Renamed to \((path as NSString).lastPathComponent)."
        ApiJournal.recordMetadata(action: spec.name, project: path, summary: summary, source: options.source)
        return ApiResult(action: spec.name, summary: summary, data: .string(path))
    case "project.archive", "project.unarchive":
        let archiving = spec.name == "project.archive"
        let (_, paths) = try loadConfigAndPaths()
        let folder = try folderName(of: input.project ?? "")
        let path = try moveProject(named: folder, from: archiving ? .active : .archive,
                                   to: archiving ? .archive : .active, paths: paths)
        let summary = "\(archiving ? "Archived" : "Restored") \(folder)."
        ApiJournal.recordMetadata(action: spec.name, project: path, summary: summary, source: options.source)
        return ApiResult(action: spec.name, summary: summary, data: .string(path))
    case "project.focus":
        let folder = try folderName(of: input.project ?? "")
        let (_, paths) = try loadConfigAndPaths()
        try setFocusedProject(key: "\(paths.activePath):\(folder)")
        return ApiResult(action: spec.name, summary: "Focused \(folder).")

    case "task.search":
        let scope = input.scope ?? "all"
        let hits = try searchableTasks(includeArchived: scope != "active",
                                       includeActive: scope != "archive")
        // The bias toward the project you're in is the focused one unless a caller says otherwise —
        // the same tie-break the quick bar has always applied, now available to everything.
        let focused = try input.project.map(projectKey(of:)) ?? focusedProjectKey()
        let ranked = TaskSearch.rank(hits, query: input.query ?? "", focusedProjectKey: focused)
            .prefix(input.limit ?? 20)
        return ApiResult(action: spec.name,
                         summary: ranked.isEmpty
                             ? "Nothing matches “\(input.query ?? "")”."
                             : "\(ranked.count) match\(ranked.count == 1 ? "" : "es").",
                         data: try JSONValue.encoding(Array(ranked)))

    case "capture.parse":
        let line = input.text ?? ""
        let now = try input.now.map(parseSessionDateArgument) ?? Date()
        // The trailing `@project` comes off first, exactly as the quick bar does it, so a line that
        // names a project doesn't leave the name inside the task's text.
        let split = QuickCaptureParser.splitTarget(line)
        let parsed = QuickCaptureParser.parse(split?.text ?? line, now: now)
        return ApiResult(action: spec.name,
                         summary: parsed.text.isEmpty ? "Nothing to capture." : parsed.text,
                         data: .object([
                            "text": .string(parsed.text),
                            "due": parsed.due.map(JSONValue.string) ?? .null,
                            "unreadableDue": parsed.unreadableDue.map(JSONValue.string) ?? .null,
                            "projectQuery": (split?.projectQuery).map(JSONValue.string) ?? .null,
                         ]))

    // MARK: Journal
    case "journal.list":
        let entries = ApiJournal.entries(limit: input.limit ?? 50,
                                         project: try input.project.map(projectPath(of:)))
        return ApiResult(action: spec.name,
                         summary: entries.isEmpty ? "Nothing written yet." : "\(entries.count) write\(entries.count == 1 ? "" : "s").",
                         data: try JSONValue.encoding(entries))

    case "journal.undo":
        let project = try input.project.map(projectPath(of:))
        let candidate = input.entry.flatMap(ApiJournal.entry(id:))
            ?? ApiJournal.nextToReverse(project: project)
        guard let entry = candidate else {
            throw ApiError(.staleReference, "There's no write on record to reverse.")
        }
        guard entry.undoable, let notesPath = entry.notesPath,
              let restored = ApiJournal.snapshot(entry.revisionBefore) else {
            throw ApiError(.unsupportedAction,
                           "\(entry.action) can't be reversed — there's no document behind it.",
                           detail: .string(entry.id))
        }
        let current = try String(contentsOfFile: notesPath, encoding: .utf8)
        // The safety the journal exists to provide: reverse only what is still exactly as this write
        // left it. Anything else and an undo would be discarding an edit made since, unseen.
        guard revision(of: current) == entry.revisionAfter else {
            throw ApiError(.conflict,
                           "That file has changed since this write, so reversing it would discard the change.",
                           detail: .string(entry.id))
        }
        let before = try parseTodos(notes: normalizeFocusMarker(notes: parseNotes(markdown: current)))
        let after = try parseTodos(notes: normalizeFocusMarker(notes: parseNotes(markdown: restored)))
        let undone = diffTodos(before: before, after: after)
        // Resolved before the dry-run check, not inside it, so a preview fails exactly where the real
        // reversal would. An entry names a notes file directly — it may belong to a project that has
        // since been renamed or archived, which is precisely when you want the reversal to still work.
        guard let config = try loadConfig() else { throw PmError.configNotFound }
        let io = makeNotesIO(notesPath: notesPath, config: config)
        if !options.dryRun {
            try io.writeContent(path: notesPath, content: restored)
            // The reversal is itself a write, and is journaled as one — so it can be reversed too,
            // and so the record doesn't quietly omit the biggest changes anybody makes.
            ApiJournal.record(action: spec.name, project: entry.project, notesPath: notesPath,
                              summary: reversalSummary(of: entry), before: current, after: restored,
                              changed: undone, source: options.source, reverses: entry.id)
        }
        return ApiResult(action: spec.name,
                         summary: options.dryRun
                             ? "Would reverse: \(strippedSummary(of: entry))."
                             : reversalSummary(of: entry) + ".",
                         revision: revision(of: restored), changed: undone,
                         focus: after.first(where: \.isFocused).map(reference(to:)),
                         dryRun: options.dryRun,
                         data: try JSONValue.encoding(entry))

    // MARK: Queries
    case "project.list":
        let (config, paths) = try loadConfigAndPaths(skipPathValidation: true)
        let codes = Array(config.domains.keys)
        let scope = input.scope ?? "active"
        var entries: [JSONValue] = []
        for (name, base) in [("active", paths.activePath), ("archive", paths.archivePath)]
        where scope == "all" || scope == name {
            for folder in (try? getProjectFolders(basePath: base, domainCodes: codes)) ?? [] {
                entries.append(.object([
                    "folder": .string(folder),
                    "name": .string(projectTitle(fromFolderName: folder)),
                    "scope": .string(name),
                    "path": .string((base as NSString).appendingPathComponent(folder)),
                ]))
            }
        }
        return ApiResult(action: spec.name, summary: "\(entries.count) project\(entries.count == 1 ? "" : "s").",
                         data: .array(entries))
    case "project.get":
        let folder = try folderName(of: input.project ?? "")
        let path = try resolveProjectPath(nameOrPrefix: input.project ?? "")
        return ApiResult(action: spec.name, summary: folder, data: .object([
            "folder": .string(folder),
            "name": .string(projectTitle(fromFolderName: folder)),
            "path": .string(path),
            "notesPath": (try resolveNotesPath(projectPath: path)).map(JSONValue.string) ?? .null,
        ]))
    case "notes.get":
        let read = try readProject(input)
        return ApiResult(action: spec.name, summary: read.output.notes.title,
                         revision: read.revision, data: try JSONValue.encoding(read.output))
    case "task.list":
        let read = try readProject(input)
        let output = read.output
        var todos = output.todos
        if input.includeCompleted != true { todos = todos.filter { !$0.checked } }
        if let limit = input.limit { todos = Array(todos.prefix(limit)) }
        return ApiResult(action: spec.name,
                         summary: "\(todos.count) task\(todos.count == 1 ? "" : "s").",
                         revision: read.revision, data: try JSONValue.encoding(todos))
    case "task.whatsDue":
        let read = try readProject(input)
        var due = read.output.todos.filter { !$0.checked && $0.effectiveDueDate != nil }
        due.sort { ($0.effectiveDueDate ?? "") < ($1.effectiveDueDate ?? "") }
        if let limit = input.limit { due = Array(due.prefix(limit)) }
        return ApiResult(action: spec.name,
                         summary: due.isEmpty ? "Nothing due." : "\(due.count) due.",
                         revision: read.revision, data: try JSONValue.encoding(due))
    case "task.progress":
        let read = try readProject(input)
        let done = read.output.todos.filter(\.checked).count
        return ApiResult(action: spec.name, summary: "\(done) of \(read.output.todos.count) done.",
                         revision: read.revision,
                         data: .object(["done": .number(Double(done)),
                                        "total": .number(Double(read.output.todos.count))]))
    case "focus.get":
        guard let folder = focusedProjectFolder() else {
            return ApiResult(action: spec.name, summary: "No focused project.", data: .null)
        }
        let output = try? notesShow(project: folder)
        let focused = output?.todos.first(where: \.isFocused)
        return ApiResult(action: spec.name,
                         summary: focused.map { "\(folder): \($0.text)" } ?? folder,
                         data: .object([
                            "project": .string(folder),
                            "task": focused.map { (try? JSONValue.encoding($0)) ?? .null } ?? .null,
                         ]))
    case "config.get":
        guard let config = try loadConfig() else { throw PmError.configNotFound }
        return ApiResult(action: spec.name, summary: "Configuration.",
                         data: try JSONValue.encoding(config))
    case "config.set":
        guard var config = try loadConfig() else { throw PmError.configNotFound }
        try setConfigValue(config: &config, key: input.key ?? "", value: try plain(input.value))
        if !options.dryRun {
            try saveConfig(config)
            ApiJournal.recordMetadata(action: spec.name, project: nil,
                                      summary: "Set \(input.key ?? "").", source: options.source)
        }
        return ApiResult(action: spec.name, summary: "Set \(input.key ?? "").", dryRun: options.dryRun)

    default:
        throw ApiError(.unsupportedAction, "\(spec.name) isn't implemented yet.")
    }
}

// MARK: - The document pipeline

/// What an action did to the markdown.
struct Outcome {
    var rawText: String
    var relocated: Bool = false
    /// A phrase for actions the task diff can't describe — a session renamed, a note appended.
    var note: Phrase?
    /// Anything the action knows that a diff of tasks can't show — which session it just opened.
    var data: JSONValue?
}

/// Read once, transform, diff, and write unless this is a dry run.
///
/// The single place a notes file is written by the contract, which is what lets `dryRun` be the same
/// path minus its last step rather than a second implementation that predicts what the first would do.
private func document(_ spec: ApiActionSpec, _ input: ApiInput, _ options: ApiOptions,
                      _ apply: (String) throws -> Outcome) throws -> ApiResult {
    let handle = try resolveNotesHandle(project: try resolvedProject(input))
    let rawText = try handle.io.readContent(path: handle.notesPath)
    // Checked here rather than per action, because it is the same claim whatever the action: "this is
    // the document I was looking at". A digest says a task is still that task; only this says the
    // tasks around it are too, which is what acting on a selection depends on.
    if let expected = input.revision, expected != revision(of: rawText) {
        throw ApiError(.conflict,
                       "This project has changed since you read it, so nothing was written.",
                       detail: .string(revision(of: rawText)))
    }
    let before = try parseTodos(notes: normalizeFocusMarker(notes: parseNotes(markdown: rawText)))

    let outcome = try apply(rawText)
    let after = try parseTodos(notes: normalizeFocusMarker(notes: parseNotes(markdown: outcome.rawText)))
    let changes = diffTodos(before: before, after: after)

    let phrase = outcome.note ?? summarize(action: spec.name, changes: changes,
                                           batch: (input.tasks?.count ?? 1) > 1)
    if !options.dryRun, outcome.rawText != rawText {
        try handle.io.writeContent(path: handle.notesPath, content: outcome.rawText)
        // After the write, never before: a journal entry for a write that then failed would be a
        // record of something that didn't happen, and an undo offered for it would do harm.
        ApiJournal.record(action: spec.name, project: handle.projectPath, notesPath: handle.notesPath,
                          summary: phrase.past, before: rawText, after: outcome.rawText,
                          changed: changes, source: options.source)
    }
    return ApiResult(action: spec.name,
                     summary: phrase.sentence(dryRun: options.dryRun),
                     revision: revision(of: outcome.rawText),
                     changed: changes,
                     focus: after.first(where: \.isFocused).map(reference(to:)),
                     relocated: outcome.relocated,
                     dryRun: options.dryRun,
                     data: outcome.data)
}

/// The `document` pipeline for the actions that are a `ProjectNotes -> ProjectNotes` transform.
///
/// One reference or a list of them, applied in order against the text as it evolves — so a reference
/// later in the batch is resolved against what the earlier ones left behind, not against the document
/// as it was when the caller read it.
private func editing(_ spec: ApiActionSpec, _ input: ApiInput, _ options: ApiOptions,
                     _ mutate: @escaping (ProjectNotes, ResolvedTaskRef) throws -> ProjectNotes) throws -> ApiResult {
    try document(spec, input, options) { rawText in
        var text = rawText
        var relocated = false
        for reference in try references(input) {
            guard let at = try resolve(reference, in: text, batch: input.tasks != nil) else { continue }
            relocated = relocated || at.relocated
            if let updated = try editTodosPreservingFormat(rawText: text, mutate: { notes in
                try mutate(normalizeFocusMarker(notes: notes), at)
            }) {
                text = updated
            }
        }
        return Outcome(rawText: text, relocated: relocated)
    }
}

/// The tasks an action was asked to act on: one, or a list.
private func references(_ input: ApiInput) throws -> [TaskRefInput] {
    if let tasks = input.tasks { return tasks }
    guard let task = input.task else {
        throw ApiError(.missingField, "This action needs a task.", detail: .string("task"))
    }
    return [task]
}

/// Resolve one of a batch's references, or nil when it no longer names anything.
///
/// In a batch a missing task is expected rather than exceptional: completing a parent completes its
/// children, deleting one removes them, so a reference to a child that came along in the same
/// selection has already been dealt with by the time its turn arrives. Skipping is the behaviour that
/// makes "act on this selection" mean what a person means by it.
///
/// That does mean a batch won't notice a task that vanished for some *other* reason — which is what
/// `revision` is for, and why the two arrived together.
private func resolve(_ reference: TaskRefInput, in text: String, batch: Bool) throws -> ResolvedTaskRef? {
    do {
        return try resolveTaskRef(reference.ref, rawText: text)
    } catch let error as PmError {
        if case .staleReference = error, batch { return nil }
        throw error
    }
}

// MARK: - Pieces

private func taskRef(_ input: ApiInput) throws -> TaskRef {
    guard let task = input.task else {
        throw ApiError(.missingField, "This action needs a task.", detail: .string("task"))
    }
    return task.ref
}

/// The project to act on: the one named, or the focused one.
private func resolvedProject(_ input: ApiInput) throws -> String {
    if let project = input.project, !project.isEmpty { return project }
    guard let focused = focusedProjectFolder() else {
        throw ApiError(.missingField, "No project given, and no project is focused.",
                       detail: .string("project"))
    }
    return focused
}

/// A project's tasks, and the revision of the document they came from.
///
/// Every read of a document reports its revision, because the guard a write can ask for is only
/// worth having if the read tells you what to ask about. One read of the file serves both.
private func readProject(_ input: ApiInput) throws -> (output: NotesShowOutput, revision: String) {
    let handle = try resolveNotesHandle(project: try resolvedProject(input))
    let rawText = try handle.io.readContent(path: handle.notesPath)
    var notes = normalizeFocusMarker(notes: try parseNotes(markdown: rawText))
    let todos = todosWithEffectiveDueDates(try parseTodos(notes: notes))
    let focusedKey = todos.first(where: { $0.isFocused }).map { "\($0.sessionIndex):\($0.lineIndex)" }
    notes = normalizeFocusMarker(notes: notes)
    return (NotesShowOutput(notes: notes, todos: todos, focusedKey: focusedKey), revision(of: rawText))
}

/// What a reversal calls itself. An entry that is already a reversal carries "Reversed:" on the
/// front, and stacking another would read "Reversed: Reversed: …" instead of saying what was put back.
private func strippedSummary(of entry: JournalEntry) -> String {
    var text = entry.summary
    for prefix in ["Reversed: ", "Restored: "] where text.hasPrefix(prefix) {
        text = String(text.dropFirst(prefix.count))
    }
    return text.hasSuffix(".") ? String(text.dropLast()) : text
}

private func reversalSummary(of entry: JournalEntry) -> String {
    entry.reverses == nil ? "Reversed: \(strippedSummary(of: entry))"
                          : "Restored: \(strippedSummary(of: entry))"
}

/// A project's key — `<basePath>:<folder>` — the spelling `focused.json` and the search's tie-break
/// both use.
private func projectKey(of project: String) throws -> String {
    let path = try resolveProjectPath(nameOrPrefix: project)
    return "\((path as NSString).deletingLastPathComponent):\((path as NSString).lastPathComponent)"
}

/// The focused project's key, or nil when nothing is focused.
private func focusedProjectKey() -> String? {
    guard let folder = focusedProjectFolder(),
          let path = try? resolveProjectPath(nameOrPrefix: folder) else { return nil }
    return "\((path as NSString).deletingLastPathComponent):\((path as NSString).lastPathComponent)"
}

/// A project's path, which is how the journal names it — a caller may have said "W-1", the folder
/// name, or a prefix, and all three should find the same entries.
private func projectPath(of project: String) throws -> String {
    try resolveProjectPath(nameOrPrefix: project)
}

private func folderName(of project: String) throws -> String {
    (try resolveProjectPath(nameOrPrefix: project) as NSString).lastPathComponent
}

/// Today's session, creating it in the markdown if the project hasn't got one yet.
private func todaySession(in rawText: String) throws -> (rawText: String, sessionIndex: Int) {
    let today = formatSessionDate()
    var notes = try parseNotes(markdown: rawText)
    if let index = notes.sessions.firstIndex(where: { $0.date == today }) { return (rawText, index) }
    guard let withSession = sessionAddPreservingFormat(rawText: rawText, label: "", date: Date()) else {
        throw PmError.notesNotFound("## Sessions")
    }
    notes = try parseNotes(markdown: withSession)
    guard let index = notes.sessions.firstIndex(where: { $0.date == today }) else {
        throw PmError.notesNotFound("## Sessions")
    }
    return (withSession, index)
}

private func focusing(_ rawText: String, sessionIndex: Int, lineIndex: Int) throws -> String {
    try editTodosPreservingFormat(rawText: rawText) { notes in
        applyFocusToTodoAt(notes: normalizeFocusMarker(notes: notes),
                           sessionIndex: sessionIndex, lineIndex: lineIndex)
    } ?? rawText
}

/// A session named by ISO date (preferred) or index, the same either-or a task reference accepts.
private func sessionIndex(_ input: ApiInput, in notes: ProjectNotes) throws -> Int {
    guard let session = input.session else {
        throw ApiError(.missingField, "This action needs a session.", detail: .string("session"))
    }
    if let index = Int(session) {
        guard index >= 0, index < notes.sessions.count else {
            throw ApiError(.staleReference, "This project has no session \(index).")
        }
        return index
    }
    let heading = try sessionHeadingDate(iso: session)
    let matching = notes.sessions.enumerated().filter { $0.element.date == heading }.map(\.offset)
    guard (input.sessionOrdinal ?? 0) < matching.count else {
        throw ApiError(.staleReference, "This project has no session dated \(session).")
    }
    return matching[input.sessionOrdinal ?? 0]
}

private func setDetail(_ notes: inout ProjectNotes, key: String, value: JSONValue?) throws {
    func string() throws -> String {
        guard let s = value?.stringValue else {
            throw ApiError(.invalidField, "\(key) takes a string.", detail: .string("value"))
        }
        return s
    }
    func list() throws -> [String] {
        guard let items = value?.arrayValue else {
            throw ApiError(.invalidField, "\(key) takes an array of strings.", detail: .string("value"))
        }
        return items.compactMap(\.stringValue)
    }
    switch key {
    case "title": notes.title = try string()
    case "summary": notes.summary = try string()
    case "problem": notes.problem = try string()
    case "approach": notes.approach = try string()
    case "goals": notes.goals = try list()
    case "learnings": notes.learnings = try list()
    default: throw ApiError(.invalidField, "Unknown section: \(key)", detail: .string("key"))
    }
}

/// A `JSONValue` as the plain Swift value `setConfigValue` expects.
private func plain(_ value: JSONValue?) throws -> Any {
    switch value {
    case .string(let s): return s
    case .bool(let b): return b
    case .number(let n): return n == n.rounded() ? Int(n) : n
    case .array(let a): return a.compactMap(\.stringValue)
    case .object(let o): return o.compactMapValues(\.stringValue)
    default: throw ApiError(.invalidField, "Missing value.", detail: .string("value"))
    }
}

/// Content hash of the notes file — what a caller sends back on a bulk operation to say which
/// version of the document it was looking at. Content rather than mtime, because mtime says when the
/// file was touched and this needs to say what it holds.
func revision(of content: String) -> String {
    SHA256.hash(data: Data(content.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
}

// MARK: - Focus, shared with the other surfaces through the config dir

/// The focused project's folder name, from `focused.json` in the config dir.
///
/// The same file the panel and the Raycast extension read; PmLib knowing how to read it is what lets
/// an action default to "the project I'm working on" without every adapter parsing it itself.
public func focusedProjectFolder() -> String? {
    let path = (getConfigDir() as NSString).appendingPathComponent("focused.json")
    guard let data = FileManager.default.contents(atPath: path),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let key = object["projectKey"] as? String,
          let separator = key.range(of: ":", options: .backwards) else { return nil }
    let folder = String(key[separator.upperBound...])
    return folder.isEmpty ? nil : folder
}

/// Write `focused.json`, so a focus set through the contract is the same focus every surface reads.
public func setFocusedProject(key: String) throws {
    let dir = getConfigDir()
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let data = try JSONSerialization.data(withJSONObject: ["projectKey": key])
    try data.write(to: URL(fileURLWithPath: (dir as NSString).appendingPathComponent("focused.json")))
}
