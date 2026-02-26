import Foundation

public func formatSessionDate(_ date: Date = Date()) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US")
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

public func getNotesPath(projectPath: String) -> String {
    let folderName = (projectPath as NSString).lastPathComponent
    let spaceIdx = folderName.firstIndex(of: " ")
    let title = spaceIdx.map { String(folderName[folderName.index(after: $0)...]) } ?? folderName
    return (projectPath as NSString).appendingPathComponent("docs/Notes - \(title).md")
}

public func resolveNotesPath(projectPath: String) -> String? {
    let canonical = getNotesPath(projectPath: projectPath)
    if FileManager.default.fileExists(atPath: canonical) { return canonical }
    let docsPath = (projectPath as NSString).appendingPathComponent("docs")
    guard let entries = try? FileManager.default.contentsOfDirectory(atPath: docsPath) else { return nil }
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
    return parseNotes(markdown: content)
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

public func createNotesFromTemplate(projectPath: String) throws -> String {
    let folderName = (projectPath as NSString).lastPathComponent
    let spaceIdx = folderName.firstIndex(of: " ")
    let title = spaceIdx.map { String(folderName[folderName.index(after: $0)...]) } ?? folderName
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
