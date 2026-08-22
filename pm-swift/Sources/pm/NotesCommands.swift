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
        let output = try notesShow(project: project)
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

/// `pm notes session note <project> <text>` — append a note to today's session, creating today's
/// session if the project hasn't got one yet.
func runNotesSessionNote(args: [String]) {
    guard args.count >= 2 else {
        stderr("Usage: pm notes session note <project> <text>")
        exit(1)
    }
    do {
        let date = try appendNoteToTodaySession(project: args[0], prose: args[1])
        print("Added note to session: \(date)")
    } catch { fail(error) }
}

// MARK: - Addressing a task
//
// Every `pm notes todo` subcommand names its task the same way: `<project> <session> <line>`, where
// `<session>` is either the session's index or its ISO date. The date form is the stable one —
// sessions are newest-first, so starting one renumbers every index below it — and it is what a
// caller that read the project earlier should be using.
//
// `--digest` carries the short hash of the text the caller believes that task has, from `notes show`.
// It is optional because a human typing an index at a terminal is asserting nothing; a client that
// read minutes ago is, and should send it. See docs/task-identity.md.

private let refUsageSuffix = "[--digest HASH] [--session-ordinal N]\n" +
    "  <session> is a session index or an ISO date (YYYY-MM-DD)."

/// Pull the reference flags out of an argument list, leaving the positionals.
private func takeRefFlags(_ args: [String]) -> (rest: [String], digest: String?, ordinal: Int) {
    var rest: [String] = [], digest: String?, ordinal = 0
    var i = 0
    while i < args.count {
        switch args[i] {
        case "--digest":
            guard i + 1 < args.count else { stderr("--digest requires a value"); exit(1) }
            digest = args[i + 1]; i += 2
        case "--session-ordinal":
            guard i + 1 < args.count, let n = Int(args[i + 1]), n >= 0 else {
                stderr("--session-ordinal requires a non-negative number"); exit(1)
            }
            ordinal = n; i += 2
        default:
            rest.append(args[i]); i += 1
        }
    }
    return (rest, digest, ordinal)
}

/// `<project> <session> <line>` plus flags, or exit with `usage`. `<session>` is an index or an
/// ISO date; anything else is a mistake worth naming rather than silently reading as index 0.
private func parseTaskAddress(_ args: [String], usage: String) -> (project: String, ref: TaskRef) {
    let (rest, digest, ordinal) = takeRefFlags(args)
    guard rest.count >= 3, let lineIndex = Int(rest[2]) else { stderr(usage); exit(1) }
    let session = rest[1]
    if let sessionIndex = Int(session) {
        return (rest[0], TaskRef(sessionIndex: sessionIndex, lineIndex: lineIndex, digest: digest))
    }
    guard (try? parseSessionDateArgument(session)) != nil else {
        stderr("Session must be an index or an ISO date (YYYY-MM-DD), not: \(session)")
        exit(1)
    }
    return (rest[0], TaskRef(sessionDate: session, sessionOrdinal: ordinal,
                             lineIndex: lineIndex, digest: digest))
}

/// Say so when a reference had to move to find its task. The write already happened and was correct;
/// this is so a client that has been holding stale positions finds out it is doing so.
private func reportRelocation(_ resolved: ResolvedTaskRef) {
    guard resolved.relocated else { return }
    stderr("note: that task had moved; acted on it at session \(resolved.sessionIndex), line \(resolved.lineIndex)")
}

func runNotesTodoComplete(args: [String]) {
    let usage = "Usage: pm notes todo complete <project> <session> <line> [--no-advance] \(refUsageSuffix)"
    let advanceFocus = !args.contains("--no-advance")
    let (project, ref) = parseTaskAddress(args.filter { $0 != "--no-advance" }, usage: usage)
    do {
        reportRelocation(try completeTodo(project: project, ref: ref, advanceFocus: advanceFocus))
    } catch { fail(error) }
}

func runNotesTodoFocus(args: [String]) {
    let (project, ref) = parseTaskAddress(
        args, usage: "Usage: pm notes todo focus <project> <session> <line> \(refUsageSuffix)")
    do { reportRelocation(try focusTodo(project: project, ref: ref)) } catch { fail(error) }
}

func runNotesTodoUndo(args: [String]) {
    let (project, ref) = parseTaskAddress(
        args, usage: "Usage: pm notes todo undo <project> <session> <line> \(refUsageSuffix)")
    do { reportRelocation(try undoTodo(project: project, ref: ref)) } catch { fail(error) }
}

func runNotesTodoAdd(args: [String]) {
    let usage = "Usage: pm notes todo add <project> <text> [--due DATE] " +
        "[--child|--before|--after <session> <line>] \(refUsageSuffix)"
    let (rest, digest, ordinal) = takeRefFlags(args)
    guard let project = rest.first else { stderr(usage); exit(1) }
    let tail = Array(rest.dropFirst())
    var due: String?
    var position: (kind: TaskInsertPosition, anchor: TaskRef)?
    var text: String?
    var i = 0
    while i < tail.count {
        let a = tail[i]
        switch a {
        case "--due":
            guard i + 1 < tail.count else { stderr("--due requires a value"); exit(1) }
            due = tail[i + 1]; i += 2
        case "--child", "--before", "--after":
            guard i + 2 < tail.count, let li = Int(tail[i + 2]) else {
                stderr("\(a) requires <session> <line>"); exit(1)
            }
            let session = tail[i + 1]
            let anchor: TaskRef
            if let si = Int(session) {
                anchor = TaskRef(sessionIndex: si, lineIndex: li, digest: digest)
            } else if (try? parseSessionDateArgument(session)) != nil {
                anchor = TaskRef(sessionDate: session, sessionOrdinal: ordinal, lineIndex: li, digest: digest)
            } else {
                stderr("Session must be an index or an ISO date (YYYY-MM-DD), not: \(session)"); exit(1)
            }
            let kind: TaskInsertPosition = a == "--child" ? .child : (a == "--before" ? .before : .after)
            position = (kind, anchor); i += 3
        default:
            if text == nil { text = a } else { stderr("Unexpected argument: \(a)"); exit(1) }
            i += 1
        }
    }
    guard let taskText = text, !taskText.trimmingCharacters(in: .whitespaces).isEmpty else {
        stderr("Task text is required\n\(usage)"); exit(1)
    }
    if let d = due, !isValidTodoDue(d) { stderr("Invalid due value: \(d)"); exit(1) }
    do {
        try addTodo(project: project, text: taskText, due: due, position: position)
    } catch { fail(error) }
}

func runNotesTodoDue(args: [String]) {
    let usage = "Usage: pm notes todo due <project> <session> <line> <DATE|--clear> \(refUsageSuffix)"
    let (rest, _, _) = takeRefFlags(args)
    guard rest.count >= 4 else { stderr(usage); exit(1) }
    let (project, ref) = parseTaskAddress(args, usage: usage)
    let dueArg = rest[3]
    let due: String? = dueArg == "--clear" ? nil : dueArg
    if let d = due, !isValidTodoDue(d) { stderr("Invalid due value: \(d)"); exit(1) }
    do { reportRelocation(try setDueOnTodo(project: project, ref: ref, due: due)) } catch { fail(error) }
}

func runNotesTodoText(args: [String]) {
    let usage = "Usage: pm notes todo text <project> <session> <line> <text> \(refUsageSuffix)"
    let (rest, _, _) = takeRefFlags(args)
    guard rest.count >= 4 else { stderr(usage); exit(1) }
    let (project, ref) = parseTaskAddress(args, usage: usage)
    do { reportRelocation(try setTodoText(project: project, ref: ref, text: rest[3])) } catch { fail(error) }
}

func runNotesTodoWrap(args: [String]) {
    let usage = "Usage: pm notes todo wrap <project> <session> <line> <parentText> \(refUsageSuffix)"
    let (rest, _, _) = takeRefFlags(args)
    guard rest.count >= 4 else { stderr(usage); exit(1) }
    let (project, ref) = parseTaskAddress(args, usage: usage)
    do { reportRelocation(try wrapTodo(project: project, ref: ref, text: rest[3])) } catch { fail(error) }
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
            stderr("Usage: pm notes todo <complete|focus|undo|add|due|text|wrap> <project> <session> <line> [--digest HASH] [--no-advance for complete]\n  <session> is a session index or an ISO date (YYYY-MM-DD).")
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
        case "text":
            runNotesTodoText(args: todoArgs)
        case "wrap":
            runNotesTodoWrap(args: todoArgs)
        default:
            stderr("Usage: pm notes todo <complete|focus|undo|add|due|text|wrap> ...")
            exit(1)
        }
    case "session":
        guard args.count >= 3, args[1] == "add" || args[1] == "note" else {
            stderr("Usage: pm notes session <add|note> <project> ...")
            exit(1)
        }
        if args[1] == "note" {
            runNotesSessionNote(args: Array(args.dropFirst(2)))
            return
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
