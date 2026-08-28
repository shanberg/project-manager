import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ObjectiveC
import PmLib

/// A project window's content column: a collapsible "Project details" section, a task list grouped by
/// session, per-row focus / due editing / positional add, and an "incomplete only" filter. Binds to
/// `PMStore`; mutations go straight through it to `PmLib`.
///
/// This is the full view and editor. The "what am I on right now" reduction of it — one task, its
/// breadcrumb, and what's next — is the focus panel, a separate always-on-top window (see
/// `FocusPanelView`).
struct ProjectView: View {
    @ObservedObject var store: PMStore
    /// The state this pane shares with the project sidebar across the split (see `ProjectViewState`).
    @ObservedObject var state: ProjectViewState

    /// How the tasks area presents itself, persisted across sessions. `.incomplete` (open tasks only)
    /// is the default; `.all` also reveals completed ones. The single-task view this used to offer as a
    /// third mode is now its own surface — see `FocusPanelView`.
    @AppStorage("PMPanelTasksMode") private var tasksMode: TasksMode = .incomplete
    /// The app color-scheme override, persisted across sessions. `.system` follows the OS setting;
    /// `.light`/`.dark` pin the appearance (of both the content and the glass/vibrancy material).
    @AppStorage("PMPanelColorMode") private var colorMode: AppColorMode = .system
    /// The single "notes" view mode, toggled from the header's view-options menu and persisted across
    /// sessions. When on, the window shows the project-details brief below the header *and* reveals
    /// every session (including empty ones) as a first-class header with its editable prose note and
    /// management affordances. Off (the default) is the compact task view — no brief, and sessions are
    /// just quiet captions above their tasks with empty ones hidden.
    /// The persisted value. App-wide, and written from outside this view too — the View menu sets the
    /// same key (`AppDelegate+Commands`) — so it stays `@AppStorage`. Nothing lays out against it.
    @AppStorage("PMPanelDetailsExpanded") private var storedDetailsExpanded = false

    /// The value the view actually lays out against: a mirror of `storedDetailsExpanded` that is only
    /// ever written inside an explicit animation.
    ///
    /// `@AppStorage` republishes on the *next* runloop tick, outside whatever transaction changed it, so
    /// `withAnimation` at a toggle site simply doesn't take. The way round that was for every subview
    /// moving on the toggle to key its own `.animation(detailsMotion, value:)` off the flag — which
    /// works, but only for as long as each of them remembers to, and one that forgets jumps silently
    /// while its neighbours glide. Mirroring into plain view state puts the change back inside a
    /// transaction, so a single `withAnimation` in `setDetails` drives all of them at once.
    @State private var detailsExpanded = false
    /// Whether the project-details section is in inline-edit mode (entered by double-clicking its
    /// content). Reset when the section collapses, the project changes, or Escape is pressed.
    @State private var editingDetails = false
    /// The row (and editor kind) with an open inline editor, if any. Only one at a time.
    @State private var activeEditor: EditorTarget?
    /// True while the empty-project CTA has revealed its inline add editor (for the very first task).
    @State private var addingFirstTask = false
    /// The find bar's query. Empty while it's closed — closing clears it, so the list is never left
    /// quietly filtered by a bar you can't see.
    @State private var findQuery = ""
    /// Whether the find bar is showing, and a counter that pulls focus back into its field (⌘F while
    /// it's already open re-focuses and selects, as it does in Safari).
    @State private var findVisible = false
    @State private var findFocusToken = 0
    /// The key of the task subtree currently being dragged, set when a row's drag begins. Nil when no
    /// drag is in flight. The subtree is lifted out of the list before a drop is resolved against it —
    /// see `TaskDropResolver`.
    @State private var draggingKey: String?
    /// Frames (Y-extent + depth) of every visible task row in the task-list coordinate space, collected
    /// via a preference. The single list-level drop delegate reads these to resolve the pointer into a
    /// gap + depth.
    @State private var rowFrames: [RowFrame] = []
    /// Frames of every rendered session heading, in the same space and collected the same way. A
    /// session with no task rows to name a slot is a drop target in its own right — see `SessionFrame`.
    @State private var sessionFrames: [SessionFrame] = []
    /// The single resolved insertion slot for the in-flight drag — where to paint the indicator and
    /// which document slot the drop will use. Nil when nothing is being dragged over the list.
    @State private var dropTarget: DropTarget?
    /// The selected task rows, by `PMStore.key`. Ephemeral (never persisted): the keys are document
    /// positions, so they only mean anything against the currently-loaded todos.
    @State private var selection: Set<String> = []
    /// The row a ⇧-click or ⇧-arrow extends the selection *from* — the last row picked without ⇧.
    @State private var selectionAnchor: String?
    /// Whether the task list holds keyboard focus. Drives "emphasized" selection — the Mac's
    /// distinction between a selection in the focused control and the same selection in an unfocused
    /// one — and mirrors itself into `state.focusedPane`, which is what routes ⌘A / ⌘C / Return across
    /// the split to whichever pane the user is in.
    @FocusState private var tasksFocused: Bool
    /// Tasks awaiting the inline delete confirmation. Empty when no delete is pending.
    @State private var pendingDelete: [Todo] = []
    /// Set while this window is adding a session on purpose, so the session-count watcher doesn't read
    /// its own change as a reason to close the editor it's opening. See `beginCurrentSession`.
    @State private var sessionCountChangeIsOurs = false
    /// A row the keyboard just moved onto, for the scroll view to reveal. Cleared once acted on.
    @State private var scrollTarget: ScrollRequest?
    /// Bumped per request, so `ScrollRequest`s for the same row are distinct values. See `ScrollRequest`.
    @State private var scrollToken = 0
    /// Tracks the ⌥ key so the Open button can swap between Obsidian and Finder live, like the menu.
    @StateObject private var modifiers = ModifierMonitor()
    /// Cancels an open editor when the user clicks outside it (see `OutsideClickMonitor`).
    @StateObject private var outsideClick = OutsideClickMonitor()
    /// Clears drag state on a no-move drag press's mouse-up (see `LeftMouseUpMonitor`).
    @StateObject private var mouseUp = LeftMouseUpMonitor()
    /// Moves the task list's highlight onto a right-clicked row (see `RightMouseDownMonitor`).
    @StateObject private var rightClick = RightMouseDownMonitor()
    @StateObject private var dragEnd = DragEndWatcher()
    /// The task row the pointer is over, for that same right-click. Not `@State` — see `RowHoverTracker`.
    @State private var rowHover = RowHoverTracker()
    /// Where an open add editor will put its next task, relative to the row it's anchored on.
    ///
    /// Window state, not row state. It used to live on `TaskRow`, which was fine while an add editor
    /// was a single shot on one row and wrong the moment it stopped being one: a continuous add walks
    /// the editor down the list, and a position stored on the row it started from doesn't travel with
    /// it — every task after the first would take the *new* row's default instead.
    @State private var addPosition: TaskInsertPosition = .child
    /// The content column's measured width, and the one place it's held. Every piece of the column that
    /// wears `ReadableWidth` reads it out of the environment to size its gutters, so they open and close
    /// together instead of each measuring itself. Seeded at zero — no gutter — because that's the safe
    /// direction for the frame before the first measurement lands: the margins only ever open up.
    @State private var columnWidth: CGFloat = 0
    /// Whether the pointer is anywhere in the header strip. With the window's active state below, this
    /// is the whole input to `HeaderChrome` — the header's glass reveals itself on either.
    @State private var headerHovering = false
    /// Whether this window is the active one. The other half of the same decision.
    @Environment(\.controlActiveState) private var controlActiveState

    /// The width cap the header and the task list share. They have to be the same one — the header's
    /// trailing capsule and the rows' right edges line up against each other, and two caps would put
    /// them in different places in a wide window.
    private static var listWidth: ReadableWidth { ReadableWidth(cap: ProjectWindow.maxListWidth) }

    /// The x (in `TaskDropResolver.coordinateSpace`) where a depth-0 row's content begins — matches the rows' leading
    /// padding. The insertion indicator and the pointer→depth mapping both key off it.
    static let rowContentInset: CGFloat = 12
    /// Horizontal pixels per nesting level (matches `TaskRow.indent`'s step).
    static let indentStep: CGFloat = 16
    /// A session heading's own breathing room, the same above and below. It's inside the heading's
    /// selection band, so an uneven pair would draw a highlight sitting off-centre on its own text —
    /// which is what the separation between sessions used to be made of.
    static let sessionHeadingPadding: CGFloat = 4
    /// The separation between one session and the session before it. Applied *outside* the heading's
    /// band, so it reads as a gap between two blocks rather than as padding belonging to one of them,
    /// and the heading stays visibly closer to its own tasks than to the session above.
    static let sessionGap: CGFloat = 8
    /// The unanchored add editor's identity. Its own kind, so its key can't collide with a task row's
    /// `"session:line"` or a session's `"sess:<index>"`.
    static let quickAddTarget = EditorTarget(key: "quick", kind: .quickAdd)
    /// A session row's key. The `"sess:"` prefix is what keeps it apart from a task's `"session:line"`,
    /// so one selection set can hold both kinds of row.
    static func sessionKey(_ index: Int) -> String { "sess:\(index)" }
    /// The session index behind a row key — nil when the key names a task.
    static func sessionIndex(fromRowKey key: String) -> Int? {
        guard key.hasPrefix("sess:") else { return nil }
        return Int(key.dropFirst("sess:".count))
    }
    /// The one animation used for showing/hiding the details brief. A single shared value, applied by
    /// every subview that moves on the toggle (keyed on `detailsExpanded`), so the details content, the
    /// divider, the "Tasks" heading, and the regrouped rows all settle on the same clock rather than at
    /// different rates.
    static let detailsMotion: Animation = .snappy

    /// Show or hide the details brief: one transaction that every subview moving with it rides, plus
    /// the write-through that keeps other windows and the View menu's checkmark in step. The guard is
    /// what stops the mirror and the stored value chasing each other when the change arrives from
    /// outside.
    private func setDetails(_ expanded: Bool) {
        guard detailsExpanded != expanded else { return }
        // Session headers are rows only while notes are showing (see `rowKeys`), so a selected one
        // doesn't survive the collapse — left behind, it would keep ⌘N and Return pointing at a row
        // that isn't on screen.
        if !expanded {
            selection = selection.filter { Self.sessionIndex(fromRowKey: $0) == nil }
            if let anchor = selectionAnchor, Self.sessionIndex(fromRowKey: anchor) != nil {
                selectionAnchor = nil
            }
        }
        withAnimation(Self.detailsMotion) { detailsExpanded = expanded }
        if storedDetailsExpanded != expanded { storedDetailsExpanded = expanded }
    }

    /// True whenever some inline editor (a task row's, or the project-details form) is open.
    private var isAnyEditorActive: Bool { activeEditor != nil || editingDetails }

    private var visibleTodos: [Todo] {
        let byMode = tasksMode == .all ? store.todos : store.todos.filter { !$0.checked }
        guard let query = findQuery.trimmed?.lowercased() else { return byMode }
        // Matches the task's own text only — not its ancestors'. Filtering by a parent would pull in
        // every child of a matching task and read as "3 matches" over a dozen visible rows.
        return byMode.filter { $0.text.lowercased().contains(query) }
    }

    /// Whether a search is narrowing the list right now — as opposed to the bar merely being open with
    /// nothing typed, which shouldn't change what's shown or claim there are no results.
    private var isFiltering: Bool { findVisible && findQuery.trimmed != nil }

    /// Every selectable row's key, in the order they're drawn — what the arrow keys walk, what a
    /// ⇧-click ranges over, and what a selection is checked against when the document reloads.
    ///
    /// In notes mode a session header is a row in its own right. That's what makes an empty session
    /// reachable at all — there's nothing inside it to click — and what lets ⌘N and Return act on the
    /// session you're looking at, which is why neither needs a button sitting in the list. In the
    /// compact list it isn't a row: there the caption is a quiet separator between groups of tasks, and
    /// stopping on one every few presses would only lengthen the walk from one task to the next.
    private var rowKeys: [String] {
        guard detailsExpanded else { return visibleTodos.map(PMStore.key(for:)) }
        let sessions = store.notes?.sessions.count ?? 0
        return (0..<sessions).flatMap { si in
            [Self.sessionKey(si)] + visibleTodos.filter { $0.sessionIndex == si }.map(PMStore.key(for:))
        }
    }

    /// The session a command should act on: the one whose header is selected, on its own. Nil whenever
    /// the selection is a task, or spans more than one row.
    private var selectedSessionIndex: Int? {
        guard selection.count == 1, let key = selection.first else { return nil }
        return Self.sessionIndex(fromRowKey: key)
    }

    /// The visible tasks paired with the identity their rows are diffed on.
    ///
    /// Identity is the raw line *plus an occurrence number*. The raw line is what survives a reindex:
    /// adding or deleting a task shifts every `"session:line"` key below it, so identifying rows by
    /// key would make the whole tail read as new rows (they'd cross-fade instead of sliding). But a
    /// raw line isn't unique on its own — two identical task lines in one session ("- [ ] Follow up"
    /// twice) collide, and SwiftUI's diffing misbehaves on duplicate ids: rows flicker, and the wrong
    /// one animates out. Counting occurrences keeps the stability and makes the ids unique.
    private var identifiedTodos: [IdentifiedTodo] {
        var seen: [String: Int] = [:]
        return visibleTodos.map { todo in
            let n = seen[todo.rawLine, default: 0]
            seen[todo.rawLine] = n + 1
            return IdentifiedTodo(id: "\(todo.rawLine)#\(n)", todo: todo)
        }
    }

    var body: some View {
        mainColumn
            // Fill the pane. The readable-width cap that used to sit here now rides the column's
            // *contents* instead — see `ReadableWidth`. The sidebar is not laid out here; it's the
            // other half of the window's split view.
            .frame(minWidth: ProjectWindow.minContentWidth, maxWidth: .infinity, alignment: .leading)
            // Measure the column once, here, and hand the number down. `ReadableWidth` needs it to
            // decide how much margin the pane can spare, and it's worn by the header, the rows, the
            // details brief and the note editor — each reading its own geometry would be four
            // `GeometryReader`s answering the same question, and inside a scroll view a
            // `GeometryReader` also takes all the space it's offered.
            //
            // No animation on the write. The gutter ramps with width rather than switching at a
            // threshold, so a live resize is already smooth, and animating a value that changes every
            // frame of a window drag only makes the margins lag behind the edge being dragged.
            .background(GeometryReader { geo in
                Color.clear.preference(key: ColumnWidthKey.self, value: geo.size.width)
            })
            .onPreferenceChange(ColumnWidthKey.self) { columnWidth = $0 }
            .environment(\.pmColumnWidth, columnWidth)
            // Pin the appearance when the user overrides it; `.system` (nil) follows the OS.
            .preferredColorScheme(colorMode.colorScheme)
            // No background of its own: the window's is the right one.
            //
            // This column used to paint `.behindWindow` vibrancy across itself — correct back when the
            // whole app *was* a floating panel, and left behind when it became a window. A content pane
            // beside a source list is opaque on every Mac: the sidebar is the vibrant surface (the split
            // view's sidebar item supplies that material itself), and the contrast between the two is
            // what makes a source list read as one. Two vibrant panes read as a HUD.
            //
            // Run the content up under the (hidden, transparent) titlebar rather than sitting below it.
            // Left inset, the window opens with a bare strip along its top that reads as a titlebar that
            // failed to draw; the header belongs *in* that strip, level with the traffic lights. Content
            // under a transparent titlebar is hit-testable — only the traffic lights claim their own
            // points — so the header's controls still work up there.
            .ignoresSafeArea(.container, edges: .top)
    }

    /// The window content column — everything that isn't the sidebar.
    private var mainColumn: some View {
        Group {
            if let takeover = sessionNoteTakeover {
                // Editing a session note takes over the whole column for a focused, richer experience;
                // it enters with a navigation-style push (list slides left, editor in from the right).
                // It has its own header, so it stands outside the sticky-header split.
                SessionNoteTakeover(
                    index: takeover.index,
                    session: takeover.session,
                    projectName: store.notes?.title.trimmed ?? store.projectName ?? "",
                    store: store,
                    state: state,
                    onBack: { activeEditor = nil }
                )
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .trailing).combined(with: .opacity)))
            } else {
                // The reader lets arrow-key navigation reveal a row that's scrolled out of view —
                // each row carries its key as a scroll id (see `TaskRow.scrollMarker`).
                ScrollViewReader { proxy in
                    ScrollView {
                        scrollBody
                            .modifier(Self.listWidth)
                            // The same margin the sides get, at the foot of the list, so the last task
                            // can clear the window's bottom edge rather than ending flush against it.
                            .padding(.bottom, ReadableWidth.gutter(for: columnWidth))
                    }
                    // Double-clicking blank space adds a task to the current session (starting one
                    // when there isn't one to continue) — a Finder window's "act on the container, not
                    // on an item" double-click.
                    //
                    // Attached to the scroll view itself rather than to a filler view stretched over
                    // the leftover space, which would have to be sized from the viewport height minus
                    // the content's. Everything that wants a double-click of its own — the rows, the
                    // session captions, the details brief — carries one, and an inner gesture wins, so
                    // what reaches this is exactly what nothing else claimed.
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { beginQuickAdd() }
                    // The header (title + controls) stays pinned in the titlebar strip while the tasks
                    // scroll *under* it.
                    //
                    // A safe-area inset rather than a `VStack` sibling above the scroll view. Stacked,
                    // the scroll view began below the header, so its content stopped dead at the header's
                    // lower edge — nothing ever passed beneath it, the scroll edge effect had no work to
                    // do, and the titlebar strip over this column stayed flat on macOS 26 while the
                    // sidebar beside it (full-height, inset by AppKit) had the effect all along. Inset,
                    // the scroll view owns that strip and the system draws the effect across it. The
                    // inset reserves the header's height either way, so nothing moves at rest.
                    //
                    // No material on the inset itself any more — the header is floating glass and the
                    // strip behind it is open window, so what keeps the rows readable as they pass
                    // under it is the soft scroll edge below. `stickyHeader` still backs its own
                    // find/delete strips, and applies the width cap per text row: with the cap outside,
                    // dragging the window past `maxListWidth` left those bars stopping short of the
                    // window's edge.
                    .safeAreaInset(edge: .top, spacing: 0) {
                        stickyHeader
                    }
                    // Soften the scroll edges (macOS 26+): content fades as it passes under the pinned
                    // header and off the window's bottom edge, the idiomatic replacement for a hard clip.
                    .modifier(SoftScrollEdges())
                    .onChange(of: scrollTarget) { target in
                        guard let target else { return }
                        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(target.key) }
                    }
                }
                .transition(.asymmetric(
                    insertion: .move(edge: .leading).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)))
            }
        }
        // No `.animation(detailsMotion, value: detailsExpanded)` here any more. That modifier existed
        // because the flag was `@AppStorage` and its change landed outside any transaction; now that
        // `setDetails` owns the write, one `withAnimation` there covers every subview the change
        // touches, which is what the container modifier was approximating.
        .animation(.snappy, value: tasksMode)
        .animation(.snappy, value: sessionNoteTakeover != nil)
        // No `.clipped()` here. The push transitions do need containing — the outgoing view slides out
        // of the pane and would draw over the sidebar — but a SwiftUI clip modifier wraps this whole
        // column, scrolling task list included, in a clip layer it only needs for the fraction of a
        // second a takeover is entering or leaving. That's the same permanent-clip-around-a-scrolling-
        // list cost `ProjectSidebar` takes pains to avoid.
        //
        // The containing happens at the pane boundary instead, where it belongs and costs nothing:
        // `ProjectSplitViewController` sets `masksToBounds` on the hosting view, which is layer-backed
        // already.
        .onPreferenceChange(ActiveEditorFrameKey.self) { outsideClick.editorFrame = $0 }
        .background(WindowAccessor { outsideClick.window = $0 })
        .onExitCommand(perform: handleEscape)
        // File ▸ New Task. The menu can't reach into the view, so the window bumps a counter and the
        // add editor opens wherever it makes sense: the first-task CTA in an empty project, else an
        // "after" editor on the hero task.
        .onChange(of: state.newTaskRequest) { _ in beginNewTask() }
        // Edit ▸ Find ▸ Find… — same counter trick as New Task, for the same reason.
        .onChange(of: state.findRequest) { _ in beginFind() }
        // The rest of the Find submenu, on the same pattern.
        .onChange(of: state.findStepRequest) { _ in stepFind(by: state.findStepDirection) }
        .onChange(of: state.useSelectionForFindRequest) { _ in useSelectionForFind() }
        // Publish "a search is narrowing the list" up to the window, which is what validates Find Next
        // and Find Previous — see `ProjectViewState.findIsFiltering`.
        .onChange(of: isFiltering) { state.findIsFiltering = $0 }
        // ⌘Z / ⇧⌘Z undo & redo the window edits (move, complete, due, text, add, wrap…). Hidden
        // zero-size buttons carry the shortcuts so they work whenever the window is key.
        .background(keyboardShortcuts)
        .onChange(of: store.projectName) { _ in
            editingDetails = false
            addingFirstTask = false
            // A different project's tasks are behind the same keys, so nothing selected survives.
            selection = []
            selectionAnchor = nil
            pendingDelete = []
        }
        // A completed move (or any reload) reindexes the todos, so drop the now-stale drag state, and
        // drop any selected key that no longer names a row (completing a task hides it in Incomplete
        // mode; a move or delete can retire the tail of the index range).
        .onChange(of: store.todos) { _ in
            draggingKey = nil
            dropTarget = nil
            let live = Set(rowKeys)
            if !selection.isSubset(of: live) { selection.formIntersection(live) }
        }
        // Adding/deleting a session shifts session indices, so close any open session editor when the
        // count changes (a keyed editor would otherwise point at the wrong session) — unless this
        // window is the one that added it and is on its way into it. See `beginCurrentSession`.
        .onChange(of: store.notes?.sessions.count) { _ in
            if sessionCountChangeIsOurs {
                sessionCountChangeIsOurs = false
            } else {
                activeEditor = nil
            }
        }
        // File ▸ New Session, on the same counter as New Task and for the same reason.
        .onChange(of: state.newSessionRequest) { _ in beginCurrentSession() }
        .onChange(of: state.editDetailsRequest) { _ in beginEditDetails() }
        // Arm the drag-end backstop for the life of a drag. See `DragEndWatcher` for why the two
        // existing end signals don't between them cover a real drag.
        .onChange(of: draggingKey) { key in
            if key != nil {
                dragEnd.arm { draggingKey = nil; dropTarget = nil }
            } else {
                dragEnd.disarm()
            }
        }
        // Collapsing details (from the menu) also leaves any details-edit form.
        .onChange(of: detailsExpanded) { expanded in if !expanded { editingDetails = false } }
        // Follow the flag when it's changed from outside this view — the View menu writes the key
        // directly, and another window's toggle republishes it here.
        .onChange(of: storedDetailsExpanded) { setDetails($0) }
        // Start/stop the outside-click monitor with edit mode; an outside click cancels any editor.
        .onChange(of: isAnyEditorActive) { active in
            if active {
                // Hand focus off before the editor asks for it. The task list is `.focusable()` and
                // its `.focused($tasksFocused)` binding is still true at this point, so leaving it set
                // means the list re-asserts focus in the same update the field is requesting it — a
                // race the field loses often enough that add editors opened up without a caret.
                tasksFocused = false
                outsideClick.onOutsideClick = {
                    activeEditor = nil
                    editingDetails = false
                }
                outsideClick.start()
            } else {
                outsideClick.stop()
                // Hand keyboard focus back to the list when a field gives it up, so ↑/↓ keep working
                // after an edit without needing a click first.
                focusTasks()
            }
        }
        .onAppear {
            // Seed the mirror from the persisted value, unanimated — a window opening with the brief
            // showing should already show it, not play the reveal.
            detailsExpanded = storedDetailsExpanded
            modifiers.start()
            mouseUp.onMouseUp = { if draggingKey != nil { draggingKey = nil; dropTarget = nil } }
            mouseUp.start()
            rightClick.onRightMouseDown = {
                if let key = rowHover.key { selectForContextMenu(key) }
            }
            rightClick.start()
            // Arrow keys should work on a freshly-opened window without a click to arm them. Deferred
            // because taking focus from inside `onAppear` re-enters the update that is placing the view.
            afterCurrentUpdate { focusTasks() }
        }
        .onDisappear {
            modifiers.stop(); outsideClick.stop(); mouseUp.stop(); rightClick.stop()
            dragEnd.disarm()
            // The window outlives this pane on a retarget, and a stale "there are matches" would leave
            // Find Next enabled over a list that isn't filtered any more.
            state.findIsFiltering = false
        }
    }

    /// Invisible buttons that register the window keyboard shortcuts. `.hidden()` keeps them out of the
    /// layout and hit-testing while still binding the shortcut on the key window; the undo/redo pair is
    /// disabled when there's nothing to (un/re)do, so the shortcut no-ops (system beep) rather than firing.
    ///
    /// **Every one of these stands down while a text editor holds the keyboard** (`isEditingText`), and
    /// that is not belt-and-braces — it is the only thing keeping ⌘A, ⌘C, ⌘Z and ⌘⌫ out of the field
    /// you are typing in. A SwiftUI `.keyboardShortcut` is offered the keystroke through the key
    /// *window*'s `performKeyEquivalent`, which AppKit runs **before** the main menu — so an enabled
    /// button here beats Edit ▸ Select All to it and the field editor never sees the key at all. That
    /// is what this comment used to claim happened the other way round, and the symptom was ⌘A in a
    /// task field selecting every project in the sidebar instead of the text in front of you.
    /// Disabled, the button declines the keystroke, the main menu gets its turn, and `selectAll:` and
    /// friends route to the field editor the way `MainMenu` intends.
    private var keyboardShortcuts: some View {
        // Suppressed while the note editor is up, so ⌘Z / ⇧⌘Z reach the NSTextView's own (per-keystroke)
        // undo instead of the document-level history. `isEditingText` covers the same ground while the
        // editor actually has the keyboard; this also covers a note editor up but not focused.
        let inNoteEditor = sessionNoteTakeover != nil
        // Any text editor in this window, tracked from the real first responder — see
        // `ProjectViewState.isEditingText`. Every field in both panes is covered by that one read,
        // including the ones the view has no flag for (the find bar, the details form's fields).
        let isEditingText = state.isEditingText
        let contentCommandsStandDown = inNoteEditor || isEditingText
        return Group {
            Button("Undo", action: store.undo)
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!store.canUndo || contentCommandsStandDown)
            Button("Redo", action: store.redo)
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!store.canRedo || contentCommandsStandDown)
            Button("Copy", action: copySelection)
                .keyboardShortcut("c", modifiers: .command)
                .disabled(contentCommandsStandDown || !canCopySelection)
            // ⌘V lands text as tasks — see `pasteTasks`. Stands down with the rest while a field has
            // the keyboard, where ⌘V means paste into the text you're typing.
            Button("Paste", action: pasteTasks)
                .keyboardShortcut("v", modifiers: .command)
                .disabled(contentCommandsStandDown || !canPasteTasks)
            Button("Select All", action: selectAllInFocusedPane)
                .keyboardShortcut("a", modifiers: .command)
                .disabled(contentCommandsStandDown)
            // ⌘⌫ is the Finder delete; plain ⌫ is handled by the list's `onDeleteCommand`, which only
            // fires while the list itself (rather than a text field) holds focus. In a field ⌘⌫ is
            // "delete to the start of the line", which is why this stands down with the rest.
            Button("Delete") { requestDelete(actionTargets) }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(contentCommandsStandDown || actionTargets.isEmpty)
            // Return activates the selected row, whichever pane holds focus — a list's "open". ⌘Return
            // is the Finder's pairing for the sidebar, opening the project in a new window.
            Button("Open") { activateSelection() }
                .keyboardShortcut(.return, modifiers: [])
                .disabled(!canActivateSelection)
            Button("Open Project in New Window") { activateSelectedProject(inNewWindow: true) }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!canActivateSelectedProject)
        }
        .hidden()
    }

    /// Return: activate whatever's selected in the pane with keyboard focus.
    ///
    /// - a project — switch to it if the window isn't on it already (a click would have; arrowing to it
    ///   and hitting Return before the walk settles wouldn't), then hand focus to the tasks. That last
    ///   part is Return's real job now that selecting a project is what switches to it: it's how you
    ///   stop browsing and start working, the same move as Mail's Return out of the mailbox list.
    /// - a session — open its note, the same act as its double-click.
    /// - a task — make it the focused one, the same act as its double-click.
    private func activateSelection() {
        if state.focusedPane == .projects {
            if let key = state.projectSelection.first, key != store.projectKey {
                state.openProject(key, false)
            }
            focusTasks()
        } else if let si = selectedSessionIndex {
            openSessionNote(si)
        } else if actionTargets.count == 1, let todo = actionTargets.first {
            store.focus(todo)
        }
    }

    /// Whether Return has a row to open. Nothing doing while a form is up: Return belongs to the field
    /// being typed in, to the details editor, to the find bar, and to the delete confirmation's default
    /// button — a hidden key equivalent that fired anyway would take it from all four.
    private var canActivateSelection: Bool {
        guard activeEditor == nil, !editingDetails, !addingFirstTask,
              !findVisible, !state.isEditingText, pendingDelete.isEmpty else { return false }
        return state.focusedPane == .projects ? state.projectSelection.count == 1 : selection.count == 1
    }

    private func activateSelectedProject(inNewWindow: Bool) {
        guard let key = state.projectSelection.first else { return }
        guard inNewWindow || key != store.projectKey else { return }
        state.openProject(key, inNewWindow)
    }

    private var canActivateSelectedProject: Bool {
        state.focusedPane == .projects && state.projectSelection.count == 1
            && !state.isEditingText && pendingDelete.isEmpty
    }

    // MARK: Selection

    /// The tasks a command applies to: the selected rows.
    private var actionTargets: [Todo] {
        visibleTodos.filter { selection.contains(PMStore.key(for: $0)) }
    }

    /// Open the inline add editor — File ▸ New Task, and the empty state's button. The new task lands
    /// after the selected row, else after the focused task, so ⌘N in a long list adds where you're
    /// looking rather than at the bottom. With nothing to anchor on — an empty project, or one whose
    /// tasks are all complete and hidden — it falls through to the unanchored quick add.
    private func beginNewTask() {
        guard store.projectName != nil else { return }
        // A selected session header anchors the add on the session itself, appending to it. That's how
        // a task gets into a session with nothing in it yet, now that no button offers to.
        if let si = selectedSessionIndex {
            activeEditor = EditorTarget(key: Self.sessionKey(si), kind: .sessionAddTask,
                                        session: store.sessionRef(at: si))
        } else if let anchor = actionTargets.first ?? store.focusedTodo ?? store.openTodos.first {
            // Explicitly *after*, which is what the paragraph above has always claimed. The position
            // used to come from whatever the anchor row's own state happened to hold, and that state
            // defaulted to `.child` — so ⌘N on a selected task quietly made a subtask of it.
            addPosition = .after
            activeEditor = EditorTarget(key: PMStore.key(for: anchor), kind: .add)
        } else {
            beginQuickAdd()
        }
    }

    /// Open the unanchored add editor: the new task goes to the current session, which `PMStore.addTodo`
    /// starts when there isn't one to continue. This is what a double-click in the window's blank
    /// space opens, and where ⌘N lands when there's no row to add after.
    ///
    /// When the empty-project CTA is on screen it carries an add editor of its own, so this reveals
    /// that one rather than opening a second editor underneath it.
    private func beginQuickAdd() {
        guard store.projectName != nil, !editingDetails, sessionNoteTakeover == nil else { return }
        if showsEmptyProjectCTA {
            addingFirstTask = true
        } else {
            activeEditor = Self.quickAddTarget
        }
    }

    /// Commit one task from a row's add editor, then leave the editor open one slot further down so a
    /// list can be typed straight through — Return, Return, Return — and Escape ends it.
    ///
    /// The editor has to *move*, not merely stay open. `insertTaskRelative` puts an `.after` or
    /// `.child` task immediately below its anchor, so a second task committed against the same anchor
    /// lands above the first and a list typed in order comes out backwards. Advancing the anchor to the
    /// task just written is what keeps typed order and document order the same thing.
    ///
    /// One key covers all three positions. `.before` inserts at the anchor's index and pushes the
    /// anchor down to `line + 1`; `.after` and `.child` insert at `line + 1` themselves. So the next
    /// anchor is `line + 1` either way — it just means "the row I should insert before" in one case and
    /// "the row I just made" in the other. A `.child` chain continues as `.after`, because the sibling
    /// of the subtask you just made is the next thing you meant, not a grandchild.
    ///
    /// The key is computed rather than read back from the store: the write is asynchronous, so there's
    /// nothing to read yet. Until the reload lands this points at whatever row currently holds that
    /// slot, which is the row directly below the anchor — the same place on screen the editor is
    /// already sitting.
    private func commitAdd(text: String, due: String?, anchor: Todo) {
        store.addTodo(text: text, due: due, relativeTo: anchor, position: addPosition)
        let nextKey = "\(anchor.sessionIndex):\(anchor.lineIndex + 1)"
        if addPosition != .before { addPosition = .after }
        activeEditor = EditorTarget(key: nextKey, kind: .add)
        // The list grows above the editor, so without this the thing you're typing into walks off the
        // bottom of the window somewhere around the fourth task.
        scrollToken &+= 1
        scrollTarget = ScrollRequest(key: nextKey, token: scrollToken)
    }

    /// File ▸ New Session (⇧⌘N), and what the old "New session" button becomes.
    ///
    /// It means the *current* session: the one the project is already in, or a new one when it hasn't
    /// got one for today or has been left alone long enough that this is a new sitting — see
    /// `PMStore.openCurrentSession`. Either way it lands in the note editor with the caret ready,
    /// because a session you just asked for is one you're about to write in; dropping an empty heading
    /// into the list and leaving you to find your way into it was the long way round to the same place.
    private func beginCurrentSession() {
        guard store.projectName != nil, !editingDetails else { return }
        // Adding a session shifts every session index, which normally closes an open session editor
        // (see the `sessions.count` watcher below). This is the one change that's *opening* one, so
        // it's exempt — claimed here, before the write, so it doesn't matter which side of the
        // reload the watcher fires on.
        //
        // Claimed on a prediction, and the prediction can be wrong: the idle window is measured
        // against the file's date, which the contract re-reads for itself a moment later. So the claim
        // is taken back below if no session turned up after all, rather than left armed to swallow
        // somebody else's change later on.
        let before = store.notes?.sessions.count
        if store.willStartNewSession { sessionCountChangeIsOurs = true }
        store.openCurrentSession { index in
            if store.notes?.sessions.count == before { sessionCountChangeIsOurs = false }
            openSessionNote(index)
        }
    }

    /// Open the project's details brief for editing, revealing it first if it was collapsed — the form
    /// lives inside the brief, so asking to edit it while it's hidden would otherwise be a no-op.
    private func beginEditDetails() {
        guard store.projectName != nil else { return }
        activeEditor = nil
        setDetails(true)
        editingDetails = true
    }

    /// Put keyboard focus on the task list: the real focus (so arrow keys land there and the selection
    /// draws emphasized) plus the shared routing value the sidebar reads across the split.
    private func focusTasks() {
        tasksFocused = true
        state.focusedPane = .tasks
    }

    /// Whether ⌘C has something to put on the pasteboard — tasks, or projects when the sidebar has
    /// keyboard focus.
    private var canCopySelection: Bool {
        state.focusedPane == .projects ? !state.projectSelection.isEmpty : !actionTargets.isEmpty
    }

    private func copySelection() {
        if state.focusedPane == .projects {
            copySelectedProjects()
        } else {
            TaskPasteboard.copy(markdown: store.markdown(for: actionTargets))
        }
    }

    /// Whether ⌘V has anything to put in the list. Reads the pasteboard rather than guessing, so the
    /// command is dim for a copied image and live for a copied paragraph.
    private var canPasteTasks: Bool {
        state.focusedPane == .tasks && store.projectName != nil
            && NSPasteboard.general.canReadObject(forClasses: [NSString.self], options: nil)
    }

    /// ⌘V. Land whatever text is on the pasteboard as tasks, after the selected row's subtree — or at
    /// the end of the current session when nothing's selected.
    ///
    /// The selection moves to what was pasted, the way every Mac list leaves a paste selected: it's
    /// what you'd act on next, and it's the only confirmation that the thing arrived where you meant.
    private func pasteTasks() {
        let block = TaskPasteboard.tasksOnPasteboard()
        guard !block.isEmpty else { NSSound.beep(); return }
        let anchor = actionTargets.count == 1 ? actionTargets.first : nil
        let before = Set(rowKeys)
        store.pasteTasks(block, after: anchor) {
            // After the reload, so the keys name rows that exist. Whatever's new is what landed.
            let arrived = rowKeys.filter { !before.contains($0) }
            guard !arrived.isEmpty else { return }
            selection = Set(arrived)
            selectionAnchor = arrived.first
            if let first = arrived.first {
                scrollToken &+= 1
                scrollTarget = ScrollRequest(key: first, token: scrollToken)
            }
        }
    }

    private func selectAllInFocusedPane() {
        if state.focusedPane == .projects {
            state.projectSelection = Set(store.allProjects.map(\.projectKey))
        } else {
            selection = Set(rowKeys)
            selectionAnchor = rowKeys.first
        }
    }

    /// Click behaviour for a row — a task's or a session header's, which select alike. The standard
    /// Mac list: a plain click selects just that row, ⇧ extends the range from the anchor, ⌘ toggles
    /// the row in and out of the selection. (Activating a row — focusing a task, opening a session's
    /// note — is the double-click, see `TaskRow` and `SessionHeader`.)
    private func selectRow(_ key: String, modifiers: NSEvent.ModifierFlags) {
        focusTasks()
        if modifiers.contains(.shift), let anchor = selectionAnchor {
            selection = keysInRange(from: anchor, to: key)
        } else if modifiers.contains(.command) {
            if selection.contains(key) { selection.remove(key) } else { selection.insert(key) }
            selectionAnchor = key
        } else {
            selection = [key]
            selectionAnchor = key
        }
    }

    /// The rows a row's context menu acts on: the whole selection when the click lands inside it, just
    /// the clicked row when it doesn't (Finder's rule).
    ///
    /// Pure, and it has to stay that way. SwiftUI builds a `.contextMenu`'s content while it builds the
    /// row — not when the menu opens — so this runs for every visible row on every body pass. It used
    /// to move the highlight onto the clicked row from here via `DispatchQueue.main.async`, which meant
    /// each *unselected* row queued a "select me" on every pass; the queued write rebuilt the list, the
    /// rebuild queued them all again, and the list never settled. (The sidebar avoids the whole
    /// problem by using `contextMenu(forSelectionType:)`, which hands the menu its targets; there's no
    /// equivalent for a hand-built list.) The highlight is moved by `TaskListRightClickMonitor`
    /// instead, off a real right-click event, which agrees with what this returns for the same row.
    private func contextTargets(for todo: Todo) -> [Todo] {
        selection.contains(PMStore.key(for: todo)) ? actionTargets : [todo]
    }

    /// Move the highlight onto a right-clicked row that isn't part of the current selection. Driven by
    /// an actual `rightMouseDown`, so it runs once per click rather than once per row per render.
    private func selectForContextMenu(_ key: String) {
        guard !selection.contains(key) else { return }
        selection = [key]
        selectionAnchor = key
        focusTasks()
    }

    /// Every visible row's key between two rows inclusive, in visible order.
    private func keysInRange(from anchor: String, to key: String) -> Set<String> {
        let keys = rowKeys
        guard let i = keys.firstIndex(of: anchor), let j = keys.firstIndex(of: key) else { return [key] }
        return Set(keys[min(i, j)...max(i, j)])
    }

    /// ↑/↓ move the selection one row; holding ⇧ extends it from the anchor instead. With nothing
    /// selected, ↓ starts at the top and ↑ at the bottom. Left/right are left alone — depth in this
    /// outline is a drag, not a keystroke.
    ///
    /// `onMoveCommand` doesn't report modifiers, so ⇧ is read from the current event state; that read
    /// happens while the keystroke is being handled, so it reflects the key that caused it.
    private func moveSelection(_ direction: MoveCommandDirection) {
        let keys = rowKeys
        guard !keys.isEmpty else { return }
        let step: Int
        switch direction {
        case .up: step = -1
        case .down: step = 1
        default: return
        }
        let selected = keys.indices.filter { selection.contains(keys[$0]) }
        let from = step < 0 ? (selected.first ?? keys.count) : (selected.last ?? -1)
        let key = keys[min(max(from + step, 0), keys.count - 1)]
        if NSEvent.modifierFlags.contains(.shift) {
            let anchor = selectionAnchor ?? key
            selection = keysInRange(from: anchor, to: key)
            selectionAnchor = anchor
        } else {
            selection = [key]
            selectionAnchor = key
        }
        scrollToken &+= 1
        scrollTarget = ScrollRequest(key: key, token: scrollToken)
        focusTasks()
    }

    // MARK: Delete

    /// Ask to delete `todos`, surfacing the confirmation. Confirmation earns its place even though ⌘Z
    /// reverses a delete: the subtasks that ride along are the part you can't see from the row you
    /// picked, and the prompt is where they get named.
    private func requestDelete(_ todos: [Todo]) {
        guard !todos.isEmpty, store.projectName != nil else { return }
        activeEditor = nil
        pendingDelete = todos
    }

    private func confirmDelete() {
        store.deleteTasks(pendingDelete)
        pendingDelete = []
        // Selection keys are document positions: after a delete the surviving ones name different
        // tasks, so the honest move is to start clean rather than silently reselect the neighbours.
        selection = []
        selectionAnchor = nil
    }

    /// The inline delete confirmation, pinned under the header so it can't scroll out of reach.
    ///
    /// Inline rather than an alert or a sheet: this is a confirmation, not an interruption. It names
    /// what's about to go (the subtasks riding along are the part you can't see from the rows you
    /// picked) without blocking the rest of the window, so you can still look at the list you're about
    /// to cut into. Return deletes, Escape cancels.
    @ViewBuilder private var deleteConfirmation: some View {
        if !pendingDelete.isEmpty {
            let summary = store.deletionSummary(pendingDelete)
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(deletePrompt(summary))
                        .font(.callout.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    if summary.descendants > 0 {
                        Text("Also deletes \(count(summary.descendants, "subtask")).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    Button("Cancel") { pendingDelete = [] }
                        .keyboardShortcut(.cancelAction)
                    Button("Delete", role: .destructive, action: confirmDelete)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .controlSize(.small)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.06))
            Divider()
        }
    }

    /// "Delete “Ship the thing”?" for one task, "Delete 4 tasks?" for a set — the same shape a Mac
    /// alert would use, naming the single case and counting the plural one.
    private func deletePrompt(_ summary: (tasks: Int, descendants: Int)) -> String {
        if summary.tasks == 1, let only = store.outermost(pendingDelete).first {
            return "Delete “\(only.text.truncated(60))”?"
        }
        return "Delete \(count(summary.tasks, "task"))?"
    }

    private func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }

    /// A due date set from a row's editor lands on the whole selection when that row is part of one —
    /// the same rule the context menu follows, so the two can't disagree.
    private func applyDue(_ due: String?, from todo: Todo) {
        let targets = selection.contains(PMStore.key(for: todo)) && selection.count > 1
            ? actionTargets : [todo]
        if targets.count > 1 {
            store.setDueAll(targets, due: due)
        } else {
            store.setDue(todo, due: due)
        }
    }

    // MARK: Project pane

    /// Copy the selected projects as their folder names, one per line — the identifier the CLI, the
    /// Raycast commands and the Finder all use for a project.
    private func copySelectedProjects() {
        let names = store.allProjects
            .filter { state.projectSelection.contains($0.projectKey) }
            .map(\.name)
        guard !names.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(names.joined(separator: "\n"), forType: .string)
    }

    /// The pinned header — the project's floating chrome, and below it the strips that occasionally
    /// stand under it. Stays fixed above the scroll area; swapped out entirely for the note takeover.
    ///
    /// Two layers, because they're two different kinds of thing. The header itself is chrome that
    /// floats: a pill and a capsule of glass with bare window between them, and the task rows fading
    /// out from under it via the scroll view's soft top edge. The find bar and the delete confirmation
    /// are strips — full-width bands of controls — so they keep a real material behind them and a rule
    /// under them. Nothing is drawn for them when they're absent: an empty stack is zero-height, so its
    /// material is too.
    ///
    /// The readable-width cap sits on each text row rather than around the stack, and the material is
    /// left out of it deliberately: text belongs at the same width as the rows it heads, while a bar
    /// belongs to the window and runs the full width of the pane. Capping the stack capped the chrome
    /// with it, leaving a rule that stopped short of a bar that didn't.
    private var stickyHeader: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.modifier(Self.listWidth)
            VStack(alignment: .leading, spacing: 0) {
                findBar.modifier(Self.listWidth)
                if findVisible { Divider() }
                deleteConfirmation.modifier(Self.listWidth)
                // Above the list rather than over it: a refused batch is about the selection, and the
                // selection is in the rows right below this line.
                WriteFailureBanner(failure: store.writeFailure).modifier(Self.listWidth)
            }
            .background(TitlebarMaterial())
        }
        .animation(.snappy, value: pendingDelete.isEmpty)
        .animation(.snappy, value: findVisible)
    }

    /// The find bar: a real search field and a match count, in a strip below the header.
    ///
    /// Below the header rather than inside it, because that's where a Mac find bar goes — it's what
    /// `NSTextFinder` puts under a toolbar, and what Safari and Xcode show. It also keeps the header a
    /// stable height, which the sidebar's own header bar matches across the split.
    @ViewBuilder private var findBar: some View {
        if findVisible {
            HStack(spacing: 8) {
                SearchField(text: $findQuery,
                            placeholder: "Search tasks",
                            focusToken: findFocusToken,
                            onCancel: closeFind,
                            onCommit: focusTasks)
                    .frame(maxWidth: 260)
                if isFiltering {
                    Text(matchSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer(minLength: 0)
                Button("Done", action: closeFind)
                    .controlSize(.small)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private var matchSummary: String {
        let n = visibleTodos.count
        return n == 1 ? "1 match" : "\(n) matches"
    }

    /// Edit ▸ Find ▸ Find… (⌘F). Opening it when it's already open re-focuses and selects, so a second
    /// ⌘F is "search again" rather than a no-op.
    private func beginFind() {
        findVisible = true
        findFocusToken &+= 1
    }

    /// Close the bar and drop the query with it — a filter you can't see is a filter you'll forget.
    private func closeFind() {
        findVisible = false
        findQuery = ""
        focusTasks()
    }

    /// ⌘G / ⇧⌘G — Edit ▸ Find ▸ Find Next and Find Previous.
    ///
    /// This bar filters rather than highlighting matches in place, so there is no "next highlight" to
    /// jump to: the narrowed list *is* the matches, and stepping means moving the selection down it.
    /// That's still worth having — with the keyboard in the find field you can walk the results without
    /// leaving it, and the row you land on is the one Return and ⌘C will act on.
    ///
    /// Wraps at both ends, like every other find in the system. With nothing selected it starts at
    /// whichever end you're heading away from, so the first ⌘G lands on the first match rather than the
    /// second.
    private func stepFind(by direction: Int) {
        let keys = rowKeys
        guard !keys.isEmpty else { NSSound.beep(); return }
        let current = selection.count == 1 ? selection.first.flatMap(keys.firstIndex(of:)) : nil
        let next = current.map { ($0 + direction + keys.count) % keys.count }
            ?? (direction > 0 ? 0 : keys.count - 1)
        let key = keys[next]
        selection = [key]
        selectionAnchor = key
        scrollToken &+= 1
        scrollTarget = ScrollRequest(key: key, token: scrollToken)
    }

    /// ⌘E — Edit ▸ Find ▸ Use Selection for Find. Search for the selected task's own text.
    ///
    /// Only ever runs when no field has the keyboard: an `NSTextView` answers `performFindPanelAction:`
    /// itself, so while you're typing ⌘E means the text you selected there and never reaches the
    /// window. Opens the bar if it's shut, since searching for something is the reason you'd ask.
    private func useSelectionForFind() {
        guard let todo = actionTargets.first else { NSSound.beep(); return }
        findQuery = todo.text
        findVisible = true
    }

    /// The scrollable content below the pinned header: the optional details brief and the task/session
    /// list. This is what scrolls under the header when it overflows the window.
    @ViewBuilder private var scrollBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            if store.projectName == nil {
                emptyState
            } else {
                if detailsExpanded {
                    ProjectDetailsView(notes: store.notes, store: store, isEditing: $editingDetails)
                }
                // While editing details, hide everything below so the form stands alone.
                if !editingDetails {
                    // A project with no tasks at all gets a plain, emoji-free empty state with an add
                    // CTA. In notes mode, route to the session-oriented list even with no tasks yet, so
                    // empty sessions and the "New session" affordance still show.
                    if isFiltering && visibleTodos.isEmpty {
                        noMatches
                    } else if showsEmptyProjectCTA {
                        emptyProjectTasks
                    } else {
                        tasksSection
                    }
                    quickAddEditor
                }
            }
        }
    }

    /// Whether the tasks area is showing the empty-project call to action. Read both by the layout
    /// above and by `beginQuickAdd`, so the two can't drift into disagreeing about which add editor
    /// is the one on screen.
    private var showsEmptyProjectCTA: Bool {
        store.projectName != nil && !editingDetails
            && !(isFiltering && visibleTodos.isEmpty)
            && store.todos.isEmpty && !detailsExpanded
    }

    /// The unanchored add editor, at the foot of the list. Open only while `beginQuickAdd` has it
    /// targeted; `store.addTodo` with no anchor appends to the current session and focuses the new task.
    ///
    /// Stays open after each task, like the anchored editor — and unlike it, needs no help to do so.
    /// This one appends, so tasks come out in the order they were typed with the editor sitting still
    /// at the foot of the list; there's no anchor to advance.
    @ViewBuilder private var quickAddEditor: some View {
        if activeEditor == Self.quickAddTarget {
            AddEditor(leadingIcon: AnyView(TaskStatusIcon())) { text, due in
                // The first task into a project with no session for today creates one, and the
                // session-count watcher closes any open editor when that happens. This one is ours.
                if store.todaySessionIndex == nil { sessionCountChangeIsOurs = true }
                store.addTodo(text: text, due: due)
            } onCancel: { activeEditor = nil }
                .reportEditorFrame()
                .padding(.horizontal, 12)
                .padding(.top, 4)
                .padding(.bottom, 8)
        }
    }

    /// When the active editor is a session note, the (index, session) it targets — driving the full-column
    /// takeover editor. Nil for every other editor state.
    private var sessionNoteTakeover: (index: Int, session: Session)? {
        guard let ed = activeEditor, ed.kind == .sessionNote,
              let idx = Self.sessionIndex(fromRowKey: ed.key),
              let sessions = store.notes?.sessions, idx < sessions.count
        else { return nil }
        return (idx, sessions[idx])
    }

    /// Whether the sidebar holds a selection Escape has anything to undo: more than one project, or a
    /// single one that isn't the project this window is showing. The ordinary case — the current
    /// project selected, which is what a source list always looks like — isn't something to clear.
    private var hasProjectMultiSelection: Bool {
        state.projectSelection.count > 1
            || (state.projectSelection.first.map { $0 != store.projectKey } ?? false)
    }

    /// Escape unwinds the window one layer at a time — the pending delete, then an open editor, then a
    /// selection — and stops there. A window isn't summoned, so Escape has no business closing it.
    private func handleEscape() {
        if !pendingDelete.isEmpty {
            pendingDelete = []
        } else if editingDetails {
            editingDetails = false
        } else if activeEditor != nil {
            activeEditor = nil
        } else if findVisible {
            closeFind()
        } else if !selection.isEmpty || hasProjectMultiSelection {
            selection = []
            selectionAnchor = nil
            state.collapseProjectSelection(to: store.projectKey)
        }
        // ...and stops there. A real window isn't summoned, so Escape has no business closing it —
        // that's ⌘W. (The focus panel, which *is* summoned, still hides on its last Escape.)
    }

    // MARK: Header

    /// The header strip: the project's identity in a glass pill at the leading edge, its controls in a
    /// glass capsule at the trailing one, and nothing at all in between.
    ///
    /// This is the shape a titlebar strip takes on macOS 26 — the Messages conversation header. There's
    /// no bar; there's chrome floating over content that fades out from under it, which the scroll
    /// view's soft top edge does (see `SoftScrollEdges`). And the chrome is deliberately only
    /// *sometimes* there: in a background window the glass is gone and the strip is bare text, the
    /// window becoming active brings it in, and the pointer arriving in the strip lights it. The three
    /// states are `HeaderChrome`.
    ///
    /// Title only, on the left. Switching projects is the sidebar's job — a chevron here offered a
    /// second, smaller version of the same list, and the two disagreed about what "open" meant: this one
    /// moved the app's global focus, while the sidebar retargets the window you're in.
    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            projectPill
            Spacer(minLength: 12)
            headerControls
        }
        // Recede with the window, the way real window chrome does. The glass has already gone by this
        // point; this is what keeps the text from being the one thing in the strip still at full
        // strength.
        .opacity(headerChrome.contentOpacity)
        .modifier(TitlebarClearance(state: state))
        // Double-click empty header space toggles the details brief. On a background layer *behind* the
        // controls so the pill / view-options / open buttons in front consume their own clicks and are
        // excluded; `simultaneousGesture` so it still coexists with drag-by-window-background.
        .background(
            Color.clear
                .contentShape(Rectangle())
                .simultaneousGesture(TapGesture(count: 2).onEnded {
                    if store.projectName != nil { setDetails(!detailsExpanded) }
                })
        )
        // Hover is tracked for the strip as a whole rather than per element: this is one toolbar
        // revealing itself, so crossing the gap between the pill and the controls mustn't put it away
        // again on the way. On the outer view, whose `onHover` tracking area is its whole frame — the
        // background layer above sits behind the controls and would miss them.
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.18)) { headerHovering = hovering }
        }
        .animation(.easeOut(duration: 0.18), value: controlActiveState)
        // Right-clicking anywhere in the header opens the same view settings as the slider button.
        .contextMenu { viewOptionsMenuContent }
    }

    /// What the header's glass is doing right now — see `HeaderChrome`.
    private var headerChrome: HeaderChrome {
        HeaderChrome(active: controlActiveState, hovering: headerHovering)
    }

    /// The project's identity, in a glass pill: Messages' name pill, doing the same job. It says what
    /// you're looking at, and clicking it opens what's behind the name — there a contact card, here the
    /// project's notes brief.
    ///
    /// The hit area is the capsule the glass paints and only that. A pill that lights up under the
    /// pointer and then drops the click into the scroll view behind it is exactly the bug that was
    /// reported against the session and task rows.
    private var projectPill: some View {
        let live = store.projectName != nil
        return projectTitle
            // Enough inset that the title sits *in* the pill rather than against its edges — a capsule
            // this tight on its text reads as a tag, not as chrome.
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .headerBacking(headerChrome, in: Capsule())
            .contentShape(Capsule())
            .onTapGesture { if live { setDetails(!detailsExpanded) } }
            // A click on the pill is a click on the pill, not the start of a window drag.
            .background(WindowDragExcluder())
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(Text(store.notes?.title.trimmed ?? store.projectName ?? "No focused project"))
            .help(detailsExpanded ? "Hide notes" : "Show notes")
    }

    /// The header's controls, gathered into one glass capsule at the trailing edge: progress, the two
    /// ways of adding to the project, view options, and the "open this elsewhere" button.
    ///
    /// One capsule rather than several separate pieces of glass — they're a single group of window
    /// controls and read as one, the way the Messages header's trailing button does. With no bar behind
    /// the strip any more, the capsule is also what keeps the progress count legible over whatever has
    /// scrolled underneath it.
    ///
    /// Reading order is what you're doing, then how you're looking at it, then where else it lives:
    /// count, add, add, view options, open.
    @ViewBuilder private var headerControls: some View {
        if hasHeaderControls {
            HStack(spacing: 2) {
                let p = store.progress
                if p.total > 0 {
                    Text("\(p.done)/\(p.total)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .padding(.horizontal, 4)
                }
                if store.projectName != nil {
                    addTaskButton
                    addNoteButton
                    viewOptionsMenu
                }
                if store.projectPath != nil { openButton }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .headerBacking(headerChrome, in: Capsule())
            .background(WindowDragExcluder())
        }
    }

    /// The two add buttons: a task, and a note about the session you're in.
    ///
    /// Both summon the quick bar over the window rather than opening an editor inside it, which is the
    /// point of them — the bar is where capture lives, it already knows how to read a due date out of
    /// the line and how to place the result, and its note mode is a real markdown editor. A second,
    /// lesser version of either sitting in the header would be a third place for the same write to go
    /// wrong. The in-window editors are still there and still unchanged: ⌘N opens the inline add row,
    /// and double-clicking a session opens its note in the column.
    ///
    /// The glyphs are the modes' own, taken from `QuickBarMode` rather than restated here, so the
    /// button and the surface it opens can never come to disagree about what they mean.
    private var addTaskButton: some View {
        headerButton(symbol: QuickBarMode.capture.symbol, help: "Add a task") {
            state.openQuickBar(.capture)
        }
    }

    private var addNoteButton: some View {
        headerButton(symbol: QuickBarMode.note.symbol, help: "Write a session note") {
            state.openQuickBar(.note)
        }
    }

    /// One control in the trailing capsule: a symbol at the size and weight the others use, in a hit
    /// area big enough to click without aiming. Shared so the buttons can't drift apart.
    private func headerButton(symbol: String, help: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(Text(help))
    }

    /// Whether the trailing capsule has anything to hold. With no project focused it doesn't, and an
    /// empty pill of glass is worse than no pill.
    private var hasHeaderControls: Bool {
        store.projectName != nil || store.projectPath != nil || store.progress.total > 0
    }

    /// The project title. Plain text — the pill around it carries the gesture, so the text itself
    /// carries none.
    private var projectTitle: some View {
        Text(store.notes?.title.trimmed ?? store.projectName ?? "No focused project")
            .font(.title3.weight(.semibold))
            .lineLimit(1)
            .truncationMode(.tail)
    }

    /// Whether the view is in any non-default state (mode other than incomplete, or details showing),
    /// used to tint the view-options icon so there's a subtle "customized" cue.
    private var isViewCustomized: Bool {
        tasksMode != .incomplete || detailsExpanded || state.sidebarVisible || colorMode != .system
    }

    /// Single header menu holding all view state: the tasks-mode picker (Focused / Incomplete / All)
    /// and a "Show details" toggle (always available, so details can be added to a project that has
    /// none). Replaces the old "Details" text button and the tasks-list "Show all" checkbox,
    /// consolidating both axes in one HIG-native place.
    private var viewOptionsMenu: some View {
        Menu {
            viewOptionsMenuContent
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isViewCustomized ? Color.accentColor : Color.secondary)
                .frame(width: 20, height: 18)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("View options")
    }

    /// The view-options items — the tasks-mode picker, the "Show details" toggle, and the appearance
    /// picker. Shared by the header's slider button and the header's right-click menu, so right-clicking
    /// anywhere in the header surfaces the same view settings.
    @ViewBuilder private var viewOptionsMenuContent: some View {
        Picker("Tasks", selection: $tasksMode) {
            Label("Incomplete", systemImage: "circle").tag(TasksMode.incomplete)
            Label("All", systemImage: "list.bullet").tag(TasksMode.all)
        }
        .pickerStyle(.inline)
        Divider()
        Toggle(isOn: Binding(get: { detailsExpanded }, set: { setDetails($0) })) {
            Label("Show notes", systemImage: "note.text")
        }
        // No shortcut named here. ⌥⌘S can't be *set* on this item — a closed SwiftUI menu's items
        // aren't in the responder chain, so a key equivalent here wouldn't fire, and it lives on a
        // hidden button instead (see `keyboardShortcuts`). Spelling it into the title was the way
        // round that, and it bought a menu item whose key equivalent doesn't right-align in its own
        // column, doesn't localise, and doesn't follow the binding. The View menu advertises ⌥⌘S
        // properly, in the place a Mac user looks for it; this popover doesn't need to say it twice.
        Toggle(isOn: Binding(get: { state.sidebarVisible },
                             set: { _ in state.toggleSidebar() })) {
            Label("Show projects", systemImage: "sidebar.leading")
        }
        Divider()
        Picker("Appearance", selection: $colorMode) {
            Label("System", systemImage: "circle.lefthalf.filled").tag(AppColorMode.system)
            Label("Light", systemImage: "sun.max").tag(AppColorMode.light)
            Label("Dark", systemImage: "moon").tag(AppColorMode.dark)
        }
        .pickerStyle(.inline)
    }

    /// Opens the project in Obsidian, or in Finder while ⌥ is held (icon swaps to match), mirroring
    /// the menubar's "Open in Obsidian / ⌥ Open in Finder" alternate. The ⌥ swap is suppressed while a
    /// text editor is open, where ⌥ is used for typing and the flicker is just distracting.
    private var openButton: some View {
        let finder = modifiers.optionDown && !isAnyEditorActive
        let appIcon = AppIcons.smallImage(finder ? .finder : .obsidian)
        return Button {
            openProject(inFinder: finder)
        } label: {
            Group {
                if let appIcon {
                    Image(nsImage: appIcon).resizable().frame(width: 15, height: 15)
                } else {
                    Image(systemName: finder ? "folder" : "book.closed")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 20, height: 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(finder ? "Open in Finder" : "Open in Obsidian  (hold ⌥ for Finder)")
    }

    private func openProject(inFinder: Bool) {
        if inFinder {
            guard let path = store.projectPath else { return }
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        } else {
            ObsidianLink.open(store: store)
        }
    }

    /// Nothing matched the search. Distinct from the empty-project state on purpose: one is "this
    /// project has no tasks", the other is "your query has no hits", and offering the empty state's
    /// "add the first task" button here would be answering a question nobody asked.
    private var noMatches: some View {
        VStack(alignment: .center, spacing: 6) {
            Text("No matching tasks")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("No \(tasksMode == .all ? "task" : "open task") in this project contains “\(findQuery.trimmed ?? "")”.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            if tasksMode != .all {
                Button("Search Completed Tasks Too") { tasksMode = .all }
                    .controlSize(.small)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.vertical, 24)
    }

    private var emptyState: some View {
        VStack(alignment: .center, spacing: 6) {
            Text(store.errorMessage ?? "No focused project")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(noFocusHint)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    /// How to get somewhere from here, named by whatever the quick bar is actually bound to.
    private var noFocusHint: String {
        guard let keys = ShortcutHint.keys(.quickGoToProject) else {
            return "Pick a project from the menu bar, or the sidebar."
        }
        return "Press \(keys) to go to a project, or pick one from the menu bar."
    }

    // MARK: Tasks

    /// The sessions the compact list draws, in document order: every session with a visible task, plus
    /// every session with no tasks in it at all.
    ///
    /// The second half is the distinction worth stating. A session with nothing in it is drawn, because
    /// it's a real session someone started and it should be visible, addressable, and something a task
    /// can be dragged into — a session used to disappear the moment its last task was hidden, which
    /// left ⇧⌘N's brand new session with nothing on screen to show for it. A session whose tasks are
    /// merely *filtered* out — all complete in Incomplete mode, none matching the find bar — stays
    /// hidden, because a bare caption there would claim the session is empty when it isn't.
    ///
    /// A search hides the genuinely empty ones too. They match nothing, and a result of two tasks
    /// shouldn't arrive padded with headings that are only there because they hold nothing to reject.
    private var sessionOrder: [Int] {
        let withVisibleTasks = Set(visibleTodos.map(\.sessionIndex))
        let withAnyTasks = Set(store.todos.map(\.sessionIndex))
        let declared = Set(0..<(store.notes?.sessions.count ?? 0))
        // Union rather than the declared range alone: a todo whose session index outruns the parsed
        // session list still has to be drawn somewhere rather than silently dropped.
        return declared.union(withVisibleTasks)
            .filter { withVisibleTasks.contains($0)
                      || (!isFiltering && !withAnyTasks.contains($0)) }
            .sorted()
    }

    /// A session's bare label (no date), for seeding the rename editor. Empty when the index no
    /// longer names a session — the same tolerance `sessionContext` takes.
    private func sessionLabel(_ index: Int) -> String {
        guard let sessions = store.notes?.sessions, index >= 0, index < sessions.count else { return "" }
        return sessions[index].label
    }

    private func sessionContext(_ index: Int) -> String {
        guard let sessions = store.notes?.sessions, index < sessions.count else { return "" }
        let s = sessions[index]
        return s.label.isEmpty ? s.date : "\(s.date) · \(s.label)"
    }

    /// While a task is being wrapped it slides one level deeper (nesting under the parent-to-be); its
    /// whole subtree must cascade with it. These are the keys of that subtree — the contiguous run of
    /// deeper todos right after the wrap target — so their rows get the same +1 indent boost.
    private var wrapDescendantKeys: Set<String> {
        guard let ed = activeEditor, ed.kind == .wrap,
              let wIdx = store.todos.firstIndex(where: { PMStore.key(for: $0) == ed.key }) else { return [] }
        let wDepth = store.todos[wIdx].depth
        var keys: Set<String> = []
        var j = wIdx + 1
        while j < store.todos.count, store.todos[j].depth > wDepth {
            keys.insert(PMStore.key(for: store.todos[j]))
            j += 1
        }
        return keys
    }

    /// Shown when the focused project has no tasks at all. Deliberately emoji-free (unlike the
    /// "all complete" states, which imply work was finished) and centered on a single add CTA that
    /// reveals an inline editor for the very first task.
    @ViewBuilder private var emptyProjectTasks: some View {
        VStack(spacing: 10) {
            if addingFirstTask {
                AddEditor(leadingIcon: AnyView(TaskStatusIcon())) { text, due in
                    if store.todaySessionIndex == nil { sessionCountChangeIsOurs = true }
                    store.addTodo(text: text, due: due)
                    // The call to action is gone the moment the project has a task, taking this editor
                    // with it — so hand the typing straight to the one that appears in its place,
                    // rather than ending the flow on the word "first".
                    addingFirstTask = false
                    activeEditor = Self.quickAddTarget
                } onCancel: { addingFirstTask = false }
                    .padding(.horizontal, 12)
            } else {
                Text("No tasks yet")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button {
                    addingFirstTask = true
                } label: {
                    Label("Add a task", systemImage: "plus.circle")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .animation(.snappy, value: addingFirstTask)
    }

    private var tasksSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            // A quiet rule where the "Tasks" heading used to be, fencing the list off from the details
            // brief above it. When details are collapsed the pinned header already carries that rule, so
            // we don't draw a second one — just keep the list's top breathing room.
            if detailsExpanded {
                Divider()
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
            } else {
                Color.clear.frame(height: 4)
            }

            // In notes mode, keep the session-oriented list even when no tasks are visible — the
            // headers are the content there. A project with no sessions at all is the one case that
            // leaves nothing to draw, and gets the empty state instead of a blank column.
            if hasNothingToList {
                emptyListState
            } else {
                taskRowsList
            }
        }
        .padding(.bottom, 8)
        // One implicit animation, keyed on both triggers, so this subtree never re-scopes to its own
        // clock: rows entering/leaving (completing a task, switching tasks mode) AND the details toggle
        // both animate here with the shared `detailsMotion`. Keying it *also* on `detailsExpanded` is
        // what keeps the "Tasks" heading and rows sliding in lockstep with the details reveal above them
        // — without it, this subtree's own `.animation(_, value: visibleTodos)` suppresses the ambient
        // toggle animation and the heading drifts at a different rate.
        .animation(Self.detailsMotion, value: TasksMotionKey(todos: visibleTodos, expanded: detailsExpanded))
    }

    /// Whether the list has nothing to draw: no visible tasks, and — in notes mode, where empty
    /// sessions are still rows — no sessions either.
    private var hasNothingToList: Bool {
        guard visibleTodos.isEmpty else { return false }
        return !detailsExpanded || (store.notes?.sessions.isEmpty ?? true)
    }

    /// The quiet line standing in for an empty list. In notes mode it also names the shortcut that
    /// fills it: this is the one screen with nothing on it to right-click, and the "New session" button
    /// that used to sit here is a command now.
    @ViewBuilder private var emptyListState: some View {
        VStack(spacing: 3) {
            if detailsExpanded {
                Text("No sessions yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("⇧⌘N starts today's.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                Text(tasksMode == .all ? "No tasks yet" : "All tasks complete")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 16)
    }

    /// The task rows, grouped by session, wrapped in a single list-level drop target. One coordinate
    /// space anchors the row frames (published via preference) and the drop delegate's pointer, so the
    /// delegate resolves the drag into exactly one gap + depth and the overlay paints exactly one
    /// insertion line. Rows within a session tile with no spacing so the gaps abut with no dead bands.
    private var taskRowsList: some View {
        let wrapDescendants = wrapDescendantKeys
        // The keys of the subtree currently being dragged, so those rows dim in place while the ghost
        // floats. Empty when no drag is in flight.
        let draggedSubtree: Set<String> = draggingKey
            .flatMap { k in store.todos.first { PMStore.key(for: $0) == k } }
            .map { store.subtreeKeys(of: $0) } ?? []
        // No spacing of its own: a uniform gap between every child would sit between a heading and its
        // own tasks as readily as between two sessions. Each session brings its own `sessionGap`.
        return VStack(alignment: .leading, spacing: 0) {
            if detailsExpanded {
                revealedSessions(wrapDescendants: wrapDescendants, draggedSubtree: draggedSubtree)
            } else {
                groupedSessions(wrapDescendants: wrapDescendants, draggedSubtree: draggedSubtree)
            }
        }
        .coordinateSpace(name: TaskDropResolver.coordinateSpace)
        .onPreferenceChange(RowFramesKey.self) { rowFrames = $0 }
        .onPreferenceChange(SessionFramesKey.self) { sessionFrames = $0 }
        .overlay(alignment: .topLeading) { dropIndicator }
        // The app's own task type leads, so a reorder is matched by identity rather than by "some
        // text arrived". `.text` and `.fileURL` are what a drag from *outside* brings: a few lines out
        // of a document become tasks through the same parser ⌘V uses, and a file becomes a task
        // linking it. Which of the two paths a drag takes is decided by `isActive` — whether one of
        // our own rows started it — so an in-app reorder is never read as a text drop, even though our
        // own drag carries markdown too.
        .onDrop(of: [TaskPasteboard.taskKeysType, .text, .fileURL], delegate: ListDropDelegate(
            isActive: { draggingKey != nil },
            onCompute: { computeDropTarget(at: $0) },
            onUpdate: { dropTarget = $0 },
            onPerform: { performListDrop($0) },
            onComputeExternal: { computeExternalDropTarget(at: $0) },
            onDropExternal: { performExternalDrop($0, at: $1) }
        ))
        // The list is the keyboard target for ↑/↓, ⌫, ⌘A and ⌘C. The focus *ring* is suppressed — a
        // blue rectangle around the whole list would be heavy here — and which pane has
        // focus is shown the Mac way instead, by whether the selection reads emphasized or muted.
        .focusable()
        .focused($tasksFocused)
        .focusRingOff()
        .onMoveCommand { moveSelection($0) }
        .onDeleteCommand { requestDelete(actionTargets) }
    }

    /// The drag payload for a row: the whole selection when the grabbed row is part of one, else just
    /// that row. Reordering still moves the row you grabbed (a multi-row reorder would need a slot per
    /// subtree); it's the *exported* markdown that carries everything selected.
    private func dragProvider(for todo: Todo) -> NSItemProvider {
        let key = PMStore.key(for: todo)
        let dragged = selection.contains(key) && selection.count > 1 ? actionTargets : [todo]
        return TaskPasteboard.itemProvider(keys: dragged.map(PMStore.key(for:)),
                                           markdown: store.markdown(for: dragged))
    }

    /// Default rendering: each session `sessionOrder` picks, introduced by a quiet caption. A session
    /// with no tasks draws its caption and nothing under it — that caption is the whole of it, and it's
    /// what makes the session visible, right-clickable, and a place a task can be dragged into. This is
    /// the default when session notes aren't revealed.
    @ViewBuilder private func groupedSessions(wrapDescendants: Set<String>, draggedSubtree: Set<String>) -> some View {
        ForEach(sessionOrder, id: \.self) { si in
            let context = sessionContext(si)
            if !context.isEmpty {
                sessionCaption(si, context: context)
            }
            sessionTaskRows(si, wrapDescendants: wrapDescendants, draggedSubtree: draggedSubtree)
        }
    }

    /// A session's quiet caption in the compact list: the same target as the revealed header, behind
    /// the same gestures — double-click opens the session's note, right-click offers the rest — so a
    /// session doesn't need the notes view turned on to be written in. It swaps for the rename editor
    /// while that's what's open.
    @ViewBuilder private func sessionCaption(_ si: Int, context: String) -> some View {
        let target = EditorTarget(key: Self.sessionKey(si), kind: .sessionLabel)
        if activeEditor == target {
            InlineTextEditor(seed: sessionLabel(si),
                             placeholder: "Session label (optional)",
                             submitLabel: "Rename", allowsEmpty: true) { label in
                if let ref = activeEditor?.session { store.renameSession(ref, label: label) }
                activeEditor = nil
            } onCancel: { activeEditor = nil }
                .reportEditorFrame()
                .padding(.horizontal, 12)
                .padding(.vertical, Self.sessionHeadingPadding)
                .padding(.top, Self.sessionGap)
        } else {
            Text(context)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 12)
                .padding(.vertical, Self.sessionHeadingPadding)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { openSessionNote(si) }
                .contextMenu {
                    SessionMenu(index: si, hasNote: !sessionProse(si).isEmpty,
                                store: store, activeEditor: $activeEditor)
                }
                // Outside the caption's hit area, so the gap between sessions stays blank space rather
                // than becoming a taller target for the session below it.
                .padding(.top, Self.sessionGap)
                .background(SessionFrameReporter(index: si))
        }
    }


    /// Revealed rendering: every session (including empty ones) as a first-class row — its header, its
    /// editable prose note, and its tasks. Nothing else: adding a task or a session is a command
    /// (⌘N, ⇧⌘N) and a context-menu item, not a button parked in the list.
    @ViewBuilder private func revealedSessions(wrapDescendants: Set<String>, draggedSubtree: Set<String>) -> some View {
        let sessions = store.notes?.sessions ?? []
        ForEach(Array(sessions.enumerated()), id: \.offset) { index, session in
            SessionHeader(index: index, session: session, store: store, activeEditor: $activeEditor,
                          isSelected: selection.contains(Self.sessionKey(index)),
                          // "Emphasized" in the AppKit sense, exactly as a task row reads it.
                          isEmphasized: tasksFocused,
                          onClick: { selectRow(Self.sessionKey(index), modifiers: $0) },
                          onActivate: { openSessionNote(index) })
            sessionTaskRows(index, wrapDescendants: wrapDescendants, draggedSubtree: draggedSubtree)
            sessionAddEditor(index)
        }
    }

    /// A session's note prose, for deciding whether the menu offers "Add" or "Edit".
    private func sessionProse(_ index: Int) -> String {
        guard let sessions = store.notes?.sessions, index >= 0, index < sessions.count else { return "" }
        return leadingSessionProse(body: sessions[index].body)
    }

    /// Open a session's note in the full-column editor — the double-click on any part of a session,
    /// Return on a selected one, and the context menu's Add/Edit Note.
    private func openSessionNote(_ index: Int) {
        activeEditor = EditorTarget(key: Self.sessionKey(index), kind: .sessionNote,
                                    session: store.sessionRef(at: index))
    }

    /// One session's visible task rows, tiled with no spacing so their drop gaps abut.
    private func sessionTaskRows(_ si: Int, wrapDescendants: Set<String>, draggedSubtree: Set<String>) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(identifiedTodos.filter { $0.todo.sessionIndex == si }) { row in
                let todo = row.todo
                let key = PMStore.key(for: todo)
                TaskRow(
                    todo: todo,
                    store: store,
                    activeEditor: $activeEditor,
                    draggingKey: $draggingKey,
                    dimmed: draggedSubtree.contains(key),
                    ancestorWrapBoost: wrapDescendants.contains(key) ? 1 : 0,
                    isSelected: selection.contains(key),
                    // "Emphasized" in the AppKit sense: a selection in the pane that has keyboard
                    // focus reads stronger than the same selection in a pane that doesn't.
                    isEmphasized: tasksFocused,
                    onClick: { selectRow(key, modifiers: $0) },
                    onActivate: { store.focus(todo) },
                    contextTargets: { contextTargets(for: todo) },
                    onHoverChanged: { rowHover.set(key, inside: $0) },
                    dragProvider: { dragProvider(for: todo) },
                    onDelete: { requestDelete($0) },
                    onSetDue: { applyDue($0, from: todo) },
                    onAddTask: { text, due in commitAdd(text: text, due: due, anchor: todo) },
                    addPosition: $addPosition
                )
            }
        }
    }

    /// The per-session add editor, appended to the session it belongs to. It's opened by ⌘N with that
    /// session's header selected and by the session menu's "Add Task…" — there's no button for it.
    ///
    /// A session used to carry a visible "Add task" button whenever it had no tasks to hang a per-row
    /// add on, and the list carried a "New session" button above it. Both were doing hit-target duty
    /// for things that are properly commands, and read as form controls loose in a document. What
    /// replaced them is a session header you can select: ⌘N adds to it, Return opens its note, and
    /// ⇧⌘N starts today's.
    @ViewBuilder private func sessionAddEditor(_ index: Int) -> some View {
        if activeEditor == EditorTarget(key: Self.sessionKey(index), kind: .sessionAddTask) {
            AddEditor(leadingIcon: AnyView(TaskStatusIcon())) { text, due in
                // Appends, so it chains in order with the editor staying put — see `quickAddEditor`.
                if let ref = activeEditor?.session { store.addTaskToSession(ref, text: text, due: due) }
            } onCancel: { activeEditor = nil }
                .reportEditorFrame()
                .padding(.horizontal, 12)
                // The list tiles its children with no spacing, so the editor asks for its own gap off
                // the last task rather than sitting flush against it.
                .padding(.top, ProjectView.sessionHeadingPadding)
        }
    }

    /// The single insertion indicator: a caret dot + rule drawn at the resolved slot's Y and the chosen
    /// depth's indent. Shown whenever a slot resolved at all; when none does — which only happens when
    /// the whole list is in the air — there's nothing to point at and the "no drop" cursor says so.
    @ViewBuilder private var dropIndicator: some View {
        if let t = dropTarget {
            HStack(spacing: 0) {
                Circle().fill(Color.accentColor).frame(width: 6, height: 6)
                Capsule().fill(Color.accentColor).frame(height: 2)
            }
            .padding(.leading, Self.rowContentInset + CGFloat(t.depth) * Self.indentStep)
            .padding(.trailing, 12)
            // Center the 6pt dot on the boundary line.
            .offset(y: t.gapY - 3)
            .allowsHitTesting(false)
        }
    }

    /// Resolve a pointer location (in `TaskDropResolver.coordinateSpace`) into an insertion slot. The geometry lives in
    /// `TaskDropResolver`; this only supplies what the view knows — the visible rows, and which of them
    /// are riding along in the drag.
    private func computeDropTarget(at p: CGPoint) -> DropTarget? {
        guard let dk = draggingKey,
              let dragged = store.todos.first(where: { PMStore.key(for: $0) == dk }) else { return nil }
        return TaskDropResolver.resolve(pointer: p,
                                        rows: rowFrames,
                                        sessionFrames: sessionFrames,
                                        draggedSubtree: store.subtreeKeys(of: dragged),
                                        contentInset: Self.rowContentInset,
                                        indentStep: Self.indentStep)
    }

    /// Resolve a slot for a drag that started outside the app. Same geometry as `computeDropTarget`,
    /// minus the dragged subtree — there isn't one, so nothing has to be excluded from the list.
    private func computeExternalDropTarget(at p: CGPoint) -> DropTarget? {
        TaskDropResolver.resolve(pointer: p,
                                 rows: rowFrames,
                                 sessionFrames: sessionFrames,
                                 draggedSubtree: [],
                                 contentInset: Self.rowContentInset,
                                 indentStep: Self.indentStep)
    }

    /// Land text or files dragged in from another app.
    ///
    /// Text goes through the same parser ⌘V uses, so a list dragged out of a document arrives with its
    /// nesting and its checkboxes intact and a paragraph arrives as one task. A file arrives as a task
    /// that links it — the notes are markdown read in Obsidian, where that link is live.
    ///
    /// The providers load asynchronously, so this answers `true` for "I'll take it" and does the write
    /// when the text turns up. There's nothing useful to say in the gap: a drop that will land in a
    /// tenth of a second doesn't need a spinner.
    private func performExternalDrop(_ providers: [NSItemProvider], at target: DropTarget?) -> Bool {
        guard store.projectName != nil, !providers.isEmpty else { return false }
        let anchor = target.flatMap(anchorTask(for:))

        Task { @MainActor in
            var block: [PastedTask] = []
            for provider in providers {
                if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
                   let url = await provider.loadFileURL() {
                    let name = url.deletingPathExtension().lastPathComponent
                    block.append(PastedTask(depth: 0, text: "[\(name)](\(url.absoluteString))"))
                } else if let text = await provider.loadText() {
                    block.append(contentsOf: TaskPasteboard.parse(text))
                }
            }
            guard !block.isEmpty else { return }
            store.pasteTasks(block, after: anchor)
        }
        return true
    }

    /// The task a resolved slot sits after, for a drop that inserts rather than moves. Nil for a drop
    /// on an empty session, where the session itself is the whole address.
    private func anchorTask(for target: DropTarget) -> Todo? {
        guard case let .beside(session, line, _) = target.destination else { return nil }
        return store.todos.first { $0.sessionIndex == session && $0.lineIndex == line }
    }

    /// Commit a resolved drop: move the dragged subtree to the target's destination, then clear state.
    private func performListDrop(_ t: DropTarget) -> Bool {
        guard let dk = draggingKey,
              let source = store.todos.first(where: { PMStore.key(for: $0) == dk })
        else { return false }

        switch t.destination {
        case let .beside(session, line, after):
            guard let anchor = store.todos.first(where: {
                $0.sessionIndex == session && $0.lineIndex == line
            }) else { return false }
            store.moveSubtree(source, anchor: anchor, insertAfter: after, depth: t.depth)
        case let .endOfSession(index):
            store.moveSubtree(source, toSession: index)
        }

        draggingKey = nil
        dropTarget = nil
        return true
    }
}

/// How the project window's tasks area presents itself. Raw values persist via `@AppStorage`.
///
/// A `focused` case used to sit alongside these, collapsing the window to a single task. That view is
/// the focus panel now — a separate always-on-top window — so this is back to being what it reads as: a
/// filter over the list. A stored `"focused"` no longer decodes, and `@AppStorage` falls back to the
/// default, which is the right landing place for anyone upgrading mid-mode.
enum TasksMode: String {
    case incomplete, all
}

/// The fill behind a selectable row in the task list — a task's or a session header's: the selection
/// band, or a whisper of one on hover.
///
/// Three states, as in every native list — selected in the focused pane of the key window (accent),
/// selected but not (grey), and not selected. It's a tint rather than a solid accent fill so the row's
/// own colours — the orange due chip, the secondary strikethrough of a completed task, a session's
/// prose — stay themselves instead of needing a second, inverted palette.
struct RowSelectionBand: View {
    let isSelected: Bool
    let isEmphasized: Bool
    let isHovering: Bool
    /// Whether the row's window is the key window — a selection in an inactive window is muted, as in
    /// every native list.
    @Environment(\.controlActiveState) private var controlActiveState
    var body: some View {
        fill.clipShape(RoundedRectangle(cornerRadius: ReadableWidth.bandCornerRadius,
                                        style: .continuous))
    }

    @ViewBuilder private var fill: some View {
        if isSelected {
            isEmphasized && controlActiveState != .inactive
                ? Color.accentColor.opacity(0.28)
                : Color.primary.opacity(0.10)
        } else if isHovering {
            Color.primary.opacity(0.05)
        } else {
            Color.clear
        }
    }
}

/// The project window two selectable lists. Whichever holds keyboard focus is the one arrow keys, ⌫, ⌘A and
/// ⌘C drive, and the one whose selection reads emphasized.
/// A visible task paired with the identity its row is diffed on — see `ProjectView.identifiedTodos`.
struct IdentifiedTodo: Identifiable {
    let id: String
    let todo: Todo
}

/// Combined trigger for the tasks section's single implicit animation. It must fire on both the visible
/// task set changing *and* the details toggle, so the section animates on the same shared clock as the
/// details reveal above it rather than re-scoping to its own — see `tasksSection`.
private struct TasksMotionKey: Equatable {
    let todos: [Todo]
    let expanded: Bool
}

/// The app color-scheme override. Raw values persist via `@AppStorage`; `.system` maps to `nil`
/// so SwiftUI falls back to the OS appearance.
enum AppColorMode: String {
    case system, light, dark
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}

/// The content column's leading edge in window space, so the header can tell how much of the window's
/// traffic lights it actually sits under.
/// Optional, and reduced by "first one that actually reported", for the reason spelled out on
/// `BarHeightKey`: these are read across a view and its `.background`, so one of the two subtrees sets
/// a real measurement and the other sets nothing. With a plain value and `value = nextValue()`, the
/// subtree that reduces last wins — and when that was the non-reporting one, the answer was the
/// default. `nil` for "didn't measure" makes non-reporters skippable, so the single real measurement
/// wins regardless of order.
private struct HeaderOriginKey: PreferenceKey {
    static var defaultValue: CGFloat?
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) { value = value ?? nextValue() }
}

/// The header's own height, so its top padding can centre it on the traffic lights whatever it holds.
///
/// This one was silently broken by the reduction above: it defaulted to 22 — one `.title3` line — which
/// is the task list header's height, so that header looked right and the note takeover's two-line header
/// went on being centred as if it were one line, which is the bug measuring it was meant to fix.
private struct HeaderHeightKey: PreferenceKey {
    static var defaultValue: CGFloat?
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) { value = value ?? nextValue() }
}

/// A request to scroll a row into view.
///
/// The token is what makes two requests for the *same* row distinct values, so `onChange` sees them.
/// That used to be bought by clearing the target on the next runloop turn — a hop whose only purpose
/// was to make the next identical assignment register, and which left the target briefly stale in
/// between. Carrying the token says the same thing in the value itself.
private struct ScrollRequest: Equatable {
    let key: String
    let token: Int
}

/// The height of a whole header bar — header plus its rule and padding, not just the text — so content
/// underneath can be inset by exactly as much as the bar covers.
private struct BarHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    /// `max`, not the `value = nextValue()` of the keys above. Those are read where exactly one subtree
    /// sets them; this one is read across a stack where the bar sets a height and the editor beside it
    /// sets nothing and so contributes the default. Last-writer-wins then comes down to which of the two
    /// reduces last, and when it was the editor the answer was 0 — the bar's height never reached the
    /// editor at all, and the note's first lines sat underneath it.
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Insets a header that runs up under the window's (hidden, transparent) titlebar so it clears the
/// traffic lights and sits level with them.
///
/// Every header this column can show wears this — the task list's and the session-note takeover's —
/// because they occupy the same strip and swap places. Hard-coding the padding in one of them is how
/// the takeover's title ended up under the buttons on macOS 26, where the unified titlebar sits them
/// lower than the compact one this app started against.
private struct TitlebarClearance: ViewModifier {
    @ObservedObject var state: ProjectViewState
    /// The gap below the header. The task list's is fenced off by a rule, the takeover's by a divider
    /// tight to the editor, so they don't want the same one.
    var bottom: CGFloat = 14

    /// The column's own offset within its pane — zero until the width cap starts centring it in a wide
    /// window.
    @State private var columnOffsetInPane: CGFloat = 0

    /// The header's measured height. Seeded at one `.title3` line, which is the task list's header, so
    /// the first frame lands where it will settle rather than jumping.
    @State private var contentHeight: CGFloat = 22

    /// How much of the window's traffic lights this column sits under.
    private var overhang: CGFloat {
        guard !state.sidebarVisible else { return 0 }
        return max(0, state.leadingTitlebarInset - columnOffsetInPane)
    }

    func body(content: Content) -> some View {
        content
            .padding(.trailing, 14)
            // Start past the traffic lights, but only by however much they actually overhang this
            // column.
            //
            // Two things decide that. The sidebar, when it's showing, holds the buttons over *itself*,
            // so the column needs no inset at all. And once the window is wide enough that the width
            // cap has centred the column, it may already begin clear of them — so a fixed inset would
            // shove the title 60-odd points further right for no reason.
            //
            // The inset is animated because the sidebar's collapse is: the flag flips in one frame
            // while the pane takes a quarter second to slide, and an unanimated jump in the middle of
            // that is the reflow this used to show on every toggle.
            .padding(.leading, 14 + overhang)
            // Measured *outside* the padding above, so it reports the column's own leading edge within
            // its pane and can't feed back into the value it produces. Pane-local is all that's
            // available — each pane's SwiftUI content is its own coordinate root — but pane-local is
            // also all that's needed, given the sidebar case is settled by the flag.
            .background(GeometryReader { geo in
                Color.clear
                    .preference(key: HeaderOriginKey.self, value: geo.frame(in: .global).minX)
                    // Height is measured here too, and this is the right place for it: horizontal
                    // padding doesn't change it, and the vertical padding that consumes it is applied
                    // below, so it can't feed back either.
                    .preference(key: HeaderHeightKey.self, value: geo.size.height)
            })
            .onPreferenceChange(HeaderOriginKey.self) { if let x = $0 { columnOffsetInPane = x } }
            .onPreferenceChange(HeaderHeightKey.self) { if let h = $0, h > 0 { contentHeight = h } }
            .animation(.easeInOut(duration: 0.25), value: overhang)
            // Centre the header on the traffic lights, wherever the system has put them — the unified
            // titlebar this window uses sits them twice as far down as a compact one would, and
            // hard-coding either number means the header is level in one and adrift in the other.
            //
            // Centred on the header's *measured* height, not on half a title line. Both headers that
            // wear this are laid out by it, and they aren't the same height: the task list's is one
            // `.title3` line, while the note takeover's is a two-line stack (project name over the
            // session's date). A fixed half-line centres whichever one it was written for and hangs the
            // other below the buttons — which is what the takeover's header was doing.
            // Floored at zero, not at 8. The floor used to be 8pt of guaranteed top margin, which
            // quietly stopped being a floor and started being the answer: the note takeover's header is
            // a two-line pill, tall enough that centring it on the buttons wants about 4pt of top
            // padding, so the clamp held it ~4pt below the traffic lights it was supposed to be level
            // with. A header taller than twice the button drop is *meant* to reach further up — that's
            // what centring on a line means — and zero is the only floor that says so.
            .padding(.top, max(0, state.titlebarButtonCenterY - contentHeight / 2))
            .padding(.bottom, bottom)
    }
}

/// The readable-width cap: contents grow to `maxContentWidth` and then stop, sitting leading-aligned
/// in whatever pane width is left over, so a wide window turns into margin rather than very long rows.
///
/// Leading, not centred. The cap keeps rows readable in a wide window; centring the capped column on
/// top of that left the project name adrift in the middle of the pane, with no edge to line up against
/// and the sidebar's own content a long way off to its left.
///
/// This rides the column's contents — the header, the scrolling rows, the note editor — rather than
/// the column itself. Wrapped around the column, it capped everything inside including the header's
/// material bar, so dragging the window wider than the cap left the bar stopping short of the window's
/// edge while the pane kept going. Inside, each piece takes the cap where the cap belongs (the text)
/// and the bar spans the pane.
private struct ReadableWidth: ViewModifier {
    /// How wide this content is allowed to get. Rows and the header that leads them take
    /// `maxListWidth`; prose takes the narrower `maxContentWidth` it defaults to.
    var cap: CGFloat = ProjectWindow.maxContentWidth

    /// The column's width, measured once by `ProjectView` and handed down.
    @Environment(\.pmColumnWidth) private var columnWidth

    /// The margin at each end of the ramp. `minGutter` is what even the narrowest window gives up —
    /// content is never flush against the pane's edges — and `maxGutter` is what a window with room to
    /// spare opens out to.
    ///
    /// Between `snug` and `roomy` it ramps, so dragging a window wider opens the margins gradually
    /// rather than snapping them open as it crosses one particular pixel; a step there is visible and
    /// reads as a glitch.
    private static let snug: CGFloat = 520
    private static let roomy: CGFloat = 760
    private static let minGutter: CGFloat = 6
    private static let maxGutter: CGFloat = 20

    /// The margin a column of this width carries. Static so the scroll view can ask for the same
    /// number for its bottom inset without a second copy of the ramp.
    static func gutter(for columnWidth: CGFloat) -> CGFloat {
        guard columnWidth > snug else { return minGutter }
        let t = min(1, (columnWidth - snug) / (roomy - snug))
        return (minGutter + (maxGutter - minGutter) * t).rounded()
    }

    /// The corner radius a row's selection band takes.
    ///
    /// A constant, because the band is now always standing in a margin — there is no width at which it
    /// runs flush to the pane's edges, so there is no width at which it should look like a stripe
    /// rather than a shape. This used to track the gutter, back when a narrow window had none.
    static let bandCornerRadius: CGFloat = 7

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: cap, alignment: .leading)
            // Outside the cap, not inside it: the gutter is margin the pane gives away, so a wide
            // window spends it on breathing room at the edges and still gets the full readable width
            // between them. Inside, it would have narrowed the text instead.
            .padding(.horizontal, Self.gutter(for: columnWidth))
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The content column's width, published by `ProjectView` and read by every `ReadableWidth` under it.
private struct ColumnWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct ColumnWidthEnvironmentKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    /// The width of the project window's content column. Zero until the first measurement, which
    /// `ReadableWidth` reads as "no room to spare" — see `ReadableWidth.gutter(for:)`.
    var pmColumnWidth: CGFloat {
        get { self[ColumnWidthEnvironmentKey.self] }
        set { self[ColumnWidthEnvironmentKey.self] = newValue }
    }
}

/// The three states the project header's chrome moves through, and the one place that decides which
/// is which.
///
/// Modelled on the Messages conversation header, where the toolbar is not a permanent fixture: it's
/// absent in a background window, present once the window is active, and lit while the pointer is in
/// it. Two inputs, three states — hover wins over the window's state, so reaching for a control in a
/// window you haven't clicked into yet still shows you what you're reaching for.
///
/// One type rather than a pair of booleans read at each call site, because the pill and the capsule
/// have to agree: two pieces of glass in the same strip disagreeing about whether they exist is worse
/// than either choice made consistently.
private enum HeaderChrome: Equatable {
    /// Another window has the focus. No glass at all, and the content behind it recedes.
    case dormant
    /// This window is active, the pointer is elsewhere. Backed, at rest.
    case resting
    /// The pointer is in the header strip. Backed at full strength.
    case engaged

    init(active: ControlActiveState, hovering: Bool) {
        if hovering {
            self = .engaged
        } else if active == .inactive {
            self = .dormant
        } else {
            self = .resting
        }
    }

    /// How strongly the backing renders, 0–1.
    ///
    /// Nothing here goes to zero. An earlier pass had the dormant state drop its backing entirely, on
    /// the theory that a background window's chrome should get out of the way — but there's no bar
    /// behind this header any more, so "nothing" meant the task rows scrolled up into the title and
    /// made it unreadable. Receding is a job for less contrast, not for none, and the floor is set by
    /// what stays legible rather than by how quiet it would be nice to be.
    var backingStrength: Double {
        switch self {
        case .dormant: return 0.7
        case .resting: return 0.85
        case .engaged: return 1
        }
    }

    /// How strongly the *content* renders. Dimmed in a background window, but only slightly: this is
    /// the same legibility problem from the other side, and text at half strength over a half-strength
    /// backing is no easier to read than text over nothing.
    var contentOpacity: Double { self == .dormant ? 0.85 : 1 }
}

extension View {
    /// Backs a piece of header chrome at the strength its state calls for. One modifier for all four
    /// pieces (both headers' pills, the trailing capsule, the back button), so they can't drift apart.
    ///
    /// A plain material, not Liquid Glass, after trying both. `glassEffect` has no intensity control —
    /// its two variants are `.regular` and `.clear`, and `.clear` is the *media* variant, brighter and
    /// more present over a plain window rather than quieter. The only way to turn glass down is to
    /// fade the layer, which means putting it in a background so the title above keeps its own
    /// opacity — and glass in a background inside a `GlassEffectContainer` renders over its sibling
    /// content, which hid the very titles it was supposed to be backing.
    ///
    /// A material has the dial built in and composites the ordinary way, which is the whole
    /// requirement here: this chrome exists to hold a title legible over scrolling rows, at a weight
    /// that changes with the window's state. Liquid Glass is still in the app where it earns its keep
    /// — the focus panel, a floating HUD over other apps' windows (see `GlassBackground`).
    fileprivate func headerBacking(_ chrome: HeaderChrome, in shape: some Shape) -> some View {
        background {
            shape.fill(.regularMaterial).opacity(chrome.backingStrength)
        }
    }
}

/// The material behind a full-width strip that stands in the window's titlebar band — the find bar and
/// the delete confirmation in the task column, and the whole header of the session-note takeover — so
/// the strip reads as a bar rather than as bare window background with text floating in it.
///
/// The task column's own header no longer wears this: it's floating glass (see `HeaderChrome`), and
/// content passing beneath it is handled by the scroll view's soft top edge instead.
///
/// `NSVisualEffectView` on the `.titlebar` material, not `NSGlassEffectView`: this is an edge-to-edge
/// bar along the top of a pane, and the glass view is for free-floating elements — it rounds its own
/// corners and carries a shadow, which is right for the focus panel (see `GlassBackground`) and wrong
/// here. `.titlebar` is also the material the system itself uses in this strip, so it tracks whatever
/// macOS draws there rather than pinning the app to one version's idea of it.
///
/// `.withinWindow` so the content scrolling underneath is what blurs through it. That is the whole
/// point of the bar: with the content stopping above it there is nothing to blur and the material has
/// nothing to say.
private struct TitlebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .titlebar
        view.blendingMode = .withinWindow
        // Dim with the window, the way real window chrome does.
        view.state = .followsWindowActiveState
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// A soft top edge for a scroll area that AppKit, not SwiftUI, owns.
///
/// The task column gets this from the system — `scrollEdgeEffectStyle(.soft, for: .top)` on a SwiftUI
/// `ScrollView` (see `SoftScrollEdges`). The note takeover can't: its content is an `NSTextView` in an
/// `NSScrollView`, and AppKit's form of the effect (`NSScrollEdgeEffectStyle`) is offered only to
/// titlebar and split-view accessories, never to a scroll view you hold yourself.
///
/// So: the window's own background, faded out down the strip. Nothing more. This started as
/// `TitlebarMaterial` under the same fade, which was wrong twice over — the material is *lighter* than
/// the window background, so instead of disappearing it painted a pale band across the top of the
/// takeover, and the pills standing on it put a second material inside the first. Window background is
/// exactly what's behind the prose (the text view draws none of its own), so this is invisible at rest
/// and does its only job — hiding text that scrolls up into the header — without announcing itself.
///
/// The far stop is the same colour at zero alpha rather than `.clear`, which in a gradient interpolates
/// through transparent *black* and leaves a dark bloom halfway down.
///
/// Sized by the header, and so measured by it: the strip this fills is exactly `barHeight`, which is
/// what the editor takes as its text-container inset. The fade happens inside that height rather than
/// hanging below it, or the prose would start further down than the chrome actually reaches.
private struct SoftHeaderScrim: View {
    private var ground: Color { Color(nsColor: .windowBackgroundColor) }

    var body: some View {
        LinearGradient(
            stops: [
                .init(color: ground, location: 0),
                .init(color: ground, location: 0.55),
                .init(color: ground.opacity(0), location: 1),
            ],
            startPoint: .top, endPoint: .bottom)
    }
}

/// Applies the soft scroll-edge effect so scrolling content fades off the window's edges rather than
/// hard-clipping.
///
/// Both edges now. The top used to be suppressed because the header carried a full-width material and
/// two blurs stacked in one band read muddier than either alone. The header is floating glass now — a
/// pill and a capsule with open window between them — so the top edge is the only thing standing
/// between a task row and the traffic lights, and it's the treatment the system uses for exactly this.
private struct SoftScrollEdges: ViewModifier {
    func body(content: Content) -> some View {
        content
            .scrollEdgeEffectStyle(.soft, for: .top)
            .scrollEdgeEffectStyle(.soft, for: .bottom)
    }
}

// MARK: Task row

private struct TaskRow: View {
    let todo: Todo
    @ObservedObject var store: PMStore
    @Binding var activeEditor: EditorTarget?
    /// The key of the subtree being dragged (nil when no drag is active), set on this row's drag start.
    @Binding var draggingKey: String?
    /// True while this row belongs to the subtree currently being dragged, so it dims in place under
    /// the floating ghost.
    var dimmed: Bool = false
    /// Extra indent levels applied because an ancestor is being wrapped and this row is in its
    /// cascading subtree. 0 for the wrap target itself (it uses `isWrapping`) and for unrelated rows.
    var ancestorWrapBoost: Int = 0
    /// Whether this row is in the selection, and whether that selection is in the pane holding
    /// keyboard focus (which is what makes it read emphasized rather than muted).
    var isSelected: Bool = false
    var isEmphasized: Bool = false
    /// A click on the row, with the modifiers that were down — the parent turns those into plain /
    /// extend / toggle selection.
    var onClick: (NSEvent.ModifierFlags) -> Void = { _ in }
    /// Double-click: activate the row, i.e. make this the project's focused task.
    var onActivate: () -> Void = {}
    /// The tasks a context-menu command should apply to — the whole selection when this row is part
    /// of it, else just this row (which the parent also selects, Finder-style).
    var contextTargets: () -> [Todo] = { [] }
    /// The pointer entering or leaving this row. The list notes which row it's over so a right-click
    /// can move the highlight there before the menu opens — see `ProjectView.selectForContextMenu`.
    var onHoverChanged: (Bool) -> Void = { _ in }
    /// The pasteboard payload for a drag starting on this row.
    var dragProvider: () -> NSItemProvider = { NSItemProvider() }
    var onDelete: ([Todo]) -> Void = { _ in }
    /// Commit the row's due editor. Routed through the parent so a date set on a row inside a
    /// multi-selection lands on the whole selection, like the context menu's version.
    var onSetDue: (String?) -> Void = { _ in }
    /// Commit one task from this row's add editor. Routed through the parent because what happens
    /// *after* a commit — advancing the anchor so the next task lands below this one — is a decision
    /// about the whole list, not about this row. See `ProjectView.commitAdd`.
    var onAddTask: (String, String?) -> Void = { _, _ in }
    @State private var hovering = false
    /// Where a freshly-opened add editor will put its task (set by the plus button and the context
    /// menu's Add actions before opening the editor). The window owns it — see `ProjectView`.
    @Binding var addPosition: TaskInsertPosition

    private var key: String { PMStore.key(for: todo) }
    private var isAdding: Bool { activeEditor == EditorTarget(key: key, kind: .add) }
    private var isEditingDue: Bool { activeEditor == EditorTarget(key: key, kind: .due) }
    private var isEditingText: Bool { activeEditor == EditorTarget(key: key, kind: .edit) }
    private var isWrapping: Bool { activeEditor == EditorTarget(key: key, kind: .wrap) }
    /// Hover-revealed controls (plus, "＋date") are suppressed while any editor is open, so the window
    /// stays calm in edit mode instead of flashing affordances as the pointer crosses rows.
    private var revealControls: Bool { hovering && activeEditor == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Forms whose new row lands ABOVE this one: wrap (the new parent) and Add Before.
            if isWrapping {
                InlineTextEditor(placeholder: "New parent task", submitLabel: "Wrap",
                                 leadingIcon: AnyView(TaskStatusIcon())) { text in
                    store.wrap(todo, parentText: text)
                    activeEditor = nil
                } onCancel: { activeEditor = nil }
                    .reportEditorFrame()
                    .padding(.leading, indent(todo.depth))
            }
            if isAdding && addPosition == .before {
                addEditor.padding(.leading, indent(todo.depth))
            }

            // The task line itself — or, while editing its text, an in-place editor. Wrapping nudges
            // the row one level deeper so it visibly nests under the parent-to-be above it.
            if isEditingText {
                InlineTextEditor(seed: todo.text, placeholder: "Task text", submitLabel: "Save",
                                 leadingIcon: AnyView(TaskStatusIcon(checked: todo.checked))) { text in
                    store.editText(todo, text: text)
                    activeEditor = nil
                } onCancel: { activeEditor = nil }
                    .reportEditorFrame()
                    .padding(.leading, indent(todo.depth))
            } else {
                taskLine
                    .padding(.leading, indent(todo.depth + ancestorWrapBoost + (isWrapping ? 1 : 0)))
                    // The row's breathing room lives *inside* the published frame so adjacent rows tile
                    // edge-to-edge and the gaps the drop delegate computes abut with no dead bands.
                    .padding(.vertical, 3)
                    .background(GeometryReader { g in
                        let f = g.frame(in: .named(TaskDropResolver.coordinateSpace))
                        Color.clear.preference(key: RowFramesKey.self, value: [RowFrame(
                            key: key, session: todo.sessionIndex, line: todo.lineIndex,
                            depth: todo.depth, minY: f.minY, maxY: f.maxY)])
                    })
                    // Carve the row out of the window-drag region so the mouse-drag starts an item
                    // reorder rather than moving the window.
                    .background(WindowDragExcluder())
                    .contentShape(Rectangle())
                    // Dragging is off while any editor is open, so the list stays calm in edit mode. No
                    // custom preview: the default snapshot lifts the ghost from the row's real frame. The
                    // dim `.opacity` is applied *after* `.onDrag`, so the snapshot stays full-opacity.
                    .ifCondition(activeEditor == nil) { view in
                        view.onDrag {
                            let k = key
                            draggingKey = k
                            // Carries the app's private task keys (what the list's own drop reads) and
                            // the tasks as markdown (what every other app gets) — see TaskPasteboard.
                            let provider = dragProvider()
                            // A real drag's end (drop OR cancel-outside) releases the provider, deallocating
                            // this sentinel, which clears the drag key. (A no-move press is caught instead by
                            // the leftMouseUp monitor.)
                            let sentinel = DragEndSentinel { [dragging = $draggingKey] in
                                if dragging.wrappedValue == k { dragging.wrappedValue = nil }
                            }
                            objc_setAssociatedObject(provider, &TaskRow.dragSentinelKey,
                                                     sentinel, .OBJC_ASSOCIATION_RETAIN)
                            return provider
                        }
                    }
                    // Dim the dragged subtree in place under the floating ghost.
                    .opacity(dimmed ? 0.35 : 1)
                    .animation(.easeOut(duration: 0.15), value: dimmed)
            }

            // Forms whose row/edit lands BELOW this one: due edit, Add After (sibling), Add Subtask
            // (one level deeper).
            if isEditingDue {
                DueEditor(seed: dueSeed, leadingIcon: AnyView(TaskStatusIcon(checked: todo.checked))) { newDue in
                    onSetDue(newDue)
                    activeEditor = nil
                } onCancel: { activeEditor = nil }
                    .reportEditorFrame()
                    .padding(.leading, indent(todo.depth))
            }
            if isAdding && (addPosition == .after || addPosition == .child) {
                addEditor.padding(.leading, indent(todo.depth + (addPosition == .child ? 1 : 0)))
            }
        }
        .padding(.horizontal, 12)
        // The click target is the whole row band — the padding above included — and not the task line
        // inside it. It has to be exactly what `selectionBand` paints and what `onHover` lights up: the
        // window's blank space carries a double-click of its own (add a task), so a target that stopped
        // at the line's edge handed every click in the row's own margins to the task list. Same rule as
        // the details brief below, reached the same way.
        //
        // Only while this row has no editor open, because then the band is clear and the block holds a
        // text field the container's gestures would fight. (`localEditorKind` nil means every editor
        // branch above is false, so there is nothing in here but the task line.)
        .ifCondition(localEditorKind == nil) { view in
            view.contentShape(Rectangle())
                // Double-click activates (focuses) the task; a single click selects it. The two-count
                // gesture is declared first so SwiftUI can let it win the race.
                .onTapGesture(count: 2, perform: onActivate)
                .onTapGesture { onClick(NSEvent.modifierFlags) }
                .contextMenu {
                    TaskMenu(todo: todo, targets: contextTargets(), store: store,
                             openEditor: openEditor, openAdd: openAdd, onDelete: onDelete)
                }
                // Selection lives on the row, so the row has to report it: VoiceOver reads the task
                // with its state, and the gestures it can't perform (double-click to focus, ⌫ to
                // delete) are offered as named actions.
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .accessibilityAction(named: "Focus Task", onActivate)
                .accessibilityAction(named: "Delete Task") { onDelete(contextTargets()) }
        }
        // The selection band spans the full row width, outside the depth indent — a row's highlight
        // shouldn't step in as it nests, any more than a table row's does.
        .background(selectionBand)
        .background(scrollMarker)
        .onHover { hovering = $0; onHoverChanged($0) }
        .animation(.snappy, value: localEditorKind)
        .animation(.snappy, value: ancestorWrapBoost)
    }

    /// The row's fill. Suppressed while this row has an editor open, where the form is the subject,
    /// not the row.
    @ViewBuilder private var selectionBand: some View {
        if localEditorKind != nil {
            Color.clear
        } else {
            RowSelectionBand(isSelected: isSelected, isEmphasized: isEmphasized,
                             isHovering: hovering && activeEditor == nil)
        }
    }

    /// A zero-size view carrying this row's key as a scroll id, so keyboard navigation can reveal the
    /// row. It rides in the *background* deliberately: putting `.id()` on the row itself would
    /// override the identity `ForEach` assigns it (see `ProjectView.identifiedTodos`) and undo the
    /// stable-across-reindex row animations.
    private var scrollMarker: some View {
        Color.clear.frame(width: 0, height: 0).id(key)
    }

    /// Leading inset for a row at the given nesting depth (matches the task line's own indent step).
    private func indent(_ depth: Int) -> CGFloat { CGFloat(depth) * 16 }

    /// This row's open-editor kind, if the active editor belongs to it — drives the layout animation.
    private var localEditorKind: EditorTarget.Kind? {
        activeEditor?.key == key ? activeEditor?.kind : nil
    }

    private var taskLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Button(action: { store.toggle(todo) }) {
                Image(systemName: todo.checked ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(todo.checked ? Color.accentColor : Color.secondary)
                    .symbolReplaceIfAvailable()
                    .bounceIfAvailable(todo.checked)
            }
            .buttonStyle(.plain)

            // No tap handler of its own: clicking anywhere in the row selects it and double-clicking
            // focuses the task, both handled at the row level so the whole band is one target.
            // No line limit. A task is a sentence someone wrote, and the two-line cap silently ate the
            // end of the long ones — which are exactly the tasks whose ends matter, since that's where
            // the qualifier usually is. Rows are variable-height already (editors open inside them),
            // and `RowFrame` measures the frame rather than assuming a row height, so the drag/drop
            // geometry follows a wrapped row without being told.
            Text(todo.text)
                .font(.system(size: 13, weight: todo.isFocused ? .semibold : .regular))
                .strikethrough(todo.checked, color: .secondary)
                .foregroundStyle(todo.checked ? .secondary : .primary)
                // Wrap rather than compress: in an `HStack` a `Text` will squeeze itself to one
                // truncated line before it asks for a second one.
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 4)

            DueChip(todo: todo, isEditing: isEditingDue, reveal: revealControls,
                    onPick: onSetDue, onPickCustom: { toggleEditor(.due) })

            Button {
                addPosition = .child
                toggleEditor(.add)
            } label: {
                Image(systemName: "plus")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Add subtask")
            .opacity(revealControls || isAdding ? 1 : 0)
        }
    }

    /// The positional add editor. Its slot and indent are chosen by `addPosition`, so the form previews
    /// exactly where the new task will land. Committing doesn't close it — the parent moves it down to
    /// the next slot so a list can be typed straight through.
    private var addEditor: some View {
        AddEditor(leadingIcon: AnyView(TaskStatusIcon()), onAdd: onAddTask,
                  onCancel: { activeEditor = nil })
            .reportEditorFrame()
    }

    /// First 10 chars of own-or-inherited due, if they look like YYYY-MM-DD (for the date picker seed).
    private var dueSeed: String {
        let raw = todo.dueDate ?? todo.effectiveDueDate ?? ""
        return String(raw.prefix(10))
    }

    private func toggleEditor(_ kind: EditorTarget.Kind) {
        let target = EditorTarget(key: key, kind: kind)
        activeEditor = (activeEditor == target) ? nil : target
    }

    /// Open (never toggle) a given editor on this row — used by the context menu.
    private func openEditor(_ kind: EditorTarget.Kind) {
        activeEditor = EditorTarget(key: key, kind: kind)
    }

    /// Seed the add position, then open the add editor.
    private func openAdd(_ position: TaskInsertPosition) {
        addPosition = position
        openEditor(.add)
    }

    /// Associated-object key holding a drag's end sentinel on its item provider (see `.onDrag`).
    static var dragSentinelKey: UInt8 = 0
}

/// Clears drag state when a drag session ends. Held as an associated object on the drag's item
/// provider, so its `deinit` runs when the session releases the provider — on a drop *or* a cancel,
/// the end signal SwiftUI's `.onDrag` doesn't otherwise give us.
private final class DragEndSentinel {
    private let onEnd: () -> Void
    init(onEnd: @escaping () -> Void) { self.onEnd = onEnd }
    deinit {
        let onEnd = self.onEnd
        DispatchQueue.main.async(execute: onEnd)
    }
}

// MARK: Due chip + editor

/// How loud a due badge is, by how late it is.
///
/// The scale the sidebar and menubar already keep (`DueState`), spent on more than colour. The row's
/// badge used to be one orange for every own date, which meant "2w ago" and "in 3mo" arrived with
/// identical weight — the text said *when* while the styling implied they mattered the same amount.
/// Now overdue is filled and semibold, due-today-or-tomorrow is a tinted outline, and everything
/// further out is a quiet grey one, so the list sorts itself by urgency before it's read.
///
/// The fill matters beyond taste: it's drawn as a shape with an explicit colour, so it survives
/// whatever foreground style the enclosing menu control imposes on its label. Colour on text alone was
/// the part that could be overridden.
///
/// An inherited date takes the dashed border it always had and the colour of its state, but never the
/// fill. It's still someone else's date — worth noticing when the ancestor is overdue, not worth
/// shouting on every descendant of it.
private struct DueChipStyle {
    var text: Color
    var stroke: Color
    var fill: Color
    var weight: Font.Weight
    var dashed: Bool

    init(due: String, own: Bool) {
        let state = DueState(due: due, own: own)
        let tint: Color
        switch state {
        case .overdue: tint = Color(nsColor: .systemRed)
        case .soon: tint = Color(nsColor: .systemOrange)
        case .later, .inherited: tint = .secondary
        }
        text = tint
        stroke = tint
        dashed = !own
        if own, state == .overdue {
            fill = tint.opacity(0.16)
            weight = .semibold
        } else if own, state == .soon {
            fill = tint.opacity(0.10)
            weight = .medium
        } else {
            fill = .clear
            weight = .regular
        }
    }

    private init(text: Color, stroke: Color, fill: Color, weight: Font.Weight, dashed: Bool) {
        self.text = text; self.stroke = stroke; self.fill = fill
        self.weight = weight; self.dashed = dashed
    }

    /// The "＋date" affordance on a task with no date at all — a control, so it stays quiet.
    static let empty = DueChipStyle(text: .secondary, stroke: .secondary, fill: .clear,
                                    weight: .regular, dashed: true)
}

private struct DueChip: View {
    let todo: Todo
    let isEditing: Bool
    /// Reveal the empty-state "＋date" affordance (true while hovering the row). A real own/inherited
    /// date is content, not a control, so it stays visible regardless.
    let reveal: Bool
    /// Apply a due date — nil clears it. Whatever the row's date commands apply to, this applies to.
    let onPick: (String?) -> Void
    /// Open the precise picker, for a date the presets haven't got.
    let onPickCustom: () -> Void

    /// The date this chip is showing, and whether the task owns it or inherited it from an ancestor.
    private var shown: (raw: String, own: Bool)? {
        if let own = todo.dueDate { return (own, true) }
        if let inherited = todo.effectiveDueDate { return (inherited, false) }
        return nil
    }

    private var hasDate: Bool { shown != nil }
    private var showing: Bool { hasDate || reveal || isEditing }

    var body: some View {
        // Always laid out so hovering only toggles opacity, never the row's height. A real own/
        // inherited date is content (always visible); the empty-state "＋date" is a control that
        // fades in on hover/edit but keeps reserving its space.
        Menu {
            menuItems
        } label: {
            if let shown {
                chip(RelativeDue.short(shown.raw), style: DueChipStyle(due: shown.raw, own: shown.own))
            } else {
                chip("＋date", style: .empty)
            }
        }
        // `.button` + `.plain`, not `.borderlessButton`. The borderless style presents the label
        // through a pop-up-button control, which paints it in the control's own label colour — so the
        // chip's whole severity scale collapsed to plain text the moment it stopped being a `Button`.
        // The button style routes the label through `PlainButtonStyle` instead, which renders it as
        // written, exactly as the row's other plain buttons are rendered.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(helpText)
        .opacity(showing ? 1 : 0)
        .allowsHitTesting(showing)
    }

    /// The relative answers first, a calendar for anything else, and a way out.
    ///
    /// A menu, because that's what a chip is on this platform — you click the date pill in Reminders
    /// and get choices, not a stepper. It also puts the editor in the same language as the badge that
    /// opens it: the badge says "in 2w", so the menu says "Next Week", not 09/03/2026.
    ///
    /// Every item routes through `onPick`, which is the row's `onSetDue` — so a date chosen on a row
    /// inside a multi-selection lands on the whole selection, exactly as the context menu's version
    /// does. There's no separate single-row path to fall out of step.
    @ViewBuilder private var menuItems: some View {
        ForEach(DueSuggestion.options()) { option in
            Button { onPick(DueFormat.string(option.date)) } label: {
                Text(option.title) + Text("   \(option.hint)").foregroundStyle(.secondary)
            }
        }
        Divider()
        Button("Pick a Date…", action: onPickCustom)
        if todo.dueDate != nil {
            Divider()
            Button("Clear Due Date") { onPick(nil) }
        }
    }

    /// The tooltip: the exact date the badge is a summary of, plus what clicking does.
    ///
    /// The badge says "in 2w" now, which is faster to read and useless for deciding whether that
    /// clears a deadline — so the date it stands for has to be one hover away. See `RelativeDue.full`.
    private var helpText: String {
        if let own = todo.dueDate {
            return "Due \(RelativeDue.full(own))  ·  click to edit"
        }
        if let eff = todo.effectiveDueDate {
            return "Inherited due \(RelativeDue.full(eff))  ·  click to set this task's own"
        }
        return "Set due date"
    }

    private func chip(_ text: String, style: DueChipStyle) -> some View {
        Text(text)
            .font(.caption2.weight(style.weight))
            // A relative badge rewrites itself as the days tick down, and "in 2d" → "in 3d" shouldn't
            // shift the row's layout to do it.
            .monospacedDigit()
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(style.fill))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(style.stroke,
                                  style: StrokeStyle(lineWidth: 1, dash: style.dashed ? [3] : []))
            )
            .foregroundStyle(style.text)
    }
}

// MARK: Session header + note editor

/// A revealed session's first-class row: its date/label line, its leading-prose note when it has one,
/// and a context menu for renaming, adding a note/task, and deleting an empty session. It selects and
/// draws its highlight exactly as a task row does, so ⌘N, Return and the arrow keys can reach it.
///
/// **Double-click opens the note**, on the header line and the prose alike. It used to rename on the
/// header line and edit the note on the prose — one gesture, two meanings, decided by which line of the
/// block you happened to hit, and with no target at all until the note existed. The note is what a
/// session is for; the label is optional decoration on a heading that's identified by its date, so it
/// hands the big gesture over and is renamed from the menu or from inside the note editor.
///
/// Publishes no `RowFrame`, so it doesn't participate in the task drag-reorder geometry.
private struct SessionHeader: View {
    let index: Int
    let session: Session
    @ObservedObject var store: PMStore
    @Binding var activeEditor: EditorTarget?
    /// Whether this row is in the selection, and whether that selection is in the pane holding
    /// keyboard focus — the same pair `TaskRow` takes, drawing the same three-state band.
    var isSelected: Bool = false
    var isEmphasized: Bool = false
    /// A click on the row, with the modifiers that were down.
    var onClick: (NSEvent.ModifierFlags) -> Void = { _ in }
    /// Double-click: open this session's note.
    var onActivate: () -> Void = {}
    @State private var hovering = false

    private var key: String { ProjectView.sessionKey(index) }
    private var isRenaming: Bool { activeEditor == EditorTarget(key: key, kind: .sessionLabel) }
    /// The session's editable note — its leading prose (lines before the first task), trimmed.
    private var prose: String { leadingSessionProse(body: session.body) }

    /// The reading face for the rendered note: the editor's own face, at the editor's own size.
    ///
    /// Literally the same font object, because the seam worth removing here is the one between reading
    /// a note and editing it. It used to be the 13pt system face while the editor was 14pt system, so
    /// opening a note re-set it and re-wrapped it — the note you were looking at was not the note you
    /// got. A session note is still working text read alongside the task rows rather than the
    /// printed-brief serif of the project details; it just happens that the editor's monospaced face is
    /// what it should have been all along, and sharing it costs nothing.
    private static let noteFont = MarkdownTextEditor.baseFont
    private var context: String { session.label.isEmpty ? session.date : "\(session.date) · \(session.label)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if isRenaming {
                InlineTextEditor(seed: session.label, placeholder: "Session label (optional)",
                                 submitLabel: "Rename", allowsEmpty: true) { label in
                    if let ref = activeEditor?.session { store.renameSession(ref, label: label) }
                    activeEditor = nil
                } onCancel: { activeEditor = nil }
                    .reportEditorFrame()
            } else {
                headerLine
            }

            // The note read view, rendering the note's markdown (formatting applied, markers removed)
            // and drawing whatever pictures it embeds. A session with no note draws nothing here — the
            // header line above is the target either way, so there's no placeholder standing in for a
            // note that isn't written yet.
            if !prose.isEmpty {
                RenderedNote(prose: prose, font: Self.noteFont,
                             noteURL: store.notesPath.map { URL(fileURLWithPath: $0) })
            }
        }
        .padding(.horizontal, 12)
        // Even above and below: this padding is inside the band, so the highlight has to sit centred on
        // the heading it belongs to. The separation from the session above is applied outside the band,
        // at the end of this chain.
        .padding(.vertical, ProjectView.sessionHeadingPadding)
        // One target for the whole block — header line, note, and the padding around them — rather
        // than a gesture per line inside it. The padding was dead space when the gestures sat on the
        // content: the band lit up under the pointer and the double-click fell straight through to the
        // scroll view's "add a task to today", which is a hit area smaller than its own highlight.
        //
        // Applied outside the padding and before the band, so what you can click and what lights up are
        // the same rectangle by construction.
        // Not while renaming: the block holds a text field then, and a container gesture over it would
        // fight the clicks that place the caret.
        .ifCondition(!isRenaming) { view in
            view.contentShape(Rectangle())
                // Declared before the single click so SwiftUI can let the two-count gesture win the
                // race, exactly as a task row does it.
                .onTapGesture(count: 2, perform: onActivate)
                .onTapGesture { onClick(NSEvent.modifierFlags) }
                .contextMenu { menu }
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .accessibilityAction(named: "Open Session Note", onActivate)
        }
        // The band spans the whole session block — header line and note together, since they're one
        // row. Suppressed while the rename editor is up, where the form is the subject.
        .background(RowSelectionBand(isSelected: isSelected && !isRenaming,
                                     isEmphasized: isEmphasized,
                                     isHovering: hovering && activeEditor == nil))
        .background(scrollMarker)
        .onHover { hovering = $0 }
        .animation(.snappy, value: isRenaming)
        // The gap between this session and the one above it — outside the band and outside the hit
        // shape, so it's blank space between two blocks rather than a lopsided cushion on top of this
        // one. It's bigger than the heading's own padding, which is what keeps a heading reading as
        // the start of the tasks below it.
        .padding(.top, ProjectView.sessionGap)
        // Measured with the gap inside it, unlike the band: a drop on a session with no tasks has this
        // block as its whole target, and a bare heading is a thin one to hit. The blank strip above a
        // heading belongs to the session it introduces anyway.
        .background(SessionFrameReporter(index: index))
    }

    private var headerLine: some View {
        HStack(spacing: 6) {
            Text(context)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
        }
    }

    private var menu: some View {
        SessionMenu(index: index, hasNote: !prose.isEmpty, store: store, activeEditor: $activeEditor)
    }

    /// This row's key as a scroll id, so arrow-key navigation can reveal a header that's scrolled out
    /// of view. In the background for the same reason `TaskRow`'s is.
    private var scrollMarker: some View {
        Color.clear.frame(width: 0, height: 0).id(key)
    }
}

/// A session's context menu: rename, its note, add a task, and delete for a session with nothing in it.
/// Shared by the revealed header and the compact list's caption, so a session offers the same things
/// whichever view you're in — and so the things that lost their buttons keep a discoverable home.
private struct SessionMenu: View {
    let index: Int
    let hasNote: Bool
    @ObservedObject var store: PMStore
    @Binding var activeEditor: EditorTarget?

    private var key: String { ProjectView.sessionKey(index) }

    var body: some View {
        Button {
            activeEditor = EditorTarget(key: key, kind: .sessionNote, session: store.sessionRef(at: index))
        } label: {
            Label(hasNote ? "Edit Note…" : "Add Note…", systemImage: "note.text")
        }
        Button {
            activeEditor = EditorTarget(key: key, kind: .sessionAddTask, session: store.sessionRef(at: index))
        } label: {
            Label("Add Task…", systemImage: "plus")
        }
        Button {
            activeEditor = EditorTarget(key: key, kind: .sessionLabel, session: store.sessionRef(at: index))
        } label: {
            Label("Rename Session…", systemImage: "pencil")
        }
        // Deleting is offered only for a session with no tasks, so tasks are never removed with it.
        if !store.hasTasks(sessionIndex: index) {
            Divider()
            Button(role: .destructive) {
                if let ref = store.sessionRef(at: index) { store.deleteSession(ref) }
            } label: {
                Label("Delete Session", systemImage: "trash")
            }
        }
    }
}

/// The full-column, focused editor for a session's prose note. The column is taken over by a header
/// (Back button + the project name over the session's date and label) and a rich `MarkdownTextEditor`
/// with live syntax highlighting and ⌘B/⌘I/⌘K shortcuts. There are no Save/Cancel buttons: the note
/// **auto-saves** whenever you leave — Back, Escape, an outside click (all remove the view →
/// `onDisappear`), or the window losing key focus (`didResignKey`). `store.setSessionNote` is
/// byte-idempotent, so a repeated commit with no changes is a free no-op and yields no extra undo entry.
///
/// The label is edited here, in the header, rather than behind a gesture out in the list. This is where
/// you already are when you're working on a session, it's the one place the label is shown next to the
/// date it decorates, and it means the list doesn't need a second double-click meaning of its own.
private struct SessionNoteTakeover: View {
    let index: Int
    let session: Session
    let projectName: String
    @ObservedObject var store: PMStore
    /// Only for the titlebar clearance — this header stands in the same strip as the task list's, under
    /// the same traffic lights, so it insets itself from the same measurements.
    let state: ProjectViewState
    let onBack: () -> Void

    @State private var text: String
    /// The prose this takeover opened with, and the identity of the session it opened *on*.
    ///
    /// Both are `@State` captured at init, deliberately, because `session` is not: SwiftUI rebuilds
    /// this struct from the store on every change, so by the time the editor closes `session` is
    /// whatever now sits at `index` — which is not necessarily what was being edited. A note written
    /// from the quick bar can start a new session and insert it above this one, and then `index` names
    /// a different sitting than it did a moment ago.
    ///
    /// That is not hypothetical: it silently destroyed a note. The takeover auto-saves on the way out,
    /// the way out fired after a quick-bar note had inserted a new session at index 0, and this view
    /// wrote its untouched copy of the *previous* session's prose over the note that had just been
    /// written into the new one.
    @State private var seed: String
    @State private var seedLabel: String
    /// Which session this was opened on, by `SessionRef` rather than by `index`.
    @State private var ref: SessionRef
    /// The session's label, as typed. Committed on Return and on the way out, beside the prose.
    @State private var label: String
    /// Whether the pointer is over the label field, which is how a plain-looking line of header text
    /// says it's editable.
    @State private var labelHovering = false
    /// The window this takeover is in, so the save-on-blur only fires for *this* window losing key.
    @State private var hostWindow: NSWindow?
    /// The bar's measured height, fed to the editor as its text-container top inset.
    @State private var barHeight: CGFloat = 0
    /// Whether the pointer is in the header strip, and whether this window is the active one — the two
    /// inputs to `HeaderChrome`, exactly as in the task column's header.
    @State private var headerHovering = false
    @Environment(\.controlActiveState) private var controlActiveState

    init(index: Int, session: Session, projectName: String,
         store: PMStore, state: ProjectViewState, onBack: @escaping () -> Void) {
        self.index = index
        self.session = session
        self.projectName = projectName
        self.store = store
        self.state = state
        self.onBack = onBack
        _text = State(initialValue: leadingSessionProse(body: session.body))
        _label = State(initialValue: session.label)
        _seed = State(initialValue: leadingSessionProse(body: session.body))
        _seedLabel = State(initialValue: session.label)
        _ref = State(initialValue: store.sessionRef(at: index)
            ?? SessionRef(index: index, digest: sessionDigest(session.label)))
    }

    var body: some View {
        // The header stands over the editor rather than stacking above it, and the editor takes its
        // height as a text-container inset. That's the same arrangement the task list gets from
        // `safeAreaInset`, reached differently because this content is an `NSTextView` in an
        // `NSScrollView` rather than a SwiftUI `ScrollView`. Stacked, the prose stopped at the divider
        // and the material had nothing but window background behind it — a bar in name only.
        //
        // A `ZStack` and not `.overlay`, because the header's measured height has to reach the editor
        // and siblings in a stack propagate their preferences to the stack's parent beyond any doubt.
        // Read off an overlay it never arrived, leaving `barHeight` at zero and the first lines of the
        // note underneath the bar.
        ZStack(alignment: .top) {
            // ⌘↩ → auto-saves. The note's own file goes in so a dropped file can be linked relative to
            // it and a relative link can be followed back out of it.
            MarkdownTextEditor(text: $text, onSubmit: onBack,
                               placeholder: "Write a note…",
                               noteURL: store.notesPath.map { URL(fileURLWithPath: $0) },
                               opensAtStart: true,
                               topInset: barHeight)
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
                // Prose wants the readable cap as much as the task rows do; it used to inherit it from
                // a frame around the whole column. Its own cap rather than the general one: a note is
                // set in a fixed-advance face, so its comfortable width is a character count and can be
                // stated as one. See `MarkdownTextEditor.measureWidth`.
                .modifier(ReadableWidth(cap: MarkdownTextEditor.measureWidth))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            // Same chrome as the task list's header — this stands in the same titlebar strip, so it
            // floats the same way: a back button and an identity pill in glass, over a scrim that
            // fades out rather than a bar that ends in a rule. Cap inside the scrim, as there: the
            // title stays at the width of the prose it heads, the scrim spans the pane.
            header
                .modifier(ReadableWidth(cap: MarkdownTextEditor.measureWidth))
                .background(SoftHeaderScrim())
                .background(GeometryReader { geo in
                    Color.clear.preference(key: BarHeightKey.self, value: geo.size.height)
                })
        }
        .onPreferenceChange(BarHeightKey.self) { barHeight = $0 }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Fill the window. The takeover used to negotiate a height with a window that sized itself to
        // its content; a real window's height is the user's, so the editor takes what it's given.
        .frame(maxHeight: .infinity)
        // Cover the whole takeover as the "active editor" region so in-window clicks count as inside it.
        .reportEditorFrame()
        // Auto-save on every way out: Back / Escape / outside-click remove the view (onDisappear); a
        // blur-hide leaves the view mounted but resigns key.
        .onDisappear { commit() }
        .background(WindowAccessor { hostWindow = $0 })
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { note in
            if let hostWindow, (note.object as? NSWindow) === hostWindow { commit() }
        }
    }

    /// The takeover's header: a back button in its own glass circle, then the identity pill — the
    /// project's name over the session it belongs to.
    ///
    /// This is the closest thing in the app to the Messages conversation header it's modelled on, and
    /// it's where the two-line "name over detail" pill finally earns its second line: out in the task
    /// column the project's name stands alone, but here the note needs saying *which* session it is,
    /// and the date is the only thing that answers that.
    private var header: some View {
        HStack(spacing: 8) {
            backButton
            identityPill
            Spacer(minLength: 12)
        }
        .opacity(chrome.contentOpacity)
        .modifier(TitlebarClearance(state: state, bottom: 8))
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.18)) { headerHovering = hovering }
        }
        .animation(.easeOut(duration: 0.18), value: controlActiveState)
    }

    /// What this header's glass is doing right now — the same three states the task column uses.
    private var chrome: HeaderChrome {
        HeaderChrome(active: controlActiveState, hovering: headerHovering)
    }

    /// Back to the task list. Its own circle of glass at the leading edge, separate from the pill, the
    /// way Messages keeps its leading button apart from the name it sits beside — this is an action,
    /// and the pill is a label.
    private var backButton: some View {
        Button(action: onBack) {
            Image(systemName: "chevron.left")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(4)
        .headerBacking(chrome, in: Circle())
        .background(WindowDragExcluder())
        .help("Back to tasks")
    }

    /// The project's name over the session's date and label.
    ///
    /// No gesture of its own, because it holds a text field: the label is edited in place here. A
    /// pill that responded to a press would be promising one to something whose actual job is to take
    /// a caret.
    private var identityPill: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(projectName.isEmpty ? "Note" : projectName)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.tail)
            sessionLine
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .headerBacking(chrome, in: Capsule())
        .background(WindowDragExcluder())
    }

    /// The session's identity line under the project name: its date, fixed, and its label, editable in
    /// place. The field is plain until the pointer is over it — a bordered box in a titlebar strip would
    /// read as a form where this is a title.
    private var sessionLine: some View {
        HStack(spacing: 4) {
            Text(session.date)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            labelField
        }
    }

    /// The label field, sized to its own text rather than to whatever width is going spare.
    ///
    /// A `TextField` takes every point it is offered. Inside a pill whose whole job is to hug its
    /// contents that meant the pill stretched most of the way across the window — the field's old
    /// `maxWidth: 240` was a cap on the damage, not a fix, because a flexible frame still claims the
    /// width it's proposed. The hidden `Text` behind it is a width template instead: the label when
    /// there is one, the placeholder when there isn't. The stack sizes to the template, which is
    /// ordinary text and asks for exactly what it needs, and the field fills it — so the field is as
    /// wide as what it's showing and grows a character at a time as you type.
    ///
    /// The trailing padding is caret room. Sized to the glyphs alone, the insertion point at the end
    /// of the text sits on the field's last pixel.
    ///
    /// `.overlay`, not a `ZStack`. A stack sizes to its largest child and the field is still a child,
    /// so it claimed the full proposal and took the stack with it — the template was along for the ride
    /// rather than setting the width. Overlay content doesn't participate in layout at all: the hidden
    /// `Text` alone decides the size, and the field is handed exactly that.
    private var labelField: some View {
        Text(label.isEmpty ? "Add a label" : label)
            .font(.caption)
            .lineLimit(1)
            .hidden()
            .overlay(alignment: .leading) {
                TextField("Add a label", text: $label)
                    .textFieldStyle(.plain)
                    .font(.caption)
                    .lineLimit(1)
                    // Return in the label field renames the session it was opened on, resolved the
                    // same way the note's own save resolves it.
                    .onSubmit { commitLabel() }
            }
        .padding(.leading, 4)
        .padding(.trailing, 8)
        .padding(.vertical, 1)
        .background(RoundedRectangle(cornerRadius: 4)
            .fill(Color.primary.opacity(labelHovering ? 0.07 : 0)))
        .onHover { labelHovering = $0 }
        .help("Session label")
        .background(WindowDragExcluder())
    }

    /// Write the current text back to the session's note. The store sanitizes it (headings clamp to
    /// within-session levels; typed checkboxes graduate into real tasks), so we adopt the same cleaned
    /// prose locally — that drops the graduated checkboxes from the editor and makes repeated commits
    /// (this fires from several exit paths) byte-idempotent instead of re-extracting the same tasks.
    ///
    /// The label rides along: it's edited in the same view and leaves by the same exits, and the store's
    /// serial IO queue keeps the two writes in order — the heading rewrite preserves the body and the
    /// body rewrite preserves the heading, so neither can land on top of the other.
    /// Save on the way out — but only what was actually changed, and only into the session this was
    /// opened on.
    ///
    /// Both guards matter, and neither substitutes for the other. Writing nothing when nothing was
    /// typed is what stops an editor that was merely opened and closed from overwriting whatever
    /// arrived while it was up; the idempotence this used to lean on only holds while the document
    /// underneath is unchanged, which is exactly the case that goes wrong. And `ref` names the sitting
    /// by date and label rather than by the index it had on the way in, so a real edit can't land in a
    /// session that has since moved into that position. A reference that can no longer be resolved
    /// refuses the write rather than guessing — see `resolveSessionRef`.
    ///
    /// The note goes first and the label second, deliberately: the reference asserts the label it was
    /// made with, so renaming before writing would invalidate it for the write that follows.
    private func commit() {
        if text != seed {
            let cleaned = sanitizeSessionNoteProse(text).prose
            store.setSessionNote(ref, prose: text)
            // After the sanitizer's rewrite, not before: the seed has to be what the editor is now
            // holding, or the next commit sees a difference that is only this one's own tidying.
            if cleaned != text { text = cleaned }
            seed = text
        }
        commitLabel()
    }

    private func commitLabel() {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        // Against the label this opened with, not `session`'s — see `seed` for why the two differ.
        guard trimmed != seedLabel else { return }
        store.renameSession(ref, label: trimmed)
        seedLabel = trimmed
        // The reference asserted the old label; after the rename it has to describe the session as it
        // now is, or a second commit from this same editor would be refused as stale.
        ref.digest = sessionDigest(trimmed)
    }
}

// MARK: Project details

private struct ProjectDetailsView: View {
    let notes: ProjectNotes?
    @ObservedObject var store: PMStore
    @Binding var isEditing: Bool

    var body: some View {
        if let n = notes {
            Group {
                if isEditing {
                    DetailsEditor(notes: n, kind: store.kind) { edited in
                        // Merge the edited detail fields (including links) onto freshly-parsed notes,
                        // leaving title and sessions untouched.
                        store.saveDetails { fresh in
                            var out = fresh
                            out.summary = edited.summary
                            out.problem = edited.problem
                            out.goals = edited.goals
                            out.approach = edited.approach
                            out.links = edited.links
                            out.learnings = edited.learnings
                            return out
                        }
                        isEditing = false
                    } onCancel: {
                        isEditing = false
                    }
                    .reportEditorFrame()
                } else {
                    Group {
                        if hasAnyDetail(n) {
                            readContent(n)
                        } else {
                            placeholderContent
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            // Double-click anywhere in the details band switches to edit mode — including the empty
            // placeholders, so a project with no details yet can gain them right here.
            //
            // The whole band, padding and all, rather than just the content it wraps: the window's
            // blank space carries a double-click of its own (add a task), so a target that stopped at
            // the text's edge would hand clicks in the details' own margins to the task list.
            .ifCondition(!isEditing) { view in
                view.contentShape(Rectangle())
                    .onTapGesture(count: 2) { isEditing = true }
            }
        }
    }

    /// True when any detail block would render. When false (and not editing), the section shows empty
    /// placeholders instead of nothing, so a project with no details can still be given them here.
    private func hasAnyDetail(_ n: ProjectNotes) -> Bool {
        !n.summary.isBlank || !n.problem.isBlank
            || n.goals.contains { !$0.isBlank }
            || !n.approach.isBlank
            || n.links.contains { ($0.label ?? "").isEmpty == false || ($0.url ?? "").isEmpty == false }
            || n.learnings.contains { !$0.isBlank }
    }

    /// The empty state: one quiet placeholder per editable section, so opening details on a project
    /// with none reveals what a brief can hold and gives the double-click-to-edit gesture a target.
    private var placeholderContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(["Summary", "Problem", "Goals", "Approach", "Links", "Learnings"], id: \.self) { title in
                VStack(alignment: .leading, spacing: 4) {
                    Eyebrow(title)
                    Text("Add \(title.lowercased())…")
                        .font(Self.bodyFont)
                        .foregroundStyle(.quaternary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // A typographic treatment: the details read like a printed project brief — a serif lead
    // paragraph for the summary, uppercase tracked "eyebrow" labels, and serif body copy — so the
    // persistent project content is visually a different medium from the sans-serif task UI below.

    /// Serif reading face for detail body copy, distinguishing document content from the task UI.
    private static let bodyFont = Font.system(size: 13, design: .serif)

    private func readContent(_ n: ProjectNotes) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            // The summary is the lede: no label, set larger, it opens the brief.
            if !n.summary.isBlank {
                Text(n.summary)
                    .font(.system(size: 15, design: .serif))
                    .foregroundStyle(.primary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            proseBlock("Problem", n.problem)
            numberedBlock("Goals", n.goals)
            proseBlock("Approach", n.approach)
            LinksBlock(links: n.links)
            bulletBlock("Learnings", n.learnings)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func proseBlock(_ title: String, _ body: String) -> some View {
        if !body.isBlank {
            VStack(alignment: .leading, spacing: 4) {
                Eyebrow(title)
                Text(body)
                    .font(Self.bodyFont)
                    .foregroundStyle(.secondary)
                    .lineSpacing(1.5)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private func numberedBlock(_ title: String, _ items: [String]) -> some View {
        let nonEmpty = items.enumerated().filter { !$0.element.isBlank }
        if !nonEmpty.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Eyebrow(title)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(nonEmpty, id: \.offset) { idx, item in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            // Hanging figure: numerals in a fixed-width gutter so the copy aligns.
                            Text("\(idx + 1)")
                                .font(.system(size: 12, weight: .semibold, design: .serif))
                                .foregroundStyle(.tertiary)
                                .monospacedDigit()
                                .frame(width: 14, alignment: .trailing)
                            Text(item)
                                .font(Self.bodyFont)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private func bulletBlock(_ title: String, _ items: [String]) -> some View {
        let nonEmpty = items.filter { !$0.isBlank }
        if !nonEmpty.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Eyebrow(title)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(nonEmpty, id: \.self) { item in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("—").font(Self.bodyFont).foregroundStyle(.tertiary)
                            Text(item)
                                .font(Self.bodyFont)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }
}

/// An editorial section label: uppercase, letter-spaced, tertiary — a quiet "eyebrow" above detail
/// copy. Shared by the read view, the Links block, and the details editor so all three read alike.
private struct Eyebrow: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .textCase(.uppercase)
            .tracking(0.9)
            .foregroundStyle(.tertiary)
    }
}

/// The editable detail fields, gathered on Save. Title and sessions are intentionally left out — the
/// store re-merges these onto freshly-parsed notes so they're preserved untouched. Links are edited
/// here as a flat label/URL list; any nested link groups are preserved verbatim (see `DetailsEditor`).
private struct EditedDetails {
    var summary: String
    var problem: String
    var goals: [String]
    var approach: String
    var links: [LinkEntry]
    var learnings: [String]
}

/// One editable link row (label + URL). Backed by a stable `id` so add/remove keep field focus and
/// SwiftUI diffs the list correctly; converted to/from `LinkEntry` at the editor's edges.
private struct EditableLink: Identifiable {
    let id = UUID()
    var label: String
    var url: String
}

/// Inline edit form for the project-details section. Shows every editable section (Summary, Problem,
/// Goals×3, Approach, Links, Learnings) regardless of whether it currently has content. Seeded from
/// the notes on appear; local `@State` so Cancel is a no-op.
private struct DetailsEditor: View {
    /// Which header fields to offer. The read view already hides a blank section, so it needs no kind;
    /// the editor does, because offering a field is what puts content in it. An Area given a Problem
    /// box would get a Problem — the serializer keeps a section the kind omits precisely when it isn't
    /// empty, so the value would stick, and the one place it could have been refused is here.
    let kind: ProjectKind
    let onSave: (EditedDetails) -> Void
    let onCancel: () -> Void

    @State private var summary: String
    @State private var problem: String
    @State private var goals: [String]        // exactly 3 slots
    @State private var approach: String
    @State private var links: [EditableLink]  // flat label/URL rows (grouped links preserved separately)
    @State private var learningsText: String  // one learning per line
    /// Nested link groups (a label with child URLs) aren't expressible in this compact flat form, so
    /// they're held aside verbatim and re-appended on save — the editor never destroys them.
    private let preservedGroups: [LinkEntry]

    init(notes: ProjectNotes, kind: ProjectKind,
         onSave: @escaping (EditedDetails) -> Void, onCancel: @escaping () -> Void) {
        self.kind = kind
        self.onSave = onSave
        self.onCancel = onCancel
        // Split the stored links: grouped entries are set aside; flat entries seed the editable rows
        // (dropping the empty placeholder entry the model carries when there are no real links).
        self.preservedGroups = notes.links.filter { !($0.children ?? []).isEmpty }
        _links = State(initialValue: notes.links
            .filter { ($0.children ?? []).isEmpty }
            .compactMap { entry in
                let label = (entry.label ?? "").trimmingCharacters(in: .whitespaces)
                let url = (entry.url ?? "").trimmingCharacters(in: .whitespaces)
                return (label.isEmpty && url.isEmpty) ? nil
                    : EditableLink(label: entry.label ?? "", url: entry.url ?? "")
            })
        _summary = State(initialValue: notes.summary)
        _problem = State(initialValue: notes.problem)
        _goals = State(initialValue: Array((notes.goals + ["", "", ""]).prefix(3)))
        _approach = State(initialValue: notes.approach)
        _learningsText = State(initialValue: notes.learnings
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .joined(separator: "\n"))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Walked rather than listed, so the form and the document agree by construction: what an
            // area is written with is exactly what it can be edited with.
            ForEach(kind.headerSections, id: \.self) { section in
                field(section.label) { headerField(section) }
            }
            field("Links") { linksEditor }
            field("Learnings") {
                TextField("One per line", text: $learningsText, axis: .vertical).lineLimit(2...8)
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Save", action: save).keyboardShortcut(.defaultAction)
            }
        }
        .textFieldStyle(.roundedBorder)
        .controlSize(.small)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func headerField(_ section: HeaderSection) -> some View {
        switch section {
        case .summary: TextField("", text: $summary, axis: .vertical).lineLimit(1...5)
        case .problem: TextField("", text: $problem, axis: .vertical).lineLimit(1...5)
        case .approach: TextField("", text: $approach, axis: .vertical).lineLimit(1...5)
        case .goals:
            VStack(alignment: .leading, spacing: 3) {
                ForEach(0..<3, id: \.self) { i in
                    TextField("\(section.label.dropLast()) \(i + 1)", text: $goals[i])
                }
            }
        }
    }

    /// The link rows plus an "Add link" affordance. A short Label field leads a wider URL field, with a
    /// trailing remove control per row — mirroring the Links read view's "label — url" shape.
    private var linksEditor: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach($links) { $link in
                HStack(spacing: 4) {
                    TextField("Label", text: $link.label).frame(width: 90)
                    TextField("URL", text: $link.url)
                    Button {
                        links.removeAll { $0.id == link.id }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Remove link")
                }
            }
            Button {
                links.append(EditableLink(label: "", url: ""))
            } label: {
                Label("Add link", systemImage: "plus.circle").font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
    }

    private func field<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Eyebrow(title)
            content()
        }
    }

    private func save() {
        let learnings = learningsText
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        // Drop blank rows, normalize each into a LinkEntry, then re-append the preserved groups. If the
        // result is empty, fall back to the model's single empty entry (matching a linkless project).
        let flatLinks: [LinkEntry] = links.compactMap { row in
            let label = row.label.trimmingCharacters(in: .whitespaces)
            let url = row.url.trimmingCharacters(in: .whitespaces)
            if label.isEmpty && url.isEmpty { return nil }
            return LinkEntry(label: label.isEmpty ? nil : label, url: url.isEmpty ? nil : url)
        }
        let mergedLinks = flatLinks + preservedGroups
        onSave(EditedDetails(
            summary: summary,
            problem: problem,
            goals: goals,
            approach: approach,
            links: mergedLinks.isEmpty ? [LinkEntry()] : mergedLinks,
            learnings: learnings.isEmpty ? [""] : learnings
        ))
    }
}

private struct LinksBlock: View {
    let links: [LinkEntry]

    private var usable: [LinkEntry] {
        links.filter {
            ($0.label ?? "").isEmpty == false
                || ($0.url ?? "").isEmpty == false
                || !($0.children ?? []).isEmpty
        }
    }

    var body: some View {
        if !usable.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Eyebrow("Links")
                ForEach(Array(usable.enumerated()), id: \.offset) { _, link in
                    if let children = link.children, !children.isEmpty {
                        linkGroup(link, children: children)
                    } else {
                        linkRow(link)
                    }
                }
            }
        }
    }

    /// A nested link group: its label as a quiet heading, then its child URLs as an indented list of
    /// clickable links. Editing groups is not supported in the app (they round-trip untouched).
    @ViewBuilder private func linkGroup(_ link: LinkEntry, children: [LinkEntry]) -> some View {
        let label = (link.label ?? "").trimmingCharacters(in: .whitespaces)
        VStack(alignment: .leading, spacing: 2) {
            if !label.isEmpty {
                Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            }
            ForEach(Array(children.enumerated()), id: \.offset) { _, child in
                linkRow(child).padding(.leading, 10)
            }
        }
    }

    @ViewBuilder private func linkRow(_ link: LinkEntry) -> some View {
        let label = (link.label ?? "").trimmingCharacters(in: .whitespaces)
        let urlStr = (link.url ?? "").trimmingCharacters(in: .whitespaces)
        if isSafeURL(urlStr), let url = URL(string: urlStr) {
            // Show the label (or a tidied host if unlabeled) beside the site's favicon; the full URL
            // moves to the hover tooltip so the row stays compact.
            let pretty = prettyURL(urlStr)
            HStack(spacing: 6) {
                FaviconView(host: url.host ?? pretty)
                Link(label.isEmpty ? pretty : label, destination: url)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .help(urlStr)
        } else {
            let text = (!label.isEmpty && !urlStr.isEmpty) ? "\(label): \(urlStr)" : (label.isEmpty ? urlStr : label)
            Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    private func isSafeURL(_ s: String) -> Bool {
        let t = s.lowercased()
        return t.hasPrefix("http://") || t.hasPrefix("https://")
    }

    private func prettyURL(_ s: String) -> String {
        var out = s
        for scheme in ["https://", "http://"] where out.lowercased().hasPrefix(scheme) {
            out = String(out.dropFirst(scheme.count)); break
        }
        if out.hasSuffix("/") { out = String(out.dropLast()) }
        return out
    }
}

/// A site favicon for a link row: the fetched icon once it arrives, and a quiet globe glyph while it
/// loads or when the site has none. Sized to sit inline with the 12pt label.
private struct FaviconView: View {
    let host: String
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                Image(systemName: "globe").foregroundStyle(.tertiary)
            }
        }
        .frame(width: 14, height: 14)
        .task(id: host) { image = await FaviconLoader.shared.favicon(for: host) }
    }
}

// MARK: Helpers

/// Fires on any left mouse-up in the app while the window is shown. Used as a reliable end signal for a
/// *no-move* drag press: SwiftUI starts a drag (setting the drag key) but if the pointer never moves,
/// the release is an ordinary click whose mouse-up is delivered here — a real drag's concluding mouse-up
/// is consumed by the drag loop instead, and handled by the item-provider sentinel / the drop itself.
/// A backstop for the end of a *real* drag.
///
/// Neither existing end signal covers one on its own. `LeftMouseUpMonitor` sees only a press that never
/// moved — a real drag's concluding mouse-up is consumed by the drag loop, as its own note says. And
/// `DragEndSentinel` fires when ARC releases the drag's item provider, which is the right moment but
/// not a guarantee the framework makes. Left to those two, a release the sentinel is late for strands
/// the list: rows stay dimmed under a drag that has already finished, and only another drag clears it.
///
/// So while a drag is in flight, poll for the button coming up. Same technique and the same reason as
/// `FocusPanelChrome.startDragTracking` — inside AppKit's drag loop, a timer in `.common` modes is the
/// thing that still runs. Whichever signal arrives first wins and disarms the rest, so in the ordinary
/// case this ticks a few times during the drag and stops without ever being the one to act.
@MainActor
final class DragEndWatcher: ObservableObject {
    private var timer: Timer?
    private var onEnd: (() -> Void)?

    func arm(onEnd: @escaping () -> Void) {
        guard timer == nil else { return }
        self.onEnd = onEnd
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, NSEvent.pressedMouseButtons & 0x1 == 0 else { return }
                let end = self.onEnd
                self.disarm()
                end?()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func disarm() {
        timer?.invalidate()
        timer = nil
        onEnd = nil
    }
}

final class LeftMouseUpMonitor: ObservableObject {
    var onMouseUp: (() -> Void)?
    private var monitor: Any?

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            self?.onMouseUp?()
            return event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

/// Which task row the pointer is over. A plain reference box rather than `@State` on purpose: nothing
/// on screen depends on it, so moving between rows shouldn't cost a render. Only the right-click
/// monitor reads it, at the moment of the click.
final class RowHoverTracker {
    private(set) var key: String?

    /// `inside` false only clears the key when it's still *this* row's — rows can report leaving after
    /// the next one reports entering, which would otherwise blank a key that had just been set.
    func set(_ key: String, inside: Bool) {
        if inside { self.key = key } else if self.key == key { self.key = nil }
    }
}

/// Fires on any right mouse-down in the app while the window is shown, so the task list can move its
/// highlight onto the row whose context menu is about to open.
///
/// This is an event monitor rather than something computed while the menu is built because SwiftUI
/// builds a row's `.contextMenu` content during the row's body pass, not on the click — so anything
/// that mutates state from there runs once per row per render (see `ProjectView.contextTargets`). A
/// local monitor sees the event before it reaches the view, so the selection is committed by the time
/// the menu appears.
final class RightMouseDownMonitor: ObservableObject {
    var onRightMouseDown: (() -> Void)?
    private var monitor: Any?

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
            self?.onRightMouseDown?()
            return event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

/// Publishes whether ⌥ is currently held, so a button can swap its icon/action live (as macOS menus
/// do for alternate items). Backed by a local `flagsChanged` monitor active while the window is key.
final class ModifierMonitor: ObservableObject {
    @Published var optionDown = false
    private var monitor: Any?

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            // Only publish on a real change. `flagsChanged` fires for *every* modifier, press and
            // release — ⌘ and ⇧ included, which are exactly the keys held while multi-selecting — and
            // an unconditional write to an `@Published` republishes whether or not the value moved.
            // That rebuilt the whole view body, sidebar list and all, several times per click.
            let down = event.modifierFlags.contains(.option)
            if let self, self.optionDown != down { self.optionDown = down }
            return event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        optionDown = false
    }
}
