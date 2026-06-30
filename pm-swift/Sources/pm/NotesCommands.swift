import Foundation
import PmLib

func runNotesPath(args: [String]) {
    guard let project = args.first else {
        stderr("Usage: pm notes path <project>")
        exit(1)
    }
    do {
        let projectPath = try resolveProjectPath(nameOrPrefix: project)
        guard let notesPath = try resolveNotesPath(projectPath: projectPath) else {
            fail(PmError.notesNotFound(getNotesPath(projectPath: projectPath)))
        }
        print(notesPath)
    } catch { fail(error) }
}

func runNotesCreate(args: [String]) {
    guard let project = args.first else {
        stderr("Usage: pm notes create <project>")
        exit(1)
    }
    do {
        let projectPath = try resolveProjectPath(nameOrPrefix: project)
        let notesPath = try createNotesFromTemplate(projectPath: projectPath)
        print("Created: \(notesPath)")
    } catch { fail(error) }
}

func runNotesCurrentDay() {
    print(formatSessionDate())
}

func runNotesShow(args: [String]) {
    guard let project = args.first else {
        stderr("Usage: pm notes show <project>")
        exit(1)
    }
    do {
        let projectPath = try resolveProjectPath(nameOrPrefix: project)
        guard let notesPath = try resolveNotesPath(projectPath: projectPath) else {
            fail(PmError.notesNotFound(getNotesPath(projectPath: projectPath)))
        }
        guard let config = try loadConfig() else { throw PmError.configNotFound }
        let io = makeNotesIO(notesPath: notesPath, config: config)
        var notes = try readNotesFile(notesPath: notesPath, notesIO: io)
        notes = normalizeFocusMarker(notes: notes)
        let todos = try parseTodos(notes: notes)
        let todosWithEffective = todosWithEffectiveDueDates(todos)
        let focusedKey = todosWithEffective.first(where: { $0.isFocused }).map { "\($0.sessionIndex):\($0.lineIndex)" }
        let output = NotesShowOutput(notes: notes, todos: todosWithEffective, focusedKey: focusedKey)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(output)
        guard let str = String(data: data, encoding: .utf8) else {
            stderr("Failed to encode notes output as UTF-8.")
            exit(1)
        }
        print(str)
    } catch { fail(error) }
}

func runNotesWrite(args: [String]) {
    guard let project = args.first else {
        stderr("Usage: pm notes write <project>")
        exit(1)
    }
    do {
        let projectPath = try resolveProjectPath(nameOrPrefix: project)
        guard let notesPath = try resolveNotesPath(projectPath: projectPath) else {
            fail(PmError.notesNotFound(getNotesPath(projectPath: projectPath)))
        }
        guard let config = try loadConfig() else { throw PmError.configNotFound }
        let io = makeNotesIO(notesPath: notesPath, config: config)
        let stdinData = FileHandle.standardInput.readDataToEndOfFile()
        let notes: ProjectNotes
        do {
            notes = try JSONDecoder().decode(ProjectNotes.self, from: stdinData)
        } catch {
            stderr("Invalid JSON on stdin: \(error.localizedDescription)")
            exit(1)
        }
        // Splice only the sections that changed, preserving all other formatting. Fall back to the
        // full serializer if the existing file can't be read or a changed section can't be spliced.
        let rawText = try? io.readContent(path: notesPath)
        if let rawText = rawText, let updated = try writeNotesPreservingFormat(rawText: rawText, incoming: notes) {
            try io.writeContent(path: notesPath, content: updated)
        } else {
            try writeNotesFile(notesPath: notesPath, notes: notes, notesIO: io)
        }
    } catch { fail(error) }
}

func runNotesSessionAdd(args: [String], dateStr: String?) {
    guard let project = args.first else {
        stderr("Usage: pm notes session add <project> [label]")
        exit(1)
    }
    let label = args.count > 1 ? args[1] : ""
    do {
        let projectPath = try resolveProjectPath(nameOrPrefix: project)
        guard let notesPath = try resolveNotesPath(projectPath: projectPath) else {
            fail(PmError.notesNotFound(getNotesPath(projectPath: projectPath)))
        }
        guard let config = try loadConfig() else { throw PmError.configNotFound }
        let io = makeNotesIO(notesPath: notesPath, config: config)
        let date: Date?
        if let d = dateStr {
            date = try parseSessionDateArgument(d)
        } else {
            date = nil
        }
        let rawText = try io.readContent(path: notesPath)
        if let updated = sessionAddPreservingFormat(rawText: rawText, label: label, date: date ?? Date()) {
            try io.writeContent(path: notesPath, content: updated)
        } else {
            // No "## Sessions" heading to splice into; fall back to the model round-trip.
            let notes = addSession(notes: try parseNotes(markdown: rawText), label: label, date: date)
            try writeNotesFile(notesPath: notesPath, notes: notes, notesIO: io)
        }
        let sessionDate = formatSessionDate(date ?? Date())
        print("Added session: \(sessionDate) \(label)")
    } catch { fail(error) }
}

func runNotesTodoComplete(args: [String]) {
    let filtered = args.filter { $0 != "--no-advance" }
    guard filtered.count >= 3,
          let sessionIndex = Int(filtered[1]),
          let lineIndex = Int(filtered[2]) else {
        stderr("Usage: pm notes todo complete <project> <sessionIndex> <lineIndex> [--no-advance]")
        exit(1)
    }
    let project = filtered[0]
    let advanceFocus = !args.contains("--no-advance")
    do {
        let projectPath = try resolveProjectPath(nameOrPrefix: project)
        guard let notesPath = try resolveNotesPath(projectPath: projectPath) else {
            fail(PmError.notesNotFound(getNotesPath(projectPath: projectPath)))
        }
        guard let config = try loadConfig() else { throw PmError.configNotFound }
        let io = makeNotesIO(notesPath: notesPath, config: config)
        let rawText = try io.readContent(path: notesPath)
        let updated = try editTodosPreservingFormat(rawText: rawText) { notes in
            let normalized = normalizeFocusMarker(notes: notes)
            return try completeTodoWithDescendants(notes: normalized, sessionIndex: sessionIndex, lineIndex: lineIndex, advanceFocus: advanceFocus)
        }
        if let updated = updated { try io.writeContent(path: notesPath, content: updated) }
    } catch { fail(error) }
}

func runNotesTodoFocus(args: [String]) {
    guard args.count >= 3,
          let sessionIndex = Int(args[1]),
          let lineIndex = Int(args[2]) else {
        stderr("Usage: pm notes todo focus <project> <sessionIndex> <lineIndex>")
        exit(1)
    }
    let project = args[0]
    do {
        let projectPath = try resolveProjectPath(nameOrPrefix: project)
        guard let notesPath = try resolveNotesPath(projectPath: projectPath) else {
            fail(PmError.notesNotFound(getNotesPath(projectPath: projectPath)))
        }
        guard let config = try loadConfig() else { throw PmError.configNotFound }
        let io = makeNotesIO(notesPath: notesPath, config: config)
        let rawText = try io.readContent(path: notesPath)
        let updated = try editTodosPreservingFormat(rawText: rawText) { notes in
            let normalized = normalizeFocusMarker(notes: notes)
            return applyFocusToTodoAt(notes: normalized, sessionIndex: sessionIndex, lineIndex: lineIndex)
        }
        if let updated = updated { try io.writeContent(path: notesPath, content: updated) }
    } catch { fail(error) }
}

func runNotesTodoUndo(args: [String]) {
    guard args.count >= 3,
          let sessionIndex = Int(args[1]),
          let lineIndex = Int(args[2]) else {
        stderr("Usage: pm notes todo undo <project> <sessionIndex> <lineIndex>")
        exit(1)
    }
    let project = args[0]
    do {
        let projectPath = try resolveProjectPath(nameOrPrefix: project)
        guard let notesPath = try resolveNotesPath(projectPath: projectPath) else {
            fail(PmError.notesNotFound(getNotesPath(projectPath: projectPath)))
        }
        guard let config = try loadConfig() else { throw PmError.configNotFound }
        let io = makeNotesIO(notesPath: notesPath, config: config)
        let rawText = try io.readContent(path: notesPath)
        let updated = try editTodosPreservingFormat(rawText: rawText) { notes in
            let normalized = normalizeFocusMarker(notes: notes)
            return try undoTodoAt(notes: normalized, sessionIndex: sessionIndex, lineIndex: lineIndex)
        }
        if let updated = updated { try io.writeContent(path: notesPath, content: updated) }
    } catch { fail(error) }
}

private func isValidDueValue(_ s: String) -> Bool {
    !s.isEmpty && !s.contains("\n") && !s.contains("due:") && !s.contains("@")
}

func runNotesTodoAdd(args: [String]) {
    let usage = "Usage: pm notes todo add <project> <text> [--due DATE] [--child|--before|--after <sessionIndex> <lineIndex>]"
    guard let project = args.first else {
        stderr(usage); exit(1)
    }
    let rest = Array(args.dropFirst())
    var due: String?
    var position: (kind: TaskInsertPosition, si: Int, li: Int)?
    var text: String?
    var i = 0
    while i < rest.count {
        let a = rest[i]
        switch a {
        case "--due":
            guard i + 1 < rest.count else { stderr("--due requires a value"); exit(1) }
            due = rest[i + 1]; i += 2
        case "--child", "--before", "--after":
            guard i + 2 < rest.count, let si = Int(rest[i + 1]), let li = Int(rest[i + 2]) else {
                stderr("\(a) requires <sessionIndex> <lineIndex>"); exit(1)
            }
            let kind: TaskInsertPosition = a == "--child" ? .child : (a == "--before" ? .before : .after)
            position = (kind, si, li); i += 3
        default:
            if text == nil { text = a } else { stderr("Unexpected argument: \(a)"); exit(1) }
            i += 1
        }
    }
    guard let taskText = text, !taskText.trimmingCharacters(in: .whitespaces).isEmpty else {
        stderr("Task text is required\n\(usage)"); exit(1)
    }
    if let d = due, !isValidDueValue(d) { stderr("Invalid due value: \(d)"); exit(1) }
    do {
        let projectPath = try resolveProjectPath(nameOrPrefix: project)
        guard let notesPath = try resolveNotesPath(projectPath: projectPath) else {
            fail(PmError.notesNotFound(getNotesPath(projectPath: projectPath)))
        }
        guard let config = try loadConfig() else { throw PmError.configNotFound }
        let io = makeNotesIO(notesPath: notesPath, config: config)
        var rawText = try io.readContent(path: notesPath)

        let inserted: (rawText: String, sessionIndex: Int, lineIndex: Int)?
        let shouldFocus: Bool
        if let pos = position {
            inserted = insertTaskRelative(
                rawText: rawText,
                anchorSessionIndex: pos.si,
                anchorLineIndex: pos.li,
                text: taskText,
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
                    stderr("Notes file has no \"## Sessions\" section")
                    exit(1)
                }
                rawText = withSession
                notes = try parseNotes(markdown: rawText)
                todayIdx = notes.sessions.firstIndex(where: { $0.date == today })
            }
            guard let si = todayIdx else { stderr("Could not resolve today's session"); exit(1) }
            inserted = appendTaskToSession(rawText: rawText, sessionIndex: si, text: taskText, due: due)
            shouldFocus = true
        }
        guard let result = inserted else {
            stderr("Could not locate the target task to insert relative to")
            exit(1)
        }
        var finalText = result.rawText
        if shouldFocus {
            if let focused = try editTodosPreservingFormat(rawText: result.rawText, mutate: { notes in
                let normalized = normalizeFocusMarker(notes: notes)
                return applyFocusToTodoAt(notes: normalized, sessionIndex: result.sessionIndex, lineIndex: result.lineIndex)
            }) {
                finalText = focused
            }
        }
        try io.writeContent(path: notesPath, content: finalText)
    } catch { fail(error) }
}

func runNotesTodoDue(args: [String]) {
    guard args.count >= 4, let sessionIndex = Int(args[1]), let lineIndex = Int(args[2]) else {
        stderr("Usage: pm notes todo due <project> <sessionIndex> <lineIndex> <DATE|--clear>")
        exit(1)
    }
    let project = args[0]
    let dueArg = args[3]
    let due: String? = dueArg == "--clear" ? nil : dueArg
    if let d = due, !isValidDueValue(d) { stderr("Invalid due value: \(d)"); exit(1) }
    do {
        let projectPath = try resolveProjectPath(nameOrPrefix: project)
        guard let notesPath = try resolveNotesPath(projectPath: projectPath) else {
            fail(PmError.notesNotFound(getNotesPath(projectPath: projectPath)))
        }
        guard let config = try loadConfig() else { throw PmError.configNotFound }
        let io = makeNotesIO(notesPath: notesPath, config: config)
        let rawText = try io.readContent(path: notesPath)
        let updated = try editTodosPreservingFormat(rawText: rawText) { notes in
            setDueOnTodoAt(notes: notes, sessionIndex: sessionIndex, lineIndex: lineIndex, due: due)
        }
        if let updated = updated { try io.writeContent(path: notesPath, content: updated) }
    } catch { fail(error) }
}

func runNotes(args: [String]) {
    guard let sub = args.first else {
        stderr("Usage: pm notes <path|create|show|write|current-day|session|todo> ...")
        exit(1)
    }
    switch sub {
    case "path":
        runNotesPath(args: Array(args.dropFirst()))
    case "create":
        runNotesCreate(args: Array(args.dropFirst()))
    case "show":
        runNotesShow(args: Array(args.dropFirst()))
    case "write":
        runNotesWrite(args: Array(args.dropFirst()))
    case "current-day":
        runNotesCurrentDay()
    case "todo":
        guard args.count >= 3 else {
            stderr("Usage: pm notes todo <complete|focus|undo> <project> <sessionIndex> <lineIndex> [--no-advance for complete]")
            exit(1)
        }
        let sub = args[1]
        let todoArgs = Array(args.dropFirst(2))
        switch sub {
        case "complete":
            runNotesTodoComplete(args: todoArgs)
        case "focus":
            runNotesTodoFocus(args: todoArgs)
        case "undo":
            runNotesTodoUndo(args: todoArgs)
        case "add":
            runNotesTodoAdd(args: todoArgs)
        case "due":
            runNotesTodoDue(args: todoArgs)
        default:
            stderr("Usage: pm notes todo <complete|focus|undo|add|due> ...")
            exit(1)
        }
    case "session":
        guard args.count >= 3, args[1] == "add" else {
            stderr("Usage: pm notes session add <project> [label] [-d|--date YYYY-MM-DD]")
            exit(1)
        }
        var addArgs = Array(args.dropFirst(2))
        var dateStr: String?
        if let idx = addArgs.firstIndex(of: "-d"), idx + 1 < addArgs.count {
            dateStr = addArgs[idx + 1]
            addArgs.remove(at: idx + 1)
            addArgs.remove(at: idx)
        } else if let idx = addArgs.firstIndex(of: "--date"), idx + 1 < addArgs.count {
            dateStr = addArgs[idx + 1]
            addArgs.remove(at: idx + 1)
            addArgs.remove(at: idx)
        }
        runNotesSessionAdd(args: addArgs, dateStr: dateStr)
    default:
        stderr("Usage: pm notes <path|create|show|write|current-day|session|todo> ...")
        exit(1)
    }
}
