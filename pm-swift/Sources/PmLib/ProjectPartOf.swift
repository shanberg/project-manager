import Foundation

/// A project that is part of another: a *member* naming its *master* (docs/combining-projects.md).
///
/// Kept on the member, in its notes file's frontmatter beside `pm-icon`, as a quoted wikilink —
/// `pm-part-of: "[[S-004 Project Manager Tool]]"` — so Obsidian's properties read it as the link it is.
/// A member has one master and a master any number of members, which is why the fact lives on the side
/// there is one of; the master stores nothing, and its members are found by reading everyone else's.
///
/// **One level.** A master cannot be a member and a member cannot be a master. `setProjectPartOf` refuses
/// both, rather than letting a tree grow that every surface would then have to draw.
public enum ProjectPartOf {
    public static let frontmatterKey = "pm-part-of"

    /// The name written inside a stored value: `[[S-004 Tool|shown]]` → `S-004 Tool`. A bare name is
    /// taken as written, since a hand-edited property may not be a link. Nil for an empty value.
    public static func writtenName(in value: String) -> String? {
        var text = value.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("[["), text.hasSuffix("]]") { text = String(text.dropFirst(2).dropLast(2)) }
        if let pipe = text.firstIndex(of: "|") { text = String(text[..<pipe]) }
        text = text.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }

    /// What is written for a master: its folder name, as a quoted link.
    public static func value(forMaster folder: String) -> String {
        "\"[[\(folder)]]\""
    }
}

/// The master a notes file names, as written — resolve it against the folders to know what it means.
public func projectPartOf(rawText: String) -> String? {
    frontmatterValue(ProjectPartOf.frontmatterKey, in: rawText).flatMap(ProjectPartOf.writtenName(in:))
}

/// One member and the master it names.
public struct ProjectMembership: Equatable, Sendable {
    public let member: String
    public let memberScope: ProjectScope
    /// The master's folder, when the written name resolves to one.
    public let master: String?
    public let written: String
}

/// Every project and area that names a master, across all three roots.
///
/// Reads only the head of each notes file, since frontmatter is at the top — a vault of a few hundred
/// projects is a few hundred small reads, which is what the one query that needs this (`project.get`)
/// and the one write that checks it (`project.setPartOf`) can afford.
public func projectMemberships() throws -> [ProjectMembership] {
    let (config, paths) = try loadConfigAndPaths()
    let domainCodes = Array(config.domains.keys)
    let roots = try ProjectScope.allCases.map {
        (scope: $0, folders: try getFolders(basePath: $0.path(in: paths), scope: $0, domainCodes: domainCodes))
    }
    var out: [ProjectMembership] = []
    for root in roots {
        for folder in root.folders {
            let projectPath = (root.scope.path(in: paths) as NSString).appendingPathComponent(folder)
            guard let notes = try? resolveNotesPath(projectPath: projectPath),
                  let head = readHead(of: notes),
                  let written = projectPartOf(rawText: head) else { continue }
            let master = resolveWaitTarget(written, roots: roots).folder
            out.append(ProjectMembership(member: folder, memberScope: root.scope,
                                         master: master, written: written))
        }
    }
    return out
}

/// The first few kilobytes of a file, enough to hold its frontmatter. Nil when it can't be read.
private func readHead(of path: String, bytes: Int = 4096) -> String? {
    guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
    defer { try? handle.close() }
    let data = (try? handle.read(upToCount: bytes)) ?? Data()
    // A cut through a multi-byte character would fail to decode; the frontmatter is well before any cut.
    return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
}

/// Why a project can't be made part of another.
public enum PartOfRefusal: Error, Equatable, LocalizedError {
    case unknownMaster(String)
    case itself
    case masterIsArchived(String)
    case masterIsAMember(master: String, itsMaster: String)
    case memberIsAMaster(member: String, members: [String])

    public var errorDescription: String? {
        switch self {
        case .unknownMaster(let name):
            return "No project or area is called \(name)."
        case .itself:
            return "A project can't be part of itself."
        case .masterIsArchived(let master):
            return "\(master) is archived. Restore it before putting projects under it."
        case .masterIsAMember(let master, let itsMaster):
            return "\(master) is already part of \(itsMaster), and projects only nest one level."
        case .memberIsAMaster(let member, let members):
            let names = members.prefix(3).joined(separator: ", ") + (members.count > 3 ? "…" : "")
            return "\(member) already has projects under it (\(names)), and projects only nest one level."
        }
    }
}

/// The master `member` may be put under, resolved and checked — or the reason it can't.
///
/// `memberFolder` is the member's own folder name; `masterName` is as written by whoever asked.
public func checkedMaster(memberFolder: String, masterName: String,
                          memberships: [ProjectMembership],
                          roots: [(scope: ProjectScope, folders: [String])]) throws -> String {
    let target = resolveWaitTarget(masterName, roots: roots)
    guard let master = target.folder else { throw PartOfRefusal.unknownMaster(masterName) }
    guard master != memberFolder else { throw PartOfRefusal.itself }
    if case .released = target { throw PartOfRefusal.masterIsArchived(master) }
    if let own = memberships.first(where: { $0.member == master }), let itsMaster = own.master {
        throw PartOfRefusal.masterIsAMember(master: master, itsMaster: itsMaster)
    }
    let members = memberships.filter { $0.master == memberFolder }.map(\.member)
    if !members.isEmpty { throw PartOfRefusal.memberIsAMaster(member: memberFolder, members: members) }
    return master
}

/// `rawText` with its master set to `master`'s folder, or cleared when nil. Only the one line changes.
public func settingProjectPartOf(_ master: String?, in rawText: String) -> String {
    settingFrontmatterValue(ProjectPartOf.frontmatterKey, to: master.map(ProjectPartOf.value(forMaster:)),
                            in: rawText)
}
