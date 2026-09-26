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
        // Range, from the same table the schema publishes it from. Unchecked, a negative `limit`
        // reaches `prefix`/`suffix` and traps — which for `pm mcp` takes the server down mid-session
        // rather than refusing the one call, and a trap is not something an adapter can catch.
        if let minimum = field.minimum, let given = value?.intValue, given < minimum {
            throw ApiError(.invalidField,
                           "\(field.name) can't be less than \(minimum), and was \(given).",
                           detail: .string(field.name))
        }
    }
    for group in spec.oneOf where group.filter({ values[$0] ?? nil != nil }).count != 1 {
        throw ApiError(.missingField,
                       "\(spec.name) needs exactly one of: \(group.joined(separator: ", "))",
                       detail: .array(group.map { .string($0) }))
    }
}

/// The input as a bag of values, so validation reads it the same way the schema describes it.
/// Every field a caller can send, as the validator sees it.
///
/// This is a hand-written mirror of `ApiInput`, and the only thing keeping it honest is
/// `ApiTests.testEveryPublishedFieldIsValidated`: a field published in the manifest and missing here
/// is a field whose `required`, `allowed` and `minimum` are never checked. `kind` was exactly that —
/// published with two allowed values and validated against neither, so `kind: "nonsense"` quietly
/// became a project and the caller got told off about a domain they hadn't mentioned.
internal func fieldValues(_ input: ApiInput) -> [String: JSONValue?] {
    [
        "project": input.project.map(JSONValue.string),
        "folder": input.folder.map(JSONValue.string),
        "frame": input.frame.map(JSONValue.string),
        "sort": input.sort.map(JSONValue.string),
        "kind": input.kind.map(JSONValue.string),
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
        "sessionDigest": input.sessionDigest.map(JSONValue.string),
        "advanceFocus": input.advanceFocus.map(JSONValue.bool),
        "focus": input.focus.map(JSONValue.bool),
        "pick": input.pick.map(JSONValue.bool),
        "clearDue": input.clearDue.map(JSONValue.bool),
        "waiting": input.waiting.map(JSONValue.string),
        "clearWaiting": input.clearWaiting.map(JSONValue.bool),
        "partOf": input.partOf.map(JSONValue.string),
        "clearPartOf": input.clearPartOf.map(JSONValue.bool),
        "includeCompleted": input.includeCompleted.map(JSONValue.bool),
        "includeDropped": input.includeDropped.map(JSONValue.bool),
        "time": input.time.map(JSONValue.bool),
        "query": input.query.map(JSONValue.string),
        "entry": input.entry.map(JSONValue.string),
        "now": input.now.map(JSONValue.string),
        "period": input.period.map(JSONValue.string),
        "new": input.new.map(JSONValue.bool),
        "since": input.since.map(JSONValue.string),
        "until": input.until.map(JSONValue.string),
        "before": input.before.map(JSONValue.string),
        "activity": input.activity.map(JSONValue.bool),
        "projects": input.projects.map { .array($0.map(JSONValue.string)) },
        "from": input.from.map(JSONValue.string),
        "to": input.to.map(JSONValue.string),
        "notWork": input.notWork.map(JSONValue.bool),
    ]
}

// MARK: - Running

private func run(_ spec: ApiActionSpec, _ input: ApiInput, _ options: ApiOptions) throws -> ApiResult {
    switch spec.name {
    // MARK: Task mutations
    case "task.add":
        return try document(spec, input, options) { rawText, lastEdited in
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
                let focused = kind == .child && (input.focus ?? true)
                    ? try focusing(out.rawText, sessionIndex: out.sessionIndex, lineIndex: out.lineIndex)
                    : out.rawText
                return Outcome(rawText: focused, relocated: at.relocated)
            }
            let session = try currentSession(in: rawText, lastEdited: lastEdited)
            guard let out = appendTaskToSession(rawText: session.rawText, sessionIndex: session.sessionIndex,
                                                text: text, due: input.due) else {
                throw ApiError(.writeFailed, "Couldn't add to the current session.")
            }
            guard input.focus ?? true else { return Outcome(rawText: out.rawText) }
            return Outcome(rawText: try focusing(out.rawText, sessionIndex: out.sessionIndex,
                                                 lineIndex: out.lineIndex))
        }

    case "task.complete":
        return try editing(spec, input, options) { notes, at in
            try completeTodoWithDescendants(notes: notes, sessionIndex: at.sessionIndex,
                                            lineIndex: at.lineIndex,
                                            advanceFocus: input.advanceFocus ?? true)
        }
    case "task.drop":
        return try editing(spec, input, options) { notes, at in
            try dropTodoWithDescendants(notes: notes, sessionIndex: at.sessionIndex,
                                        lineIndex: at.lineIndex,
                                        advanceFocus: input.advanceFocus ?? true)
        }
    case "task.reopen":
        return try editing(spec, input, options) { notes, at in
            try undoTodoAt(notes: notes, sessionIndex: at.sessionIndex, lineIndex: at.lineIndex)
        }
    case "task.focus":
        guard input.pick ?? true else {
            return try editing(spec, input, options) { notes, at in
                applyFocusToTodoAt(notes: notes, sessionIndex: at.sessionIndex, lineIndex: at.lineIndex)
            }
        }
        return try document(spec, input, options) { (context: DocumentContext) in
            try focusing(input, context, source: options.source)
        }
    case "task.pick":
        return try document(spec, input, options) { (context: DocumentContext) in
            try picking(input, context, source: options.source)
        }
    case "task.release":
        return try document(spec, input, options) { (context: DocumentContext) in
            try releasing(input, context, source: options.source)
        }
    case "task.setText":
        return try document(spec, input, options) { (context: DocumentContext) in
            // One task takes `text`; a batch gives each its own, since renaming several to one text is
            // never what anyone meant.
            let batch = input.tasks != nil
            var text = context.rawText
            var relocated = false
            var sidecar: [PickEvent] = []
            for reference in try references(input) {
                guard let new = (batch ? reference.text : input.text),
                      !new.trimmingCharacters(in: .whitespaces).isEmpty else {
                    throw PmError.emptyTodoText
                }
                guard let at = try resolve(reference, in: text, batch: batch) else { continue }
                relocated = relocated || at.relocated
                let renamed = try editTodosPreservingFormat(rawText: text) { notes in
                    setTextOnTodoAt(notes: normalizeFocusMarker(notes: notes), sessionIndex: at.sessionIndex,
                                    lineIndex: at.lineIndex, text: new)
                } ?? text
                sidecar += try retargeting(at, from: DocumentContext(rawText: text, lastEdited: context.lastEdited,
                                                                     projectPath: context.projectPath),
                                           to: renamed, source: options.source)
                text = renamed
            }
            return Outcome(rawText: text, relocated: relocated, sidecar: sidecar)
        }
    case "task.setDue":
        return try editing(spec, input, options) { notes, at in
            let due = (input.clearDue == true) ? nil : input.due
            if let d = due, !isValidTodoDue(d) { throw PmError.invalidTodoDue(d) }
            return setDueOnTodoAt(notes: notes, sessionIndex: at.sessionIndex,
                                  lineIndex: at.lineIndex, due: due)
        }
    case "task.setWaiting":
        return try editing(spec, input, options) { notes, at in
            let waiting = (input.clearWaiting == true) ? nil : input.waiting
            if let w = waiting, !isValidWaitTarget(w) { throw PmError.invalidWaitTarget(w) }
            return setWaitingOnTodoAt(notes: notes, sessionIndex: at.sessionIndex,
                                      lineIndex: at.lineIndex, waiting: waiting)
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
        return try document(spec, input, options) { rawText, lastEdited in
            // "The current session" rather than "today's": the first sitting of a day starts one, and
            // so does coming back to the project after `sessionIdleWindow` — see `SessionWindow.swift`.
            let hadToday = try parseNotes(markdown: rawText).sessions
                .contains { $0.date == formatSessionDate() }
            let session = try currentSession(in: rawText, lastEdited: lastEdited, label: input.label,
                                             forcingNew: input.new == true)
            // Reported either way, so a caller can ask for the current session and use the answer
            // without knowing whether it had to be made — and without formatting a date to find it.
            let sessions = try parseNotes(markdown: session.rawText).sessions
            let data: JSONValue = session.sessionIndex < sessions.count
                ? .object([
                    "date": .string(sessions[session.sessionIndex].date),
                    "isoDate": sessionISODate(heading: sessions[session.sessionIndex].date)
                        .map(JSONValue.string) ?? .null,
                    "label": .string(sessions[session.sessionIndex].label),
                    "index": .number(Double(session.sessionIndex)),
                  ])
                : .null
            guard session.started else {
                return Outcome(rawText: session.rawText,
                               note: .statement("The current session was already there"), data: data)
            }
            return Outcome(rawText: session.rawText,
                           note: hadToday
                               ? Phrase(past: "Started a new session", future: "start a new session")
                               : Phrase(past: "Started today's session", future: "start today's session"),
                           data: data)
        }
    case "session.note":
        return try document(spec, input, options) { rawText, lastEdited in
            guard let prose = input.prose, !prose.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw PmError.emptySessionNote
            }
            guard let out = try appendSessionNotePreservingFormat(rawText: rawText, prose: prose,
                                                                  lastEdited: lastEdited) else {
                throw PmError.notesNotFound("## Sessions")
            }
            return Outcome(rawText: out, note: Phrase(past: "Added a note to the current session",
                                                      future: "add a note to the current session"))
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
    case "session.backfillTimes":
        // A migration, once per project: see `SessionTimes`. One write for the whole document, so it is
        // one journal entry and one undo however many sittings it dates.
        return try document(spec, input, options) { (context: DocumentContext) in
            let evidence = SessionTimes.evidence(projectPath: context.projectPath)
            guard let result = try SessionTimes.backfill(rawText: context.rawText, evidence: evidence)
            else {
                return Outcome(rawText: context.rawText,
                               note: .statement("Every session already has a time"),
                               data: .array([]))
            }
            let count = result.guesses.count
            let guessed = result.guesses.filter { $0.basis != .placeholder }.count
            let sessions = count == 1 ? "1 session" : "\(count) sessions"
            let from = guessed == count ? "from the record"
                : guessed == 0 ? "placeholder times"
                : "\(guessed) from the record, \(count - guessed) placeholder"
            return Outcome(rawText: result.rawText,
                           note: Phrase(past: "Gave \(sessions) a time (\(from))",
                                        future: "give \(sessions) a time (\(from))"),
                           data: try JSONValue.encoding(result.guesses))
        }
    case "session.delete":
        return try document(spec, input, options) { rawText in
            let notes = try parseNotes(markdown: rawText)
            let index = try sessionIndex(input, in: notes)
            // The guard this action's error message has always promised, finally made.
            //
            // It used to be nothing but a message: the refusal was reported whenever the delete
            // returned nil, which it does only when the heading can't be found, and the actual "does
            // it still hold tasks" test lived in the app's menu — where it gates the affordance
            // against the document the window is showing, while the delete lands against a freshly
            // re-read one. Anything that shifted the session indices in between (a note from the
            // quick bar starting a new session is enough) turned a delete of an empty sitting into a
            // delete of a different one, tasks and all. Every caller that isn't the app — the CLI,
            // MCP, Raycast — had no gate whatsoever.
            if try parseTodos(notes: notes).contains(where: { $0.sessionIndex == index }) {
                throw ApiError(.writeFailed, "That session still has tasks in it.")
            }
            guard let out = deleteSessionPreservingFormat(rawText: rawText, sessionIndex: index) else {
                throw ApiError(.writeFailed, "Couldn't delete that session.")
            }
            return Outcome(rawText: out, note: Phrase(past: "Deleted the session", future: "delete the session"))
        }

    // MARK: Notes
    case "notes.setDetail":
        // Refused here rather than written and dropped. The serializer keeps a section the kind omits
        // only when it isn't empty, so setting one on an area would appear to work and then vanish the
        // next time anything rewrote the document.
        let detailKind = ProjectKind.of(folderName: try folderName(of: input.project ?? ""))
        if let section = HeaderSection(rawValue: input.key ?? ""), !detailKind.headerSections.contains(section) {
            throw ApiError(.invalidField, "An \(detailKind.rawValue) has no \(section.label) section.",
                           detail: .string("key"))
        }
        return try document(spec, input, options) { rawText in
            var notes = try parseNotes(markdown: rawText)
            try setDetail(&notes, key: input.key ?? "", value: input.value)
            guard let out = try writeNotesPreservingFormat(rawText: rawText, incoming: notes,
                                                           kind: detailKind) else {
                throw ApiError(.writeFailed, "Couldn't splice that section.")
            }
            return Outcome(rawText: out, note: Phrase(past: "Updated \(input.key ?? "the notes")", future: "update \(input.key ?? "the notes")"))
        }
    case "notes.addLink":
        // Links are common to both kinds, so this can't trip the header guard — the kind is passed
        // because the writer always wants one, not because this action has a decision to make.
        let linkKind = ProjectKind.of(folderName: try folderName(of: try resolvedProject(input)))
        // A link is a card in the project's Links frame, with `## Links` its mirror (ProjectLinksFrame).
        // The notes are written as they always were, so the journal and its undo are unchanged, and
        // then the board is brought up to them — here, because this may run while the app isn't.
        defer {
            if !options.dryRun, let handle = try? resolveNotesHandle(project: try resolvedProject(input)) {
                _ = try? ProjectLinksFrame.syncFiles(projectPath: handle.projectPath,
                                                     notesPath: handle.notesPath, io: handle.io)
            }
        }
        return try document(spec, input, options) { rawText in
            guard let url = input.text, !url.isEmpty else { throw PmError.emptyTodoText }
            var notes = try parseNotes(markdown: rawText)
            notes.links.append(LinkEntry(label: input.label ?? url, url: url))
            guard let out = try writeNotesPreservingFormat(rawText: rawText, incoming: notes,
                                                           kind: linkKind) else {
                throw ApiError(.writeFailed, "Couldn't add the link.")
            }
            return Outcome(rawText: out, note: Phrase(past: "Added the link", future: "add the link"))
        }

    // MARK: Projects
    case "project.create":
        let (config, paths) = try loadConfigAndPaths()
        // Absent means project: that's what every caller written before Areas existed meant by saying
        // nothing, and the field is validated against `allowed` before it gets here.
        let kind = ProjectKind(rawValue: input.kind ?? ProjectKind.project.rawValue) ?? .project
        if kind.isNumbered, input.domain == nil || config.domains[input.domain ?? ""] == nil {
            throw ApiError(.invalidField, "Unknown domain: \(input.domain ?? "")", detail: .string("domain"))
        }
        if !kind.isNumbered, input.domain != nil {
            throw ApiError(.invalidField, "An \(kind.rawValue) doesn't take a domain code.", detail: .string("domain"))
        }
        let path = try createProject(config: config, paths: paths, kind: kind, domainCode: input.domain,
                                     title: input.title ?? "", dryRun: options.dryRun)
        let name = (path as NSString).lastPathComponent
        return metadata(spec, options, path: path,
                        Phrase(past: "Created \(name)", future: "create \(name)"))
    case "project.adopt":
        let (config, paths) = try loadConfigAndPaths()
        let folder = input.folder ?? ""
        let notesPath = try adoptArea(config: config, paths: paths, folderName: folder,
                                      dryRun: options.dryRun)
        return metadata(spec, options, path: notesPath,
                        Phrase(past: "Took on \(folder)", future: "take on \(folder)"))
    case "project.rename":
        let path = try renameProjectTitle(nameOrPrefix: input.project ?? "", newTitle: input.title ?? "",
                                          dryRun: options.dryRun)
        let name = (path as NSString).lastPathComponent
        return metadata(spec, options, path: path,
                        Phrase(past: "Renamed to \(name)", future: "rename it to \(name)"))
    case "project.archive", "project.unarchive":
        let archiving = spec.name == "project.archive"
        let (_, paths) = try loadConfigAndPaths()
        let folder = try folderName(of: input.project ?? "")
        // Everything archives into the one archive; what comes back out goes wherever its kind lives,
        // which its name still says however long it has been in there.
        let home = ProjectKind.of(folderName: folder).homeScope
        let path = try moveProject(named: folder, from: archiving ? home : .archive,
                                   to: archiving ? .archive : home, paths: paths,
                                   dryRun: options.dryRun)
        return metadata(spec, options, path: path,
                        archiving ? Phrase(past: "Archived \(folder)", future: "archive \(folder)")
                                  : Phrase(past: "Restored \(folder)", future: "restore \(folder)"))
    case "project.setPartOf":
        // Checked against the whole vault before the one file is written: one level, no archived master,
        // not itself. See `ProjectPartOf` and docs/combining-projects.md.
        let member = try folderName(of: try resolvedProject(input))
        let clearing = input.clearPartOf == true
        guard clearing || !(input.partOf ?? "").trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ApiError(.missingField, "Say which project this is part of, or clear it.",
                           detail: .string("partOf"))
        }
        var master: String?
        if !clearing, let name = input.partOf {
            let (config, paths) = try loadConfigAndPaths()
            let roots = try ProjectScope.allCases.map {
                (scope: $0, folders: try getFolders(basePath: $0.path(in: paths), scope: $0,
                                                    domainCodes: Array(config.domains.keys)))
            }
            do {
                master = try checkedMaster(memberFolder: member, masterName: name,
                                           memberships: try projectMemberships(), roots: roots)
            } catch let refusal as PartOfRefusal {
                throw ApiError(.invalidField, refusal.errorDescription ?? "That can't be done.",
                               detail: .string("partOf"))
            }
        }
        return try document(spec, input, options) { rawText in
            let phrase = master.map { Phrase(past: "Made \(member) part of \($0)",
                                             future: "make \(member) part of \($0)") }
                ?? Phrase(past: "Took \(member) out of its master project",
                          future: "take \(member) out of its master project")
            return Outcome(rawText: settingProjectPartOf(master, in: rawText), note: phrase,
                           data: master.map(JSONValue.string) ?? .null)
        }
    case "project.focus":
        // The key is built from where the thing actually is, not from `activePath`. That was the same
        // string for every project and stops being so the moment an area — or anything archived — can
        // be focused.
        let path = try resolveProjectPath(nameOrPrefix: input.project ?? "")
        let folder = (path as NSString).lastPathComponent
        if !options.dryRun {
            let key = "\((path as NSString).deletingLastPathComponent):\(folder)"
            try setFocusedProject(key: key)
            // Attention arrived here, and a `began` implicitly ends whatever it was on before
            // (docs/time-tracking.md D4). Folio writes these too, with a real clock behind them; this
            // is what keeps the record honest when the focus came from Raycast, `pm` or a model, and
            // when Folio isn't running at all.
            //
            // The focused task is colour on the span, never a total (D1), so failing to read it is a
            // reason to log without it rather than to fail the focus.
            let task = (try? resolveNotesPath(projectPath: path))
                .flatMap { $0 }
                .flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }
                .flatMap { try? notesShow(rawText: $0) }?
                .todos.first(where: \.isFocused)?.text
            AttentionLog.began(project: folder, key: key, task: task, source: options.source)
        }
        return ApiResult(action: spec.name,
                         summary: Phrase(past: "Focused \(folder)",
                                         future: "focus \(folder)").sentence(dryRun: options.dryRun),
                         dryRun: options.dryRun)

    case "time.count":
        guard let from = input.from.flatMap(DoneLog.date), let to = input.to.flatMap(DoneLog.date) else {
            throw ApiError(.invalidField,
                           "from and to need to be ISO 8601 with a zone, like 2026-09-23T11:07:00Z.",
                           detail: .string(input.from.flatMap(DoneLog.date) == nil ? "from" : "to"))
        }
        guard to > from else {
            throw ApiError(.invalidField, "to has to come after from.", detail: .string("to"))
        }
        // A minute's grace for clocks and for "until now" typed at the end of a minute; past that, it's
        // time that hasn't happened, and there's nothing on record yet to answer for.
        guard to <= Date().addingTimeInterval(60) else {
            throw ApiError(.invalidField, "to is in the future — only time that's happened can be counted.",
                           detail: .string("to"))
        }
        let stretch = "\(SessionTimes.clockLabel(from, calendar: .current))–\(SessionTimes.clockLabel(to, calendar: .current)) (\(durationLabel(to.timeIntervalSince(from))))"
        if input.notWork == true {
            var data: JSONValue?
            if !options.dryRun {
                data = try JSONValue.encoding(AttentionLog.counted(from: from, to: to, source: options.source))
            }
            return ApiResult(action: spec.name,
                             summary: Phrase(past: "Marked \(stretch) as not work",
                                             future: "mark \(stretch) as not work").sentence(dryRun: options.dryRun),
                             dryRun: options.dryRun, data: data)
        }
        guard let name = input.project else {
            // `notWork: false` and no project passes the one-of check, and says nothing.
            throw ApiError(.missingField, "time.count needs a project, or notWork: true.",
                           detail: .string("project"))
        }
        let path = try resolveProjectPath(nameOrPrefix: name)
        let folder = (path as NSString).lastPathComponent
        // The key is spelled the way `project.focus` and `focused.json` spell it, so the answer and the
        // spans either side of it are one project, not two that happen to share a name.
        let key = "\((path as NSString).deletingLastPathComponent):\(folder)"
        var data: JSONValue?
        if !options.dryRun {
            let event = AttentionLog.counted(from: from, to: to, project: folder, key: key,
                                             source: options.source)
            data = try JSONValue.encoding(event)
        }
        return ApiResult(action: spec.name,
                         summary: Phrase(past: "Counted \(stretch) for \(projectTitle(fromFolderName: folder))",
                                         future: "count \(stretch) for \(projectTitle(fromFolderName: folder))")
                             .sentence(dryRun: options.dryRun),
                         dryRun: options.dryRun, data: data)

    case "task.search":
        let scope = input.scope ?? "all"
        let hits = try searchableTasks(includeArchived: scope != "active",
                                       includeActive: scope != "archive", projects: input.projects)
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

    case "task.waiting":
        // Active by default, where the other cross-project query defaults to all. A wait is a claim
        // about work that hasn't happened yet, and an archived project's unfinished tasks are not
        // waiting on anything any more — they were put down.
        let scope = input.scope ?? "active"
        let buckets = try waitingBuckets(includeArchived: scope != "active",
                                         includeActive: scope != "archive", projects: input.projects)
        let count = buckets.reduce(0) { $0 + $1.tasks.count }
        let released = buckets.filter { $0.state == "released" }.count
        var summary = "Nothing is waiting."
        if !buckets.isEmpty {
            summary = "\(count) task\(count == 1 ? "" : "s") waiting on "
                + "\(buckets.count) thing\(buckets.count == 1 ? "" : "s")."
            if released > 0 { summary += " \(released) released." }
        }
        return ApiResult(action: spec.name, summary: summary, data: try JSONValue.encoding(buckets))

    case "task.done":
        // All by default, where `task.waiting` defaults to active: a project finished and archived this
        // week is exactly the work a week's report is for.
        let scope = input.scope ?? "all"
        let range = try DoneRange.resolve(period: input.period, since: input.since, until: input.until)
        let items = try doneTasks(in: range, includeArchived: scope != "active",
                                  includeActive: scope != "archive",
                                  includeDropped: input.includeDropped == true)
        let done = items.filter { !$0.dropped }
        let projects = Set(items.map(\.projectFolder)).count
        let dropped = items.count - done.count
        var summary = done.isEmpty
            ? "Nothing done"
            : "\(done.count) task\(done.count == 1 ? "" : "s") done"
        if dropped > 0 { summary += ", \(dropped) dropped" }
        summary += projects > 1 ? " across \(projects) projects." : "."
        return ApiResult(action: spec.name, summary: summary, data: try JSONValue.encoding(items))

    case "session.list":
        let range = try DoneRange.resolve(period: input.period, since: input.since, until: input.until)
        let list = try sessionList(in: range, projects: input.projects, time: input.time == true)
        let done = list.sittings.reduce(0) { $0 + $1.finished.count }
            + list.elsewhere.filter { !$0.dropped }.count
        let projects = Set(list.sittings.map(\.projectFolder)).count
        var summary = list.sittings.isEmpty
            ? "No sittings"
            : "\(list.sittings.count) sitting\(list.sittings.count == 1 ? "" : "s")"
        if projects > 1 { summary += " in \(projects) projects" }
        if done > 0 { summary += ", \(done) done" }
        return ApiResult(action: spec.name, summary: summary + ".", data: try JSONValue.encoding(list))

    case "time.aways":
        let range = try DoneRange.resolve(period: input.period, since: input.since, until: input.until)
        let aways = try attentionAways(in: range, projects: input.projects)
        let total = aways.reduce(0) { $0 + $1.seconds }
        let summary = aways.isEmpty
            ? "No aways."
            : "\(aways.count) away\(aways.count == 1 ? "" : "s"), \(durationLabel(total))."
        return ApiResult(action: spec.name, summary: summary, data: try JSONValue.encoding(aways))

    case "time.spent":
        let range = try DoneRange.resolve(period: input.period, since: input.since, until: input.until)
        let report = try timeSpent(in: range, projects: input.projects)
        let tracked = report.projects.filter { $0.seconds > 0 }
        let inferred = tracked.filter(\.inferred).count
        var summary = tracked.isEmpty
            ? "No time on record"
            : "\(durationLabel(report.seconds)) across \(tracked.count) project\(tracked.count == 1 ? "" : "s")"
        // Said in the sentence, not only in the data: a total that is partly guessed should say so
        // wherever it is read aloud (D4).
        if inferred > 0 { summary += ", \(inferred) inferred" }
        let counted = tracked.filter(\.counted).count
        if counted > 0 { summary += ", \(counted) with counted time" }
        return ApiResult(action: spec.name, summary: summary + ".", data: try JSONValue.encoding(report))

    case "task.due":
        let due = try dueTasks(until: input.until, projects: input.projects)
        let today = isoDay(Date())
        let overdue = due.filter { ($0.due.map { String($0.prefix(10)) } ?? "") < today }.count
        let projects = Set(due.map(\.projectFolder)).count
        var summary = due.isEmpty ? "Nothing due." : "\(due.count) due"
        if !due.isEmpty {
            if overdue > 0 { summary += ", \(overdue) overdue" }
            summary += projects > 1 ? " across \(projects) projects." : "."
        }
        return ApiResult(action: spec.name, summary: summary, data: try JSONValue.encoding(due))

    case "task.leftovers":
        let list = try leftoverTasks(before: input.before, projects: input.projects)
        let tasks = list.taskCount
        var summary = "Nothing left open."
        if tasks > 0 {
            summary = "\(tasks) task\(tasks == 1 ? "" : "s") left open in \(list.sittingCount) "
                + "sitting\(list.sittingCount == 1 ? "" : "s")"
            summary += list.projects.count > 1 ? " across \(list.projects.count) projects." : "."
        }
        return ApiResult(action: spec.name, summary: summary, data: try JSONValue.encoding(list))

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
        // What the write appended to the pick log, looked up now: an entry names its events by id.
        let appended = (entry.sidecar ?? []).isEmpty ? []
            : entry.project.map { PickLog.events(ids: entry.sidecar ?? [], projectPath: $0) } ?? []
        guard entry.undoable, entry.notesPath != nil || !appended.isEmpty else {
            throw ApiError(.unsupportedAction,
                           "\(entry.action) can't be reversed — there's no document behind it.",
                           detail: .string(entry.id))
        }
        let cancelling = PickLog.reversing(appended, source: options.source)
        guard let notesPath = entry.notesPath else {
            // Picks alone, with no document behind them. Nothing to check: a `released` cancels only the
            // pick it names, so reversing one can never undo anything else.
            if !options.dryRun, let project = entry.project {
                try PickLog.append(cancelling, projectPath: project)
                ApiJournal.recordSidecar(action: spec.name, project: project,
                                         summary: reversalSummary(of: entry), ids: cancelling.map(\.id),
                                         source: options.source, reverses: entry.id)
            }
            return ApiResult(action: spec.name,
                             summary: options.dryRun
                                 ? "Would reverse: \(strippedSummary(of: entry))."
                                 : reversalSummary(of: entry) + ".",
                             dryRun: options.dryRun,
                             data: try JSONValue.encoding(entry),
                             sidecar: options.dryRun ? nil : cancelling)
        }
        guard let restored = ApiJournal.snapshot(entry.revisionBefore) else {
            throw ApiError(.unsupportedAction,
                           "\(entry.action) can't be reversed — there's no document behind it.",
                           detail: .string(entry.id))
        }
        let current = try String(contentsOfFile: notesPath, encoding: .utf8)
        // The safety the journal exists to provide: reverse only what is still exactly as this write
        // left it. Anything else and an undo would be discarding an edit made since, unseen. The picks
        // are held to the same check: half an undo is worse than none.
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
            // Document first: the picks are appended only once it has been restored.
            if let project = entry.project { try PickLog.append(cancelling, projectPath: project) }
            // The reversal is itself a write, and is journaled as one — so it can be reversed too,
            // and so the record doesn't quietly omit the biggest changes anybody makes.
            ApiJournal.record(action: spec.name, project: entry.project, notesPath: notesPath,
                              summary: reversalSummary(of: entry), before: current, after: restored,
                              changed: undone, source: options.source, reverses: entry.id,
                              sidecar: cancelling.map(\.id))
        }
        return ApiResult(action: spec.name,
                         summary: options.dryRun
                             ? "Would reverse: \(strippedSummary(of: entry))."
                             : reversalSummary(of: entry) + ".",
                         revision: revision(of: restored), changed: undone,
                         focus: after.first(where: \.isFocused).map(reference(to:)),
                         dryRun: options.dryRun,
                         data: try JSONValue.encoding(entry),
                         sidecar: options.dryRun || cancelling.isEmpty ? nil : cancelling)

    // MARK: Queries
    case "project.list":
        let (config, paths) = try loadConfigAndPaths(skipPathValidation: true)
        let codes = Array(config.domains.keys)
        let scope = input.scope ?? "active"
        if input.activity == true {
            let scopes = ProjectScope.allCases.filter { scope == "all" || scope == $0.rawValue }
            let summaries = try projectSummaries(scopes: scopes, kind: input.kind, projects: input.projects)
            return ApiResult(action: spec.name,
                             summary: "\(summaries.count) result\(summaries.count == 1 ? "" : "s").",
                             data: try JSONValue.encoding(summaries))
        }
        let only = try input.projects.map(projectFolders(named:))
        let wanted = input.kind.flatMap(ProjectKind.init(rawValue:))
        var entries: [JSONValue] = []
        for scopeCase in ProjectScope.allCases where scope == "all" || scope == scopeCase.rawValue {
            let base = scopeCase.path(in: paths)
            for folder in (try? getFolders(basePath: base, scope: scopeCase, domainCodes: codes)) ?? [] {
                if let only, !only.contains(folder) { continue }
                let kind = ProjectKind.of(folderName: folder)
                guard wanted == nil || wanted == kind else { continue }
                entries.append(.object([
                    "folder": .string(folder),
                    "name": .string(projectTitle(fromFolderName: folder)),
                    "code": projectCode(fromName: folder).map(JSONValue.string) ?? .null,
                    "kind": .string(kind.rawValue),
                    "scope": .string(scopeCase.rawValue),
                    "path": .string((base as NSString).appendingPathComponent(folder)),
                ]))
            }
        }
        return ApiResult(action: spec.name, summary: "\(entries.count) result\(entries.count == 1 ? "" : "s").",
                         data: .array(entries))
    case "project.adoptable":
        let (_, paths) = try loadConfigAndPaths(skipPathValidation: true)
        let folders = (try? getAdoptableFolders(basePath: paths.areasPath)) ?? []
        return ApiResult(action: spec.name,
                         summary: folders.isEmpty
                             ? "Nothing to take on."
                             : folders.count == 1 ? "1 folder could become an area."
                                                  : "\(folders.count) folders could become areas.",
                         data: .array(folders.map { folder in
                             .object(["folder": .string(folder),
                                      "path": .string((paths.areasPath as NSString).appendingPathComponent(folder))])
                         }))
    case "project.get":
        let folder = try folderName(of: input.project ?? "")
        let memberships = (try? projectMemberships()) ?? []
        let path = try resolveProjectPath(nameOrPrefix: input.project ?? "")
        return ApiResult(action: spec.name, summary: folder, data: .object([
            "folder": .string(folder),
            "name": .string(projectTitle(fromFolderName: folder)),
            "kind": .string(ProjectKind.of(folderName: folder).rawValue),
            "path": .string(path),
            "notesPath": (try resolveNotesPath(projectPath: path)).map(JSONValue.string) ?? .null,
            // The master it names, resolved, and the projects that name it — so a caller can draw either
            // side of the relationship from the one it has. See `ProjectPartOf`.
            "partOf": memberships.first { $0.member == folder }?.master.map(JSONValue.string) ?? .null,
            "members": .array(memberships.filter { $0.master == folder }.map { .string($0.member) }),
        ]))
    // MARK: Cards (docs/items.md D9)

    case "card.list":
        let path = try projectPath(of: try resolvedProject(input))
        let title = try projectTitleOf(input)
        let document = try readProjectCanvas(at: path)
        let sort = input.sort.flatMap(CanvasItemSort.init(rawValue:)) ?? .reading
        var sections = CanvasItems.sections(of: document, sort: sort)
        if let wanted = input.frame {
            sections = sections.filter {
                $0.label?.compare(wanted, options: .caseInsensitive) == .orderedSame
            }
        }
        let count = sections.reduce(0) { $0 + $1.items.count }
        return ApiResult(action: spec.name,
                         summary: "\(count) item\(count == 1 ? "" : "s") in \(title).",
                         data: .object([
                            "project": .string(title),
                            "sort": .string(sort.rawValue),
                            "sections": .array(sections.map { section -> JSONValue in
                                .object([
                                    // Null rather than a name for the cards loose on the board: they
                                    // are in no frame, which is a different thing from being in one
                                    // called nothing.
                                    "frame": section.label.map(JSONValue.string) ?? .null,
                                    "items": .array(section.items.map(described)),
                                ])
                            }),
                         ]))

    case "card.add":
        let path = try projectPath(of: try resolvedProject(input))
        let title = try projectTitleOf(input)
        let text = (input.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw ApiError(.invalidField, "card.add needs something to put on the board.",
                           detail: .string("text"))
        }
        // A project has a canvas, or wants one — the same declaration `resolveProjectCanvasPath` makes.
        // **A preview makes nothing, the board included.** Creating it here would leave a project that
        // had no board with one, which is a write, and "what would this do" must not do it.
        let existing = try resolveProjectCanvasPath(projectPath: path)
        let canvasPath: String
        if let existing {
            canvasPath = existing
        } else if options.dryRun {
            canvasPath = getProjectCanvasPath(projectPath: path)
        } else {
            canvasPath = try createProjectCanvas(projectPath: path,
                                                 notesPath: try resolveNotesPath(projectPath: path))
        }
        let before = (try? String(contentsOfFile: canvasPath, encoding: .utf8))
            ?? CanvasDocument().serialized()
        var document = try CanvasDocument.parse(Data(before.utf8))
        let address = canvasTypedAddress(text)
        let frame = input.frame.map { CanvasItemPlacement.frame(labelled: $0, in: &document) }
        let node = CanvasItemPlacement.add(address.map { CanvasContent.link(url: $0) } ?? .text(text),
                                           to: &document, frame: frame)
        let after = try document.serialized()
        // Named after the placement rather than looked up by label: the card went into the frame that
        // was named, or into the Inbox, which is a marked node and need not still be called one.
        let where_ = frame.flatMap { document.node(id: $0) } ?? CanvasItemPlacement.inbox(of: document)
        let phrase = "\(address == nil ? "a card" : "a web card") to "
            + "\(where_.map(canvasFrameLabel) ?? CanvasItemPlacement.inboxLabel) in \(title)."
        if !options.dryRun {
            try document.write(to: URL(fileURLWithPath: canvasPath))
            // Journaled as the document write it is. The board is not the notes, so the entry names
            // the canvas — and `journal.undo` restores a file's content under a revision guard, which
            // is as true of a `.canvas` as of a `.md`. What it cannot report is a diff of tasks,
            // because a board has none.
            ApiJournal.record(action: spec.name, project: path, notesPath: canvasPath,
                              summary: "Added " + phrase, before: before, after: after, changed: [],
                              source: options.source)
        }
        return ApiResult(action: spec.name,
                         summary: (options.dryRun ? "Would add " : "Added ") + phrase,
                         revision: revision(of: after),
                         dryRun: options.dryRun,
                         data: .object(["card": described(CanvasItem.of(node) ?? CanvasItem(
                            id: node.id, title: text, kind: .text, rect: node.frame))]))

    case "notes.get":
        let read = try readProject(input)
        return ApiResult(action: spec.name, summary: read.notes.title,
                         revision: read.revision, data: try JSONValue.encoding(read))
    case "task.list":
        let read = try readProject(input)
        var todos = read.todos
        if input.includeCompleted != true { todos = todos.filter { !$0.checked } }
        if let limit = input.limit { todos = Array(todos.prefix(limit)) }
        let title = try projectTitleOf(input)
        return ApiResult(action: spec.name,
                         summary: "\(todos.count) task\(todos.count == 1 ? "" : "s") in \(title).",
                         revision: read.revision, data: try labelled(todos, in: read, project: title))
    case "task.whatsDue":
        let read = try readProject(input)
        var due = read.todos.filter { !$0.checked && $0.effectiveDueDate != nil }
        due.sort { ($0.effectiveDueDate ?? "") < ($1.effectiveDueDate ?? "") }
        if let limit = input.limit { due = Array(due.prefix(limit)) }
        return ApiResult(action: spec.name,
                         summary: due.isEmpty ? "Nothing due." : "\(due.count) due.",
                         revision: read.revision,
                         data: try labelled(due, in: read, project: try projectTitleOf(input)))
    case "task.progress":
        let read = try readProject(input)
        let (done, total) = read.todos.progress
        let dropped = read.todos.count - total
        return ApiResult(action: spec.name, summary: "\(done) of \(total) done.",
                         revision: read.revision,
                         data: .object(["done": .number(Double(done)),
                                        "dropped": .number(Double(dropped)),
                                        "total": .number(Double(total))]))
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
        let key = input.key ?? ""
        try setConfigValue(config: &config, key: key, value: try plain(input.value))
        let phrase = Phrase(past: "Set \(key)", future: "set \(key)")
        if !options.dryRun {
            try saveConfig(config)
            ApiJournal.recordMetadata(action: spec.name, project: nil, summary: phrase.past + ".",
                                      source: options.source)
        }
        return ApiResult(action: spec.name, summary: phrase.sentence(dryRun: options.dryRun),
                         dryRun: options.dryRun)

    default:
        throw ApiError(.unsupportedAction, "\(spec.name) isn't implemented yet.")
    }
}

/// The envelope for a mutation with no document behind it — a project created, renamed or moved.
///
/// These sit outside `document()`, which is what let them ignore `dryRun` and write anyway while
/// reporting `dryRun: false` and a past-tense sentence. One place to end them means the flag can't be
/// dropped by the next action that joins them: it decides the tense, the `dryRun` field, and whether
/// anything is journaled, together.
private func metadata(_ spec: ApiActionSpec, _ options: ApiOptions, path: String,
                      _ phrase: Phrase) -> ApiResult {
    if !options.dryRun {
        ApiJournal.recordMetadata(action: spec.name, project: path, summary: phrase.past + ".",
                                  source: options.source)
    }
    return ApiResult(action: spec.name, summary: phrase.sentence(dryRun: options.dryRun),
                     dryRun: options.dryRun, data: .string(path))
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
    /// Events for the project's pick log, appended after the notes are written. A pick changes nothing
    /// in the notes (unless it had to start a sitting), so this is most of what those actions do.
    var sidecar: [PickEvent] = []
}

/// What an action that needs more than the text gets to see: when the project was last edited, for
/// the ones that resolve the current session, and where it lives, for the ones that read its pick log.
struct DocumentContext {
    let rawText: String
    let lastEdited: Date?
    let projectPath: String
}

/// Read once, transform, diff, and write unless this is a dry run.
///
/// The single place a notes file is written by the contract, which is what lets `dryRun` be the same
/// path minus its last step rather than a second implementation that predicts what the first would do.
private func document(_ spec: ApiActionSpec, _ input: ApiInput, _ options: ApiOptions,
                      _ apply: (String) throws -> Outcome) throws -> ApiResult {
    try document(spec, input, options) { rawText, _ in try apply(rawText) }
}

/// `document`, for the three actions that also need to know when the project was last edited — the
/// ones that resolve "the current session", which is a question about how long ago that was. See
/// `SessionWindow.swift`.
///
/// A separate entry point rather than a second parameter on every closure: nine of the twelve actions
/// have no use for it, and the date is read here rather than by each of them because this is where the
/// notes file is already resolved.
private func document(_ spec: ApiActionSpec, _ input: ApiInput, _ options: ApiOptions,
                      _ apply: (String, Date?) throws -> Outcome) throws -> ApiResult {
    try document(spec, input, options) { (context: DocumentContext) in
        try apply(context.rawText, context.lastEdited)
    }
}

/// `document`, for the actions that read or write the project's pick log as well as its notes.
private func document(_ spec: ApiActionSpec, _ input: ApiInput, _ options: ApiOptions,
                      _ apply: (DocumentContext) throws -> Outcome) throws -> ApiResult {
    let handle = try resolveNotesHandle(project: try resolvedProject(input))
    let lastEdited = notesLastEdited(path: handle.notesPath)
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

    let outcome = try apply(DocumentContext(rawText: rawText, lastEdited: lastEdited,
                                            projectPath: handle.projectPath))
    let after = try parseTodos(notes: normalizeFocusMarker(notes: parseNotes(markdown: outcome.rawText)))
    let changes = diffTodos(before: before, after: after)

    let batch = (input.tasks?.count ?? 1) > 1
    let phrase = outcome.note ?? summarize(action: spec.name, changes: changes, batch: batch)
    // The receipt, and after it the aside that a reference had to move — see `tellingItHadMoved`,
    // which is where the argument for saying it here lives. Not on the phrase the journal records:
    // that is a label for an undo step, and where the task was found is not part of what changed.
    let told = outcome.relocated ? phrase.tellingItHadMoved(batch: batch) : phrase
    if !options.dryRun, outcome.rawText != rawText {
        try handle.io.writeContent(path: handle.notesPath, content: outcome.rawText)
        // After the write, never before: a journal entry for a write that then failed would be a
        // record of something that didn't happen, and an undo offered for it would do harm.
        ApiJournal.record(action: spec.name, project: handle.projectPath, notesPath: handle.notesPath,
                          summary: phrase.past, before: rawText, after: outcome.rawText,
                          changed: changes, source: options.source,
                          sidecar: outcome.sidecar.map(\.id))
    }
    // After the notes, for the same reason the journal is: a pick into a sitting whose heading failed
    // to write would name a sitting that isn't there.
    if !options.dryRun {
        try PickLog.append(outcome.sidecar, projectPath: handle.projectPath)
        // A pick that changed nothing in the notes is still a write, and still something another
        // surface should be able to take back — so it is journaled on its own, with no document behind
        // it. Reversing it needs no revision check: a `released` only cancels the pick it names.
        if outcome.rawText == rawText, !outcome.sidecar.isEmpty {
            ApiJournal.recordSidecar(action: spec.name, project: handle.projectPath,
                                     summary: phrase.past, ids: outcome.sidecar.map(\.id),
                                     source: options.source)
        }
    }
    return ApiResult(action: spec.name,
                     summary: told.sentence(dryRun: options.dryRun),
                     revision: revision(of: outcome.rawText),
                     changed: changes,
                     focus: after.first(where: \.isFocused).map(reference(to:)),
                     relocated: outcome.relocated,
                     dryRun: options.dryRun,
                     data: outcome.data,
                     sidecar: options.dryRun || outcome.sidecar.isEmpty ? nil : outcome.sidecar)
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

// MARK: - Picking up

/// What picking up a set of references came to, before anyone words it.
private struct PickUp {
    /// The text with the current sitting in it — started, if the project was cold. Only worth writing
    /// when `events` isn't empty: nothing picked, nothing should start.
    var rawText: String
    var events: [PickEvent] = []
    var picked: [String] = []
    var alreadyHere = 0
    var alreadyPicked = 0
    var relocated = false
    var into: PickedInto
    var intoIndex: Int
}

/// Pick up each reference into the current sitting, skipping the ones already in it or already picked
/// up into it. Shared by `task.pick` and by the focus that picks up (docs/sessions.md D4).
private func pickUp(_ references: [TaskRefInput], batch: Bool, _ context: DocumentContext,
                    source: String) throws -> PickUp {
    let session = try currentSession(in: context.rawText, lastEdited: context.lastEdited)
    let text = session.rawText
    let notes = normalizeFocusMarker(notes: try parseNotes(markdown: text))
    let todos = try parseTodos(notes: notes)
    guard let into = PickLog.sitting(at: session.sessionIndex, in: notes) else {
        throw ApiError(.writeFailed, "The current session's heading isn't a date PM can name.")
    }
    let standing = PickLog.resolved(projectPath: context.projectPath, notes: notes, todos: todos)
    let at = timestamp()

    // What's already picked up into the current sitting, as the trees it covers. A pick written before
    // picks named trees can name a subtask; it covers that subtask's tree all the same.
    let pickedHere = Set(standing.filter { $0.intoIndex == session.sessionIndex }.compactMap { pick in
        todos.first { $0.sessionIndex == pick.sessionIndex && $0.lineIndex == pick.lineIndex }
            .map { treeKey(TaskTree.root(of: $0, in: todos)) }
    })

    var out = PickUp(rawText: text, into: into, intoIndex: session.sessionIndex)
    var seen = Set<String>()
    for reference in references {
        guard let position = try resolve(reference, in: text, batch: batch) else { continue }
        out.relocated = out.relocated || position.relocated
        guard let touched = todos.first(where: {
                  $0.sessionIndex == position.sessionIndex && $0.lineIndex == position.lineIndex
              }) else { continue }
        // A pick names the tree, by its root: working on a subtask is working on the task it's part of,
        // and the root is the line that says what that is (docs/sessions.md D3).
        let todo = TaskTree.root(of: touched, in: todos)
        guard seen.insert(treeKey(todo)).inserted else { continue }
        if todo.sessionIndex == session.sessionIndex { out.alreadyHere += 1; continue }
        if pickedHere.contains(treeKey(todo)) { out.alreadyPicked += 1; continue }
        guard let task = PickLog.task(todo, in: notes) else {
            throw ApiError(.invalidField, "\u{201C}\(todo.text)\u{201D} is under a heading PM can't date, so it can't be picked up.",
                           detail: .string("task"))
        }
        out.events.append(PickEvent(at: at, event: .picked, task: task, into: into, source: source))
        out.picked.append(todo.text)
    }
    return out
}

private func treeKey(_ root: Todo) -> String { "\(root.sessionIndex):\(root.lineIndex)" }

/// `task.pick`: record that each task's tree was picked up into the current sitting.
///
/// Starts the sitting when the project is cold, the one change to the notes a pick can make — and only
/// when something is actually picked, so asking to pick up a task that's already here writes nothing.
private func picking(_ input: ApiInput, _ context: DocumentContext, source: String) throws -> Outcome {
    let result = try pickUp(try references(input), batch: input.tasks != nil, context, source: source)
    let data: JSONValue = .object(["into": .string(result.into.session),
                                   "intoIndex": .number(Double(result.intoIndex))])
    guard !result.events.isEmpty else {
        let finding = result.alreadyPicked > 0 && result.alreadyHere == 0
            ? (input.tasks == nil ? "That task is already picked up" : "Those tasks are already picked up")
            : (input.tasks == nil ? "That task is already in this session" : "Those tasks are already in this session")
        // The original text, not the one with a new sitting spliced in: nothing was picked, so nothing
        // should start.
        return Outcome(rawText: context.rawText, relocated: result.relocated, note: .statement(finding), data: data)
    }
    let what = result.picked.count == 1 ? "\u{201C}\(result.picked[0])\u{201D}" : "\(result.picked.count) tasks"
    return Outcome(rawText: result.rawText, relocated: result.relocated,
                   note: Phrase(past: "Picked up \(what)", future: "pick up \(what)"),
                   data: data, sidecar: result.events)
}

/// `task.focus`, picking up: focusing a task from an older sitting is working on it now, so it is
/// picked up into the current one first (docs/sessions.md D3). A task that can't be picked up — under
/// a heading PM can't date, or in a project whose current heading it can't — is focused all the same:
/// the pick is a record kept alongside the focus, never a reason to refuse it.
private func focusing(_ input: ApiInput, _ context: DocumentContext, source: String) throws -> Outcome {
    let reference = try references(input)[0]
    var text = context.rawText
    var events: [PickEvent] = []
    var relocated = false
    if let result = try? pickUp([reference], batch: false, context, source: source), !result.events.isEmpty {
        text = result.rawText
        events = result.events
        relocated = result.relocated
    }
    // Resolved again against the text the pick left, which may have a sitting spliced in above the
    // task. The reference names it by date, so that finds the same line.
    let at = try resolveTaskRef(reference.ref, rawText: text)
    let focused = try editTodosPreservingFormat(rawText: text) { notes in
        applyFocusToTodoAt(notes: normalizeFocusMarker(notes: notes), sessionIndex: at.sessionIndex,
                           lineIndex: at.lineIndex)
    } ?? text
    guard let picked = events.first?.task.text else {
        return Outcome(rawText: focused, relocated: relocated || at.relocated)
    }
    let what = "\u{201C}\(picked)\u{201D}"
    return Outcome(rawText: focused, relocated: relocated || at.relocated,
                   note: Phrase(past: "Picked up and focused \(what)", future: "pick up and focus \(what)"),
                   sidecar: events)
}

/// `task.release`: put each task back — cancel its pick into the named sitting, or its latest pick when
/// no sitting is named. The task itself isn't touched.
private func releasing(_ input: ApiInput, _ context: DocumentContext, source: String) throws -> Outcome {
    let notes = normalizeFocusMarker(notes: try parseNotes(markdown: context.rawText))
    let todos = try parseTodos(notes: notes)
    let sitting = input.session == nil ? nil : try sessionIndex(input, in: notes)
    let standing = PickLog.resolved(projectPath: context.projectPath, notes: notes, todos: todos)
    let at = timestamp()

    var events: [PickEvent] = []
    var released: [String] = []
    var relocated = false
    // Each standing pick, by the tree it covers.
    func root(_ pick: PickLog.Resolved) -> String? {
        todos.first { $0.sessionIndex == pick.sessionIndex && $0.lineIndex == pick.lineIndex }
            .map { treeKey(TaskTree.root(of: $0, in: todos)) }
    }
    for reference in try references(input) {
        guard let position = try resolve(reference, in: context.rawText, batch: input.tasks != nil) else { continue }
        relocated = relocated || position.relocated
        guard let touched = todos.first(where: {
            $0.sessionIndex == position.sessionIndex && $0.lineIndex == position.lineIndex
        }) else { continue }
        // Putting back any line of a picked tree puts the tree back. Without a sitting named, that's
        // the tree's latest pick; every pick into that one sitting goes with it, since a pick written
        // before picks named trees may name a subtask and would otherwise leave the tree standing.
        let tree = TaskTree.root(of: touched, in: todos)
        let covering = standing.filter { root($0) == treeKey(tree) && (sitting == nil || $0.intoIndex == sitting) }
        guard let latest = covering.last else { continue }
        let cancelled = covering.filter { $0.intoIndex == latest.intoIndex }
            .filter { pick in !events.contains { $0.reverses == pick.event.id } }
        guard !cancelled.isEmpty else { continue }
        for pick in cancelled {
            events.append(PickEvent(at: at, event: .released, task: pick.event.task, into: pick.event.into,
                                    reverses: pick.event.id, source: source))
        }
        released.append(tree.text)
    }
    guard !events.isEmpty else {
        return Outcome(rawText: context.rawText, relocated: relocated,
                       note: .statement(input.tasks == nil ? "That task isn't picked up"
                                                           : "None of those tasks are picked up"))
    }
    let what = released.count == 1 ? "\u{201C}\(released[0])\u{201D}" : "\(released.count) tasks"
    return Outcome(rawText: context.rawText, relocated: relocated,
                   note: Phrase(past: "Put back \(what)", future: "put back \(what)"), sidecar: events)
}

/// The `retargeted` a rename owes the picks of the task it renamed, so they follow it rather than go
/// stale. Nothing when the task wasn't picked up, or its text didn't change.
private func retargeting(_ at: ResolvedTaskRef, from context: DocumentContext, to renamed: String,
                         source: String) throws -> [PickEvent] {
    let before = normalizeFocusMarker(notes: try parseNotes(markdown: context.rawText))
    let beforeTodos = try parseTodos(notes: before)
    let picks = PickLog.resolved(projectPath: context.projectPath, notes: before, todos: beforeTodos)
        .filter { $0.sessionIndex == at.sessionIndex && $0.lineIndex == at.lineIndex }
    guard !picks.isEmpty else { return [] }
    let after = normalizeFocusMarker(notes: try parseNotes(markdown: renamed))
    guard let todo = try parseTodos(notes: after).first(where: {
              $0.sessionIndex == at.sessionIndex && $0.lineIndex == at.lineIndex }),
          let was = beforeTodos.first(where: {
              $0.sessionIndex == at.sessionIndex && $0.lineIndex == at.lineIndex }),
          let task = PickLog.task(todo, in: after) else { return [] }
    let from = was.digest ?? taskDigest(was.text)
    guard task.digest != from else { return [] }
    return [PickEvent(at: timestamp(), event: .retargeted, task: PickedTask(
                session: task.session, ordinal: task.ordinal, line: task.line, digest: from, text: task.text),
                      retargets: picks.map(\.event.id), to: task.digest, source: source)]
}

private func timestamp(_ date: Date = Date()) -> String { PickLog.timestamp(date) }

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
///
/// This used to parse the document here, alongside `notesShow` parsing it there — two implementations
/// of one read, one of which knew about revisions. Now there is one, and the revision comes back from
/// it whoever asked.
/// The name of the project a read resolved to — the one thing a caller can't otherwise learn when it
/// left `project` out and the focused one answered.
private func projectTitleOf(_ input: ApiInput) throws -> String {
    let path = try resolveProjectPath(nameOrPrefix: try resolvedProject(input))
    return projectTitle(fromFolderName: (path as NSString).lastPathComponent)
}

/// Tasks as a caller reads them: each says which project it is in, and its `context` calls the
/// sitting a session. `context` used to read "Fri, Sep 18 · General Work", and a label after a date
/// reads as a place — a reader took "General Work" for a project. The Mac app keeps the plain form.
private func labelled(_ todos: [Todo], in read: NotesShowOutput, project: String) throws -> JSONValue {
    guard case .array(let entries) = try JSONValue.encoding(todos) else { return .null }
    return .array(zip(todos, entries).map { todo, entry in
        guard case .object(var fields) = entry else { return entry }
        fields["project"] = .string(project)
        if read.notes.sessions.indices.contains(todo.sessionIndex) {
            let session = read.notes.sessions[todo.sessionIndex]
            if !session.label.isEmpty {
                fields["sessionLabel"] = .string(session.label)
                fields["context"] = .string("\(session.date) · session: \(session.label)")
            }
        }
        return .object(fields)
    })
}

private func readProject(_ input: ApiInput) throws -> NotesShowOutput {
    try notesShow(handle: try resolveNotesHandle(project: try resolvedProject(input)))
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

/// The session a write lands in, creating it in the markdown when the project hasn't got one for
/// today or has been left alone long enough that this is a new sitting. See `SessionWindow.swift`.
private func currentSession(in rawText: String, lastEdited: Date?,
                            label: String? = nil, forcingNew: Bool = false) throws -> CurrentSession {
    guard let session = try currentSessionPreservingFormat(rawText: rawText, lastEdited: lastEdited,
                                                           label: label, forcingNew: forcingNew) else {
        throw PmError.notesNotFound("## Sessions")
    }
    return session
}

private func focusing(_ rawText: String, sessionIndex: Int, lineIndex: Int) throws -> String {
    try editTodosPreservingFormat(rawText: rawText) { notes in
        applyFocusToTodoAt(notes: normalizeFocusMarker(notes: notes),
                           sessionIndex: sessionIndex, lineIndex: lineIndex)
    } ?? rawText
}

/// A session named by ISO date (preferred) or index, the same either-or a task reference accepts.
/// Which session an action's input names, resolved through `SessionRef` so the date/ordinal/digest
/// rules live in one tested place rather than being restated here.
///
/// `session` is an ISO date or an index, the same either-or it has always been; `sessionDigest` is the
/// new part, and optional in the same spirit as a task's — a person typing an index at a prompt asserts
/// nothing, while a caller that read early and acts late should always send one.
private func sessionIndex(_ input: ApiInput, in notes: ProjectNotes) throws -> Int {
    guard let session = input.session else {
        throw ApiError(.missingField, "This action needs a session.", detail: .string("session"))
    }
    let ref: SessionRef
    if let index = Int(session) {
        ref = SessionRef(date: nil, ordinal: 0, index: index, digest: input.sessionDigest)
    } else {
        ref = SessionRef(date: session, ordinal: input.sessionOrdinal ?? 0,
                         index: nil, digest: input.sessionDigest)
    }
    return try resolveSessionRef(ref, notes: notes).index
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
public func revision(of content: String) -> String {
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

// MARK: - Cards

/// A project's board as a document, or an empty one when it hasn't got a board yet.
///
/// Empty rather than an error: "what does this project hold?" has an honest answer for a project with
/// no canvas, and it is "nothing". Only adding makes one.
private func readProjectCanvas(at projectPath: String) throws -> CanvasDocument {
    guard let path = try resolveProjectCanvasPath(projectPath: projectPath) else { return CanvasDocument() }
    return try CanvasDocument.parse(Data(contentsOf: URL(fileURLWithPath: path)))
}

/// One item on the wire (docs/items.md D2). The same fields every lens draws, named the same way.
private func described(_ item: CanvasItem) -> JSONValue {
    var kind = "text"
    var detail = item.detail
    switch item.kind {
    case .text: kind = "text"
    case .file: kind = "file"
    case .view: kind = "view"
    case .page(let host):
        kind = "page"
        detail = detail ?? host
    }
    return .object([
        "id": .string(item.id),
        "title": .string(item.title),
        "kind": .string(kind),
        "detail": detail.map(JSONValue.string) ?? .null,
    ])
}
