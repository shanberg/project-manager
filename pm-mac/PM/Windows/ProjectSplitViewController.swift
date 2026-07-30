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
/// It's used for both chrome styles. In the panel style the sidebar's thickness is pinned, so the panel
/// keeps its exact original geometry (a fixed 420pt column, widened by exactly the sidebar's width).
@MainActor
final class ProjectSplitViewController: NSSplitViewController {
    private(set) var store: PMStore
    let state: ProjectViewState
    private let chromeStyle: WindowChromeStyle
    private let chrome: PanelChrome

    private var sidebarItem: NSSplitViewItem!
    private var contentItem: NSSplitViewItem!
    private var sidebarHosting: NSHostingController<ProjectSidebar>!
    private var contentHosting: NSHostingController<PanelView>!

    /// Whether this controller is currently holding the shared project scan open. It owns that retain
    /// rather than the sidebar view, because a collapsed split item keeps its view mounted — the view
    /// can't tell it's been hidden, and would go on paying for a scan nobody can see.
    private var holdsProjectScan = false

    /// Callbacks the window supplies. `onContentHeight` and the resize trio only matter to the panel
    /// style, which sizes itself to its content.
    var onDismiss: () -> Void = {}
    var onContentHeight: (CGFloat) -> Void = { _ in }
    var onResizeBegan: () -> Void = {}
    var onResizeChanged: (CGFloat) -> Void = { _ in }
    var onResizeEnded: () -> Void = {}

    init(store: PMStore, state: ProjectViewState, chromeStyle: WindowChromeStyle, chrome: PanelChrome) {
        self.store = store
        self.state = state
        self.chromeStyle = chromeStyle
        self.chrome = chrome
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()

        sidebarHosting = NSHostingController(rootView: ProjectSidebar(store: store, state: state))
        contentHosting = NSHostingController(rootView: makeContentView())
        // The content fills whatever frame the split gives it. Left on the default
        // (`.preferredContentSize`) AppKit would resize the window to the SwiftUI content's ideal size,
        // which closes a loop with the panel style's own auto-fit: the content sizes itself to the
        // window, so its ideal height *is* the window's height, feeding straight back into the frame.
        contentHosting.sizingOptions = []
        sidebarHosting.sizingOptions = []

        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarHosting)
        sidebarItem.minimumThickness = chromeStyle.isPanel ? ProjectWindow.sidebarWidth : ProjectWindow.sidebarMinWidth
        sidebarItem.maximumThickness = chromeStyle.isPanel ? ProjectWindow.sidebarWidth : ProjectWindow.sidebarMaxWidth
        sidebarItem.canCollapse = true
        // The panel hugs its content, so a sidebar that sprang back open on a window resize would
        // fight the auto-fit; in a window it's the standard behavior.
        sidebarItem.holdingPriority = .defaultLow
        sidebarItem.isCollapsed = !ProjectWindow.isSidebarVisible

        contentItem = NSSplitViewItem(viewController: contentHosting)
        contentItem.minimumThickness = ProjectWindow.minContentWidth
        contentItem.canCollapse = false

        addSplitViewItem(sidebarItem)
        addSplitViewItem(contentItem)

        splitView.autosaveName = chromeStyle.isPanel ? "PMPanelSplit" : "PMProjectSplit"
        splitView.dividerStyle = .thin

        syncProjectScan()
    }

    /// Rebuild the SwiftUI content — used on first load and whenever the window is retargeted at a
    /// different project.
    private func makeContentView() -> PanelView {
        PanelView(
            store: store,
            chrome: chrome,
            state: state,
            chromeStyle: chromeStyle,
            onDismiss: { [weak self] in self?.onDismiss() },
            onContentHeight: { [weak self] height in self?.onContentHeight(height) },
            onResizeBegan: { [weak self] in self?.onResizeBegan() },
            onResizeChanged: { [weak self] delta in self?.onResizeChanged(delta) },
            onResizeEnded: { [weak self] in self?.onResizeEnded() }
        )
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

    /// Show/hide the sidebar, keeping the persisted preference and the shared scan in step. The View
    /// menu's ⌥⌘S and the header's toggle both land here.
    override func toggleSidebar(_ sender: Any?) {
        super.toggleSidebar(sender)
        // `toggleSidebar` animates, so `isCollapsed` is already the new value but the animation is in
        // flight; the preference and the scan can be updated straight away.
        UserDefaults.standard.set(!sidebarItem.isCollapsed, forKey: ProjectWindow.sidebarDefaultsKey)
        syncProjectScan()
    }

    /// Match the split's collapsed state to the persisted preference — for when the preference is
    /// changed somewhere other than this window (the header toggle, or another window's View menu).
    func applySidebarPreference() {
        let wanted = !ProjectWindow.isSidebarVisible
        guard sidebarItem.isCollapsed != wanted else { return }
        sidebarItem.animator().isCollapsed = wanted
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
