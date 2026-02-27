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
