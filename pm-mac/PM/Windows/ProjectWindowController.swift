import AppKit
import Combine
import SwiftUI

/// One project window: a real Mac window with a hidden titlebar and a full-size content view. The
/// traffic lights float over the sidebar, the content runs to the top of the frame, and the title is
/// still set (invisible) so window tabs, the Window menu and ⌘` all name the project properly.
///
/// This used to have a second chrome — the app's original borderless HUD, offered as a window-style
/// setting. That chrome now belongs to the focus panel, which is the surface it was always describing,
/// so a project window is unconditionally a window.
@MainActor
final class ProjectWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    /// The project this window shows. Changing it is `retarget(to:)`, not a write.
    private(set) var projectKey: String?
    private(set) var store: PMStore

    /// Which way this window is rendering its project — its task list, or its board.
    ///
    /// **Per project, and remembered.** A window opened onto a project, and a window retargeted at one,
    /// both come up the way that project was last looked at — see `ProjectRendererMemory`, which holds
    /// the argument and what it costs.
    private var renderer: ProjectRenderer = .tasks

    /// Set while a remembered canvas is waiting for its path.
    ///
    /// A project's canvas path arrives with the store's first read of its folder, so at the moment a
    /// window is built every project looks like a project without a board. Switching to the canvas
    /// renderer then would put the "no canvas yet" empty state on screen and take it away again a
    /// moment later, which is a worse answer than the task list for the same fraction of a second.
    /// `watchCanvasPath` picks this up when the path lands.
    private var awaitsRememberedCanvas = false

    /// The project's canvas path arrives with the store's first read, and again whenever the project's
    /// folder is re-scanned. A window in canvas mode has to follow it: the path is nil for the moment
    /// after a retarget, so acting only at the moment of the switch would leave the window showing the
    /// previous project's board, or an empty state for a project that has one.
    private var canvasPathWatch: AnyCancellable?

    let state = ProjectViewState()
    private let split: ProjectSplitViewController

    /// Called when the window has closed, so `WindowManager` can drop it.
    var onClose: ((ProjectWindowController) -> Void)?
    /// Asks to open a project — in this window or a new one. Supplied by `WindowManager`.
    var onOpenProject: ((String, Bool) -> Void)?

    init(projectKey: String?, store: PMStore, startsWithSidebar: Bool, remembersFrame: Bool) {
        self.projectKey = projectKey
        self.store = store

        split = ProjectSplitViewController(store: store, state: state,
                                           startsWithSidebar: startsWithSidebar)

        let window = TextFocusWindow(
            contentRect: NSRect(x: 0, y: 0,
                                width: ProjectWindow.minContentWidth + ProjectWindow.sidebarWidth
                                    + ProjectWindow.sidebarDividerWidth,
                                height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        // Things' chrome: no toolbar, no visible title, content running under the titlebar. The title
        // is still *set* below — `titleVisibility` only hides it from the titlebar, while tabs, the
        // Window menu and ⌘` all keep reading it.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.contentMinSize = NSSize(width: ProjectWindow.minContentWidth,
                                       height: ProjectWindow.minWindowHeight)
        // A ceiling on width, none on height. A task list gains from every extra row it can show and
        // nothing from being stretched sideways across a large display, so the window stops widening
        // where the content stops benefiting — see `ProjectWindow.maxWindowContentWidth`.
        window.contentMaxSize = NSSize(width: ProjectWindow.maxWindowContentWidth,
                                       height: .greatestFiniteMagnitude)
        // No full screen, because there's nothing for it to do: a window that can't pass 1120pt wide
        // would sit pinned at that width in the middle of an otherwise empty display. With
        // `.fullScreenNone` the green button reverts to plain zoom — grow to the maximum — which is the
        // honest affordance for a window with a maximum. (Full-height is still free: only width is
        // capped, so zoom takes the whole screen vertically.)
        window.collectionBehavior.insert(.fullScreenNone)
        window.tabbingIdentifier = ProjectWindow.tabbingIdentifier
        window.tabbingMode = .automatic
        // An empty toolbar, purely for its geometry. A window with one gets the taller unified titlebar
        // and the lower, further-inset traffic lights that go with it — the proportions every current
        // Mac app has. Without a toolbar you get the compact titlebar, with the buttons tucked hard
        // into the corner.
        //
        // It has no delegate and therefore no items, `titlebarAppearsTransparent` keeps it from drawing
        // a background, and the split items' `titlebarSeparatorStyle = .none` keeps it from drawing a
        // line. So it costs nothing visually and is not a toolbar in the UI sense.
        //
        // A titlebar accessory is the obvious-looking alternative and doesn't work: an accessory with
        // `layoutAttribute = .top` adds a strip *below* the titlebar (Safari's bookmarks bar) without
        // making the titlebar itself taller or moving the window buttons. The unified toolbar is the
        // supported route to these metrics, so this is the intended API rather than a trick — the only
        // oddity is having no items in it. Nothing exposes it to the user: customization is off and the
        // app's hand-built menus offer no Show/Hide Toolbar, so it can't be toggled out from under the
        // header. And if it ever were, `measureTitlebarButtons` re-runs on the resize and the header
        // follows the new geometry rather than holding the old one.
        let toolbar = NSToolbar(identifier: "PMProjectTitlebar")
        toolbar.allowsUserCustomization = false
        toolbar.showsBaselineSeparator = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        super.init(window: window)

        window.contentViewController = split
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.identifier = NSUserInterfaceItemIdentifier(ProjectWindow.windowIdentifier)

        // Wire the content's callbacks now that `self` exists.
        state.openProject = { [weak self] key, inNewWindow in
            self?.onOpenProject?(key, inNewWindow)
        }
        state.toggleSidebar = { [weak self] in self?.toggleSidebar() }
        state.setRenderer = { [weak self] next in self?.setRenderer(next) }
        watchCanvasPath()
        split.onRendererChanged = { [weak self] in
            guard let self else { return }
            renderer = split.renderer
            applyWidthLimits()
        }
        // Publish "a field has the keyboard" into the shared state, which is what stands the window's
        // own ⌘A / ⌘C / ⌘Z / ⌘⌫ down while you're typing — see `ProjectViewState.isEditingText`.
        // Deferred by a turn of the run loop because AppKit changes the first responder from inside
        // SwiftUI's own focus update, and publishing into an `ObservableObject` from there is a write
        // during a view update. A turn is far quicker than the next keystroke.
        window.onTextFocusChange = { [weak self] editing in
            afterCurrentUpdate {
                guard let self, self.state.isEditingText != editing else { return }
                self.state.isEditingText = editing
            }
        }

        // One remembered frame for project windows, not one per project. A window is a window: it has
        // the size and place you last left it at, and pointing it at a different project doesn't move
        // or resize it. It used to autosave under `PMProject:<key>`, which meant every project carried
        // its own geometry — so the same window jumped and resized as you switched projects in it, and
        // each project's first window opened somewhere unrelated to where you were working.
        //
        // Only the window that opens with nothing else already up claims that frame. Later windows are
        // cascaded off it by `WindowManager` and deliberately don't write back, or every "Open in New
        // Window" would walk the remembered frame further down the screen.
        //
        // `setFrameAutosaveName` has to come after the window exists and before it's shown. Placement is
        // decided here rather than left to `NSWindowController`'s own cascade, which interacts with a
        // frame autosave name in ways that differ between the first window and later ones: centred by
        // default, the remembered frame instead when there is one, and `WindowManager` steps any
        // additional window off the one in front.
        shouldCascadeWindows = false
        window.center()
        if remembersFrame {
            window.setFrameAutosaveName("PMProject")
            window.setFrameUsingName("PMProject")
            // A frame saved before the cap existed — or under a taller titlebar — can be wider than
            // the cap allows. `setFrameUsingName` restores it verbatim rather than constraining it, so
            // the first window after an upgrade would open wider than the user could ever drag it.
            let capped = window.frameRect(forContentRect:
                NSRect(x: 0, y: 0, width: ProjectWindow.maxWindowContentWidth, height: 100)).width
            if window.frame.width > capped {
                var frame = window.frame
                frame.size.width = capped
                window.setFrame(frame, display: false)
            }
        }

        applyTitle()

        // Measure before the first frame is drawn, not after the window is ordered in. The defaults in
        // `ProjectViewState` are only starting guesses — 92pt of traffic lights and a compact
        // titlebar's 13pt drop — so measuring in `show()` meant the header was laid out against the
        // guess and then visibly settled onto the real numbers as the window opened. `layoutIfNeeded`
        // forces the theme frame to place its buttons, which is what makes them measurable this early.
        window.layoutIfNeeded()
        measureTitlebarButtons()

        applyRememberedRenderer()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// Open this window the way its project was last looked at.
    ///
    /// Called on the way up and again on every retarget, since a retarget is the same question asked
    /// about a different project.
    private func applyRememberedRenderer() {
        guard ProjectRendererMemory.of(projectKey) == .canvas else {
            awaitsRememberedCanvas = false
            if renderer == .canvas { setRenderer(.tasks) }
            return
        }
        guard store.canvasPath != nil else { return awaitsRememberedCanvas = true }
        awaitsRememberedCanvas = false
        setRenderer(.canvas)
    }

    /// ⌘Z goes to whatever this window is showing. With a board up that is the canvas document's own
    /// stack, shared with the canvas's own window if it also has one open — which is the only coherent
    /// answer when both are the same document.
    ///
    /// The task list gets one manager for the window, which is what AppKit would have made for it
    /// anyway: implementing this method at all takes the default away, so returning nil here would mean
    /// no undo in any text field in the window rather than "carry on as before".
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        if renderer == .canvas, let board = split.undoManagerForContent { return board }
        return windowUndoManager
    }

    private let windowUndoManager = UndoManager()

    // MARK: Presentation

    func show() {
        showWindow(nil)
        // Already measured in the initialiser; this catches a window restored to a frame (or a screen)
        // that changes the chrome between construction and appearing.
        measureTitlebarButtons()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    var isVisible: Bool { window?.isVisible ?? false }

    /// Publish where the window's traffic lights actually sit, so the leftmost pane's header can start
    /// past them and sit level with them.
    ///
    /// Re-run on everything that can move them, not once on open. A window's chrome is not a constant:
    /// full screen takes the titlebar away entirely, joining a tab group adds a bar that moves the
    /// content area, and a resize can bring either about. Measured only in `show()`, a window that went
    /// full screen kept a titlebar-sized gap above a header with no titlebar over it, and the same
    /// stale-constant problem the measurement exists to avoid came back by another route.
    /// Write the window's own button geometry through to the view state, ignoring sub-point noise so a
    /// live resize doesn't republish (and re-lay-out the whole column) on every frame for a value that
    /// hasn't moved. The measuring itself is `NSWindow.titlebarButtonMetrics`, shared with the canvas
    /// window's header.
    private func measureTitlebarButtons() {
        guard let metrics = window?.titlebarButtonMetrics() else { return }
        if abs(state.leadingTitlebarInset - metrics.leadingInset) > 0.5 {
            state.leadingTitlebarInset = metrics.leadingInset
        }
        if abs(state.titlebarButtonCenterY - metrics.buttonCenterY) > 0.5 {
            state.titlebarButtonCenterY = metrics.buttonCenterY
        }
    }

    // MARK: Retargeting

    /// Show a different project in this window. The store is swapped (stores are shared per project),
    /// the title follows, and the new project becomes the global focus since this window is the one in
    /// front. The window itself doesn't move: what it's showing changed, not which window it is.
    func retarget(to newStore: PMStore, projectKey newKey: String?) {
        guard newKey != projectKey else { return }
        projectKey = newKey
        store = newStore
        split.retarget(to: newStore, projectKey: newKey)
        applyTitle()
        pushFocusToDisk()
        // The new project decides how it is shown, not the window — and the board a canvas project
        // wants is the *new* one, whose path arrives with the new store's first read. So this can go
        // either way here and `watchCanvasPath` finishes it when the path lands.
        watchCanvasPath()
        applyRememberedRenderer()
    }

    /// Put the sidebar's selection back on the project this window is actually showing. Used when a
    /// switch doesn't happen after all — the project turned out to be open in another window, which
    /// comes forward instead (see `WindowManager.retarget`).
    func syncSidebarSelection() {
        state.projectSelection = projectKey.map { [$0] } ?? []
    }

    /// The window's title — invisible in the titlebar, but what the Window menu, ⌘`, and the tab bar
    /// all show. The subtitle carries progress, which is where the header's "3/8" goes in a window.
    func applyTitle() {
        guard let window else { return }
        let title = store.notes?.title.trimmingCharacters(in: .whitespacesAndNewlines)
        // The folder name is the fallback and the one that carries a code, so it's written the way the
        // rest of the app has been told to write names — see `ProjectCodes`.
        let name = (title?.isEmpty ?? true) ? store.projectName.map { ProjectCodes.display($0) } : title
        window.title = name ?? "PM"
        let p = store.progress
        window.subtitle = p.total > 0 ? "\(p.done) of \(p.total) done" : ""
    }

    /// File ▸ Project Canvas, and the header button's twin — this window's project, its board.
    func openProjectCanvas() {
        CanvasWindowController.openProjectCanvas(for: store)
    }

    // MARK: Rendering the project as a board

    /// View ▸ Show Canvas — render this window's project as its board rather than as its task list.
    ///
    /// A different thing from File ▸ Project Canvas, which opens the board in a window of its own. This
    /// is the same window looking at the same project a different way, and both can be up at once: the
    /// document store is shared per file (see `CanvasStoreRegistry`), so the two are views of one board
    /// with one undo stack rather than two copies racing each other to save.
    @objc func toggleCanvasRenderer(_ sender: Any?) {
        setRenderer(renderer == .canvas ? .tasks : .canvas)
    }

    private func watchCanvasPath() {
        canvasPathWatch = store.$canvasPath
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                guard let self, renderer == .canvas || awaitsRememberedCanvas else { return }
                // On the next turn: this fires from inside the store's own publish, and re-entering the
                // split view's child swap from there is a layout change during an update.
                afterCurrentUpdate { [weak self] in
                    guard let self, self.renderer == .canvas || self.awaitsRememberedCanvas else {
                        return
                    }
                    self.awaitsRememberedCanvas = false
                    self.setRenderer(.canvas)
                }
            }
    }

    func setRenderer(_ next: ProjectRenderer) {
        renderer = next
        switch next {
        case .tasks:
            split.showTasks()
        case .canvas:
            split.showCanvas(at: store.canvasPath.map { URL(fileURLWithPath: $0) },
                             projectName: window?.title,
                             create: { [weak self] in self?.createAndShowCanvas() })
        }
        applyWidthLimits()
        // What the split actually settled on, which is not always what was asked for: a canvas that
        // won't parse falls back to the task list, and remembering the ask would send the window
        // straight back into the same failure on every launch.
        ProjectRendererMemory.remember(split.renderer, for: projectKey)
    }

    /// The empty state's button: make the board, then show it. The creating half is
    /// `PMStore.openableCanvasPath`, which is the app's one place that decides where a project's canvas
    /// goes and what starts in it.
    private func createAndShowCanvas() {
        store.openableCanvasPath { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                setRenderer(.canvas)
            case .failure(let error):
                let alert = NSAlert()
                alert.messageText = "Couldn't make a canvas for this project."
                alert.informativeText = (error as? LocalizedError)?.errorDescription
                    ?? String(describing: error)
                alert.alertStyle = .warning
                alert.runModal()
            }
        }
    }

    /// The window's size limits, which are not the same for the two renderers.
    ///
    /// A task list gains from every extra row it can show and nothing from being stretched sideways, so
    /// a window showing one stops widening at `maxWindowContentWidth` and declines full screen — the
    /// green button reverting to plain zoom is the honest affordance for a window with a maximum. A
    /// board is the opposite: it is a plane, and every point of width is more of it you can see. So the
    /// cap and the full-screen refusal are lifted for a canvas and re-applied on the way back — and on
    /// the way back the window is pulled in if it has outgrown the cap in the meantime, since a window
    /// wider than its own maximum is one the user can never restore by dragging.
    private func applyWidthLimits() {
        guard let window else { return }
        switch renderer {
        case .canvas:
            window.contentMaxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                           height: CGFloat.greatestFiniteMagnitude)
            window.collectionBehavior.remove(.fullScreenNone)
        case .tasks:
            window.contentMaxSize = NSSize(width: ProjectWindow.maxWindowContentWidth,
                                           height: .greatestFiniteMagnitude)
            if !window.styleMask.contains(.fullScreen) {
                window.collectionBehavior.insert(.fullScreenNone)
                let capped = window.frameRect(forContentRect:
                    NSRect(x: 0, y: 0, width: ProjectWindow.maxWindowContentWidth, height: 100)).width
                if window.frame.width > capped {
                    var frame = window.frame
                    frame.size.width = capped
                    window.setFrame(frame, display: true, animate: true)
                }
            }
        }
    }

    // MARK: Sidebar

    /// The header's toggle, routed through the split view so it animates and persists in one place.
    /// Show the project list and put the keyboard in it — File ▸ All Projects…, which is "browse
    /// everything" rather than "toggle a pane", so it only ever opens the sidebar.
    func revealProjectList() {
        if isSidebarCollapsedNow { split.toggleSidebar(nil) }
        state.requestFocusProjectList()
    }

    private var isSidebarCollapsedNow: Bool { !isSidebarVisible }

    func toggleSidebar() {
        split.toggleSidebar(nil)
    }

    var isSidebarVisible: Bool { !split.isSidebarCollapsed }

    // MARK: NSWindowDelegate

    func windowDidBecomeMain(_ notification: Notification) {
        pushFocusToDisk()
        // Joining or leaving a tab group moves the content area without resizing the window, and there
        // is no delegate callback for it. Becoming main is the moment that always follows.
        measureTitlebarButtons()
    }

    /// The chrome-change hooks. All three land in the same place: whatever moved, re-ask the buttons
    /// where they are. The measurement is two coordinate conversions and `publishTitlebarMetrics`
    /// swallows sub-point changes, so running it on every frame of a live resize costs nothing.
    func windowDidResize(_ notification: Notification) {
        measureTitlebarButtons()
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        measureTitlebarButtons()
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        measureTitlebarButtons()
    }

    func windowWillClose(_ notification: Notification) {
        split.prepareForClose()
        onClose?(self)
    }

    /// ⌘T and the tab bar's `+`. A tab on the project this window already shows would be a duplicate,
    /// so New Tab means "another project alongside this one": the most recent one that isn't open yet,
    /// added to this window's tab group.
    @objc override func newWindowForTab(_ sender: Any?) {
        guard let key = WindowManager.shared.nextUnopenedProjectKey else { return }
        WindowManager.shared.open(projectKey: key, asTabOf: self)
    }

    // MARK: Menu commands answered by this window

    /// File ▸ New Task. The content opens its inline add editor; the window can't do it directly, so it
    /// nudges the shared state and the view responds.
    @objc func newTask(_ sender: Any?) {
        state.requestNewTask()
    }

    /// File ▸ New Session. Same hand-off as New Task: the content opens the current session's note,
    /// starting a session first when there isn't one to continue.
    @objc func newSession(_ sender: Any?) {
        state.requestNewSession()
    }

    /// Open the project's details form — the summary, problem, goals, approach and learnings, which
    /// were five separate Raycast forms and are one brief here. Same hand-off again.
    ///
    /// Deferred by a turn, unlike the two above, because the quick bar's `>details` may have opened
    /// this window a moment ago: a counter bumped before the content's first body pass is a change
    /// `onChange` never sees, and the request would be dropped. (The New Session hand-off can be
    /// reached the same way from the menu bar and takes that chance today.)
    func editDetails() {
        afterCurrentUpdate { [weak self] in self?.state.requestEditDetails() }
    }

    /// Edit ▸ Find. One selector for the whole submenu, dispatched on the item's tag — which is how
    /// AppKit's own find menu works, and why `MainMenu` sets `NSTextFinder.Action` raw values as tags
    /// rather than giving each item a selector of its own.
    ///
    /// Only reaches this window when nothing closer in the responder chain wants it. `NSTextView`
    /// implements `performFindPanelAction:`, so while a field editor holds the keyboard ⌘E means "use
    /// the text I selected" and never gets here — which is the behaviour a Mac user expects and comes
    /// free from routing it this way.
    @objc func performFindPanelAction(_ sender: Any?) {
        let tag = (sender as? NSMenuItem)?.tag ?? NSTextFinder.Action.showFindInterface.rawValue
        switch NSTextFinder.Action(rawValue: tag) {
        case .nextMatch: state.requestFindStep(1)
        case .previousMatch: state.requestFindStep(-1)
        case .setSearchString: state.requestUseSelectionForFind()
        default: state.requestFind()
        }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(performFindPanelAction(_:)):
            guard store.projectName != nil else { return false }
            // Next/Previous need matches to step between; the other two only need a project.
            switch NSTextFinder.Action(rawValue: item.tag) {
            case .nextMatch, .previousMatch: return state.findIsFiltering
            default: return true
            }
        case #selector(newTask(_:)), #selector(newSession(_:)):
            return store.projectName != nil
        case #selector(newWindowForTab(_:)):
            // Nothing to open if every project is already on screen.
            return WindowManager.shared.nextUnopenedProjectKey != nil
        case #selector(toggleCanvasRenderer(_:)):
            item.state = renderer == .canvas ? .on : .off
            return store.projectName != nil
        default:
            return true
        }
    }

    /// The frontmost window owns the global focus, so the CLI, Raycast and the menubar all follow
    /// whichever project you're looking at.
    private func pushFocusToDisk() {
        guard let projectKey, projectKey != PMFiles.focusedProjectKey() else { return }
        PMStore.setGlobalFocus(key: projectKey) {
            // The watcher will see the write too, but that's debounced by up to a second; nudging the
            // menubar here makes the switch feel immediate.
            (NSApp.delegate as? AppDelegate)?.syncFocusedStore()
        }
    }
}

/// The project window itself: an `NSWindow` that reports whether a text editor holds the keyboard.
///
/// `makeFirstResponder` is the one funnel every focus change goes through — a SwiftUI `TextField`
/// taking the keyboard makes its *field editor* (an `NSTextView`) the responder, the note editor's own
/// text view goes the same way, and moving focus back to a list swaps in a plain view. So watching it
/// answers "is the user typing" for every field in either pane, present or future, without the panes
/// having to declare themselves.
///
/// Why the window needs to answer that at all: see `ProjectView.keyboardShortcuts`. In short, SwiftUI
/// key equivalents are offered the keystroke before the main menu is, so the content's commands have to
/// stand aside for the field rather than trusting Edit ▸ Select All to get there first.
final class TextFocusWindow: NSWindow {
    /// Called on every first-responder change with whether the new one is an editable text view.
    var onTextFocusChange: ((Bool) -> Void)?

    /// The token-aware field editor, made on first use and then shared — one per window, which is what
    /// a field editor is.
    private lazy var tokenEditor = TokenFieldEditor()

    /// Lend the token fields an editor that can draw a pill, and everything else the standard one.
    ///
    /// A `[[…]]` behaves as one thing in these fields — the caret steps over it, backspace takes all of
    /// it — and until this existed it did that while looking like plain text with odd spacing in it.
    /// The shared editor could only be reached through its delegate, which carries the glyph half of
    /// `TokenLayoutManager` and not the drawing half; see `TokenFieldEditor`.
    ///
    /// Scoped to `TokenClickField` rather than given to every field in the window, because a window
    /// also holds the find bar and the details form, and none of those contain a token to draw.
    override func fieldEditor(_ createFlag: Bool, for client: Any?) -> NSText? {
        guard TokenFieldEditor.wants(client) else { return super.fieldEditor(createFlag, for: client) }
        return tokenEditor
    }

    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        let accepted = super.makeFirstResponder(responder)
        // Read back `firstResponder` rather than trusting the argument: handing a window an
        // `NSTextField` installs the shared field editor instead, and that editor is the responder the
        // keystrokes actually reach.
        onTextFocusChange?((firstResponder as? NSText)?.isEditable ?? false)
        return accepted
    }
}
