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

/// Unwrap (dissolve) a parent todo: remove it and promote its children (with their subtrees) one
/// level shallower, into the parent's position. If the dissolved parent held focus, focus moves to
/// its first child so it isn't lost. Format-preserving. Inverse of `wrapTodo`.
public func unwrapTodo(project: String, sessionIndex: Int, lineIndex: Int) throws {
    let handle = try resolveNotesHandle(project: project)
    let rawText = try handle.io.readContent(path: handle.notesPath)
    // Was the dissolved parent the focused task? If so, focus should follow to its first child, which
    // takes over the parent's (sessionIndex, lineIndex) once the parent line is removed.
    let wasFocused = try parseTodos(notes: parseNotes(markdown: rawText)).contains {
        $0.sessionIndex == sessionIndex && $0.lineIndex == lineIndex && $0.isFocused
    }
    guard let updated = unwrapTaskPreservingFormat(
        rawText: rawText, sessionIndex: sessionIndex, lineIndex: lineIndex) else {
        throw PmError.notesNotFound(handle.notesPath)
    }
    var finalText = updated
    if wasFocused {
        if let focused = try editTodosPreservingFormat(rawText: updated, mutate: { notes in
            applyFocusToTodoAt(
                notes: normalizeFocusMarker(notes: notes),
                sessionIndex: sessionIndex,
                lineIndex: lineIndex)
        }) {
            finalText = focused
        }
    }
    try handle.io.writeContent(path: handle.notesPath, content: finalText)
}

/// The line indices, within `sessionIndex`, of the task at `lineIndex` and its descendants — the
/// contiguous run of deeper tasks right after it. Mirrors the subtree rule the raw edits use.
private func subtreeLineIndices(todos: [Todo], sessionIndex: Int, lineIndex: Int) -> Set<Int> {
    let session = todos.filter { $0.sessionIndex == sessionIndex }.sorted { $0.lineIndex < $1.lineIndex }
    guard lineIndex < session.count else { return [] }
    let depth = session[lineIndex].depth
    var indices: Set<Int> = [lineIndex]
    var i = lineIndex + 1
    while i < session.count, session[i].depth > depth {
        indices.insert(i)
        i += 1
    }
    return indices
}

/// Delete a todo and its whole subtree. Format-preserving — only the removed lines change.
///
/// If the removed block carried the ` @` focus marker, focus moves to the next open leaf of what
/// remains (`nextDiveInLeaf` with nothing focused picks the first open leaf in document order), so a
/// delete never leaves the project focus-less. A project with nothing open left simply has no marker.
public func deleteTodo(project: String, sessionIndex: Int, lineIndex: Int) throws {
    let handle = try resolveNotesHandle(project: project)
    let rawText = try handle.io.readContent(path: handle.notesPath)
    let before = try parseTodos(notes: parseNotes(markdown: rawText))
    let removed = subtreeLineIndices(todos: before, sessionIndex: sessionIndex, lineIndex: lineIndex)
    let losesFocus = before.contains {
        $0.sessionIndex == sessionIndex && removed.contains($0.lineIndex) && $0.isFocused
    }
    guard let updated = deleteSubtreePreservingFormat(
        rawText: rawText, sessionIndex: sessionIndex, lineIndex: lineIndex) else {
        throw PmError.notesNotFound(handle.notesPath)
    }
    var finalText = updated
    if losesFocus,
       let next = nextDiveInLeaf(todos: try parseTodos(notes: parseNotes(markdown: updated))),
       let refocused = try editTodosPreservingFormat(rawText: updated, mutate: { notes in
           applyFocusToTodoAt(notes: normalizeFocusMarker(notes: notes),
                              sessionIndex: next.sessionIndex, lineIndex: next.lineIndex)
       }) {
        finalText = refocused
    }
    try handle.io.writeContent(path: handle.notesPath, content: finalText)
}

/// Move a todo (and its subtree) to a precise slot — after/before an anchor todo, with the root
/// re-indented to `depth` — preserving format. The source lines travel verbatim (checkbox, due, and
/// focus marker included), only their indent changes, so focus follows the moved task. Moves may cross
/// session boundaries. Drives the panel's drag-reorder (Y picks the anchor/slot, X picks the depth).
public func moveSubtree(
    project: String,
    sourceSessionIndex: Int,
    sourceLineIndex: Int,
    anchorSessionIndex: Int,
    anchorLineIndex: Int,
    insertAfterAnchor: Bool,
    depth: Int
) throws {
    let handle = try resolveNotesHandle(project: project)
    let rawText = try handle.io.readContent(path: handle.notesPath)
    guard let updated = moveSubtreePreservingFormat(
        rawText: rawText,
        sourceSessionIndex: sourceSessionIndex,
        sourceLineIndex: sourceLineIndex,
        anchorSessionIndex: anchorSessionIndex,
        anchorLineIndex: anchorLineIndex,
        insertAfterAnchor: insertAfterAnchor,
        depth: depth) else {
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

// MARK: - Session operations (create / rename / delete / prose note)

/// Add a new (empty) session at the top of the Sessions list, dated `date` with an optional `label`.
/// Format-preserving; falls back to nothing if there's no "## Sessions" heading to splice into.
public func addSession(project: String, label: String, date: Date = Date()) throws {
    let handle = try resolveNotesHandle(project: project)
    let rawText = try handle.io.readContent(path: handle.notesPath)
    let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let updated = sessionAddPreservingFormat(rawText: rawText, label: trimmed, date: date) else {
        throw PmError.notesNotFound(handle.notesPath)
    }
    try handle.io.writeContent(path: handle.notesPath, content: updated)
}

/// Rename a session's label (its trailing text after the date), preserving the date and body.
public func renameSession(project: String, sessionIndex: Int, label: String) throws {
    let handle = try resolveNotesHandle(project: project)
    let rawText = try handle.io.readContent(path: handle.notesPath)
    guard let updated = renameSessionPreservingFormat(rawText: rawText, sessionIndex: sessionIndex, label: label) else {
        throw PmError.notesNotFound(handle.notesPath)
    }
    try handle.io.writeContent(path: handle.notesPath, content: updated)
}

/// Set (create/replace/clear) a session's note. The freeform text is sanitized so it can't break the
/// document (headings clamp to within-session levels; typed checkboxes graduate into real tasks in the
/// session's task list). Empty prose removes the note.
public func setSessionNote(project: String, sessionIndex: Int, prose: String) throws {
    let handle = try resolveNotesHandle(project: project)
    let rawText = try handle.io.readContent(path: handle.notesPath)
    guard let updated = commitSessionNotePreservingFormat(rawText: rawText, sessionIndex: sessionIndex, prose: prose) else {
        throw PmError.notesNotFound(handle.notesPath)
    }
    try handle.io.writeContent(path: handle.notesPath, content: updated)
}

/// Append `prose` to today's session note, creating today's session when the project hasn't got one
/// yet. Returns the session's date string, so a caller can say which session it landed in.
///
/// Appending, not replacing: the note is a running log of the day, so a second note joins the first
/// under a blank line rather than overwriting it. Empty prose is rejected.
@discardableResult
public func appendNoteToTodaySession(project: String, prose: String) throws -> String {
    guard !prose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw PmError.emptySessionNote
    }
    let handle = try resolveNotesHandle(project: project)
    let rawText = try handle.io.readContent(path: handle.notesPath)
    guard let updated = try appendSessionNotePreservingFormat(rawText: rawText, prose: prose) else {
        throw PmError.notesNotFound(handle.notesPath)
    }
    try handle.io.writeContent(path: handle.notesPath, content: updated)
    return formatSessionDate()
}

/// Delete a session (heading + body). The caller gates this to sessions with no tasks.
public func deleteSession(project: String, sessionIndex: Int) throws {
    let handle = try resolveNotesHandle(project: project)
    let rawText = try handle.io.readContent(path: handle.notesPath)
    guard let updated = deleteSessionPreservingFormat(rawText: rawText, sessionIndex: sessionIndex) else {
        throw PmError.notesNotFound(handle.notesPath)
    }
    try handle.io.writeContent(path: handle.notesPath, content: updated)
}

/// Sweep out every session left with nothing in it — no note, no tasks, just a heading. Returns the
/// number removed (0 when there was nothing to prune, in which case the file isn't touched). Callers
/// use this on *open*, not on every write, so a session you add stays put while you're working in it.
@discardableResult
public func pruneEmptySessions(project: String) throws -> Int {
    try pruneEmptySessions(handle: try resolveNotesHandle(project: project))
}

/// `pruneEmptySessions(project:)` for a caller that already resolved the notes handle.
@discardableResult
public func pruneEmptySessions(handle: NotesHandle) throws -> Int {
    let rawText = try handle.io.readContent(path: handle.notesPath)
    guard let result = pruneEmptySessionsPreservingFormat(rawText: rawText) else { return 0 }
    try handle.io.writeContent(path: handle.notesPath, content: result.rawText)
    return result.removed
}

/// Append a task to the end of a specific session's task list (or right after its heading when it has
/// no tasks yet), preserving format. Lets the panel populate an otherwise-empty session directly.
public func appendTaskToSession(project: String, sessionIndex: Int, text: String, due: String?) throws {
    guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { throw PmError.emptyTodoText }
    if let d = due, !isValidTodoDue(d) { throw PmError.invalidTodoDue(d) }
    let handle = try resolveNotesHandle(project: project)
    let rawText = try handle.io.readContent(path: handle.notesPath)
    guard let result = appendTaskToSession(rawText: rawText, sessionIndex: sessionIndex, text: text, due: due) else {
        throw PmError.notesNotFound(handle.notesPath)
    }
    try handle.io.writeContent(path: handle.notesPath, content: result.rawText)
}
