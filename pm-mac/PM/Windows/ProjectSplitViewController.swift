import AppKit
import SwiftUI

/// A project window's content: the project sidebar beside the task column, as a real
/// `NSSplitViewController`.
///
/// The two panes used to be a SwiftUI `HStack` with a fixed-width sidebar, which meant hand-rolling
/// everything AppKit already does here — the vibrancy behind a source list, the collapse animation,
/// the draggable divider, remembering its width, and the titlebar inset that lets the traffic lights
/// sit over the sidebar. A split view controller brings all of that, and it's what lets each pane live
/// in its own hosting controller.
///
@MainActor
final class ProjectSplitViewController: NSSplitViewController {
    private(set) var store: PMStore
    let state: ProjectWindowState
    /// Whether this window opens with its sidebar showing. The first window of a session takes the
    /// persisted preference; later ones start collapsed — a second window is opened to look at another
    /// project *beside* the first, and a second copy of the project list isn't what it's for.
    private let startsWithSidebar: Bool

    private var sidebarItem: NSSplitViewItem!
    private var contentItem: NSSplitViewItem!
    private var sidebarHosting: NSHostingController<ProjectSidebar>!
    /// The container the content column's two renderers take turns in — see
    /// `ProjectContentPaneController`.
    private let contentPane = ProjectContentPaneController()

    /// Whether this controller is currently holding the shared project scan open. It owns that retain
    /// rather than the sidebar view, because a collapsed split item keeps its view mounted — the view
    /// can't tell it's been hidden, and would go on paying for a scan nobody can see.
    private var holdsProjectScan = false

    /// Keeps `state.sidebarVisible` (and the scan retain) in step with the sidebar item's real collapsed
    /// state, whoever changed it. See where it's installed in `viewDidLoad`.
    private var collapseObservation: NSKeyValueObservation?

    init(store: PMStore, state: ProjectWindowState, startsWithSidebar: Bool) {
        self.store = store
        self.state = state
        self.startsWithSidebar = startsWithSidebar
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()

        sidebarHosting = NSHostingController(rootView: ProjectSidebar(store: store, state: state))
        wireTabModel()
        // The sidebar keeps `.minSize`, and this is the whole reason its collapse animation looks like
        // a sidebar rather than a glitch: while a split item animates, AppKit sizes the pane's content
        // view to its *fitting* width and slides it in from behind the divider. A hosting view with no
        // sizing options has no fitting width to speak of — AppKit gave it 10pt — so all that slid past
        // was a 10pt slice of the middle of the rows. With `.minSize` the pane's content view keeps the
        // width SwiftUI asks for (see `ProjectSidebar`'s frozen layout), and the whole sidebar slides.
        sidebarHosting.sizingOptions = [.minSize]

        // An `NSHostingView` reports its SwiftUI ideal size as an intrinsic size and defends it with
        // the default (500) hugging and compression-resistance priorities — which outrank the split
        // view's own dragging constraints, so the divider simply won't move. Standing both panes down
        // to `.defaultLow` hands the width decision back to the split view, which is what makes the
        // divider draggable and what lets the sidebar honour its min/max thicknesses.
        for view in [sidebarHosting.view, contentPane.view] {
            view.setContentHuggingPriority(.defaultLow, for: .horizontal)
            view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }

        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarHosting)
        sidebarItem.minimumThickness = ProjectWindow.sidebarMinWidth
        sidebarItem.maximumThickness = ProjectWindow.sidebarMaxWidth
        sidebarItem.canCollapse = true
        // *Above* the content's. A split view resizes its lowest-priority pane first, so the pane you
        // want to hold still is the one with the higher number — this was the wrong way round, and the
        // sidebar was taking every point the window gained or lost. The sidebar's width is something
        // the user set once, by dragging; resizing a window is not a request to change it.
        sidebarItem.holdingPriority = .defaultLow + 1
        // A sidebar collapses by resizing the *window* by default — show it and the window grows by
        // its width. That is the same coupling from the other side, and it is intolerable for the
        // auto-hide below, which runs mid-drag: the window would fight the edge the user is dragging.
        // With this the window is left alone and the task column takes the space, so the only thing
        // that ever moves a window edge is a hand on it (or `makeRoomForSidebar`, which is asked for).
        sidebarItem.collapseBehavior = .preferResizingSiblingsWithFixedSplitView

        contentItem = NSSplitViewItem(viewController: contentPane)
        contentItem.minimumThickness = ProjectWindow.minContentWidth
        contentItem.canCollapse = false
        contentItem.holdingPriority = .defaultLow

        // Both panes run the full height of the window, under the (hidden) titlebar.
        for item in [sidebarItem!, contentItem!] {
            item.allowsFullHeightLayout = true
            // No toolbar and no visible title, so there's no titlebar for AppKit to draw a separator
            // under; the rule below the task header is the app's own, and a second line at the
            // titlebar's bottom edge would sit a few points above it.
            item.titlebarSeparatorStyle = .none
        }

        // The task column runs *beneath* the floating sidebar, with a safe area keeping its content in
        // the clear — the sidebar is a pane of glass over the window's content in the current design,
        // not a column beside it, so the window reads as one surface rather than two abutting ones.
        // This goes on the content item and not the sidebar: it describes what extends under what.
        //
        // The column's own header still declines the *top* safe area, because it deliberately runs up
        // into the titlebar to sit level with the traffic lights. Only the leading inset is wanted here,
        // and that's the one this supplies while the sidebar is showing.
        contentItem.automaticallyAdjustsSafeAreaInsets = true

        // The arrange menu, in the strip along the bottom of the source list. An accessory rather than
        // a bar inside the sidebar's own SwiftUI: AppKit floats it over the list, insets the rows above
        // it, and folds it into the scroll edge effect, none of which a view in the pane can do for
        // itself. It's also what frees the pane of the header bar it used to need.
        let bottomBar = NSSplitViewItemAccessoryViewController()
        let bottomBarHosting = NSHostingController(rootView: SidebarBottomBar())
        // `.minSize` so the accessory takes the bar's own height from SwiftUI rather than being sized
        // by AppKit — the same reason the sidebar itself uses it.
        bottomBarHosting.sizingOptions = [.minSize]
        bottomBar.addChild(bottomBarHosting)
        bottomBar.view = bottomBarHosting.view
        sidebarItem.addBottomAlignedAccessoryViewController(bottomBar)

        addSplitViewItem(sidebarItem)
        addSplitViewItem(contentItem)

        // One autosave name for every project window: the sidebar's width is a per-app preference, not
        // a per-project one, so dragging it in any window sets it for the next window you open.
        splitView.autosaveName = "PMProjectSplit"
        splitView.dividerStyle = .thin

        // After `addSplitViewItem`, not before: an item that hasn't joined its controller yet has no
        // split view to collapse in, and the assignment is quietly dropped — which is why windows meant
        // to open with the sidebar hidden were opening with it showing. And after the autosave name,
        // because setting that restores the saved subview frames — which record a width *and* a
        // collapsed flag, so a restore lands on top of this and re-opens a sidebar the window asked to
        // start without. Autosave is here for the width; visibility is this window's call.
        sidebarItem.isCollapsed = !startsWithSidebar

        // `state.sidebarVisible` is a mirror of the pane, so it follows the pane rather than being
        // written wherever something happens to collapse it. The two ways round it are exactly the ones
        // above — an autosave restore, and dragging the divider onto the window edge, neither of which
        // goes near `toggleSidebar` — and a stale mirror is visible in the content column, which reads
        // it to decide whether its header has to start clear of the traffic lights. With the sidebar
        // showing and the flag still saying otherwise, the project title was inset past lights that
        // were sitting over the sidebar, leaving a gap the width of them beside the divider.
        collapseObservation = sidebarItem.observe(\.isCollapsed, options: [.initial, .new]) { [weak self] item, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.state.sidebarVisible = !item.isCollapsed
                self.syncProjectScan()
                // With the sidebar showing, the traffic lights sit over *it* and a board in the content
                // column needs no inset of its own — the same rule the task column's header follows.
                self.canvasPane?.ignoresTrafficLights = !item.isCollapsed
            }
        }

        // `queue: nil` so it runs synchronously inside the resize that posted it, rather than a turn of
        // the run loop later — the whole point is to decide within the frame the window is being
        // dragged through.
        resizeObservation = NotificationCenter.default.addObserver(
            forName: NSSplitView.didResizeSubviewsNotification, object: splitView, queue: nil
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self else { return }
                // A divider index means a hand on the divider — the one thing that sets the sidebar's
                // width. Everything else that resizes these subviews is the window changing size, and
                // must not be mistaken for the user asking for a narrower sidebar.
                if note.userInfo?["NSSplitViewDividerIndex"] != nil { self.recordSidebarWidth() }
                self.syncSidebarForAvailableWidth()
            }
        }
    }

    /// Take the sidebar's current width as the width to hold it at.
    private func recordSidebarWidth() {
        guard !sidebarItem.isCollapsed else { return }
        sidebarWidthAtRest = min(max(sidebarItem.viewController.view.frame.width,
                                     ProjectWindow.sidebarMinWidth),
                                 ProjectWindow.sidebarMaxWidth)
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        // Seed the divider on a first run. Without an autosaved position the split view splits the
        // available width by holding priority, which hands the sidebar far more than it wants.
        guard !didSeedDividerPosition, !sidebarItem.isCollapsed else { return }
        didSeedDividerPosition = true
        let autosaved = splitView.autosaveName.map {
            UserDefaults.standard.object(forKey: "NSSplitView Subview Frames \($0)") != nil
        } ?? false
        if !autosaved { splitView.setPosition(ProjectWindow.sidebarWidth, ofDividerAt: 0) }
        // The restored width is a width the user dragged to, in some window, at some point — which is
        // exactly what the auto-hide holds the sidebar at. Without this the window would open honouring
        // the default instead of the sidebar in front of the user.
        recordSidebarWidth()
    }

    private var didSeedDividerPosition = false

    /// Identifies the in-flight sidebar animation, so a completion handler that belongs to a toggle
    /// that's already been superseded can't clear `sidebarAnimating` out from under the current one.
    private var settleToken = 0

    // MARK: Auto-hide

    /// The width the user has put the sidebar at. Deliberately *not* re-read from the pane on every
    /// layout: as a window narrows past what fits, the split view squeezes the sidebar before this
    /// code gets a look in, and a threshold measured from the squeezed width would chase itself down
    /// and never fire. It changes when the divider is dragged, and at no other time.
    private var sidebarWidthAtRest = ProjectWindow.sidebarWidth

    /// Whether the sidebar is hidden because the window ran out of room for it, rather than because
    /// somebody asked for it to be hidden. Only the former comes back on its own.
    private var sidebarHiddenForWidth = false

    /// Watches the split view's own resizes — see `syncSidebarForAvailableWidth`.
    private var resizeObservation: NSObjectProtocol?

    /// The narrowest this window can be and still show the sidebar at its set width beside a task
    /// column at *its* minimum.
    private var widthNeededForSidebar: CGFloat {
        sidebarWidthAtRest + splitView.dividerThickness + ProjectWindow.minContentWidth
    }

    /// Hide the sidebar when the window is too narrow to hold it beside a usable task column, and give
    /// it back when the window is wide enough again.
    ///
    /// This is the *only* thing window width is allowed to do to the sidebar; short of vanishing, it
    /// stays exactly the width the divider was left at.
    private func syncSidebarForAvailableWidth() {
        guard isViewLoaded, splitView.bounds.width > 0 else { return }
        // A point of slack. Widths land on fractional points, and a sidebar that hides itself because
        // the window came up half a point short is not what "too small" means.
        let hasRoom = splitView.bounds.width + 1 >= widthNeededForSidebar
        // Set directly rather than through the animator: this rides a live resize drag, and a slide
        // that takes a quarter second to catch up with the window edge reads as lag, not animation.
        if !hasRoom, !sidebarItem.isCollapsed {
            sidebarHiddenForWidth = true
            sidebarItem.isCollapsed = true
        } else if hasRoom, sidebarHiddenForWidth, sidebarItem.isCollapsed {
            sidebarHiddenForWidth = false
            sidebarItem.isCollapsed = false
        }
    }

    /// `viewWillLayout` catches the window's own resizes, but a point late: the split view has already
    /// squeezed the sidebar by the time it runs, so the pane visibly narrows for a frame before it
    /// goes. The notification fires as part of that same resize, which is why both are here.
    override func viewWillLayout() {
        super.viewWillLayout()
        syncSidebarForAvailableWidth()
    }

    /// Widen the window enough to show the sidebar, for a window that hasn't the room.
    ///
    /// Asking for the sidebar in a narrow window has to mean something, and the two honest answers are
    /// "squeeze the task column" — which its minimum forbids — and this one. Without it the pane would
    /// appear and the next layout pass would auto-hide it straight back, so the toggle would look
    /// broken in exactly the windows the auto-hide exists for.
    private func makeRoomForSidebar() {
        guard let window = view.window else { return }
        let shortfall = widthNeededForSidebar - splitView.bounds.width
        guard shortfall > 0 else { return }
        var frame = window.frame
        frame.size.width += shortfall
        window.setFrame(window.constrainFrameRect(frame, to: window.screen), display: true)
    }

    // MARK: What the column shows

    /// This window's tabs. One on the notes is what the window has always been; the rest is new.
    private(set) var tabs = ProjectTabSet()
    /// What both headers draw the bar from. See `ProjectTabModel`.
    let tabModel = ProjectTabModel()

    /// Where the project's board is and what to call it.
    ///
    /// A closure rather than arguments, because a tab is switched from inside this controller — a click
    /// on the bar — and there is nobody to pass them in at that moment. The window supplies it; the
    /// store belongs to the window.
    ///
    /// It used to carry a third member, `create`, for the empty state's button. Nothing asks to have a
    /// canvas made any more: having one is a consequence of opening the project, so the making is
    /// `ensureCanvas` and there is nobody left to press.
    var canvasSource: () -> (url: URL?, name: String?) = { (nil, nil) }

    /// Which renderer is up. Read by the window for its menu checkmark and its width cap.
    var renderer: ProjectRenderer { tabs.selected.view.isBoard ? .canvas : .tasks }

    /// The board the window is showing, if it is showing one.
    var canvasPane: CanvasPaneController? { contentPane.current as? CanvasPaneController }

    // MARK: Driving the tabs

    /// Show this set of tabs. `canvasPending` says the project's board is still being looked for, so a
    /// board tab has to hold still rather than answer — see `ProjectWindowController`.
    func setTabs(_ next: ProjectTabSet, canvasPending pending: Bool = false) {
        // A pane built while the board was still being looked for is a placeholder, and `applySelectedTab`
        // would find it in the cache and show it again for good. Dropped the moment the waiting ends.
        if canvasPending, !pending { contentPane.dropAll() }
        canvasPending = pending
        canvasUnavailable = false
        triedReplacingCanvas = false
        tabs = next
        applySelectedTab()
    }

    /// Set while a board tab has nothing to show *yet* — as opposed to nothing to show.
    private var canvasPending = false

    private func wireTabModel() {
        tabModel.select = { [weak self] id in
            guard let self, id != tabs.selectedID else { return }
            tabs.select(id)
            applySelectedTab()
        }
        tabModel.close = { [weak self] id in
            guard let self, tabs.close(id) else { return }
            // After the switch, not before: the pane being torn down may be the one on screen, and a
            // window with nothing in it for one turn of the run loop flickers.
            applySelectedTab()
            contentPane.drop(tab: id)
        }
        tabModel.move = { [weak self] id, index in
            guard let self else { return }
            tabs.move(id, to: index)
            refreshTabModel()
            // The row's order is part of how the window was left, so it goes to the same place the
            // rest of the tabs do — nothing on screen changed, only what is remembered.
            onRendererChanged?()
        }
        tabModel.openNotes = { [weak self] in self?.openTab(.notes) }
        tabModel.openBoard = { [weak self] in self?.goToCanvas() }
        tabModel.openFrame = { [weak self] id in self?.openTab(.board(.frame(id))) }
        tabModel.openWorkspace = { [weak self] name in self?.openTab(.board(.workspace(name))) }
        tabModel.goToCanvas = { [weak self] in self?.goToCanvas() }
        tabModel.tileAsWorkspace = { [weak self] tiling in self?.tileAsWorkspace(tiling) ?? false }
        tabModel.selectWorkspace = { [weak self] name in self?.selectWorkspace(name) ?? false }
        tabModel.renameWorkspace = { [weak self] name in self?.renameWorkspace(named: name) }
        tabModel.duplicateWorkspace = { [weak self] name in self?.duplicateWorkspace(named: name) }
        tabModel.deleteWorkspace = { [weak self] name in self?.deleteWorkspace(named: name) }
        tabModel.renameTab = { [weak self] id, name in self?.renameTab(id, to: name) }
    }

    /// Open this view in a tab, or go to the tab already showing it.
    ///
    /// **A second chip on one thing is two names for it**, and picking between them is a question with
    /// no answer — so opening what is open is switching to it. That is the same call `WindowManager`
    /// makes for a project that already has a window, and under docs/canvas-workspaces.md §7c it is
    /// what lets the bar be read as the list of what you have open.
    func openTab(_ view: ProjectTabView) {
        if let existing = tabs.first(showing: view) {
            tabs.select(existing.id)
        } else {
            tabs.open(view)
        }
        applySelectedTab()
    }

    /// ⌃⇥ / ⌃⇧⇥.
    func cycleTabs(by step: Int) {
        guard tabs.tabs.count > 1 else { return }
        tabs.selectNext(by: step)
        applySelectedTab()
    }

    /// ⌘1…⌘9 — see `ProjectWindowController.selectProjectTabByIndex`. `.max` is "the last one".
    func selectTab(at index: Int) {
        guard tabs.tabs.count > 1 else { return }
        tabs.select(at: index)
        applySelectedTab()
    }

    /// Build (or reveal) the content for the tab that is up, and tell everyone what changed.
    func applySelectedTab() {
        let tab = tabs.selected
        if let existing = contentPane.content(for: tab.id) {
            contentPane.show(existing, for: tab.id)
        } else {
            let made = makeContent(for: tab)
            contentPane.show(made, for: tab.id)
        }
        canvasPane?.focusBoard()
        refreshTabModel()
        onRendererChanged?()
    }

    /// The controller a tab needs, made fresh.
    ///
    /// **Every tab in a project window is a board.** The notes are the project's own card tiled alone
    /// (docs/canvas-workspaces.md §7d); everything else is that board at some other scale. So there is
    /// one path here and one fallback, where there used to be two of each.
    private func makeContent(for tab: ProjectTab) -> NSViewController {
        let focus: CanvasFocus = if case .board(let pinned) = tab.view { pinned } else { .note }
        if let pane = makeBoard(focus) { return pane }
        if replaceUnreadableCanvasOnce(), let pane = makeBoard(focus) { return pane }
        return makeBoardless()
    }

    /// The project's canvas is on disk and will not open. Replace it, once.
    ///
    /// **Under the invariant this is not a state to render, it is a file to fix.** A project has a
    /// canvas; a file that will not parse is not one, and the fallback it used to earn — the whole task
    /// column — coupled reaching your tasks to a sidecar file that does not hold them. Nothing is
    /// destroyed: the unreadable file keeps its name with the date on it, and the pane that opens says
    /// so and offers to show it. See `PmLib.replaceUnreadableCanvas`.
    ///
    /// **Once per project per window.** A second failure straight after a replacement is not a broken
    /// canvas — it is a vault that cannot be written to, and writing the file again would not help. So
    /// that falls through to the pane that says so.
    ///
    /// Only the project's own board, never a window opened on somebody's canvas file: `replaceCanvas`
    /// answers nil for those. The declaration is about projects, and a `.canvas` you asked PM to open
    /// is a document you are looking at, not a file the app is entitled to rewrite.
    private func replaceUnreadableCanvasOnce() -> Bool {
        guard !triedReplacingCanvas, canvasSource().url != nil else { return false }
        triedReplacingCanvas = true
        guard let kept = replaceCanvas() else { return false }
        replacementNotice = ("This project's canvas couldn't be read, so PM made a new one. "
                                 + "Your old board is still in the folder.", kept)
        return true
    }

    /// Set once a replacement has been tried for the project this window is on. Cleared with
    /// `canvasUnavailable`, which is to say whenever the window takes a different project.
    private var triedReplacingCanvas = false

    /// What the next board pane should say about the file it was given, and the file to show for it.
    /// Consumed by the first pane made after a replacement — there is only ever one notice, and saying
    /// it again in every tab would be nagging rather than reporting.
    private var replacementNotice: (message: String, file: URL?)?

    /// What a tab shows when the board could not be put on screen.
    ///
    /// Under the invariant there is no third case: a project has a canvas, and if one is not there yet
    /// it is being made. So this is a wait or a failure, and never a question — the empty state that
    /// used to offer to create one is gone with the ask that needed it.
    ///
    /// **Nothing to show yet is not nothing to show.** A project's canvas path arrives with its first
    /// read of the folder, so for a moment after a switch every project looks like a project without a
    /// board. Answering then puts a whole view on screen and takes it away again. The tab holds still
    /// instead; it is milliseconds, and there is nothing worth saying inside them.
    ///
    /// A canvas that is *on disk* and will not open is the failure, not the wait — making one is no
    /// answer when the file is already there — so that goes straight to the column, as does a creation
    /// that came back empty-handed. See `canvasUnavailable`.
    private func makeBoardless() -> NSViewController {
        guard canvasSource().url == nil, !canvasUnavailable else { return makeTroublePane() }
        if !canvasPending { afterCurrentUpdate { [weak self] in self?.ensureCanvas() } }
        return ProjectWaitingPaneController()
    }

    private func makeBoard(_ focus: CanvasFocus) -> CanvasPaneController? {
        let source = canvasSource()
        guard let url = source.url, let store = try? CanvasStoreRegistry.store(for: url) else {
            // A canvas that won't parse, or a project whose one is not there yet. `makeBoardless`
            // tells those two apart and answers each; File ▸ Open Canvas reports a parse error
            // properly for anyone who went at the file directly.
            return nil
        }
        let pane = CanvasPaneController(store: store, tabs: tabModel)
        pane.openingNotice = replacementNotice
        replacementNotice = nil
        pane.title_ = source.name ?? url.deletingPathExtension().lastPathComponent
        pane.ignoresTrafficLights = !sidebarItem.isCollapsed
        pane.focus = focus
        pane.onTilingChanged = { [weak self] in self?.refreshTabModel() }
        return pane
    }

    /// What is left when the window cannot show this project: a sentence and how to act on it.
    ///
    /// This is where the task column used to be. It stopped being an answer when the notes became a
    /// card on the board — a fallback that renders the whole application is a second implementation of
    /// it, kept alive by a case that should not exist — and the case itself is gone now: a canvas that
    /// will not parse is replaced rather than fallen back from. See `ProjectTrouble`.
    private func makeTroublePane() -> NSViewController {
        ProjectTroublePaneController(message: troubleMessage)
    }

    private var troubleMessage: ProjectTrouble.Message {
        ProjectTrouble.message(hasProject: store.projectKey != nil,
                               errorMessage: store.errorMessage,
                               goToProjectKeys: ShortcutHint.keys(.quickGoToProject))
    }

    /// Make the project's board if it hasn't got one — supplied by the window, which owns the store.
    ///
    /// A project window needs a canvas the moment it opens now, because its notes are a card on one.
    /// That is the convention `PMStore.openableCanvasPath` has always stated in its own words: a
    /// project is assumed to have a canvas, so opening one is never a two-step ceremony of "make it,
    /// then open it".
    var ensureCanvas: () -> Void = {}

    /// Replace this project's unreadable canvas, and say where the old file was kept — supplied by the
    /// window, which owns the store. Nil when there is nothing to replace, or when the window is
    /// showing a canvas it was opened on rather than a project's own.
    var replaceCanvas: () -> URL? = { nil }

    /// Set once making the board has been tried and failed, so a tab stops waiting for one and shows
    /// the column instead. Cleared when the window takes a different project.
    ///
    /// Load-bearing rather than incidental: with no empty state left to land on, this is the only thing
    /// standing between a vault that cannot be written to and a window that waits for ever.
    private(set) var canvasUnavailable = false

    /// The board could not be made. Told by the window, which is where the error is reported.
    ///
    /// Whatever tab is up, not only the notes: every tab wants a board now, so every tab is waiting on
    /// this answer and every tab has the same fallback.
    func canvasCouldNotBeMade() {
        guard !canvasUnavailable else { return }
        canvasUnavailable = true
        contentPane.drop(tab: tabs.selectedID)
        applySelectedTab()
    }

    /// Say what the bar should now draw. The names of pinned tabs come from the board's own document —
    /// a frame's label is the frame's, not the tab's — so a frame renamed in Obsidian renames the tab
    /// that points at it, and one deleted leaves a tab that says so rather than one that vanishes.
    func refreshTabModel() {
        let board = canvasPane
        tabModel.items = tabs.tabs.map { tab in
            switch tab.view {
            case .board(.whole):
                // The canvas, drawn as a glyph. It has no name because it is not one of the places —
                // it is the board the places are places *in*. See `ProjectTabItem.isCanvas`.
                return ProjectTabItem(id: tab.id, name: "Canvas", isCanvas: true, closable: false)
            case .notes, .board(.note):
                // Nothing opens a `.note` tab — `onOpenInTab` sends the note to a `.notes` tab, which
                // is what a notes tab is. Drawn the same either way, so a stored tab from some future
                // that does open one still says what it is.
                return ProjectTabItem(id: tab.id, name: "Notes")
            case .board(.frame(let node)):
                return ProjectTabItem(id: tab.id, name: board?.frameName(node) ?? "Frame")
            case .board(.workspace(let name)):
                // A workspace's chip is the workspace (§7i), so it does not close — the way to be rid
                // of one is Delete, on this chip's own menu.
                return ProjectTabItem(id: tab.id, name: name, workspaceName: name, closable: false)
            }
        }
        tabModel.selectedID = tabs.selectedID
        tabModel.frames = board?.frames() ?? []
    }

    // MARK: The workspaces this window has open

    /// **Show the canvas** — the pill's ✕, ⌘−, and ⌘↩ with nothing left to narrow.
    ///
    /// A tab stopped following its board here, and this is what replaced it. The old rule was that a
    /// tab *became* whatever its pane was showing: zoom out of Dashboard and the chip renamed itself to
    /// Canvas, while a second chip was inserted behind it so the workspace you had just left did not
    /// vanish from the window. Three things moved for one gesture, which is where the reflow came from.
    ///
    /// Now nothing moves. A workspace tab is its workspace for as long as the workspace exists (§7i),
    /// so leaving one is not an edit to anything — it is going to a different tab, and the canvas is a
    /// tab. The pane you were in keeps its tiles, so coming back to its chip is instant and exact.
    func goToCanvas() {
        guard tabs.selectedID != tabs.canvasID else { return }
        tabs.select(tabs.canvasID)
        applySelectedTab()
    }

    /// **⌘Return, on a board that is not tiled.** Keep this tiling as a workspace and open it.
    ///
    /// Every set of tiles is a workspace and every workspace has a name (§7i), so there is no state
    /// this could produce that is "tiled, but not yet anything" — the act that makes the tiling is the
    /// act that makes the workspace. The name is assigned rather than asked for, because ⌘Return is the
    /// board's fastest gesture and a modal in front of it would be a modal in front of fullscreening a
    /// card. It is renameable in place from its chip the moment it exists.
    ///
    /// **The same cards resume the same workspace rather than making a second.** Otherwise every
    /// ⌘Return on the six cards you always tile would leave another Workspace 7 behind and the row
    /// would fill with copies of one thing. This is the job the volatile untitled workspace used to do,
    /// done by the store instead, and it is what makes retiring that one affordable.
    ///
    /// - Returns: whether the window took it. False leaves the board to tile itself, which is the right
    ///   answer for a board with no canvas file to keep a workspace in.
    func tileAsWorkspace(_ tiling: CanvasViewState.Tiling) -> Bool {
        guard let url = canvasSource().url else { return false }
        let wanted = Set(tiling.ids)
        let existing = CanvasWorkspaces.of(url).first { Set($0.value.ids) == wanted }?.key
        let name = existing ?? WorkspaceNamePrompt.freshName(avoiding: CanvasWorkspaces.names(of: url))
        if existing == nil { CanvasWorkspaces.save(tiling, as: name, for: url) }
        openTab(.board(.workspace(name)))
        return true
    }

    /// Go to the tab already showing this workspace. False when none is, which is the caller's cue to
    /// switch the board it has — see `CanvasPaneController.goToWorkspace(named:)`.
    private func selectWorkspace(_ name: String) -> Bool {
        guard let tab = tabs.first(showing: .board(.workspace(name))), tab.id != tabs.selectedID
        else { return false }
        tabs.select(tab.id)
        applySelectedTab()
        return true
    }

    /// A chip's label, typed into rather than picked from a menu.
    ///
    /// Only a workspace chip has an editable label — the canvas has no name, and the other two are
    /// named after what they show rather than by you — so this is always a rename. It used to fork: a
    /// chip could be a workspace *without* a name, and typing into that one was naming it. §7i retired
    /// the state, and the fork with it.
    func renameTab(_ id: String, to name: String) {
        guard let old = tabs.tabs.first(where: { $0.id == id })?.view.workspaceName else { return }
        renameWorkspace(named: old, to: name)
    }

    /// Rename a workspace, **and carry its chips across with it**.
    ///
    /// §7b accepted that renaming broke a tab pinned to the old name, on the grounds that the name is
    /// the whole of a workspace's identity and a pin that stops resolving lands on the board. That is
    /// still true of pins in *other* windows. It stopped being true here the moment a tab became where
    /// a workspace lives: this window knows every chip on the old name, so it moves them.
    ///
    /// A remove and a save rather than a key change, because there is nothing underneath the name to
    /// re-key. Saved before the old one is removed, so a failure leaves you with both rather than
    /// neither.
    func renameWorkspace(named old: String) {
        guard let url = canvasSource().url, CanvasWorkspaces.tiling(named: old, of: url) != nil,
              let new = WorkspaceNamePrompt.run(titled: "Rename “\(old)”", seed: old)
        else { return }
        renameWorkspace(named: old, to: new)
    }

    /// The rename itself, with the name already decided — typed into the chip, or come back from the
    /// prompt above.
    func renameWorkspace(named old: String, to new: String) {
        guard old != new, let url = canvasSource().url,
              let tiling = CanvasWorkspaces.tiling(named: old, of: url)
        else { return }
        // Renaming *onto* a name is replacing what has it — the save below does not ask, because for
        // the live write-through it must not. See `WorkspaceNamePrompt.confirmReplacing`.
        guard !CanvasWorkspaces.exists(new, of: url) || WorkspaceNamePrompt.confirmReplacing(new)
        else { return }
        CanvasWorkspaces.save(tiling, as: new, for: url)
        CanvasWorkspaces.remove(old, for: url)
        for tab in tabs.tabs where tab.view == .board(.workspace(old)) {
            tabs.retarget(tab.id, to: .board(.workspace(new)))
            let pane = contentPane.content(for: tab.id) as? CanvasPaneController
            pane?.focus = .workspace(new)
            pane?.workspaceRenamed(from: old, to: new)
        }
        // A rename onto a name that had a chip of its own has just made two chips saying it.
        closeDuplicateTabs()
        refreshTabModel()
    }

    /// Sweep up after a pass that retargeted tabs in bulk — see `ProjectTabSet.collapseDuplicates`.
    ///
    /// The panes go after the switch rather than before it, which is the order `tabModel.close` uses
    /// and for the same reason: the one being torn down may be the one on screen, and a window with
    /// nothing in it for a turn of the run loop flickers.
    private func closeDuplicateTabs() {
        let closed = tabs.collapseDuplicates()
        guard !closed.isEmpty else { return }
        applySelectedTab()
        for id in closed { contentPane.drop(tab: id) }
    }

    /// Copy a workspace and open the copy — backlog item 10, and the last of §7b.
    ///
    /// You have built a six-tile workspace and want a variant of it; before this the only answer was to
    /// build the variant from scratch. §7b made that shortage sharper rather than easier: a named
    /// workspace is adjusted **live**, so "let me try something without wrecking this one" had nowhere
    /// left to go. It goes here.
    ///
    /// Copied from the store rather than from a board, so a workspace you are not looking at can be
    /// duplicated from its chip. For the one you are in they are the same bytes anyway — the
    /// write-through keeps the durable row level with the screen.
    ///
    /// The copy arrives in its own tab and takes the selection, which is the shape every act that
    /// *makes* a workspace now has, ⌘Return included.
    func duplicateWorkspace(named old: String) {
        guard let url = canvasSource().url,
              let tiling = CanvasWorkspaces.tiling(named: old, of: url)
        else { return }
        let taken = CanvasWorkspaces.names(of: url)
        guard let new = WorkspaceNamePrompt.run(
            titled: "Duplicate “\(old)”",
            seed: WorkspaceNamePrompt.copyName(of: old, avoiding: taken)), new != old
        else { return }
        // The seed counts past the copies that exist; what is typed over it need not.
        guard !taken.contains(new) || WorkspaceNamePrompt.confirmReplacing(new) else { return }
        CanvasWorkspaces.save(tiling, as: new, for: url)
        openTab(.board(.workspace(new)))
    }

    /// Forget a workspace, **and take its chip with it**.
    ///
    /// Delete is the only verb here that removes a workspace, and since §7i it is the only one that
    /// removes a chip: the row is the list of workspaces, so a chip that outlived its workspace would
    /// be a chip the next refresh puts back. What is on the board is untouched — the cards are where
    /// they were, and the tiles were a view rather than a thing being destroyed.
    ///
    /// **Asked about first**, which it was not for most of this feature's life. The paragraph above is
    /// the whole reason it felt safe to ship without a question, and it is only half the story: the
    /// tiles survive, and the *workspace* — the thing you named so it would be there next month — does
    /// not, with no undo to reach for. See `WorkspaceNamePrompt.confirmDelete`.
    func deleteWorkspace(named name: String) {
        guard let url = canvasSource().url, WorkspaceNamePrompt.confirmDelete(name) else { return }
        CanvasWorkspaces.remove(name, for: url)
        let doomed = tabs.tabs.filter { $0.view == .board(.workspace(name)) }.map(\.id)
        tabs.drop { $0.view == .board(.workspace(name)) }
        // After the switch, not before: the pane being torn down may be the one on screen, and a
        // window with nothing in it for one turn of the run loop flickers.
        applySelectedTab()
        for id in doomed { contentPane.drop(tab: id) }
        refreshTabModel()
    }

    /// Back to the notes — View ▸ Show Canvas turning itself off. A tab of its own rather than a
    /// replacement: the canvas tab cannot become something else, and the notes already have a chip if
    /// they are open at all.
    func showTasks() { openTab(.notes) }

    /// Show the project's board, which is the canvas tab every window has.
    func showCanvas() { goToCanvas() }

    /// The project's board has appeared (or moved) since a tab was built. Rebuild the tab that is
    /// waiting on it, so a canvas that has just been made lands on screen rather than leaving the
    /// window on the pane that was holding still for it.
    func canvasPathChanged() {
        canvasUnavailable = false
        triedReplacingCanvas = false
        let wantsBoard = tabs.selected.view.isBoard || tabs.selected.view == .notes
        guard wantsBoard, !(contentPane.current is CanvasPaneController) else { return }
        contentPane.drop(tab: tabs.selectedID)
        applySelectedTab()
    }

    /// Told when the column changes what it is showing, so the window can re-apply its width cap and
    /// its menus can re-validate.
    var onRendererChanged: (() -> Void)?

    /// The board's undo stack while one is showing, so ⌘Z in this window reaches the board rather than
    /// the task list — and, because the store is shared, undoes in the canvas's own window too.
    ///
    /// Asked of the pane rather than of its store, because a card you are typing in answers first: an
    /// open editor's ⌘Z is its own typing, not the document's. See `CanvasPaneController`.
    var undoManagerForContent: UndoManager? { canvasPane?.undoManagerForContent }

    // MARK: Retargeting

    /// Point this window at a different project. The store is swapped rather than rebound: stores are
    /// shared per project (see `StoreRegistry`), so rebinding one would quietly change the project for
    /// every other holder of it.
    func retarget(to newStore: PMStore, projectKey: String?) {
        guard newStore !== store else { return }
        store = newStore
        sidebarHosting.rootView = ProjectSidebar(store: newStore, state: state)
        // Every tab was a view of the *old* project, so none of them survive. The window follows this
        // with the new project's own remembered tabs; rebuilding here as well is what keeps the column
        // from being empty for the turn of the run loop in between.
        contentPane.dropAll()
        applySelectedTab()
        // The sidebar's selection *is* the window's project (see `ProjectSidebar`), so a switch moves
        // it — including a switch that came from somewhere else entirely, like Open Recent. Written
        // after the sidebar has been rebound to the new store, so the change is read against the
        // project the window is now on rather than the one it was on a line ago.
        // The key rather than `newStore.projectKey`: a store created for this switch doesn't know its
        // own project until its first (asynchronous) read lands.
        state.projectSelection = projectKey.map { [$0] } ?? []
    }

    // MARK: Sidebar

    var isSidebarCollapsed: Bool { sidebarItem.isCollapsed }

    /// Show/hide *this window's* sidebar. The View menu's ⌥⌘S and the header's toggle both land here.
    ///
    /// Sidebar visibility is per window, like every other source-list app: hiding it in one window
    /// doesn't reach into the others. The persisted value is only the default a first window opens
    /// with, so the app comes back the way you left it.
    override func toggleSidebar(_ sender: Any?) {
        // An explicit toggle outranks the auto-hide in both directions: showing it means the window
        // makes room, and hiding it means it stays hidden however wide the window gets.
        sidebarHiddenForWidth = false
        if sidebarItem.isCollapsed { makeRoomForSidebar() }

        // Set before the animation starts, cleared once it's over: the sidebar only pins its layout and
        // clips while it's actually moving (see `ProjectSidebar`). The width it pins *to* is read here,
        // while the pane is still at rest — a collapsed item keeps its last width, so this is the width
        // the sidebar has now or is about to have again, in both directions.
        state.sidebarRestingWidth = sidebarWidthAtRest
        state.sidebarAnimating = true

        // Cleared by the animation's own completion, not by a timer set to outlast it. This used to be
        // a 0.4s `DispatchWorkItem` guessing at a ~0.25s slide, which is only ever right by margin: the
        // duration isn't ours to know, and under Reduce Motion, low power or load the unfreeze could
        // land mid-slide — causing exactly the reflow the freeze exists to prevent.
        //
        // `super.toggleSidebar` animates through the item's animator proxy, so running it inside an
        // animation group makes it this group's animation and the completion handler fires when it
        // actually ends. Re-entrancy is safe: a second toggle mid-flight starts its own group, and the
        // first group's completion sets the flag the second one has already re-raised, so the token
        // check keeps the stale completion from clearing it early.
        settleToken &+= 1
        let token = settleToken
        NSAnimationContext.runAnimationGroup { _ in
            super.toggleSidebar(sender)
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.settleToken == token else { return }
                self.state.sidebarAnimating = false
                // A window that opened with the sidebar hidden has never seen the restored width, so
                // the first time the pane appears is the first chance to learn it.
                self.recordSidebarWidth()
            }
        }
        // `toggleSidebar` animates, so `isCollapsed` is already the new value but the animation is in
        // flight; the observation has already mirrored it into the state and updated the scan. All
        // that's left here is persisting the preference — and only from here, because this is the one
        // path that means "the user asked for the sidebar to be like this from now on". A restore or a
        // divider drag changes the pane without changing what the next window should open with.
        UserDefaults.standard.set(!sidebarItem.isCollapsed, forKey: ProjectWindow.sidebarDefaultsKey)
    }

    /// Tick View ▸ Show Projects while the sidebar is showing.
    ///
    /// `toggleSidebar:` targets nil, so it walks the responder chain to here rather than to the app
    /// delegate — which means this is the only place that can answer for it. Without this the item sat
    /// permanently unchecked beside two neighbours (Show Focus Panel, Show Notes) that both check
    /// themselves in `AppDelegate.validateMenuItem`, so a window with its sidebar open showed a View
    /// menu offering to show it.
    ///
    /// A checkmark rather than a Show/Hide title swap, matching those two neighbours: three items in
    /// one group should say what they are the same way.
    ///
    /// Not an `override`: `NSSplitViewController` implements this in Objective-C but doesn't surface it
    /// to Swift, so there's nothing to override and nothing to call `super` on. Validation is only ever
    /// asked of the object that would *receive* the action, and the only action this controller answers
    /// is `toggleSidebar:` — so everything else that reaches here is already enabled by virtue of
    /// having got here.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleSidebar(_:)) {
            item.state = sidebarItem.isCollapsed ? .off : .on
        }
        return true
    }

    /// Hold the shared project scan open exactly while this window's sidebar is showing.
    private func syncProjectScan() {
        let wanted = !sidebarItem.isCollapsed
        guard wanted != holdsProjectScan else { return }
        holdsProjectScan = wanted
        if wanted { ProjectIndex.shared.retain() } else { ProjectIndex.shared.release() }
    }

    /// Release the scan retain when the window closes; the split view controller outlives its window
    /// only briefly, but the retain has to be balanced either way.
    func prepareForClose() {
        // Before the release, so a collapse on the way down can't hand the retain straight back.
        collapseObservation?.invalidate()
        collapseObservation = nil
        resizeObservation.map(NotificationCenter.default.removeObserver)
        resizeObservation = nil
        // A board showing here holds the canvas document open, and the last holder is what saves it and
        // stops it polling the file. A window closing on a board must give that hold back — for every
        // tab that has one, not only the one on screen.
        contentPane.dropAll()
        if holdsProjectScan {
            holdsProjectScan = false
            ProjectIndex.shared.release()
        }
    }
}
