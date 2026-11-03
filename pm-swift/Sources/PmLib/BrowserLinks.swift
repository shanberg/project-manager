import Foundation

// MARK: - Whose page is in front of the browser
//
// While you're tracked on one project, the browser's front tab can be another project's: a Figma file,
// a Google Doc, a staging site, a Slack channel that project links. The link is already written down —
// it's in that project's `## Links`, the mirror of its Links frame — so the tab can be matched against
// it without anything new being kept. See docs/away-time.md, Browser signals.
//
// Nothing here reads a browser. The app reads the front tab and asks; PmLib says whose it is.

/// A web address reduced to what a tab and a link are compared on.
public enum LinkKey: Hashable, Sendable {
    /// A Slack channel, by its ID — the same in `app.slack.com/client/T…/C…` and in a shared
    /// `<workspace>.slack.com/archives/C…/p…` message link.
    case slackChannel(String)
    /// Anything else: its host without `www.`, and its path, a component at a time.
    case page(host: String, path: [String])

    public init?(_ text: String) {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespaces)),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              var host = url.host?.lowercased() else { return nil }
        let path = url.path.split(separator: "/").map(String.init)
        if host == "app.slack.com" || host.hasSuffix(".slack.com") {
            if let channel = Self.slackChannel(host: host, path: path) {
                self = .slackChannel(channel)
                return
            }
        }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        self = .page(host: host, path: path)
    }

    /// `C…` or `G…` (a private channel). A DM (`D…`) is a conversation with a person, never a
    /// project's, so it's no channel here.
    private static func slackChannel(host: String, path: [String]) -> String? {
        let candidate: String?
        if host == "app.slack.com", path.count >= 3, path[0] == "client" {
            candidate = path[2]
        } else if path.count >= 2, path[0] == "archives" {
            candidate = path[1]
        } else {
            candidate = nil
        }
        guard let id = candidate?.uppercased(), let first = id.first, first == "C" || first == "G",
              id.count >= 8 else { return nil }
        return id
    }

    /// Whether a tab at `self` is on the page `link` names: the same channel, or the same host with the
    /// link's path a prefix of the tab's. A link to a bare host names no page — it would claim every tab
    /// on a site most projects share.
    public func isOnPage(_ link: LinkKey) -> Bool {
        switch (self, link) {
        case (.slackChannel(let tab), .slackChannel(let named)):
            return tab == named
        case (.page(let host, let path), .page(let linkHost, let linkPath)):
            return host == linkHost && !linkPath.isEmpty && path.starts(with: linkPath)
        default:
            return false
        }
    }

    /// How much of the address a match rests on, so the more specific of two links wins.
    var depth: Int {
        switch self {
        case .slackChannel: return .max
        case .page(_, let path): return path.count
        }
    }

    public var isSlackChannel: Bool { if case .slackChannel = self { return true } else { return false } }
}

/// Every project's links, ready to be asked "whose page is this".
public struct BrowserLinkIndex: Sendable {
    public struct Entry: Equatable, Sendable {
        public var key: LinkKey
        public var project: String
        /// What the link is called in the project, or its address.
        public var label: String
    }

    public var entries: [Entry]

    public init(entries: [Entry]) { self.entries = entries }

    /// The project whose link the tab is on, and that link's label. The deepest match wins; a match
    /// two projects share at the same depth is nobody's — Folio would only be guessing.
    public func match(_ tab: String) -> (project: String, label: String)? {
        guard let key = LinkKey(tab) else { return nil }
        let hits = entries.filter { key.isOnPage($0.key) }
        guard let deepest = hits.map(\.key.depth).max() else { return nil }
        let best = hits.filter { $0.key.depth == deepest }
        guard Set(best.map(\.project)).count == 1, let first = best.first else { return nil }
        return (first.project, first.label)
    }

    /// From each project's `## Links`, children included.
    public init(projects: [(folder: String, links: [LinkEntry])]) {
        var entries: [Entry] = []
        func walk(_ links: [LinkEntry], _ folder: String) {
            for link in links {
                if let url = link.url, let key = LinkKey(url) {
                    entries.append(Entry(key: key, project: folder, label: link.label ?? url))
                }
                walk(link.children ?? [], folder)
            }
        }
        for project in projects { walk(project.links, project.folder) }
        self.init(entries: entries)
    }

    /// Every active project's and area's links. Each notes file is read again only when it changed.
    public static func load() throws -> BrowserLinkIndex {
        let (config, paths) = try loadConfigAndPaths(skipPathValidation: true)
        let codes = Array(config.domains.keys)
        var projects: [(folder: String, links: [LinkEntry])] = []
        for scope in ProjectScope.allCases where !scope.isArchived {
            let base = scope.path(in: paths)
            for folder in (try? getFolders(basePath: base, scope: scope, domainCodes: codes)) ?? [] {
                let projectPath = (base as NSString).appendingPathComponent(folder)
                guard let notesPath = (try? resolveNotesPath(projectPath: projectPath)) ?? nil else { continue }
                projects.append((folder, LinksCache.shared.links(notesPath: notesPath)))
            }
        }
        return BrowserLinkIndex(projects: projects)
    }
}

private final class LinksCache: @unchecked Sendable {
    static let shared = LinksCache()
    private let lock = NSLock()
    private var entries: [String: (modified: Date?, links: [LinkEntry])] = [:]

    func links(notesPath: String) -> [LinkEntry] {
        let modified = notesLastEdited(path: notesPath)
        lock.lock()
        let hit = entries[notesPath]
        lock.unlock()
        if let hit, hit.modified == modified, modified != nil { return hit.links }
        let links = (try? String(contentsOfFile: notesPath, encoding: .utf8))
            .flatMap { try? parseNotes(markdown: $0).links } ?? []
        lock.lock()
        entries[notesPath] = (modified, links)
        lock.unlock()
        return links
    }
}

// MARK: - Sites that aren't work

/// Sites you've said aren't work, by domain (docs/away-time.md): one in front for a minute ends the span,
/// as a not-work app does. A domain covers its subdomains: `youtube.com` is `m.youtube.com` too.
public enum NotWorkSites {
    public static func matches(_ tab: String, domains: [String]) -> Bool {
        guard let host = URL(string: tab)?.host?.lowercased() else { return false }
        return domains.contains { raw in
            let domain = normalized(raw)
            return !domain.isEmpty && (host == domain || host.hasSuffix("." + domain))
        }
    }

    /// What someone typed, as a bare domain: `https://www.YouTube.com/feed` → `youtube.com`.
    public static func normalized(_ text: String) -> String {
        var domain = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let url = URL(string: domain), let host = url.host, url.scheme != nil { domain = host }
        if let slash = domain.firstIndex(of: "/") { domain = String(domain[..<slash]) }
        if domain.hasPrefix("www.") { domain.removeFirst(4) }
        return domain
    }
}

// MARK: - A Slack channel nobody has linked

/// The channel's name from a Slack tab's title — "brand-refresh (Channel) - Acme - Slack" is
/// `brand-refresh`. Nil when the title doesn't say.
public func slackChannelName(fromTitle title: String) -> String? {
    let trimmed = title.trimmingCharacters(in: .whitespaces)
    guard let end = trimmed.range(of: " (Channel)") ?? trimmed.range(of: " (Private channel)") else { return nil }
    let name = trimmed[..<end.lowerBound].trimmingCharacters(in: .whitespaces)
    return name.isEmpty ? nil : name.hasPrefix("#") ? String(name.dropFirst()) : name
}

/// Minutes an unlinked channel was in front, per day: what decides when to offer to link it (5 min on
/// two different days). Kept per Mac; holds channel IDs and day numbers, nothing else.
public struct ChannelSightings: Codable, Equatable, Sendable {
    /// Channel ID → local day (`YYYY-MM-DD`) → minutes in front.
    public var minutes: [String: [String: Int]] = [:]

    public init(minutes: [String: [String: Int]] = [:]) { self.minutes = minutes }

    public static let threshold = 5
    public static let days = 2

    public mutating func add(_ count: Int, channel: String, day: String) {
        minutes[channel, default: [:]][day, default: 0] += count
        // A fortnight is plenty to tell a habit from a visit; older days are let go.
        if let days = minutes[channel], days.count > 14 {
            minutes[channel] = Dictionary(uniqueKeysWithValues: days.sorted { $0.key > $1.key }.prefix(14).map { ($0.key, $0.value) })
        }
    }

    /// Whether the channel has been in front long enough, on enough days, to be worth linking.
    public func isWorthLinking(_ channel: String) -> Bool {
        (minutes[channel] ?? [:]).values.filter { $0 >= Self.threshold }.count >= Self.days
    }
}
