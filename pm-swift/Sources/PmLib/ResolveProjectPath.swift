import Foundation

/// Resolve project name or prefix to full project path (in active or archive).
public func resolveProjectPath(nameOrPrefix: String) throws -> String {
    let (config, paths) = try loadConfigAndPaths()
    let domainCodes = Array(config.domains.keys)
    let active = getProjectFolders(basePath: paths.activePath, domainCodes: domainCodes)
    let archive = getProjectFolders(basePath: paths.archivePath, domainCodes: domainCodes)
    let all = active + archive
    guard let matched = matchProject(folders: all, query: nameOrPrefix) else {
        let trimmed = nameOrPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixMatches = all.filter { $0.hasPrefix(trimmed) }
        if prefixMatches.count > 1 {
            throw PmError.ambiguousProject(nameOrPrefix)
        }
        throw PmError.projectNotFound(nameOrPrefix)
    }
    let basePath = active.contains(matched) ? paths.activePath : paths.archivePath
    return (basePath as NSString).appendingPathComponent(matched)
}
