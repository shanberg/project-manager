import Foundation

func buildProjectPattern(domainCodes: [String]) throws -> NSRegularExpression {
    let sorted = domainCodes.sorted { $0.count > $1.count }
    let escaped = sorted.map { NSRegularExpression.escapedPattern(for: $0) }
    let pattern = "^(\(escaped.joined(separator: "|")))-\\d+\\s+.+$"
    do {
        return try NSRegularExpression(pattern: pattern)
    } catch {
        throw PmError.invalidProjectPattern(pattern: pattern)
    }
}

public func getProjectFolders(basePath: String, domainCodes: [String]) throws -> [String] {
    let codes = domainCodes.isEmpty ? Array(defaultDomains.keys) : domainCodes
    let pattern = try buildProjectPattern(domainCodes: codes)
    let url = URL(fileURLWithPath: basePath)
    let entries: [URL]
    do {
        entries = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
    } catch {
        let message = (error as NSError).localizedDescription
        throw PmError.cannotListDirectory(path: basePath, message: message)
    }
    return entries
        .filter { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
        .map { $0.lastPathComponent }
        .filter { name in
            pattern.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
        }
        .sorted()
}

/// The Areas in a folder, newest first by nothing — sorted by name, as `getProjectFolders` sorts.
///
/// Directories under `basePath` whose names are area-shaped — no `CODE-NNN` prefix.
///
/// The name test rules out every project with a string comparison and no I/O, which matters because
/// the archive holds both kinds: asking for the areas in it has to leave `W-4 Old Thing` alone.
///
/// A missing directory is not an error. Areas arrived after the other two roots and `areasPath` is
/// resolved rather than required, so "no `areas/` folder" is the ordinary state of every vault that
/// hasn't made one yet.
private func areaShapedDirectories(basePath: String) throws -> [URL] {
    let url = URL(fileURLWithPath: basePath)
    let entries: [URL]
    do {
        entries = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
    } catch {
        if isFileNotFoundError(error) { return [] }
        throw PmError.cannotListDirectory(path: basePath, message: (error as NSError).localizedDescription)
    }
    return entries
        .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        .filter { !ProjectKind.of(folderName: $0.lastPathComponent).isNumbered }
}

/// Whether PM has written notes into a folder — what makes one of these an Area rather than a folder
/// that happens to live in `areas/`. The same question `pm notes path` asks.
private func hasNotes(_ folder: URL) -> Bool {
    ((try? resolveNotesPath(projectPath: folder.path)) ?? nil) != nil
}

/// The Areas in a folder, sorted by name.
///
/// Area-shaped *and* carrying notes. The second half is what keeps a folder someone dropped into
/// `areas/` for their own reasons — a pile of receipts, a vault of clippings — from showing up as an
/// empty Area they never made.
public func getAreaFolders(basePath: String) throws -> [String] {
    try areaShapedDirectories(basePath: basePath)
        .filter(hasNotes)
        .map { $0.lastPathComponent }
        .sorted()
}

/// Folders that could become Areas but aren't yet: area-shaped, and with no notes in them.
///
/// The exact complement of `getAreaFolders` over the same set, which is the point. A PARA vault
/// already has Areas in it — the folders were there long before PM knew the word — and the rule that
/// keeps PM from claiming them is also the rule that leaves them unreachable. This is the list of
/// what you could hand it.
public func getAdoptableFolders(basePath: String) throws -> [String] {
    try areaShapedDirectories(basePath: basePath)
        .filter { !hasNotes($0) }
        .map { $0.lastPathComponent }
        .sorted()
}

/// Result of matching a project query against folder names. Single source of truth for resolve logic.
public enum ProjectMatch {
    case matched(String)
    case ambiguous
    case notFound
}

/// Classify how a query matches project folders. Use this instead of duplicating prefix logic.
public func matchProjectResult(folders: [String], query: String) -> ProjectMatch {
    let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
    if q.isEmpty { return .notFound }
    if let exact = folders.first(where: { $0 == q }) { return .matched(exact) }
    let prefixMatches = folders.filter { $0.hasPrefix(q) }
    if prefixMatches.count == 1 { return .matched(prefixMatches[0]) }
    if prefixMatches.count > 1 { return .ambiguous }
    return .notFound
}

/// Returns the single matching folder name, or nil if not found or ambiguous. Convenience for callers that only need the match.
public func matchProject(folders: [String], query: String) -> String? {
    if case .matched(let name) = matchProjectResult(folders: folders, query: query) { return name }
    return nil
}
