import Foundation

/// Resolve project name or prefix to full project path (in active or archive).
/// Throws emptyProjectQuery if nameOrPrefix is empty or only whitespace.
public func resolveProjectPath(nameOrPrefix: String) throws -> String {
    let trimmed = nameOrPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw PmError.emptyProjectQuery }
    let (config, paths) = try loadConfigAndPaths()
    return try resolveProjectPath(config: config, paths: paths, nameOrPrefix: trimmed)
}

/// Internal overload for testing with injected config and paths (avoids loading from disk).
/// When the same folder name exists in both active and archive, the active path is returned.
internal func resolveProjectPath(config: PmConfig, paths: ResolvedPaths, nameOrPrefix: String) throws -> String {
    let domainCodes = Array(config.domains.keys)
    let active = try getProjectFolders(basePath: paths.activePath, domainCodes: domainCodes)
    let archive = try getProjectFolders(basePath: paths.archivePath, domainCodes: domainCodes)
    let all = active + archive
    switch matchProjectResult(folders: all, query: nameOrPrefix) {
    case .matched(let folderName):
        // Prefer active when the same folder name exists in both (active.contains checked first).
        let basePath = active.contains(folderName) ? paths.activePath : paths.archivePath
        return (basePath as NSString).appendingPathComponent(folderName)
    case .ambiguous:
        throw PmError.ambiguousProject(nameOrPrefix)
    case .notFound:
        throw PmError.projectNotFound(nameOrPrefix)
    }
}
