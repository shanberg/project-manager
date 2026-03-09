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

private let dueMetadataPattern: NSRegularExpression? = {
    try? NSRegularExpression(pattern: #"^\s+due:\s*(\d{4}-\d{2}-\d{2}(?:\s+\d{1,2}:\d{2}(?::\d{2})?)?|\d{1,2}-\d{1,2}-\d{4}(?:\s+\d{1,2}:\d{2}(?::\d{2})?)?)\s*$"#)
}()

private func parseDueFromNextLine(_ lines: [String], afterIndex idx: Int) -> String? {
    guard idx + 1 < lines.count else { return nil }
    let nextLine = lines[idx + 1]
    guard nextLine.first == " " || nextLine.first == "\t" else { return nil }
    guard let pattern = dueMetadataPattern,
          let m = pattern.firstMatch(in: nextLine, range: NSRange(nextLine.startIndex..., in: nextLine)),
          let r1 = Range(m.range(at: 1), in: nextLine) else { return nil }
    return String(nextLine[r1])
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
        for (idx, line) in lines.enumerated() {
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
            let dueDate = parseDueFromNextLine(lines, afterIndex: idx)
            todos.append(Todo(
                text: text,
                checked: checked,
                rawLine: line,
                context: context,
                depth: depth,
                sessionIndex: sessionIndex,
                lineIndex: lineIndex,
                isFocused: isFocused,
                dueDate: dueDate
            ))
            lineIndex += 1
        }
    }
    return todos
}

/// Compare due date strings by calendar order (earliest first). Uses first 10 chars (YYYY-MM-DD) when present so "2025-03-15" and "2025-03-15 14:30" compare equal.
private func dueDateSortKey(_ s: String) -> String {
    let prefix = String(s.prefix(10))
    if prefix.count == 10, prefix.filter({ $0 == "-" }).count == 2 {
        return prefix
    }
    return s
}

/// Earliest due date among ancestors (parent, grandparent, …). "Nearest" = soonest deadline. Returns nil if no ancestor has a due.
private func earliestAncestorDue(sessionTodos: [Todo], idx: Int) -> String? {
    var candidates: [String] = []
    var i = idx
    while let p = parentOf(sessionTodos: sessionTodos, idx: i) {
        if let d = sessionTodos[p].dueDate { candidates.append(d) }
        i = p
    }
    return candidates.min(by: { dueDateSortKey($0) < dueDateSortKey($1) })
}

/// Returns todos with effectiveDueDate set: earliest due among own and all ancestors (nearest deadline). Use when producing notes show output.
public func todosWithEffectiveDueDates(_ todos: [Todo]) -> [Todo] {
    let bySession = Dictionary(grouping: todos) { $0.sessionIndex }
    return todos.map { todo in
        let sessionTodos = (bySession[todo.sessionIndex] ?? []).sorted { $0.lineIndex < $1.lineIndex }
        guard let idx = sessionTodos.firstIndex(where: { $0.lineIndex == todo.lineIndex }) else {
            return Todo(
                text: todo.text,
                checked: todo.checked,
                rawLine: todo.rawLine,
                context: todo.context,
                depth: todo.depth,
                sessionIndex: todo.sessionIndex,
                lineIndex: todo.lineIndex,
                isFocused: todo.isFocused,
                dueDate: todo.dueDate,
                effectiveDueDate: todo.dueDate
            )
        }
        var candidates: [String] = []
        if let own = todo.dueDate { candidates.append(own) }
        if let ancestor = earliestAncestorDue(sessionTodos: sessionTodos, idx: idx) { candidates.append(ancestor) }
        let effective = candidates.min(by: { dueDateSortKey($0) < dueDateSortKey($1) })
        return Todo(
            text: todo.text,
            checked: todo.checked,
            rawLine: todo.rawLine,
            context: todo.context,
            depth: todo.depth,
            sessionIndex: todo.sessionIndex,
            lineIndex: todo.lineIndex,
            isFocused: todo.isFocused,
            dueDate: todo.dueDate,
            effectiveDueDate: effective
        )
    }
}

private let todoLinePattern: NSRegularExpression? = {
    try? NSRegularExpression(pattern: #"^(\s*-\s+)\[([ xX])\]\s+(.*)$"#)
}()

// MARK: - Now-style focus advance (parent's first leaf, else next sibling's first leaf, else parent)
// Full flow: docs/task-focus-flow.md

/// First leaf in the subtree rooted at idx (deepest first descendant, or self if leaf).
private func firstLeafOf(sessionTodos: [Todo], idx: Int) -> Int {
    guard idx + 1 < sessionTodos.count, sessionTodos[idx + 1].depth > sessionTodos[idx].depth else {
        return idx
    }
    return firstLeafOf(sessionTodos: sessionTodos, idx: idx + 1)
}

/// First leaf in the parent's subtree (document order), excluding any index in indicesToComplete. Returns nil if parent has no such leaf.
private func firstLeafOfParentExcluding(sessionTodos: [Todo], parentIdx: Int, indicesToComplete: Set<Int>) -> Int? {
    let parentDepth = sessionTodos[parentIdx].depth
    var i = parentIdx + 1
    while i < sessionTodos.count, sessionTodos[i].depth > parentDepth {
        let isLeaf = (i + 1 >= sessionTodos.count) || (sessionTodos[i + 1].depth <= sessionTodos[i].depth)
        if isLeaf, !indicesToComplete.contains(i) {
            return i
        }
        i += 1
    }
    return nil
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

/// First open (unchecked) leaf in document order that is not in the completed set. Used when no structural candidate exists.
private func firstOpenLeafNotInSet(todos: [Todo], completedSessionIndex: Int, indicesToComplete: Set<Int>) -> Todo? {
    let sessionIndices = Set(todos.map(\.sessionIndex)).sorted()
    for sessionIdx in sessionIndices {
        let sessionTodos = todos.filter { $0.sessionIndex == sessionIdx }.sorted { $0.lineIndex < $1.lineIndex }
        for i in 0..<sessionTodos.count {
            let t = sessionTodos[i]
            guard !t.checked else { continue }
            if sessionIdx == completedSessionIndex, indicesToComplete.contains(t.lineIndex) { continue }
            let isLeaf = (i + 1 >= sessionTodos.count) || (sessionTodos[i + 1].depth <= t.depth)
            if isLeaf { return t }
        }
    }
    return nil
}

/// Choose next focus using now pattern: parent's first leaf, else next sibling's first leaf, else parent. Prefer unchecked.
private func selectNewCurrentAfterRemoval(
    sessionTodos: [Todo],
    completedLineIndex: Int,
    indicesToComplete: Set<Int>
) -> Todo? {
    guard let (siblingIndices, position) = siblingIndicesAndPosition(sessionTodos: sessionTodos, idx: completedLineIndex) else {
        return nil
    }
    var candidates: [Int] = []
    if let parentIdx = parentOf(sessionTodos: sessionTodos, idx: completedLineIndex),
       let parentFirstLeaf = firstLeafOfParentExcluding(sessionTodos: sessionTodos, parentIdx: parentIdx, indicesToComplete: indicesToComplete) {
        candidates.append(parentFirstLeaf)
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

/// Complete the todo at (sessionIndex, lineIndex) and all its descendants. Optionally move focus to next open todo (now-style: parent's first leaf, else next sibling first leaf, else parent).
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
            nextTodo = firstOpenLeafNotInSet(todos: todos, completedSessionIndex: sessionIndex, indicesToComplete: indicesToComplete)
        }
        updatedNotes = applyFocusToTodoInNotes(notes: updatedNotes, todo: nextTodo)
    }
    return updatedNotes
}

/// Move the single " @" focus marker to the task at (sessionIndex, lineIndex). Strips @ from all other task lines.
public func applyFocusToTodoAt(notes: ProjectNotes, sessionIndex: Int, lineIndex: Int) -> ProjectNotes {
    guard let pattern = todoLinePattern else { return notes }
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
            let isTarget = si == sessionIndex && taskCount == lineIndex
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

/// Uncheck the task at (sessionIndex, lineIndex) and move focus to it. One logical write.
public func undoTodoAt(notes: ProjectNotes, sessionIndex: Int, lineIndex: Int) throws -> ProjectNotes {
    guard sessionIndex < notes.sessions.count else { return notes }
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
        let prefix = String(line[r1])
        var check = String(line[r2])
        var content = String(line[r3])
        if content.hasSuffix(focusMarkerSuffix) {
            content = String(content.dropLast(focusMarkerSuffix.count)).trimmingCharacters(in: .whitespaces)
        }
        if taskCount == lineIndex {
            check = " "
        }
        outLines.append("\(prefix)[\(check)] \(content)")
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
    return applyFocusToTodoAt(notes: updatedNotes, sessionIndex: sessionIndex, lineIndex: lineIndex)
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
