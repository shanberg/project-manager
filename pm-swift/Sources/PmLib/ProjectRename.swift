import Foundation

private let invalidRenameTitleCharacters: CharacterSet = CharacterSet(charactersIn: "/\\\0")

/// Split a project folder basename into `Domain-<digits>` and title using configured domain codes (longest match first).
public func parseProjectPrefixAndTitle(folderName: String, domainCodes: [String]) throws -> (prefix: String, title: String) {
    let sorted = domainCodes.sorted { $0.count > $1.count }
    for domain in sorted {
        let escaped = NSRegularExpression.escapedPattern(for: domain)
        let pattern = "^\(escaped)-(\\d+)\\s+(.+)$"
        guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
        let range = NSRange(folderName.startIndex..., in: folderName)
        guard let match = re.firstMatch(in: folderName, range: range),
              let numRange = Range(match.range(at: 1), in: folderName),
              let titleRange = Range(match.range(at: 2), in: folderName) else { continue }
        let digits = String(folderName[numRange])
        let title = String(folderName[titleRange])
        let prefix = "\(domain)-\(digits)"
        return (prefix, title)
    }
    throw PmError.projectFolderMalformed(folderName)
}

/// Give a project or area a new title. Updates the notes `#` title and renames the notes file when needed.
///
/// A project keeps its `Domain-<digits>` prefix and only the title segment moves — the number is its
/// identity and renaming isn't renumbering. An area has no prefix to keep: its name *is* its title, so
/// the new folder name is simply the new title.
/// - Parameter dryRun: check everything and work out the new folder name, then stop before the move.
public func renameProjectTitle(nameOrPrefix: String, newTitle: String,
                               dryRun: Bool = false) throws -> String {
    let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { throw PmError.emptyRenameTitle }
    if trimmed.unicodeScalars.contains(where: { invalidRenameTitleCharacters.contains($0) }) {
        throw PmError.invalidProjectTitle(title: trimmed)
    }
    let (config, _) = try loadConfigAndPaths()
    let projectPath = try resolveProjectPath(nameOrPrefix: nameOrPrefix)
    let oldName = (projectPath as NSString).lastPathComponent
    let kind = ProjectKind.of(folderName: oldName)
    let newBasename: String
    if kind.isNumbered {
        let domainCodes = Array(config.domains.keys)
        let (prefix, _) = try parseProjectPrefixAndTitle(folderName: oldName, domainCodes: domainCodes)
        newBasename = "\(prefix) \(trimmed)"
    } else {
        newBasename = trimmed
    }
    if newBasename == oldName { return newBasename }
    let parent = (projectPath as NSString).deletingLastPathComponent
    let dest = (parent as NSString).appendingPathComponent(newBasename)
    if FileManager.default.fileExists(atPath: dest) {
        throw PmError.renameTargetExists(dest)
    }
    if dryRun { return newBasename }
    try FileManager.default.moveItem(atPath: projectPath, toPath: dest)
    if let resolved = try resolveNotesPath(projectPath: dest),
       FileManager.default.fileExists(atPath: resolved) {
        let canonical = getNotesPath(projectPath: dest)
        let ioResolved = makeNotesIO(notesPath: resolved, config: config)
        let raw = try ioResolved.readContent(path: resolved)
        var notes = try parseNotes(markdown: raw)
        notes.title = trimmed
        // Update only the title line, preserving all other formatting. Fall back to the full
        // serializer if the title line can't be spliced (e.g. no `# ` heading).
        let content = (try writeNotesPreservingFormat(rawText: raw, incoming: notes, kind: ProjectKind.of(notesPath: canonical))) ?? serializeNotes(notes, kind: ProjectKind.of(notesPath: canonical))
        if resolved == canonical {
            try ioResolved.writeContent(path: canonical, content: content)
        } else {
            let ioCanon = makeNotesIO(notesPath: canonical, config: config)
            try ioCanon.writeContent(path: canonical, content: content)
            try FileManager.default.removeItem(atPath: resolved)
        }
    }
    return newBasename
}
