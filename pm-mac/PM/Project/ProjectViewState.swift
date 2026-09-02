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
    ///
    /// A single selection *is* the window's project: selecting one switches to it, and switching moves
    /// this (see `ProjectSidebar.selectionChanged`). Only a multiple selection stands apart, as a batch
    /// for ⌘C or the context menu to act on.
    @Published var projectSelection: Set<String> = []

    /// Which pane has keyboard focus, for routing ⌘C / ⌘A / Return.
    ///
    /// Each pane still owns a real `@FocusState` internally — that's what draws the emphasized
    /// selection and takes arrow keys — and writes here when it *gains* focus. Nothing writes nil: a
    /// pane losing focus (the window going inactive, a menu opening) shouldn't strand the commands
    /// with no target, so the last focused pane stays remembered.
    @Published var focusedPane: ProjectPane? = .tasks

    /// Whether a text editor in this window currently holds the keyboard — a row's inline field, the
    /// find bar, a details form field, a session note.
    ///
    /// Published by the window itself (`TextFocusWindow`, which watches its own first responder)
    /// rather than assembled from the view's editor flags, because it has to be true for *every* field
    /// in either pane and only while that field really has the keyboard. A flag like `findVisible` is
    /// neither: the find bar can be open with the list focused, and no flag at all stands for the
    /// details form's fields.
    ///
    /// What reads it: `ProjectView.keyboardShortcuts`, where it takes the window's ⌘A / ⌘C / ⌘Z / ⌘⌫
    /// out of play so the keystroke reaches the field you are typing in. See that comment for why the
    /// main menu can't be relied on to win the race by itself.
    @Published var isEditingText = false

    /// Open a project — the sidebar's double-click and Return. Supplied by the window, which decides
    /// whether that means retargeting this window or opening another one.
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

    /// True only while the sidebar is animating open or shut. The sidebar freezes its layout and clips
    /// for the duration; the rest of the time it lays out normally, so a scrolling list isn't sitting
    /// inside a clip layer it doesn't need.
    @Published var sidebarAnimating = false

    /// The width the sidebar pane rests at, published by the split view controller just before it
    /// animates. It's what the sidebar freezes its layout at, so the content that slides past the
    /// divider is laid out at the width it will actually land on rather than the pane's bare minimum.
    @Published var sidebarRestingWidth: CGFloat = ProjectWindow.sidebarMinWidth

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

    /// Whether a search is narrowing the list right now — the bar open *and* something typed into it.
    ///
    /// Published up out of the pane because the window validates Find Next / Find Previous, and "is
    /// there anything to step through" is a question only the content can answer. `findVisible` alone
    /// would be the wrong answer: an open bar with an empty field filters nothing, so there are no
    /// matches to be next in.
    @Published var findIsFiltering = false

    /// Bumped by Edit ▸ Find ▸ Find Next / Find Previous, with the direction alongside. Same counter
    /// pattern as `newTaskRequest`; the direction rides separately rather than in the counter so the
    /// two consecutive ⌘Gs that mean the same thing still read as two distinct requests.
    @Published var findStepRequest = 0
    private(set) var findStepDirection = 1

    func requestFindStep(_ direction: Int) {
        findStepDirection = direction
        findStepRequest &+= 1
    }

    /// Bumped by Edit ▸ Find ▸ Use Selection for Find (⌘E). Only ever reaches the window when no text
    /// field has the keyboard — an `NSTextView` answers `performFindPanelAction:` itself and claims it
    /// first, which is the behaviour a Mac user expects while they're typing.
    @Published var useSelectionForFindRequest = 0

    func requestUseSelectionForFind() { useSelectionForFindRequest &+= 1 }

    /// Bumped by File ▸ All Projects…, which reveals the sidebar and puts the keyboard in it. Same
    /// counter pattern as `newTaskRequest`: the sidebar's focus is a `@FocusState` it owns, so the only
    /// way in from outside is to ask.
    @Published var focusProjectListRequest = 0

    func requestFocusProjectList() { focusProjectListRequest &+= 1 }

    /// Bumped by File ▸ New Session, on the same counter pattern as `newTaskRequest`.
    @Published var newSessionRequest = 0

    func requestNewSession() { newSessionRequest &+= 1 }

    /// Bumped by the quick bar's Edit Project Details, same counter pattern again. The details form
    /// only exists while the brief is showing, so the view reveals it on the way in.
    @Published var editDetailsRequest = 0

    func requestEditDetails() { editDetailsRequest &+= 1 }

    /// Escape's last stop in the sidebar: drop a multiple selection back to the one project the window
    /// is on. A source list is never left with nothing selected — that's what it means for the
    /// selection to be the window's project — so this collapses rather than clears.
    func collapseProjectSelection(to projectKey: String?) {
        projectSelection = projectKey.map { [$0] } ?? []
    }
}
