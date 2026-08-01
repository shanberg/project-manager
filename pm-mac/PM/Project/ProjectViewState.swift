import SwiftUI

/// Which pane a window's keyboard commands drive. Kept as a value (rather than a `@FocusState`) so it
/// survives the two panes living in separate view hierarchies — see `ProjectViewState.focusedPane`.
enum ProjectPane: Hashable {
    case tasks
    case projects
}

/// The state a project window's two panes share.
///
/// The sidebar and the task column used to be one SwiftUI hierarchy, so this was ordinary `@State` on
/// `ProjectView` handed down as bindings. Once the split view puts each pane in its own hosting
/// controller they can't share `@State` — or a `@FocusState`, whose scope is a single hierarchy — so
/// the handful of genuinely shared values live here instead, one instance per window.
///
/// Only what *both* panes touch belongs here. The task list's own selection stays private to
/// `ProjectView`; it never leaves that pane.
@MainActor
final class ProjectViewState: ObservableObject {
    /// The selected projects in the sidebar. Shared because ⌘C and ⌘A act on whichever pane has
    /// keyboard focus, and those commands are answered from the window, not from inside the sidebar.
    /// Selecting a project doesn't switch to it — that's the double-click (or Return).
    @Published var projectSelection: Set<String> = []

    /// Which pane has keyboard focus, for routing ⌘C / ⌘A / Return.
    ///
    /// Each pane still owns a real `@FocusState` internally — that's what draws the emphasized
    /// selection and takes arrow keys — and writes here when it *gains* focus. Nothing writes nil: a
    /// pane losing focus (the window going inactive, a menu opening) shouldn't strand the commands
    /// with no target, so the last focused pane stays remembered.
    @Published var focusedPane: ProjectPane? = .tasks

    /// The task column header's measured height, so the sidebar's own header bar and rule line up with
    /// it across the split.
    @Published var headerHeight: CGFloat = 0

    /// Open a project — the sidebar's double-click and Return. Supplied by the window, which decides
    /// whether that means retargeting this window or opening another one.
    var openProject: (_ projectKey: String, _ inNewWindow: Bool) -> Void = { _, _ in }

    /// Show/hide the sidebar. Supplied by the window: collapsing is the split view's job, so the
    /// header's toggle and the View menu's ⌥⌘S both end up in the same place.
    var toggleSidebar: () -> Void = {}

    /// How far in from this window's leading edge its close/minimise/zoom buttons reach, plus a
    /// margin. Whichever pane is leftmost insets its header by this so the two never overlap.
    ///
    /// Measured from the real buttons once the window is on screen rather than hard-coded: Apple has
    /// moved these between releases, and a stale constant shows up as a title either colliding with the
    /// zoom button or floating oddly far from the edge.
    @Published var leadingTitlebarInset: CGFloat = ProjectWindow.trafficLightsWidth

    /// How far down from the window's top edge its traffic lights are centred, so a header running
    /// under the titlebar can sit level with them. Larger with the taller unified titlebar than with
    /// the compact one, which is exactly why it's measured rather than assumed.
    @Published var titlebarButtonCenterY: CGFloat = 13

    /// Whether *this window's* sidebar is showing. Per window, like every other source-list app — the
    /// persisted `PMPanelSidebar` is only the default a session's first window opens with, so the
    /// content can't read it and be right.
    @Published var sidebarVisible = false

    /// Bumped by the File ▸ New Task command. The content watches the counter rather than being handed
    /// a closure: a SwiftUI `View` is a value rebuilt on every body pass, so a closure registered from
    /// one would capture a stale copy of its state.
    @Published var newTaskRequest = 0

    func requestNewTask() { newTaskRequest &+= 1 }

    /// Bumped by Edit ▸ Find ▸ Find…, for the same reason `newTaskRequest` is a counter rather than a
    /// closure: a SwiftUI `View` is a value rebuilt on every body pass, so a closure registered from
    /// one captures a stale copy of its state.
    @Published var findRequest = 0

    func requestFind() { findRequest &+= 1 }

    /// Clear both panes' selections (Escape's last stop before it gives up).
    func clearSelections() {
        projectSelection = []
    }
}
