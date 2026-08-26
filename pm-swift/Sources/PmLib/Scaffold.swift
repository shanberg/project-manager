import Foundation

/// Characters that would make the project folder name multiple path components or unsafe.
private let invalidTitleCharacters: CharacterSet = CharacterSet(charactersIn: "/\\\0")

/// Creates the folder, its scaffold, and its notes file, and returns its path.
///
/// One function for both kinds, because the steps are the same and only the answers differ: what the
/// folder is called, which root it goes in, what subfolders it gets, and which template it starts
/// from. All four come off `kind`, so this reads properties rather than asking which kind it has.
///
/// **Not atomic.** If a later step throws (e.g. a template read or the write fails), the folder and
/// its subfolders may already exist on disk. Callers should remove it when handling the error so a
/// half-made one doesn't keep the number it drew.
/// - Parameter domainCode: required for a numbered kind, refused for an unnumbered one. Withholding it
///   from a project is the caller having lost track of what it's making, and passing one to an area is
///   the same mistake in the other direction; neither should be quietly ignored.
/// - Parameter dryRun: run every check and work out where it would go, then stop before creating
///   anything. The same path minus its last steps rather than a prediction of them, so a preview can't
///   report a name or a refusal the real call wouldn't.
public func createProject(config: PmConfig, paths: ResolvedPaths, kind: ProjectKind = .project,
                          domainCode: String? = nil, title: String,
                          dryRun: Bool = false) throws -> String {
    if title.unicodeScalars.contains(where: { invalidTitleCharacters.contains($0) }) {
        throw PmError.invalidProjectTitle(title: title)
    }
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw PmError.invalidProjectTitle(title: title) }
    guard kind.isNumbered == (domainCode != nil) else {
        throw PmError.domainNotApplicable(kind: kind.rawValue)
    }

    let folderName: String
    if let domainCode {
        let formatted = try getNextFormattedNumber(activePath: paths.activePath,
                                                   archivePath: paths.archivePath,
                                                   domainCode: domainCode)
        folderName = "\(domainCode)-\(formatted) \(trimmed)"
    } else {
        folderName = trimmed
    }

    let projectPath = (kind.root(in: paths) as NSString).appendingPathComponent(folderName)
    // An unnumbered name is only unique if nothing already has it. Numbered ones can't collide — the
    // number sees to that — so this is here for areas, and it matters: creating a second "Hiring"
    // would find the folder already present, carry on, and write over the first one's notes.
    if !kind.isNumbered, FileManager.default.fileExists(atPath: projectPath) {
        throw PmError.areaAlreadyExists(projectPath)
    }

    // Read the template even on a dry run: it is a read, and it is the step most likely to refuse.
    let notesContent = try getNotesTemplateContent(templatePath: kind.notesTemplatePath(in: config),
                                                   title: trimmed, kind: kind)
    if dryRun { return projectPath }

    let fm = FileManager.default
    // Intermediates on purpose: an area is the first thing that ever needs `areas/` to exist, and a
    // vault that has never had one won't have the folder.
    try fm.createDirectory(atPath: projectPath, withIntermediateDirectories: true)
    for sub in kind.subfolders(in: config) {
        try fm.createDirectory(atPath: (projectPath as NSString).appendingPathComponent(sub), withIntermediateDirectories: true)
    }
    let notesPath = getNotesPath(projectPath: projectPath)
    try notesContent.write(toFile: notesPath, atomically: true, encoding: .utf8)
    return projectPath
}
