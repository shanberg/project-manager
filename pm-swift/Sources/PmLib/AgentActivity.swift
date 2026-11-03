import Foundation

// MARK: - What an agent was doing while nobody was at the keys
//
// An away is a stretch with no input on the Mac, and from the attention log alone an agent run and a
// lunch look the same (docs/away-time.md). Claude Code keeps a transcript per session under
// `~/.claude/projects`, one JSON line per message, each with a `timestamp` and the session's `cwd`.
// Lines landing inside an away are evidence that work went on in that folder while the Mac was quiet.
//
// Read only, on demand, and never written anywhere: a transcript's folder and the minutes it was busy
// are all that's taken from it. Nothing about what the agent said or did is read. The October 2026
// log had agent activity inside 122 of 157 unanswered aways.

/// A minute a transcript was busy in, and the folder its session ran in.
public struct AgentMoment: Equatable, Sendable {
    /// The start of the minute.
    public var minute: Date
    /// The session's working directory, as the transcript gives it.
    public var folder: String
    /// The project or area the folder belongs to, when one claims it (`AgentFolders`). Nil otherwise.
    public var project: String?

    public init(minute: Date, folder: String, project: String? = nil) {
        self.minute = minute
        self.folder = folder
        self.project = project
    }
}

public enum AgentActivity {
    /// Where Claude Code keeps its transcripts. `PM_AGENT_TRANSCRIPTS` points it elsewhere — tests point
    /// it at an empty folder so a real transcript can't leak into an assertion.
    public static var transcriptsRoot: String {
        if let root = ProcessInfo.processInfo.environment["PM_AGENT_TRANSCRIPTS"], !root.isEmpty {
            return (root as NSString).expandingTildeInPath
        }
        return (NSHomeDirectory() as NSString).appendingPathComponent(".claude/projects")
    }

    /// The busy minutes in `range`, per folder, one moment per folder per minute, oldest first.
    /// Unresolved: `AgentFolders.resolve` says whose they are.
    ///
    /// A day of transcripts is around 130 MB, so each file is read once per process and then only from
    /// where the last read stopped — transcripts are only ever appended to.
    public static func moments(in range: DoneRange, root: String = transcriptsRoot) -> [AgentMoment] {
        let lo = Int(range.start.timeIntervalSince1970 / 60)
        let hi = Int(range.end.timeIntervalSince1970 / 60)
        var out: [AgentMoment] = []
        for file in transcripts(under: root, touchedIn: range) {
            guard let read = TranscriptCache.read(file), let folder = read.folder else { continue }
            for minute in read.minutes where minute >= lo && minute < hi {
                out.append(AgentMoment(minute: Date(timeIntervalSince1970: Double(minute) * 60), folder: folder))
            }
        }
        // Two sessions in one folder in the same minute are one busy minute.
        var seen = Set<String>()
        return out
            .sorted { $0.minute != $1.minute ? $0.minute < $1.minute : $0.folder < $1.folder }
            .filter { seen.insert("\($0.folder)|\($0.minute.timeIntervalSince1970)").inserted }
    }

    /// The transcripts that can hold a line in `range`: changed since it began, and begun before it ended.
    /// Subagents keep their own transcripts in folders under the session's, so the walk goes all the way down.
    static func transcripts(under root: String, touchedIn range: DoneRange) -> [String] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .creationDateKey, .isRegularFileKey]
        guard let walk = FileManager.default.enumerator(at: URL(fileURLWithPath: root),
                                                        includingPropertiesForKeys: keys) else { return [] }
        var out: [String] = []
        for case let url as URL in walk where url.pathExtension == "jsonl" {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true
            else { continue }
            if let modified = values.contentModificationDate, modified < range.start { continue }
            if let created = values.creationDate, created >= range.end { continue }
            out.append(url.path)
        }
        return out
    }

    // MARK: Parsing

    /// One transcript's folder and busy minutes, from a chunk of its lines. `bytes` must end at a line
    /// break or the end of what's been written; a line cut short is the caller's to hold back.
    static func scan(_ bytes: UnsafeRawBufferPointer, into minutes: inout Set<Int>, folder: inout String?) {
        guard let base = bytes.baseAddress else { return }
        let end = base + bytes.count
        var line = base
        while line < end {
            let lineEnd = memchr(line, 0x0A, end - line).map { UnsafeRawPointer($0) } ?? end
            if let stamp = value(of: timestampKey, in: line, lineEnd), let minute = epochMinute(stamp) {
                minutes.insert(minute)
            }
            if folder == nil, let cwd = value(of: cwdKey, in: line, lineEnd) {
                folder = String(decoding: UnsafeRawBufferPointer(start: cwd.baseAddress, count: cwd.count),
                                as: UTF8.self)
            }
            line = lineEnd + 1
        }
    }

    private static let timestampKey = Array(#""timestamp":""#.utf8)
    private static let cwdKey = Array(#""cwd":""#.utf8)

    /// The string value after `key` on the line, up to its closing quote, without unescaping. Paths and
    /// timestamps hold no quotes, so the first one closes it.
    private static func value(of key: [UInt8], in line: UnsafeRawPointer, _ lineEnd: UnsafeRawPointer)
        -> UnsafeBufferPointer<UInt8>? {
        guard let found = key.withUnsafeBytes({ memmem(line, lineEnd - line, $0.baseAddress, key.count) })
        else { return nil }
        let start = UnsafeRawPointer(found) + key.count
        guard start < lineEnd, let close = memchr(start, 0x22, lineEnd - start) else { return nil }
        return UnsafeBufferPointer(start: start.assumingMemoryBound(to: UInt8.self),
                                   count: UnsafeRawPointer(close) - start)
    }

    /// `2026-11-03T02:46:19.471Z` as whole minutes since 1970, without a formatter: there are tens of
    /// thousands of these a day. UTC only, which is all Claude Code writes; anything else is nil.
    static func epochMinute(_ text: UnsafeBufferPointer<UInt8>) -> Int? {
        guard text.count >= 17, text[4] == 0x2D, text[7] == 0x2D, text[10] == 0x54, text[13] == 0x3A,
              text.last == 0x5A else { return nil }
        func number(_ from: Int, _ count: Int) -> Int? {
            var n = 0
            for i in from..<(from + count) {
                let digit = Int(text[i]) - 48
                guard (0...9).contains(digit) else { return nil }
                n = n * 10 + digit
            }
            return n
        }
        guard let year = number(0, 4), let month = number(5, 2), let day = number(8, 2),
              let hour = number(11, 2), let minute = number(14, 2),
              (1...12).contains(month), (1...31).contains(day) else { return nil }
        // Days from the civil date (Howard Hinnant's algorithm).
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        let days = era * 146097 + doe - 719468
        return (days * 24 + hour) * 60 + minute
    }
}

/// Each transcript's busy minutes, kept for the life of the process and topped up from where the last
/// read stopped. Folio asks every time the menu bar opens; only what was appended since is read again.
private enum TranscriptCache {
    struct Entry {
        var size: UInt64 = 0
        /// Where the next read starts: just past the last whole line.
        var offset: UInt64 = 0
        var folder: String?
        var minutes = Set<Int>()
    }

    private static var entries: [String: Entry] = [:]
    private static let lock = NSLock()

    static func read(_ path: String) -> Entry? {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? UInt64
        else { return nil }
        lock.lock()
        defer { lock.unlock() }
        // A file that shrank was rewritten, not appended to: start it again.
        var entry = entries[path].flatMap { $0.size <= size ? $0 : nil } ?? Entry()
        guard size > entry.offset, let handle = FileHandle(forReadingAtPath: path) else { return entry }
        defer { try? handle.close() }
        try? handle.seek(toOffset: entry.offset)
        guard let data = try? handle.read(upToCount: Int(size - entry.offset)), !data.isEmpty
        else { return entry }
        // Up to the last line break; a line still being written is read whole next time.
        guard let lastBreak = data.lastIndex(of: 0x0A) else { return entry }
        let whole = data.startIndex..<data.index(after: lastBreak)
        data[whole].withUnsafeBytes { AgentActivity.scan($0, into: &entry.minutes, folder: &entry.folder) }
        entry.offset += UInt64(whole.count)
        entry.size = size
        entries[path] = entry
        return entry
    }
}

// MARK: - Whose folder it is

/// Which project or area a folder an agent ran in belongs to.
///
/// - `pm-folders` in a notes file's frontmatter claims folders outright: `pm-folders: ["~/dev/designs"]`,
///   or one path as a plain value. A folder inside a claimed one is claimed too; the deepest claim wins.
/// - Failing that, a folder whose last component spells a project's title, ignoring case and anything
///   that isn't a letter or digit: `~/dev/maxwell-carmody` is Maxwell Carmody.
/// - Otherwise nobody's, and it's shown as the folder.
public struct AgentFolders: Equatable, Sendable {
    /// Claimed path (expanded, no trailing slash) → project folder name.
    public var claims: [String: String]
    /// Spelled title → project folder name, for the name match. A title two projects share matches neither.
    public var titles: [String: String]

    public static let frontmatterKey = "pm-folders"

    public init(claims: [String: String] = [:], titles: [String: String] = [:]) {
        self.claims = claims
        self.titles = titles
    }

    /// From each project's folder name and the `pm-folders` it claims.
    public init(projects: [(folder: String, claims: [String])]) {
        var claims: [String: String] = [:]
        var titles: [String: String] = [:]
        var shared = Set<String>()
        for project in projects {
            for path in project.claims { claims[Self.normalizedPath(path)] = project.folder }
            let spelled = Self.spelling(projectTitle(fromFolderName: project.folder))
            guard !spelled.isEmpty else { continue }
            if titles[spelled] != nil { shared.insert(spelled) }
            titles[spelled] = project.folder
        }
        for spelled in shared { titles[spelled] = nil }
        self.init(claims: claims, titles: titles)
    }

    /// A claim on the folder or any folder it's in, else a title spelled by the folder or any folder
    /// it's in — `~/dev/maxwell-carmody/packages/core` is still Maxwell Carmody's. Deepest first, and
    /// never the home folder or above it, whose names say nothing about a project.
    public func project(for folder: String) -> String? {
        let ancestors = Self.ancestors(of: Self.normalizedPath(folder))
        for path in ancestors { if let claimed = claims[path] { return claimed } }
        for path in ancestors {
            if let named = titles[Self.spelling((path as NSString).lastPathComponent)] { return named }
        }
        return nil
    }

    /// The path and every folder it's in, deepest first, stopping short of the home folder.
    static func ancestors(of path: String) -> [String] {
        let home = NSHomeDirectory()
        var out: [String] = []
        var path = path
        while path != home, path != "/", !path.isEmpty {
            out.append(path)
            let parent = (path as NSString).deletingLastPathComponent
            guard parent != path else { break }
            path = parent
        }
        return out
    }

    public func resolve(_ moments: [AgentMoment]) -> [AgentMoment] {
        var cache: [String: String?] = [:]
        return moments.map { moment in
            var out = moment
            if let known = cache[moment.folder] {
                out.project = known
            } else {
                let project = self.project(for: moment.folder)
                cache[moment.folder] = project
                out.project = project
            }
            return out
        }
    }

    static func normalizedPath(_ path: String) -> String {
        var out = (path.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
        while out.count > 1, out.hasSuffix("/") { out.removeLast() }
        return out
    }

    static func spelling(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    /// Every project's and area's claims, from the head of each notes file, and every folder's title.
    public static func load() throws -> AgentFolders {
        let (config, paths) = try loadConfigAndPaths(skipPathValidation: true)
        let codes = Array(config.domains.keys)
        var projects: [(folder: String, claims: [String])] = []
        for scope in ProjectScope.allCases {
            let base = scope.path(in: paths)
            for folder in (try? getFolders(basePath: base, scope: scope, domainCodes: codes)) ?? [] {
                let path = (base as NSString).appendingPathComponent(folder)
                let head = (try? resolveNotesPath(projectPath: path)).flatMap { readHead(of: $0) }
                projects.append((folder, head.map(projectAgentFolders(rawText:)) ?? []))
            }
        }
        return AgentFolders(projects: projects)
    }
}

/// The folders a notes file claims under `pm-folders`: a flow list (`["~/a", "~/b"]`) or one plain path.
public func projectAgentFolders(rawText: String) -> [String] {
    guard let value = frontmatterValue(AgentFolders.frontmatterKey, in: rawText)?
        .trimmingCharacters(in: .whitespaces), !value.isEmpty else { return [] }
    guard value.hasPrefix("["), value.hasSuffix("]") else { return [unquoted(value)] }
    return value.dropFirst().dropLast().split(separator: ",")
        .map { unquoted($0.trimmingCharacters(in: .whitespaces)) }
        .filter { !$0.isEmpty }
}

private func unquoted(_ text: String) -> String {
    for quote in ["\"", "'"] where text.count >= 2 && text.hasPrefix(quote) && text.hasSuffix(quote) {
        return String(text.dropFirst().dropLast())
    }
    return text
}
