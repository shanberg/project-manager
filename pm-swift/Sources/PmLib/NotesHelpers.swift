import Foundation

/// Parse a YYYY-MM-DD string for session date (e.g. from --date). Throws PmError.invalidSessionDate if invalid.
/// Date-only strings are interpreted as noon UTC so the calendar day is stable when formatted in any timezone.
public func parseSessionDateArgument(_ string: String) throws -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate]
    guard let date = formatter.date(from: string) else {
        throw PmError.invalidSessionDate(value: string)
    }
    // Noon UTC so the calendar day is stable when formatted in any timezone (matches Raycast session date).
    return date.addingTimeInterval(12 * 3600)
}

/// Session date string for notes headings and session matching. Must match Raycast’s formatSessionDate (en-US short) so that addTodoToTodaySession works.
/// Uses UTC so the same calendar day is formatted identically everywhere (deterministic tests and stable session headings).
public func formatSessionDate(_ date: Date = Date()) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "EEE, MMM d, yyyy"
    return formatter.string(from: date)
}

public func addSession(notes: ProjectNotes, label: String, date: Date? = nil) -> ProjectNotes {
    let session = Session(
        date: formatSessionDate(date ?? Date()),
        label: label,
        body: ""
    )
    var out = notes
    out.sessions.insert(session, at: 0)
    return out
}

/// Project title derived from folder name (part after first space in "D-1 Title"). Falls back to full folder name if no space.
public func projectTitle(fromFolderName folderName: String) -> String {
    let spaceIdx = folderName.firstIndex(of: " ")
    return spaceIdx.map { String(folderName[folderName.index(after: $0)...]) } ?? folderName
}

public func getNotesPath(projectPath: String) -> String {
    let folderName = (projectPath as NSString).lastPathComponent
    let title = projectTitle(fromFolderName: folderName)
    return (projectPath as NSString).appendingPathComponent("docs/Notes - \(title).md")
}

/// Resolve the path to the project's notes file (canonical or single/first matching Notes - *.md in docs/).
/// Returns nil if no notes file exists; throws on I/O errors (e.g. permission denied listing docs/).
public func resolveNotesPath(projectPath: String) throws -> String? {
    let canonical = getNotesPath(projectPath: projectPath)
    if FileManager.default.fileExists(atPath: canonical) { return canonical }
    let docsPath = (projectPath as NSString).appendingPathComponent("docs")
    let entries: [String]
    do {
        entries = try FileManager.default.contentsOfDirectory(atPath: docsPath)
    } catch {
        if isFileNotFoundError(error) { return nil }
        throw PmError.cannotListDirectory(path: docsPath, message: (error as NSError).localizedDescription)
    }
    let notesFiles = entries.filter { $0.hasPrefix("Notes - ") && $0.hasSuffix(".md") }
    if notesFiles.count == 1 { return (docsPath as NSString).appendingPathComponent(notesFiles[0]) }
    if notesFiles.count > 1 {
        let canonicalName = (canonical as NSString).lastPathComponent
        let match = notesFiles.first { $0 == canonicalName } ?? notesFiles[0]
        return (docsPath as NSString).appendingPathComponent(match)
    }
    return nil
}

/// Read and parse the notes file. When `notesIO` is nil, uses direct file I/O.
public func readNotesFile(notesPath: String, notesIO: NotesIO? = nil) throws -> ProjectNotes {
    let io = notesIO ?? DirectNotesIO()
    let content = try io.readContent(path: notesPath)
    return try parseNotes(markdown: content)
}

/// Serialize and write the notes file. When `notesIO` is nil, uses direct file I/O.
public func writeNotesFile(notesPath: String, notes: ProjectNotes, notesIO: NotesIO? = nil) throws {
    let io = notesIO ?? DirectNotesIO()
    let content = serializeNotes(notes)
    try io.writeContent(path: notesPath, content: content)
}

// MARK: - Surgical edit (preserve file formatting)

private let surgicalSessionSectionPattern: NSRegularExpression? = {
    try? NSRegularExpression(pattern: #"^##\s+Sessions\s*$"#, options: .caseInsensitive)
}()

private let surgicalSessionHeadingPattern: NSRegularExpression? = {
    try? NSRegularExpression(pattern: #"^###\s+(Mon|Tue|Wed|Thu|Fri|Sat|Sun),"#)
}()

private let surgicalTaskLinePattern: NSRegularExpression? = {
    try? NSRegularExpression(pattern: #"^\s*-\s+\[([ xX])\]\s+(.*)$"#)
}()

/// Returns the 0-based line number of the task at (sessionIndex, lineIndex) in the raw markdown, or nil if not found.
public func findTaskLineNumber(content: String, sessionIndex: Int, lineIndex: Int) -> Int? {
    guard let sectionPattern = surgicalSessionSectionPattern,
          let headingPattern = surgicalSessionHeadingPattern,
          let taskPattern = surgicalTaskLinePattern else { return nil }
    let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    guard let sectionLine = lines.firstIndex(where: { sectionPattern.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }) else { return nil }
    var lineIdx = sectionLine + 1
    var currentSession = -1
    while lineIdx < lines.count {
        let line = lines[lineIdx]
        if headingPattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
            currentSession += 1
            if currentSession == sessionIndex {
                var taskCount = 0
                var i = lineIdx + 1
                while i < lines.count, headingPattern.firstMatch(in: lines[i], range: NSRange(lines[i].startIndex..., in: lines[i])) == nil,
                      surgicalSessionSectionPattern?.firstMatch(in: lines[i], range: NSRange(lines[i].startIndex..., in: lines[i])) == nil {
                    if taskPattern.firstMatch(in: lines[i], range: NSRange(lines[i].startIndex..., in: lines[i])) != nil {
                        if taskCount == lineIndex { return i }
                        taskCount += 1
                    }
                    i += 1
                }
                return nil
            }
        }
        lineIdx += 1
    }
    return nil
}

/// Replaces the given lines (0-based indices) with new content; other lines are unchanged. Preserves line count and trailing newline.
public func replaceLinesInContent(content: String, replacements: [Int: String]) -> String {
    guard !replacements.isEmpty else { return content }
    var lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    for (idx, newLine) in replacements {
        if idx >= 0, idx < lines.count {
            lines[idx] = newLine
        }
    }
    return lines.joined(separator: "\n")
}

/// Returns (sessionIndex, lineIndex) of the task line that contains the focus marker " @", or nil.
public func focusedTaskIndicesInNotes(notes: ProjectNotes) -> (sessionIndex: Int, lineIndex: Int)? {
    let taskPattern = try? NSRegularExpression(pattern: #"^\s*-\s+\[([ xX])\]\s+(.*)$"#)
    guard let pattern = taskPattern else { return nil }
    for (sessionIndex, session) in notes.sessions.enumerated() {
        let bodyLines = session.body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var lineIndex = 0
        for line in bodyLines {
            if pattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
                if line.hasSuffix(" @") { return (sessionIndex, lineIndex) }
                lineIndex += 1
            }
        }
    }
    return nil
}

private let focusMarkerSuffix = " @"

/// Surgical todo complete: replace only the task line(s) in raw content so the rest of the file is unchanged. Returns nil if line numbers cannot be determined (fall back to full parse/serialize).
public func applySurgicalTodoComplete(content: String, notes: ProjectNotes, todos: [Todo], sessionIndex: Int, lineIndex: Int, advanceFocus: Bool) -> String? {
    guard let completedLineNum = findTaskLineNumber(content: content, sessionIndex: sessionIndex, lineIndex: lineIndex),
          let completedTodo = todos.first(where: { $0.sessionIndex == sessionIndex && $0.lineIndex == lineIndex }) else { return nil }
    var newCompletedLine = completedTodo.rawLine.replacingOccurrences(of: "[ ]", with: "[x]")
    if newCompletedLine.hasSuffix(focusMarkerSuffix) {
        newCompletedLine = String(newCompletedLine.dropLast(focusMarkerSuffix.count))
    }
    var replacements: [Int: String] = [completedLineNum: newCompletedLine]
    if advanceFocus {
        let updatedNotes: ProjectNotes
        do {
            updatedNotes = try completeTodoWithDescendants(notes: notes, sessionIndex: sessionIndex, lineIndex: lineIndex, advanceFocus: true)
        } catch { return nil }
        guard let (nextSi, nextLi) = focusedTaskIndicesInNotes(notes: updatedNotes),
              let nextLineNum = findTaskLineNumber(content: content, sessionIndex: nextSi, lineIndex: nextLi),
              let nextTodo = todos.first(where: { $0.sessionIndex == nextSi && $0.lineIndex == nextLi }) else {
            return replaceLinesInContent(content: content, replacements: replacements)
        }
        let nextLine = nextTodo.rawLine.hasSuffix(focusMarkerSuffix) ? nextTodo.rawLine : nextTodo.rawLine + focusMarkerSuffix
        replacements[nextLineNum] = nextLine
    }
    return replaceLinesInContent(content: content, replacements: replacements)
}

/// Surgical todo undo: uncheck the task and move focus to it; remove focus from previous. Returns nil to fall back to full path.
public func applySurgicalTodoUndo(content: String, notes: ProjectNotes, todos: [Todo], sessionIndex: Int, lineIndex: Int) -> String? {
    guard let lineNum = findTaskLineNumber(content: content, sessionIndex: sessionIndex, lineIndex: lineIndex),
          let todo = todos.first(where: { $0.sessionIndex == sessionIndex && $0.lineIndex == lineIndex }) else { return nil }
    var replacements: [Int: String] = [:]
    if let (curSi, curLi) = focusedTaskIndicesInNotes(notes: notes), (curSi, curLi) != (sessionIndex, lineIndex),
       let curLineNum = findTaskLineNumber(content: content, sessionIndex: curSi, lineIndex: curLi),
       let curTodo = todos.first(where: { $0.sessionIndex == curSi && $0.lineIndex == curLi }) {
        let withoutFocus = curTodo.rawLine.hasSuffix(focusMarkerSuffix) ? String(curTodo.rawLine.dropLast(focusMarkerSuffix.count)) : curTodo.rawLine
        replacements[curLineNum] = withoutFocus
    }
    let unchecked = todo.rawLine.replacingOccurrences(of: "[x]", with: "[ ]")
    let withFocus = unchecked.hasSuffix(focusMarkerSuffix) ? unchecked : unchecked + focusMarkerSuffix
    replacements[lineNum] = withFocus
    return replaceLinesInContent(content: content, replacements: replacements)
}

/// Surgical focus: replace the current focus line (remove " @") and the target line (add " @"). Returns nil to fall back to full path.
public func applySurgicalFocus(content: String, notes: ProjectNotes, todos: [Todo], sessionIndex: Int, lineIndex: Int) -> String? {
    let currentFocus = focusedTaskIndicesInNotes(notes: notes)
    guard let targetLineNum = findTaskLineNumber(content: content, sessionIndex: sessionIndex, lineIndex: lineIndex),
          let targetTodo = todos.first(where: { $0.sessionIndex == sessionIndex && $0.lineIndex == lineIndex }) else { return nil }
    var replacements: [Int: String] = [:]
    if let (curSi, curLi) = currentFocus, let curLineNum = findTaskLineNumber(content: content, sessionIndex: curSi, lineIndex: curLi),
       let curTodo = todos.first(where: { $0.sessionIndex == curSi && $0.lineIndex == curLi }) {
        let withoutFocus = curTodo.rawLine.hasSuffix(focusMarkerSuffix) ? String(curTodo.rawLine.dropLast(focusMarkerSuffix.count)) : curTodo.rawLine
        replacements[curLineNum] = withoutFocus
    }
    let targetNew = targetTodo.rawLine.hasSuffix(focusMarkerSuffix) ? targetTodo.rawLine : targetTodo.rawLine + focusMarkerSuffix
    replacements[targetLineNum] = targetNew
    return replaceLinesInContent(content: content, replacements: replacements)
}

/// Resolve notes template content: if template path is set, file must exist and is used (with {{title}} replaced); otherwise use embedded default.
public func getNotesTemplateContent(templatePath: String?, title: String) throws -> String {
    if let path = templatePath, !path.isEmpty {
        let expanded = (path as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expanded) else {
            throw PmError.notesTemplateNotFound(expanded)
        }
        let content = try String(contentsOfFile: expanded, encoding: .utf8)
        return content.replacingOccurrences(of: "{{title}}", with: title)
    }
    let content = notesTemplate.replacingOccurrences(of: "{{title}}", with: title)
    return content.hasPrefix("\n") ? String(content.dropFirst()) : content
}

/// Embedded default notes template (same as templates/notes.md with {{title}} placeholder).
public let notesTemplate = """
# {{title}}

> [!summary] Summary
> 


> [!question] Problem
> 


> [!info] Goals
> 1.  
> 2.  
> 3.  


> [!info] Approach
> 


## Links

- 

## Learnings

- 

## Sessions
"""

/// Create a notes file from the configured template. Requires a valid config and existing active/archive paths
/// (uses `loadConfigAndPaths()` to resolve the template path). Throws if the notes file already exists.
/// Uses NotesIO so the file is created via Obsidian CLI when configured.
public func createNotesFromTemplate(projectPath: String) throws -> String {
    let folderName = (projectPath as NSString).lastPathComponent
    let title = projectTitle(fromFolderName: folderName)
    let notesPath = getNotesPath(projectPath: projectPath)
    if FileManager.default.fileExists(atPath: notesPath) {
        throw PmError.notesAlreadyExists(notesPath)
    }
    let (config, _) = try loadConfigAndPaths()
    let content = try getNotesTemplateContent(templatePath: config.notesTemplatePath, title: title)
    let docsPath = (projectPath as NSString).appendingPathComponent("docs")
    try FileManager.default.createDirectory(atPath: docsPath, withIntermediateDirectories: true)
    let io = makeNotesIO(notesPath: notesPath, config: config)
    try io.writeContent(path: notesPath, content: content)
    return notesPath
}
