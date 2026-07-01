import Foundation

/// High-level notes operations shared by the `pm` CLI and native front-ends (the macOS menubar
/// agent app). Each function resolves a project to its notes file, loads it through the right IO
/// strategy (direct or Obsidian CLI), applies a format-preserving mutation, and writes it back —
/// so every caller goes through one code path instead of re-implementing the load/mutate/write dance.
///
/// These wrap the lower-level pure functions in `NotesTodos`, `NotesRawEdit`, and `NotesHelpers`;
/// they own only the file plumbing, keeping the domain logic testable in isolation.

/// Resolved handle to a project's notes file plus the config and IO strategy for it.
public struct NotesHandle {
    public let projectPath: String
    public let notesPath: String
    public let config: PmConfig
    public let io: NotesIO

    public init(projectPath: String, notesPath: String, config: PmConfig, io: NotesIO) {
        self.projectPath = projectPath
        self.notesPath = notesPath
        self.config = config
        self.io = io
    }
}

/// Resolve a project (full name or unambiguous prefix) to its notes file.
/// - Throws: `.projectNotFound`/`.ambiguousProject` from resolution, `.notesNotFound` if the project
///   has no notes file yet, `.configNotFound` if pm is unconfigured.
public func resolveNotesHandle(project: String) throws -> NotesHandle {
    let projectPath = try resolveProjectPath(nameOrPrefix: project)
    guard let notesPath = try resolveNotesPath(projectPath: projectPath) else {
        throw PmError.notesNotFound(getNotesPath(projectPath: projectPath))
    }
    guard let config = try loadConfig() else { throw PmError.configNotFound }
    let io = makeNotesIO(notesPath: notesPath, config: config)
    return NotesHandle(projectPath: projectPath, notesPath: notesPath, config: config, io: io)
}

/// The `pm notes show` payload: parsed notes, todos with effective (inherited) due dates, and the
/// focused todo's stable key. Focus is normalized so at most one line carries the ` @` marker.
public func notesShow(project: String) throws -> NotesShowOutput {
    try notesShow(handle: try resolveNotesHandle(project: project))
}

/// `notesShow` for a pre-resolved handle — lets callers resolve once and reuse the notes path
/// (e.g. to set up a file watch) without a second project-directory scan.
public func notesShow(handle: NotesHandle) throws -> NotesShowOutput {
    var notes = try readNotesFile(notesPath: handle.notesPath, notesIO: handle.io)
    notes = normalizeFocusMarker(notes: notes)
    let todos = todosWithEffectiveDueDates(try parseTodos(notes: notes))
    let focusedKey = todos.first(where: { $0.isFocused }).map { "\($0.sessionIndex):\($0.lineIndex)" }
    return NotesShowOutput(notes: notes, todos: todos, focusedKey: focusedKey)
}

/// Apply a format-preserving todo mutation and write it back. The transform receives freshly-parsed
/// notes with focus already normalized. A no-op transform (returns nil internally) writes nothing.
public func editTodos(project: String, _ mutate: @escaping (ProjectNotes) throws -> ProjectNotes) throws {
    let handle = try resolveNotesHandle(project: project)
    let rawText = try handle.io.readContent(path: handle.notesPath)
    let updated = try editTodosPreservingFormat(rawText: rawText) { notes in
        try mutate(normalizeFocusMarker(notes: notes))
    }
    if let updated = updated {
        try handle.io.writeContent(path: handle.notesPath, content: updated)
    }
}

/// Apply a format-preserving edit to the notes' detail fields (summary/problem/goals/approach/
/// links/learnings/title) and write it back. The transform receives freshly-parsed notes — so
/// sessions and todos are read from disk, not a possibly-stale caller copy — and the splice
/// preserves every untouched section (and the whole Sessions region) byte-for-byte, falling back to
/// a full serialize only if a changed section can't be spliced. A no-op edit writes nothing.
public func editDetails(project: String, _ mutate: (ProjectNotes) throws -> ProjectNotes) throws {
    let handle = try resolveNotesHandle(project: project)
    let rawText = try handle.io.readContent(path: handle.notesPath)
    let current = try parseNotes(markdown: rawText)
    let updated = try mutate(current)
    guard updated != current else { return }
    if let spliced = try writeNotesPreservingFormat(rawText: rawText, incoming: updated) {
        try handle.io.writeContent(path: handle.notesPath, content: spliced)
    } else {
        try writeNotesFile(notesPath: handle.notesPath, notes: updated, notesIO: handle.io)
    }
}

/// Complete a todo (and its descendants). By default advances focus per the now-style rule.
public func completeTodo(project: String, sessionIndex: Int, lineIndex: Int, advanceFocus: Bool = true) throws {
    try editTodos(project: project) { notes in
        try completeTodoWithDescendants(
            notes: notes, sessionIndex: sessionIndex, lineIndex: lineIndex, advanceFocus: advanceFocus)
    }
}

/// Move the single ` @` focus marker onto the given todo line.
public func focusTodo(project: String, sessionIndex: Int, lineIndex: Int) throws {
    try editTodos(project: project) { notes in
        applyFocusToTodoAt(notes: notes, sessionIndex: sessionIndex, lineIndex: lineIndex)
    }
}

/// Undo a completion: re-open the todo and move focus back onto it.
public func undoTodo(project: String, sessionIndex: Int, lineIndex: Int) throws {
    try editTodos(project: project) { notes in
        try undoTodoAt(notes: notes, sessionIndex: sessionIndex, lineIndex: lineIndex)
    }
}

/// Replace a todo's text in place, preserving its checkbox, due, focus marker, and indent.
public func setTodoText(project: String, sessionIndex: Int, lineIndex: Int, text: String) throws {
    guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { throw PmError.emptyTodoText }
    try editTodos(project: project) { notes in
        setTextOnTodoAt(notes: notes, sessionIndex: sessionIndex, lineIndex: lineIndex, text: text)
    }
}

/// Wrap a todo in a new parent task (insert a parent above at the task's indent, nest the task and
/// its subtree under it). Focus stays on the wrapped task. Format-preserving.
public func wrapTodo(project: String, sessionIndex: Int, lineIndex: Int, text: String) throws {
    guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { throw PmError.emptyTodoText }
    let handle = try resolveNotesHandle(project: project)
    let rawText = try handle.io.readContent(path: handle.notesPath)
    guard let updated = wrapTaskPreservingFormat(
        rawText: rawText, sessionIndex: sessionIndex, lineIndex: lineIndex, parentText: text) else {
        throw PmError.notesNotFound(handle.notesPath)
    }
    try handle.io.writeContent(path: handle.notesPath, content: updated)
}

/// Set (or clear, with `due == nil`) the inline `due:` value on a todo line.
public func setDueOnTodo(project: String, sessionIndex: Int, lineIndex: Int, due: String?) throws {
    if let d = due, !isValidTodoDue(d) { throw PmError.invalidTodoDue(d) }
    try editTodos(project: project) { notes in
        setDueOnTodoAt(notes: notes, sessionIndex: sessionIndex, lineIndex: lineIndex, due: due)
    }
}

/// Validate a `due:` value: non-empty, single-line, and free of the reserved `due:` / `@` tokens.
public func isValidTodoDue(_ s: String) -> Bool {
    !s.isEmpty && !s.contains("\n") && !s.contains("due:") && !s.contains("@")
}

/// Add a todo. With `position`, insert relative to an anchor task (child/before/after); a child
/// insert takes focus. Without `position`, quick-add to today's session (creating it if needed) and
/// take focus. Mirrors `pm notes todo add`.
public func addTodo(
    project: String,
    text: String,
    due: String? = nil,
    position: (kind: TaskInsertPosition, sessionIndex: Int, lineIndex: Int)? = nil
) throws {
    guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { throw PmError.emptyTodoText }
    if let d = due, !isValidTodoDue(d) { throw PmError.invalidTodoDue(d) }

    let handle = try resolveNotesHandle(project: project)
    var rawText = try handle.io.readContent(path: handle.notesPath)

    let inserted: (rawText: String, sessionIndex: Int, lineIndex: Int)?
    let shouldFocus: Bool
    if let pos = position {
        inserted = insertTaskRelative(
            rawText: rawText,
            anchorSessionIndex: pos.sessionIndex,
            anchorLineIndex: pos.lineIndex,
            text: text,
            due: due,
            position: pos.kind
        )
        shouldFocus = pos.kind == .child
    } else {
        // Quick add: append to today's session (creating it if needed) and take focus.
        let today = formatSessionDate(Date())
        var notes = try parseNotes(markdown: rawText)
        var todayIdx = notes.sessions.firstIndex(where: { $0.date == today })
        if todayIdx == nil {
            guard let withSession = sessionAddPreservingFormat(rawText: rawText, label: "", date: Date()) else {
                throw PmError.notesNotFound(handle.notesPath)
            }
            rawText = withSession
            notes = try parseNotes(markdown: rawText)
            todayIdx = notes.sessions.firstIndex(where: { $0.date == today })
        }
        guard let si = todayIdx else { throw PmError.notesNotFound(handle.notesPath) }
        inserted = appendTaskToSession(rawText: rawText, sessionIndex: si, text: text, due: due)
        shouldFocus = true
    }

    guard let result = inserted else { throw PmError.notesNotFound(handle.notesPath) }

    var finalText = result.rawText
    if shouldFocus {
        if let focused = try editTodosPreservingFormat(rawText: result.rawText, mutate: { notes in
            applyFocusToTodoAt(
                notes: normalizeFocusMarker(notes: notes),
                sessionIndex: result.sessionIndex,
                lineIndex: result.lineIndex)
        }) {
            finalText = focused
        }
    }
    try handle.io.writeContent(path: handle.notesPath, content: finalText)
}
