import Foundation

/// Focus marker: space + @ at end of task line. Only one such line should exist in the notes file.
private let focusMarkerSuffix = " @"

/// Normalizes session bodies so at most one task line ends with " @". The first such line (by session order, then line order) is kept; all others have " @" stripped.
public func normalizeFocusMarker(notes: ProjectNotes) -> ProjectNotes {
    let todoLinePattern: NSRegularExpression
    do {
        todoLinePattern = try NSRegularExpression(pattern: #"^(\s*-\s+)\[([ xX])\]\s+(.*)$"#)
    } catch {
        return notes
    }
    var foundFirst = false
    var outSessions: [Session] = []
    for session in notes.sessions {
        let lines = session.body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var outLines: [String] = []
        for line in lines {
            guard let m = todoLinePattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let r1 = Range(m.range(at: 1), in: line),
                  let r2 = Range(m.range(at: 2), in: line),
                  let r3 = Range(m.range(at: 3), in: line) else {
                outLines.append(line)
                continue
            }
            var content = String(line[r3])
            let hasFocus = content.hasSuffix(focusMarkerSuffix)
            if hasFocus {
                if foundFirst {
                    content = String(content.dropLast(focusMarkerSuffix.count)).trimmingCharacters(in: .whitespaces)
                    let prefix = String(line[r1])
                    let check = String(line[r2])
                    outLines.append("\(prefix)[\(check)] \(content)")
                } else {
                    foundFirst = true
                    outLines.append(line)
                }
            } else {
                outLines.append(line)
            }
        }
        let newBody = outLines.joined(separator: "\n")
        outSessions.append(Session(date: session.date, label: session.label, body: newBody))
    }
    return ProjectNotes(
        title: notes.title,
        summary: notes.summary,
        problem: notes.problem,
        goals: notes.goals,
        approach: notes.approach,
        links: notes.links,
        learnings: notes.learnings,
        sessions: outSessions
    )
}

public func parseTodos(notes: ProjectNotes) throws -> [Todo] {
    let todoLinePattern: NSRegularExpression
    do {
        todoLinePattern = try NSRegularExpression(pattern: #"^(\s*-\s+)\[([ xX])\]\s+(.*)$"#)
    } catch {
        throw PmError.notesRegexError(pattern: #"^(\s*-\s+)\[([ xX])\]\s+(.*)$"#)
    }
    var todos: [Todo] = []
    var foundFocused = false
    for (sessionIndex, session) in notes.sessions.enumerated() {
        let context = session.label.isEmpty ? session.date : "\(session.date) · \(session.label)"
        let lines = session.body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var lineIndex = 0
        for line in lines {
            guard let m = todoLinePattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let r2 = Range(m.range(at: 2), in: line),
                  let r3 = Range(m.range(at: 3), in: line) else { continue }
            let leadingSpaces = line.prefix(while: { $0 == " " }).count
            let depth = leadingSpaces / 2
            let checked = line[r2].lowercased() == "x"
            var text = String(line[r3])
            let isFocused: Bool
            if text.hasSuffix(focusMarkerSuffix) {
                text = String(text.dropLast(focusMarkerSuffix.count)).trimmingCharacters(in: .whitespaces)
                if !foundFocused {
                    foundFocused = true
                    isFocused = true
                } else {
                    isFocused = false
                }
            } else {
                isFocused = false
            }
            todos.append(Todo(
                text: text,
                checked: checked,
                rawLine: line,
                context: context,
                depth: depth,
                sessionIndex: sessionIndex,
                lineIndex: lineIndex,
                isFocused: isFocused
            ))
            lineIndex += 1
        }
    }
    return todos
}

private let todoLinePattern: NSRegularExpression? = {
    try? NSRegularExpression(pattern: #"^(\s*-\s+)\[([ xX])\]\s+(.*)$"#)
}()

/// Complete the todo at (sessionIndex, lineIndex) and all its descendants. Optionally move focus to next open todo.
public func completeTodoWithDescendants(notes: ProjectNotes, sessionIndex: Int, lineIndex: Int, advanceFocus: Bool) throws -> ProjectNotes {
    let todos = try parseTodos(notes: notes)
    guard sessionIndex < notes.sessions.count else { return notes }
    let sessionTodos = todos.filter { $0.sessionIndex == sessionIndex }.sorted { $0.lineIndex < $1.lineIndex }
    guard lineIndex < sessionTodos.count else { return notes }
    let parent = sessionTodos[lineIndex]
    let parentDepth = parent.depth
    var indicesToComplete: Set<Int> = [lineIndex]
    for i in (lineIndex + 1)..<sessionTodos.count {
        if sessionTodos[i].depth <= parentDepth { break }
        indicesToComplete.insert(i)
    }
    guard let pattern = todoLinePattern else { return notes }
    let session = notes.sessions[sessionIndex]
    let lines = session.body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    var taskCount = 0
    var outLines: [String] = []
    for line in lines {
        guard let m = pattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let r1 = Range(m.range(at: 1), in: line),
              let r2 = Range(m.range(at: 2), in: line),
              let r3 = Range(m.range(at: 3), in: line) else {
            outLines.append(line)
            continue
        }
        let check = String(line[r2])
        let content = String(line[r3])
        let isUnchecked = check.lowercased() != "x"
        let shouldComplete = indicesToComplete.contains(taskCount) && isUnchecked
        if shouldComplete {
            var newContent = content
            if newContent.hasSuffix(focusMarkerSuffix) {
                newContent = String(newContent.dropLast(focusMarkerSuffix.count)).trimmingCharacters(in: .whitespaces)
            }
            let prefix = String(line[r1])
            outLines.append("\(prefix)[x] \(newContent)")
        } else {
            outLines.append(line)
        }
        taskCount += 1
    }
    var updatedNotes = ProjectNotes(
        title: notes.title,
        summary: notes.summary,
        problem: notes.problem,
        goals: notes.goals,
        approach: notes.approach,
        links: notes.links,
        learnings: notes.learnings,
        sessions: notes.sessions
    )
    updatedNotes.sessions[sessionIndex] = Session(date: session.date, label: session.label, body: outLines.joined(separator: "\n"))
    let shouldAdvance = advanceFocus || parent.isFocused
    if shouldAdvance {
        let openTodos = todos.filter { !$0.checked }
        let nextOpen = openTodos.first { t in
            t.sessionIndex != sessionIndex || !indicesToComplete.contains(t.lineIndex)
        }
        updatedNotes = applyFocusToTodoInNotes(notes: updatedNotes, todo: nextOpen)
    }
    return updatedNotes
}

private func applyFocusToTodoInNotes(notes: ProjectNotes, todo: Todo?) -> ProjectNotes {
    guard let pattern = todoLinePattern else { return notes }
    let targetSessionIndex = todo?.sessionIndex ?? -1
    let targetLineIndex = todo?.lineIndex ?? -1
    var outSessions: [Session] = []
    for (si, session) in notes.sessions.enumerated() {
        let lines = session.body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var taskCount = 0
        var outLines: [String] = []
        for line in lines {
            guard let m = pattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let r1 = Range(m.range(at: 1), in: line),
                  let r2 = Range(m.range(at: 2), in: line),
                  let r3 = Range(m.range(at: 3), in: line) else {
                outLines.append(line)
                continue
            }
            let isTarget = todo != nil && si == targetSessionIndex && taskCount == targetLineIndex
            var content = String(line[r3])
            if content.hasSuffix(focusMarkerSuffix) {
                content = String(content.dropLast(focusMarkerSuffix.count)).trimmingCharacters(in: .whitespaces)
            }
            let prefix = String(line[r1])
            let check = String(line[r2])
            outLines.append("\(prefix)[\(check)] \(content)\(isTarget ? focusMarkerSuffix : "")")
            taskCount += 1
        }
        outSessions.append(Session(date: session.date, label: session.label, body: outLines.joined(separator: "\n")))
    }
    return ProjectNotes(
        title: notes.title,
        summary: notes.summary,
        problem: notes.problem,
        goals: notes.goals,
        approach: notes.approach,
        links: notes.links,
        learnings: notes.learnings,
        sessions: outSessions
    )
}
