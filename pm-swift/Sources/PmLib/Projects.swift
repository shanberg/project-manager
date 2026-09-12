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
    let entries: [DirectoryListingCache.Entry]
    do {
        entries = try directoryListings.entries(of: basePath)
    } catch {
        let message = (error as NSError).localizedDescription
        throw PmError.cannotListDirectory(path: basePath, message: message)
    }
    return entries
        .filter(\.isDirectory)
        .map(\.name)
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
    let entries: [DirectoryListingCache.Entry]
    do {
        entries = try directoryListings.entries(of: basePath)
    } catch {
        if isFileNotFoundError(error) { return [] }
        throw PmError.cannotListDirectory(path: basePath, message: (error as NSError).localizedDescription)
    }
    return entries
        .filter { $0.isDirectory && !ProjectKind.of(folderName: $0.name).isNumbered }
        .map { url.appendingPathComponent($0.name, isDirectory: true) }
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

// MARK: - Listing a root, once per change

/// A directory's entries — each one's name, and whether it is a folder — cached against the directory's
/// modification date.
///
/// **Why.** Turning a project name into a folder lists every PARA root, and every surface does it on every
/// call: the CLI, the MCP server, Raycast through the CLI, and the Mac app several times per checkbox
/// tick. With a thousand projects one resolution measured 16ms, nearly all of it these listings, against
/// 0.03ms to read the notes file itself. A directory's modification date moves whenever an entry is
/// added, removed or renamed, and that is all the project and area listings read — so a cheap stat tells
/// whether the last listing still holds. The app's root watcher already depends on the same property of
/// the filesystem (`ConfigWatcher.watchRoots`).
///
/// **Only the listing is cached, never the questions asked of it.** Whether an area-shaped folder carries
/// notes depends on what is *inside* that folder, which does not move the root's date, so `hasNotes` is
/// asked afresh every time.
///
/// Three rules keep the cache from ever answering with a listing that is out of date:
///
///   * **The date is read before the listing, not after.** Read after, a change landing between the two
///     would be stored under the new date alongside the old entries, and look current until the next
///     change. Read before, the same race stores the new entries under the old date, and the next call
///     sees the date has moved and lists again. The worst case is one listing too many.
///   * **A listing is not kept while the directory's date is recent** (`racyWindow`, two seconds). A
///     filesystem that records whole seconds — or two, like FAT — would give a folder created in the same
///     second as the listing the same date the listing was stored under. This is git's "racily clean"
///     rule for its index, for the same reason. It is what lets `project.create` followed at once by
///     `task.add` on that project work in one MCP session on any filesystem.
///   * **And an entry is trusted for `maxAge` at most**, ten seconds, as a backstop for a filesystem that
///     does not move a directory's date at all — some network and cloud mounts. On APFS the date alone is
///     exact; the age only bounds how long anything stranger could be wrong for.
///
/// Errors are never cached, and a directory with no readable date never is either.
final class DirectoryListingCache: @unchecked Sendable {
    struct Entry: Equatable, Sendable {
        let name: String
        let isDirectory: Bool
    }

    private let lock = NSLock()
    private var stored: [String: (stamp: Date, listedAt: Date, entries: [Entry])] = [:]

    private let stamp: @Sendable (String) -> Date?
    private let list: @Sendable (String) throws -> [Entry]
    private let now: @Sendable () -> Date
    let racyWindow: TimeInterval
    let maxAge: TimeInterval

    init(stamp: @escaping @Sendable (String) -> Date? = DirectoryListingCache.modificationDate,
         list: @escaping @Sendable (String) throws -> [Entry] = DirectoryListingCache.listEntries,
         now: @escaping @Sendable () -> Date = { Date() },
         racyWindow: TimeInterval = 2, maxAge: TimeInterval = 10) {
        self.stamp = stamp
        self.list = list
        self.now = now
        self.racyWindow = racyWindow
        self.maxAge = maxAge
    }

    func entries(of path: String) throws -> [Entry] {
        let stamp = self.stamp(path)          // before the listing — see above
        let now = self.now()
        if let stamp, let hit = lookup(path), hit.stamp == stamp, now.timeIntervalSince(hit.listedAt) < maxAge {
            return hit.entries
        }
        let entries = try list(path)
        lock.lock(); defer { lock.unlock() }
        if let stamp, now.timeIntervalSince(stamp) >= racyWindow {
            stored[path] = (stamp, now, entries)
        } else {
            stored[path] = nil
        }
        return entries
    }

    private func lookup(_ path: String) -> (stamp: Date, listedAt: Date, entries: [Entry])? {
        lock.lock(); defer { lock.unlock() }
        return stored[path]
    }

    static let modificationDate: @Sendable (String) -> Date? = { path in
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    /// The listing the two folder functions used to make themselves: hidden files skipped, and whether
    /// each entry is a directory read from the same resource values.
    static let listEntries: @Sendable (String) throws -> [Entry] = { path in
        try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: path),
                                                    includingPropertiesForKeys: [.isDirectoryKey],
                                                    options: [.skipsHiddenFiles])
            .map { Entry(name: $0.lastPathComponent,
                         isDirectory: (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true) }
    }
}

/// The one cache every folder listing goes through.
let directoryListings = DirectoryListingCache()
