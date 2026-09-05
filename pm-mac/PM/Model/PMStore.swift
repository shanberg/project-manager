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

/// The last revision the store saw, held where the IO queue can reach it.
///
/// A box rather than a stored property because the value has to be readable and writable off the main
/// actor: every read and write of the notes file happens on the store's IO queue, and the revision is
/// a fact about that file, updated by whichever of them ran last.
private final class RevisionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?
    var value: String? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); defer { lock.unlock() }; stored = newValue }
    }
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

    /// Whether the thing this store is bound to is a project or an area.
    ///
    /// Derived from the folder name, like everywhere else, so it can't disagree with what the file on
    /// disk is. A store with nothing loaded reads as a project — that's what the app was before Areas
    /// existed, and `ProjectKind.of` would call an empty name an area.
    var kind: ProjectKind { projectName.map(ProjectKind.of(folderName:)) ?? .project }
    /// Resolved path to the focused project's notes file, captured during reload so the app can watch
    /// it without re-scanning the (protected) project directory on every UI update.
    @Published private(set) var notesPath: String?
    /// The project's canvas, when it has one on disk. Nil is "not made yet", never "this project
    /// doesn't do canvases" — every project is assumed to want a board, so the header offers to make
    /// one rather than hiding itself. Re-resolved on every load so a canvas created in Obsidian while
    /// PM is open turns up without a restart.
    @Published private(set) var canvasPath: String?
    @Published private(set) var notes: ProjectNotes?
    @Published private(set) var todos: [Todo] = []
    /// What each distinct wait target on this project's tasks turns out to name, resolved once per
    /// load rather than once per row.
    ///
    /// A row asks this rather than resolving for itself because resolution walks every project folder
    /// name: per-row that's the folder list times the task list on every redraw, and a task list is
    /// redrawn on every keystroke in the note beside it. Keyed by the target string exactly as the
    /// task line spells it, which is what `Todo.effectiveWaiting` carries.
    @Published private(set) var waitTargets: [String: WaitTarget] = [:]
    @Published private(set) var focusedKey: String?
    /// When this project's notes file was last written, read at each reload. It's what tells a
    /// command whether it's continuing the current session or starting a new one — see
    /// `willStartNewSession` and `PmLib.sessionIdleWindow`.
    @Published private(set) var lastEditedAt: Date?
    /// Why this project can't be read, if it can't. A read failure only — writes report themselves
    /// through `writeFailure` below.
    @Published private(set) var errorMessage: String?

    /// A write that didn't happen, and why.
    ///
    /// Separate from `errorMessage` because the two have different shapes. `errorMessage` is state:
    /// something is wrong with the project, and a successful read clears it. A refused write is an
    /// event: the project is fine, and the reload that follows the refusal succeeds — which would wipe
    /// the sentence before anyone read it. So it carries a token instead, which surfaces watch to put
    /// the sentence up, and the quick bar compares to tell "the write I just made failed" from "a
    /// reload happened to fail while I was writing".
    struct WriteFailure: Equatable { let message: String; let token: Int }
    @Published private(set) var writeFailure: WriteFailure?
    private var writeFailures = 0
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

    /// The revision of the last document this store read or wrote — what a batch sends back to say
    /// "this is the document the selection was made against". See `deleteTasks` for why batches need it
    /// and single-task writes don't.
    ///
    /// It deliberately doesn't live in published state. The moment to read it is *inside* the IO queue,
    /// when the write is about to happen and everything queued ahead of it has landed. Read on the main
    /// actor when the click arrives, it would still be the value from before the store's own last write,
    /// and the second of two quick batches would be refused for a change the app itself made.
    private let seenRevision = RevisionBox()

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
        // A sink rather than an assign, because what a landing folder scan changes here isn't a
        // mirrored value but a derived one: archiving the project a task waits on turns that wait from
        // pending to released, and it happens in a different window from the one showing the task.
        ProjectIndex.shared.$waitRoots
            .sink { [weak self] _ in
                Task { @MainActor in self?.resolveWaits() }
            }
            .store(in: &cancellables)
    }

    private var cancellables = Set<AnyCancellable>()

    /// Point this store at a different project (or back at `focused.json`) and reload.
    func bind(to key: String?) {
        guard boundKey != key else { return }
        boundKey = key
        reload()
    }

    // MARK: Derived state for the UI

    /// The currently focused todo, if any.
    /// Re-resolve every distinct wait on the current tasks against the folder scan.
    ///
    /// Called on load, and again whenever the folder scan lands — archiving the project a task waits
    /// on is what turns that wait from pending to released, and it happens in a different window from
    /// the one showing the task.
    func resolveWaits() {
        let targets = todos.compactMap(\.effectiveWaiting)
        guard !targets.isEmpty else {
            if !waitTargets.isEmpty { waitTargets = [:] }
            return
        }
        let roots = ProjectIndex.shared.waitRoots.map { (scope: $0.scope, folders: $0.folders) }
        guard !roots.isEmpty else { return }
        let resolved = resolveWaitTargets(targets, roots: roots)
        if resolved != waitTargets { waitTargets = resolved }
    }

    /// What a task is waiting on, and what that name turns out to be — nil when it isn't waiting.
    ///
    /// Reads `effectiveWaiting`, so a task under a waiting parent answers with the parent's wait, and
    /// reports whether the wait is this task's own: a descendant draws it as reported rather than
    /// declared. An unscanned or unknown target resolves to `.unresolved`, which is a real answer —
    /// most things anyone waits on are people.
    func wait(for todo: Todo) -> (target: String, resolution: WaitTarget, isOwn: Bool)? {
        guard let target = todo.effectiveWaiting else { return nil }
        return (target, waitTargets[target] ?? .unresolved, todo.waiting != nil)
    }

    var focusedTodo: Todo? { todos.first { $0.isFocused } }

    /// Open (unchecked) todos in document order.
    var openTodos: [Todo] { todos.openTasks }
    /// The open tasks that could actually be picked up — what every surface offering you a task shows.
    var availableTodos: [Todo] { todos.availableTasks }
    /// This project's current task: the focused one, else the first available one.
    var heroTodo: Todo? { todos.heroTask }

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
        guard let h = todos.heroTask else { return nil }
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
            canvasPath = nil
            notes = nil
            todos = []
            lastEditedAt = nil
            focusedKey = nil
            heroSnapshot = nil   // no project → nothing to animate from next time
            undoStack = []; redoStack = []   // history belongs to a project
            seenRevision.value = nil         // and so does the revision of its document
            errorMessage = key == nil ? nil : "Invalid project."
            hasLoaded = true
            ProjectIndex.shared.warmRecents()
            ProjectIndex.shared.warmWaitRoots()
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
            let result = Result { () -> (NotesShowOutput, String, String, Date?) in
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
                // Set here, on the IO queue, rather than beside the published state: a batch reads it
                // from the same queue, so it always sees the newest read that has actually finished.
                self?.seenRevision.value = output.revision
                // After the prune above, which is a write of our own — read before it, the file's
                // date would be the moment *this* load touched it rather than the last real edit.
                return (output, handle.notesPath, handle.projectPath, notesLastEdited(path: handle.notesPath))
            }
            if case .failure(let error) = result {
                let ns = error as NSError
                Log.write("reload FAILED: \(error) [domain=\(ns.domain) code=\(ns.code)]")
            }
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success(let (output, path, projectPath, lastEdited)):
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
                    self.resolveWaits()
                    self.lastEditedAt = lastEdited
                    self.focusedKey = output.focusedKey
                    self.errorMessage = nil
                    self.hasLoaded = true
                    self.refreshCanvasPath(projectPath: projectPath)
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
                    ProjectIndex.shared.warmWaitRoots()
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

    // MARK: The project's canvas

    /// Re-resolve the project's board off the main thread and publish it.
    ///
    /// Its own hop rather than another element in `reload`'s tuple: this is two directory listings and
    /// nothing else depends on it, so widening the load — which already carries the notes read, the
    /// prune and the revision — to thread a third path through would cost more in the reading than it
    /// saves in the running.
    private func refreshCanvasPath(projectPath: String) {
        io.async { [weak self] in
            let resolved = try? resolveProjectCanvasPath(projectPath: projectPath)
            Task { @MainActor in
                guard let self, self.projectPath == projectPath else { return }
                self.canvasPath = resolved
            }
        }
    }

    /// The project's board, made if it hasn't got one yet, handed back on the main actor.
    ///
    /// Creation is a side effect of asking for it, which is the whole point of the convention: a
    /// project is assumed to have a canvas, so opening one is never a two-step ceremony of "make it,
    /// then open it". Resolution happens again here rather than trusting `canvasPath`, because the
    /// published value is a snapshot and the answer to "should I write a file" deserves the live one.
    func openableCanvasPath(_ done: @escaping @MainActor (Result<String, Error>) -> Void) {
        guard let projectPath else {
            // A window made a moment ago by the menu command itself: the store's first load is still in
            // flight, so there is no project folder to answer about yet. Wait for it rather than doing
            // nothing — a command that silently no-ops the first time you press it, and works the
            // second, is the kind of bug people stop reporting and start working around. `hasLoaded`
            // stops this at one retry: after a load, nil means there really is no project.
            if !hasLoaded { reload { [weak self] in self?.openableCanvasPath(done) } }
            return
        }
        let notesPath = self.notesPath
        io.async { [weak self] in
            let result = Result {
                try resolveProjectCanvasPath(projectPath: projectPath)
                    ?? createProjectCanvas(projectPath: projectPath, notesPath: notesPath)
            }
            Task { @MainActor in
                if case .success(let path) = result, self?.projectPath == projectPath {
                    self?.canvasPath = path
                }
                done(result)
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

    // MARK: Mutations (each performs one contract action, then reloads)
    //
    // These go through `PMContract` rather than `NotesService` so the app writes the way every other
    // surface does — and so each write carries the task's digest. The store holds the tasks from its
    // last read, and the notes file is markdown the user also edits in Obsidian; a click acts on what
    // was on screen, which may not be what's on disk any more. See docs/task-identity.md.

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
                let message = PMContract.message(for: error)
                Task { @MainActor in self?.noteWriteFailure(message) }
            }
            // Re-read the document once, for two things at once. Undo banks the pre-edit bytes only
            // when the bytes actually moved, so a no-op mutation costs no ⌘Z step. And the revision has
            // to catch up here rather than when the reload lands: a second batch fired before that
            // would otherwise be refused for a change this write made, which is the app arguing with
            // itself. Every write passes through here — including `moveSubtree`, which doesn't go
            // through the contract and so has no result to report a revision back in.
            let after = try? Self.snapshot(project: name)
            if let after { self?.seenRevision.value = revision(of: after.raw) }
            if let before, let after, before.raw != after.raw {
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

    /// Record a write that didn't happen. The token advances every time, so two identical refusals in
    /// a row still read as two — a banner that only watched the text would sit there looking stale.
    private func noteWriteFailure(_ message: String) {
        writeFailures += 1
        writeFailure = WriteFailure(message: message, token: writeFailures)
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
                self?.seenRevision.value = revision(of: target.raw)
            } catch {
                let message = String(describing: error)
                Task { @MainActor in self?.noteWriteFailure(message) }
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

    /// The same task as the contract names it. Completing doesn't change a task's text, so the digest
    /// taken before the write still identifies it afterwards — which is what lets the undo find it
    /// even if the document has moved on since.
    private var lastCompletedRef: TaskRefInput?

    /// `then` runs once the document has been re-read, like `addTodo`'s — it's what lets a caller that
    /// has already handed the keyboard back say whether the change actually landed.
    func complete(_ todo: Todo, advanceFocus: Bool = true, then: (@MainActor () -> Void)? = nil) {
        lastCompletedKey = Self.key(for: todo)
        lastCompletedRef = todo.reference
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        mutate(then: then) { project in
            try PMContract.perform("task.complete", PMContract.input(project: project, task: todo) {
                $0.advanceFocus = advanceFocus
            })
        }
    }

    /// Undo the most recent completion (re-open it and move focus back onto it).
    func undoLast(then: (@MainActor () -> Void)? = nil) {
        guard let reference = lastCompletedRef else { return }
        lastCompletedKey = nil
        lastCompletedRef = nil
        mutate(then: then) { project in
            var input = ApiInput()
            input.project = project
            input.task = reference
            try PMContract.perform("task.reopen", input)
        }
    }

    func toggle(_ todo: Todo) {
        if todo.checked {
            undo(todo)
        } else {
            complete(todo, advanceFocus: true)
        }
    }

    func focus(_ todo: Todo, then: (@MainActor () -> Void)? = nil) {
        // Focus is navigation, not a content edit, so keep it out of the undo history.
        mutate(recordsUndo: false, then: then) {
            try PMContract.perform("task.focus", PMContract.input(project: $0, task: todo))
        }
    }

    func undo(_ todo: Todo) {
        mutate { try PMContract.perform("task.reopen", PMContract.input(project: $0, task: todo)) }
    }

    func setDue(_ todo: Todo, due: String?, then: (@MainActor () -> Void)? = nil) {
        mutate(then: then) { project in
            try PMContract.perform("task.setDue", PMContract.input(project: project, task: todo) {
                if let due { $0.due = due } else { $0.clearDue = true }
            })
        }
    }

    /// Set or clear what a task is waiting on.
    func setWaiting(_ todo: Todo, waiting: String?, then: (@MainActor () -> Void)? = nil) {
        mutate(then: then) { project in
            try PMContract.perform("task.setWaiting", PMContract.input(project: project, task: todo) {
                if let waiting { $0.waiting = waiting } else { $0.clearWaiting = true }
            })
        }
    }

    /// Replace a task's text in place (checkbox, due, focus, and indent preserved).
    func editText(_ todo: Todo, text: String) {
        mutate { project in
            try PMContract.perform("task.setText", PMContract.input(project: project, task: todo) {
                $0.text = text
            })
        }
    }

    /// Wrap a task in a new parent task, nesting the task (and its subtree) under it; focus stays put.
    func wrap(_ todo: Todo, parentText: String) {
        mutate { project in
            try PMContract.perform("task.wrap", PMContract.input(project: project, task: todo) {
                $0.text = parentText
            })
        }
    }

    /// Dissolve a parent task: remove it and promote its children (with their subtrees) into its
    /// place. If the dissolved parent held focus, focus moves to its first child. Only meaningful for
    /// tasks with children — `hasChildren(_:)` gates the UI affordance. Inverse of `wrap`.
    func unwrap(_ todo: Todo) {
        mutate { try PMContract.perform("task.unwrap", PMContract.input(project: $0, task: todo)) }
    }

    /// Drag-reorder, still a `NotesService` call: the contract has no action for it.
    ///
    /// It is the panel's own gesture — two references, a side and a depth, resolved from a drop's
    /// coordinates — with no caller that reads early and acts late, which is what a contract action
    /// would be protecting against. It stays here until something else needs it.
    ///
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

    /// Paste (or drop) a block of tasks in after `anchor`'s whole subtree, at the anchor's own depth.
    /// With no anchor they go at the end of the current session.
    ///
    /// One `mutate`, so a paste of nine lines is one write and one ⌘Z — the same rule `deleteTasks`
    /// follows, and the reason this is a `PmLib` splice rather than a run of `task.add` calls: after
    /// the first of those the store's in-memory tasks no longer describe the document the second would
    /// have to anchor against, and each would bank its own undo step.
    func pasteTasks(_ block: [PastedTask], after anchor: Todo?, then: (@MainActor () -> Void)? = nil) {
        guard !block.isEmpty else { return }
        let session = anchor == nil ? (todaySessionIndex ?? notes?.sessions.indices.last) : nil
        mutate(then: then) { project in
            try PmLib.insertTaskBlock(project: project,
                                      block: block,
                                      anchorSessionIndex: anchor?.sessionIndex,
                                      anchorLineIndex: anchor?.lineIndex,
                                      sessionIndex: session)
        }
    }

    /// Move a task (and its subtree) to the end of a session, at top level. What a drop on a session
    /// with no tasks means: there's no task there to sit beside, so the session is the whole address.
    func moveSubtree(_ todo: Todo, toSession index: Int) {
        mutate {
            try PmLib.moveSubtree(project: $0,
                                  sourceSessionIndex: todo.sessionIndex, sourceLineIndex: todo.lineIndex,
                                  toSessionIndex: index)
        }
    }

    // MARK: Selection-wide operations
    //
    // The task list supports multi-selection, so these take a set of tasks and perform the
    // whole batch inside ONE `mutate` — a single pre-edit snapshot is banked, so ⌘Z reverses the
    // entire action rather than unwinding it task by task.
    //
    // Each also sends the revision of the document the selection was made against, which single-task
    // writes deliberately don't. A digest says "this is still that task"; only a revision says "the
    // tasks around it are still the ones you were looking at". A batch needs the second because a
    // reference it can't resolve is *skipped* rather than refused — completing a parent completes its
    // children, so a child that came along in the same selection is expected to be gone by the time its
    // turn arrives. That tolerance is what makes "act on this selection" mean what a person means by
    // it, and it's also what would let a task edited in Obsidian a second ago drop out of the batch
    // without a word. The revision is the line between the two: same document, skip freely; different
    // document, do nothing and say so. A single-task write needs none of it — its digest already
    // identifies its one task, and guarding it on the whole document would refuse it because a line
    // elsewhere in the file changed.

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
        // One action for the selection, not one per task: a single write, a single journal entry,
        // and a single step to undo — a batch a person made in one gesture should come back in one.
        let seen = seenRevision
        mutate { project in
            try PMContract.perform("task.delete", PMContract.input(project: project) {
                $0.tasks = bottomUp.map(\.reference)
                $0.revision = seen.value
            })
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
            lastCompletedRef = targets.last?.reference
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        }
        let seen = seenRevision
        mutate { project in
            try PMContract.perform(completing ? "task.complete" : "task.reopen",
                                   PMContract.input(project: project) {
                $0.tasks = targets.map(\.reference)
                $0.revision = seen.value
                // `advanceFocus: false` — a batch shouldn't march focus once per task. The backend
                // still moves focus if one of the completed tasks was holding it.
                if completing { $0.advanceFocus = false }
            })
        }
    }

    /// Set (or clear, with `due == nil`) the due date on every task in `todos` as one edit.
    func setDueAll(_ todos: [Todo], due: String?) {
        guard !todos.isEmpty else { return }
        let seen = seenRevision
        mutate { project in
            try PMContract.perform("task.setDue", PMContract.input(project: project) {
                $0.tasks = todos.map(\.reference)
                $0.revision = seen.value
                if let due { $0.due = due } else { $0.clearDue = true }
            })
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
    func diveIn(then: (@MainActor () -> Void)? = nil) {
        guard let next = nextTodo else {
            then?()
            return
        }
        focus(next, then: then)
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
        mutate(then: then) { project in
            try PMContract.perform("task.add", PMContract.input(project: project) { input in
                input.text = text
                input.due = due
                if let anchor, let position {
                    input.anchor = anchor.reference
                    input.position = position == .child ? "child" : (position == .before ? "before" : "after")
                }
            })
        }
    }

    // MARK: Session mutations (each flows through `mutate`, so ⌘Z undo/redo covers it)

    /// The strongest reference that can be made to the session at `index` right now: its date, its
    /// ordinal among that day's sittings, and a digest of its label.
    ///
    /// Anything that reads a session and acts on it *later* — an editor you type into, a menu item you
    /// click — should take one of these at the moment it opens and hand it back when it commits. An
    /// `Int` captured then and used now names whatever has since moved into that position, which is how
    /// a note written from the quick bar could redirect an open editor onto a different sitting. See
    /// `SessionRef`.
    func sessionRef(at index: Int) -> SessionRef? {
        guard let notes, notes.sessions.indices.contains(index) else { return nil }
        return SessionRef(session: notes.sessions[index], at: index, in: notes)
    }

    /// Whether the session at `index` has any task lines — gates the "Delete session" affordance
    /// so tasks are never removed with it. The affordance only; the write refuses on its own account
    /// (see `session.delete` in `ApiDispatch`), because a gate read here is read against a document
    /// the write will not be applied to.
    func hasTasks(sessionIndex index: Int) -> Bool {
        todos.contains { $0.sessionIndex == index }
    }

    /// The index of today's session, or nil when the project hasn't got one yet.
    var todaySessionIndex: Int? {
        let today = formatSessionDate()
        return notes?.sessions.firstIndex { $0.date == today }
    }

    /// Whether the next thing written into this project opens a new session rather than joining the
    /// one it already has.
    ///
    /// The same question `PmLib.currentSessionPreservingFormat` answers on the way into a write, asked
    /// here so a command can tell whether it has to go through the contract at all. The rule itself
    /// isn't restated — the window and the "has it gone cold" test are the library's, and only the
    /// document this store already has in memory is read locally.
    var willStartNewSession: Bool {
        guard let sessions = notes?.sessions, let index = todaySessionIndex,
              sessions.indices.contains(index) else {
            return true   // no session for today yet
        }
        let session = sessions[index]
        // A heading with nothing under it is a sitting that never started, so writing into it starts
        // it — however long ago it was made.
        guard !session.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return sessionHasGoneCold(lastEdited: lastEditedAt)
    }

    /// Open the current session for writing, starting one when there isn't one to continue, and hand
    /// its index back once the document has been re-read.
    ///
    /// The current session is today's — unless the project has been left alone past
    /// `PmLib.sessionIdleWindow`, in which case coming back to it is a new sitting and gets a heading
    /// of its own, labelled with the time so two dated the same day can be told apart. Within the
    /// window this stays idempotent: ask twice in a row and you land in the same session both times.
    func openCurrentSession(then: @escaping @MainActor (Int) -> Void) {
        if let index = todaySessionIndex, !willStartNewSession {
            then(index)
            return
        }
        mutate(then: { [weak self] in
            guard let self, let index = self.todaySessionIndex else { return }
            then(index)
        }) { try PMContract.perform("session.start", PMContract.input(project: $0)) }
    }

    /// Fill in the session-addressing fields of an action's input from a reference.
    private static func address(_ input: inout ApiInput, _ ref: SessionRef) {
        input.session = ref.date ?? ref.index.map(String.init)
        input.sessionOrdinal = ref.ordinal
        input.sessionDigest = ref.digest
    }

    /// Rename the session `ref` names (its trailing label; the date is preserved).
    func renameSession(_ ref: SessionRef, label: String, then: (@MainActor () -> Void)? = nil) {
        mutate(then: then) { project in
            try PMContract.perform("session.rename", PMContract.input(project: project) {
                Self.address(&$0, ref)
                $0.label = label
            })
        }
    }

    /// Delete the session `ref` names. Refused by the write itself if it still holds tasks.
    func deleteSession(_ ref: SessionRef) {
        mutate { project in
            try PMContract.perform("session.delete", PMContract.input(project: project) {
                Self.address(&$0, ref)
            })
        }
    }

    /// Replace the note of the session `ref` names — its whole body, task lines included and in place.
    func setSessionNote(_ ref: SessionRef, body: String, then: (@MainActor () -> Void)? = nil) {
        mutate(then: then) { try PmLib.setSessionNote(project: $0, session: ref, body: body) }
    }

    /// Append a task to the session `ref` names.
    func addTaskToSession(_ ref: SessionRef, text: String, due: String? = nil) {
        mutate { try PmLib.appendTaskToSession(project: $0, session: ref, text: text, due: due) }
    }

    // There are deliberately no `Int`-indexed forms of the four writes above.
    //
    // Every one of them used to take a bare session index, and each was a place where a number read at
    // one moment was applied to the document at another. `sessionRef(at:)` costs a caller nothing and
    // the reference it makes survives the splice that the index doesn't, so the positional form has no
    // remaining use here — and leaving it available is leaving the bug available. `SessionRef` still
    // carries an index for callers that genuinely have nothing else (the CLI's positional arguments);
    // this store is never one of them.

    /// Add prose to the current session's note, starting a session when there isn't one to continue —
    /// no session for today, or the project left alone past `PmLib.sessionIdleWindow`.
    ///
    /// Appending, not setting: `setSessionNote` replaces the session's whole body, so a line typed into
    /// the quick bar would silently swallow the note *and* the tasks the session already held. The note
    /// is a running log, and a second entry joins the end of the first.
    /// `then` runs after the re-read, which matters when the caller means to open the session next:
    /// this may have just started it, and asking for it against a stale document would make a second
    /// heading.
    func appendSessionNote(_ prose: String, then: (@MainActor () -> Void)? = nil) {
        mutate(then: then) { project in
            try PMContract.perform("session.note", PMContract.input(project: project) { $0.prose = prose })
        }
    }
}
