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

/// The shape of a numbered project folder name: a domain code, a hyphen, a number, a space.
///
/// Deliberately not built from the configured domain codes. This runs in `getNotesPath`, which has a
/// path and nothing else — no config, and no way to get one without turning a string transform into
/// an I/O call. The grammar is what identifies the prefix, not the particular letters.
private let numberedProjectPrefix = try? NSRegularExpression(pattern: #"^[A-Za-z]+-\d+\s+"#)

/// Project title derived from its folder name: `"W-12 Website Refresh"` is `"Website Refresh"`.
///
/// Only a name that actually carries a `CODE-NNN ` prefix is stripped. Splitting on the first space
/// unconditionally — what this did until Areas existed — is right for every project and wrong for
/// every folder without a prefix: `"Team 1:1s"` became `"1:1s"`, so `getNotesPath` wrote
/// `docs/Notes - 1:1s.md`. `resolveNotesPath` hides that on reads by falling back to any
/// `Notes - *.md` in `docs/`, which is exactly why the write side had to be fixed rather than left
/// to it — the fallback would keep finding the right file while every write minted the wrong one.
///
/// A folder whose own name happens to have the prefix's grammar (`"Q4-2026 planning"`) is still read
/// as prefixed. The cost is a notes file named after the tail of its folder, and the alternative is
/// passing configuration into a pure string transform.
public func projectTitle(fromFolderName folderName: String) -> String {
    guard let regex = numberedProjectPrefix,
          let match = regex.firstMatch(in: folderName, range: NSRange(folderName.startIndex..., in: folderName)),
          let range = Range(match.range, in: folderName)
    else { return folderName }
    return String(folderName[range.upperBound...])
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
