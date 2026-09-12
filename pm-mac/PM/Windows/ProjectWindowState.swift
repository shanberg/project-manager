import SwiftUI

/// What a project window's sidebar shares with the window around it.
///
/// The sidebar and the task column used to be one SwiftUI hierarchy, so this was ordinary `@State` on
/// the column handed down as bindings. Once the split view put each pane in its own hosting controller
/// they could not share `@State` — or a `@FocusState`, whose scope is a single hierarchy — so the
/// handful of genuinely shared values moved here, one instance per window.
///
/// It was `ProjectViewState` while the other pane was `ProjectView`, and it shrank when that pane
/// became a board: what is left is the sidebar's selection, the window's tabs, and the two errands the
/// sidebar hands back up. Nothing about a list of tasks lives here any more.
@MainActor
@Observable
final class ProjectWindowState {
    /// The selected projects in the sidebar. Shared because the window answers the commands that act
    /// on it — a selection is a batch for ⌘C or the context menu, and neither is asked from inside the
    /// list.
    ///
    /// A single selection *is* the window's project: selecting one switches to it, and switching moves
    /// this (see `ProjectSidebar.selectionChanged`). Only a multiple selection stands apart, as a batch
    /// for ⌘C or the context menu to act on.
    var projectSelection: Set<String> = []

    /// The window's tabs, so the task column's header can draw the same bar the board's does.
    ///
    /// Handed in rather than published, because it is an object the window owns for the window's whole
    /// life: what changes is inside it, and the views that draw it observe it directly.
    @ObservationIgnored
    var tabs = ProjectTabModel()

    /// Open a project — the sidebar's double-click and Return. Supplied by the window, which decides
    /// whether that means retargeting this window or opening another one.
    @ObservationIgnored
    var openProject: (_ projectKey: String, _ inNewWindow: Bool) -> Void = { _, _ in }

    /// Open the project a `[[…]]` names, given the folder name written inside it.
    ///
    /// The lookup lives here rather than at each editor, so a token clicked in the note, in an Add Task
    /// field and in a row's context menu all reach the same window by the same route. A name that
    /// resolves to nothing does nothing — `[[Dana]]` is a person, and clicking it is not an error.
    func openProject(named folder: String) {
        guard let key = ProjectIndex.shared.projectKey(forFolder: folder) else { return }
        openProject(key, false)
    }

    /// Show/hide the sidebar. Supplied by the window: collapsing is the split view's job, so the
    /// header's toggle and the View menu's ⌥⌘S both end up in the same place.
    @ObservationIgnored
    var toggleSidebar: () -> Void = {}

    /// How far in from this window's leading edge its close/minimise/zoom buttons reach, plus a
    /// margin. Whichever pane is leftmost insets its header by this so the two never overlap.
    ///
    /// Measured from the real buttons once the window is on screen rather than hard-coded: Apple has
    /// moved these between releases, and a stale constant shows up as a title either colliding with the
    /// zoom button or floating oddly far from the edge.
    var leadingTitlebarInset: CGFloat = ProjectWindow.trafficLightsWidth

    /// How far down from the window's top edge its traffic lights are centred, so a header running
    /// under the titlebar can sit level with them. Larger with the taller unified titlebar than with
    /// the compact one, which is exactly why it's measured rather than assumed.
    var titlebarButtonCenterY: CGFloat = 13

    /// True only while the sidebar is animating open or shut. The sidebar freezes its layout and clips
    /// for the duration; the rest of the time it lays out normally, so a scrolling list isn't sitting
    /// inside a clip layer it doesn't need.
    var sidebarAnimating = false

    /// The width the sidebar pane rests at, published by the split view controller just before it
    /// animates. It's what the sidebar freezes its layout at, so the content that slides past the
    /// divider is laid out at the width it will actually land on rather than the pane's bare minimum.
    var sidebarRestingWidth: CGFloat = ProjectWindow.sidebarMinWidth

    /// Whether *this window's* sidebar is showing. Per window, like every other source-list app — the
    /// persisted `PMPanelSidebar` is only the default a session's first window opens with, so the
    /// content can't read it and be right.
    var sidebarVisible = false

    /// Bumped by File ▸ All Projects…, and by a window that opens on no project at all, which reveals
    /// the sidebar and puts the keyboard in it.
    ///
    /// A counter rather than a closure — the last of a family that used to have six members, one per
    /// command the task column answered. The rest went with the column: the board answers its own
    /// commands from the responder chain, and the window-shaped versions aim at the project's card (see
    /// `CanvasPaneController.aimAtProjectCard`). This one stays because the sidebar's focus really is a
    /// `@FocusState` it owns, so the only way in from outside is to ask.
    var focusProjectListRequest = 0

    func requestFocusProjectList() { focusProjectListRequest &+= 1 }

    /// Escape's last stop in the sidebar: drop a multiple selection back to the one project the window
    /// is on. A source list is never left with nothing selected — that's what it means for the
    /// selection to be the window's project — so this collapses rather than clears.
    func collapseProjectSelection(to projectKey: String?) {
        projectSelection = projectKey.map { [$0] } ?? []
    }
}
