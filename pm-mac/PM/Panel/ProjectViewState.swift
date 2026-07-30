import SwiftUI

/// Which pane a window's keyboard commands drive. Kept as a value (rather than a `@FocusState`) so it
/// survives the two panes living in separate view hierarchies — see `ProjectViewState.focusedPane`.
enum PanelPane: Hashable {
    case tasks
    case projects
}

/// The state a project window's two panes share.
///
/// The sidebar and the task column used to be one SwiftUI hierarchy, so this was ordinary `@State` on
/// `PanelView` handed down as bindings. Once the split view puts each pane in its own hosting
/// controller they can't share `@State` — or a `@FocusState`, whose scope is a single hierarchy — so
/// the handful of genuinely shared values live here instead, one instance per window.
///
/// Only what *both* panes touch belongs here. The task list's own selection stays private to
/// `PanelView`; it never leaves that pane.
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
    @Published var focusedPane: PanelPane? = .tasks

    /// The task column header's measured height, so the sidebar's own header bar and rule line up with
    /// it across the split.
    @Published var headerHeight: CGFloat = 0

    /// Open a project — the sidebar's double-click and Return. Supplied by the window, which decides
    /// whether that means retargeting this window or opening another one.
    var openProject: (_ projectKey: String, _ inNewWindow: Bool) -> Void = { _, _ in }

    /// Show/hide the sidebar. Supplied by the window: collapsing is the split view's job, so the
    /// header's toggle and the View menu's ⌥⌘S both end up in the same place.
    var toggleSidebar: () -> Void = {}

    /// Bumped by the File ▸ New Task command. The content watches the counter rather than being handed
    /// a closure: a SwiftUI `View` is a value rebuilt on every body pass, so a closure registered from
    /// one would capture a stale copy of its state.
    @Published var newTaskRequest = 0

    func requestNewTask() { newTaskRequest &+= 1 }

    /// Clear both panes' selections (Escape's last stop before it gives up).
    func clearSelections() {
        projectSelection = []
    }
}
