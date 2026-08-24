import Foundation

/// Characters that would make the project folder name multiple path components or unsafe.
private let invalidTitleCharacters: CharacterSet = CharacterSet(charactersIn: "/\\\0")

/// Creates project directory, subfolders, and notes file.
///
/// **Not atomic.** If a later step throws (e.g. template read or write fails), the project directory
/// and subfolders may already exist on disk. Callers should remove the project directory when
/// handling the error to avoid leaving a partial project.
/// - Parameter dryRun: run every check and work out where the project would go, then stop before
///   creating anything. The same path minus its last steps rather than a prediction of them, so a
///   preview can't report a name or a refusal the real call wouldn't.
public func createProject(config: PmConfig, paths: ResolvedPaths, domainCode: String, title: String,
                          dryRun: Bool = false) throws -> String {
    if title.unicodeScalars.contains(where: { invalidTitleCharacters.contains($0) }) {
        throw PmError.invalidProjectTitle(title: title)
    }
    let formatted = try getNextFormattedNumber(activePath: paths.activePath, archivePath: paths.archivePath, domainCode: domainCode)
    let folderName = "\(domainCode)-\(formatted) \(title)"
    let projectPath = (paths.activePath as NSString).appendingPathComponent(folderName)
    // Read the template even on a dry run: it is a read, and it is the step most likely to refuse.
    let notesContent = try getNotesTemplateContent(templatePath: config.notesTemplatePath, title: title)
    if dryRun { return projectPath }
    let fm = FileManager.default
    try fm.createDirectory(atPath: projectPath, withIntermediateDirectories: true)
    for sub in config.subfolders {
        try fm.createDirectory(atPath: (projectPath as NSString).appendingPathComponent(sub), withIntermediateDirectories: true)
    }
    let notesPath = getNotesPath(projectPath: projectPath)
    try notesContent.write(toFile: notesPath, atomically: true, encoding: .utf8)
    return projectPath
}
