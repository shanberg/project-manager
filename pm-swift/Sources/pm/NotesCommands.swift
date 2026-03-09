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
        let focusedKey = todos.first(where: { $0.isFocused }).map { "\($0.sessionIndex):\($0.lineIndex)" }
        let output = NotesShowOutput(notes: notes, todos: todos, focusedKey: focusedKey)
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
        try writeNotesFile(notesPath: notesPath, notes: notes, notesIO: io)
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
        var notes = try readNotesFile(notesPath: notesPath, notesIO: io)
        let date: Date?
        if let d = dateStr {
            date = try parseSessionDateArgument(d)
        } else {
            date = nil
        }
        notes = addSession(notes: notes, label: label, date: date)
        try writeNotesFile(notesPath: notesPath, notes: notes, notesIO: io)
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
        var notes = try readNotesFile(notesPath: notesPath, notesIO: io)
        notes = normalizeFocusMarker(notes: notes)
        notes = try completeTodoWithDescendants(notes: notes, sessionIndex: sessionIndex, lineIndex: lineIndex, advanceFocus: advanceFocus)
        try writeNotesFile(notesPath: notesPath, notes: notes, notesIO: io)
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
        var notes = try readNotesFile(notesPath: notesPath, notesIO: io)
        notes = normalizeFocusMarker(notes: notes)
        notes = applyFocusToTodoAt(notes: notes, sessionIndex: sessionIndex, lineIndex: lineIndex)
        try writeNotesFile(notesPath: notesPath, notes: notes, notesIO: io)
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
        var notes = try readNotesFile(notesPath: notesPath, notesIO: io)
        notes = normalizeFocusMarker(notes: notes)
        notes = try undoTodoAt(notes: notes, sessionIndex: sessionIndex, lineIndex: lineIndex)
        try writeNotesFile(notesPath: notesPath, notes: notes, notesIO: io)
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
        default:
            stderr("Usage: pm notes todo <complete|focus|undo> <project> <sessionIndex> <lineIndex> [--no-advance for complete]")
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
