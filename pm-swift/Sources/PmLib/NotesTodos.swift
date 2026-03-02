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

// MARK: - Now-style focus advance (previous sibling's last leaf, else next sibling's first leaf, else parent)

/// Last line index of the subtree rooted at idx (inclusive). Subtree = idx plus following lines with greater depth.
private func lastLeafOf(sessionTodos: [Todo], idx: Int) -> Int {
    var i = idx
    while i + 1 < sessionTodos.count, sessionTodos[i + 1].depth > sessionTodos[idx].depth {
        i += 1
    }
    return i
}

/// First leaf in the subtree rooted at idx (deepest first descendant, or self if leaf).
private func firstLeafOf(sessionTodos: [Todo], idx: Int) -> Int {
    guard idx + 1 < sessionTodos.count, sessionTodos[idx + 1].depth > sessionTodos[idx].depth else {
        return idx
    }
    return firstLeafOf(sessionTodos: sessionTodos, idx: idx + 1)
}

/// Index of the parent task (last task before idx with strictly lesser depth), or nil if root-level.
private func parentOf(sessionTodos: [Todo], idx: Int) -> Int? {
    let depth = sessionTodos[idx].depth
    for i in (0..<idx).reversed() {
        if sessionTodos[i].depth < depth { return i }
    }
    return nil
}

/// Sibling line indices at same depth under the same parent, and our position among them.
private func siblingIndicesAndPosition(sessionTodos: [Todo], idx: Int) -> (indices: [Int], position: Int)? {
    let depth = sessionTodos[idx].depth
    let parentIdx = parentOf(sessionTodos: sessionTodos, idx: idx)
    let parentDepth: Int
    let rangeStart: Int
    if let p = parentIdx {
        parentDepth = sessionTodos[p].depth
        rangeStart = p + 1
    } else {
        parentDepth = -1
        rangeStart = 0
    }
    var siblingIndices: [Int] = []
    var i = rangeStart
    while i < sessionTodos.count, sessionTodos[i].depth > parentDepth {
        if sessionTodos[i].depth == depth {
            siblingIndices.append(i)
        }
        i += 1
    }
    guard let pos = siblingIndices.firstIndex(of: idx) else { return nil }
    return (siblingIndices, pos)
}

/// Choose next focus using now pattern: previous sibling's last leaf, else next sibling's first leaf, else parent. Prefer unchecked.
private func selectNewCurrentAfterRemoval(
    sessionTodos: [Todo],
    completedLineIndex: Int,
    indicesToComplete: Set<Int>
) -> Todo? {
    guard let (siblingIndices, position) = siblingIndicesAndPosition(sessionTodos: sessionTodos, idx: completedLineIndex) else {
        return nil
    }
    var candidates: [Int] = []
    if position > 0 {
        let prevSiblingIdx = siblingIndices[position - 1]
        candidates.append(lastLeafOf(sessionTodos: sessionTodos, idx: prevSiblingIdx))
    }
    if position + 1 < siblingIndices.count {
        let nextSiblingIdx = siblingIndices[position + 1]
        candidates.append(firstLeafOf(sessionTodos: sessionTodos, idx: nextSiblingIdx))
    }
    if let parentIdx = parentOf(sessionTodos: sessionTodos, idx: completedLineIndex) {
        candidates.append(parentIdx)
    }
    let validCandidates = candidates.filter { !indicesToComplete.contains($0) }
    if let firstUnchecked = validCandidates.first(where: { !sessionTodos[$0].checked }) {
        return sessionTodos[firstUnchecked]
    }
    if let firstAny = validCandidates.first {
        return sessionTodos[firstAny]
    }
    return nil
}

/// Complete the todo at (sessionIndex, lineIndex) and all its descendants. Optionally move focus to next open todo (now-style: prev sibling last leaf, else next sibling first leaf, else parent).
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
        let nextTodo: Todo?
        if let nowStyle = selectNewCurrentAfterRemoval(sessionTodos: sessionTodos, completedLineIndex: lineIndex, indicesToComplete: indicesToComplete) {
            nextTodo = nowStyle
        } else {
            let openTodos = todos.filter { !$0.checked }
            nextTodo = openTodos.first { t in
                t.sessionIndex != sessionIndex || !indicesToComplete.contains(t.lineIndex)
            }
        }
        updatedNotes = applyFocusToTodoInNotes(notes: updatedNotes, todo: nextTodo)
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
