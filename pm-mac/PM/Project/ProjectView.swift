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
    @AppStorage("PMPanelDetailsExpanded") private var detailsExpanded = false
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
    /// drag is in flight. A subtree can't land on itself or its own descendants.
    @State private var draggingKey: String?
    /// Frames (Y-extent + depth) of every visible task row in the task-list coordinate space, collected
    /// via a preference. The single list-level drop delegate reads these to resolve the pointer into a
    /// gap + depth.
    @State private var rowFrames: [RowFrame] = []
    /// The single resolved drop indicator for the in-flight drag — the gap Y, the chosen depth, and
    /// whether it's a legal target. Nil when nothing is being dragged over the list.
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
    /// A row the keyboard just moved onto, for the scroll view to reveal. Cleared once acted on.
    @State private var scrollTarget: String?
    /// Tracks the ⌥ key so the Open button can swap between Obsidian and Finder live, like the menu.
    @StateObject private var modifiers = ModifierMonitor()
    /// Cancels an open editor when the user clicks outside it (see `OutsideClickMonitor`).
    @StateObject private var outsideClick = OutsideClickMonitor()
    /// Clears drag state on a no-move drag press's mouse-up (see `LeftMouseUpMonitor`).
    @StateObject private var mouseUp = LeftMouseUpMonitor()
    /// Moves the task list's highlight onto a right-clicked row (see `RightMouseDownMonitor`).
    @StateObject private var rightClick = RightMouseDownMonitor()
    /// The task row the pointer is over, for that same right-click. Not `@State` — see `RowHoverTracker`.
    @State private var rowHover = RowHoverTracker()

    /// Named coordinate space the task rows publish their frames in, and the drop delegate resolves the
    /// pointer against. Shared with `TaskRow`, so it lives on the type.
    static let taskListSpace = "pmTaskList"
    /// The x (in `taskListSpace`) where a depth-0 row's content begins — matches the rows' leading
    /// padding. The insertion indicator and the pointer→depth mapping both key off it.
    static let rowContentInset: CGFloat = 12
    /// Horizontal pixels per nesting level (matches `TaskRow.indent`'s step).
    static let indentStep: CGFloat = 16
    /// The one animation used for showing/hiding the details brief. A single shared value, applied by
    /// every subview that moves on the toggle (keyed on `detailsExpanded`), so the details content, the
    /// divider, the "Tasks" heading, and the regrouped rows all settle on the same clock rather than at
    /// different rates.
    static let detailsMotion: Animation = .snappy

    /// True whenever some inline editor (a task row's, or the project-details form) is open.
    private var isAnyEditorActive: Bool { activeEditor != nil || editingDetails }

    /// True while the project-details section is rendered directly below the header. Drives the
    /// header/divider spacing so the details read as a continuation of the title, not a fenced pane.
    private var detailsShowing: Bool { store.projectName != nil && detailsExpanded }

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
            // The column keeps a readable width: free to grow to `maxContentWidth` and then stop,
            // centered, so a wide window becomes margin rather than very long rows. The sidebar is not
            // laid out here — it's the other half of the window's split view.
            .frame(minWidth: ProjectWindow.minContentWidth, maxWidth: ProjectWindow.maxContentWidth,
                   alignment: .leading)
            // Leading, not centred. The cap keeps rows readable in a wide window; centring the capped
            // column on top of that left the project name adrift in the middle of the pane, with no
            // edge to line up against and the sidebar's own content a long way off to its left.
            .frame(maxWidth: .infinity, alignment: .leading)
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
                VStack(spacing: 0) {
                    // The header (title + toolbar) stays pinned; only the content below scrolls, sliding
                    // under it when it overflows the window.
                    stickyHeader
                    // The reader lets arrow-key navigation reveal a row that's scrolled out of view —
                    // each row carries its key as a scroll id (see `TaskRow.scrollMarker`).
                    ScrollViewReader { proxy in
                        ScrollView {
                            scrollBody
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        // Soften the scroll edges (macOS 26+): content fades as it passes under the pinned
                        // header and off the window's bottom edge, the idiomatic replacement for a hard clip.
                        .modifier(SoftScrollEdges())
                        .onChange(of: scrollTarget) { target in
                            guard let target else { return }
                            withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(target) }
                            // Cleared so that stepping back onto the same row later scrolls again.
                            DispatchQueue.main.async { scrollTarget = nil }
                        }
                    }
                }
                .transition(.asymmetric(
                    insertion: .move(edge: .leading).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)))
            }
        }
        // Show/hide details rides one shared animation (`detailsMotion`). It must be an implicit
        // value-based modifier, not `withAnimation` at the toggle site: `detailsExpanded` is
        // `@AppStorage`, whose change republishes on the next runloop tick — outside any explicit
        // transaction — so `withAnimation` wouldn't take. Every subview that moves on the toggle keys
        // its own animation off `detailsExpanded` with this same value, so nothing drifts.
        .animation(Self.detailsMotion, value: detailsExpanded)
        .animation(.snappy, value: tasksMode)
        .animation(.snappy, value: sessionNoteTakeover != nil)
        .clipped()
        .onPreferenceChange(ActiveEditorFrameKey.self) { outsideClick.editorFrame = $0 }
        .background(WindowAccessor { outsideClick.window = $0 })
        .onExitCommand(perform: handleEscape)
        // File ▸ New Task. The menu can't reach into the view, so the window bumps a counter and the
        // add editor opens wherever it makes sense: the first-task CTA in an empty project, else an
        // "after" editor on the hero task.
        .onChange(of: state.newTaskRequest) { _ in beginNewTask() }
        // Edit ▸ Find ▸ Find… — same counter trick as New Task, for the same reason.
        .onChange(of: state.findRequest) { _ in beginFind() }
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
            let live = Set(visibleTodos.map(PMStore.key(for:)))
            if !selection.isSubset(of: live) { selection.formIntersection(live) }
        }
        // Adding/deleting a session shifts session indices, so close any open session editor when the
        // count changes (a keyed editor would otherwise point at the wrong session).
        .onChange(of: store.notes?.sessions.count) { _ in activeEditor = nil }
        // Collapsing details (from the menu) also leaves any details-edit form.
        .onChange(of: detailsExpanded) { expanded in if !expanded { editingDetails = false } }
        // Start/stop the outside-click monitor with edit mode; an outside click cancels any editor.
        .onChange(of: isAnyEditorActive) { active in
            if active {
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
            modifiers.start()
            mouseUp.onMouseUp = { if draggingKey != nil { draggingKey = nil; dropTarget = nil } }
            mouseUp.start()
            rightClick.onRightMouseDown = {
                if let key = rowHover.key { selectForContextMenu(key) }
            }
            rightClick.start()
            // Arrow keys should work on a freshly-opened window without a click to arm them.
            DispatchQueue.main.async { focusTasks() }
        }
        .onDisappear { modifiers.stop(); outsideClick.stop(); mouseUp.stop(); rightClick.stop() }
    }

    /// Invisible buttons that register the window keyboard shortcuts. `.hidden()` keeps them out of the
    /// layout and hit-testing while still binding the shortcut on the key window; the undo/redo pair is
    /// disabled when there's nothing to (un/re)do, so the shortcut no-ops (system beep) rather than firing.
    ///
    /// ⌘C and ⌘A intentionally sit *behind* the Edit menu's own Copy / Select All (see
    /// `AppDelegate.installMainMenu`): AppKit offers a key equivalent to the main menu before the key
    /// window, so while a text field is focused those items claim the keystroke and edit the text.
    /// These fire only when no responder wants them — i.e. when the list, not a field, is in play.
    private var keyboardShortcuts: some View {
        // Suppressed while the note editor is up, so ⌘Z / ⇧⌘Z reach the NSTextView's own (per-keystroke)
        // undo instead of the document-level history.
        let inNoteEditor = sessionNoteTakeover != nil
        return Group {
            Button("Undo", action: store.undo)
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!store.canUndo || inNoteEditor)
            Button("Redo", action: store.redo)
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!store.canRedo || inNoteEditor)
            Button("Copy", action: copySelection)
                .keyboardShortcut("c", modifiers: .command)
                .disabled(inNoteEditor || !canCopySelection)
            Button("Select All", action: selectAllInFocusedPane)
                .keyboardShortcut("a", modifiers: .command)
                .disabled(inNoteEditor)
            // ⌘⌫ is the Finder delete; plain ⌫ is handled by the list's `onDeleteCommand`, which only
            // fires while the list itself (rather than a text field) holds focus.
            Button("Delete") { requestDelete(actionTargets) }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(inNoteEditor || actionTargets.isEmpty)
            // Return opens the selected project — a list's "open" — and ⌘Return opens it in a new
            // window, the Finder's pairing. Only live while the sidebar holds keyboard focus, so Return
            // keeps its usual meaning in every editor and dialog.
            Button("Open Project") { activateSelectedProject(inNewWindow: false) }
                .keyboardShortcut(.return, modifiers: [])
                .disabled(!canActivateSelectedProject)
            Button("Open Project in New Window") { activateSelectedProject(inNewWindow: true) }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!canActivateSelectedProject)
        }
        .hidden()
    }

    private func activateSelectedProject(inNewWindow: Bool) {
        guard let key = state.projectSelection.first else { return }
        guard inNewWindow || key != store.projectKey else { return }
        state.openProject(key, inNewWindow)
    }

    private var canActivateSelectedProject: Bool {
        state.focusedPane == .projects && state.projectSelection.count == 1 && pendingDelete.isEmpty
    }

    // MARK: Selection

    /// The tasks a command applies to: the selected rows.
    private var actionTargets: [Todo] {
        visibleTodos.filter { selection.contains(PMStore.key(for: $0)) }
    }

    /// Open the inline add editor — File ▸ New Task, and the empty state's button. The new task lands
    /// after the selected row, else after the focused task, so ⌘N in a long list adds where you're
    /// looking rather than at the bottom.
    private func beginNewTask() {
        guard store.projectName != nil else { return }
        if store.todos.isEmpty {
            addingFirstTask = true
        } else if let anchor = actionTargets.first ?? store.focusedTodo ?? store.openTodos.first {
            activeEditor = EditorTarget(key: PMStore.key(for: anchor), kind: .add)
        }
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

    private func selectAllInFocusedPane() {
        if state.focusedPane == .projects {
            state.projectSelection = Set(store.allProjects.map(\.projectKey))
        } else {
            selection = Set(visibleTodos.map(PMStore.key(for:)))
            selectionAnchor = selection.isEmpty ? nil : PMStore.key(for: visibleTodos[0])
        }
    }

    /// Click behaviour for a task row, following the standard Mac list: a plain click selects just
    /// that row, ⇧ extends the range from the anchor, ⌘ toggles the row in and out of the selection.
    /// (Activating a task — making it the focused one — is the double-click, see `TaskRow`.)
    private func selectRow(_ todo: Todo, modifiers: NSEvent.ModifierFlags) {
        focusTasks()
        let key = PMStore.key(for: todo)
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
        let keys = visibleTodos.map(PMStore.key(for:))
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
        let keys = visibleTodos.map(PMStore.key(for:))
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
        scrollTarget = key
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

    /// The pinned header — the project title/toolbar, plus the rule that fences it off from the task list
    /// (only when details are collapsed; with details open they sit directly under the title as one
    /// continuous brief). Stays fixed above the scroll area; swapped out entirely for the note takeover.
    private var stickyHeader: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            findBar
            if !detailsShowing || findVisible { Divider() }
            deleteConfirmation
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
                    } else if store.todos.isEmpty && !detailsExpanded {
                        emptyProjectTasks
                    } else {
                        tasksSection
                    }
                }
            }
        }
    }

    /// When the active editor is a session note, the (index, session) it targets — driving the full-column
    /// takeover editor. Nil for every other editor state.
    private var sessionNoteTakeover: (index: Int, session: Session)? {
        guard let ed = activeEditor, ed.kind == .sessionNote,
              ed.key.hasPrefix("sess:"),
              let idx = Int(ed.key.dropFirst("sess:".count)),
              let sessions = store.notes?.sessions, idx < sessions.count
        else { return nil }
        return (idx, sessions[idx])
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
        } else if !selection.isEmpty || !state.projectSelection.isEmpty {
            selection = []
            selectionAnchor = nil
            state.clearSelections()
        }
        // ...and stops there. A real window isn't summoned, so Escape has no business closing it —
        // that's ⌘W. (The focus panel, which *is* summoned, still hides on its last Escape.)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            // Title only. Switching projects is the sidebar's job — a chevron here offered a second,
            // smaller version of the same list, and the two disagreed about what "open" meant: this one
            // moved the app's global focus, while the sidebar retargets the window you're in.
            projectTitle
            Spacer()
            let p = store.progress
            if p.total > 0 {
                Text("\(p.done)/\(p.total)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if store.projectName != nil { viewOptionsMenu }
            if store.projectPath != nil {
                HStack(spacing: 4) {
                    openButton
                    raycastButton
                }
            }
        }
        .modifier(TitlebarClearance(state: state))
        // Double-click empty header space (or the title) toggles the details brief. On a background
        // layer *behind* the controls so the switcher / view-options / open buttons in front consume
        // their own clicks and are excluded; `simultaneousGesture` so it still coexists with
        // drag-by-window-background.
        .background(
            Color.clear
                .contentShape(Rectangle())
                .simultaneousGesture(TapGesture(count: 2).onEnded {
                    if store.projectName != nil { detailsExpanded.toggle() }
                })
        )
        // Right-clicking anywhere in the header opens the same view settings as the slider button.
        .contextMenu { viewOptionsMenuContent }
    }

    /// The project title. Plain text — the details-toggle double-click lives on the header background
    /// behind it, so the title itself carries no gesture.
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
        Toggle(isOn: $detailsExpanded) { Label("Show notes", systemImage: "note.text") }
        // The ⌥⌘S shortcut lives on a hidden button (see `keyboardShortcuts`) rather than here — a closed
        // SwiftUI menu's items aren't in the responder chain, so a key equivalent set here wouldn't fire.
        Toggle(isOn: Binding(get: { state.sidebarVisible },
                             set: { _ in state.toggleSidebar() })) {
            Label("Show projects  ⌥⌘S", systemImage: "sidebar.leading")
        }
        Divider()
        Picker("Appearance", selection: $colorMode) {
            Label("System", systemImage: "circle.lefthalf.filled").tag(AppColorMode.system)
            Label("Light", systemImage: "sun.max").tag(AppColorMode.light)
            Label("Dark", systemImage: "moon").tag(AppColorMode.dark)
        }
        .pickerStyle(.inline)
    }

    /// Opens the focused project's view in Raycast (same deep link as the menu's "View Project").
    private var raycastButton: some View {
        Button {
            if let url = URL(string: "raycast://extensions/shanberg/project-manager/view-focused-project") {
                NSWorkspace.shared.open(url)
            }
        } label: {
            Group {
                if let icon = AppIcons.smallImage(.raycast) {
                    Image(nsImage: icon).resizable().frame(width: 15, height: 15)
                } else {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 20, height: 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open project in Raycast")
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
        } else if let url = URL(string: "raycast://extensions/shanberg/project-manager/open-focused-in-obsidian") {
            NSWorkspace.shared.open(url)
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
            Text("Focus a project from Raycast or the menubar.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    // MARK: Tasks

    /// Session indices in first-appearance order among the visible todos.
    private var sessionOrder: [Int] {
        var seen = Set<Int>()
        var order: [Int] = []
        for t in visibleTodos where !seen.contains(t.sessionIndex) {
            seen.insert(t.sessionIndex); order.append(t.sessionIndex)
        }
        return order
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
                    store.addTodo(text: text, due: due)
                    addingFirstTask = false
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

            // In notes mode, always show the session-oriented list (headers + affordances) even when no
            // tasks are currently visible; otherwise fall back to the empty-state copy.
            if visibleTodos.isEmpty && !detailsExpanded {
                Text(tasksMode == .all ? "No tasks yet" : "All tasks complete")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 16)
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
        return VStack(alignment: .leading, spacing: 4) {
            if detailsExpanded {
                revealedSessions(wrapDescendants: wrapDescendants, draggedSubtree: draggedSubtree)
            } else {
                groupedSessions(wrapDescendants: wrapDescendants, draggedSubtree: draggedSubtree)
            }
        }
        .coordinateSpace(name: Self.taskListSpace)
        .onPreferenceChange(RowFramesKey.self) { rowFrames = $0 }
        .overlay(alignment: .topLeading) { dropIndicator }
        // The app's own task type leads, so a reorder is matched by identity rather than by "some
        // text arrived"; `.text` stays in the list only because the same drag also carries markdown.
        // Foreign drags are turned away regardless — `isActive` is false unless one of our own rows
        // started the drag.
        .onDrop(of: [TaskPasteboard.taskKeysType, .text], delegate: ListDropDelegate(
            isActive: draggingKey != nil,
            onCompute: { computeDropTarget(at: $0) },
            onUpdate: { dropTarget = $0 },
            onPerform: { performListDrop($0) }
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

    /// Default rendering: only sessions that have visible tasks, each introduced by a quiet caption.
    /// Empty sessions stay hidden. This is the default when session notes aren't revealed.
    @ViewBuilder private func groupedSessions(wrapDescendants: Set<String>, draggedSubtree: Set<String>) -> some View {
        ForEach(sessionOrder, id: \.self) { si in
            let context = sessionContext(si)
            if !context.isEmpty {
                Text(context)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
                    .padding(.bottom, 2)
            }
            sessionTaskRows(si, wrapDescendants: wrapDescendants, draggedSubtree: draggedSubtree)
        }
    }

    /// Revealed rendering: every session (including empty ones) as a first-class header with its
    /// editable prose note, its tasks, and an add-task affordance, plus a "New session" affordance on top.
    @ViewBuilder private func revealedSessions(wrapDescendants: Set<String>, draggedSubtree: Set<String>) -> some View {
        let sessions = store.notes?.sessions ?? []
        newSessionAffordance
        ForEach(Array(sessions.enumerated()), id: \.offset) { index, session in
            SessionHeader(index: index, session: session, store: store, activeEditor: $activeEditor)
            sessionTaskRows(index, wrapDescendants: wrapDescendants, draggedSubtree: draggedSubtree)
            // An explicit add affordance for a session with nothing visible to anchor a per-row add on.
            if !visibleTodos.contains(where: { $0.sessionIndex == index }) {
                sessionAddTaskAffordance(index)
            }
        }
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
                    onClick: { selectRow(todo, modifiers: $0) },
                    onActivate: { store.focus(todo) },
                    contextTargets: { contextTargets(for: todo) },
                    onHoverChanged: { rowHover.set(key, inside: $0) },
                    dragProvider: { dragProvider(for: todo) },
                    onDelete: { requestDelete($0) },
                    onSetDue: { applyDue($0, from: todo) }
                )
            }
        }
    }

    /// The "New session" control (revealed mode): a quiet button that opens an inline optional-label
    /// editor; submitting adds a today-dated session at the top of the list.
    @ViewBuilder private var newSessionAffordance: some View {
        let target = EditorTarget(key: "sess:new", kind: .sessionNew)
        if activeEditor == target {
            InlineTextEditor(placeholder: "Session label (optional)", submitLabel: "Add", allowsEmpty: true) { label in
                store.addSession(label: label)
                activeEditor = nil
            } onCancel: { activeEditor = nil }
                .reportEditorFrame()
                .padding(.horizontal, 12)
                .padding(.top, 4)
        } else {
            Button { activeEditor = target } label: {
                Label("New session", systemImage: "plus.circle").font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.top, 4)
        }
    }

    /// The per-session "Add task" affordance (revealed mode), shown when a session has no visible tasks
    /// to hang a per-row add on. Opening it reveals an inline add editor that appends to the session.
    @ViewBuilder private func sessionAddTaskAffordance(_ index: Int) -> some View {
        let target = EditorTarget(key: "sess:\(index)", kind: .sessionAddTask)
        if activeEditor == target {
            AddEditor(leadingIcon: AnyView(TaskStatusIcon())) { text, due in
                store.addTaskToSession(index, text: text, due: due)
                activeEditor = nil
            } onCancel: { activeEditor = nil }
                .reportEditorFrame()
                .padding(.horizontal, 12)
        } else {
            Button { activeEditor = target } label: {
                Label("Add task", systemImage: "plus").font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 12)
            .padding(.bottom, 2)
        }
    }

    /// The single insertion indicator: a caret dot + rule drawn at the resolved gap's Y and the chosen
    /// depth's indent. Only shown for a legal target; an illegal one shows the "no drop" cursor instead.
    @ViewBuilder private var dropIndicator: some View {
        if let t = dropTarget, t.valid {
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

    /// Resolve a pointer location (in `taskListSpace`) into a drop target: which gap (by Y), which depth
    /// (by X, clamped to the legal `[rowBelow.depth ... rowAbove.depth+1]` range at that gap), and the
    /// anchor row + side that names the exact document slot. Nil when nothing is being dragged or there
    /// are no rows.
    private func computeDropTarget(at p: CGPoint) -> DropTarget? {
        guard let dk = draggingKey,
              let dragged = store.todos.first(where: { PMStore.key(for: $0) == dk }) else { return nil }
        let subtree = store.subtreeKeys(of: dragged)
        let rows = rowFrames.sorted { $0.minY < $1.minY }
        guard !rows.isEmpty else { return nil }

        // Gap index = how many rows sit (by midpoint) at or above the pointer → 0 = above the first row,
        // rows.count = below the last (the trailing gap).
        let gapIndex = rows.filter { ($0.minY + $0.maxY) / 2 <= p.y }.count
        let rowAbove: RowFrame? = gapIndex > 0 ? rows[gapIndex - 1] : nil
        let rowBelow: RowFrame? = gapIndex < rows.count ? rows[gapIndex] : nil

        // Legal depth range at this gap: no shallower than the row below (else you'd re-parent it), no
        // deeper than one under the row above (its deepest legal child).
        let minDepth = rowBelow?.depth ?? 0
        let maxDepth = max(minDepth, rowAbove.map { $0.depth + 1 } ?? 0)
        let rawDepth = Int(((p.x - Self.rowContentInset) / Self.indentStep).rounded())
        let depth = min(max(rawDepth, minDepth), maxDepth)

        // Resolve the document slot. Nesting deeper than the row below anchors on the row above (which
        // supplies the parent chain); otherwise anchor the row below and insert before it — this keeps a
        // cross-session boundary landing in the right session, and a plain sibling insert precise.
        let anchor: RowFrame
        let insertAfter: Bool
        if rowBelow == nil {
            anchor = rowAbove!; insertAfter = true
        } else if rowAbove == nil {
            anchor = rowBelow!; insertAfter = false
        } else if depth > rowBelow!.depth {
            anchor = rowAbove!; insertAfter = true
        } else {
            anchor = rowBelow!; insertAfter = false
        }

        let gapY = rowAbove?.maxY ?? rowBelow?.minY ?? 0
        let valid = !subtree.contains(anchor.key)
        return DropTarget(gapY: gapY, depth: depth, valid: valid,
                          anchorSession: anchor.session, anchorLine: anchor.line, insertAfter: insertAfter)
    }

    /// Commit a resolved drop: move the dragged subtree to the target's slot + depth, then clear state.
    private func performListDrop(_ t: DropTarget) -> Bool {
        guard t.valid,
              let dk = draggingKey,
              let source = store.todos.first(where: { PMStore.key(for: $0) == dk }),
              let anchor = store.todos.first(where: {
                  $0.sessionIndex == t.anchorSession && $0.lineIndex == t.anchorLine
              })
        else { return false }
        store.moveSubtree(source, anchor: anchor, insertAfter: t.insertAfter, depth: t.depth)
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

/// A visible task row's vertical extent and depth in the task-list coordinate space, published via
/// preference so the single list-level drop delegate can resolve the pointer into a gap + depth without
/// per-row drop targets. Carries the row's document identity (session/line) to name the move anchor.
struct RowFrame: Equatable {
    let key: String
    let session: Int
    let line: Int
    let depth: Int
    let minY: CGFloat
    let maxY: CGFloat
}

/// Collects every visible row's frame into one array for the drop delegate.
struct RowFramesKey: PreferenceKey {
    static var defaultValue: [RowFrame] = []
    static func reduce(value: inout [RowFrame], nextValue: () -> [RowFrame]) {
        value.append(contentsOf: nextValue())
    }
}

/// The single resolved drop indicator for an in-flight drag: the gap's Y (a row boundary), the chosen
/// nesting depth, whether it's a legal target, and the document slot (anchor row + side) the move will
/// use. Produced from the pointer by `computeDropTarget`.
struct DropTarget: Equatable {
    let gapY: CGFloat
    let depth: Int
    let valid: Bool
    let anchorSession: Int
    let anchorLine: Int
    let insertAfter: Bool
}

/// The content column's leading edge in window space, so the header can tell how much of the window's
/// traffic lights it actually sits under.
private struct HeaderOriginKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
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
                Color.clear.preference(key: HeaderOriginKey.self, value: geo.frame(in: .global).minX)
            })
            .onPreferenceChange(HeaderOriginKey.self) { columnOffsetInPane = $0 }
            .animation(.easeInOut(duration: 0.25), value: overhang)
            // Centre the title on the traffic lights, wherever the system has put them — the unified
            // titlebar this window uses sits them twice as far down as a compact one would, and
            // hard-coding either number means the title is level in one and adrift in the other. Half a
            // title line is the only constant here.
            .padding(.top, max(8, state.titlebarButtonCenterY - 11))
            .padding(.bottom, bottom)
    }
}

/// Applies the soft scroll-edge effect so scrolling content fades at the top/bottom edges — under the
/// pinned header and off the bottom edge — rather than hard-clipping.
private struct SoftScrollEdges: ViewModifier {
    func body(content: Content) -> some View {
        content.scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
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
    @State private var hovering = false
    /// Whether the row window is the key window — a selection in an inactive window is muted, as
    /// in every native list.
    @Environment(\.controlActiveState) private var controlActiveState
    /// Which position a freshly-opened add editor should seed to (set by the plus button and the
    /// context menu's Add actions before opening the editor).
    @State private var pendingAddPosition: TaskInsertPosition = .child

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
            if isAdding && pendingAddPosition == .before {
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
                        let f = g.frame(in: .named(ProjectView.taskListSpace))
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
                    // Double-click activates (focuses) the task; a single click selects it. The
                    // two-count gesture is declared first so SwiftUI can let it win the race.
                    .onTapGesture(count: 2, perform: onActivate)
                    .onTapGesture { onClick(NSEvent.modifierFlags) }
                    .contextMenu {
                        TaskMenu(todo: todo, targets: contextTargets(), store: store,
                                 openEditor: openEditor, openAdd: openAdd, onDelete: onDelete)
                    }
                    // Dim the dragged subtree in place under the floating ghost.
                    .opacity(dimmed ? 0.35 : 1)
                    .animation(.easeOut(duration: 0.15), value: dimmed)
                    // Selection lives on the row, so the row has to report it: VoiceOver reads the
                    // task with its state, and the gestures it can't perform (double-click to focus,
                    // ⌫ to delete) are offered as named actions.
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                    .accessibilityAction(named: "Focus Task", onActivate)
                    .accessibilityAction(named: "Delete Task") { onDelete(contextTargets()) }
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
            if isAdding && (pendingAddPosition == .after || pendingAddPosition == .child) {
                addEditor.padding(.leading, indent(todo.depth + (pendingAddPosition == .child ? 1 : 0)))
            }
        }
        .padding(.horizontal, 12)
        // The selection band spans the full row width, outside the depth indent — a row's highlight
        // shouldn't step in as it nests, any more than a table row's does.
        .background(selectionBand)
        .background(scrollMarker)
        .onHover { hovering = $0; onHoverChanged($0) }
        .animation(.snappy, value: localEditorKind)
        .animation(.snappy, value: ancestorWrapBoost)
    }

    /// The row's fill: the selection band, or a whisper of one on hover.
    ///
    /// Three states, as in every native list — selected in the focused pane of the key window
    /// (accent), selected but not (grey), and not selected. It's a tint rather than a solid accent
    /// fill so the row's own colours — the orange due chip, the secondary strikethrough of a
    /// completed task — stay themselves instead of needing a second, inverted palette.
    /// Suppressed while this row has an editor open, where the form is the subject, not the row.
    @ViewBuilder private var selectionBand: some View {
        if localEditorKind != nil {
            Color.clear
        } else if isSelected {
            (isEmphasized && controlActiveState != .inactive
                ? Color.accentColor.opacity(0.28)
                : Color.primary.opacity(0.10))
        } else if hovering && activeEditor == nil {
            Color.primary.opacity(0.05)
        } else {
            Color.clear
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
            Text(todo.text)
                .font(.system(size: 13, weight: todo.isFocused ? .semibold : .regular))
                .strikethrough(todo.checked, color: .secondary)
                .foregroundStyle(todo.checked ? .secondary : .primary)
                .lineLimit(2)

            Spacer(minLength: 4)

            DueChip(todo: todo, isEditing: isEditingDue, reveal: revealControls) { toggleEditor(.due) }

            Button {
                pendingAddPosition = .child
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

    /// The positional add editor. Its slot and indent are chosen by the caller (above/below, depth)
    /// from `pendingAddPosition`, so the form previews exactly where the new task will land.
    private var addEditor: some View {
        AddEditor(leadingIcon: AnyView(TaskStatusIcon())) { text, due in
            store.addTodo(text: text, due: due, relativeTo: todo, position: pendingAddPosition)
            activeEditor = nil
        } onCancel: { activeEditor = nil }
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
        pendingAddPosition = position
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

// MARK: Drag-to-reorder drop delegate

/// The single list-level drop target. Resolves the pointer (in the task-list coordinate space) into a
/// gap + depth via the parent's `onCompute`, reports it so the list can paint the one insertion line,
/// and commits the move on drop. All row/store access lives in the parent-supplied closures, so this
/// stays a plain value type.
private struct ListDropDelegate: DropDelegate {
    /// Whether a drag is in flight (nothing to resolve otherwise).
    let isActive: Bool
    /// Resolve a pointer location into the drop target (nil when illegal / no rows).
    let onCompute: (CGPoint) -> DropTarget?
    /// Publish the current target (nil clears the indicator).
    let onUpdate: (DropTarget?) -> Void
    /// Commit the resolved move; returns whether it was accepted.
    let onPerform: (DropTarget) -> Bool

    func validateDrop(info: DropInfo) -> Bool { isActive }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let target = onCompute(info.location)
        onUpdate(target)
        return DropProposal(operation: (target?.valid ?? false) ? .move : .forbidden)
    }

    func dropExited(info: DropInfo) { onUpdate(nil) }

    func performDrop(info: DropInfo) -> Bool {
        guard let target = onCompute(info.location), target.valid else { onUpdate(nil); return false }
        return onPerform(target)
    }
}

// MARK: Due chip + editor

private struct DueChip: View {
    let todo: Todo
    let isEditing: Bool
    /// Reveal the empty-state "＋date" affordance (true while hovering the row). A real own/inherited
    /// date is content, not a control, so it stays visible regardless.
    let reveal: Bool
    let onTap: () -> Void

    private var hasDate: Bool { todo.dueDate != nil || todo.effectiveDueDate != nil }

    var body: some View {
        // Always laid out so hovering only toggles opacity, never the row's height. A real own/
        // inherited date is content (always visible); the empty-state "＋date" is a control that
        // fades in on hover/edit but keeps reserving its space.
        Button(action: onTap) {
            if let own = todo.dueDate {
                chip(String(own.prefix(10)), color: .orange, dashed: false)
            } else if let eff = todo.effectiveDueDate {
                chip(String(eff.prefix(10)), color: .secondary, dashed: true)
            } else {
                chip("＋date", color: .secondary, dashed: true)
            }
        }
        .buttonStyle(.plain)
        .help(todo.dueDate != nil ? "Edit due date" :
              (todo.effectiveDueDate != nil ? "Inherited due — click to set this task's own" : "Set due date"))
        .opacity(hasDate || reveal || isEditing ? 1 : 0)
        .allowsHitTesting(hasDate || reveal || isEditing)
    }

    private func chip(_ text: String, color: Color, dashed: Bool) -> some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(color, style: StrokeStyle(lineWidth: 1, dash: dashed ? [3] : []))
            )
            .foregroundStyle(color)
    }
}

// MARK: Session header + note editor

/// A revealed session's first-class header: its date/label line (double-click or right-click to
/// rename), its editable leading-prose note (double-click to edit, or a quiet "Add note…" placeholder
/// when empty), and a context menu for renaming, adding a note/task, and deleting an empty session.
/// Publishes no `RowFrame`, so it doesn't participate in the task drag-reorder geometry.
private struct SessionHeader: View {
    let index: Int
    let session: Session
    @ObservedObject var store: PMStore
    @Binding var activeEditor: EditorTarget?

    private var key: String { "sess:\(index)" }
    private var isRenaming: Bool { activeEditor == EditorTarget(key: key, kind: .sessionLabel) }
    /// The session's editable note — its leading prose (lines before the first task), trimmed.
    private var prose: String { leadingSessionProse(body: session.body) }

    /// The serif reading face for the rendered note, matching the project-details brief.
    private static let noteFont: NSFont = {
        let size: CGFloat = 13
        if let serif = NSFont.systemFont(ofSize: size).fontDescriptor.withDesign(.serif) {
            return NSFont(descriptor: serif, size: size) ?? NSFont.systemFont(ofSize: size)
        }
        return NSFont.systemFont(ofSize: size)
    }()
    private var context: String { session.label.isEmpty ? session.date : "\(session.date) · \(session.label)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if isRenaming {
                InlineTextEditor(seed: session.label, placeholder: "Session label (optional)",
                                 submitLabel: "Rename", allowsEmpty: true) { label in
                    store.renameSession(index, label: label)
                    activeEditor = nil
                } onCancel: { activeEditor = nil }
                    .reportEditorFrame()
            } else {
                headerLine
            }

            // The note read view / placeholder; opening it (double-click or "Edit Note…") takes over the
            // whole column with the rich editor — see ProjectView.sessionNoteTakeover. The read view renders
            // the note's markdown (formatting applied, markers removed) in the details brief's serif face.
            if !prose.isEmpty {
                Text(renderedMarkdown(prose, base: Self.noteFont, baseColor: .secondaryLabelColor))
                    .lineSpacing(1.5)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { openNote() }
            } else {
                Text("Add note…")
                    .font(.system(size: 13, design: .serif))
                    .foregroundStyle(.quaternary)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { openNote() }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 2)
        .animation(.snappy, value: isRenaming)
    }

    private var headerLine: some View {
        HStack(spacing: 6) {
            Text(context)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { activeEditor = EditorTarget(key: key, kind: .sessionLabel) }
        .contextMenu { sessionMenu }
    }

    @ViewBuilder private var sessionMenu: some View {
        Button { activeEditor = EditorTarget(key: key, kind: .sessionLabel) } label: {
            Label("Rename Session…", systemImage: "pencil")
        }
        Button { openNote() } label: {
            Label(prose.isEmpty ? "Add Note…" : "Edit Note…", systemImage: "note.text")
        }
        Button { activeEditor = EditorTarget(key: key, kind: .sessionAddTask) } label: {
            Label("Add Task…", systemImage: "plus")
        }
        // Deleting is offered only for a session with no tasks, so tasks are never removed with it.
        if !store.hasTasks(sessionIndex: index) {
            Divider()
            Button(role: .destructive) { store.deleteSession(index) } label: {
                Label("Delete Session", systemImage: "trash")
            }
        }
    }

    private func openNote() { activeEditor = EditorTarget(key: key, kind: .sessionNote) }
}

/// The full-column, focused editor for a session's prose note. The column is taken over by a header
/// (Back button + the project name over the session name) and a rich `MarkdownTextEditor` with live
/// syntax highlighting and ⌘B/⌘I/⌘K shortcuts. There are no Save/Cancel buttons: the note **auto-saves**
/// whenever you leave — Back, Escape, an outside click (all remove the view → `onDisappear`), or the
/// the window losing key focus (`didResignKey`). `store.setSessionNote` is byte-idempotent, so a
/// repeated commit with no changes is a free no-op and yields no extra undo entry.
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
    /// The window this takeover is in, so the save-on-blur only fires for *this* window losing key.
    @State private var hostWindow: NSWindow?

    init(index: Int, session: Session, projectName: String,
         store: PMStore, state: ProjectViewState, onBack: @escaping () -> Void) {
        self.index = index
        self.session = session
        self.projectName = projectName
        self.store = store
        self.state = state
        self.onBack = onBack
        _text = State(initialValue: leadingSessionProse(body: session.body))
    }

    private var sessionName: String {
        session.label.isEmpty ? session.date : "\(session.date) · \(session.label)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            MarkdownTextEditor(text: $text, onSubmit: onBack)   // ⌘↩ closes → onDisappear auto-saves
                .frame(maxHeight: .infinity)                    // fill the remaining takeover height
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
        }
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

    private var header: some View {
        HStack(spacing: 8) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Back to tasks")
            VStack(alignment: .leading, spacing: 1) {
                Text(projectName.isEmpty ? "Note" : projectName)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(sessionName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .modifier(TitlebarClearance(state: state, bottom: 8))
    }

    /// Write the current text back to the session's note. The store sanitizes it (headings clamp to
    /// within-session levels; typed checkboxes graduate into real tasks), so we adopt the same cleaned
    /// prose locally — that drops the graduated checkboxes from the editor and makes repeated commits
    /// (this fires from several exit paths) byte-idempotent instead of re-extracting the same tasks.
    private func commit() {
        let cleaned = sanitizeSessionNoteProse(text).prose
        store.setSessionNote(index, prose: text)
        if cleaned != text { text = cleaned }
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
                    DetailsEditor(notes: n) { edited in
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
                    // Double-click anywhere in the details content switches to edit mode — including the
                    // empty placeholders, so a project with no details yet can gain them right here.
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { isEditing = true }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
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

    init(notes: ProjectNotes, onSave: @escaping (EditedDetails) -> Void, onCancel: @escaping () -> Void) {
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
            field("Summary") { TextField("", text: $summary, axis: .vertical).lineLimit(1...5) }
            field("Problem") { TextField("", text: $problem, axis: .vertical).lineLimit(1...5) }
            field("Goals") {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(0..<3, id: \.self) { i in
                        TextField("Goal \(i + 1)", text: $goals[i])
                    }
                }
            }
            field("Approach") { TextField("", text: $approach, axis: .vertical).lineLimit(1...5) }
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

/// Fetches and caches site favicons for the Links block. Each host is fetched once — directly from the
/// site's own `/favicon.ico`, so no third-party favicon service sees which sites are linked — decoded to
/// an `NSImage`, and served from an in-memory cache thereafter. Hosts with no usable icon are remembered
/// as misses so the view stops retrying. Fetches are deduped, so repeated rows for one host share a load.
@MainActor
final class FaviconLoader {
    static let shared = FaviconLoader()

    private var cache: [String: NSImage] = [:]
    private var misses: Set<String> = []
    private var inflight: [String: Task<NSImage?, Never>] = [:]

    func favicon(for host: String) async -> NSImage? {
        let key = host.lowercased()
        guard !key.isEmpty else { return nil }
        if let img = cache[key] { return img }
        if misses.contains(key) { return nil }
        if let task = inflight[key] { return await task.value }

        let task = Task<NSImage?, Never> { await Self.fetch(host: key) }
        inflight[key] = task
        let img = await task.value
        inflight[key] = nil
        if let img { cache[key] = img } else { misses.insert(key) }
        return img
    }

    nonisolated private static func fetch(host: String) async -> NSImage? {
        guard let url = URL(string: "https://\(host)/favicon.ico") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 8)
        // A browser-like UA — some hosts 403 the default URLSession agent.
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let img = NSImage(data: data), img.size.width > 0, img.size.height > 0 else { return nil }
            return img
        } catch {
            return nil
        }
    }
}

// MARK: Helpers

/// Fires on any left mouse-up in the app while the window is shown. Used as a reliable end signal for a
/// *no-move* drag press: SwiftUI starts a drag (setting the drag key) but if the pointer never moves,
/// the release is an ordinary click whose mouse-up is delivered here — a real drag's concluding mouse-up
/// is consumed by the drag loop instead, and handled by the item-provider sentinel / the drop itself.
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
