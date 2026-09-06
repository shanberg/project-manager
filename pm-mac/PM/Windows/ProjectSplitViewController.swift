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
    let state: ProjectViewState
    /// Whether this window opens with its sidebar showing. The first window of a session takes the
    /// persisted preference; later ones start collapsed — a second window is opened to look at another
    /// project *beside* the first, and a second copy of the project list isn't what it's for.
    private let startsWithSidebar: Bool

    private var sidebarItem: NSSplitViewItem!
    private var contentItem: NSSplitViewItem!
    private var sidebarHosting: NSHostingController<ProjectSidebar>!
    private var contentHosting: NSHostingController<ProjectView>!
    /// The container the content column's two renderers take turns in — see
    /// `ProjectContentPaneController`.
    private let contentPane = ProjectContentPaneController()
    /// The board, while this window is rendering one. Nil when it is showing tasks.
    private(set) var canvasPane: CanvasPaneController?
    /// The stand-in for a project that hasn't got a canvas yet.
    private var canvasEmptyState: NSHostingController<ProjectCanvasEmptyState>?

    /// Whether this controller is currently holding the shared project scan open. It owns that retain
    /// rather than the sidebar view, because a collapsed split item keeps its view mounted — the view
    /// can't tell it's been hidden, and would go on paying for a scan nobody can see.
    private var holdsProjectScan = false

    /// Keeps `state.sidebarVisible` (and the scan retain) in step with the sidebar item's real collapsed
    /// state, whoever changed it. See where it's installed in `viewDidLoad`.
    private var collapseObservation: NSKeyValueObservation?

    init(store: PMStore, state: ProjectViewState, startsWithSidebar: Bool) {
        self.store = store
        self.state = state
        self.startsWithSidebar = startsWithSidebar
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()

        sidebarHosting = NSHostingController(rootView: ProjectSidebar(store: store, state: state))
        contentHosting = NSHostingController(rootView: makeContentView())
        contentPane.show(contentHosting)
        // The content fills whatever frame the split gives it. Left on the default
        // (`.preferredContentSize`) AppKit would resize the window to the SwiftUI content's ideal size,
        // which fights the user's own window size on every content change.
        contentHosting.sizingOptions = []
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

    /// Rebuild the SwiftUI content — used on first load and whenever the window is retargeted at a
    /// different project.
    private func makeContentView() -> ProjectView {
        ProjectView(store: store, state: state)
    }

    // MARK: What the column shows

    /// Which renderer is up. Read by the window for its menu checkmark and its width cap.
    private(set) var renderer: ProjectRenderer = .tasks

    /// Show the project's board in the content column.
    ///
    /// `url` nil means the project hasn't got a canvas — an empty state offering to make one, rather
    /// than making one, because switching a view shouldn't write to somebody's vault.
    func showCanvas(at url: URL?, projectName: String?,
                    create: @escaping () -> Void) {
        renderer = .canvas
        guard let url else {
            dropCanvas()
            let empty = NSHostingController(rootView: ProjectCanvasEmptyState(
                projectName: projectName,
                create: create,
                showTasks: { [weak self] in self?.showTasks() }))
            empty.sizingOptions = []
            canvasEmptyState = empty
            contentPane.show(empty)
            return
        }
        // Already on this board — a retarget that landed back on the same project, most often.
        if let existing = canvasPane, existing.store.url.standardizedFileURL == url.standardizedFileURL {
            existing.title_ = projectName ?? existing.title_
            return
        }
        dropCanvas()
        guard let store = try? CanvasStoreRegistry.store(for: url) else {
            // A canvas that won't parse. Falling back to the task list is the honest answer: the window
            // still shows the project, and File ▸ Open Canvas reports the error properly.
            renderer = .tasks
            contentPane.show(contentHosting)
            return
        }
        let pane = CanvasPaneController(store: store)
        pane.title_ = projectName ?? url.deletingPathExtension().lastPathComponent
        pane.ignoresTrafficLights = !sidebarItem.isCollapsed
        // The same switch the task list's header carries, so the way back is where the way here was.
        pane.header.showsRendererSwitch = true
        pane.header.setRenderer = { [weak self] next in
            guard next == .tasks else { return }
            self?.showTasks()
        }
        canvasPane = pane
        contentPane.show(pane)
        pane.focusBoard()
    }

    /// Back to the task list.
    func showTasks() {
        renderer = .tasks
        dropCanvas()
        contentPane.show(contentHosting)
        onRendererChanged?()
    }

    /// Told when the column changes what it is showing, so the window can re-apply its width cap and
    /// its menus can re-validate.
    var onRendererChanged: (() -> Void)?

    private func dropCanvas() {
        canvasPane?.teardown()
        canvasPane = nil
        canvasEmptyState = nil
    }

    /// The board's undo stack while one is showing, so ⌘Z in this window reaches the board rather than
    /// the task list — and, because the store is shared, undoes in the canvas's own window too.
    var undoManagerForContent: UndoManager? { canvasPane?.store.undoManager }

    // MARK: Retargeting

    /// Point this window at a different project. The store is swapped rather than rebound: stores are
    /// shared per project (see `StoreRegistry`), so rebinding one would quietly change the project for
    /// every other holder of it.
    func retarget(to newStore: PMStore, projectKey: String?) {
        guard newStore !== store else { return }
        store = newStore
        sidebarHosting.rootView = ProjectSidebar(store: newStore, state: state)
        contentHosting.rootView = makeContentView()
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
        // stops it polling the file. A window closing on a board must give that hold back.
        dropCanvas()
        if holdsProjectScan {
            holdsProjectScan = false
            ProjectIndex.shared.release()
        }
    }
}
