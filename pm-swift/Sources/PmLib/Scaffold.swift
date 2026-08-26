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

/// Take on a folder that already exists as an Area, by writing PM's notes file into it.
///
/// A PARA vault has Areas in it before PM knows the word — `Areas/Work`, `Areas/Marriage`, folders
/// with years of material. The rule that makes an Area "a folder PM has written notes into" is what
/// stops PM claiming every directory it can see; it is also what leaves those unreachable. Adopting is
/// the door that rule needs.
///
/// **It writes one file and creates one directory to put it in.** No `resources/`, no scaffold, no
/// tidying. The folder is already organized the way its owner organizes things, and a command that
/// rearranged it in passing would be a worse deal than leaving it alone. `createProject` builds a
/// folder, so it decides the shape; this one is a guest.
///
/// Only Areas. Adopting a folder as a *project* would mean renaming it to `CODE-NNN Title` — taking a
/// number and changing what the folder is called on disk — which is a different act with a different
/// blast radius, and nobody has asked for it.
///
/// - Parameter dryRun: run every check and work out where the notes would go, then stop.
@discardableResult
public func adoptArea(config: PmConfig, paths: ResolvedPaths, folderName: String,
                      dryRun: Bool = false) throws -> String {
    let name = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, !name.contains("/") else {
        throw PmError.cannotAdopt(name: folderName, reason: "that isn't a folder name in \(paths.areasPath)")
    }
    // A numbered name is a project's, and this doesn't make projects.
    guard !ProjectKind.of(folderName: name).isNumbered else {
        throw PmError.cannotAdopt(name: name, reason: "that's a project's name — it's numbered")
    }

    let folder = (paths.areasPath as NSString).appendingPathComponent(name)
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory), isDirectory.boolValue else {
        throw PmError.cannotAdopt(name: name, reason: "there's no folder by that name in \(paths.areasPath)")
    }
    guard ((try? resolveNotesPath(projectPath: folder)) ?? nil) == nil else {
        throw PmError.cannotAdopt(name: name, reason: "it's already an area")
    }

    // Read the template before creating anything: it is a read, and the step most likely to refuse.
    let contents = try getNotesTemplateContent(templatePath: ProjectKind.area.notesTemplatePath(in: config),
                                               title: name, kind: .area)
    let notesPath = getNotesPath(projectPath: folder)
    if dryRun { return notesPath }

    try FileManager.default.createDirectory(atPath: (notesPath as NSString).deletingLastPathComponent,
                                            withIntermediateDirectories: true)
    try contents.write(toFile: notesPath, atomically: true, encoding: .utf8)
    return notesPath
}
