import AppKit
import PmLib
import SwiftUI

/// The quick bar's window: summon, place, dismiss.
///
/// A `KeyablePanel` like the focus panel, and for the same reason — it has to take the keyboard from
/// whatever app you were in without activating PM, so dismissing it leaves you back in that app with
/// your insertion point where you left it. Everything else is the opposite of the focus panel's
/// chrome: no snapping, no remembered position, no pinning. A bar you summon appears where you're
/// looking and leaves the moment you're done, so it's centred on the active screen every time.
@MainActor
final class QuickBarController: NSObject, NSWindowDelegate {
    static let shared = QuickBarController()

    private var panel: KeyablePanel?
    private var hosting: NSHostingController<QuickBarView>?
    private let model = QuickBarModel()
    /// A hide waiting out a transient loss of key focus; cancelled if the keyboard comes back.
    private var pendingHide: DispatchWorkItem?
    /// A receipt on screen, waiting out its dwell before the bar fades. Cancelled by a new summon.
    private var pendingDismiss: DispatchWorkItem?
    /// Whether a row is mid-flight: run, but not yet landed. A second ⏎ in that window would write the
    /// line twice, and the field still has the keyboard until the receipt replaces it.
    private var isRunning = false
    /// The app that was in front when the bar was summoned, so dismissing it can put you back there.
    private var previousApp: NSRunningApplication?
    /// Whether the full project list is currently retained for the bar (its scan is gated).
    private var holdsProjectIndex = false
    /// Watches ⌥ while the bar is up, so a row's label can flip under it. Installed on summon and
    /// removed on dismiss — there's nothing to watch when the bar isn't taking keystrokes.
    private var flagsMonitor: Any?
    /// The capture line the bar was last closed on without running anything, and when.
    ///
    /// Escape already takes two presses so that a half-typed sentence isn't lost to one — but every
    /// other way out threw it away just as completely: clicking into another window, pressing the
    /// hotkey again, or letting the blur timer fire. Those are the same loss, and this is the same
    /// answer, offered as a row on the next summon rather than typed back into the field.
    private var stashedLine: String?
    private var stashedAt: Date = .distantPast

    private override init() {
        super.init()
        model.onRun = { [weak self] row, modifiers in self?.run(row, modifiers: modifiers) }
        model.onDismiss = { [weak self] in self?.hide() }
        model.dryRun = { [weak self] command, argument in self?.dryRun(command, argument: argument) }
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    // MARK: Presentation

    /// Summon in a mode. Summoning the mode that's already up dismisses it — a toggle, since the same
    /// key brought it here.
    func toggle(mode: QuickBarMode) {
        if isVisible, model.mode == mode { hide() } else { show(mode: mode) }
    }

    func show(mode: QuickBarMode) {
        // Recorded before anything happens: the bar is meant to take the keyboard *without* bringing
        // PM forward, so whether the app was already active is the only way to tell a summon that
        // behaved from one that activated the app behind your back.
        let wasActive = NSApp.isActive
        pendingHide?.cancel()
        pendingHide = nil
        pendingDismiss?.cancel()
        pendingDismiss = nil
        isRunning = false
        // Off until the bar is on screen: the view and the model both outlive the panel being ordered
        // out, so a new summon's first layout would otherwise animate away from what the last one left.
        model.animatesLayout = false
        // Remember where you came from before anything moves, so dismissing can hand focus back.
        if !wasActive { previousApp = NSWorkspace.shared.frontmostApplication }
        seed(mode: mode)
        let panel = ensurePanel()
        rebuildContent()
        panel.contentView?.layoutSubtreeIfNeeded()
        position(panel)

        // A summon that interrupts a fading receipt gets a whole panel back, not the tail of one.
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        // The bar is nothing but a text field; every path here is a request to type into it.
        panel.takeKey()
        assertKeyOnceSettled(panel)
        // After this turn of the run loop, which is the one the first layout's fit arrives on.
        DispatchQueue.main.async { [weak self] in self?.model.animatesLayout = true }
        installFlagsMonitor()
        Log.write("quick bar shown: mode=\(mode) anchor=\(model.focusedTaskText ?? "none") frame=\(panel.frame) key=\(panel.isKeyWindow) appActive=\(wasActive)->\(NSApp.isActive)")
    }

    /// Dismiss the bar, handing the front back to whatever app it was taken from.
    ///
    /// `restoringFocus: false` is for the one command that means "go to PM" — opening a project window.
    /// Everything else (a task captured, Escape, clicking away) is something you did *while* working
    /// somewhere else, so the last step is putting you back in it.
    /// Ask for the keyboard once more shortly after summoning, if it didn't stick.
    ///
    /// Belt and braces around a window-server handoff this code doesn't control: ordering a window in
    /// and making it key are separate operations, and a panel that comes up without the keyboard is
    /// useless rather than merely untidy. One retry, so a genuine refusal isn't turned into a loop.
    private func assertKeyOnceSettled(_ panel: KeyablePanel) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, self.isVisible, !panel.isKeyWindow else { return }
            Log.write("quick bar re-taking key")
            self.pendingHide?.cancel()
            self.pendingHide = nil
            panel.takeKey()
        }
    }

    /// Follow ⌥ for as long as the bar is up.
    ///
    /// Only the labels want this: holding ⌥ turns "Add after" into "Add before" the moment the key
    /// goes down, the same live flip the menubar's alternate item does. Running a row doesn't consult
    /// it — that reads the modifiers off the keystroke that ran it, which is the authoritative answer
    /// at the only instant it matters.
    private func installFlagsMonitor() {
        guard flagsMonitor == nil else { return }
        // Read once, up front. A flags monitor only ever hears about a *change*, so a bar summoned
        // with ⌥ already held — which is most of the times anyone holds it, since the point is to see
        // the alternate — showed "Add after" until the key was released. The first answer has to come
        // from the keyboard's current state rather than from the next thing that happens to it.
        model.optionDown = NSEvent.modifierFlags.contains(.option)
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.model.optionDown = event.modifierFlags.contains(.option)
            return event
        }
    }

    private func removeFlagsMonitor() {
        if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
        flagsMonitor = nil
        model.optionDown = false
    }

    func hide(restoringFocus: Bool = true) {
        stashUnsentLine()
        pendingHide?.cancel()
        pendingHide = nil
        pendingDismiss?.cancel()
        pendingDismiss = nil
        isRunning = false
        model.receipt = nil
        model.animatesLayout = false
        removeFlagsMonitor()
        let previous = previousApp
        previousApp = nil
        guard let panel, panel.isVisible else { return }
        Log.write("quick bar hidden")
        panel.orderOut(nil)
        releaseProjectIndex()
        // Only when PM is still the active app: if you've already clicked into something else, that
        // click is a more recent answer to "where should the focus be" than this is.
        if restoringFocus, NSApp.isActive, let previous, !previous.isTerminated {
            previous.activate()
        }
    }

    /// Keep a capture line the bar is about to close on, so the next summon can offer it back.
    ///
    /// Only a line that nothing was done with. A row mid-flight (`isRunning`) is about to write this
    /// text somewhere, and a receipt on screen means it already has — offering either back would be
    /// the bar proposing to write the same task twice.
    private func stashUnsentLine() {
        // `isVisible` as well as the rest: `hide()` is idempotent and gets called more than once on
        // some paths, and the second call arrives after a receipt has been cleared but before the next
        // summon has emptied the field — which is a line that was already written, offered back.
        guard isVisible, model.receipt == nil, !isRunning, model.mode == .capture else { return }
        let line = model.reading.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return }
        stashedLine = model.query
        stashedAt = Date()
    }

    /// Hand the front back to the app the bar was summoned over, leaving the bar itself on screen.
    ///
    /// Split out of `hide` for the receipt. The point of giving focus back is that you carry on typing
    /// where you were, and making that wait on a line of text being read would spend the very thing
    /// the bar exists to protect. So the front goes back first, and what's left on screen is a receipt
    /// rather than anything you have to deal with.
    private func yieldFocus() {
        let previous = previousApp
        previousApp = nil
        // Only when PM is still the active app: if you've already clicked into something else, that
        // click is a more recent answer to "where should the focus be" than this is.
        guard NSApp.isActive, let previous, !previous.isTerminated else { return }
        previous.activate()
    }

    /// Say what just happened, then take the bar off screen on its own.
    ///
    /// The bar's promise is that you can type a thing into it and go straight back to what you were
    /// doing. It kept the second half and dropped the first: the panel vanished and left no evidence
    /// the task existed, which is a promise you end up checking by hand. This is the evidence. It's
    /// deliberately not a dialog — the keyboard has already gone back, nothing is waiting on you, and
    /// it can therefore afford to stay up long enough to actually be read.
    private func confirm(_ receipt: QuickBarReceipt) {
        // Cleared first: a bar that has already gone still has to stop counting the row as in flight,
        // or the next summon inherits a field that won't run anything.
        isRunning = false
        guard let panel, panel.isVisible else { return }
        pendingHide?.cancel()
        pendingHide = nil
        removeFlagsMonitor()
        yieldFocus()
        panel.acceptsKey = false
        model.receipt = receipt
        Log.write("quick bar receipt\(receipt.isFailure ? " (failed)" : ""): \(receipt.spoken)")
        let work = DispatchWorkItem { [weak self] in self?.fadeOut() }
        pendingDismiss = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.dwell(for: receipt), execute: work)
    }

    /// Fade the receipt out rather than cutting it. The summon is instant on purpose — see
    /// `animationBehavior` below — but nothing is racing for the keyboard on the way out.
    private func fadeOut() {
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.receiptFade
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            // The front went back when the receipt went up, so there's nothing left to restore.
            self?.hide(restoringFocus: false)
            self?.panel?.alphaValue = 1
        }
    }

    /// Show a receipt for a write that landed — and none for one that didn't.
    ///
    /// `errorBefore` is what the store last complained about *before* this write. A different complaint
    /// after it means this is the write that failed, and the failure notification is already saying so;
    /// a receipt on top of that would be the bar claiming the opposite of the truth in a second place.
    private func settle(_ message: String, failure: String, store: PMStore, errorBefore: String?) {
        guard store.errorMessage == errorBefore else {
            confirm(.failed(failure, store.errorMessage))
            return
        }
        confirm(.done(message))
    }

    /// How long a receipt stays up.
    ///
    /// Scaled to what it says, because a fixed dwell is only ever right for one length of sentence.
    /// "Added to today's session" and "Added under “review the Q3 numbers with Dana before…”" were
    /// given the same three-quarters of a second, and you are reading both out of the corner of your
    /// eye while typing somewhere else — so the long one went before it had been read.
    ///
    /// A failure gets its own, longer floor. It says something you didn't expect, it carries the
    /// store's complaint underneath it, and unlike a success there is something you'll want to do
    /// about it — so it has to survive being noticed before it can be read.
    private static func dwell(for receipt: QuickBarReceipt) -> TimeInterval {
        let reading = Double(receipt.spoken.count) * perCharacterDwell
        return receipt.isFailure
            ? min(maxFailureDwell, minFailureDwell + reading)
            : min(maxReceiptDwell, minReceiptDwell + reading)
    }

    /// The floor, the ceiling and the rate between them. The rate is roughly a fast silent read of a
    /// line you already half expect, which is what a receipt for a thing you just asked for is.
    private static let minReceiptDwell: TimeInterval = 0.75
    private static let maxReceiptDwell: TimeInterval = 1.9
    private static let minFailureDwell: TimeInterval = 2.0
    private static let maxFailureDwell: TimeInterval = 4.5
    private static let perCharacterDwell: TimeInterval = 0.028

    /// How long a receipt takes to go.
    private static let receiptFade: TimeInterval = 0.18

    /// Fill in what the rows are built from, fresh each summon: the focused project may have moved and
    /// the project lists may have been rescanned since last time.
    private func seed(mode: QuickBarMode) {
        retainProjectIndex()
        let index = ProjectIndex.shared
        index.warmRecents()
        index.warmAllProjects()
        model.recents = index.recents
        model.allProjects = index.allProjects
        refreshContext()
        model.allTasks = searchableTasks(from: index)
        // Only capture lines are worth catching, and only for a while: a sentence you abandoned ten
        // minutes ago is not what you summoned the bar for now. Only offered back in the mode it was
        // typed in, since a `>` or `@` line is a query you threw away on purpose.
        model.restorable = mode == .capture && Date().timeIntervalSince(stashedAt) < Self.stashLifetime
            ? stashedLine : nil
        model.reset(mode: mode)
    }

    /// Every open task the `/` mode can search.
    ///
    /// The index's copy of every project, with the focused project's own tasks read live over the top.
    /// The index is warmed on a TTL and in the background, so its idea of the project you're standing
    /// in can be half a minute out of date — which is exactly the project whose tasks you are most
    /// likely to go looking for, and exactly the window in which you'd be looking for the one you just
    /// added. The loaded store always knows.
    private func searchableTasks(from index: ProjectIndex) -> [ProjectIndex.TaskEntry] {
        guard let store = focusedStore, let key = store.projectKey, let name = store.projectName else {
            return index.openTasks
        }
        let isArchived = focusedProjectScope == .archive
        let short = QuickBarModel.shortName(of: name)
        let live = store.openTodos.compactMap { todo -> ProjectIndex.TaskEntry? in
            let text = todo.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return ProjectIndex.TaskEntry(
                projectKey: key, projectName: name, projectShortName: short, isArchived: isArchived,
                text: text, due: todo.dueDate ?? todo.effectiveDueDate, isFocused: todo.isFocused,
                sessionIndex: todo.sessionIndex, lineIndex: todo.lineIndex)
        }
        return live + index.openTasks.filter { $0.projectKey != key }
    }

    /// How long an abandoned capture line stays on offer. Long enough to cover going to look something
    /// up and coming back; short enough that it's never a line you'd forgotten you typed.
    private static let stashLifetime: TimeInterval = 120

    /// Re-read everything about the focused project that the rows name.
    ///
    /// Called on every summon and again whenever the focused store changes while the bar is up. The
    /// bar can sit open for as long as you leave it, and the focus can move under it — a window, the
    /// menubar, a notification's Complete button, the CLI. Running a row already re-resolves the
    /// anchor, deliberately, so without this a row could go on saying "Narrow under X" while ⏎ put the
    /// task under Y. Naming the wrong task is worse than naming none.
    func refreshContext() {
        model.focusedProjectName = PMFiles.focusedProjectKey().flatMap { PMFiles.projectName(fromKey: $0) }
        model.focusedProjectKey = focusedStore?.projectKey
        model.anchor = anchorTask.map(Self.preview)
        // The whole session, for the preview to draw a window of. Already in memory: this is the same
        // `todos` the menubar and any open window are rendering, so it costs a copy and no read.
        model.projectTodos = focusedStore?.todos.map(Self.preview) ?? []
        model.sessions = focusedStore?.notes?.sessions.map {
            PreviewSession(date: $0.date, label: $0.label)
        } ?? []
        model.todaySession = focusedStore?.todaySessionIndex
        model.todayNote = focusedStore?.todaySessionIndex.flatMap { index in
            focusedStore?.notes?.sessions[index].body
        }.map { leadingSessionProse(body: $0) }
        model.canUndoCompletion = focusedStore?.lastCompletedKey != nil
        model.hasNextTask = focusedStore?.nextTodo != nil
        model.focusedProjectIsArchived = focusedProjectScope == .archive
    }

    /// The focused project's store changed. Only of interest while the bar is on screen — the rest of
    /// the time the next summon reads it fresh anyway.
    ///
    /// Driven from the delegate's own store subscription rather than from one of our own, because the
    /// delegate re-points that subscription when the *focused project* changes. A subscription held
    /// here would go on watching a store nothing is looking at any more.
    func focusedStoreChanged() {
        guard isVisible else { return }
        refreshContext()
    }

    /// The full-project scan runs only while something wants it. The bar wants it while it's up, and
    /// not a moment longer — this is the same retain the project sidebar uses.
    private func retainProjectIndex() {
        guard !holdsProjectIndex else { return }
        holdsProjectIndex = true
        ProjectIndex.shared.retain()
    }

    private func releaseProjectIndex() {
        guard holdsProjectIndex else { return }
        holdsProjectIndex = false
        ProjectIndex.shared.release()
    }

    // MARK: The focused project

    /// A task as the preview draws it. Five fields and two indices, so the model never holds the
    /// store's own value type.
    private static func preview(_ todo: Todo) -> PreviewTodo {
        PreviewTodo(text: todo.text.trimmingCharacters(in: .whitespacesAndNewlines),
                    depth: todo.depth, checked: todo.checked, isFocused: todo.isFocused,
                    due: todo.dueDate ?? todo.effectiveDueDate,
                    sessionIndex: todo.sessionIndex, lineIndex: todo.lineIndex)
    }

    /// The store the bar writes to: the delegate's, which follows `focused.json` and is the *same*
    /// instance the menubar and any window on that project are showing — so a captured task appears
    /// everywhere at once, under one undo history.
    ///
    /// Taken from the delegate rather than acquired from `StoreRegistry` on the spot because this one
    /// is already loaded. A freshly acquired store reloads asynchronously, so its task list is empty
    /// for the first moments — exactly the moments the bar is being seeded and drawn.
    private var focusedStore: PMStore? {
        guard let store = (NSApp.delegate as? AppDelegate)?.store, store.projectName != nil else {
            return nil
        }
        return store
    }

    /// The task a relative placement acts on: the focused one, or the first open task when the project
    /// has no explicit focus. The same fallback every other surface uses, so "narrow" always has a
    /// target in a project you haven't focused anything in yet.
    private var anchorTask: Todo? {
        guard let store = focusedStore else { return nil }
        return store.focusedTodo ?? store.openTodos.first
    }

    /// Which folder the focused project is in. Read off its key, which names the folder it was found
    /// in, rather than by looking on disk.
    private var focusedProjectScope: ProjectScope? {
        guard let key = focusedStore?.projectKey, let paths = try? loadConfigAndPaths().1 else {
            return nil
        }
        return key.hasPrefix("\(paths.archivePath):") ? .archive : .active
    }

    // MARK: Running a row

    /// Run a row.
    ///
    /// ⌘ means one thing on every row: *and show me*. A plain ⏎ does the thing and gives you back the
    /// app you were in — which is what this bar is for, summoned over your work and gone again. ⌘⏎ does
    /// the same thing and then puts PM in front of the result: the focus panel on the task, the window
    /// on the session, the project you just switched to.
    ///
    /// Some commands have no version of themselves that stays out of your way — Settings, a rename
    /// prompt — and those come forward either way. Nothing else does.
    private func run(_ row: QuickBarRow, modifiers: EventModifiers) {
        // Nothing runs while a receipt is up, or while the row before it is still landing: the field
        // keeps the keyboard right until the receipt replaces it, and a second ⏎ in that gap is how one
        // typed line becomes two tasks.
        guard model.receipt == nil, !isRunning else { return }
        let reveal = modifiers.contains(.command)
        switch row {
        case .capture(let placement, let text, let due, _, let target):
            // The rows are on screen before anything's been typed, to show where a line would go. They
            // are a preview until there's a line to put anywhere.
            guard !text.isEmpty else { return }
            isRunning = true
            if let target {
                captureToTarget(target, placement: placement, text: text, due: due, reveal: reveal)
                return
            }
            guard let store = focusedStore else {
                isRunning = false
                return
            }
            // Only the reveal leaves now: it's about to put PM in front of the answer, so there's
            // nothing for a receipt to tell you. The other path keeps the bar up until the write lands,
            // so what it says afterwards is something that happened rather than something intended.
            if reveal { hide(restoringFocus: false) }
            apply(placement, text: text, due: due, in: store, modifiers: modifiers, reveal: reveal)

        case .command(let command, let argument):
            perform(command, argument: argument, reveal: reveal)

        case .project(let key, let name, _, _, _):
            PMStore.setGlobalFocus(key: key)
            Log.write("quick bar focused \(name)\(reveal ? " and opened it" : "")")
            hide(restoringFocus: !reveal)
            if reveal { WindowManager.shared.open(projectKey: key) }

        case .task(let entry):
            goTo(entry, reveal: reveal)

        case .action(let action):
            perform(action)
        }
    }

    // MARK: Ways out of an empty list

    /// Run one of the rows that stand in for an empty list.
    ///
    /// Three of the four leave the bar up, because what they do *is* changing what the bar is showing
    /// — you asked for a way to carry on, not a way to leave. Only New Project has an answer of its
    /// own to put in front of you.
    private func perform(_ action: QuickBarAction) {
        Log.write("quick bar action: \(action.id)")
        switch action {
        case .findProject:
            model.switchTo(.goToProject, text: "")
        case .captureHere(let text), .restore(let text):
            // Spent on the way past. The line is in the field now, so if it's abandoned again it will
            // be stashed again — but a line that was picked up and *written* must never come back on
            // the next summon offering to write itself a second time.
            stashedLine = nil
            model.switchTo(.capture, text: text)
        case .newProject:
            hide(restoringFocus: false)
            ProjectPrompts.newProject { key in WindowManager.shared.open(projectKey: key) }
        }
    }

    // MARK: Going to a task

    /// Move PM's focus onto a task found by search, wherever it lives.
    ///
    /// The index the search ran against is a snapshot, so the project is re-read before anything is
    /// written: what's stored is a task's text and where it was, and where it was is the weaker of the
    /// two — every add or completion above a line renumbers it. See `locate(_:in:)`.
    private func goTo(_ entry: ProjectIndex.TaskEntry, reveal: Bool) {
        isRunning = true
        let there = QuickBarModel.display(entry.projectName, short: entry.projectShortName)
        // Already in this project, and its store is loaded and current — nothing to re-read.
        if let store = focusedStore, store.projectKey == entry.projectKey {
            focus(entry, in: store, named: nil, reveal: reveal)
            return
        }
        let key = entry.projectKey
        let store = StoreRegistry.shared.acquire(key)
        store.reload { [weak self] in
            guard let self else { return }
            guard store.projectName != nil else {
                StoreRegistry.shared.release(key)
                Log.write("quick bar couldn't load \(entry.projectName) to focus a task")
                self.confirm(.failed("Couldn't open \(there)", store.errorMessage))
                return
            }
            // Named in the receipt, because this one moved you: the task you asked for was somewhere
            // other than where you were, and which project it turned out to be in is the fact you
            // didn't already have.
            self.focus(entry, in: store, named: there, reveal: reveal) {
                StoreRegistry.shared.release(key)
            }
        }
    }

    /// Write the focus onto `entry`'s task and say so.
    private func focus(_ entry: ProjectIndex.TaskEntry, in store: PMStore, named there: String?,
                       reveal: Bool, then release: (@MainActor () -> Void)? = nil) {
        guard let todo = locate(entry, in: store) else {
            release?()
            // Completed, edited or deleted since the scan. Saying so is the whole value of the answer
            // — the alternative is a bar that closes on nothing and leaves you wondering whether it
            // moved the focus somewhere you weren't looking.
            confirm(.failed("“\(QuickBarModel.truncate(entry.text, 44))” isn't open any more", nil))
            return
        }
        let errorBefore = store.errorMessage
        let named = QuickBarModel.truncate(todo.text, 44)
        store.focus(todo) { [weak self] in
            defer { release?() }
            guard let self else { return }
            // The project's focus is written into its own notes file; this is what points PM at that
            // file. In this order, so the app arrives at a project already focused on the right line.
            if store.projectKey != self.focusedStore?.projectKey {
                PMStore.setGlobalFocus(key: entry.projectKey)
            }
            guard !reveal else {
                self.hide(restoringFocus: false)
                FocusPanelController.shared.show()
                return
            }
            let where_ = there.map { " in \($0)" } ?? ""
            self.settle("Focused “\(named)”\(where_)",
                        failure: "Couldn't focus “\(named)”\(where_)",
                        store: store, errorBefore: errorBefore)
        }
    }

    /// Find the task an index entry describes in a freshly-read store.
    ///
    /// By text first, then by position. The text is what you searched for and what the row showed you,
    /// so a line that still reads the same is the same task; the coordinates only break the tie when a
    /// project has two open tasks worded identically, and then the one nearest where the scan saw it is
    /// the one meant. Nil when nothing matches, which is a real answer: the task was completed or
    /// re-worded between the scan and the keystroke.
    private func locate(_ entry: ProjectIndex.TaskEntry, in store: PMStore) -> Todo? {
        let candidates = store.openTodos.filter {
            $0.text.trimmingCharacters(in: .whitespacesAndNewlines) == entry.text
        }
        if let exact = candidates.first(where: {
            $0.sessionIndex == entry.sessionIndex && $0.lineIndex == entry.lineIndex
        }) { return exact }
        return candidates.min { distance($0, from: entry) < distance($1, from: entry) }
    }

    /// How far a task is from where the scan last saw it. A different session counts as further than
    /// any distance within one, since sessions are the coarser move.
    private func distance(_ todo: Todo, from entry: ProjectIndex.TaskEntry) -> Int {
        abs(todo.sessionIndex - entry.sessionIndex) * 10_000 + abs(todo.lineIndex - entry.lineIndex)
    }

    /// Write a captured line where the chosen row said it would go, and — with `reveal` — show it.
    private func apply(_ placement: CapturePlacement, text: String, due: String?,
                       in store: PMStore, modifiers: EventModifiers, reveal: Bool) {
        Log.write("quick bar \(placement.rawValue)\(reveal ? " (reveal)" : ""): \(text)\(due.map { " due:\($0)" } ?? "")")
        let optionDown = modifiers.contains(.option)
        let errorBefore = store.errorMessage
        switch placement {
        case .narrow, .after:
            // Resolved now rather than held from the summon. The anchor is a value snapshot carrying
            // line coordinates, and the bar can sit open while a window or the menubar moves the focus
            // or edits the file underneath it — acting on stale coordinates would put the task on the
            // wrong line. Every other surface acts on the project's current focus too.
            guard let anchor = anchorTask else {
                hide()
                return
            }
            let position: TaskInsertPosition = placement == .narrow
                ? .child
                : (optionDown ? .before : .after)
            store.addTodo(text: text, due: due, relativeTo: anchor, position: position) { [weak self] in
                guard reveal else {
                    // Named from the anchor the write actually used, not from the row's label, which
                    // was written before that anchor was re-resolved.
                    self?.settle(placement.confirmation(anchor: anchor.text, optionDown: optionDown),
                                 failure: placement.failure(anchor: anchor.text, optionDown: optionDown),
                                 store: store, errorBefore: errorBefore)
                    return
                }
                // A child insert moves the project's focus onto the new task by itself — that is what
                // narrowing means — so the panel is already pointing at it. A sibling doesn't, so a
                // request to be shown the new task has to move the focus there first.
                if position != .child { self?.focusAdded(text: text, near: anchor, in: store) }
                FocusPanelController.shared.show()
            }
        case .sessionEnd:
            // The unanchored add appends to today's session and takes focus, so the panel lands on it.
            store.addTodo(text: text, due: due) { [weak self] in
                guard reveal else {
                    self?.settle(placement.confirmation(anchor: nil, optionDown: optionDown),
                                 failure: placement.failure(anchor: nil, optionDown: optionDown),
                                 store: store, errorBefore: errorBefore)
                    return
                }
                FocusPanelController.shared.show()
            }
        case .sessionNote:
            store.appendSessionNote(text) { [weak self] in
                guard reveal else {
                    self?.settle(placement.confirmation(anchor: nil, optionDown: optionDown),
                                 failure: placement.failure(anchor: nil, optionDown: optionDown),
                                 store: store, errorBefore: errorBefore)
                    return
                }
                WindowManager.shared.openFocusedProject().newSession(nil)
            }
        }
    }

    /// Write a captured line into a project other than the one in focus — what a trailing `@…` asks
    /// for, and the reason the bar no longer needs two summons to file something somewhere else.
    ///
    /// The target's store is acquired for the length of the write and released after. It may not be
    /// loaded yet — `StoreRegistry.acquire` reads it asynchronously, and `PMStore` refuses to mutate
    /// until it knows its project's name — so the write is chained off a reload rather than fired at a
    /// store that would quietly drop it on the floor.
    ///
    /// Only the two unanchored placements ever get here; see `QuickBarModel.isOffered`. There is no
    /// task in this project for the bar to be relative to, and it won't name one it hasn't read.
    private func captureToTarget(_ target: CaptureTarget, placement: CapturePlacement,
                                 text: String, due: String?, reveal: Bool) {
        Log.write("quick bar \(placement.rawValue) into \(target.name)\(reveal ? " (reveal)" : ""): \(text)\(due.map { " due:\($0)" } ?? "")")
        let key = target.key
        let store = StoreRegistry.shared.acquire(key)
        store.reload {
            // A project that wouldn't load has no name, and a mutation against one silently does
            // nothing and never calls back. Stop here rather than leaving the bar waiting on it.
            guard store.projectName != nil else {
                StoreRegistry.shared.release(key)
                Log.write("quick bar redirect failed to load \(target.name)")
                // The line is still in the field behind this receipt, and the bar stashes it on the
                // way out — so a project that wouldn't open costs you the trip, not the sentence.
                self.confirm(.failed("Couldn't open \(target.displayName)", store.errorMessage))
                return
            }
            let errorBefore = store.errorMessage
            let landed: @MainActor () -> Void = {
                defer { StoreRegistry.shared.release(key) }
                guard reveal else {
                    let what = placement.confirmation(anchor: nil, optionDown: false)
                    let failed = placement.failure(anchor: nil, optionDown: false)
                    self.settle("\(what) in \(target.displayName)",
                                failure: "\(failed) in \(target.displayName)",
                                store: store, errorBefore: errorBefore)
                    return
                }
                // "And show me" across a redirect means going there: what you just wrote is in a
                // project you aren't in, so the only useful answer is to be in it.
                self.hide(restoringFocus: false)
                PMStore.setGlobalFocus(key: key)
                WindowManager.shared.open(projectKey: key)
            }
            switch placement {
            case .sessionNote: store.appendSessionNote(text, then: landed)
            default: store.addTodo(text: text, due: due, then: landed)
            }
        }
    }

    /// Move the project's focus onto a task that was just written beside `anchor`.
    ///
    /// Found by its text within the anchor's session rather than by a line index, because the insert
    /// has renumbered every line after it. Two open tasks with the same text in one session are
    /// ambiguous; the one nearest the anchor is the one just written, and in the worst case the two
    /// read identically anyway.
    private func focusAdded(text: String, near anchor: Todo, in store: PMStore) {
        let match = store.openTodos
            .filter { $0.sessionIndex == anchor.sessionIndex && $0.text == text }
            .min { abs($0.lineIndex - anchor.lineIndex) < abs($1.lineIndex - anchor.lineIndex) }
        guard let match else { return }
        store.focus(match)
    }

    // MARK: What a command would do

    /// Run a command's own transform against a copy of the project, so the preview can show its
    /// result before it happens.
    ///
    /// These are the real functions the write calls, not a description of them — `PMStore.complete`
    /// reaches `completeTodoWithDescendants`, and so does this. That's the only version of this
    /// feature worth having: a preview that models what a command does is a second implementation,
    /// and the two come apart the first time either is changed. Everything here is a pure
    /// `ProjectNotes → ProjectNotes` value transform, so a dry run touches no file and costs a parse.
    ///
    /// Nil means "this command changes nothing in the session", which is the honest answer for two
    /// thirds of the list and is drawn as an untinted one.
    private func dryRun(_ command: QuickBarCommand, argument: String) -> PreviewOutcome? {
        guard let store = focusedStore, let notes = store.notes else { return nil }
        let task = anchorTask
        switch command {
        case .complete:
            guard let task else { return nil }
            // `advanceFocus: true` matches the call the row actually makes, so the preview shows the
            // focus landing where it will land — which is the half of this command you can't see.
            let after = try? completeTodoWithDescendants(notes: notes, sessionIndex: task.sessionIndex,
                                                         lineIndex: task.lineIndex, advanceFocus: true)
            return outcome(after)

        case .undoLast:
            // The same key `PMStore.undoLast` reads, split the same way.
            guard let key = store.lastCompletedKey else { return nil }
            let parts = key.split(separator: ":").compactMap { Int($0) }
            guard parts.count == 2 else { return nil }
            return outcome(try? undoTodoAt(notes: notes, sessionIndex: parts[0], lineIndex: parts[1]))

        case .diveIn:
            guard let next = store.nextTodo else { return nil }
            return outcome(applyFocusToTodoAt(notes: notes, sessionIndex: next.sessionIndex,
                                              lineIndex: next.lineIndex))

        case .setDue:
            // Only a phrase that reads as a date. One that doesn't opens the panel's date editor
            // instead, and there is nothing about that to draw in the session.
            guard let task, !argument.isEmpty,
                  let date = QuickCaptureParser.date(from: argument) else { return nil }
            return outcome(setDueOnTodoAt(notes: notes, sessionIndex: task.sessionIndex,
                                          lineIndex: task.lineIndex, due: DueFormat.string(date)))

        case .wrapTask:
            guard let task else { return nil }
            return wrapped(notes, task: task)

        default:
            return nil
        }
    }

    /// Wrapping is a raw-markdown transform, so the notes go out to text and come back.
    ///
    /// The round trip loses whatever formatting the file had, which would matter if this were being
    /// written and doesn't here: only the structure is read back, and the structure is what the box
    /// draws. The parent's text is a placeholder because the bar never has one — `>wrap` opens the
    /// panel's editor to ask for it. The shape is the answer anyway: what's worth seeing is the task
    /// and its whole subtree dropping a level.
    private func wrapped(_ notes: ProjectNotes, task: Todo) -> PreviewOutcome? {
        guard let raw = wrapTaskPreservingFormat(rawText: serializeNotes(notes),
                                                 sessionIndex: task.sessionIndex,
                                                 lineIndex: task.lineIndex,
                                                 parentText: Self.wrapPlaceholder),
              let after = try? parseNotes(markdown: raw),
              let todos = try? todosWithEffectiveDueDates(parseTodos(notes: after)) else { return nil }
        let added = todos.firstIndex { $0.sessionIndex == task.sessionIndex
                                    && $0.text == Self.wrapPlaceholder }
        return PreviewOutcome(todos: todos.map(Self.preview), added: added)
    }

    /// What the wrapped parent is called until you've said. Shown as the added line's text, so it has
    /// to read as a prompt rather than as a task somebody wrote.
    private static let wrapPlaceholder = "New parent task…"

    /// Parse a dry run's result the way the store parses a real one.
    ///
    /// `todosWithEffectiveDueDates` is not optional here: `notesShow` applies it, so `store.todos`
    /// carries inherited due dates and a bare `parseTodos` doesn't. Without it every task that
    /// inherits a date from an ancestor would come back with that date missing, and the diff would
    /// report the whole subtree as having its due date changed by a command that never touched one.
    private func outcome(_ notes: ProjectNotes?) -> PreviewOutcome? {
        guard let notes, let todos = try? todosWithEffectiveDueDates(parseTodos(notes: notes)) else {
            return nil
        }
        return PreviewOutcome(todos: todos.map(Self.preview), added: nil)
    }

    // MARK: Running a command

    /// Whether this command's own answer is somewhere inside PM you'd want to be looking at. Those
    /// dismiss the bar without handing the front back, because putting you where you were would undo
    /// the thing you just asked for.
    ///
    /// The focus panel's editors are the exception worth stating: the panel is deliberately
    /// non-activating, so opening one is not a request to leave the app you're in. That's the property
    /// these commands were given a global shortcut for in the first place.
    private func staysInPM(_ command: QuickBarCommand, argument: String) -> Bool {
        switch command {
        case .openWindow, .settings, .newProject, .renameProject, .addLink, .editDetails: return true
        // Given text it just writes the note; given none it opens the place that edits it.
        case .sessionNote: return argument.isEmpty
        default: return false
        }
    }

    /// Where ⌘⏎ takes you once this command has run.
    ///
    /// Nil for the ones whose own answer is already a window — ⌘ has nothing to add to Settings or to
    /// a rename prompt, which come forward regardless.
    private enum Reveal { case focusPanel, sessionEditor, window }

    private func revealTarget(for command: QuickBarCommand) -> Reveal? {
        switch command {
        // Not editTask or wrapTask: opening the panel's editor is what those already do, so ⌘ has
        // nothing left to add. setDue only opens one when it can't read the date it was given.
        case .complete, .undoLast, .diveIn, .setDue: return .focusPanel
        case .sessionNote, .startSession: return .sessionEditor
        case .archiveProject, .unarchiveProject: return .window
        default: return nil
        }
    }

    /// What to say once a command has run and the bar has gone.
    ///
    /// Nil for anything you'd be looking at anyway — a panel, a window, another app coming forward —
    /// and for the two commands whose whole effect *is* opening an editor. What's left is the set that
    /// changes the file and leaves you where you were, which is exactly the set that used to leave you
    /// wondering whether it had.
    private func confirmation(for command: QuickBarCommand, argument: String, task: Todo?) -> String? {
        switch command {
        case .complete:
            return task.map { "Completed “\(QuickBarModel.truncate($0.text, 44))”" }
        case .undoLast:
            return "Put the last completed task back"
        case .diveIn:
            // The task it's about to land on, read before the move. Naming it is the whole content of
            // a command whose only visible effect is somewhere you aren't looking.
            return focusedStore?.nextTodo.map { "Focused “\(QuickBarModel.truncate($0.text, 44))”" }
        case .setDue:
            // Only when the phrase read as a date. One that didn't opens the panel's date editor
            // instead, which is a window on screen and needs nothing said about it.
            guard let task, !argument.isEmpty,
                  let date = QuickCaptureParser.date(from: argument) else { return nil }
            return "“\(QuickBarModel.truncate(task.text, 30))” is due \(QuickBarModel.dueLabel(date))"
        case .sessionNote:
            return argument.isEmpty ? nil : "Added to today's note"
        case .startSession:
            return argument.isEmpty ? "Opened today's session" : "Today's session: “\(argument)”"
        case .archiveProject:
            return focusedStore?.projectName.map { "Archived \(QuickBarModel.display($0))" }
        case .unarchiveProject:
            return focusedStore?.projectName.map { "Unarchived \(QuickBarModel.display($0))" }
        default:
            return nil
        }
    }

    /// What to say when a command's write didn't land.
    ///
    /// Only reached by the commands that earned a receipt in the first place — the ones that change
    /// the file and leave you where you were. Everything else is looking at its own answer, and a
    /// window that didn't open needs no sentence to say so.
    private func failure(for command: QuickBarCommand, task: Todo?) -> String {
        switch command {
        case .complete:
            return task.map { "Couldn't complete “\(QuickBarModel.truncate($0.text, 44))”" }
                ?? "Couldn't complete the focused task"
        case .undoLast: return "Couldn't put the last completed task back"
        case .diveIn: return "Couldn't move the focus"
        case .setDue: return "Couldn't set the due date"
        case .sessionNote: return "Couldn't add to today's note"
        case .startSession: return "Couldn't open today's session"
        case .archiveProject: return "Couldn't archive the project"
        case .unarchiveProject: return "Couldn't unarchive the project"
        default: return "That didn't work"
        }
    }

    private func perform(_ command: QuickBarCommand, argument: String, reveal: Bool) {
        let task = anchorTask
        let store = focusedStore
        let target = reveal ? revealTarget(for: command) : nil
        let stays = staysInPM(command, argument: argument)
        Log.write("quick bar command: \(command.rawValue)\(argument.isEmpty ? "" : " \(argument)")\(reveal ? " (reveal)" : "")")

        // A command about to put something of PM's in front of you has nothing to confirm — you can
        // see that it worked. A receipt is for the rest, and a command that has one keeps the bar up
        // until its write lands, so that what it says is something that happened.
        let receipt = (target == nil && !stays)
            ? confirmation(for: command, argument: argument, task: task)
            : nil
        if receipt == nil { hide(restoringFocus: !(stays || target != nil)) } else { isRunning = true }
        let errorBefore = store?.errorMessage

        // What every path here ends with: the receipt for the ones that earned one, and otherwise the
        // reveal that ⌘ asked for.
        let landed: @MainActor () -> Void = { [weak self] in
            guard let self else { return }
            guard let receipt else {
                self.reveal(target)
                return
            }
            // A command offered against a project the store hasn't caught up with yet. The bar is
            // still up waiting on a write to confirm, and there's nothing to confirm it against — so
            // close it rather than leaving it holding the screen.
            guard let store else {
                self.hide()
                return
            }
            self.settle(receipt, failure: self.failure(for: command, task: task),
                        store: store, errorBefore: errorBefore)
        }

        switch command {
        case .complete:
            guard let store, let task else { break }
            store.complete(task, then: landed)
            return
        case .diveIn:
            guard let store else { break }
            store.diveIn(then: landed)
            return
        case .undoLast:
            guard let store else { break }
            store.undoLast(then: landed)
            return
        case .setDue:
            setDue(argument, on: task, in: store, then: landed)
            return
        case .editTask:
            FocusPanelController.shared.show(editor: .edit)
        case .wrapTask:
            FocusPanelController.shared.show(editor: .wrap)
        case .sessionNote:
            if argument.isEmpty {
                WindowManager.shared.openFocusedProject().newSession(nil)
                return   // already the reveal target; asking twice would open today's session twice
            }
            guard let store else { break }
            // Chained rather than fired alongside: this may have just created today's session, and
            // asking for it against a document that hasn't been re-read would make a second one.
            store.appendSessionNote(argument, then: landed)
            return
        case .startSession:
            startTodaySession(labelled: argument, in: store, then: landed)
            return
        case .addLink:
            if let store { ProjectPrompts.addLink(store: store) }
        case .openWindow:
            WindowManager.shared.openFocusedProject()
        case .openInFinder:
            if let path = store?.projectPath {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
        case .openInObsidian:
            if let store { ObsidianLink.open(store: store) }
        case .editDetails:
            WindowManager.shared.openFocusedProject().editDetails()
        case .renameProject:
            renameFocusedProject(store)
        case .archiveProject, .unarchiveProject:
            // Synchronous, and it either threw or it didn't — so this is the one receipt that doesn't
            // wait on a store re-read to know whether it has something true to say.
            let moved = moveFocusedProject(store, from: command == .archiveProject ? .active : .archive)
            guard let receipt, moved else { break }
            confirm(.done(receipt))
            return
        case .newProject:
            ProjectPrompts.newProject { key in WindowManager.shared.open(projectKey: key) }
        case .settings:
            SettingsWindowController.shared.show()
        }
        // Everything that fell through here either had no receipt to give or found nothing to act on.
        hide(restoringFocus: !(stays || target != nil))
        self.reveal(target)
    }

    /// Bring PM's answer forward, for a ⌘⏎ that asked to see it.
    private func reveal(_ target: Reveal?) {
        switch target {
        case .none: return
        case .focusPanel: FocusPanelController.shared.show()
        case .sessionEditor: WindowManager.shared.openFocusedProject().newSession(nil)
        case .window: WindowManager.shared.openFocusedProject()
        }
    }

    /// Archive or unarchive the focused project. The move re-points `focused.json` and any window on
    /// it, so PM stays pointed at the same project in its new folder.
    /// Returns whether the move happened, which is what decides whether there's anything to confirm.
    @discardableResult
    private func moveFocusedProject(_ store: PMStore?, from source: ProjectScope) -> Bool {
        guard let name = store?.projectName else { return false }
        do {
            try ProjectLifecycle.move(projectNamed: name, from: source)
            return true
        } catch {
            ProjectLifecycle.present(error, doing: source == .active
                                     ? "Couldn't archive “\(name)”" : "Couldn't unarchive “\(name)”")
            return false
        }
    }

    /// `>due friday`. A phrase the parser can't read falls through to the focus panel's own date
    /// editor rather than being dropped — the bar has already gone by the time you'd find out, so
    /// silence here reads as the command not working.
    private func setDue(_ phrase: String, on task: Todo?, in store: PMStore?,
                        then: @escaping @MainActor () -> Void) {
        guard let store, let task else {
            then()
            return
        }
        guard !phrase.isEmpty, let date = QuickCaptureParser.date(from: phrase) else {
            FocusPanelController.shared.show(editor: .due)
            then()
            return
        }
        store.setDue(task, due: DueFormat.string(date), then: then)
    }

    /// `>session` opens today's, `>session standup` labels it. `openTodaySession` is idempotent — a
    /// session is identified by its date, so asking twice lands in the same one.
    private func startTodaySession(labelled label: String, in store: PMStore?,
                                   then: @escaping @MainActor () -> Void) {
        guard let store else {
            then()
            return
        }
        store.openTodaySession { index in
            guard !label.isEmpty else {
                then()
                return
            }
            store.renameSession(index, label: label, then: then)
        }
    }

    private func renameFocusedProject(_ store: PMStore?) {
        guard let store, let name = store.projectName, let key = store.projectKey else { return }
        // Archived or not is a question about where the folder lives, which the key already answers.
        let isArchived = (try? loadConfigAndPaths()).map { key.hasPrefix("\($0.1.archivePath):") } ?? false
        ProjectPrompts.rename(projectNamed: name, isArchived: isArchived)
    }

    // MARK: Window

    private func ensurePanel() -> KeyablePanel {
        if let panel { return panel }
        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: QuickBarMetrics.width, height: 60),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hidesOnDeactivate = false
        panel.tabbingMode = .disallowed
        // Above everything, and present on whichever Space you summon it from — a bar you can't reach
        // from a full-screen app is a bar you can't rely on.
        panel.level = .floating
        // Matching the focus panel, which holds key focus reliably under the same summon.
        panel.collectionBehavior = [.ignoresCycle, .canJoinAllSpaces, .fullScreenAuxiliary]
        // No animation. `orderFrontRegardless` on a window with an animation behavior fades it in
        // asynchronously, and that animation finishes *after* the `takeKey` that follows it — dropping
        // the key status it was just granted, intermittently, depending on how the two race. A bar you
        // summon to type into should appear at once anyway.
        panel.animationBehavior = .none
        self.panel = panel
        return panel
    }

    private func rebuildContent() {
        let view = QuickBarView(model: model,
                                onContentHeight: { [weak self] height in self?.fit(to: height) })
        if let hosting {
            hosting.rootView = view
        } else {
            let hosting = NSHostingController(rootView: view)
            hosting.sizingOptions = []
            panel?.contentViewController = hosting
            // Assigning a content view controller resizes the window to that controller's
            // `fittingSize`, and SwiftUI hasn't laid out yet at this point, so it reports zero. The
            // window is left 0×0 — visible, key, and drawing nothing. Put a real size back before
            // anything measures or positions it.
            panel?.setContentSize(NSSize(width: QuickBarMetrics.width, height: Self.minHeight))
            self.hosting = hosting
        }
    }

    /// Grow and shrink with the rows, keeping the field where it is rather than centring the whole
    /// panel again — a field that slides up the screen as you type is a field you have to chase.
    ///
    /// The width is stated, never inherited. The bar has exactly one width, and reading it back off the
    /// window means any moment the window is the wrong size becomes permanent — which is what a
    /// zero-width window left behind by the content install turned into.
    ///
    /// Never animated here, though the bar does grow and shrink smoothly — the animation belongs to
    /// the content, and this follows it.
    ///
    /// Animating the window frame instead was the obvious way round and the wrong one. The panel's
    /// corners are drawn twice, once by `NSGlassEffectView`'s own radius and once by the view's
    /// `clipShape`, and animating the window put a third interpolation — the window server's — under
    /// both. Three curves over the same corner don't have to agree at every frame, and where they
    /// disagreed a square corner showed through. So the height is animated once, in SwiftUI, where the
    /// glass, the mask and the layout are all one pass; the measured height arrives here already part
    /// way through the curve, and this puts the window exactly where the content already is.
    private func fit(to height: CGFloat) {
        guard let panel else { return }
        let target = max(ceil(height), Self.minHeight)
        var frame = panel.frame
        guard abs(frame.height - target) > 1 || abs(frame.width - QuickBarMetrics.width) > 1 else { return }
        let top = frame.maxY
        frame.size = NSSize(width: QuickBarMetrics.width, height: target)
        frame.origin.y = top - target
        panel.setFrame(frame, display: true)
        // A borderless window's shadow is cached from its rendered alpha, so a resize leaves the old
        // outline behind until it's invalidated. Every frame of the growth, not just the last: a shadow
        // still tracing the height from two frames ago is its own dark edge across the panel.
        panel.invalidateShadow()
    }

    /// The smallest the bar can be: the field row on its own, with no results under it.
    private static let minHeight: CGFloat = 56

    /// Centred horizontally, high on the screen — where a summoned bar goes, and above the middle so
    /// its rows drop into empty space rather than over the thing you're reading.
    private func position(_ panel: NSPanel) {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = panel.frame.size
        let origin = NSPoint(x: visible.midX - size.width / 2,
                             y: visible.maxY - visible.height * Self.topInsetFraction - size.height)
        panel.setFrameOrigin(origin)
    }

    /// How far down the screen the bar's top edge sits, as a fraction of the visible height.
    private static let topInsetFraction: CGFloat = 0.22

    // MARK: NSWindowDelegate

    /// Losing the keyboard means you've gone somewhere else, and a quick bar left behind on screen is
    /// clutter you have to dismiss by hand. Unlike the focus panel there's no pinned case: the bar has
    /// nothing to show once you're not typing into it.
    ///
    /// Deferred, though, rather than done on the spot. Summoning the bar produces a brief resign/regain
    /// of key focus — the app coming forward hands key to its main window for a moment on the way — and
    /// hiding synchronously turned that blip into a bar that flashed up and vanished, every first
    /// press. The same grace period the focus panel uses, and the same re-check: if the keyboard came
    /// back, this wasn't you leaving.
    func windowDidResignKey(_ notification: Notification) {
        panel?.acceptsKey = false
        // A receipt is *meant* to be read after the front has gone back where it came from, and going
        // back is itself a resign. It has its own timer; this one would cut it short every time.
        guard model.receipt == nil else { return }
        pendingHide?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let panel = self.panel else { return }
            guard !panel.isKeyWindow else { return }
            self.hide()
        }
        pendingHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.blurHideDelay, execute: work)
    }

    /// Long enough to ride out the summon's own focus blip, short enough that clicking away from the
    /// bar still feels like it closed when you clicked.
    private static let blurHideDelay: TimeInterval = 0.2
}
