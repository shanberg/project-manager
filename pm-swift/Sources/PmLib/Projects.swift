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

public func matchProject(folders: [String], query: String) -> String? {
    let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
    if q.isEmpty { return nil }
    if let exact = folders.first(where: { $0 == q }) { return exact }
    let prefixMatches = folders.filter { $0.hasPrefix(q) }
    if prefixMatches.count == 1 { return prefixMatches[0] }
    if prefixMatches.count > 1 { return nil }
    return nil
}
