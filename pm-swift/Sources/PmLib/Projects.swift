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
/// Two questions, in the order that costs least. An Area's name carries no `CODE-NNN` prefix, which
/// is a string test and rules out every project; and it is a directory PM has written notes into,
/// which is the same question `pm notes path` asks and costs a `stat`.
///
/// Both are needed, and the archive is why. `areas/` holds only Areas, so the name test looks
/// redundant there — but archived Areas and archived projects share one `archive/`, and asking this
/// function for the Areas in it has to leave `W-4 Old Thing` alone. The notes test is what keeps a
/// folder someone dropped into `areas/` for their own reasons from showing up as an empty Area.
///
/// A missing directory is not an error. Areas arrived after the other two roots and `areasPath` is
/// resolved rather than required, so "no `areas/` folder" is the ordinary state of every vault that
/// hasn't made one yet, and the honest answer to "which Areas are there" is none.
public func getAreaFolders(basePath: String) throws -> [String] {
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
        .filter { ProjectKind.of(folderName: $0.lastPathComponent) == .area }
        .filter { ((try? resolveNotesPath(projectPath: $0.path)) ?? nil) != nil }
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
