import Foundation
import PmLib

/// The app-wide scan of the projects folders, shared by every `PMStore`.
///
/// These two lists — the recency-ordered switcher list and the full sidebar list — describe *all*
/// projects, not the one a store is bound to, so they don't belong to any single store. When the app
/// had exactly one `PMStore` that distinction didn't matter; with a store per open window it does:
/// each store would otherwise run the same protected-folder scan and the same per-project notes reads
/// on its own timer. Hoisting them here means the scan happens once no matter how many windows are
/// open, and every store mirrors the result (see `PMStore.init`).
@MainActor
final class ProjectIndex: ObservableObject {
    static let shared = ProjectIndex()

    /// Projects ordered by notes-file mtime, newest first, each carrying cached progress/due/summary so
    /// a switcher can render rings + hints without protected-folder reads while it's being built.
    ///
    /// Unlike the old per-store version this excludes nothing: a consumer drops whichever project it's
    /// showing (`PMStore.recents` does exactly that), which is why the cap is one higher than the eight
    /// rows a switcher wants.
    @Published private(set) var recents: [Recent] = []

    /// Every project in the active and archive folders, newest-edited first within each group, each
    /// carrying cached progress + hero task for the project sidebar. Its (much larger) scan is gated on
    /// `retain()` — nothing pays for it while every sidebar is hidden.
    @Published private(set) var allProjects: [ProjectEntry] = []

    /// Every open task across every project, for the quick bar's task search.
    ///
    /// Falls out of the same pass that fills `allProjects`: that scan already reads each project's
    /// notes to find its progress and hero task, so keeping the rest of the open tasks costs the read
    /// nothing — only the memory to hold them. Gated on the same `retain()`, so nothing pays for it
    /// while no sidebar and no quick bar wants it.
    @Published private(set) var openTasks: [TaskEntry] = []

    // MARK: Types

    /// One row of the full project list: the project, its folder-name parts (the sidebar groups and
    /// sorts on these), whether it lives in the archive folder, and the same cached completion/next-task
    /// pair the switchers show. `detailsLoaded` is false for the name-only skeleton the first scan paints
    /// before the per-project notes reads land (and for projects past `maxDetailWarm`, whose notes are
    /// never read) — those rows have no progress, next task, or due date yet.
    struct ProjectEntry: Identifiable, Equatable {
        /// Full folder name, e.g. "H-004 Maxwell Carmody" — also the `pm` project identifier.
        let name: String
        let projectKey: String
        /// Domain code ("H") and sequence number (4) parsed off the folder name, for code sorting.
        /// Empty/zero if the name doesn't parse (it always should — the scan only returns matches).
        let code: String
        let number: Int
        /// The name without its "CODE-NNN " prefix, for name sorting and the row's label.
        let shortName: String
        /// The code's configured domain label ("Home"), falling back to the bare code. An area has no
        /// domain and gets "Areas", so a domain-grouped list has somewhere to put it.
        let domain: String
        /// Project or area. Read off the folder name, never stored.
        let kind: ProjectKind
        let isArchived: Bool
        /// Notes-file mtime (folder mtime as a fallback), for recency sorting.
        let modified: Date
        let done: Int
        let total: Int
        /// The project's focused task, else its first open one — the row's second line.
        let nextTask: String?
        /// Earliest due among its open tasks, for due grouping.
        let nextDue: String?
        let detailsLoaded: Bool
        var id: String { projectKey }
        var fraction: Double { total > 0 ? Double(done) / Double(total) : 0 }
        /// Whether a completion ring means anything here — the kind's answer, forwarded so a view can
        /// ask a row rather than reach through it.
        var showsProgress: Bool { kind.showsProgress }
    }

    /// One open task, somewhere. What a cross-project search matches against, and enough to go to it.
    ///
    /// The line coordinates are a hint, not an address. They were true when the scan ran and the file
    /// may have been edited since, so going to one of these re-reads the project and finds the task by
    /// its text — see `QuickBarController.focus(_:)`. They're kept because they break the tie when two
    /// open tasks read the same.
    struct TaskEntry: Identifiable, Equatable, SearchableTask {
        let projectKey: String
        let projectName: String
        /// The project name without its "CODE-NNN " prefix, for the row's second line.
        let projectShortName: String
        let isArchived: Bool
        let text: String
        /// Own due date, else the nearest one inherited from an ancestor — the same value a task's own
        /// badge shows.
        let due: String?
        /// Whether this is the project's focused task, which floats it up the ranking.
        let isFocused: Bool
        let sessionIndex: Int
        let lineIndex: Int
        var id: String { "\(projectKey)#\(sessionIndex):\(lineIndex)" }
    }

    /// A recent project plus its cached completion/due/summary. `fraction` is the ring fill.
    /// `focusedText` is the project's focused (or next open) task, for the switchers' second line.
    struct Recent: Identifiable, Equatable {
        let projectKey: String
        let name: String
        /// Project or area, so a switcher row draws the right mark. Derived from the name like
        /// everywhere else, so a Recent needs nothing stored to know.
        var kind: ProjectKind { ProjectKind.of(folderName: name) }
        let done: Int
        let total: Int
        let nextDue: String?
        let summary: String?
        let focusedText: String?
        var id: String { projectKey }
        var fraction: Double { total > 0 ? Double(done) / Double(total) : 0 }
    }

    /// A project as the folder scan finds it, before any notes are read: the identity and the parts of
    /// the folder name the sidebar groups and sorts on.
    struct ProjectListing {
        let projectKey: String
        let name: String
        let code: String
        let number: Int
        let shortName: String
        let domain: String
        let kind: ProjectKind
        let isArchived: Bool
        let modified: Date

        /// Complete this listing with the values a notes read produces (or the zeroes that stand in
        /// until one lands).
        func entry(done: Int, total: Int, nextTask: String?, nextDue: String?, detailsLoaded: Bool) -> ProjectEntry {
            ProjectEntry(name: name, projectKey: projectKey, code: code, number: number,
                         shortName: shortName, domain: domain, kind: kind, isArchived: isArchived,
                         modified: modified, done: done, total: total, nextTask: nextTask,
                         nextDue: nextDue, detailsLoaded: detailsLoaded)
        }
    }

    // MARK: Scan plumbing

    /// Background queue for the recents warm (its own protected-folder scan + per-project notes reads),
    /// kept off every store's `io` queue so it can't delay a mutation/reload.
    private let recentsQueue = DispatchQueue(label: "com.stuarthanberg.pm.recents")
    private var recentsWarmedAt: Date = .distantPast

    /// Background queue for the sidebar's full-project scan, kept off both the stores' `io` queues and
    /// `recentsQueue` so a long list of per-project notes reads can't delay a mutation or the recents warm.
    private let projectsQueue = DispatchQueue(label: "com.stuarthanberg.pm.all-projects")
    private var allProjectsWarmedAt: Date = .distantPast
    private var waitRootsWarmedAt: Date = .distantPast

    /// How many sidebars are currently showing the full project list. The scan runs only while this is
    /// above zero, so a window with its sidebar hidden costs nothing.
    private var wantsAllProjectsCount = 0
    private var wantsAllProjects: Bool { wantsAllProjectsCount > 0 }

    /// How many projects get their notes read for progress/hero text. Past this the list still shows
    /// every project, just without a ring — a guard against a pathological project folder.
    private static let maxDetailWarm = 100

    /// How many open tasks one project contributes to the search list.
    private static let maxTasksPerProject = 200

    /// One more than the eight rows a switcher shows, so a consumer can drop its own project and still
    /// have eight left.
    private static let recentsLimit = 9

    /// How long a warm is considered fresh. Keeps the frequent (watcher-driven) reloads from re-scanning.
    private static let ttl: TimeInterval = 30

    // MARK: Recents

    /// Rebuild `recents` in the background: the projects ordered by notes-file mtime (like the Raycast
    /// status command's `getRecentProjectsByEdit`) with their progress/due/summary. Derived purely from
    /// the filesystem — no shared write is needed, so recents populate even on a fresh install.
    func warmRecents(force: Bool = false) {
        if !force, Date().timeIntervalSince(recentsWarmedAt) < Self.ttl { return }
        recentsWarmedAt = Date()
        // Taken on the main actor, before the work leaves it: these rows show project names, and a
        // scan has no way to reach `waitRoots` from a background queue.
        let groups = writtenNameGroups
        let shortening = !ProjectCodes.areShown
        recentsQueue.async { [weak self] in
            guard let list = Self.recentsByEdit(limit: Self.recentsLimit) else { return }
            let warmed: [Recent] = list.map { r in
                guard let out = try? notesShow(project: r.name) else {
                    return Recent(projectKey: r.projectKey, name: r.name, done: 0, total: 0,
                                  nextDue: nil, summary: nil, focusedText: nil)
                }
                let summary = out.notes.summary.trimmingCharacters(in: .whitespacesAndNewlines)
                return Recent(projectKey: r.projectKey, name: r.name,
                              done: out.todos.filter { $0.checked }.count,
                              total: out.todos.count,
                              nextDue: Self.earliestDue(out.todos),
                              summary: summary.isEmpty ? nil : summary,
                              focusedText: Self.heroTaskText(out.todos, shorteningCodes: shortening,
                                                             in: groups))
            }
            Task { @MainActor in
                guard let self, warmed != self.recents else { return }
                self.recents = warmed
            }
        }
    }

    // MARK: Wait targets

    /// Every project folder name, grouped by scope, for resolving what a task says it's waiting on.
    ///
    /// Folder names only — no notes are read. That's what lets this be ungated where `allProjects`
    /// isn't: a task row has to draw its wait whether or not a sidebar is open, and three directory
    /// listings is a cost every reload can carry where a `notesShow` per project is not.
    @Published private(set) var waitRoots: [WaitRoot] = []

    struct WaitRoot: Equatable {
        let scope: ProjectScope
        /// The root's path — the first half of a `projectKey`, so a folder this resolves to can be
        /// opened without a second scan to find out where it lives.
        let base: String
        let folders: [String]
    }

    /// Everything an `@` mention can offer, from the same folder scan the waits resolve against — so
    /// the list you pick from and the list a target resolves in can't disagree.
    ///
    /// Built off `waitRoots` rather than `allProjects` for the reason that scan is ungated: mentions
    /// have to work in a note editor with no sidebar open, and this costs three directory listings
    /// where `allProjects` costs a notes read per project.
    var mentionCandidates: [MentionCandidate] {
        waitRoots.flatMap { root in
            root.folders.map { folder in
                let kind = ProjectKind.of(folderName: folder)
                let short = projectTitle(fromFolderName: folder)
                let code = kind.isNumbered ? String(folder.prefix(while: { $0 != " " })) : ""
                return MentionCandidate(name: folder, shortName: short, code: code,
                                        kind: kind, isArchived: root.scope.isArchived)
            }
        }
    }

    /// The folder lists a written `[[…]]` name is resolved against, in the order a name should be
    /// understood: what's in hand, then what's standing, then what's been put away.
    ///
    /// Snapshotted rather than read from inside the background scans, because `waitRoots` is main-actor
    /// state and those scans are not. Empty until the first scan lands, which is the same answer the
    /// strict lookup used to give and self-corrects on the next warm.
    var writtenNameGroups: [[String]] { waitRoots.map(\.folders) }

    /// The `projectKey` for a written name, or nil if no scanned root answers to it.
    ///
    /// **Resolved leniently, not matched exactly.** This is the lookup behind every click on a token,
    /// and it used to require the name in the file to equal a folder name character for character —
    /// while the wait on the same line was resolved by four rules including the project's code. So a
    /// row drew a renamed project's *current* title and clicking that title did nothing, and a
    /// hand-typed `[[Website Refresh]]` never navigated at all, because the folder is
    /// `W-1 Website Refresh`. One question, one answer: see `resolveWrittenName`.
    func projectKey(forFolder folder: String) -> String? {
        guard let resolved = resolveWrittenName(folder, in: writtenNameGroups) else { return nil }
        for root in waitRoots where root.folders.contains(resolved) {
            return "\(root.base):\(resolved)"
        }
        return nil
    }

    /// What a stored `[[…]]` target names now, for a surface drawing the words rather than navigating.
    func currentName(of target: String) -> String? {
        resolveWrittenName(target, in: writtenNameGroups)
    }

    /// A line of text as it reads: brackets gone, and each token showing what it names *now*.
    ///
    /// The one call every plain-text surface makes — the menubar rows, the sidebar's next-task line,
    /// the quick bar's search rows, the Waiting list. Gathered here rather than spelled out at each
    /// site so the two decisions in it, whether to show codes and whether to resolve, can't be made
    /// four different ways.
    func displayText(_ text: String) -> String {
        Self.displayText(text, shorteningCodes: !ProjectCodes.areShown, in: writtenNameGroups)
    }

    /// The same, for a background scan holding a snapshot of the folder groups.
    nonisolated static func displayText(_ text: String, shorteningCodes: Bool,
                                        in groups: [[String]]) -> String {
        displayingWikilinks(text, shorteningCodes: shorteningCodes,
                            resolving: { resolveWrittenName($0, in: groups) })
    }

    /// Rebuild `waitRoots`. Shares the recents TTL, so the watcher-driven reloads don't re-list the
    /// folders on every keystroke.
    func warmWaitRoots(force: Bool = false) {
        if !force, Date().timeIntervalSince(waitRootsWarmedAt) < Self.ttl { return }
        waitRootsWarmedAt = Date()
        recentsQueue.async { [weak self] in
            guard let roots = Self.scanWaitRoots() else { return }
            Task { @MainActor in
                guard let self, roots != self.waitRoots else { return }
                self.waitRoots = roots
            }
        }
    }

    private nonisolated static func scanWaitRoots() -> [WaitRoot]? {
        guard let (config, paths) = try? loadConfigAndPaths() else { return nil }
        let codes = Array(config.domains.keys)
        return ProjectScope.allCases.map { scope in
            let base = scope.path(in: paths)
            return WaitRoot(scope: scope, base: base,
                            folders: (try? getFolders(basePath: base, scope: scope,
                                                      domainCodes: codes)) ?? [])
        }
    }

    // MARK: All projects (the project sidebar)

    /// Register a sidebar as wanting the full project list; the last one to `release` stops the scans.
    /// The list is kept when the count drops to zero, so re-showing a sidebar paints the previous rows
    /// while any fresh scan runs rather than flashing empty.
    ///
    /// The first holder only bypasses the TTL when there's nothing to show. Forcing it unconditionally
    /// meant every ⌥⌘S kicked off a full scan of both project folders plus a `notesShow` per project —
    /// work whose results are, within the TTL, identical to what's already on screen, and which lands
    /// mid-collapse if you toggle the sidebar twice in quick succession.
    func retain() {
        wantsAllProjectsCount += 1
        if wantsAllProjectsCount == 1 { warmAllProjects(force: allProjects.isEmpty) }
    }

    func release() {
        wantsAllProjectsCount = max(0, wantsAllProjectsCount - 1)
    }

    /// Rebuild `allProjects` in the background: every project in both folders, newest-edited first, with
    /// progress, next task and next due. Two-stage so a long list paints immediately — the names land
    /// first, then the same rows again with their notes-derived detail. A project switch forces a fresh
    /// pass (it reorders the list and moves the sidebar's selection).
    ///
    /// The list is published in one order (recency); which projects show, how they're grouped and how
    /// they're sorted is the sidebar's business, so changing those settings never costs a re-scan.
    func warmAllProjects(force: Bool = false) {
        guard wantsAllProjects else { return }
        if !force, Date().timeIntervalSince(allProjectsWarmedAt) < Self.ttl { return }
        allProjectsWarmedAt = Date()
        let groups = writtenNameGroups
        let shortening = !ProjectCodes.areShown
        projectsQueue.async { [weak self] in
            guard let listing = Self.allProjectsByEdit() else { return }
            Task { @MainActor in self?.seedAllProjects(listing) }
            var warmed: [ProjectEntry] = []
            var tasks: [TaskEntry] = []
            for (index, item) in listing.enumerated() {
                guard index < Self.maxDetailWarm, let out = try? notesShow(project: item.name) else {
                    warmed.append(item.entry(done: 0, total: 0, nextTask: nil, nextDue: nil,
                                             detailsLoaded: false))
                    continue
                }
                warmed.append(item.entry(done: out.todos.filter { $0.checked }.count,
                                         total: out.todos.count,
                                         nextTask: Self.heroTaskText(out.todos,
                                                                     shorteningCodes: shortening,
                                                                     in: groups),
                                         nextDue: Self.earliestDue(out.todos),
                                         detailsLoaded: true))
                tasks += Self.openTasks(of: out.todos, in: item, shorteningCodes: shortening,
                                        resolvingIn: groups)
            }
            let collected = tasks
            Task { @MainActor in
                guard let self else { return }
                if warmed != self.allProjects { self.allProjects = warmed }
                if collected != self.openTasks { self.openTasks = collected }
            }
        }
    }

    /// Paint the freshly-scanned membership/order right away, reusing any detail already warmed for a
    /// project so rings don't blink off on a re-scan. New projects come in name-only until the detail
    /// pass lands.
    private func seedAllProjects(_ listing: [ProjectListing]) {
        let known = Dictionary(allProjects.map { ($0.projectKey, $0) }, uniquingKeysWith: { a, _ in a })
        let seeded = listing.map { item -> ProjectEntry in
            if let cached = known[item.projectKey], cached.isArchived == item.isArchived { return cached }
            return item.entry(done: 0, total: 0, nextTask: nil, nextDue: nil, detailsLoaded: false)
        }
        if seeded != allProjects { allProjects = seeded }
    }

    // MARK: Filesystem scans (off-main only)

    /// Every project in the active and archive folders, ordered by notes-file mtime (newest first,
    /// falling back to folder mtime) across both. Does protected-folder IO, so only ever call this off
    /// the main thread.
    private nonisolated static func allProjectsByEdit() -> [ProjectListing]? {
        guard let (config, paths) = try? loadConfigAndPaths() else { return nil }
        let codes = Array(config.domains.keys)
        var result: [ProjectListing] = []
        for scope in ProjectScope.allCases {
            let base = scope.path(in: paths)
            guard let folders = try? getFolders(basePath: base, scope: scope, domainCodes: codes) else { continue }
            result += folders.map { name in
                let projectPath = (base as NSString).appendingPathComponent(name)
                let notesPath = (try? resolveNotesPath(projectPath: projectPath)) ?? nil
                let attrs = try? FileManager.default.attributesOfItem(atPath: notesPath ?? projectPath)
                let parts = nameParts(name, domains: config.domains)
                return ProjectListing(projectKey: "\(base):\(name)", name: name,
                                      code: parts.code, number: parts.number, shortName: parts.shortName,
                                      domain: parts.domain, kind: ProjectKind.of(folderName: name),
                                      isArchived: scope.isArchived,
                                      modified: (attrs?[.modificationDate] as? Date) ?? .distantPast)
            }
        }
        return result.sorted { $0.modified > $1.modified }
    }

    /// Split a project folder name ("H-004 Maxwell Carmody") into its domain code, sequence number and
    /// display name, and look the code up in the configured domains ("Home"). The scan only ever hands
    /// us names that matched `getProjectFolders`' pattern, so the fallbacks are belt-and-braces: an
    /// unparseable name keeps its whole self as the display name and groups under "Other".
    private nonisolated static func nameParts(
        _ name: String, domains: [String: String]
    ) -> (code: String, number: Int, shortName: String, domain: String) {
        // An area's name has no parts: no code, no number, and the whole thing is what it's called.
        // It groups under "Areas" so a domain-grouped list has somewhere to put it, though the sidebar
        // gives them a section of their own and never asks.
        let kind = ProjectKind.of(folderName: name)
        guard kind.isNumbered else { return ("", 0, name, kind.pluralDisplayName) }
        guard let dash = name.firstIndex(of: "-"),
              let space = name[dash...].firstIndex(of: " ") else {
            return ("", 0, name, "Other")
        }
        let code = String(name[name.startIndex..<dash])
        let number = Int(name[name.index(after: dash)..<space]) ?? 0
        let shortName = String(name[name.index(after: space)...])
            .trimmingCharacters(in: .whitespaces)
        return (code, number, shortName.isEmpty ? name : shortName, domains[code] ?? code)
    }

    /// All projects across the active + archive folders, ordered by notes-file mtime (newest first,
    /// falling back to folder mtime), capped at `limit`. Does protected-folder IO, so only ever call
    /// this off the main thread.
    private nonisolated static func recentsByEdit(limit: Int) -> [PMFiles.RecentProject]? {
        guard let (config, paths) = try? loadConfigAndPaths() else { return nil }
        let codes = Array(config.domains.keys)
        var entries: [(project: PMFiles.RecentProject, mtime: Date)] = []
        for scope in ProjectScope.allCases {
            let base = scope.path(in: paths)
            guard let folders = try? getFolders(basePath: base, scope: scope, domainCodes: codes) else { continue }
            for name in folders {
                let key = "\(base):\(name)"
                let projectPath = (base as NSString).appendingPathComponent(name)
                let notesPath = (try? resolveNotesPath(projectPath: projectPath)) ?? nil
                let attrs = try? FileManager.default.attributesOfItem(atPath: notesPath ?? projectPath)
                let mtime = (attrs?[.modificationDate] as? Date) ?? .distantPast
                entries.append((PMFiles.RecentProject(projectKey: key, name: name), mtime))
            }
        }
        return entries.sorted { $0.mtime > $1.mtime }.prefix(limit).map(\.project)
    }

    /// A recent project's "current task" — its focused task, else its first open one — for the
    /// switchers' second line. Mirrors the menubar button's `focusedTodo ?? openTodos.first`, and is
    /// nil when everything is done.
    private nonisolated static func heroTaskText(_ todos: [Todo], shorteningCodes: Bool,
                                                 in groups: [[String]]) -> String? {
        let text = todos.heroTask
            .map { displayText($0.text, shorteningCodes: shorteningCodes, in: groups) }?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (text?.isEmpty ?? true) ? nil : text
    }

    /// The open tasks of one project, as search rows.
    ///
    /// Capped per project for the same reason `maxDetailWarm` caps the scan: one pathological notes
    /// file shouldn't be able to make the search list unbounded. Past the cap the project's remaining
    /// tasks aren't searchable, which is a much smaller failure than the alternative.
    private nonisolated static func openTasks(of todos: [Todo], in item: ProjectListing,
                                             shorteningCodes: Bool,
                                             resolvingIn groups: [[String]]) -> [TaskEntry] {
        todos.lazy
            .filter { !$0.checked && !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
            .prefix(maxTasksPerProject)
            .map { todo in
                TaskEntry(projectKey: item.projectKey, projectName: item.name,
                          projectShortName: item.shortName, isArchived: item.isArchived,
                          // The name, not the markup, and the name it goes by now: this text is both
                          // searched and shown, and nobody looks for a task by the brackets in it or
                          // by what a project used to be called.
                          text: displayText(todo.text, shorteningCodes: shorteningCodes, in: groups)
                              .trimmingCharacters(in: .whitespacesAndNewlines),
                          due: todo.dueDate ?? todo.effectiveDueDate, isFocused: todo.isFocused,
                          sessionIndex: todo.sessionIndex, lineIndex: todo.lineIndex)
            }
    }

    /// Earliest due (own or inherited) among open todos, for the recent-project "next due" hint.
    private nonisolated static func earliestDue(_ todos: [Todo]) -> String? {
        todos.filter { !$0.checked }
            .compactMap { $0.dueDate ?? $0.effectiveDueDate }
            .min { (RelativeDue.parse($0) ?? .distantFuture) < (RelativeDue.parse($1) ?? .distantFuture) }
    }
}
