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

        // Contain the content column's push transitions (the session-note takeover slides in from the
        // trailing edge while the task list slides out the leading one) to the pane. The column used to
        // do this itself with a SwiftUI `.clipped()`, which meant its scrolling task list sat inside a
        // clip layer permanently for the sake of a quarter-second animation. A layer mask on the pane
        // that hosts it is free — the hosting view is layer-backed regardless — and the pane's edge is
        // the boundary the transition should respect anyway.
        contentHosting.view.wantsLayer = true
        contentHosting.view.layer?.masksToBounds = true

        // An `NSHostingView` reports its SwiftUI ideal size as an intrinsic size and defends it with
        // the default (500) hugging and compression-resistance priorities — which outrank the split
        // view's own dragging constraints, so the divider simply won't move. Standing both panes down
        // to `.defaultLow` hands the width decision back to the split view, which is what makes the
        // divider draggable and what lets the sidebar honour its min/max thicknesses.
        for view in [sidebarHosting.view, contentHosting.view] {
            view.setContentHuggingPriority(.defaultLow, for: .horizontal)
            view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }

        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarHosting)
        sidebarItem.minimumThickness = ProjectWindow.sidebarMinWidth
        sidebarItem.maximumThickness = ProjectWindow.sidebarMaxWidth
        sidebarItem.canCollapse = true
        // Below the content's, so growing the window widens the task column and leaves the sidebar at
        // the width the user set — the behaviour every other source-list app has.
        sidebarItem.holdingPriority = .defaultLow - 1

        contentItem = NSSplitViewItem(viewController: contentHosting)
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
            }
        }
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
    }

    private var didSeedDividerPosition = false
    /// Identifies the in-flight sidebar animation, so a completion handler that belongs to a toggle
    /// that's already been superseded can't clear `sidebarAnimating` out from under the current one.
    private var settleToken = 0

    /// Rebuild the SwiftUI content — used on first load and whenever the window is retargeted at a
    /// different project.
    private func makeContentView() -> ProjectView {
        ProjectView(store: store, state: state)
    }

    // MARK: Retargeting

    /// Point this window at a different project. The store is swapped rather than rebound: stores are
    /// shared per project (see `StoreRegistry`), so rebinding one would quietly change the project for
    /// every other holder of it.
    func retarget(to newStore: PMStore) {
        guard newStore !== store else { return }
        store = newStore
        state.projectSelection = []
        sidebarHosting.rootView = ProjectSidebar(store: newStore, state: state)
        contentHosting.rootView = makeContentView()
    }

    // MARK: Sidebar

    var isSidebarCollapsed: Bool { sidebarItem.isCollapsed }

    /// Show/hide *this window's* sidebar. The View menu's ⌥⌘S and the header's toggle both land here.
    ///
    /// Sidebar visibility is per window, like every other source-list app: hiding it in one window
    /// doesn't reach into the others. The persisted value is only the default a first window opens
    /// with, so the app comes back the way you left it.
    override func toggleSidebar(_ sender: Any?) {
        // Set before the animation starts, cleared once it's over: the sidebar only pins its layout and
        // clips while it's actually moving (see `ProjectSidebar`). The width it pins *to* is read here,
        // while the pane is still at rest — a collapsed item keeps its last width, so this is the width
        // the sidebar has now or is about to have again, in both directions.
        state.sidebarRestingWidth = max(sidebarItem.viewController.view.frame.width,
                                        ProjectWindow.sidebarMinWidth)
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
            }
        }
        // `toggleSidebar` animates, so `isCollapsed` is already the new value but the animation is in
        // flight; the observation has already mirrored it into the state and updated the scan. All
        // that's left here is persisting the preference — and only from here, because this is the one
        // path that means "the user asked for the sidebar to be like this from now on". A restore or a
        // divider drag changes the pane without changing what the next window should open with.
        UserDefaults.standard.set(!sidebarItem.isCollapsed, forKey: ProjectWindow.sidebarDefaultsKey)
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
        if holdsProjectScan {
            holdsProjectScan = false
            ProjectIndex.shared.release()
        }
    }
}
