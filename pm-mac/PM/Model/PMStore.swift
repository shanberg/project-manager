import Foundation
import Combine
import AppKit
import PmLib

/// A classified change of the focused ("hero") task between two loads, used to drive directional
/// animations in the focus panel card and the menubar button so the movement reads spatially.
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

/// Single source of truth for the focused project, shared by the menubar item, the focus panel and the project windows.
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

    /// The shared scans, mirrored in so views observing this store still repaint when they land.
    /// See `ProjectIndex` for why they live outside the store.
    @Published private var indexRecents: [Recent] = []
    @Published private(set) var allProjects: [ProjectEntry] = []

    /// Recent projects for the menubar's and this store's quick-switchers: the shared recency list with
    /// *this* store's project dropped (a switcher never offers the project you're already in) and capped
    /// at the eight rows a switcher shows.
    var recents: [Recent] { Array(indexRecents.lazy.filter { $0.projectKey != self.projectKey }.prefix(8)) }

    /// The scans' row types live on `ProjectIndex` now; these keep `PMStore.Recent` /
    /// `PMStore.ProjectEntry` working for the sidebar and the menubar.
    typealias ProjectEntry = ProjectIndex.ProjectEntry
    typealias Recent = ProjectIndex.Recent

    /// A whole-document snapshot for undo/redo — the notes path plus its exact raw bytes at a point in
    /// time. Restoring one writes the bytes back verbatim, so undo is format-preserving like every edit.
    struct DocSnapshot: Equatable { let notesPath: String; let raw: String }

    /// Undo/redo history of pre-mutation document snapshots, for in-app edits (move, complete,
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

    /// Whether this store is currently holding the shared full-project scan open (see
    /// `setWantsAllProjects`). Tracked per store so each one contributes at most one retain.
    private var wantsAllProjects = false

    /// The project this store shows. Every store is bound to exactly one project (nil = none, which
    /// renders the empty state) rather than following `focused.json`, so two windows can show two
    /// projects at once. Following the focus is the menubar's job: when `focused.json` changes it
    /// acquires the store for the new key, which means it shares one store — one undo stack, one
    /// `lastCompletedKey` — with any window already showing that project.
    private(set) var boundKey: String?

    /// Mirror the shared scans into this store's published state, so existing views that observe the
    /// store keep repainting when a scan lands.
    init(boundKey: String? = nil) {
        self.boundKey = boundKey
        ProjectIndex.shared.$recents.assign(to: &$indexRecents)
        ProjectIndex.shared.$allProjects.assign(to: &$allProjects)
    }

    /// Point this store at a different project (or back at `focused.json`) and reload.
    func bind(to key: String?) {
        guard boundKey != key else { return }
        boundKey = key
        reload()
    }

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
    /// fields needed to classify how it moved. Mirrors the focus panel hero task.
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

    /// Re-read this store's project and its notes. Safe to call frequently (e.g. from the watcher).
    ///
    /// `then` runs on the main actor once the re-read has landed and been published, so a caller that
    /// needs to act on the *new* document — pointing an editor at a session it just added — can wait
    /// for the indices to be real rather than guessing at them.
    func reload(then: (@MainActor () -> Void)? = nil) {
        let key = boundKey
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
            errorMessage = key == nil ? nil : "Invalid project."
            hasLoaded = true
            ProjectIndex.shared.warmRecents()
            ProjectIndex.shared.warmAllProjects()
            then?()
            return
        }
        // Opening a project sweeps out any session left with nothing in it — see the prune below.
        let isOpening = projectKey != key
        io.async { [weak self] in
            // Resolve the project directory once (this is the protected-folder access), then reuse
            // the handle for both the notes read and the cached notes path.
            Log.write("reload start: name=\(name)")
            let result = Result { () -> (NotesShowOutput, String, String) in
                let cfg = try? loadConfig()
                Log.write("config: useObsidianCLI=\(cfg?.useObsidianCLI ?? false)")
                let handle = try resolveNotesHandle(project: name)
                Log.write("resolved: notesPath=\(handle.notesPath) io=\(type(of: handle.io))")
                // Sessions with no note and no tasks are swept on open, so abandoned headings don't
                // pile up. Only on open: a session added mid-session stays until you come back to the
                // project. Best-effort — a failure here must not cost us the load.
                if isOpening, let n = try? pruneEmptySessions(handle: handle), n > 0 {
                    Log.write("pruned \(n) empty session(s)")
                }
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
                    ProjectIndex.shared.warmRecents()
                    // A switch reorders the sidebar (the new project jumps to the top of its group) and
                    // moves the selection, so re-scan straight away rather than waiting out the TTL.
                    ProjectIndex.shared.warmAllProjects(force: projectChanged)
                case .failure(let error):
                    // Keep the last-good render on transient failures; only surface the error text.
                    self.errorMessage = String(describing: error)
                    self.hasLoaded = true
                }
                // After the publish, either way: a completion that only ran on success would strand a
                // caller waiting on it the one time the read failed.
                then?()
            }
        }
    }

    /// Write the *global* focused project — `focused.json` plus the recent list — which the CLI,
    /// Raycast and the menubar all read. Whichever PM window is frontmost owns this value, so it's a
    /// static: it isn't about any one store's project.
    ///
    /// `completion` runs on the main actor once the write has landed, so a caller that needs to re-read
    /// `focused.json` (a focus-following store) doesn't race its own write.
    static func setGlobalFocus(key: String, completion: (@MainActor () -> Void)? = nil) {
        guard let name = PMFiles.projectName(fromKey: key) else { return }
        focusQueue.async {
            try? PMFiles.setFocusedProjectKey(key)
            PMFiles.recordRecent(projectKey: key, name: name)
            if let completion { Task { @MainActor in completion() } }
        }
    }

    /// Serial queue for focus writes, so two windows becoming main in quick succession can't interleave.
    private static let focusQueue = DispatchQueue(label: "com.stuarthanberg.pm.focus")

    /// Move the global focus to `key`. Callers that also need to *show* that project (a window
    /// switching projects) go through `WindowManager.retarget`, which swaps in the store for the new
    /// key; this only moves the focus.
    func setFocusedProject(key: String) {
        Self.setGlobalFocus(key: key)
    }

    // MARK: The shared scans

    /// Hold the shared full-project scan open while this store's sidebar is showing. Forwards to
    /// `ProjectIndex`, which refcounts across windows so the scan runs once for all of them.
    func setWantsAllProjects(_ on: Bool) {
        guard wantsAllProjects != on else { return }
        wantsAllProjects = on
        if on { ProjectIndex.shared.retain() } else { ProjectIndex.shared.release() }
    }

    // MARK: Mutations (each performs the NotesService call, then reloads)

    /// Run a document mutation off-main, then reload. When `recordsUndo` (the default), the pre-edit
    /// document is banked for undo if the edit actually changed bytes. Navigation-only writes (focus)
    /// pass `recordsUndo: false` so ⌘Z reverts real edits, not selection changes.
    private func mutate(recordsUndo: Bool = true,
                        then: (@MainActor () -> Void)? = nil,
                        _ work: @escaping (String) throws -> Void) {
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
            Task { @MainActor in self?.reload(then: then) }
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
    /// with the subtree's root re-indented to `depth`. Drives the drag-to-reorder: the drop's
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
    // The task list supports multi-selection, so these take a set of tasks and perform the
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
    /// already inside another's subtree) and the extra descendants that ride along. The
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
    /// right after it in document order. Used to reject drops onto a task's own descendants.
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
    /// open leaf after it in document order. Drives both "Dive in" and the focus panel's "Next" hint so
    /// the two can't diverge. The leaf-finding logic lives in `PmLib.nextDiveInLeaf` (shared with the
    /// Raycast command and covered by unit tests).
    var nextTodo: Todo? { PmLib.nextDiveInLeaf(todos: todos) }

    /// The chain of ancestor task texts above `todo`, joined with chevrons, or nil if it's a root task.
    /// Walks the flat todo list backward, picking up one task at each shallower depth within the same
    /// session — the same structure the list's indentation reflects.
    ///
    /// Lives on the store rather than in a view because it's the focus panel's breadcrumb *and* the
    /// context any other surface would need to say where a task sits; a copy in each would drift.
    func breadcrumb(for todo: Todo) -> String? {
        guard let idx = todos.firstIndex(where: {
            $0.sessionIndex == todo.sessionIndex && $0.lineIndex == todo.lineIndex
        }) else { return nil }
        var ancestors: [String] = []
        var wantDepth = todo.depth - 1
        var i = idx - 1
        while i >= 0, wantDepth >= 0 {
            let t = todos[i]
            if t.sessionIndex == todo.sessionIndex, t.depth == wantDepth {
                ancestors.insert(t.text, at: 0)
                wantDepth -= 1
            }
            i -= 1
        }
        return ancestors.isEmpty ? nil : ancestors.joined(separator: "  ›  ")
    }

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

    /// Add a task. `then` runs once the document has been re-read, so a caller that needs to find the
    /// task it just wrote has a list that contains it.
    func addTodo(text: String, due: String? = nil, relativeTo anchor: Todo? = nil,
                 position: TaskInsertPosition? = nil, then: (@MainActor () -> Void)? = nil) {
        let placement: (kind: TaskInsertPosition, sessionIndex: Int, lineIndex: Int)?
        if let anchor, let position {
            placement = (position, anchor.sessionIndex, anchor.lineIndex)
        } else {
            placement = nil
        }
        mutate(then: then) { try PmLib.addTodo(project: $0, text: text, due: due, position: placement) }
    }

    // MARK: Session mutations (each flows through `mutate`, so ⌘Z undo/redo covers it)

    /// Whether the session at `index` has any task lines — gates the "Delete session" affordance
    /// so tasks are never removed with it.
    func hasTasks(sessionIndex index: Int) -> Bool {
        todos.contains { $0.sessionIndex == index }
    }

    /// The index of today's session, or nil when the project hasn't got one yet.
    var todaySessionIndex: Int? {
        let today = formatSessionDate()
        return notes?.sessions.firstIndex { $0.date == today }
    }

    /// Open today's session for writing, creating it only if the project hasn't got one, and hand its
    /// index back once the document has been re-read.
    ///
    /// "New session" means *today's* session, not another one. A session is identified by its date —
    /// `addTodo` and the menubar's note both find today's by matching that string — so a second
    /// heading with the same date leaves every one of those with two candidates and no way to choose.
    /// This makes the command idempotent: ask for today twice and you land in the same place.
    func openTodaySession(then: @escaping @MainActor (Int) -> Void) {
        if let index = todaySessionIndex {
            then(index)
            return
        }
        mutate(then: { [weak self] in
            guard let self, let index = self.todaySessionIndex else { return }
            then(index)
        }) { try PmLib.addSession(project: $0, label: "", date: Date()) }
    }

    /// Rename the session at `index` (its trailing label; the date is preserved).
    func renameSession(_ index: Int, label: String) {
        mutate { try PmLib.renameSession(project: $0, sessionIndex: index, label: label) }
    }

    /// Set (or clear, with empty `prose`) the leading-prose note under the session at `index`.
    func setSessionNote(_ index: Int, prose: String) {
        mutate { try PmLib.setSessionNote(project: $0, sessionIndex: index, prose: prose) }
    }

    /// Delete the session at `index`. The app only offers this for sessions with no tasks.
    func deleteSession(_ index: Int) {
        mutate { try PmLib.deleteSession(project: $0, sessionIndex: index) }
    }

    /// Append a task to the session at `index` (used to populate an otherwise-empty session).
    func addTaskToSession(_ index: Int, text: String, due: String? = nil) {
        mutate { try PmLib.appendTaskToSession(project: $0, sessionIndex: index, text: text, due: due) }
    }

    /// Add prose to today's session note, creating today's session when the project hasn't got one.
    ///
    /// Appending, not setting: `setSessionNote` replaces the session's whole leading-prose region, so a
    /// line typed into the quick bar would silently swallow whatever the day's note already said. The
    /// note is a running log, and a second entry joins the first.
    /// `then` runs after the re-read, which matters when the caller means to open today's session
    /// next: this may have just created it, and asking for it against a stale document would make a
    /// second heading with the same date.
    func appendSessionNote(_ prose: String, then: (@MainActor () -> Void)? = nil) {
        mutate(then: then) { _ = try PmLib.appendNoteToTodaySession(project: $0, prose: prose) }
    }
}
