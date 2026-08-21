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
    /// The app that was in front when the bar was summoned, so dismissing it can put you back there.
    private var previousApp: NSRunningApplication?
    /// Whether the full project list is currently retained for the bar (its scan is gated).
    private var holdsProjectIndex = false
    /// Watches ⌥ while the bar is up, so a row's label can flip under it. Installed on summon and
    /// removed on dismiss — there's nothing to watch when the bar isn't taking keystrokes.
    private var flagsMonitor: Any?

    private override init() {
        super.init()
        model.onRun = { [weak self] row, modifiers in self?.run(row, modifiers: modifiers) }
        model.onDismiss = { [weak self] in self?.hide() }
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
        // Remember where you came from before anything moves, so dismissing can hand focus back.
        if !wasActive { previousApp = NSWorkspace.shared.frontmostApplication }
        seed(mode: mode)
        let panel = ensurePanel()
        rebuildContent()
        panel.contentView?.layoutSubtreeIfNeeded()
        position(panel)

        panel.orderFrontRegardless()
        // The bar is nothing but a text field; every path here is a request to type into it.
        panel.takeKey()
        assertKeyOnceSettled(panel)
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
        pendingHide?.cancel()
        pendingHide = nil
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

    /// Fill in what the rows are built from, fresh each summon: the focused project may have moved and
    /// the project lists may have been rescanned since last time.
    private func seed(mode: QuickBarMode) {
        retainProjectIndex()
        let index = ProjectIndex.shared
        index.warmRecents()
        index.warmAllProjects()
        model.recents = index.recents
        model.allProjects = index.allProjects
        model.focusedProjectName = PMFiles.focusedProjectKey().flatMap { PMFiles.projectName(fromKey: $0) }
        model.focusedTaskText = anchorTask?.text
        model.canUndoCompletion = focusedStore?.lastCompletedKey != nil
        model.hasNextTask = focusedStore?.nextTodo != nil
        model.reset(mode: mode)
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

    // MARK: Running a row

    private func run(_ row: QuickBarRow, modifiers: EventModifiers) {
        switch row {
        case .capture(let placement, let text, let due, _):
            guard let store = focusedStore else { return }
            apply(placement, text: text, due: due, in: store, modifiers: modifiers)
            hide()

        case .command(let command, let argument):
            perform(command, argument: argument)

        case .project(let key, let name, _, _, _):
            PMStore.setGlobalFocus(key: key)
            Log.write("quick bar focused \(name)")
            // ⌘⏎ points PM at the project without pulling you out of what you're doing, so it hands the
            // front back; a plain ⏎ is a request to go there, and putting you back would undo it.
            let opensWindow = !modifiers.contains(.command)
            hide(restoringFocus: !opensWindow)
            if opensWindow {
                WindowManager.shared.open(projectKey: key)
            }
        }
    }

    /// Write a captured line where the chosen row said it would go.
    private func apply(_ placement: CapturePlacement, text: String, due: String?,
                       in store: PMStore, modifiers: EventModifiers) {
        switch placement {
        case .narrow, .after:
            // Resolved now rather than held from the summon. The anchor is a value snapshot carrying
            // line coordinates, and the bar can sit open while a window or the menubar moves the focus
            // or edits the file underneath it — acting on stale coordinates would put the task on the
            // wrong line. Every other surface acts on the project's current focus too.
            guard let anchor = anchorTask else { return }
            let position: TaskInsertPosition = placement == .narrow
                ? .child
                : (modifiers.contains(.option) ? .before : .after)
            store.addTodo(text: text, due: due, relativeTo: anchor, position: position)
            Log.write("quick bar \(placement.rawValue): \(text)\(due.map { " due:\($0)" } ?? "")")
        case .sessionEnd:
            store.addTodo(text: text, due: due)
            Log.write("quick bar added task: \(text)\(due.map { " due:\($0)" } ?? "")")
        case .sessionNote:
            store.appendSessionNote(text)
            Log.write("quick bar added session note: \(text)")
        }
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
        case .openWindow, .settings, .newProject, .renameProject, .addLink: return true
        // Given text it just writes the note; given none it opens the place that edits it.
        case .sessionNote: return argument.isEmpty
        default: return false
        }
    }

    private func perform(_ command: QuickBarCommand, argument: String) {
        let task = anchorTask
        let store = focusedStore
        Log.write("quick bar command: \(command.rawValue)\(argument.isEmpty ? "" : " \(argument)")")
        hide(restoringFocus: !staysInPM(command, argument: argument))

        switch command {
        case .complete:
            if let store, let task { store.complete(task) }
        case .diveIn:
            store?.diveIn()
        case .undoLast:
            store?.undoLast()
        case .editTask:
            FocusPanelController.shared.show(editor: .edit)
        case .wrapTask:
            FocusPanelController.shared.show(editor: .wrap)
        case .setDue:
            setDue(argument, on: task, in: store)
        case .sessionNote:
            if argument.isEmpty {
                WindowManager.shared.openFocusedProject().newSession(nil)
            } else {
                store?.appendSessionNote(argument)
            }
        case .startSession:
            startTodaySession(labelled: argument, in: store)
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
        case .renameProject:
            renameFocusedProject(store)
        case .newProject:
            ProjectPrompts.newProject { key in WindowManager.shared.open(projectKey: key) }
        case .settings:
            SettingsWindowController.shared.show()
        }
    }

    /// `>due friday`. A phrase the parser can't read falls through to the focus panel's own date
    /// editor rather than being dropped — the bar has already gone by the time you'd find out, so
    /// silence here reads as the command not working.
    private func setDue(_ phrase: String, on task: Todo?, in store: PMStore?) {
        guard let store, let task else { return }
        guard !phrase.isEmpty, let date = QuickCaptureParser.date(from: phrase) else {
            FocusPanelController.shared.show(editor: .due)
            return
        }
        store.setDue(task, due: DueFormat.string(date))
    }

    /// `>session` opens today's, `>session standup` labels it. `openTodaySession` is idempotent — a
    /// session is identified by its date, so asking twice lands in the same one.
    private func startTodaySession(labelled label: String, in store: PMStore?) {
        guard let store else { return }
        store.openTodaySession { index in
            guard !label.isEmpty else { return }
            store.renameSession(index, label: label)
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
        // outline behind until it's invalidated.
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
