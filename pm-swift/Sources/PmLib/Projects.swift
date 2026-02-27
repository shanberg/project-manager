import Foundation

func buildProjectPattern(domainCodes: [String]) -> NSRegularExpression? {
    let sorted = domainCodes.sorted { $0.count > $1.count }
    let escaped = sorted.map { NSRegularExpression.escapedPattern(for: $0) }
    let pattern = "^(\(escaped.joined(separator: "|")))-\\d+\\s+.+$"
    return try? NSRegularExpression(pattern: pattern)
}

public func getProjectFolders(basePath: String, domainCodes: [String]) -> [String] {
    let codes = domainCodes.isEmpty ? Array(defaultDomains.keys) : domainCodes
    guard let pattern = buildProjectPattern(domainCodes: codes) else { return [] }
    let url = URL(fileURLWithPath: basePath)
    guard let entries = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
        return []
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

public func matchProject(folders: [String], query: String) -> String? {
    let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
    if q.isEmpty { return nil }
    if let exact = folders.first(where: { $0 == q }) { return exact }
    let prefixMatches = folders.filter { $0.hasPrefix(q) }
    if prefixMatches.count == 1 { return prefixMatches[0] }
    if prefixMatches.count > 1 { return nil }
    return nil
}
