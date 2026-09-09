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

    /// The board this window was opened *on*, when it was opened on a file rather than a project.
    ///
    /// A `.canvas` is a file and can live anywhere in the vault — several in a real one sit at its root
    /// belonging to no project at all — so "open this canvas" is an errand no project answers. It used
    /// to be answered by a second window type (`CanvasWindowController`), which is a whole idea of what
    /// a window is, kept for one case. This is the same case answered by the window the app already
    /// has: a project window with no project, showing that board.
    ///
    /// Only the *source* differs, which is why one optional is the whole of it — everything downstream
    /// of `canvasSource` is asking "which file", not "which project". And it is where the window
    /// **started**, not what it is: click a project in the sidebar and this clears, because a window
    /// showing a project's board should show *that project's* board. See `retarget`.
    private(set) var openedCanvas: URL?

    /// Which way this window is rendering its project — its task list, or its board.
    ///
    /// **Per project, and remembered.** A window opened onto a project, and a window retargeted at one,
    /// both come up the way that project was last looked at — see `ProjectRendererMemory`, which holds
    /// the argument and what it costs.
    private var renderer: ProjectRenderer = .tasks

    /// Set while a remembered canvas is waiting for its path.
    ///
    /// A project's canvas path arrives with the store's first read of its folder, so at the moment a
    /// window is built every project looks like a project without a board. Answering then would put
    /// the "no canvas yet" empty state on screen and take it away again a moment later, offering to
    /// make a canvas the project already has. The board tab shows an empty pane for that moment
    /// instead — see `ProjectSplitViewController.setTabs` — and `watchCanvasPath` finishes the job
    /// when the path lands.
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

    init(projectKey: String?, store: PMStore, startsWithSidebar: Bool, remembersFrame: Bool,
         canvas: URL? = nil) {
        self.projectKey = projectKey
        self.store = store
        self.openedCanvas = canvas

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
        // **No native window tabs.** A project window has tabs of its own now — the notes, the board,
        // a frame on it, an arrangement of it — and AppKit's would sit in a bar directly above them
        // meaning something else entirely: another *project* beside this one. Two tab bars in one
        // window, one nested in the other, each with its own idea of what a tab is. Opening a second
        // project is still File ▸ New Window and the sidebar, which is what it always was.
        window.tabbingMode = .disallowed
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
        state.tabs = split.tabModel
        // The split switches tabs on its own — a click on the bar — so it asks for the project's board
        // rather than being handed it. The store is the window's.
        //
        // `self.store` and `self.window` in full, and that is not a style choice: this closure is
        // written inside `init`, where the bare names `store` and `window` are the initialiser's own
        // parameter and local. Spelled that way the closure answers for the project the window was
        // *opened* on for the rest of its life, so retargeting to a project with no canvas and then
        // switching to the board handed back the previous project's file.
        split.canvasSource = { [weak self] in
            guard let self else { return (nil, nil, {}) }
            // A window opened on a file shows that file. Ahead of the project's own board rather than
            // instead of it: the two never both apply, because opening on a file is what a window with
            // no project does, and taking a project clears it.
            return (self.openedCanvas ?? self.store.canvasPath.map { URL(fileURLWithPath: $0) },
                    self.window?.title,
                    { [weak self] in self?.openProjectCanvas() })
        }
        split.ensureCanvas = { [weak self] in self?.ensureProjectCanvas() }
        watchCanvasPath()
        split.onRendererChanged = { [weak self] in
            guard let self else { return }
            renderer = split.renderer
            applyWidthLimits()
            ProjectTabMemory.remember(split.tabs, for: projectKey)
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
        // A window opened on a file has one thing to show and no project whose habits to consult.
        // Nothing is pending either — the path did not have to be looked for, it was handed in.
        if openedCanvas != nil { return split.setTabs(ProjectTabSet(.board(.whole))) }
        // The tabs this project was last looked at through, seeded — for a project that has never had
        // any — from what the old one-renderer memory said. See `ProjectTabMemory`.
        let seed: ProjectTabView = ProjectRendererMemory.of(projectKey) == .canvas
            ? .board(.whole) : .notes
        let remembered = ProjectTabMemory.of(projectKey, seed: seed)
        // A board that isn't there yet is worth waiting for rather than falling back from: the store
        // learns the canvas path asynchronously, and answering in the meantime would either offer to
        // make a canvas the project already has or — as this did until the store could tell "nobody
        // has looked" from "there isn't one" — put the whole task list on screen for the fraction of a
        // second before the board arrived. The tabs are right either way; it is only the pane inside
        // the board tab that has to hold still. See `ProjectSplitViewController.setTabs`.
        let pending = remembered.tabs.contains { $0.view.isBoard } && !store.hasResolvedCanvasPath
        awaitsRememberedCanvas = pending
        split.setTabs(remembered, canvasPending: pending)
    }

    /// ⌘Z goes to whatever this window is showing. With a board up that is the canvas document's own
    /// stack, shared with every other window showing the same file — which is the only coherent answer
    /// when they are all the same document.
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
    /// hasn't moved. The measuring itself is `NSWindow.titlebarButtonMetrics`.
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
        // The window has a project now, so it is a project's window: whatever file it was opened on is
        // where it started and not what it shows. Before `applyTitle` and the renderer, both of which
        // read it.
        openedCanvas = nil
        split.retarget(to: newStore, projectKey: newKey)
        applyTitle()
        pushFocusToDisk()
        // The new project decides how it is shown, not the window — and the board a canvas project
        // wants is the *new* one, whose path arrives with the new store's first read. So this can go
        // either way here and `watchCanvasPath` finishes it when the path lands.
        watchCanvasPath()
        applyRememberedRenderer()
    }

    /// The window's title — invisible in the titlebar, but what the Window menu, ⌘`, and the tab bar
    /// all show. The subtitle carries progress, which is where the header's "3/8" goes in a window.
    func applyTitle() {
        guard let window else { return }
        // A window opened on a file is named for the file, and carries it: `representedURL` is what
        // gives the titlebar its proxy icon and its ⌘-click path menu, which for a document window is
        // most of what a title is for.
        if let openedCanvas {
            window.title = openedCanvas.deletingPathExtension().lastPathComponent
            window.subtitle = ""
            window.representedURL = openedCanvas
            return
        }
        let title = store.notes?.title.trimmingCharacters(in: .whitespacesAndNewlines)
        // The folder name is the fallback and the one that carries a code, so it's written the way the
        // rest of the app has been told to write names — see `ProjectCodes`.
        let name = (title?.isEmpty ?? true) ? store.projectName.map { ProjectCodes.display($0) } : title
        window.title = name ?? "PM"
        // A window retargeted away from the file it was opened on must lose the proxy icon with it: a
        // titlebar still offering the old canvas's path menu is a window claiming to be a document it
        // is not showing.
        window.representedURL = nil
        let p = store.progress
        window.subtitle = p.total > 0 ? "\(p.done) of \(p.total) done" : ""
    }

    /// This window's project, as its board — making the board first if the project hasn't got one.
    ///
    /// The canvas empty state's button and File ▸ Open Project Canvas in New Window are the same
    /// errand reached two ways, and the half worth not duplicating is the failure: creating the board
    /// writes a file, so a refusal has to be *said*. Silence and a window that didn't change is the one
    /// outcome that leaves you nothing to act on.
    ///
    /// Creation is a side effect of asking, which is `PMStore.openableCanvasPath`'s whole convention —
    /// a project is assumed to have a canvas, so opening one is never "make it, then open it".
    /// Make the project's board if it hasn't got one, without going to it — what a notes tab needs,
    /// since its notes are a card on that board (docs/canvas-workspaces.md §7d).
    ///
    /// **Quiet on both outcomes**, which is what separates it from `openProjectCanvas` below. That one
    /// is a thing you asked for, so it says so when it cannot be done; this is the app making a file on
    /// its own behalf to answer a question you asked in other words, and the honest response to failing
    /// at it is to show you your notes the old way rather than to put up a box about a file you never
    /// mentioned.
    func ensureProjectCanvas() {
        guard !makingCanvas else { return }
        guard store.projectKey != nil else { return split.canvasCouldNotBeMade() }
        makingCanvas = true
        store.openableCanvasPath { [weak self] result in
            guard let self else { return }
            makingCanvas = false
            // On success the path publishes, and the watch above rebuilds the tab onto the board.
            if case .failure = result { split.canvasCouldNotBeMade() }
        }
    }

    private var makingCanvas = false

    func openProjectCanvas() {
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

    // MARK: Rendering the project as a board

    /// View ▸ Show Canvas — render this window's project as its board rather than as its task list.
    ///
    /// A different thing from File ▸ Open Project Canvas in New Window, which is the same view in a
    /// second window; this is the window you are in, looking another way. Both can be up at once, on
    /// one document: the store is shared per file (see `CanvasStoreRegistry`), so two windows on a
    /// board are two views of it with one undo stack rather than two copies racing each other to save.
    @objc func toggleCanvasRenderer(_ sender: Any?) {
        setRenderer(renderer == .canvas ? .tasks : .canvas)
    }

    private func watchCanvasPath() {
        // Both halves of the answer: where the board is, and whether that has been looked for at all.
        // A project with no board publishes nil over nil, which is no change to see — so a window
        // watching only the path would wait on it for ever. See `PMStore.hasResolvedCanvasPath`.
        canvasPathWatch = Publishers.CombineLatest(store.$canvasPath.removeDuplicates(),
                                                   store.$hasResolvedCanvasPath.removeDuplicates())
            .dropFirst()
            .sink { [weak self] _ in
                guard self != nil else { return }
                // On the next turn: this fires from inside the store's own publish, and re-entering the
                // split view's child swap from there is a layout change during an update.
                afterCurrentUpdate { [weak self] in
                    guard let self else { return }
                    if renderer == .canvas || awaitsRememberedCanvas {
                        awaitsRememberedCanvas = false
                        applyRememberedRenderer()
                    }
                    // Unconditionally, unlike before: a *notes* tab wants the board too now (§7d), and
                    // its renderer is `.tasks`. The split answers for whether it has anything to do.
                    split.canvasPathChanged()
                }
            }
    }

    /// The renderer switch: change what the tab you are in is showing, rather than opening one.
    ///
    /// A tab is a slot. Pressing Tasks while looking at a board turns *this* view into the notes,
    /// exactly as following a link in a browser tab changes what that tab holds — and opening another
    /// view alongside it is a different gesture with its own command.
    func setRenderer(_ next: ProjectRenderer) {
        split.replaceSelected(with: next == .canvas ? .board(.whole) : .notes)
        renderer = split.renderer
        applyWidthLimits()
        // What the split actually settled on, which is not always what was asked for: a project with
        // no canvas lands on the empty state, and both memories should record the ask rather than a
        // failure that would send the window straight back into it on every launch.
        ProjectRendererMemory.remember(split.renderer, for: projectKey)
        ProjectTabMemory.remember(split.tabs, for: projectKey)
    }

    // MARK: Tabs

    /// View ▸ New Tab. Another view of this project beside the one you are in — the notes if you
    /// are on a board, the board if you are on the notes, which is the tab you most likely wanted and
    /// the one you can change with the switch if it wasn't.
    @objc func newProjectTab(_ sender: Any?) {
        split.openTab(renderer == .canvas ? .notes : .board(.whole))
    }

    @objc func closeProjectTab(_ sender: Any?) {
        split.tabModel.close(split.tabs.selectedID)
    }

    @objc func selectNextProjectTab(_ sender: Any?) { split.cycleTabs(by: 1) }
    @objc func selectPreviousProjectTab(_ sender: Any?) { split.cycleTabs(by: -1) }

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
        case #selector(toggleCanvasRenderer(_:)):
            item.state = renderer == .canvas ? .on : .off
            return store.projectName != nil
        case #selector(newProjectTab(_:)):
            return store.projectName != nil
        case #selector(closeProjectTab(_:)), #selector(selectNextProjectTab(_:)),
             #selector(selectPreviousProjectTab(_:)):
            // Dim at one tab: the last tab never closes, and there is nothing to cycle between.
            return split.tabs.tabs.count > 1
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
