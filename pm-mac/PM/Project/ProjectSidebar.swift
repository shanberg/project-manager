import SwiftUI
import AppKit

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

/// How the sidebar's rows are gathered into sections.
enum ProjectGrouping: String { case due, domain }

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
/// "name — task" line, given room to breathe. Clicking a row focuses that project, so the sidebar is
/// the always-visible form of the title's switcher menu, for when you're moving between projects rather
/// than working inside one.
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
    @AppStorage("PMSidebarGroup") private var grouping: ProjectGrouping = .domain
    @AppStorage("PMSidebarSort") private var sortOrder: ProjectSortOrder = .recency

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBar
            Divider()
            list
        }
        // Lay out at no less than the pane's own minimum width, then clip to whatever width the pane
        // currently has.
        //
        // Collapsing animates the pane's width to zero, and without this the content re-lays out at
        // every intermediate width on the way — names re-truncating, the header's label and menu
        // crushing together, rows reflowing — for a quarter second, every toggle. A native source list
        // doesn't do that because `NSTableView` clips its rows rather than reflowing them, and this is
        // that behaviour: the content holds its layout and slides out of view behind the clip. Dragging
        // the divider still reflows normally, since the split item won't go below this width except by
        // collapsing.
        .frame(minWidth: ProjectWindow.sidebarMinWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
        // The sidebar runs under the (hidden, transparent) titlebar too, so the two panes' header bars
        // start at the same y and their rules meet. The traffic lights land in this pane's header —
        // `headerBar` insets itself past them.
        .ignoresSafeArea(.container, edges: .top)
        // Only ever written on *gaining* focus: a pane losing it (the window going inactive, a menu
        // opening) shouldn't strand ⌘C with no target.
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
            ForEach(groups) { group in
                Section {
                    ForEach(group.entries) { entry in
                        ProjectSidebarRow(
                            entry: entry,
                            isFocusedProject: entry.projectKey == store.projectKey,
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
        .focused($listFocused)
        // Selection is the single click (the list's own); the double click switches the window to a
        // project, and the right-click menu acts on whatever was clicked.
        //
        // Both hang off the *list*, not the rows. The selection-aware `contextMenu` is the API written
        // for this: it hands the menu the rows the click applies to — the whole selection when the
        // click lands inside it, just the clicked row when it doesn't — with AppKit's own highlight
        // behind it. A per-row `.contextMenu` can't see that and has to work the selection out itself,
        // which means mutating state from inside a view body: every row would queue its own "select
        // me", each queued write would rebuild the list, and the rebuild would queue them all again.
        // For the same reason the double click is `primaryAction:` here rather than a `TapGesture` on
        // each row, which competed with the click the list needs to select with.
        .contextMenu(forSelectionType: String.self) { keys in
            let targets = entries(for: keys)
            if !targets.isEmpty {
                ProjectMenu(targets: targets,
                            onActivate: { openProject($0, inNewWindow: false) },
                            onOpenInNewWindow: { openProject($0, inNewWindow: true) })
            }
        } primaryAction: { keys in
            guard keys.count == 1, let entry = entries(for: keys).first else { return }
            openProject(entry, inNewWindow: false)
        }
    }

    /// The sidebar's own header: a quiet label and the arrange menu, sized to the task header beside it
    /// so the two rules meet.
    private var headerBar: some View {
        HStack(spacing: 4) {
            SidebarEyebrow("Projects")
            Spacer(minLength: 0)
            arrangeMenu
        }
        // The window's close/minimise/zoom buttons sit in this bar, over the sidebar — so the label
        // starts past them rather than under them.
        .padding(.leading, state.leadingTitlebarInset)
        .padding(.trailing, 12)
        // Match the task header height exactly (less its own 1pt rule) when it's been measured, so
        // the sidebar's divider continues the header's; fall back to a sensible height before then.
        .frame(height: state.headerHeight > 1 ? state.headerHeight - 1 : 47)
    }

    /// Status / grouping / sorting, one submenu each — the sidebar's counterpart to the task
    /// header's view-options button, and the shape the Finder's View menu uses for the same job
    /// ("Sort By ▸"). Three short lists behind their own titles read as three separate decisions;
    /// flattened into one column they'd run together into eleven items with no visible boundary
    /// between what filters, what groups, and what orders.
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
        } label: {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 18)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Filter, group & sort projects")
    }

    /// The projects behind a set of keys, in the store's order. Pure — it's read while a menu is being
    /// built, so it must not touch any state.
    private func entries(for keys: Set<String>) -> [PMStore.ProjectEntry] {
        store.allProjects.filter { keys.contains($0.projectKey) }
    }

    /// Open a project — in this window (the double-click, Return) or a new one (⌘-double-click,
    /// ⌘Return, the context menu). The window decides what that means; the sidebar just asks.
    private func openProject(_ entry: PMStore.ProjectEntry, inNewWindow: Bool) {
        let newWindow = inNewWindow || NSEvent.modifierFlags.contains(.command)
        guard newWindow || entry.projectKey != store.projectKey else { return }
        state.openProject(entry.projectKey, newWindow)
    }

    /// The filtered projects, sorted, then gathered into sections.
    private var groups: [ProjectGroup] {
        Self.arranged(store.allProjects, status: status, grouping: grouping, sort: sortOrder)
    }

    /// Filter, sort, then gather into sections. `Dictionary(grouping:)` preserves the order of the
    /// values it's handed, so sorting once up front orders every section.
    private static func arranged(_ projects: [PMStore.ProjectEntry],
                                 status: ProjectStatusFilter,
                                 grouping: ProjectGrouping,
                                 sort: ProjectSortOrder) -> [ProjectGroup] {
        let sorted = projects
            .filter { status.includes($0) }
            .sorted { sort.precedes($0, $1) }
        switch grouping {
        case .domain:
            let byDomain = Dictionary(grouping: sorted, by: \.domain)
            return byDomain.keys.sorted().map { ProjectGroup(title: $0, entries: byDomain[$0] ?? []) }
        case .due:
            let byBucket = Dictionary(grouping: sorted, by: DueBucket.of)
            return DueBucket.allCases.compactMap { bucket in
                guard let entries = byBucket[bucket] else { return nil }
                return ProjectGroup(title: bucket.title, entries: entries)
            }
        }
    }
}

/// A single project row: completion ring, name, and the project's next task beneath it. The row draws
/// only its content — selection, hover and focus highlighting all belong to the enclosing `List`,
/// which gets the active/inactive and emphasized/unemphasized states right for free. The project the
/// app is currently *on* is marked separately (its name reads semibold), since selection and focus
/// are different things here. Archived projects (visible under the Archived / All filters) read a
/// step quieter than active ones.
private struct ProjectSidebarRow: View {
    let entry: PMStore.ProjectEntry
    /// Whether this is the project the window is currently showing.
    let isFocusedProject: Bool
    /// Live (done, total) for the focused project, which the cached scan can lag behind. Nil for every
    /// other row, which falls back to the warmed values.
    let liveProgress: (done: Int, total: Int)?

    private var total: Int { liveProgress?.total ?? entry.total }
    private var done: Int { liveProgress?.done ?? entry.done }
    private var fraction: Double { total > 0 ? Double(done) / Double(total) : 0 }

    /// Every row is this tall whether or not it has a task line.
    ///
    /// Not a style choice — a correctness one. The scan paints project names first and fills in each
    /// project's next task a moment later, so a row that sized to its content would grow from one line
    /// to two *after* the list had laid out. The table keeps the row rectangles it measured, and from
    /// then on the highlight it draws under the pointer belongs to a different row than the one you're
    /// over. A constant height means the rows never move under the mouse, and it gives the list an even
    /// rhythm besides.
    ///
    /// Tall enough that the two text lines sit *inside* the source list's rounded highlight with air
    /// above and below, rather than filling it to the edges — the difference between a row that reads
    /// as an item and one that reads as a band.
    private static let height: CGFloat = 38

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            // The ring is a template image, so it takes the row's foreground color, the same way the
            // menubar recolors it.
            Image(nsImage: MenubarRing.image(fraction: fraction, hasProject: total > 0, tint: nil))
                .renderingMode(.template)
                .opacity(entry.detailsLoaded ? 1 : 0.35)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name)
                    .font(.system(size: 13, weight: isFocusedProject ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let task = entry.nextTask {
                    Text(task)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 0)
        }
        // Fixed, so a task line arriving mid-scan can't resize the row (see `height`). One-line rows
        // centre in it rather than riding the top edge.
        .frame(height: Self.height)
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

/// Right-click actions for the selected projects. Opening is single-target (a window shows one project
/// at a time); revealing and copying work on the whole selection, so a multi-select is worth making.
/// Nothing here is destructive — a project is a folder of the user's own files, and removing one belongs
/// in the Finder.
private struct ProjectMenu: View {
    let targets: [PMStore.ProjectEntry]
    let onActivate: (PMStore.ProjectEntry) -> Void
    let onOpenInNewWindow: (PMStore.ProjectEntry) -> Void

    private var isMulti: Bool { targets.count > 1 }

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

