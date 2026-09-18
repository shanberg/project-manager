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
@Observable
final class PMStore {
    private(set) var projectKey: String?
    private(set) var projectName: String?
    /// Resolved project folder path, captured during reload (for Open in Finder etc.).
    private(set) var projectPath: String?

    /// Whether the thing this store is bound to is a project or an area.
    ///
    /// Derived from the folder name, like everywhere else, so it can't disagree with what the file on
    /// disk is. A store with nothing loaded reads as a project — that's what the app was before Areas
    /// existed, and `ProjectKind.of` would call an empty name an area.
    var kind: ProjectKind { projectName.map(ProjectKind.of(folderName:)) ?? .project }
    /// Resolved path to the focused project's notes file, captured during reload so the app can watch
    /// it without re-scanning the (protected) project directory on every UI update.
    private(set) var notesPath: String?
    /// The project's canvas, when it has one on disk. Nil is "not made yet", never "this project
    /// doesn't do canvases" — every project is assumed to want a board, so the header offers to make
    /// one rather than hiding itself. Re-resolved on every load so a canvas created in Obsidian while
    /// PM is open turns up without a restart.
    private(set) var canvasPath: String?
    /// Whether that answer has been *looked for* yet on this project.
    ///
    /// Nil `canvasPath` means two different things — "nobody has looked" and "looked, there isn't one"
    /// — and until this existed nothing could tell them apart, because resolution is an async hop off
    /// the load (see `refreshCanvasPath`). A window opening a project it remembers as a board has to:
    /// the first is worth holding still for a moment, the second is the empty state that offers to make
    /// one. See `ProjectWindowController.applyRememberedRenderer`, which flashed the task list for
    /// exactly as long as it could not ask this question.
    private(set) var hasResolvedCanvasPath = false
    private(set) var notes: ProjectNotes?
    /// The icon chosen in Project Settings, read from the notes' frontmatter at each load. Nil draws
    /// the progress ring.
    private(set) var icon: ProjectIcon?
    /// The colour chosen in Project Settings, from the same frontmatter — see `ProjectColor`.
    private(set) var color: ProjectColor?
    private(set) var todos: [Todo] = []
    /// Every standing pick that still resolves in this read: which older task was picked up into which
    /// sitting (docs/sessions.md D2). Each task also carries its latest one as `Todo.picked`.
    private(set) var picks: [TaskPick] = []
    /// What each distinct wait target on this project's tasks turns out to name, resolved once per
    /// load rather than once per row.
    ///
    /// A row asks this rather than resolving for itself because resolution walks every project folder
    /// name: per-row that's the folder list times the task list on every redraw, and a task list is
    /// redrawn on every keystroke in the note beside it. Keyed by the target string exactly as the
    /// task line spells it, which is what `Todo.effectiveWaiting` carries.
    private(set) var waitTargets: [String: WaitTarget] = [:]
    private(set) var focusedKey: String?
    /// When this project's notes file was last written, read at each reload. It's what tells a
    /// command whether it's continuing the current session or starting a new one — see
    /// `willStartNewSession` and `PmLib.sessionIdleWindow`.
    private(set) var lastEditedAt: Date?
    /// Why this project can't be read, if it can't. A read failure only — writes report themselves
    /// through `writeFailure` below.
    private(set) var errorMessage: String?

    /// A write that didn't happen, and why.
    ///
    /// Separate from `errorMessage` because the two have different shapes. `errorMessage` is state:
    /// something is wrong with the project, and a successful read clears it. A refused write is an
    /// event: the project is fine, and the reload that follows the refusal succeeds — which would wipe
    /// the sentence before anyone read it. So it carries a token instead, which surfaces watch to put
    /// the sentence up, and the quick bar compares to tell "the write I just made failed" from "a
    /// reload happened to fail while I was writing".
    struct WriteFailure: Equatable { let message: String; let token: Int }
    private(set) var writeFailure: WriteFailure?
    @ObservationIgnored
    private var writeFailures = 0
    /// True once the first successful load has painted; used to keep the last-good render across
    /// transient (cloud-sync) read failures instead of flashing to empty.
    private(set) var hasLoaded = false

    /// The most recent classified change of the focused task, paired with a monotonic token. Observers
    /// (the focused card, the menubar button) animate whenever the token advances, reading `focusMove`
    /// for the direction; a token that doesn't advance means nothing worth animating changed. The token
    /// — not `focusMove` alone — is the trigger, so two successive moves in the same direction still
    /// fire.
    private(set) var focusMove: FocusMove = .none
    private(set) var focusMoveToken: Int = 0

    /// Snapshot of the hero task from the last load, compared against the next load to classify the
    /// movement. Identity (`key`), `text`, `depth`, and document position (`session`/`line`) are all it
    /// takes to tell an edit from a dive-in / bubble-up / next / previous.
    private struct HeroSnapshot { let key: String; let text: String; let depth: Int; let session: Int; let line: Int }
    @ObservationIgnored
    private var heroSnapshot: HeroSnapshot?

    /// The shared scans, read straight through rather than copied in.
    ///
    /// These used to be stored properties kept in step with `ProjectIndex` by two Combine
    /// `assign(to:)` mirrors, because a view observing this store had no way to also be observing the
    /// index — `ObservableObject` invalidates on the object you subscribed to, so the value had to be
    /// physically present here to be noticed. Observation tracks through computed properties, so a
    /// view reading `store.allProjects` now registers a dependency on `ProjectIndex.allProjects`
    /// itself. The copies, the two subscriptions, and the window in which a store held a scan result
    /// one turn out of date all go away with them.
    var indexRecents: [Recent] { ProjectIndex.shared.recents }
    var allProjects: [ProjectEntry] { ProjectIndex.shared.allProjects }

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

    /// One ⌘Z: the whole gesture, which may have changed the document, the project's pick log, or both
    /// (docs/sessions.md D4). A focus that picked a task up is one step that puts the focus back *and*
    /// releases the pick; a tick that picked up reopens the task and releases it.
    struct UndoStep: Equatable {
        /// The bytes to restore, when the gesture changed the file.
        var document: DocSnapshot?
        /// What the gesture appended to the pick log: undo appends the events that cancel these, and
        /// the step it banks for redo carries the ones it appended.
        var picks: [PickEvent] = []
        /// What the Edit menu calls this step, when it has a name of its own — "Pick Up".
        var name: String?
    }

    /// Undo/redo history for in-app edits (move, complete, due, text, add, wrap, unwrap, pick up…).
    /// Coarse but reliable: each step restores the full prior document, and takes back what it picked up.
    /// Published so the menu/keyboard affordances can reflect availability; cleared on a project switch.
    private(set) var undoStack: [UndoStep] = []
    private(set) var redoStack: [UndoStep] = []
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    /// "Undo Pick Up", or plain "Undo" for a step without a name of its own.
    var undoMenuTitle: String { undoStack.last?.name.map { "Undo \($0)" } ?? "Undo" }
    var redoMenuTitle: String { redoStack.last?.name.map { "Redo \($0)" } ?? "Redo" }
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
    @ObservationIgnored
    private var wantsAllProjects = false

    /// The project this store shows. Every store is bound to exactly one project (nil = none, which
    /// renders the empty state) rather than following `focused.json`, so two windows can show two
    /// projects at once. Following the focus is the menubar's job: when `focused.json` changes it
    /// acquires the store for the new key, which means it shares one store — one undo stack, one
    /// `lastCompletedKey` — with any window already showing that project.
    /// Not observable: it was never `@Published`, and `bind(to:)` sets it and then reloads, so a
    /// view that cared would be repainted by the reload anyway.
    @ObservationIgnored
    private(set) var boundKey: String?

    /// Mirror the shared scans into this store's published state, so existing views that observe the
    /// store keep repainting when a scan lands.
    init(boundKey: String? = nil) {
        self.boundKey = boundKey
        // `recents` and `allProjects` are read through to the index rather than mirrored, so there is
        // nothing to keep in step. What a landing folder scan changes here is a *derived* value:
        // archiving the project a task waits on turns that wait from pending to released, and it
        // happens in a different window from the one showing the task. That still needs watching.
        waitRootsRelay = ObservationRelay(tracking: { _ = ProjectIndex.shared.waitRoots },
                                          then: { [weak self] in self?.resolveWaits() })
    }

    /// Bookkeeping, not state. `@Observable` instruments *every* stored `var`, so without this the
    /// store's private counters and its Combine bag would each invalidate every view reading the store
    /// — a regression `ObservableObject` could not have, because a property had to opt *in* with
    /// `@Published`. `PMStoreObservationTests` is what makes the omission fail rather than just cost.
    @ObservationIgnored
    private var cancellables = Set<AnyCancellable>()
    @ObservationIgnored
    private var waitRootsRelay: ObservationRelay?

    // MARK: What a non-SwiftUI observer follows

    /// The properties `AppDelegate.storeDidChange` depends on: each one's name, paired with a read of
    /// it. `trackForAppDelegate` runs the reads so an `ObservationRelay` watching this store is woken
    /// by them; `PMStoreObservationTests` checks the names against what the type actually has.
    ///
    /// **One list rather than a list and a matching method**, because two of those drift: adding a
    /// property to the names and forgetting the read would leave the app delegate deaf to it while
    /// every check still passed. Pairing them makes that arrangement unspellable.
    ///
    /// **It is deliberately all of them.** A SwiftUI view gets the benefit of `@Observable` for free —
    /// it depends on what it draws, and that is where the win of this migration is. The app delegate
    /// genuinely does not: one pass syncs notifications, refreshes the menubar glyph, renames every
    /// window, re-points the notes watches and reports a write failure, and between them those read
    /// most of this class. Narrowing the list by tracing which of them reads `waitTargets` would buy a
    /// few skipped passes and risk a menubar that stops updating for one kind of change — silent, and
    /// the bad trade.
    ///
    /// What this buys over `objectWillChange` is that the dependency is now written down, and a
    /// twenty-third property cannot be added without a decision being made about it.
    static let appDelegateDependencies: [(name: String, read: @MainActor (PMStore) -> Any)] = [
        ("projectKey", { $0.projectKey as Any }),
        ("projectName", { $0.projectName as Any }),
        ("projectPath", { $0.projectPath as Any }),
        ("notesPath", { $0.notesPath as Any }),
        ("canvasPath", { $0.canvasPath as Any }),
        ("hasResolvedCanvasPath", { $0.hasResolvedCanvasPath }),
        ("notes", { $0.notes as Any }),
        ("icon", { $0.icon as Any }),
        ("color", { $0.color as Any }),
        ("todos", { $0.todos }),
        ("picks", { $0.picks }),
        ("waitTargets", { $0.waitTargets }),
        ("focusedKey", { $0.focusedKey as Any }),
        ("lastEditedAt", { $0.lastEditedAt as Any }),
        ("errorMessage", { $0.errorMessage as Any }),
        ("writeFailure", { $0.writeFailure as Any }),
        ("hasLoaded", { $0.hasLoaded }),
        ("focusMove", { $0.focusMove }),
        ("focusMoveToken", { $0.focusMoveToken }),
        // Computed pass-throughs to `ProjectIndex` rather than stored properties, but reading one
        // inside `withObservationTracking` registers the index's property just the same — so the app
        // delegate is still woken by a folder scan, exactly as it was when these were mirrored in.
        ("indexRecents", { $0.indexRecents }),
        ("allProjects", { $0.allProjects }),
        ("undoStack", { $0.undoStack }),
        ("redoStack", { $0.redoStack }),
        ("lastCompletedKey", { $0.lastCompletedKey as Any }),
    ]

    /// Reads every dependency above, so that `withObservationTracking` registers them.
    func trackForAppDelegate() {
        for dependency in Self.appDelegateDependencies { _ = dependency.read(self) }
    }


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

    /// Completion progress as (done, total). Dropped tasks are out of both — see `[Todo].progress`.
    var progress: (done: Int, total: Int) { todos.progress }

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
            // Nothing to look for and nothing to wait on: there is no project here.
            hasResolvedCanvasPath = true
            notes = nil
            icon = nil
            color = nil
            todos = []
            picks = []
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
            let result = Result { () -> (NotesShowOutput, String, String, Date?, ProjectIcon?, ProjectColor?) in
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
                // Read the bytes here rather than through `notesShow(handle:)`, because the icon lives
                // in frontmatter the parsed notes don't carry — one read, handed to both.
                let raw = try handle.io.readContent(path: handle.notesPath)
                // With the folder, so the read carries the picks that live beside the notes.
                let output = try notesShow(rawText: raw, projectPath: handle.projectPath)
                Log.write("notesShow ok: todos=\(output.todos.count)")
                // Set here, on the IO queue, rather than beside the published state: a batch reads it
                // from the same queue, so it always sees the newest read that has actually finished.
                self?.seenRevision.value = output.revision
                // After the prune above, which is a write of our own — read before it, the file's
                // date would be the moment *this* load touched it rather than the last real edit.
                return (output, handle.notesPath, handle.projectPath, notesLastEdited(path: handle.notesPath),
                        projectIcon(rawText: raw), projectColor(rawText: raw))
            }
            if case .failure(let error) = result {
                let ns = error as NSError
                Log.write("reload FAILED: \(error) [domain=\(ns.domain) code=\(ns.code)]")
            }
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success(let (output, path, projectPath, lastEdited, icon, color)):
                    // Classify how the hero task moved since the last load, but never animate across a
                    // project switch (the two heroes are unrelated) — just reseat the snapshot.
                    let projectChanged = self.projectKey != key
                    if projectChanged { self.undoStack.removeAll(); self.redoStack.removeAll() }
                    // A different project's board is a different question, and the old answer must not
                    // be read as this one's while the new one is being looked for.
                    if projectChanged { self.hasResolvedCanvasPath = false }
                    self.projectKey = key
                    self.projectName = name
                    self.notesPath = path
                    self.projectPath = projectPath
                    self.notes = output.notes
                    self.icon = icon
                    self.color = color
                    self.todos = output.todos
                    self.picks = output.picks
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
                // After the path, so anything watching both sees the answer before it is told the
                // looking is over.
                self.hasResolvedCanvasPath = true
            }
        }
    }

    /// The project's board, made if it hasn't got one yet, handed back on the main actor.
    ///
    /// Creation is a side effect of asking for it, which is the whole point of the convention: a
    /// project is assumed to have a canvas, so opening one is never a two-step ceremony of "make it,
    /// then open it". Resolution happens again here rather than trusting `canvasPath`, because the
    /// published value is a snapshot and the answer to "should I write a file" deserves the live one.
    ///
    /// Says whether it *made* the board, which is to say whether this is a new project's.
    func openableCanvasPath(_ done: @escaping @MainActor (Result<OpenableCanvas, Error>) -> Void) {
        guard let projectPath else {
            // A window made a moment ago by the menu command itself: the store's first load is still in
            // flight, so there is no project folder to answer about yet. Wait for it rather than doing
            // nothing — a command that silently no-ops the first time you press it, and works the
            // second, is the kind of bug people stop reporting and start working around. `hasLoaded`
            // stops this at one retry: after a load, nil means there really is no project.
            //
            // And then it *says so*. This used to return without calling back at all, which was
            // survivable while the answer only decided whether a menu command did anything. It isn't
            // now: a project window's notes are a card on this board, so a caller left holding a
            // completion that never runs is a window waiting on a file for ever — see
            // `ProjectWindowController.ensureProjectCanvas`, whose in-flight latch would never clear.
            guard !hasLoaded else { return done(.failure(PmError.projectNotFound(projectName ?? ""))) }
            reload { [weak self] in self?.openableCanvasPath(done) }
            return
        }
        let notesPath = self.notesPath
        io.async { [weak self] in
            let result = Result { () -> OpenableCanvas in
                if let found = try resolveProjectCanvasPath(projectPath: projectPath) {
                    return OpenableCanvas(path: found, made: false)
                }
                return OpenableCanvas(path: try createProjectCanvas(projectPath: projectPath,
                                                                    notesPath: notesPath),
                                      made: true)
            }
            Task { @MainActor in
                if case .success(let canvas) = result, self?.projectPath == projectPath {
                    self?.canvasPath = canvas.path
                }
                done(result)
            }
        }
    }

    /// What `openableCanvasPath` found.
    struct OpenableCanvas {
        let path: String
        /// Whether the file was written just now rather than found.
        let made: Bool
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
        mutating(recordsUndo: recordsUndo, then: then) { project in
            try work(project)
            return []
        }
    }

    /// `mutate`, for a write that may also append to the project's pick log. `work` returns what it
    /// appended, and a step is banked when it appended anything — whatever `recordsUndo` says, because
    /// a focus that picked something up has done more than navigate (docs/sessions.md D4). That step
    /// carries the document too when the bytes moved, so undoing it takes back the whole gesture.
    private func mutating(recordsUndo: Bool = true, named stepName: String? = nil,
                          then: (@MainActor () -> Void)? = nil,
                          _ work: @escaping (String) throws -> [PickEvent]) {
        // **A completion is always called**, the rule `reload` states for its own: a caller waiting on
        // `then` — the quick bar's receipt, a surface giving a store back to the registry — is stranded
        // if it only runs when the write happened. With no project there is nothing to write to, and that
        // is a refused write like any other: reported, so a bar comparing failure tokens says so rather
        // than confirming, and then completed.
        guard let name = projectName else {
            noteWriteFailure("No project is open, so nothing was written.")
            then?()
            return
        }
        io.async { [weak self] in
            // Resolved once, for both snapshots. Resolving lists every PARA root, so it costs in proportion
            // to how many projects there are — measured at 0.8ms with 20 and 16ms with 1,000, against
            // 0.03ms to read the file itself — and it was most of what a tick spent outside the write.
            // Safe to share across `work` because nothing passed here moves a project folder: every
            // mutation is an edit inside the notes document. The reload that follows resolves again, which
            // keeps a folder moved from outside mid-write a thing the store recovers from.
            let handle = try? resolveNotesHandle(project: name)
            // Read even when this write doesn't record undo on its own account: whether it will is only
            // known once it has said whether it picked anything up.
            let before = handle.flatMap { try? Self.snapshot($0) }
            var picks: [PickEvent] = []
            do {
                picks = try work(name)
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
            let after = handle.flatMap { try? Self.snapshot($0) }
            if let after { self?.seenRevision.value = revision(of: after.raw) }
            let changed = before.flatMap { before in after.map { before.raw != $0.raw } } ?? false
            if !picks.isEmpty || (recordsUndo && changed) {
                let step = UndoStep(document: changed ? before : nil, picks: picks,
                                    name: picks.isEmpty ? nil : stepName)
                Task { @MainActor in self?.recordUndo(step) }
            }
            Task { @MainActor in self?.reload(then: then) }
        }
    }

    /// Read the current raw document behind an already-resolved handle, as a snapshot. Protected-folder
    /// IO — off-main only. Takes a handle rather than a project name so a caller that needs two reads,
    /// or a read and a write, pays for resolving the project once.
    private nonisolated static func snapshot(_ handle: NotesHandle) throws -> DocSnapshot {
        DocSnapshot(notesPath: handle.notesPath, raw: try handle.io.readContent(path: handle.notesPath))
    }

    /// Record a write that didn't happen. The token advances every time, so two identical refusals in
    /// a row still read as two — a banner that only watched the text would sit there looking stale.
    private func noteWriteFailure(_ message: String) {
        writeFailures += 1
        writeFailure = WriteFailure(message: message, token: writeFailures)
    }

    /// Push a step onto the undo stack (capped), invalidating any pending redo.
    private func recordUndo(_ step: UndoStep) {
        undoStack.append(step)
        if undoStack.count > maxHistory { undoStack.removeFirst(undoStack.count - maxHistory) }
        redoStack.removeAll()
    }

    /// Take back the most recent step, banking what it replaced for redo. No-op when empty.
    func undo() { restore(from: \.undoStack, to: \.redoStack) }

    /// Re-apply the most recently undone step, banking what it replaced for undo. No-op when empty.
    func redo() { restore(from: \.redoStack, to: \.undoStack) }

    /// Shared undo/redo primitive: pop a step off `source`, write its document back and append the
    /// events that cancel its picks, and bank the reverse onto `dest` so the move is reversible. Reload
    /// paints the restored state.
    ///
    /// **Document first, and all or nothing.** The picks are appended only once the document has been
    /// written: a restore that fails leaves the log alone and the step on the stack, because half an
    /// undo is worse than none.
    private func restore(from source: ReferenceWritableKeyPath<PMStore, [UndoStep]>,
                         to dest: ReferenceWritableKeyPath<PMStore, [UndoStep]>) {
        guard let name = projectName, let step = self[keyPath: source].last else { return }
        let projectPath = self.projectPath
        io.async { [weak self] in
            var banked: DocSnapshot?
            if let target = step.document {
                // One resolution for both the banked snapshot and the write, as in `mutate`. If it fails,
                // that is reported and nothing is written.
                let handle: NotesHandle
                do {
                    handle = try resolveNotesHandle(project: name)
                } catch {
                    let message = String(describing: error)
                    Task { @MainActor in self?.noteWriteFailure(message) }
                    return
                }
                banked = try? Self.snapshot(handle)
                do {
                    try handle.io.writeContent(path: handle.notesPath, content: target.raw)
                    self?.seenRevision.value = revision(of: target.raw)
                } catch {
                    let message = String(describing: error)
                    Task { @MainActor in self?.noteWriteFailure(message) }
                    return
                }
            }
            var appended: [PickEvent] = []
            if !step.picks.isEmpty, let projectPath {
                let cancelling = PickLog.reversing(step.picks, source: "app")
                do {
                    try PickLog.append(cancelling, projectPath: projectPath)
                    appended = cancelling
                } catch {
                    let message = PMContract.message(for: error)
                    Task { @MainActor in self?.noteWriteFailure(message) }
                }
            }
            Task { @MainActor in
                guard let self else { return }
                if !self[keyPath: source].isEmpty { self[keyPath: source].removeLast() }
                if banked != nil || !appended.isEmpty {
                    self[keyPath: dest].append(UndoStep(document: banked, picks: appended, name: step.name))
                }
                self.reload()
            }
        }
    }

    /// Key of the most recently completed task this session, for the menubar's ⌥ Undo alternate.
    private(set) var lastCompletedKey: String?

    /// The same task as the contract names it. Completing doesn't change a task's text, so the digest
    /// taken before the write still identifies it afterwards — which is what lets the undo find it
    /// even if the document has moved on since.
    @ObservationIgnored
    private var lastCompletedRef: TaskRefInput?

    /// `then` runs once the document has been re-read, like `addTodo`'s — it's what lets a caller that
    /// has already handed the keyboard back say whether the change actually landed.
    func complete(_ todo: Todo, advanceFocus: Bool = true, then: (@MainActor () -> Void)? = nil) {
        lastCompletedKey = Self.key(for: todo)
        lastCompletedRef = todo.reference
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        mutating(pickingUp: [todo], then: then) { project in
            try PMContract.perform(.taskComplete, PMContract.input(project: project, task: todo) {
                $0.advanceFocus = advanceFocus
            })
        }
    }

    /// Undo the most recent completion (re-open it and move focus back onto it).
    func undoLast(then: (@MainActor () -> Void)? = nil) {
        // Completed rather than reported: nothing to undo is not a refused write, and reporting it as
        // one would post a notification whenever the bar asked from the background.
        guard let reference = lastCompletedRef else { then?(); return }
        lastCompletedKey = nil
        lastCompletedRef = nil
        mutate(then: then) { project in
            var input = ApiInput()
            input.project = project
            input.task = reference
            try PMContract.perform(.taskReopen, input)
        }
    }

    func toggle(_ todo: Todo) {
        if todo.checked {
            undo(todo)
        } else {
            complete(todo, advanceFocus: true)
        }
    }

    /// Focus a task you chose — and, when it is from an older sitting, pick it up into the current
    /// one (docs/sessions.md D3).
    ///
    /// Focus is navigation, not a content edit, so on its own it stays out of the undo history. A focus
    /// that picked something up has done more than navigate, and is one step: ⌘Z puts the focus back
    /// and releases the pick, and the Edit menu calls it Undo Pick Up.
    func focus(_ todo: Todo, then: (@MainActor () -> Void)? = nil) {
        mutating(recordsUndo: false, named: "Pick Up", then: then) {
            try PMContract.perform(.taskFocus, PMContract.input(project: $0, task: todo)).sidecar ?? []
        }
    }

    /// Pick Up: take older tasks up into the current sitting without moving their lines. One step.
    func pickUp(_ todos: [Todo], then: (@MainActor () -> Void)? = nil) {
        guard !todos.isEmpty else { then?(); return }
        mutating(named: "Pick Up", then: then) { project in
            try PMContract.perform(.taskPick, Self.references(todos, project: project)).sidecar ?? []
        }
    }

    /// Put Back: take each task's latest pick back. The tasks aren't touched. One step.
    func putBack(_ todos: [Todo], then: (@MainActor () -> Void)? = nil) {
        guard !todos.isEmpty else { then?(); return }
        mutating(named: "Put Back", then: then) { project in
            try PMContract.perform(.taskRelease, Self.references(todos, project: project)).sidecar ?? []
        }
    }

    /// Whether Pick Up has something to do for `todo`: it is open, and neither written in the latest
    /// sitting nor already picked up into it. The contract has the last word — a project left long
    /// enough starts a new sitting, and then everything is older — but a menu item that says what it
    /// will usually do beats one that is always there.
    func canPickUp(_ todo: Todo) -> Bool {
        guard !todo.checked else { return false }
        guard !willStartNewSession, let current = todaySessionIndex else { return true }
        return todo.sessionIndex != current && !picks.contains {
            $0.sessionIndex == todo.sessionIndex && $0.lineIndex == todo.lineIndex && $0.intoIndex == current
        }
    }

    /// One task as `task`, several as `tasks` — the either-or every batchable action takes.
    private nonisolated static func references(_ todos: [Todo], project: String) -> ApiInput {
        PMContract.input(project: project) { input in
            if todos.count == 1 { input.task = todos[0].reference } else { input.tasks = todos.map(\.reference) }
        }
    }

    /// `mutate`, for a write that works on tasks — which picks them up into the current sitting first
    /// (docs/sessions.md D3: ticking or editing an old task is the clearest sign you worked on it now).
    ///
    /// The pick is never a reason to refuse the write: a task PM can't pick up is ticked all the same.
    /// And it is taken back if the write it came with is refused, because it only happened as part of
    /// that write. Both land in one step, so ⌘Z reopens the task and releases the pick together.
    private func mutating(pickingUp todos: [Todo], then: (@MainActor () -> Void)? = nil,
                          _ work: @escaping (String) throws -> Void) {
        let projectPath = self.projectPath
        mutating(then: then) { project in
            let picked = todos.isEmpty ? []
                : ((try? PMContract.perform(.taskPick, Self.references(todos, project: project)))?.sidecar ?? [])
            do {
                try work(project)
            } catch {
                if !picked.isEmpty, let projectPath {
                    try? PickLog.append(PickLog.reversing(picked, source: "app"), projectPath: projectPath)
                }
                throw error
            }
            return picked
        }
    }

    func undo(_ todo: Todo) {
        mutate { try PMContract.perform(.taskReopen, PMContract.input(project: $0, task: todo)) }
    }

    func setDue(_ todo: Todo, due: String?, then: (@MainActor () -> Void)? = nil) {
        mutating(pickingUp: [todo], then: then) { project in
            try PMContract.perform(.taskSetDue, PMContract.input(project: project, task: todo) {
                if let due { $0.due = due } else { $0.clearDue = true }
            })
        }
    }

    /// Set or clear what a task is waiting on.
    func setWaiting(_ todo: Todo, waiting: String?, then: (@MainActor () -> Void)? = nil) {
        mutating(pickingUp: [todo], then: then) { project in
            try PMContract.perform(.taskSetWaiting, PMContract.input(project: project, task: todo) {
                if let waiting { $0.waiting = waiting } else { $0.clearWaiting = true }
            })
        }
    }

    /// Replace a task's text in place (checkbox, due, focus, and indent preserved).
    func editText(_ todo: Todo, text: String) {
        mutating(pickingUp: [todo]) { project in
            try PMContract.perform(.taskSetText, PMContract.input(project: project, task: todo) {
                $0.text = text
            })
        }
    }

    /// Wrap a task in a new parent task, nesting the task (and its subtree) under it; focus stays put.
    func wrap(_ todo: Todo, parentText: String) {
        mutate { project in
            try PMContract.perform(.taskWrap, PMContract.input(project: project, task: todo) {
                $0.text = parentText
            })
        }
    }

    /// Dissolve a parent task: remove it and promote its children (with their subtrees) into its
    /// place. If the dissolved parent held focus, focus moves to its first child. Only meaningful for
    /// tasks with children — `hasChildren(_:)` gates the UI affordance. Inverse of `wrap`.
    func unwrap(_ todo: Todo) {
        mutate { try PMContract.perform(.taskUnwrap, PMContract.input(project: $0, task: todo)) }
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
        guard !block.isEmpty else { then?(); return }
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
            try PMContract.perform(.taskDelete, PMContract.input(project: project) {
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
        // Finishing old work picks it up; reopening it doesn't — you didn't work on it, you took back
        // saying you had.
        mutating(pickingUp: completing ? targets : []) { project in
            try PMContract.perform(completing ? .taskComplete : .taskReopen,
                                   PMContract.input(project: project) {
                $0.tasks = targets.map(\.reference)
                $0.revision = seen.value
                // `advanceFocus: false` — a batch shouldn't march focus once per task. The backend
                // still moves focus if one of the completed tasks was holding it.
                if completing { $0.advanceFocus = false }
            })
        }
    }

    /// Drop every open task in `todos`, with their open subtasks: closed, not done. One edit, one ⌘Z.
    ///
    /// Closed tasks in the selection are left alone rather than turned from done into dropped — a
    /// selection swept across an old session's leftovers takes its finished work along for the ride,
    /// and that work was done. Focus moves on from a lone dropped task the way it does from a
    /// completed one; a batch doesn't march it once per task, the same as `toggleAll`.
    func drop(_ todos: [Todo], then: (@MainActor () -> Void)? = nil) {
        let targets = todos.filter { !$0.checked }
        guard !targets.isEmpty else { then?(); return }
        let seen = seenRevision
        mutate(then: then) { project in
            try PMContract.perform(.taskDrop, PMContract.input(project: project) {
                $0.tasks = targets.map(\.reference)
                $0.revision = seen.value
                if targets.count > 1 { $0.advanceFocus = false }
            })
        }
    }

    /// Set (or clear, with `due == nil`) the due date on every task in `todos` as one edit.
    func setDueAll(_ todos: [Todo], due: String?) {
        guard !todos.isEmpty else { return }
        let seen = seenRevision
        mutate { project in
            try PMContract.perform(.taskSetDue, PMContract.input(project: project) {
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
            try PMContract.perform(.taskAdd, PMContract.input(project: project) { input in
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
    ///
    /// `then` is given nil when no session could be opened — no project, or a start that didn't land —
    /// rather than not being called, which left the quick bar waiting on a receipt that never came.
    ///
    /// `forcingNew` is ⌥ New Session: a new sitting even inside the window, unless today's newest is still
    /// empty — see `PmLib.currentSessionPreservingFormat` and docs/tile-sessions.md D1.
    func openCurrentSession(forcingNew: Bool = false, then: @escaping @MainActor (Int?) -> Void) {
        if !forcingNew, let index = todaySessionIndex, !willStartNewSession {
            then(index)
            return
        }
        mutate(then: { [weak self] in
            then(self?.todaySessionIndex)
        }) { try PMContract.perform(.sessionStart, PMContract.input(project: $0) { $0.new = forcingNew ? true : nil }) }
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
            try PMContract.perform(.sessionRename, PMContract.input(project: project) {
                Self.address(&$0, ref)
                $0.label = label
            })
        }
    }

    /// Delete the session `ref` names. Refused by the write itself if it still holds tasks.
    func deleteSession(_ ref: SessionRef) {
        mutate { project in
            try PMContract.perform(.sessionDelete, PMContract.input(project: project) {
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
            try PMContract.perform(.sessionNote, PMContract.input(project: project) { $0.prose = prose })
        }
    }
}
