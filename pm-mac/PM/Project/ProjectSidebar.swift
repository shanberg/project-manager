import SwiftUI
import AppKit
import PmLib

/// Which projects the sidebar lists, persisted across sessions.
enum ProjectStatusFilter: String {
    case active, archived, all

    func includes(_ entry: PMStore.ProjectEntry) -> Bool {
        switch self {
        case .active: return !entry.isArchived
        case .archived: return entry.isArchived
        case .all: return true
        }
    }
}

/// Which kinds the sidebar shows. A separate axis from the status filter, because "archived" and
/// "area" answer different questions — an area can be either.
enum ProjectKindFilter: String, CaseIterable {
    case projects, areas, all

    func includes(_ entry: PMStore.ProjectEntry) -> Bool {
        switch self {
        case .projects: return entry.kind == .project
        case .areas: return entry.kind == .area
        case .all: return true
        }
    }
}

/// How the sidebar's rows are gathered into sections.
///
/// Areas take part in neither: they have no domain and no due date. They get a section of their own
/// below whatever the grouping produced — see `arranged`.
enum ProjectGrouping: String { case due, domain }

/// How far ahead the Up Next band looks, and whether it appears at all.
///
/// A preference rather than a constant, because "soon" isn't the same distance for everyone: a week
/// matches `DueBucket.week`, so the band and the Due grouping agree by default, but a list where most
/// work lands the same afternoon wants Today, and one planned in fortnights wants fourteen days.
///
/// `.off` sits in the same picker rather than being a separate toggle beside it. Turning the band off
/// *is* a horizon — the shortest one there is — and splitting it into a checkbox would make two
/// controls out of one decision, with a disabled-looking picker whenever the checkbox was clear.
enum UpNextHorizon: String, CaseIterable {
    case off, today, three, week, fortnight

    /// Whole days ahead a project may be due and still card. Nil when the band is off. Overdue
    /// projects qualify at every horizon: a negative delta is under any ceiling, including Today's
    /// zero, which is why that case reads "Overdue & Today" rather than "Today".
    var days: Int? {
        switch self {
        case .off: return nil
        case .today: return 0
        case .three: return 3
        case .week: return 7
        case .fortnight: return 14
        }
    }

    var title: String {
        switch self {
        case .off: return "Off"
        case .today: return "Overdue & Today"
        case .three: return "Next 3 Days"
        case .week: return "Next 7 Days"
        case .fortnight: return "Next 14 Days"
        }
    }
}

/// How rows are ordered inside a section.
enum ProjectSortOrder: String {
    case code, name, recency

    /// Code sorts on the parsed (code, number) pair rather than the folder name, so "H-9" precedes
    /// "H-10"; name sorts on the name with its code prefix stripped, which is the whole point of having
    /// both; recency is newest-edited first.
    func precedes(_ a: PMStore.ProjectEntry, _ b: PMStore.ProjectEntry) -> Bool {
        switch self {
        case .code: return (a.code, a.number) < (b.code, b.number)
        case .name: return a.shortName.localizedStandardCompare(b.shortName) == .orderedAscending
        case .recency: return a.modified > b.modified
        }
    }
}

/// A due-date section. Cases are declared in the order they're shown, so a project's most urgent work
/// sits at the top of the list.
enum DueBucket: String, CaseIterable {
    case overdue, today, week, later, none

    var title: String {
        switch self {
        case .overdue: return "Overdue"
        case .today: return "Today"
        case .week: return "Next 7 days"
        case .later: return "Later"
        case .none: return "No due date"
        }
    }

    /// Bucket a project by its earliest open due date. Projects whose notes haven't been read yet (and
    /// those with nothing due) land in `.none`.
    static func of(_ entry: PMStore.ProjectEntry) -> DueBucket {
        guard let due = entry.nextDue, let days = RelativeDue.dayDelta(due) else { return .none }
        switch days {
        case ..<0: return .overdue
        case 0: return .today
        case 1...7: return .week
        default: return .later
        }
    }
}

/// One rendered section: a heading and the rows under it.
private struct ProjectGroup: Identifiable {
    let title: String
    let entries: [PMStore.ProjectEntry]
    var id: String { title }
}

/// The project window's sidebar: the projects, in sections, each row carrying the same
/// completion ring the menubar and the switcher draw plus the project's next task — the switcher menu's
/// "name — task" line, given room to breathe. Clicking a row switches the window to that project, so the
/// sidebar is the always-visible form of the title's switcher menu, for when you're moving between
/// projects rather than working inside one.
///
/// **The selection is the window's project.** A source list has one current item, and this one used to
/// draw two: a selection highlight that meant nothing on its own, and a separate semibold row for the
/// project the window was actually on. Picking a row — by click, by arrow key, by type-select — is what
/// switches, exactly as picking a mailbox switches Mail. Only a *multiple* selection stands apart from
/// the window's project, because a batch to act on isn't a place to go.
///
/// Which projects show, how they're grouped and how they're sorted all live in a menu at the top right
/// and are persisted. None of them touch the scan: `store.allProjects` is published once in recency
/// order and re-arranged here, so changing a setting is instant.
///
/// The scan itself only runs while a sidebar is showing — the split view controller holds it open, since
/// it's the only thing that can see the sidebar collapse — so a hidden sidebar costs nothing. The row for
/// the current project takes its progress from the live store rather than the cached scan, so completing
/// a task updates its ring immediately.
struct ProjectSidebar: View {
    @ObservedObject var store: PMStore
    /// The state shared with the task column across the split: the project selection (so the window's
    /// ⌘C / ⌘A can act on this pane), which pane has focus, and the task header's measured height.
    @ObservedObject var state: ProjectViewState

    /// Whether the list holds keyboard focus. Local — a `@FocusState` can't span the two hosting
    /// controllers the split view puts the panes in — and mirrored into `state.focusedPane` on the way
    /// in, which is what the window's commands route on.
    @FocusState private var listFocused: Bool

    @AppStorage("PMSidebarStatus") private var status: ProjectStatusFilter = .active
    @AppStorage("PMSidebarKind") private var kindFilter: ProjectKindFilter = .all
    @AppStorage("PMSidebarGroup") private var grouping: ProjectGrouping = .domain
    @AppStorage("PMSidebarSort") private var sortOrder: ProjectSortOrder = .recency
    /// Whether rows keep the folder name's "CODE-NNN " prefix. Off, a row reads as the bare project
    /// name — which is what you want once the codes are yours and the domain section already says
    /// which one you're in. It's a display choice only: the tooltip, the copied name and the sort
    /// orders all still see the full name.
    @AppStorage("PMSidebarShowCode") private var showsCode: Bool = true
    /// How far ahead the Up Next band looks (`.off` hides it). Read here and in the bottom bar, which
    /// is where it's set — see `SidebarBottomBar`.
    @AppStorage("PMSidebarUpNext") private var upNextHorizon: UpNextHorizon = .week

    /// The pending keyboard-driven switch, cancelled by the next selection change. See
    /// `selectionChanged`: a walk down the list shouldn't switch to every project it passes through.
    @State private var switchTask: Task<Void, Never>?

    var body: some View {
        list
            // A source list opens with its current item selected. Nothing else seeds this: the window
            // is already showing a project, and a list that draws no selection until you touch it
            // reads as though the window isn't on anything.
            .onAppear { seedSelection() }
            // A store created for a window that's still opening doesn't know its project until its
            // first read lands, so the seed above can arrive too early to have anything to select.
            .onChange(of: store.projectKey) { _ in seedSelection() }
            .onChange(of: state.projectSelection) { keys in selectionChanged(to: keys) }
            .onDisappear { switchTask?.cancel() }
        // While the pane is animating open or shut, lay out at the width it rests at and clip to
        // whatever width it currently has.
        //
        // Collapsing animates the pane to zero, and without this the content re-lays out on the way —
        // names re-truncating, rows reflowing — for a quarter second, every toggle. A native source
        // list doesn't do that, because `NSTableView` clips its rows rather than reflowing them; this
        // is that behaviour.
        //
        // The width has to be the pane's *resting* width, not its minimum, and the hosting controller
        // has to be sizing on `.minSize` (it is) for either to matter. AppKit slides the pane's content
        // view in from behind the divider at whatever fitting width that view claims, so this frozen
        // layout is literally what the animation carries: pinned to the minimum, a wider sidebar
        // reflowed once more as it landed; unpinned, nothing was carried at all.
        //
        // Only while it moves, though. Leaving the clip on permanently wraps a scrolling list in a clip
        // layer it has no use for, which is its own kind of jank the moment you start scrolling.
        .ifCondition(state.sidebarAnimating || !state.sidebarVisible) {
            $0.frame(minWidth: state.sidebarRestingWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .clipped()
        }
        // No `ignoresSafeArea` here, and no header bar of its own: the split item runs full height, so
        // AppKit hands this pane a safe area that already clears the titlebar (and the traffic lights
        // sitting in it) at the top and the bottom bar's floating accessory at the bottom. The list
        // fills the pane and insets its rows into that safe area by itself, which is what makes them
        // scroll *under* the titlebar the way a source list should.
        //
        // This pane used to carry its own header bar, hand-sized to the task column's header and
        // hand-inset past the traffic lights, because there was no other way to reserve that space.
        // The accessory API is that way (see `ProjectSplitViewController`).
        //
        // Only ever written on *gaining* focus: a pane losing it (the window going inactive, a menu
        // opening) shouldn't strand ⌘C with no target.
        .onChange(of: state.focusProjectListRequest) { _ in listFocused = true }
        .onChange(of: listFocused) { focused in
            if focused { state.focusedPane = .projects }
        }
    }

    /// The projects, as a real `List`.
    ///
    /// This was hand-built once — a `ScrollView` of rows with their own hover state, click handling,
    /// range maths and arrow-key navigation — and every one of those was a worse copy of what `List`
    /// already does. A native list brings click / ⇧-click / ⌘-click, arrow keys, type-select,
    /// scrolling (including scrolling the selection into view), the three-state selection highlight
    /// that dims when the pane or window loses focus, and the accessibility that comes with a real
    /// table. It's a flat list of selectable rows: exactly what `List` is for.
    ///
    /// The source-list style is what gives a row its own identity: the selection and hover highlights
    /// are inset rounded rectangles rather than full-bleed squared bands, so each project reads as a
    /// discrete item the way a Finder sidebar entry does. It also supplies the row insets, the section
    /// header treatment and the collapse affordance, so none of those are set by hand here.
    ///
    /// The one bit of the window own dressing kept on top: the scroll background is dropped, since the
    /// split view's sidebar item already draws the material behind this and two would stack.
    private var list: some View {
        List(selection: $state.projectSelection) {
            // The Up Next band, as the list's first section rather than a `VStack` above the list.
            //
            // Inside, a card is an ordinary list item: it gets selection, arrow keys, type-select,
            // scroll-into-view, the three-state highlight and the selection-aware context menu for
            // free — the same argument this list already makes for not hand-building its rows. Above
            // the list, every one of those would have to be rebuilt worse, and the band would sit in a
            // strip that doesn't scroll under the titlebar the way the rest of the pane does.
            //
            // A card carries the *same* tag as its project's row further down, not a prefixed one, so
            // selecting either highlights both. That's deliberate twice over: it shows which row a card
            // stands for, and it keeps ⌘C, ⌘A, Return and the context menu — all of which resolve
            // `state.projectSelection` against `store.allProjects` from outside this file — working on
            // plain project keys with nothing to unwrap.
            if !upNext.isEmpty {
                Section {
                    ForEach(upNext) { entry in
                        UpNextCard(
                            entry: entry,
                            isSelected: state.projectSelection.contains(entry.projectKey),
                            showsCode: showsCode,
                            liveProgress: entry.projectKey == store.projectKey ? store.progress : nil
                        )
                        .tag(entry.projectKey)
                        .listRowSeparator(.hidden)
                    }
                } header: {
                    SidebarEyebrow("Up Next")
                }
            }
            ForEach(groups) { group in
                Section {
                    ForEach(group.entries) { entry in
                        ProjectSidebarRow(
                            entry: entry,
                            isFocusedProject: entry.projectKey == store.projectKey,
                            isSelected: state.projectSelection.contains(entry.projectKey),
                            showsCode: showsCode,
                            liveProgress: entry.projectKey == store.projectKey ? store.progress : nil
                        )
                        .tag(entry.projectKey)
                        .listRowSeparator(.hidden)
                    }
                } header: {
                    SidebarEyebrow(group.title)
                }
            }
            if groups.isEmpty {
                Text(store.allProjects.isEmpty ? "No projects" : "None \(status.rawValue)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        // The scroll edge effect is left on `.automatic`. It was pinned to a hard top edge when this
        // pane had a header bar of its own — a band fading in behind a button that had nothing else
        // behind it read as the button jumping. The button is in the bottom bar now and the titlebar is
        // what rows scroll under, which is exactly the case the automatic effect is written for.
        .focused($listFocused)
        // Selection is the single click (the list's own) and switching the window is the same act —
        // see `selectionChanged`. The right-click menu acts on whatever was clicked.
        //
        // Both hang off the *list*, not the rows. The selection-aware `contextMenu` is the API written
        // for this: it hands the menu the rows the click applies to — the whole selection when the
        // click lands inside it, just the clicked row when it doesn't — with AppKit's own highlight
        // behind it. A per-row `.contextMenu` can't see that and has to work the selection out itself,
        // which means mutating state from inside a view body: every row would queue its own "select
        // me", each queued write would rebuild the list, and the rebuild would queue them all again.
        // For the same reason the double click is `primaryAction:` here rather than a `TapGesture` on
        // each row, which competed with the click the list needs to select with — and why the switch
        // hangs off the selection rather than off a click handler this list has no room for.
        .contextMenu(forSelectionType: String.self) { keys in
            let targets = entries(for: keys)
            if !targets.isEmpty {
                ProjectMenu(targets: targets,
                            onActivate: { openProject($0, inNewWindow: false) },
                            onOpenInNewWindow: { openProject($0, inNewWindow: true) },
                            onRename: { ProjectPrompts.rename(projectNamed: $0.name, isArchived: $0.isArchived) })
            }
        } primaryAction: { keys in
            // The first click of the double already switched (see `selectionChanged`), so this only
            // has to cover the one case a plain click can't reach: the project is open in another
            // window, which `WindowManager` brings forward rather than duplicating here.
            guard keys.count == 1, let entry = entries(for: keys).first else { return }
            openProject(entry, inNewWindow: false)
        }
    }

    /// Select the window's project when nothing is selected. Never overrides a selection that's
    /// already there: that one is the user's, and it may be a multiple.
    private func seedSelection() {
        guard state.projectSelection.isEmpty, let key = store.projectKey else { return }
        state.projectSelection = [key]
    }

    /// The selection moved — switch the window to it.
    ///
    /// This is the whole click behaviour, and the whole keyboard behaviour with it, because selecting
    /// *is* switching here. The modifiers fall out of that:
    ///
    /// - plain click / ↑↓ / type-select — switch this window;
    /// - ⌥-click — switch a *new* window, leaving this one where it is (the app's "⌥ is the alternate
    ///   destination", same as the header's Open button);
    /// - ⇧-click / ⌘-click — extend or toggle the selection and switch nothing, since a multiple
    ///   selection isn't a place to go. ⌘-clicking a single unselected row is therefore also how you
    ///   select a project without opening it.
    ///
    /// New windows are on ⌥ rather than the ⌘ they used to be on, because ⌘-click is how AppKit
    /// extends a list selection and the two can't both have it.
    private func selectionChanged(to keys: Set<String>) {
        switchTask?.cancel()
        switchTask = nil
        // Empty (a click below the last row) or multiple: nothing to switch to.
        guard keys.count == 1, let key = keys.first else { return }

        // `NSApp.currentEvent` is the event being dispatched, so this runs against the click or
        // keystroke that moved the selection — the same read `openProject` has always made.
        let event = NSApp.currentEvent
        let fromMouse = event.map { $0.type == .leftMouseDown || $0.type == .leftMouseUp } ?? false

        if fromMouse, event?.modifierFlags.contains(.option) == true {
            // The click moved the list's selection on its way to here, but this window isn't going
            // anywhere — put the selection back on the project it's actually showing.
            state.projectSelection = store.projectKey.map { [$0] } ?? []
            state.openProject(key, true)
            return
        }
        guard key != store.projectKey else { return }
        guard !fromMouse else {
            state.openProject(key, false)
            return
        }
        // Arrow keys walk the list, and a walk shouldn't leave ten projects in the recents list and
        // ten writes to `focused.json` behind it — switching is what records both. A click is a
        // decision and switches at once; a keystroke waits for the selection to settle.
        switchTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled, state.projectSelection == keys, key != store.projectKey else { return }
            state.openProject(key, false)
        }
    }

    /// The projects behind a set of keys, in the store's order. Pure — it's read while a menu is being
    /// built, so it must not touch any state.
    private func entries(for keys: Set<String>) -> [PMStore.ProjectEntry] {
        store.allProjects.filter { keys.contains($0.projectKey) }
    }

    /// Open a project — in this window, or a new one (⌥-click, ⌘Return, the context menu). The window
    /// decides what that means; the sidebar just asks.
    private func openProject(_ entry: PMStore.ProjectEntry, inNewWindow: Bool) {
        let newWindow = inNewWindow || NSEvent.modifierFlags.contains(.option)
        guard newWindow || entry.projectKey != store.projectKey else { return }
        state.openProject(entry.projectKey, newWindow)
    }

    /// The projects the Up Next band cards, most pressing first. Empty means no band at all.
    private var upNext: [PMStore.ProjectEntry] {
        Self.upNext(store.allProjects, status: status, grouping: grouping,
                    sort: sortOrder, horizon: upNextHorizon)
    }

    /// How many projects the band cards. Past three it stops reading as a summary and becomes a second
    /// list — and at 224 points, three cards already take about a third of the sidebar.
    private static let maxUpNext = 3

    /// Pick the projects worth carding: the ones the list is already showing, due inside the horizon,
    /// soonest first, capped at `maxUpNext`.
    ///
    /// Three things make the band vanish entirely rather than show an empty container, because a band
    /// that's always there stops being read:
    ///
    /// - the horizon is `.off`;
    /// - the list is already grouped by Due, which puts an Overdue section at the top of its own
    ///   accord. A band above that is the same list twice, four points apart, in two different shapes.
    ///   The band earns its place precisely *because* the default grouping is by domain;
    /// - nothing is due inside the horizon.
    ///
    /// Archived projects never card, even under the Archived or All filter: an archived project isn't
    /// work, whatever date its notes still carry. Everything else is filtered by the same `status` the
    /// list uses, so the band can never point at a project that isn't below it.
    ///
    /// Pure and static for the same reason `arranged` is: it's read while a body is being built.
    private static func upNext(_ projects: [PMStore.ProjectEntry],
                               status: ProjectStatusFilter,
                               grouping: ProjectGrouping,
                               sort: ProjectSortOrder,
                               horizon: UpNextHorizon) -> [PMStore.ProjectEntry] {
        guard let horizonDays = horizon.days, grouping != .due else { return [] }
        let candidates = projects.filter { entry in
            guard status.includes(entry), !entry.isArchived else { return false }
            guard let due = entry.nextDue, let delta = RelativeDue.dayDelta(due) else { return false }
            return delta <= horizonDays
        }
        // Soonest first, on the parsed date rather than the day delta, so two projects due the same day
        // at different hours still order. A genuine tie falls back to the sort order the user picked,
        // so the band never contradicts the list underneath it.
        return Array(
            candidates.sorted { a, b in
                let da = a.nextDue.flatMap(RelativeDue.parse) ?? .distantFuture
                let db = b.nextDue.flatMap(RelativeDue.parse) ?? .distantFuture
                if da != db { return da < db }
                return sort.precedes(a, b)
            }
            .prefix(maxUpNext)
        )
    }

    /// The filtered projects, sorted, then gathered into sections.
    private var groups: [ProjectGroup] {
        Self.arranged(store.allProjects, status: status, kinds: kindFilter,
                      grouping: grouping, sort: sortOrder)
    }

    /// Filter, sort, then gather into sections. `Dictionary(grouping:)` preserves the order of the
    /// values it's handed, so sorting up front orders the Domain grouping's sections; Due re-sorts by
    /// date within its own branch below, since due order and `sort` order aren't the same thing.
    private static func arranged(_ projects: [PMStore.ProjectEntry],
                                 status: ProjectStatusFilter,
                                 kinds: ProjectKindFilter,
                                 grouping: ProjectGrouping,
                                 sort: ProjectSortOrder) -> [ProjectGroup] {
        let sorted = projects
            .filter { status.includes($0) && kinds.includes($0) }
            .sorted { sort.precedes($0, $1) }

        // Areas are held out of the grouping and appended in one section at the bottom. Neither
        // grouping has anything to say about them — an area has no domain and no due date, so by Domain
        // they'd file under a heading that isn't one and by Due they'd all land together in "No date" —
        // and the list reads better with the changing foreground on top and the standing things beneath
        // it. Sorting happened before the split, so both halves are already in order.
        let areas = sorted.filter { $0.kind == .area }
        let rest = sorted.filter { $0.kind != .area }

        var groups: [ProjectGroup]
        switch grouping {
        case .domain:
            let byDomain = Dictionary(grouping: rest, by: \.domain)
            groups = byDomain.keys.sorted().map { ProjectGroup(title: $0, entries: byDomain[$0] ?? []) }
        case .due:
            // The due date, not `sort`, decides order within a bucket — otherwise "Later" (which spans
            // weeks to years) reads as shuffled whenever `sort` is Code or Recency. Same comparator as
            // `upNext`: soonest first on the parsed date, `sort` only breaks a tie.
            let dueSorted = rest.sorted { a, b in
                let da = a.nextDue.flatMap(RelativeDue.parse) ?? .distantFuture
                let db = b.nextDue.flatMap(RelativeDue.parse) ?? .distantFuture
                if da != db { return da < db }
                return sort.precedes(a, b)
            }
            let byBucket = Dictionary(grouping: dueSorted, by: DueBucket.of)
            groups = DueBucket.allCases.compactMap { bucket in
                guard let entries = byBucket[bucket] else { return nil }
                return ProjectGroup(title: bucket.title, entries: entries)
            }
        }
        if !areas.isEmpty {
            groups.append(ProjectGroup(title: ProjectKind.area.pluralDisplayName, entries: areas))
        }
        return groups
    }
}

/// The sidebar's bottom bar: filter, group and sort, in the strip along the bottom of the source list.
///
/// This is where a source list's own controls belong — the sidebar column isn't a place to put toolbar
/// items, and the bottom bar is the strip Mac apps use for the actions that act on the list itself.
/// It's carried by a `NSSplitViewItemAccessoryViewController` (see `ProjectSplitViewController`), which
/// is what floats it over the list, insets the rows above it, and fades them under it on scroll.
///
/// Its own `@AppStorage` rather than a binding passed across: the bar is a separate hosting controller
/// in the accessory, so there's no view tree to thread a binding down. Both views read the same three
/// keys and `@AppStorage` republishes to every reader, so the list re-arranges as the menu is used.
struct SidebarBottomBar: View {
    @AppStorage("PMSidebarStatus") private var status: ProjectStatusFilter = .active
    @AppStorage("PMSidebarKind") private var kindFilter: ProjectKindFilter = .all
    @AppStorage("PMSidebarGroup") private var grouping: ProjectGrouping = .domain
    @AppStorage("PMSidebarSort") private var sortOrder: ProjectSortOrder = .recency
    /// See `ProjectSidebar.showsCode` — same key, read here so the menu can toggle it.
    @AppStorage("PMSidebarShowCode") private var showsCode: Bool = true
    /// See `ProjectSidebar.upNextHorizon` — same key, set here.
    @AppStorage("PMSidebarUpNext") private var upNextHorizon: UpNextHorizon = .week

    var body: some View {
        HStack(spacing: 4) {
            arrangeMenu
            Spacer(minLength: 0)
        }
        // AppKit already insets the accessory from the pane's edges, so this is only the gap between
        // the bar's own edge and the control in it.
        .padding(.horizontal, 6)
        .frame(height: 24)
    }

    /// Status / grouping / sorting, one submenu each — the shape the Finder's View menu uses for the
    /// same job ("Sort By ▸"). Three short lists behind their own titles read as three separate
    /// decisions; flattened into one column they'd run together into eleven items with no visible
    /// boundary between what filters, what groups, and what orders.
    ///
    /// Each submenu holds an inline `Picker`, so its options carry checkmarks and the current value
    /// is visible one level down rather than being spelled out in the parent row.
    private var arrangeMenu: some View {
        Menu {
            Menu {
                Picker("Status", selection: $status) {
                    Label("Active", systemImage: "circle").tag(ProjectStatusFilter.active)
                    Label("Archived", systemImage: "archivebox").tag(ProjectStatusFilter.archived)
                    Label("All", systemImage: "square.stack").tag(ProjectStatusFilter.all)
                }
                .pickerStyle(.inline)
                // Two pickers in one submenu, because both answer "which rows". Status and kind are
                // independent — an area can be archived — so they can't be one list.
                Divider()
                Picker("Kind", selection: $kindFilter) {
                    Label("Projects", systemImage: "shippingbox").tag(ProjectKindFilter.projects)
                    Label("Areas", systemImage: "circle.dotted").tag(ProjectKindFilter.areas)
                    Label("Everything", systemImage: "square.stack.3d.up").tag(ProjectKindFilter.all)
                }
                .pickerStyle(.inline)
            } label: {
                Label("Show", systemImage: "line.3.horizontal.decrease.circle")
            }
            Menu {
                Picker("Group by", selection: $grouping) {
                    Label("Due", systemImage: "calendar").tag(ProjectGrouping.due)
                    Label("Domain", systemImage: "folder").tag(ProjectGrouping.domain)
                }
                .pickerStyle(.inline)
            } label: {
                Label("Group By", systemImage: "rectangle.3.group")
            }
            Menu {
                Picker("Sort by", selection: $sortOrder) {
                    Label("Code", systemImage: "number").tag(ProjectSortOrder.code)
                    Label("Name", systemImage: "textformat").tag(ProjectSortOrder.name)
                    Label("Recency", systemImage: "clock").tag(ProjectSortOrder.recency)
                }
                .pickerStyle(.inline)
            } label: {
                Label("Sort By", systemImage: "arrow.up.arrow.down")
            }
            // With the other three rather than below the divider: this decides *which* projects appear
            // at the top of the list, which is the same kind of decision as filtering and grouping.
            // Below the divider is where the one display-only choice lives.
            //
            // Nothing here spells out that Group By ▸ Due suppresses the band. Disabling the submenu in
            // that case would be worse than silence — it reads as broken rather than as redundant, and
            // the band reappearing the moment you group by Domain again explains itself.
            Menu {
                Picker("Up next", selection: $upNextHorizon) {
                    ForEach(UpNextHorizon.allCases, id: \.self) { horizon in
                        Text(horizon.title).tag(horizon)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Label("Up Next", systemImage: "calendar.badge.clock")
            }
            Divider()
            // A checkbox rather than a fourth submenu: it's one binary display choice, not a choice
            // between alternatives, and the three submenus above are all "which projects, in what
            // order" — this one only changes how a row is written.
            Toggle(isOn: $showsCode) {
                Label("Show Project Code", systemImage: "number")
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 18)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        // A fixed footprint rather than `.fixedSize()`. A borderless `Menu` reports an intrinsic width
        // that isn't perfectly stable — it shifts with hover and key state — so pinning it keeps the
        // button still.
        .frame(width: 22, height: 18)
        .help("Filter, group & sort projects")
    }
}

/// A single project row: completion ring, name, and the project's next task beneath it. The row draws
/// only its content — selection, hover and focus highlighting all belong to the enclosing `List`,
/// which gets the active/inactive and emphasized/unemphasized states right for free. The project the
/// window is on also reads semibold; normally that's the selected row too, and the weight only says
/// anything of its own while a multiple selection is up. Archived projects (visible under the Archived
/// / All filters) read a step quieter than active ones.
private struct ProjectSidebarRow: View {
    let entry: PMStore.ProjectEntry
    /// Whether this is the project the window is currently showing.
    let isFocusedProject: Bool
    /// Whether the row sits in the list's selection — the due date's tint has to stand down on the
    /// highlight, where a red or orange word doesn't read.
    let isSelected: Bool
    /// Whether the name keeps its "CODE-NNN " prefix (`PMSidebarShowCode`).
    let showsCode: Bool
    /// Live (done, total) for the focused project, which the cached scan can lag behind. Nil for every
    /// other row, which falls back to the warmed values.
    let liveProgress: (done: Int, total: Int)?

    private var total: Int { liveProgress?.total ?? entry.total }
    private var done: Int { liveProgress?.done ?? entry.done }
    private var fraction: Double { total > 0 ? Double(done) / Double(total) : 0 }
    private var title: String { showsCode ? entry.name : entry.shortName }

    /// How long ago an area was last written to, in the shortest form that still reads: "today",
    /// "3d", "5w". Deliberately coarse — this is a glance at whether something has been left alone,
    /// not a timestamp.
    static func lastTouched(_ date: Date, now: Date = Date()) -> String {
        let days = Calendar.current.dateComponents([.day], from: date, to: now).day ?? 0
        switch days {
        case ..<1: return "today"
        case 1: return "1d"
        case 2...13: return "\(days)d"
        case 14...364: return "\(days / 7)w"
        default: return "\(days / 365)y"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            KindMark(entry: entry, fraction: fraction, total: total)
            VStack(alignment: .leading, spacing: 1) {
                // The due date rides the name line rather than the task line: `nextDue` is the
                // earliest due across the project's open tasks, which needn't be the next task's own.
                // It's the same fact the Due grouping buckets on, so a due-grouped list reads as its
                // section heading spelled out per row.
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(title)
                        .font(.system(size: 13, weight: isFocusedProject ? .semibold : .regular))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                    if let due = entry.nextDue {
                        SidebarDueLabel(due: due, isSelected: isSelected)
                    } else if !entry.showsProgress, entry.detailsLoaded {
                        // Nothing with a ring has room for this, and nothing without a ring has a due
                        // date — so the slot the date rides in carries the one time signal an area
                        // does have: when it was last written to. It also explains the order the list
                        // is in when sorting by recency, which is the default.
                        Text(Self.lastTouched(entry.modified))
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                if let task = entry.nextTask {
                    Text(task)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
        // Sized to its content: a project with nothing in flight is a single line, and only the ones
        // with a next task are two. A uniform height made every row as tall as the tallest, which read
        // as a list of half-empty boxes.
        //
        // This was fixed for a reason once — the scan paints names first and fills in each project's
        // next task a moment later, so rows grow after the list has laid out. That's survivable now
        // because the seed reuses whatever detail it already has (see `ProjectIndex.seedAllProjects`),
        // so a re-scan doesn't drop every task line and re-add it; only the very first scan of a
        // session resizes rows, once.
        .padding(.vertical, 4)
        // The whole row is the click target, not just its text.
        .contentShape(Rectangle())
        // Carve the row out of the focus panel window-drag region, or AppKit's drag-tracking loop eats the
        // mouse-down and the row never registers the click. This has to sit on the row rather than
        // behind the `List` (where it was): a `List` builds its own scroll and table views, and those
        // are in front of anything the list's SwiftUI `.background` puts down — so the excluder was
        // never the view AppKit hit-tested. Inside the row it *is* the deepest view under the pointer.
        .background(WindowDragExcluder())
        // Archived projects stay legible but recede, so a mixed ("All") list still reads at a glance.
        .opacity(entry.isArchived ? 0.6 : 1)
        .help(helpText)
        // Two text lines and a ring read as one row, with the tooltip's fuller description as its
        // label. The list supplies the row's selected state and actions.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(helpText)
    }

    /// Tooltip: the counts and due date the one-line-per-field row has no room for.
    private var helpText: String {
        var parts: [String] = [entry.name]
        if total > 0 { parts.append("\(done)/\(total)") }
        if let due = entry.nextDue { parts.append("due \(RelativeDue.short(due))") }
        if let task = entry.nextTask { parts.append(task) }
        return parts.joined(separator: "  ·  ")
    }
}

/// The project's soonest open due date, trailing its name — the one fact the row's two lines couldn't
/// carry, and the reason a sidebar is worth scanning at all: which project needs you next.
///
/// Plain tinted text rather than the menubar's `DuePillView` capsule. A source list's rows are already
/// small inset shapes; a filled capsule inside one reads as a badge on a badge, and the menubar's pill
/// earns its background because it sits on a flat menu row with no shape of its own.
///
/// The tint stands down on a selected row: `.secondary` is the one style that resolves correctly
/// against all three of the list's highlights (accent, unemphasized grey, none), where a fixed red or
/// white is wrong for two of them. This is the same trade the pill makes when it inverts.
private struct SidebarDueLabel: View {
    let due: String
    let isSelected: Bool

    var body: some View {
        Text(RelativeDue.short(due))
            .font(.system(size: 11))
            .monospacedDigit()
            .lineLimit(1)
            .foregroundStyle(isSelected ? Color.secondary : tint)
            // A long project name truncates before the date gives up any of its width — the date is
            // three or four characters and the name has ellipsis to fall back on.
            .layoutPriority(1)
            // The exact date behind the badge. This one summarises a whole project's earliest due, so
            // the tooltip names it rather than leaving "in 2w" as the only answer available.
            .help("Next due \(RelativeDue.full(due))")
    }

    /// Red overdue, orange due today or tomorrow, quiet after that — the menubar pill's own scale, so
    /// the two surfaces agree on what "late" looks like. `own: true` because a project's earliest due
    /// is just a date by the time it reaches here; whether the task inherited it isn't carried.
    private var tint: Color {
        switch DueState(due: due, own: true) {
        case .overdue: return Color(nsColor: .systemRed)
        case .soon: return Color(nsColor: .systemOrange)
        case .later, .inherited: return .secondary
        }
    }
}

/// One Up Next card: the same three facts its row carries — ring, name, next task — with the due date
/// promoted from `SidebarDueLabel`'s tinted text to the menubar's `DuePillView`, on a fill washed with
/// the severity colour.
///
/// The wash is the point of the card. At 224 points there is no room to say anything the row doesn't
/// already say, so what a card adds isn't information but *weight*: a shape, a semibold name and a tint
/// you read before you read a word. The tint is redundant with the pill's own text ("2d ago", "today"),
/// which is exactly what lets it sit under 10% — the card never depends on colour to be understood, so
/// Increase Contrast and the colour-blind settings are a non-event.
///
/// Two things it deliberately isn't. It isn't a material: the sidebar is already vibrant, and a second
/// material on top of the first composites to mud in light and to a smudge in dark, so the fill is a
/// flat low-alpha colour the vibrancy still reads through. And it has no leading accent rail — that's a
/// web convention no system app draws, and the app already owns two ways of saying "late" that cost
/// nothing to reuse.
///
/// Selected, the card gives up its fill, its border and its tint and lets the list's own highlight
/// through. That's the same trade `SidebarDueLabel` makes and for the same reason — a red or orange
/// wash resolves against exactly one of the list's three highlight states — and it's what keeps a card
/// from reading as a permanently-selected row while it sits directly above real ones. `DuePillView`
/// already knows how to invert onto the highlight; it only needs telling.
private struct UpNextCard: View {
    let entry: PMStore.ProjectEntry
    /// Whether the row sits in the list's selection. Drives the stand-down described above.
    let isSelected: Bool
    /// Whether the name keeps its "CODE-NNN " prefix (`PMSidebarShowCode`), as the rows do.
    let showsCode: Bool
    /// Live (done, total) when this is the window's own project, which the cached scan can lag behind.
    let liveProgress: (done: Int, total: Int)?

    private var total: Int { liveProgress?.total ?? entry.total }
    private var done: Int { liveProgress?.done ?? entry.done }
    private var fraction: Double { total > 0 ? Double(done) / Double(total) : 0 }
    private var title: String { showsCode ? entry.name : entry.shortName }

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            // An area reaches this card whenever a task inside it has a date, so it needs the mark too.
            KindMark(entry: entry, fraction: fraction, total: total)
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    // Semibold is what marks the promotion. The rows below stay regular, so a carded
                    // project reads heavier than its own row without needing a different size.
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                    if let due = entry.nextDue {
                        DuePillView(text: RelativeDue.short(due),
                                    state: DueState(due: due, own: true),
                                    selected: isSelected)
                            // The name truncates before the pill gives up any width: the pill is three
                            // or four characters and the name has ellipsis to fall back on.
                            .layoutPriority(1)
                            .help("Next due \(RelativeDue.full(due))")
                    }
                }
                if let task = entry.nextTask {
                    Text(task)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
        // The row's own 4×6 plus the point the border takes.
        .padding(.vertical, 7)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            // Radius 8, a step above the ~5 the source list's selection shape uses, so a card reads as
            // a container rather than as a selected row.
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(fill)
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(border, lineWidth: 0.5)
                }
        }
        // Outside the shape, so it's the gap *between* cards rather than more padding inside them —
        // sidebar list rows are contiguous, and without this two cards would touch.
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        // See `ProjectSidebarRow`: without this AppKit's window-drag tracking eats the mouse-down and
        // the card never registers the click.
        .background(WindowDragExcluder())
        .help(helpText)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(helpText)
    }

    /// The card's severity, on the same `DueState` scale the menubar pill and the sidebar's due label
    /// use. `own: true` because a project's earliest due is just a date by the time it reaches here —
    /// whether the task inherited it isn't carried this far.
    private var severity: DueState {
        guard let due = entry.nextDue else { return .later }
        return DueState(due: due, own: true)
    }

    private var fill: Color {
        guard !isSelected else { return .clear }
        switch severity {
        case .overdue: return Color(nsColor: .systemRed).opacity(0.09)
        case .soon: return Color(nsColor: .systemOrange).opacity(0.10)
        // `.controlBackgroundColor` is white over a light window and near-black over a dark one, so a
        // neutral card reads as raised off the sidebar in both without branching on the appearance.
        case .later, .inherited: return Color(nsColor: .controlBackgroundColor).opacity(0.7)
        }
    }

    private var border: Color {
        guard !isSelected else { return .clear }
        switch severity {
        case .overdue: return Color(nsColor: .systemRed).opacity(0.16)
        case .soon: return Color(nsColor: .systemOrange).opacity(0.18)
        case .later, .inherited: return Color(nsColor: .separatorColor)
        }
    }

    /// Tooltip: the counts and due date the card's two lines have no room for. Same shape as the row's,
    /// so hovering a card and hovering its row say the same thing.
    private var helpText: String {
        var parts: [String] = [entry.name]
        if total > 0 { parts.append("\(done)/\(total)") }
        if let due = entry.nextDue { parts.append("due \(RelativeDue.short(due))") }
        if let task = entry.nextTask { parts.append(task) }
        return parts.joined(separator: "  ·  ")
    }
}

/// Right-click actions for the selected projects. Opening is single-target (a window shows one project
/// at a time); revealing, copying and archiving work on the whole selection, so a multi-select is worth
/// making. Nothing here deletes anything — a project is a folder of the user's own files, archiving is a
/// move you can undo by unarchiving, and removing one belongs in the Finder.
private struct ProjectMenu: View {
    let targets: [PMStore.ProjectEntry]
    let onActivate: (PMStore.ProjectEntry) -> Void
    let onOpenInNewWindow: (PMStore.ProjectEntry) -> Void
    let onRename: (PMStore.ProjectEntry) -> Void

    private var isMulti: Bool { targets.count > 1 }

    /// Whether the selection archives or unarchives as one act — nil on a mixed selection, which has no
    /// single answer and so isn't offered.
    private var archiveDirection: Bool? {
        guard let first = targets.first else { return nil }
        return targets.allSatisfy { $0.isArchived == first.isArchived } ? first.isArchived : nil
    }

    var body: some View {
        if let only = targets.first, !isMulti {
            Button { onActivate(only) } label: {
                Label("Open Project", systemImage: "arrow.right.circle")
            }
            Button { onOpenInNewWindow(only) } label: {
                Label("Open in New Window", systemImage: "macwindow.badge.plus")
            }
            Divider()
        }
        Button { reveal() } label: {
            Label(isMulti ? "Reveal \(targets.count) in Finder" : "Reveal in Finder", systemImage: "folder")
        }
        Button { copyNames() } label: {
            Label(isMulti ? "Copy \(targets.count) Names" : "Copy Name", systemImage: "doc.on.doc")
        }
        .keyboardShortcut("c", modifiers: .command)
        if let only = targets.first, !isMulti {
            Divider()
            Button { onRename(only) } label: {
                Label("Rename \(only.kind.displayName)…", systemImage: "pencil")
            }
        }
        if let isArchived = archiveDirection {
            if !isMulti { Divider() }
            Button { ProjectLifecycle.move(projects: targets) } label: {
                Label(archiveTitle(isArchived: isArchived),
                      systemImage: isArchived ? "tray.and.arrow.up" : "archivebox")
            }
        }
    }

    /// The one kind in the selection, or nil when it holds both — which is when the menu falls back to
    /// the neutral wording rather than picking one of the two and being wrong about half the rows.
    private var singleKind: ProjectKind? {
        guard let first = targets.first else { return nil }
        return targets.allSatisfy { $0.kind == first.kind } ? first.kind : nil
    }

    /// A project is archived; an area is put down. Same move, and not the same act — one is finished,
    /// the other is handed on or let go — so the menu says which.
    private func archiveTitle(isArchived: Bool) -> String {
        let kind = singleKind
        if isMulti {
            let noun = kind?.pluralDisplayName ?? "Items"
            return isArchived ? "Restore \(targets.count) \(noun)"
                              : "\(kind?.retireVerb ?? "Archive") \(targets.count) \(noun)"
        }
        let noun = kind?.displayName ?? "Item"
        return isArchived ? "Restore \(noun)" : "\(kind?.retireVerb ?? "Archive") \(noun)"
    }

    /// One Finder window with every selected project's folder highlighted.
    private func reveal() {
        let urls = targets
            .compactMap { PMFiles.projectPath(fromKey: $0.projectKey) }
            .map { URL(fileURLWithPath: $0) }
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    private func copyNames() {
        let names = targets.map(\.name).joined(separator: "\n")
        guard !names.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(names, forType: .string)
    }
}

/// The mark at the head of a sidebar row: a completion ring for a project, and for an area a dotted
/// circle — the same shape with no end to fill toward.
///
/// Drawing a ring on an area would be the one mark in the app that lies. `done/total` there is a
/// fraction of a number that keeps growing, so it would sit near some arbitrary percentage forever and
/// mean nothing by it. The menubar and the switcher say the same thing with a dashed ring, which is as
/// close to `circle.dotted` as a 15pt drawn glyph gets.
///
/// One view rather than two copies, because the row and the Up Next card both draw it and an area can
/// appear in either — a card whenever one of its tasks carries a date.
private struct KindMark: View {
    let entry: PMStore.ProjectEntry
    let fraction: Double
    let total: Int

    var body: some View {
        if entry.showsProgress {
            // The ring is a template image, so it takes the row's foreground color, the same way the
            // menubar recolors it.
            Image(nsImage: MenubarRing.image(fraction: fraction, hasProject: total > 0, tint: nil))
                .renderingMode(.template)
                .opacity(entry.detailsLoaded ? 1 : 0.35)
        } else {
            Image(systemName: "circle.dotted")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                // Matched to the ring image's box so both kinds of row line their text up.
                .frame(width: 16, height: 16)
        }
    }
}

/// An editorial section label: uppercase, letter-spaced, tertiary — the sidebar's echo of the details
/// brief's eyebrow.
private struct SidebarEyebrow: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .textCase(.uppercase)
            .tracking(0.9)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
    }
}

