import Foundation

/// What a wait is called on screen: the resolved project's *current* title, falling back to the text
/// as stored.
///
/// Reading the name from the folder rather than from the token is what makes a rename invisible. The
/// stored token goes on saying `W-1 Website Refresh` long after the project became `W-1 Site Refresh`
/// — `matchWaitTarget`'s code rule is what keeps it resolving, and this is what keeps anyone from
/// having to know it did. Drawing the stored text instead would leave every surface quietly asserting
/// an old name, which is worse than the broken link it replaced: a dead reference announces itself,
/// and a stale one doesn't.
///
/// An unresolved target is drawn exactly as written, because the text is all there is. `[[Dana]]` is a
/// complete statement and there is nothing to improve about it.
public func waitDisplayName(target: String, resolution: WaitTarget) -> String {
    resolution.folder.map(projectTitle(fromFolderName:)) ?? target
}

/// One thing being waited on, and every task waiting on it.
///
/// The inline token answers "why can't I do *this*?" — it's part of the sentence the task makes, and
/// it wraps with it. That's the right shape for a task list and the wrong shape for the other
/// question, which is "what am I waiting on?" Asked that way the target is the subject, not a
/// modifier, and the tasks are its list: one heading, one column, everything under it aligned. The
/// alignment given up by drawing the wait inline is paid back here.
///
/// Grouping is also what makes the unblock event legible. A project being archived releases every task
/// waiting on it at once, and that is one event about one target — so the surface that reports it has
/// to be grouped by target, or the news arrives as several unrelated rows quietly changing colour.
public struct WaitingGroup<Task> {
    /// What two spellings of the same target have in common. The resolved folder when there is one, so
    /// `[[W-1]]` and `[[Website Refresh]]` land in one group; the lowercased text otherwise, because
    /// an unresolved name has nothing else to be identified by.
    public let key: String
    /// The target as somebody wrote it — the first spelling in the input, which is why the input's
    /// order is the caller's to decide.
    public let target: String
    public let resolution: WaitTarget
    public let tasks: [Task]

    /// What the group is called — see `waitDisplayName`.
    public var title: String { waitDisplayName(target: target, resolution: resolution) }

    /// Whether what these tasks were waiting on has landed.
    public var isReleased: Bool { resolution.isReleased }

    public init(key: String, target: String, resolution: WaitTarget, tasks: [Task]) {
        self.key = key
        self.target = target
        self.resolution = resolution
        self.tasks = tasks
    }
}

extension WaitingGroup: Identifiable { public var id: String { key } }
extension WaitingGroup: Equatable where Task: Equatable {}
extension WaitingGroup: Sendable where Task: Sendable {}

/// Gather waiting tasks into one group per thing being waited on.
///
/// - Parameters:
///   - tasks: every task that is waiting, in whatever order the caller wants the groups' names taken
///     from and their tasks listed in.
///   - target: what a task says it's waiting on — its effective wait, so a task under a waiting parent
///     files under the parent's target rather than under nothing.
///   - resolutions: what each distinct target turned out to name, from `resolveWaitTargets`. A target
///     missing from the map is treated as unresolved, which is what it is.
///
/// **Released groups come first.** Every other ordering here is arbitrary and this one isn't: a
/// released group is the only kind carrying news. It says work you filed away as blocked is live
/// again, which is a thing to act on today, where a pending group is a thing to act on when somebody
/// else is done. Unresolved goes last — not because it matters least, but because PM knows least about
/// it, and a list sorted by what the app can tell you should be honest about where that runs out.
///
/// Within each band, by title, case-insensitively. Alphabetical rather than by size: a group's size is
/// how much of your work one person is holding up, which is interesting, but it makes the list reorder
/// itself every time you tick something off — and a list you re-read is one you want to stay put.
public func waitingGroups<Task>(_ tasks: [Task],
                                target: (Task) -> String,
                                resolutions: [String: WaitTarget]) -> [WaitingGroup<Task>] {
    var order: [String] = []
    var names: [String: String] = [:]
    var resolved: [String: WaitTarget] = [:]
    var members: [String: [Task]] = [:]

    for task in tasks {
        let name = target(task)
        let resolution = resolutions[name] ?? .unresolved
        let key = resolution.folder ?? name.lowercased()
        if members[key] == nil {
            order.append(key)
            names[key] = name
            resolved[key] = resolution
        }
        members[key, default: []].append(task)
    }

    return order
        .map { WaitingGroup(key: $0, target: names[$0] ?? $0,
                            resolution: resolved[$0] ?? .unresolved, tasks: members[$0] ?? []) }
        .sorted { a, b in
            let rank = (band(a.resolution), band(b.resolution))
            if rank.0 != rank.1 { return rank.0 < rank.1 }
            return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
        }
}

/// Which band a resolution sorts into. Released first — see `waitingGroups`.
private func band(_ resolution: WaitTarget) -> Int {
    switch resolution {
    case .released: return 0
    case .pending: return 1
    case .unresolved: return 2
    }
}

/// A waiting group as the contract publishes it: the target, what it resolved to, and the tasks.
///
/// Flat rather than generic, because a JSON shape has to be one shape. `state` is the resolution
/// spelled out for a reader that has no `WaitTarget` — an adapter, a model, a shell script — and it is
/// the field any of them should branch on, because it's the one that says whether the wait still holds.
public struct WaitingBucket: Codable, Equatable, Sendable {
    /// The target as the task line spells it.
    public let target: String
    /// The resolved project's current title, else the target as written.
    public let title: String
    /// The folder this target names, when it names one PM can find.
    public let folder: String?
    /// `pending`, `released`, or `unresolved`.
    public let state: String
    public let tasks: [TaskSearchHit]

    public init(target: String, title: String, folder: String?, state: String, tasks: [TaskSearchHit]) {
        self.target = target
        self.title = title
        self.folder = folder
        self.state = state
        self.tasks = tasks
    }
}

public extension WaitTarget {
    /// The resolution as one word, for anything reading this over a wire.
    var stateName: String {
        switch self {
        case .pending: return "pending"
        case .released: return "released"
        case .unresolved: return "unresolved"
        }
    }
}

/// Everything being waited on, across every project, grouped by what it's waiting on.
///
/// Built on `searchableTasks` rather than a scan of its own: that walk already reads every project's
/// notes and already carries the wait, so asking it this second question costs a filter. Callers with a
/// warmed index of their own (the macOS app has one) should group their own rows instead — see
/// `waitingGroups`, which is the part with the rules in it.
public func waitingBuckets(includeArchived: Bool = false,
                           includeActive: Bool = true) throws -> [WaitingBucket] {
    let hits = try searchableTasks(includeArchived: includeArchived, includeActive: includeActive)
        .filter { $0.effectiveWaiting != nil }
    let (config, paths) = try loadConfigAndPaths(skipPathValidation: true)
    let codes = Array(config.domains.keys)
    let roots = ProjectScope.allCases.map {
        (scope: $0, folders: (try? getFolders(basePath: $0.path(in: paths), scope: $0, domainCodes: codes)) ?? [])
    }
    let resolutions = resolveWaitTargets(hits.compactMap(\.effectiveWaiting), roots: roots)
    return waitingGroups(hits, target: { $0.effectiveWaiting ?? "" }, resolutions: resolutions)
        .map { WaitingBucket(target: $0.target, title: $0.title, folder: $0.resolution.folder,
                             state: $0.resolution.stateName, tasks: $0.tasks) }
}
