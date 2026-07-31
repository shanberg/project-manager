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
        sidebarHosting.sizingOptions = []

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
        sidebarItem.isCollapsed = !startsWithSidebar

        contentItem = NSSplitViewItem(viewController: contentHosting)
        contentItem.minimumThickness = ProjectWindow.minContentWidth
        contentItem.canCollapse = false
        contentItem.holdingPriority = .defaultLow

        // Both panes run the full height of the window, under the (hidden) titlebar — each header
        // positions itself past the traffic lights rather than sitting below them. Declaring it here
        // rather than only in the views is what tells AppKit the layout is deliberate.
        //
        // The matching `automaticallyAdjustsSafeAreaInsets = false` is macOS 26 only, so the panes'
        // SwiftUI content still declines the top safe area itself — that form works on every target.
        for item in [sidebarItem!, contentItem!] {
            item.allowsFullHeightLayout = true
            // No toolbar and no visible title, so there's no titlebar for AppKit to draw a separator
            // under; the rule below each header is the app's own, and a second line at the titlebar's
            // bottom edge would sit a few points above it.
            item.titlebarSeparatorStyle = .none
        }

        addSplitViewItem(sidebarItem)
        addSplitViewItem(contentItem)

        // One autosave name for every project window: the sidebar's width is a per-app preference, not
        // a per-project one, so dragging it in any window sets it for the next window you open.
        splitView.autosaveName = "PMProjectSplit"
        splitView.dividerStyle = .thin

        state.sidebarVisible = startsWithSidebar
        syncProjectScan()
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
        super.toggleSidebar(sender)
        // `toggleSidebar` animates, so `isCollapsed` is already the new value but the animation is in
        // flight; the state and the scan can be updated straight away.
        state.sidebarVisible = !sidebarItem.isCollapsed
        UserDefaults.standard.set(state.sidebarVisible, forKey: ProjectWindow.sidebarDefaultsKey)
        syncProjectScan()
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
        if holdsProjectScan {
            holdsProjectScan = false
            ProjectIndex.shared.release()
        }
    }
}
