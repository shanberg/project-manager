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

public func readNotesFile(notesPath: String) throws -> ProjectNotes {
    let content = try String(contentsOfFile: notesPath, encoding: .utf8)
    return try parseNotes(markdown: content)
}

public func writeNotesFile(notesPath: String, notes: ProjectNotes) throws {
    let content = serializeNotes(notes)
    try content.write(toFile: notesPath, atomically: true, encoding: .utf8)
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
    return notesTemplate.replacingOccurrences(of: "{{title}}", with: title)
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
    try content.write(toFile: notesPath, atomically: true, encoding: .utf8)
    return notesPath
}
