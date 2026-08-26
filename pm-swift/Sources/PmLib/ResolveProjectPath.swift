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
///
/// Three roots, searched in the order a name should be understood: what's in hand first, then what's
/// standing, then what's been put away. A name present in more than one resolves to the earliest —
/// which is how `active` has always won over `archive`, now with `areas` between them.
///
/// This is the one place every surface turns a name into a thing, so teaching it about Areas is what
/// makes `task.add`, `session.note`, `notes.get` and focus work on one without any of them changing.
internal func resolveProjectPath(config: PmConfig, paths: ResolvedPaths, nameOrPrefix: String) throws -> String {
    let domainCodes = Array(config.domains.keys)
    let roots: [(base: String, folders: [String])] = try ProjectScope.allCases.map {
        ($0.path(in: paths), try getFolders(basePath: $0.path(in: paths), scope: $0, domainCodes: domainCodes))
    }
    switch matchProjectResult(folders: roots.flatMap(\.folders), query: nameOrPrefix) {
    case .matched(let folderName):
        guard let root = roots.first(where: { $0.folders.contains(folderName) }) else {
            throw PmError.projectNotFound(nameOrPrefix)
        }
        return (root.base as NSString).appendingPathComponent(folderName)
    case .ambiguous:
        throw PmError.ambiguousProject(nameOrPrefix)
    case .notFound:
        throw PmError.projectNotFound(nameOrPrefix)
    }
}
