import Foundation
import Combine
import AppKit
import PmLib

/// A classified change of the focused ("hero") task between two loads, used to drive directional
/// animations in the panel's focused card and the menubar button so the movement reads spatially.
/// Directions follow the outline geometry, so most moves are diagonal rather than cardinal: diving
/// into a narrower subtask travels down-and-right (the child is both deeper and lower), a completion
/// bubbling up to an ancestor travels up-and-left, while advancing to / stepping back from a
/// same-level sibling stays vertical (down / up). A plain in-place text edit wipes rather than moving.
enum FocusMove: Equatable {
    case none    // no meaningful change (first load, project switch, or an unrelated reload)
    case wipe    // same task, its text was edited in place
    case up      // moved to an earlier task at the same level (previous) → up
    case down    // moved to a later task at the same level (next) → down
    case left    // focus rose to a shallower / ancestor task → up-left
    case right   // focus dove into a deeper / narrower task → down-right
}

/// Single source of truth for the focused project, shared by the menubar item and the panel.
///
/// Calls `PmLib` directly (no `pm` subprocess, no Rust bridge). All notes IO runs on a serial
/// background queue so concurrent mutations can't interleave writes; published state is updated on
/// the main actor. `reload()` re-reads `focused.json` and `pm notes show` for the focused project;
/// mutations perform their `NotesService` call and then reload.
@MainActor
final class PMStore: ObservableObject {
    @Published private(set) var projectKey: String?
    @Published private(set) var projectName: String?
    /// Resolved project folder path, captured during reload (for Open in Finder etc.).
    @Published private(set) var projectPath: String?
    /// Resolved path to the focused project's notes file, captured during reload so the app can watch
    /// it without re-scanning the (protected) project directory on every UI update.
    @Published private(set) var notesPath: String?
    @Published private(set) var notes: ProjectNotes?
    @Published private(set) var todos: [Todo] = []
    @Published private(set) var focusedKey: String?
    @Published private(set) var errorMessage: String?
    /// True once the first successful load has painted; used to keep the last-good render across
    /// transient (cloud-sync) read failures instead of flashing to empty.
    @Published private(set) var hasLoaded = false

    /// The most recent classified change of the focused task, paired with a monotonic token. Observers
    /// (the focused card, the menubar button) animate whenever the token advances, reading `focusMove`
    /// for the direction; a token that doesn't advance means nothing worth animating changed. The token
    /// — not `focusMove` alone — is the trigger, so two successive moves in the same direction still
    /// fire.
    @Published private(set) var focusMove: FocusMove = .none
    @Published private(set) var focusMoveToken: Int = 0

    /// Snapshot of the hero task from the last load, compared against the next load to classify the
    /// movement. Identity (`key`), `text`, `depth`, and document position (`session`/`line`) are all it
    /// takes to tell an edit from a dive-in / bubble-up / next / previous.
    private struct HeroSnapshot { let key: String; let text: String; let depth: Int; let session: Int; let line: Int }
    private var heroSnapshot: HeroSnapshot?

    /// Recent projects for the menubar's and panel's quick-switchers, ordered by notes-file mtime with
    /// the focused project excluded, each carrying cached progress/due/summary so a switcher can render
    /// rings + hints without protected-folder reads while it's being built. Warmed off-thread from
    /// `reload()`, shared so the two switchers can't diverge.
    @Published private(set) var recents: [Recent] = []

    /// Every project in the active and archive folders, newest-edited first within each group, each
    /// carrying cached progress + hero task for the panel's optional project sidebar. Unlike `recents`
    /// this keeps the focused project and isn't truncated, so its (much larger) scan is gated on
    /// `wantsAllProjects` — nothing pays for it while the sidebar is hidden.
    @Published private(set) var allProjects: [ProjectEntry] = []

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
        /// The code's configured domain label ("Home"), falling back to the bare code.
        let domain: String
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
    }

    /// A recent project plus its cached completion/due/summary. `fraction` is the ring fill.
    /// `focusedText` is the project's focused (or next open) task, for the switchers' second line.
    struct Recent: Identifiable, Equatable {
        let projectKey: String
        let name: String
        let done: Int
        let total: Int
        let nextDue: String?
        let summary: String?
        let focusedText: String?
        var id: String { projectKey }
        var fraction: Double { total > 0 ? Double(done) / Double(total) : 0 }
    }

    /// A whole-document snapshot for undo/redo — the notes path plus its exact raw bytes at a point in
    /// time. Restoring one writes the bytes back verbatim, so undo is format-preserving like every edit.
    struct DocSnapshot: Equatable { let notesPath: String; let raw: String }

    /// Undo/redo history of pre-mutation document snapshots, for panel-initiated edits (move, complete,
    /// due, text, add, wrap, unwrap…). Coarse but reliable: each step restores the full prior document.
    /// Published so the menu/keyboard affordances can reflect availability; cleared on a project switch.
    @Published private(set) var undoStack: [DocSnapshot] = []
    @Published private(set) var redoStack: [DocSnapshot] = []
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    /// Cap the history so a long session can't grow it without bound.
    private let maxHistory = 100

    /// Serial queue for all `PmLib` notes IO (reads and writes) — prevents interleaved writes.
    private let io = DispatchQueue(label: "com.stuarthanberg.pm.notes-io")

    /// Background queue for the recents warm (its own protected-folder scan + per-project notes reads),
    /// kept off `io` so it can't delay a focused-project mutation/reload.
    private let recentsQueue = DispatchQueue(label: "com.stuarthanberg.pm.recents")
    private var recentsWarmedAt: Date = .distantPast
    private var recentsWarmedForKey: String?

    /// Background queue for the sidebar's full-project scan, kept off both `io` and `recentsQueue` so a
    /// long list of per-project notes reads can't delay a mutation or the recents warm.
    private let projectsQueue = DispatchQueue(label: "com.stuarthanberg.pm.all-projects")
    private var allProjectsWarmedAt: Date = .distantPast
    /// Whether any UI is currently showing the full project list (see `setWantsAllProjects`).
    private var wantsAllProjects = false
    /// How many projects get their notes read for progress/hero text. Past this the list still shows
    /// every project, just without a ring — a guard against a pathological project folder.
    private static let maxDetailWarm = 100

    // MARK: Derived state for the UI

    /// The currently focused todo, if any.
    var focusedTodo: Todo? { todos.first { $0.isFocused } }

    /// Open (unchecked) todos in document order.
    var openTodos: [Todo] { todos.filter { !$0.checked } }

    /// Completion progress as (done, total). Total counts all parsed todos.
    var progress: (done: Int, total: Int) {
        let total = todos.count
        let done = todos.filter { $0.checked }.count
        return (done, total)
    }

    /// A stable key for a todo, matching `focusedKey` format ("sessionIndex:lineIndex").
    static func key(for todo: Todo) -> String { "\(todo.sessionIndex):\(todo.lineIndex)" }

    /// The hero task a load presents — the focused todo, else the first open one — reduced to the
    /// fields needed to classify how it moved. Mirrors the panel's `focusedHero`.
    private func makeHeroSnapshot(_ todos: [Todo]) -> HeroSnapshot? {
        guard let h = todos.first(where: { $0.isFocused }) ?? todos.first(where: { !$0.checked }) else { return nil }
        return HeroSnapshot(key: Self.key(for: h), text: h.text, depth: h.depth,
                            session: h.sessionIndex, line: h.lineIndex)
    }

    /// Classify the movement from one hero snapshot to the next. Depth wins first (a change of level is
    /// a dive-in or bubble-up regardless of order); at the same level, document position decides
    /// next vs previous. Same task with new text is a wipe; anything else (first load, nothing focused)
    /// is `.none`.
    private func classifyHeroMove(from old: HeroSnapshot?, to new: HeroSnapshot?) -> FocusMove {
        guard let new, let old else { return .none }
        if old.key == new.key { return old.text == new.text ? .none : .wipe }
        if new.depth > old.depth { return .right }
        if new.depth < old.depth { return .left }
        return (new.session, new.line) > (old.session, old.line) ? .down : .up
    }

    // MARK: Loading

    /// Re-read the focused project and its notes. Safe to call frequently (e.g. from the watcher).
    func reload() {
        let key = PMFiles.focusedProjectKey()
        guard let key, let name = PMFiles.projectName(fromKey: key) else {
            projectKey = nil
            projectName = nil
            projectPath = nil
            notesPath = nil
            notes = nil
            todos = []
            focusedKey = nil
            heroSnapshot = nil   // no project → nothing to animate from next time
            undoStack = []; redoStack = []   // history belongs to a project
            errorMessage = key == nil ? nil : "Invalid focused project."
            hasLoaded = true
            warmRecents()
            warmAllProjects()
            return
        }
        io.async { [weak self] in
            // Resolve the project directory once (this is the protected-folder access), then reuse
            // the handle for both the notes read and the cached notes path.
            Log.write("reload start: name=\(name)")
            let result = Result { () -> (NotesShowOutput, String, String) in
                let cfg = try? loadConfig()
                Log.write("config: useObsidianCLI=\(cfg?.useObsidianCLI ?? false)")
                let handle = try resolveNotesHandle(project: name)
                Log.write("resolved: notesPath=\(handle.notesPath) io=\(type(of: handle.io))")
                let output = try notesShow(handle: handle)
                Log.write("notesShow ok: todos=\(output.todos.count)")
                return (output, handle.notesPath, handle.projectPath)
            }
            if case .failure(let error) = result {
                let ns = error as NSError
                Log.write("reload FAILED: \(error) [domain=\(ns.domain) code=\(ns.code)]")
            }
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success(let (output, path, projectPath)):
                    // Classify how the hero task moved since the last load, but never animate across a
                    // project switch (the two heroes are unrelated) — just reseat the snapshot.
                    let projectChanged = self.projectKey != key
                    if projectChanged { self.undoStack.removeAll(); self.redoStack.removeAll() }
                    self.projectKey = key
                    self.projectName = name
                    self.notesPath = path
                    self.projectPath = projectPath
                    self.notes = output.notes
                    self.todos = output.todos
                    self.focusedKey = output.focusedKey
                    self.errorMessage = nil
                    self.hasLoaded = true
                    let newHero = self.makeHeroSnapshot(output.todos)
                    if !projectChanged {
                        let move = self.classifyHeroMove(from: self.heroSnapshot, to: newHero)
                        if move != .none {
                            self.focusMove = move
                            self.focusMoveToken += 1
                        }
                    }
                    self.heroSnapshot = newHero
                    self.warmRecents()
                    // A switch reorders the sidebar (the new project jumps to the top of its group) and
                    // moves the selection, so re-scan straight away rather than waiting out the TTL.
                    self.warmAllProjects(force: projectChanged)
                case .failure(let error):
                    // Keep the last-good render on transient failures; only surface the error text.
                    self.errorMessage = String(describing: error)
                    self.hasLoaded = true
                }
            }
        }
    }

    /// Switch the focused project (updates focused.json + recent list) and reload.
    func setFocusedProject(key: String) {
        guard let name = PMFiles.projectName(fromKey: key) else { return }
        io.async { [weak self] in
            try? PMFiles.setFocusedProjectKey(key)
            PMFiles.recordRecent(projectKey: key, name: name)
            Task { @MainActor in self?.reload() }
        }
    }

    // MARK: Recents (shared by both switchers)

    /// Rebuild `recents` in the background: the projects ordered by notes-file mtime (like the Raycast
    /// status command's `getRecentProjectsByEdit`) with their progress/due/summary. Derived purely from
    /// the filesystem — no shared write is needed, so recents populate even on a fresh install. A 30s
    /// TTL keyed on the focused project keeps the frequent (watcher-driven) reloads from re-scanning,
    /// while a project switch re-warms immediately (the key changed).
    private func warmRecents() {
        let excludeKey = projectKey
        if recentsWarmedForKey == excludeKey, Date().timeIntervalSince(recentsWarmedAt) < 30 { return }
        recentsWarmedAt = Date()
        recentsWarmedForKey = excludeKey
        recentsQueue.async { [weak self] in
            guard let list = Self.recentsByEdit(excludeKey: excludeKey, limit: 8) else { return }
            let warmed: [Recent] = list.map { r in
                guard let out = try? notesShow(project: r.name) else {
                    return Recent(projectKey: r.projectKey, name: r.name, done: 0, total: 0, nextDue: nil, summary: nil, focusedText: nil)
                }
                let summary = out.notes.summary.trimmingCharacters(in: .whitespacesAndNewlines)
                return Recent(projectKey: r.projectKey, name: r.name,
                              done: out.todos.filter { $0.checked }.count,
                              total: out.todos.count,
                              nextDue: Self.earliestDue(out.todos),
                              summary: summary.isEmpty ? nil : summary,
                              focusedText: Self.heroTaskText(out.todos))
            }
            Task { @MainActor in
                guard let self, warmed != self.recents else { return }
                self.recents = warmed
            }
        }
    }

    // MARK: All projects (the panel's optional sidebar)

    /// Turn the full-project scan on or off. The sidebar calls this as it appears/disappears, so a
    /// hidden sidebar costs nothing; turning it on warms immediately (bypassing the TTL). The last
    /// list is kept when it's turned off, so re-showing paints the previous rows while the fresh scan
    /// runs rather than flashing empty.
    func setWantsAllProjects(_ on: Bool) {
        guard wantsAllProjects != on else { return }
        wantsAllProjects = on
        if on { warmAllProjects(force: true) }
    }

    /// Rebuild `allProjects` in the background: every project in both folders, newest-edited first, with
    /// progress, next task and next due. Two-stage so a long list paints immediately — the names land
    /// first, then the same rows again with their notes-derived detail. A 30s TTL keeps the frequent
    /// (watcher-driven) reloads from re-scanning; a project switch forces a fresh pass.
    ///
    /// The list is published in one order (recency); which projects show, how they're grouped and how
    /// they're sorted is the sidebar's business, so changing those settings never costs a re-scan.
    private func warmAllProjects(force: Bool = false) {
        guard wantsAllProjects else { return }
        if !force, Date().timeIntervalSince(allProjectsWarmedAt) < 30 { return }
        allProjectsWarmedAt = Date()
        projectsQueue.async { [weak self] in
            guard let listing = Self.allProjectsByEdit() else { return }
            Task { @MainActor in self?.seedAllProjects(listing) }
            let warmed: [ProjectEntry] = listing.enumerated().map { index, item in
                guard index < Self.maxDetailWarm, let out = try? notesShow(project: item.name) else {
                    return item.entry(done: 0, total: 0, nextTask: nil, nextDue: nil, detailsLoaded: false)
                }
                return item.entry(done: out.todos.filter { $0.checked }.count,
                                  total: out.todos.count,
                                  nextTask: Self.heroTaskText(out.todos),
                                  nextDue: Self.earliestDue(out.todos),
                                  detailsLoaded: true)
            }
            Task { @MainActor in
                guard let self, warmed != self.allProjects else { return }
                self.allProjects = warmed
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

    /// A project as the folder scan finds it, before any notes are read: the identity and the parts of
    /// the folder name the sidebar groups and sorts on.
    struct ProjectListing {
        let projectKey: String
        let name: String
        let code: String
        let number: Int
        let shortName: String
        let domain: String
        let isArchived: Bool
        let modified: Date

        /// Complete this listing with the values a notes read produces (or the zeroes that stand in
        /// until one lands).
        func entry(done: Int, total: Int, nextTask: String?, nextDue: String?, detailsLoaded: Bool) -> ProjectEntry {
            ProjectEntry(name: name, projectKey: projectKey, code: code, number: number,
                         shortName: shortName, domain: domain, isArchived: isArchived, modified: modified,
                         done: done, total: total, nextTask: nextTask, nextDue: nextDue,
                         detailsLoaded: detailsLoaded)
        }
    }

    /// Every project in the active and archive folders, ordered by notes-file mtime (newest first,
    /// falling back to folder mtime) across both. Does protected-folder IO, so only ever call this off
    /// the main thread.
    private nonisolated static func allProjectsByEdit() -> [ProjectListing]? {
        guard let (config, paths) = try? loadConfigAndPaths() else { return nil }
        let codes = Array(config.domains.keys)
        var result: [ProjectListing] = []
        for base in [paths.activePath, paths.archivePath] {
            let isArchived = base == paths.archivePath
            guard let folders = try? getProjectFolders(basePath: base, domainCodes: codes) else { continue }
            result += folders.map { name in
                let projectPath = (base as NSString).appendingPathComponent(name)
                let notesPath = (try? resolveNotesPath(projectPath: projectPath)) ?? nil
                let attrs = try? FileManager.default.attributesOfItem(atPath: notesPath ?? projectPath)
                let parts = nameParts(name, domains: config.domains)
                return ProjectListing(projectKey: "\(base):\(name)", name: name,
                                      code: parts.code, number: parts.number, shortName: parts.shortName,
                                      domain: parts.domain, isArchived: isArchived,
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
    /// falling back to folder mtime), excluding the focused project, capped at `limit`. Does protected-
    /// folder IO, so only ever call this off the main thread.
    private nonisolated static func recentsByEdit(excludeKey: String?, limit: Int) -> [PMFiles.RecentProject]? {
        guard let (config, paths) = try? loadConfigAndPaths() else { return nil }
        let codes = Array(config.domains.keys)
        var entries: [(project: PMFiles.RecentProject, mtime: Date)] = []
        for base in [paths.activePath, paths.archivePath] {
            guard let folders = try? getProjectFolders(basePath: base, domainCodes: codes) else { continue }
            for name in folders {
                let key = "\(base):\(name)"
                if key == excludeKey { continue }
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
    private nonisolated static func heroTaskText(_ todos: [Todo]) -> String? {
        let hero = todos.first { $0.isFocused } ?? todos.first { !$0.checked }
        let text = hero?.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return (text?.isEmpty ?? true) ? nil : text
    }

    /// Earliest due (own or inherited) among open todos, for the recent-project "next due" hint.
    private nonisolated static func earliestDue(_ todos: [Todo]) -> String? {
        todos.filter { !$0.checked }
            .compactMap { $0.dueDate ?? $0.effectiveDueDate }
            .min { (RelativeDue.parse($0) ?? .distantFuture) < (RelativeDue.parse($1) ?? .distantFuture) }
    }

    // MARK: Mutations (each performs the NotesService call, then reloads)

    /// Run a document mutation off-main, then reload. When `recordsUndo` (the default), the pre-edit
    /// document is banked for undo if the edit actually changed bytes. Navigation-only writes (focus)
    /// pass `recordsUndo: false` so ⌘Z reverts real edits, not selection changes.
    private func mutate(recordsUndo: Bool = true, _ work: @escaping (String) throws -> Void) {
        guard let name = projectName else { return }
        io.async { [weak self] in
            let before = recordsUndo ? try? Self.snapshot(project: name) : nil
            do {
                try work(name)
            } catch {
                Task { @MainActor in self?.errorMessage = String(describing: error) }
            }
            // Only record when the edit actually changed the bytes (skips no-op mutations).
            if let before, let after = try? Self.snapshot(project: name), before.raw != after.raw {
                Task { @MainActor in self?.recordUndo(before) }
            }
            Task { @MainActor in self?.reload() }
        }
    }

    /// Read the current raw document for `project` as a snapshot. Protected-folder IO — off-main only.
    private nonisolated static func snapshot(project: String) throws -> DocSnapshot {
        let handle = try resolveNotesHandle(project: project)
        return DocSnapshot(notesPath: handle.notesPath, raw: try handle.io.readContent(path: handle.notesPath))
    }

    /// Push a pre-edit snapshot onto the undo stack (capped), invalidating any pending redo.
    private func recordUndo(_ snap: DocSnapshot) {
        undoStack.append(snap)
        if undoStack.count > maxHistory { undoStack.removeFirst(undoStack.count - maxHistory) }
        redoStack.removeAll()
    }

    /// Restore the most recent pre-edit document, banking the current one for redo. No-op when empty.
    func undo() { restore(from: \.undoStack, to: \.redoStack) }

    /// Re-apply the most recently undone document, banking the current one for undo. No-op when empty.
    func redo() { restore(from: \.redoStack, to: \.undoStack) }

    /// Shared undo/redo primitive: pop a snapshot off `source`, write it to disk, and bank the pre-write
    /// document onto `dest` so the move is reversible. Reload paints the restored state.
    private func restore(from source: ReferenceWritableKeyPath<PMStore, [DocSnapshot]>,
                         to dest: ReferenceWritableKeyPath<PMStore, [DocSnapshot]>) {
        guard let name = projectName, let target = self[keyPath: source].last else { return }
        io.async { [weak self] in
            let current = try? Self.snapshot(project: name)
            do {
                let handle = try resolveNotesHandle(project: name)
                try handle.io.writeContent(path: handle.notesPath, content: target.raw)
            } catch {
                Task { @MainActor in self?.errorMessage = String(describing: error) }
                return
            }
            Task { @MainActor in
                guard let self else { return }
                if !self[keyPath: source].isEmpty { self[keyPath: source].removeLast() }
                if let current { self[keyPath: dest].append(current) }
                self.reload()
            }
        }
    }

    /// Key of the most recently completed task this session, for the menubar's ⌥ Undo alternate.
    @Published private(set) var lastCompletedKey: String?

    func complete(_ todo: Todo, advanceFocus: Bool = true) {
        lastCompletedKey = Self.key(for: todo)
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        mutate { try completeTodo(project: $0, sessionIndex: todo.sessionIndex, lineIndex: todo.lineIndex, advanceFocus: advanceFocus) }
    }

    /// Undo the most recent completion (re-open it and move focus back onto it).
    func undoLast() {
        guard let key = lastCompletedKey else { return }
        let parts = key.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return }
        lastCompletedKey = nil
        mutate { try undoTodo(project: $0, sessionIndex: parts[0], lineIndex: parts[1]) }
    }

    func toggle(_ todo: Todo) {
        if todo.checked {
            undo(todo)
        } else {
            complete(todo, advanceFocus: true)
        }
    }

    func focus(_ todo: Todo) {
        // Focus is navigation, not a content edit, so keep it out of the undo history.
        mutate(recordsUndo: false) { try focusTodo(project: $0, sessionIndex: todo.sessionIndex, lineIndex: todo.lineIndex) }
    }

    func undo(_ todo: Todo) {
        mutate { try undoTodo(project: $0, sessionIndex: todo.sessionIndex, lineIndex: todo.lineIndex) }
    }

    func setDue(_ todo: Todo, due: String?) {
        mutate { try setDueOnTodo(project: $0, sessionIndex: todo.sessionIndex, lineIndex: todo.lineIndex, due: due) }
    }

    /// Replace a task's text in place (checkbox, due, focus, and indent preserved).
    func editText(_ todo: Todo, text: String) {
        mutate { try setTodoText(project: $0, sessionIndex: todo.sessionIndex, lineIndex: todo.lineIndex, text: text) }
    }

    /// Wrap a task in a new parent task, nesting the task (and its subtree) under it; focus stays put.
    func wrap(_ todo: Todo, parentText: String) {
        mutate { try wrapTodo(project: $0, sessionIndex: todo.sessionIndex, lineIndex: todo.lineIndex, text: parentText) }
    }

    /// Dissolve a parent task: remove it and promote its children (with their subtrees) into its
    /// place. If the dissolved parent held focus, focus moves to its first child. Only meaningful for
    /// tasks with children — `hasChildren(_:)` gates the UI affordance. Inverse of `wrap`.
    func unwrap(_ todo: Todo) {
        mutate { try unwrapTodo(project: $0, sessionIndex: todo.sessionIndex, lineIndex: todo.lineIndex) }
    }

    /// Move `todo` (and its whole subtree) to a precise slot — after/before the `anchor` todo's line,
    /// with the subtree's root re-indented to `depth`. Drives the panel's drag-to-reorder: the drop's
    /// Y resolves the anchor + side, its X the depth. Illegal drops (anchor inside the moved subtree)
    /// are rejected by the backend; the drop handler avoids offering them.
    func moveSubtree(_ todo: Todo, anchor: Todo, insertAfter: Bool, depth: Int) {
        mutate {
            try PmLib.moveSubtree(project: $0,
                                  sourceSessionIndex: todo.sessionIndex, sourceLineIndex: todo.lineIndex,
                                  anchorSessionIndex: anchor.sessionIndex, anchorLineIndex: anchor.lineIndex,
                                  insertAfterAnchor: insertAfter, depth: depth)
        }
    }

    // MARK: Selection-wide operations
    //
    // The panel's task list supports multi-selection, so these take a set of tasks and perform the
    // whole batch inside ONE `mutate` — a single pre-edit snapshot is banked, so ⌘Z reverses the
    // entire action rather than unwinding it task by task.

    /// The outermost tasks among `todos`, in document order: any task that already sits inside
    /// another's subtree is dropped, since an operation on the ancestor covers it. Keeps a batch from
    /// acting on the same line twice (which, for delete, would consume a stale index).
    func outermost(_ todos: [Todo]) -> [Todo] {
        var covered: Set<String> = []
        for todo in todos {
            let key = Self.key(for: todo)
            for descendant in subtreeKeys(of: todo) where descendant != key { covered.insert(descendant) }
        }
        return todos
            .filter { !covered.contains(Self.key(for: $0)) }
            .sorted { ($0.sessionIndex, $0.lineIndex) < ($1.sessionIndex, $1.lineIndex) }
    }

    /// The subtree rooted at `todo` in document order — the task plus the contiguous run of deeper
    /// todos right after it. The list form of `subtreeKeys(of:)`.
    func subtree(of todo: Todo) -> [Todo] {
        guard let idx = todos.firstIndex(where: {
            $0.sessionIndex == todo.sessionIndex && $0.lineIndex == todo.lineIndex
        }) else { return [] }
        var out = [todos[idx]]
        var j = idx + 1
        while j < todos.count, todos[j].depth > todos[idx].depth {
            out.append(todos[j])
            j += 1
        }
        return out
    }

    /// What deleting `todos` would remove: the tasks actually picked (after collapsing any that are
    /// already inside another's subtree) and the extra descendants that ride along. The panel's
    /// confirmation names both, so a delete never silently takes more than it showed.
    func deletionSummary(_ todos: [Todo]) -> (tasks: Int, descendants: Int) {
        let roots = outermost(todos)
        let all = roots.reduce(into: Set<String>()) { $0.formUnion(subtreeKeys(of: $1)) }
        return (roots.count, max(0, all.count - roots.count))
    }

    /// Delete `todos` and their subtrees in one document edit (one undo step).
    ///
    /// Deletion is the one batch where order matters: removing a task shifts the line indices of
    /// everything after it in the same session, so the roots are deleted *bottom-up* and every
    /// remaining target's index stays valid.
    func deleteTasks(_ todos: [Todo]) {
        let roots = outermost(todos)
        guard !roots.isEmpty else { return }
        let bottomUp = roots.sorted { ($0.sessionIndex, $0.lineIndex) > ($1.sessionIndex, $1.lineIndex) }
        mutate { project in
            for todo in bottomUp {
                try PmLib.deleteTodo(project: project,
                                     sessionIndex: todo.sessionIndex, lineIndex: todo.lineIndex)
            }
        }
    }

    /// Complete every open task in `todos`, or — when they're all complete already — reopen them all.
    /// Mirrors how a Mac checkbox batch behaves on a mixed selection: the majority action is "finish
    /// what's left". Completion is in place, so no index shifting to worry about.
    func toggleAll(_ todos: [Todo]) {
        guard !todos.isEmpty else { return }
        let open = todos.filter { !$0.checked }
        let targets = open.isEmpty ? todos : open
        let completing = !open.isEmpty
        if completing {
            lastCompletedKey = targets.last.map(Self.key(for:))
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        }
        mutate { project in
            for todo in targets {
                if completing {
                    // `advanceFocus: false` — a batch shouldn't march focus once per task. The backend
                    // still moves focus if one of the completed tasks was holding it.
                    try completeTodo(project: project, sessionIndex: todo.sessionIndex,
                                     lineIndex: todo.lineIndex, advanceFocus: false)
                } else {
                    try undoTodo(project: project, sessionIndex: todo.sessionIndex, lineIndex: todo.lineIndex)
                }
            }
        }
    }

    /// Set (or clear, with `due == nil`) the due date on every task in `todos` as one edit.
    func setDueAll(_ todos: [Todo], due: String?) {
        guard !todos.isEmpty else { return }
        mutate { project in
            for todo in todos {
                try setDueOnTodo(project: project, sessionIndex: todo.sessionIndex,
                                 lineIndex: todo.lineIndex, due: due)
            }
        }
    }

    /// `todos` rendered as a markdown block for the pasteboard: each task with its whole subtree, in
    /// document order, dedented so the shallowest line sits at the left margin.
    ///
    /// The lines travel as they're stored (checkbox, `due:`, list marker and relative nesting intact),
    /// so a copied selection pastes back into these notes — or any markdown document — as real tasks.
    /// The ` @` focus marker is stripped: focus names one task *within a document*, and carrying it to
    /// the clipboard would smuggle a second marker into wherever it lands.
    func markdown(for todos: [Todo]) -> String {
        let lines = outermost(todos).flatMap { subtree(of: $0) }.map(\.rawLine)
        guard !lines.isEmpty else { return "" }
        let dedent = lines.map { $0.prefix { $0 == " " }.count }.min() ?? 0
        return lines
            .map { line -> String in
                var out = String(line.dropFirst(dedent))
                if out.hasSuffix(" @") { out.removeLast(2) }
                return out
            }
            .joined(separator: "\n")
    }

    /// The keys of `todo` and its subtree — the task itself plus the contiguous run of deeper todos
    /// right after it in document order. Used by the panel to reject drops onto a task's own descendants.
    func subtreeKeys(of todo: Todo) -> Set<String> {
        guard let idx = todos.firstIndex(where: {
            $0.sessionIndex == todo.sessionIndex && $0.lineIndex == todo.lineIndex
        }) else { return [] }
        var keys: Set<String> = [Self.key(for: todo)]
        var j = idx + 1
        while j < todos.count, todos[j].depth > todos[idx].depth {
            keys.insert(Self.key(for: todos[j]))
            j += 1
        }
        return keys
    }

    /// Whether `todo` has at least one child task — i.e. the next task in document order (same
    /// session) sits one or more levels deeper. Drives the "Unwrap" affordance's availability.
    func hasChildren(_ todo: Todo) -> Bool {
        guard let idx = todos.firstIndex(where: {
            $0.sessionIndex == todo.sessionIndex && $0.lineIndex == todo.lineIndex
        }) else { return false }
        let next = idx + 1
        return next < todos.count
            && todos[next].sessionIndex == todo.sessionIndex
            && todos[next].depth > todos[idx].depth
    }

    /// The task focus should advance to: the first open leaf under the focused task, else the next
    /// open leaf after it in document order. Drives both "Dive in" and the focused-mode "Next" hint so
    /// the two can't diverge. The leaf-finding logic lives in `PmLib.nextDiveInLeaf` (shared with the
    /// Raycast command and covered by unit tests).
    var nextTodo: Todo? { PmLib.nextDiveInLeaf(todos: todos) }

    /// "Dive in": move focus to the next open leaf. Mirrors the Raycast Dive In command.
    func diveIn() {
        if let next = nextTodo { focus(next) }
    }

    /// Persist an edit to the project's detail fields (summary, problem, goals, approach, learnings).
    /// The transform runs against freshly-parsed notes on the IO queue, so tasks/sessions are read
    /// from disk and preserved. Reloads afterward like every other mutation.
    func saveDetails(_ transform: @escaping (ProjectNotes) -> ProjectNotes) {
        mutate { try editDetails(project: $0, transform) }
    }

    func addTodo(text: String, due: String? = nil, relativeTo anchor: Todo? = nil, position: TaskInsertPosition? = nil) {
        let placement: (kind: TaskInsertPosition, sessionIndex: Int, lineIndex: Int)?
        if let anchor, let position {
            placement = (position, anchor.sessionIndex, anchor.lineIndex)
        } else {
            placement = nil
        }
        mutate { try PmLib.addTodo(project: $0, text: text, due: due, position: placement) }
    }

    // MARK: Session mutations (each flows through `mutate`, so ⌘Z undo/redo covers it)

    /// Whether the session at `index` has any task lines — gates the panel's "Delete session" affordance
    /// so tasks are never removed with it.
    func hasTasks(sessionIndex index: Int) -> Bool {
        todos.contains { $0.sessionIndex == index }
    }

    /// Add a new (empty) session dated today at the top of the Sessions list, with an optional label.
    func addSession(label: String = "") {
        mutate { try PmLib.addSession(project: $0, label: label, date: Date()) }
    }

    /// Rename the session at `index` (its trailing label; the date is preserved).
    func renameSession(_ index: Int, label: String) {
        mutate { try PmLib.renameSession(project: $0, sessionIndex: index, label: label) }
    }

    /// Set (or clear, with empty `prose`) the leading-prose note under the session at `index`.
    func setSessionNote(_ index: Int, prose: String) {
        mutate { try PmLib.setSessionNote(project: $0, sessionIndex: index, prose: prose) }
    }

    /// Delete the session at `index`. The panel only offers this for sessions with no tasks.
    func deleteSession(_ index: Int) {
        mutate { try PmLib.deleteSession(project: $0, sessionIndex: index) }
    }

    /// Append a task to the session at `index` (used to populate an otherwise-empty session).
    func addTaskToSession(_ index: Int, text: String, due: String? = nil) {
        mutate { try PmLib.appendTaskToSession(project: $0, sessionIndex: index, text: text, due: due) }
    }
}
