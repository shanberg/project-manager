import Foundation

/// What a task's `waiting:` target turns out to name.
///
/// The wait itself is stored on the task and means something without this: `waiting: [[Dana]]` is a
/// complete, working statement about a person, and no lookup will ever improve it. Resolution is what
/// PM adds *when it can* — the target names a project or area it knows, so the wait can be navigated
/// to and, more importantly, can be seen to have ended.
///
/// Note what isn't here: an error case. A target PM can't place is `unresolved`, not invalid. That
/// distinction is the whole reason the feature is worth having, because most things anyone waits on
/// are people and none of them are in the projects folder.
public enum WaitTarget: Equatable, Sendable {
    /// A project or area that's still live. The wait stands.
    case pending(folder: String)
    /// A project or area that's been archived. Whatever this task was waiting for has landed, and
    /// nobody has told the task yet — which is the moment this whole feature exists to catch.
    case released(folder: String)
    /// A name PM has no folder for, or one that names more than one thing. Displayed as written.
    case unresolved

    /// The folder this names, when it names one.
    public var folder: String? {
        switch self {
        case .pending(let f), .released(let f): return f
        case .unresolved: return nil
        }
    }

    /// Whether the thing being waited on is finished.
    public var isReleased: Bool {
        if case .released = self { return true }
        return false
    }
}

/// Match a wait target against one root's folder names, leniently.
///
/// Three ways to name the same folder, tried from the most complete statement to the least:
///
/// 1. the folder name itself — `W-1 Website Refresh`
/// 2. the title alone — `Website Refresh`, which is what a person writes and what the app offers
/// 3. an unambiguous code prefix — `W-1`, which is how the CLI has always let you name a project
///
/// Title before prefix, because a title is a whole answer and a prefix is an abbreviation of one; a
/// folder literally titled `W-1` would otherwise be shadowed by the prefix rule. All three compare
/// case-insensitively: this is a name someone typed into a sentence, not a path.
///
/// A prefix matching more than one folder returns nil rather than picking. `matchProjectResult` calls
/// that `ambiguous` and the CLI turns it into an error, which is right when a command is about to act
/// on one project; here the caller is drawing a row, and the honest thing to draw for a name that
/// could mean two projects is the same thing drawn for a name that means none.
func matchWaitTarget(_ target: String, in folders: [String]) -> String? {
    let q = target.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !q.isEmpty else { return nil }
    if let exact = folders.first(where: { $0.caseInsensitiveCompare(q) == .orderedSame }) { return exact }
    let byTitle = folders.filter {
        projectTitle(fromFolderName: $0).caseInsensitiveCompare(q) == .orderedSame
    }
    if byTitle.count == 1 { return byTitle[0] }
    if byTitle.count > 1 { return nil }
    let byPrefix = folders.filter { $0.lowercased().hasPrefix(q.lowercased()) }
    return byPrefix.count == 1 ? byPrefix[0] : nil
}

/// Resolve a wait target against the project roots, in the order a name should be understood: what's
/// in hand, then what's standing, then what's been put away.
///
/// The order is load-bearing rather than tidy. A project unarchived back into `active` is live again,
/// and a name that matches in both roots has to read as live — so `active` winning isn't a tiebreak,
/// it's the rule that stops a restored project from still looking finished. Same order as
/// `resolveProjectPath`, for the same reason.
///
/// - Parameter roots: each scope with its folder names, in `ProjectScope.allCases` order.
public func resolveWaitTarget(_ target: String, roots: [(scope: ProjectScope, folders: [String])]) -> WaitTarget {
    for root in roots {
        guard let folder = matchWaitTarget(target, in: root.folders) else { continue }
        return root.scope.isArchived ? .released(folder: folder) : .pending(folder: folder)
    }
    return .unresolved
}

/// Resolve every distinct wait target in one pass over the folders.
///
/// Batched because the callers are all list-shaped — a task list, a project index, a Waiting grouping
/// — and reading three directories once per row is the kind of thing that turns a scan into a stall.
/// The scan that already walks these folders can hand its lists straight in.
public func resolveWaitTargets(_ targets: [String],
                               roots: [(scope: ProjectScope, folders: [String])]) -> [String: WaitTarget] {
    var out: [String: WaitTarget] = [:]
    for target in targets where out[target] == nil {
        out[target] = resolveWaitTarget(target, roots: roots)
    }
    return out
}

/// Read the project roots off disk and resolve against them. For callers with no folder lists of their
/// own; anything drawing a list should read the folders once and use the batch form.
public func resolveWaitTarget(_ target: String) throws -> WaitTarget {
    let (config, paths) = try loadConfigAndPaths()
    let domainCodes = Array(config.domains.keys)
    let roots = try ProjectScope.allCases.map {
        (scope: $0, folders: try getFolders(basePath: $0.path(in: paths), scope: $0, domainCodes: domainCodes))
    }
    return resolveWaitTarget(target, roots: roots)
}
