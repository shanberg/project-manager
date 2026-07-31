import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ObjectiveC
import PmLib

/// The panel's SwiftUI content, reconstructing the retired Tauri panel: a collapsible "Project
/// details" section, a task list grouped by session, per-row focus / due editing / positional add,
/// an "incomplete only" filter, and Escape-to-dismiss. Binds to `PMStore`; mutations go straight
/// through it to `PmLib`. Reports its content height so the panel window can auto-fit.
struct PanelView: View {
    @ObservedObject var store: PMStore
    /// Shared chrome state (e.g. hide the scrollbar during a resize animation).
    @ObservedObject var chrome: PanelChrome
    /// The state this pane shares with the project sidebar across the split (see `ProjectViewState`).
    @ObservedObject var state: ProjectViewState
    /// Whether this content is in a real window or the panel — see `WindowChromeStyle`.
    var chromeStyle: WindowChromeStyle = .window
    /// Escape with no open editor asks the window to hide.
    var onDismiss: () -> Void = {}
    /// Measured content height, for the window's auto-fit.
    var onContentHeight: (CGFloat) -> Void = { _ in }
    /// The bottom grab handle's live height drag — begin, the drag's total translation, and mouse-up.
    var onResizeBegan: () -> Void = {}
    var onResizeChanged: (CGFloat) -> Void = { _ in }
    var onResizeEnded: () -> Void = {}

    /// How the tasks area presents itself, persisted across panel sessions. `.incomplete` (open tasks
    /// only) is the default; `.all` also reveals completed tasks; `.focused` collapses to a single
    /// focused-task card with an ancestor breadcrumb and a dim "next" line.
    @AppStorage("PMPanelTasksMode") private var tasksMode: TasksMode = .incomplete
    /// The panel's color-scheme override, persisted across sessions. `.system` follows the OS setting;
    /// `.light`/`.dark` pin the appearance (of both the content and the glass/vibrancy material).
    @AppStorage("PMPanelColorMode") private var colorMode: PanelColorMode = .system
    /// The single "notes" view mode, toggled from the header's view-options menu and persisted across
    /// panel sessions. When on, the panel shows the project-details brief below the header *and* reveals
    /// every session (including empty ones) as a first-class header with its editable prose note and
    /// management affordances. Off (the default) is the compact task view — no brief, and sessions are
    /// just quiet captions above their tasks with empty ones hidden.
    @AppStorage("PMPanelDetailsExpanded") private var detailsExpanded = false
    /// Whether the project-details section is in inline-edit mode (entered by double-clicking its
    /// content). Reset when the section collapses, the project changes, or Escape is pressed.
    @State private var editingDetails = false
    /// The row (and editor kind) with an open inline editor, if any. Only one at a time.
    @State private var activeEditor: EditorTarget?
    /// Which position a freshly-opened add editor should seed to in focused mode (set by the focused
    /// card's context-menu Add actions before opening the editor). The task list tracks this per-row.
    @State private var focusedAddPosition: TaskInsertPosition = .child
    /// True while the empty-project CTA has revealed its inline add editor (for the very first task).
    @State private var addingFirstTask = false
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
    /// The panel's content height, tracked only while the main view is showing (frozen during the note
    /// takeover). The takeover reads it as a floor so it never shrinks the panel below its current height.
    @State private var measuredHeight: CGFloat = 0
    /// Natural height of the scrollable body. The pinned header's height is measured too, but lives on
    /// `state` because the sidebar lines its own header up with it across the split. The window's
    /// auto-fit targets their sum (the body lives in a `ScrollView`, whose own frame can't report the
    /// content's natural height). See `reportMainHeight`.
    @State private var scrollContentHeight: CGFloat = 0

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
        tasksMode == .all ? store.todos : store.todos.filter { !$0.checked }
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
            // The column keeps a readable width: fixed in the panel, and in a window free to grow to
            // `maxContentWidth` and then stop, centered, so a wide window becomes margin rather than
            // very long rows. The sidebar is no longer laid out here — it's the other half of the
            // window's split view (see `ProjectSplitViewController`).
            .frame(minWidth: ProjectWindow.minContentWidth,
                   maxWidth: chromeStyle.isPanel ? ProjectWindow.minContentWidth : ProjectWindow.maxContentWidth)
            .frame(maxWidth: .infinity)
            // The height grip, drawn over the bottom edge rather than laid out in the column, so it
            // costs the content nothing and never enters the measured height.
            .overlay(alignment: .bottom) { resizeHandle }
            // Pin the appearance when the user overrides it; `.system` (nil) follows the OS. Applied
            // above the background so the glass/vibrancy material (a child NSView) inherits the scheme.
            .preferredColorScheme(colorMode.colorScheme)
            // Liquid Glass (macOS 26+) / vibrancy background, filling the content's layout.
            .background {
                // The material runs under the titlebar even though the content doesn't: with
                // `fullSizeContentView` the hosting view is inset below the (invisible) titlebar, so
                // without this the strip above the header shows the bare window background — a black
                // band that reads as a titlebar that failed to draw.
                PanelBackground(rounded: chromeStyle.isPanel)
                    .ifCondition(!chromeStyle.isPanel) { $0.ignoresSafeArea(.container, edges: .top) }
            }
            // Only the panel rounds itself: it's borderless, so nothing else would. A real window's
            // frame does the clipping, and clipping again inside it would round the content away from
            // the window's own corners.
            .ifCondition(chromeStyle.isPanel) {
                $0.clipShape(RoundedRectangle(cornerRadius: ProjectWindow.cornerRadius, style: .continuous))
            }
            // The panel's content is meant to run under its (absent) titlebar; without this the hosting
            // controller insets it, so the measured height is ~one row short of what's shown and the
            // panel scrolls. In a window the inset is exactly what we want — it's what keeps the header
            // clear of the traffic lights.
            .ifCondition(chromeStyle.isPanel) { $0.ignoresSafeArea(.container, edges: .top) }
    }

    /// The panel's height grip: a quiet grabber along the bottom edge. Panel-style only, and only with
    /// the sidebar open — that's the only mode with a user-set height, since with it hidden the panel
    /// hugs its content down to a single task and there's nothing to drag. A real window has resize
    /// edges of its own.
    ///
    /// It sits in an overlay rather than the layout so it can't affect the measured content height, and
    /// excludes itself from the window-drag region so a pull resizes instead of moving.
    @ViewBuilder private var resizeHandle: some View {
        if chromeStyle.isPanel && state.sidebarVisible && sessionNoteTakeover == nil {
            PanelResizeHandle(onBegan: onResizeBegan, onChanged: onResizeChanged, onEnded: onResizeEnded)
        }
    }

    /// The panel's content column — everything that isn't the sidebar.
    private var mainColumn: some View {
        Group {
            if let takeover = sessionNoteTakeover {
                // Editing a session note takes over the whole panel for a focused, richer experience;
                // it enters with a navigation-style push (list slides left, editor in from the right).
                // It has its own header and a fixed height, so it stands outside the sticky-header split.
                SessionNoteTakeover(
                    index: takeover.index,
                    session: takeover.session,
                    projectName: store.notes?.title.trimmed ?? store.projectName ?? "",
                    height: takeoverTargetHeight,
                    store: store,
                    onBack: { activeEditor = nil }
                )
                .background(GeometryReader { geo in
                    Color.clear.preference(key: ContentHeightKey.self, value: geo.size.height)
                })
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .trailing).combined(with: .opacity)))
            } else {
                VStack(spacing: 0) {
                    // The header (title + toolbar) stays pinned; only the content below scrolls, sliding
                    // under it when it overflows the panel's max height. The header reports its own height
                    // separately so the window's auto-fit still targets header + content.
                    stickyHeader
                        .background(GeometryReader { geo in
                            Color.clear.preference(key: HeaderHeightKey.self, value: geo.size.height)
                        })
                    // The reader lets arrow-key navigation reveal a row that's scrolled out of view —
                    // each row carries its key as a scroll id (see `TaskRow.scrollMarker`).
                    ScrollViewReader { proxy in
                        ScrollView {
                            scrollBody
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(GeometryReader { geo in
                                    Color.clear.preference(key: ContentHeightKey.self, value: geo.size.height)
                                })
                        }
                        // Hide the scrollbar while the window is animating its resize (it would otherwise
                        // flash as the viewport and content briefly mismatch); it returns for genuine overflow.
                        .scrollIndicators(chrome.isResizing ? .never : .automatic)
                        // Soften the scroll edges (macOS 26+): content fades as it passes under the pinned
                        // header and off the panel's bottom, the idiomatic replacement for a hard clip.
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
        // Track the panel's height, but freeze it while the takeover is up so it keeps the main view's
        // height — the takeover reads it as a "don't shrink below" floor. (The window still fits to the
        // takeover's own reported height via onContentHeight.)
        // The window fits to header + scrollable content. In the takeover, `h` is the takeover's own
        // full height (it carries its own header), reported straight through; otherwise `h` is just the
        // scroll body's natural height and the pinned header's height is added on.
        .onPreferenceChange(ContentHeightKey.self) { h in
            if sessionNoteTakeover == nil {
                scrollContentHeight = h
                reportMainHeight()
            } else {
                onContentHeight(h)
            }
        }
        .onPreferenceChange(HeaderHeightKey.self) { hh in
            state.headerHeight = hh
            if sessionNoteTakeover == nil { reportMainHeight() }
        }
        .onPreferenceChange(ActiveEditorFrameKey.self) { outsideClick.editorFrame = $0 }
        .background(WindowAccessor { outsideClick.window = $0 })
        .onExitCommand(perform: handleEscape)
        // File ▸ New Task. The menu can't reach into the view, so the window bumps a counter and the
        // add editor opens wherever it makes sense: the first-task CTA in an empty project, else an
        // "after" editor on the hero task.
        .onChange(of: state.newTaskRequest) { _ in beginNewTask() }
        // ⌘Z / ⇧⌘Z undo & redo the panel's edits (move, complete, due, text, add, wrap…). Hidden
        // zero-size buttons carry the shortcuts so they work whenever the panel is key.
        .background(panelShortcuts)
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

    /// Invisible buttons that register the panel's keyboard shortcuts. `.hidden()` keeps them out of the
    /// layout and hit-testing while still binding the shortcut on the key window; the undo/redo pair is
    /// disabled when there's nothing to (un/re)do, so the shortcut no-ops (system beep) rather than firing.
    ///
    /// ⌘C and ⌘A intentionally sit *behind* the Edit menu's own Copy / Select All (see
    /// `AppDelegate.installMainMenu`): AppKit offers a key equivalent to the main menu before the key
    /// window, so while a text field is focused those items claim the keystroke and edit the text.
    /// These fire only when no responder wants them — i.e. when the list, not a field, is in play.
    private var panelShortcuts: some View {
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

    /// The tasks a command applies to: the selected rows in the list modes, or the hero card in
    /// focused mode — there's one task on screen there and no list to select in, so ⌘C and ⌫ still
    /// have an obvious target.
    private var actionTargets: [Todo] {
        if tasksMode == .focused { return focusedHero.map { [$0] } ?? [] }
        return visibleTodos.filter { selection.contains(PMStore.key(for: $0)) }
    }

    /// Open the inline add editor — File ▸ New Task, and the empty state's button.
    private func beginNewTask() {
        guard store.projectName != nil else { return }
        if store.todos.isEmpty {
            addingFirstTask = true
        } else if let hero = focusedHero {
            openFocusedAdd(.after, for: hero)
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
    /// rebuild queued them all again, and the panel never settled. (The sidebar avoids the whole
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
    /// It lives *inside* the panel rather than in an alert or sheet on purpose: an unpinned panel
    /// hides as soon as it loses key focus, and a separate modal window would take that focus and
    /// pull the panel out from under its own dialog. Return deletes, Escape cancels.
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
            if !detailsShowing { Divider() }
            deleteConfirmation
        }
        .animation(.snappy, value: pendingDelete.isEmpty)
    }

    /// The scrollable content below the pinned header: the optional details brief and the task/session
    /// list. This is what scrolls under the header when it overflows the panel's max height.
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
                    if store.todos.isEmpty && !detailsExpanded {
                        emptyProjectTasks
                    } else if tasksMode == .focused {
                        focusedSection
                    } else {
                        tasksSection
                    }
                }
            }
        }
    }

    /// Report the main view's total content height (pinned header + scroll body) to the window's auto-fit.
    /// Called whenever either part is remeasured. Frozen-height behavior during the takeover is handled by
    /// its own reporting path; this only runs while the main view is showing.
    ///
    /// This is only ever the *content's* height — what the window does with it depends on the sidebar
    /// (see `PanelChromeController.fit`): hidden, the panel hugs this exactly; open, it keeps the
    /// height the user dragged it to and this just seeds the first one.
    private func reportMainHeight() {
        let total = state.headerHeight + scrollContentHeight
        measuredHeight = total
        onContentHeight(total)
    }

    /// When the active editor is a session note, the (index, session) it targets — driving the full-panel
    /// takeover editor. Nil for every other editor state.
    private var sessionNoteTakeover: (index: Int, session: Session)? {
        guard let ed = activeEditor, ed.kind == .sessionNote,
              ed.key.hasPrefix("sess:"),
              let idx = Int(ed.key.dropFirst("sess:".count)),
              let sessions = store.notes?.sessions, idx < sessions.count
        else { return nil }
        return (idx, sessions[idx])
    }

    /// The panel's max content height, matching `PanelChromeController.fit`'s cap (the tarot-card ratio, or
    /// 95% of the screen, whichever is smaller).
    private var maxContentHeight: CGFloat {
        let screen = NSScreen.main?.visibleFrame.height ?? 900
        // Keyed to the content column, not the window: the sidebar shouldn't make the panel taller.
        return min(ProjectWindow.minContentWidth * ProjectWindow.maxHeightRatio, (screen * 0.95).rounded(.down))
    }

    /// The takeover's height: never below the panel's height when it opened (so it can't shrink the
    /// panel), grown to a comfortable 70% of the max only when the panel was smaller than that, and
    /// capped at the max so long notes scroll inside the editor rather than the panel.
    ///
    /// Nil with the sidebar open: there the panel's height is the user's and the window won't resize to
    /// suit the editor, so the takeover fills the window it's given rather than asking for a height.
    private var takeoverTargetHeight: CGFloat? {
        state.sidebarVisible ? nil : min(max(measuredHeight, maxContentHeight * 0.70), maxContentHeight)
    }

    /// Escape unwinds the panel one layer at a time — the pending delete, then an open editor, then a
    /// selection — and only dismisses the panel once there's nothing left to back out of.
    private func handleEscape() {
        if !pendingDelete.isEmpty {
            pendingDelete = []
        } else if editingDetails {
            editingDetails = false
        } else if activeEditor != nil {
            activeEditor = nil
        } else if !selection.isEmpty || !state.projectSelection.isEmpty {
            selection = []
            selectionAnchor = nil
            state.clearSelections()
        } else {
            onDismiss()
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            // Title (double-click toggles the details brief) with the switcher arrow tucked after it.
            HStack(spacing: 4) {
                projectTitle
                projectSwitcherMenu
            }
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
        .padding(.horizontal, 14)
        // Equal breathing room above and below the title, so the pinned header reads as a balanced bar.
        // Constant regardless of the details toggle, so the sticky header keeps a stable height.
        .padding(.vertical, 14)
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
    /// behind it, and the switcher lives on the adjacent arrow, so the title itself carries no gesture.
    private var projectTitle: some View {
        Text(store.notes?.title.trimmed ?? store.projectName ?? "No focused project")
            .font(.title3.weight(.semibold))
            .lineLimit(1)
            .truncationMode(.tail)
    }

    /// The project switcher: a subtle chevron after the title (the macOS navigation-title / document-
    /// title idiom). Opening it lists the recent projects — each with the same completion ring the
    /// menubar draws — then "All projects…" to Raycast's searchable list for anything beyond recents.
    /// Present even with no focused project, so you can switch in from the empty state. Reads
    /// `store.recents`, warmed off-thread and shared with the menubar's switcher.
    private var projectSwitcherMenu: some View {
        Menu {
            if store.recents.isEmpty {
                Text("No recent projects").font(.caption)
            } else {
                ForEach(store.recents) { recent in
                    Button {
                        store.setFocusedProject(key: recent.projectKey)
                    } label: {
                        Label {
                            // Native menus render a single line, so the focused task rides after the
                            // name as a dimmed fragment rather than a true second line.
                            Text(recent.name)
                                + Text(recent.focusedText.map { "  —  \($0.truncated(48))" } ?? "")
                                    .foregroundColor(.secondary)
                        } icon: {
                            Image(nsImage: MenubarRing.image(fraction: recent.fraction,
                                                             hasProject: recent.total > 0, tint: nil))
                        }
                    }
                }
            }
            Divider()
            Button {
                if let url = URL(string: "raycast://extensions/shanberg/project-manager/list-projects") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Label("All projects…", systemImage: "magnifyingglass")
            }
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 18)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Switch project")
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
            Label("Focused", systemImage: "scope").tag(TasksMode.focused)
            Label("Incomplete", systemImage: "circle").tag(TasksMode.incomplete)
            Label("All", systemImage: "list.bullet").tag(TasksMode.all)
        }
        .pickerStyle(.inline)
        Divider()
        Toggle(isOn: $detailsExpanded) { Label("Show notes", systemImage: "note.text") }
        // The ⌥⌘S shortcut lives on a hidden button (see `panelShortcuts`) rather than here — a closed
        // SwiftUI menu's items aren't in the responder chain, so a key equivalent set here wouldn't fire.
        Toggle(isOn: Binding(get: { state.sidebarVisible },
                             set: { _ in state.toggleSidebar() })) {
            Label("Show projects  ⌥⌘S", systemImage: "sidebar.leading")
        }
        Divider()
        Picker("Appearance", selection: $colorMode) {
            Label("System", systemImage: "circle.lefthalf.filled").tag(PanelColorMode.system)
            Label("Light", systemImage: "sun.max").tag(PanelColorMode.light)
            Label("Dark", systemImage: "moon").tag(PanelColorMode.dark)
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
                if let icon = AppIcons.panelImage(.raycast) {
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
        let appIcon = AppIcons.panelImage(finder ? .finder : .obsidian)
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
        // blue rectangle around the whole list would be heavy in a HUD panel — and which pane has
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
    /// Empty sessions stay hidden. This is the panel's behavior when session notes aren't revealed.
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

    // MARK: Focused mode

    /// The task the focused card centers on: the truly focused todo if there is one, else the first
    /// open task so the card still has something to show.
    private var focusedHero: Todo? { store.focusedTodo ?? store.openTodos.first }

    /// Compact "what am I doing right now" card: an ancestor breadcrumb, the hero task (completable,
    /// with its due date), and a dim tappable "Next" line. Falls back to a gentle empty state when
    /// there's nothing open to focus.
    @ViewBuilder private var focusedSection: some View {
        if let hero = focusedHero {
            focusedCard(hero)
        } else {
            VStack(alignment: .center, spacing: 6) {
                Text("Nothing focused").font(.subheadline).foregroundStyle(.secondary)
                Text("All tasks complete").font(.caption).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
        }
    }

    /// The focused hero card. Right-clicking the hero opens the same `TaskMenu` as a list row; the
    /// input-driven actions (edit / add / wrap / due) open inline editors in place around the hero,
    /// mirroring the task list's per-row editing so focused mode is fully actionable, not read-only.
    private func focusedCard(_ hero: Todo) -> some View {
        let key = PMStore.key(for: hero)
        let isEditingText = activeEditor == EditorTarget(key: key, kind: .edit)
        let isEditingDue = activeEditor == EditorTarget(key: key, kind: .due)
        let isAdding = activeEditor == EditorTarget(key: key, kind: .add)
        let isWrapping = activeEditor == EditorTarget(key: key, kind: .wrap)

        return VStack(alignment: .leading, spacing: 12) {
            // Editors whose new row lands ABOVE the hero: wrap (the new parent) and Add Before.
            if isWrapping {
                InlineTextEditor(placeholder: "New parent task", submitLabel: "Wrap",
                                 leadingIcon: AnyView(TaskStatusIcon(size: heroIconSize))) { text in
                    store.wrap(hero, parentText: text)
                    activeEditor = nil
                } onCancel: { activeEditor = nil }
                    .reportEditorFrame()
            }
            if isAdding && focusedAddPosition == .before {
                focusedAddEditor(hero)
            }

            // The hero display (breadcrumb + task line) — or, while editing its text, an in-place
            // editor. The display carries the movement animation: keyed by the task's identity + text,
            // it transitions whenever the store reports a classified move (see `.animation` below), so
            // navigating tasks slides directionally and an in-place edit wipes.
            if isEditingText {
                InlineTextEditor(seed: hero.text, placeholder: "Task text", submitLabel: "Save",
                                 leadingIcon: AnyView(TaskStatusIcon(checked: hero.checked, size: heroIconSize))) { text in
                    store.editText(hero, text: text)
                    activeEditor = nil
                } onCancel: { activeEditor = nil }
                    .reportEditorFrame()
            } else {
                heroDisplay(hero)
                    .id(heroSignature(hero))
                    .transition(heroTransition(for: store.focusMove))
            }

            // Editors whose row/edit lands BELOW the hero: due edit, Add After (sibling), Add Subtask.
            if isEditingDue {
                DueEditor(seed: String((hero.dueDate ?? hero.effectiveDueDate ?? "").prefix(10)),
                          leadingIcon: AnyView(TaskStatusIcon(checked: hero.checked, size: heroIconSize))) { newDue in
                    store.setDue(hero, due: newDue)
                    activeEditor = nil
                } onCancel: { activeEditor = nil }
                    .reportEditorFrame()
            }
            if isAdding && (focusedAddPosition == .after || focusedAddPosition == .child) {
                focusedAddEditor(hero)
            }

            // The dim "Next" line, hidden while editing so the card stays calm in edit mode.
            if activeEditor == nil, let next = store.nextTodo, next != hero {
                Divider()
                HStack(spacing: 6) {
                    Text("Next").font(.caption2).foregroundStyle(.tertiary)
                    Text(next.text).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                .onTapGesture { store.focus(next) }
                .help("Focus this task")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 14)
        // Drive the hero transition off the store's move token: only a real, classified change
        // animates (incidental reloads leave the token untouched), and the direction/curve match it.
        .animation(heroAnimation(for: store.focusMove), value: store.focusMoveToken)
        // Contain the sliding hero within the card so a directional push doesn't bleed into the header
        // or the Next line.
        .clipped()
        // The whole focused card represents the active task, so a right-click anywhere in it — not
        // just on the hero line — opens the task menu. `contentShape` makes the padding/empty area
        // hit-testable too. Inline editors still show the field's own copy/paste menu on right-click.
        .contentShape(Rectangle())
        .contextMenu {
            TaskMenu(todo: hero, store: store,
                     openEditor: { openFocusedEditor($0, for: hero) },
                     openAdd: { openFocusedAdd($0, for: hero) })
        }
        .animation(.snappy, value: activeEditor)
    }

    /// The focused hero's checkbox size, shared with its inline editors so the status glyph keeps the
    /// same identity in view and edit modes.
    private var heroIconSize: CGFloat { 18 }

    /// The hero's static presentation — the ancestor breadcrumb above its completable line — as one
    /// unit, so a movement transition slides the whole identity (context included), not just the text.
    private func heroDisplay(_ hero: Todo) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let crumb = breadcrumb(for: hero) {
                Text(crumb)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            heroLine(hero)
        }
    }

    /// Identity for the hero display's transition: the task key plus its text, so both navigating to a
    /// different task (key changes) and editing the current one in place (text changes) swap identity
    /// and animate, while incidental changes (due, indent) update in place.
    private func heroSignature(_ hero: Todo) -> String { "\(PMStore.key(for: hero))|\(hero.text)" }

    /// The transition for a hero change: a directional push whose incoming edge matches the direction
    /// of travel, or an in-place wipe for a text edit.
    private func heroTransition(for move: FocusMove) -> AnyTransition {
        switch move {
        case .right: return .cornerPush(horizontal: .trailing, vertical: .bottom)  // dove into a subtask → down-right
        case .left:  return .cornerPush(horizontal: .leading,  vertical: .top)     // bubbled up to an ancestor → up-left
        case .down:  return .cornerPush(horizontal: nil,       vertical: .bottom)  // next → rises up from below
        case .up:    return .cornerPush(horizontal: nil,       vertical: .top)     // previous → drops down from above
        case .wipe:  return .wipe
        case .none:  return .identity
        }
    }

    /// The curve for a hero change — a quick snappy slide for spatial moves, a smooth ease for a wipe.
    private func heroAnimation(for move: FocusMove) -> Animation {
        move == .wipe ? .easeInOut(duration: 0.3) : .snappy(duration: 0.32)
    }

    /// The hero's completable line: a large checkbox, its text, and (when dated) a read-only due chip.
    private func heroLine(_ hero: Todo) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Button(action: { store.toggle(hero) }) {
                Image(systemName: hero.checked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: heroIconSize))
                    .foregroundStyle(hero.checked ? Color.accentColor : Color.secondary)
                    .symbolReplaceIfAvailable()
                    .bounceIfAvailable(hero.checked)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 6) {
                Text(hero.text)
                    .font(.system(size: 17, weight: .semibold))
                    .strikethrough(hero.checked, color: .secondary)
                    .foregroundStyle(hero.checked ? .secondary : .primary)
                    .lineLimit(3)
                if hero.dueDate != nil || hero.effectiveDueDate != nil {
                    staticDueChip(hero)
                }
            }
        }
    }

    /// The positional add editor for the focused card. Its slot (above/below) is chosen by the caller
    /// from `focusedAddPosition`, matching the task list's previewed insert position.
    private func focusedAddEditor(_ hero: Todo) -> some View {
        AddEditor(leadingIcon: AnyView(TaskStatusIcon(size: heroIconSize))) { text, due in
            store.addTodo(text: text, due: due, relativeTo: hero, position: focusedAddPosition)
            activeEditor = nil
        } onCancel: { activeEditor = nil }
            .reportEditorFrame()
    }

    /// Open (never toggle) the given editor kind on the focused hero — used by its context menu.
    private func openFocusedEditor(_ kind: EditorTarget.Kind, for hero: Todo) {
        activeEditor = EditorTarget(key: PMStore.key(for: hero), kind: kind)
    }

    /// Seed the focused add position, then open the add editor on the hero.
    private func openFocusedAdd(_ position: TaskInsertPosition, for hero: Todo) {
        focusedAddPosition = position
        openFocusedEditor(.add, for: hero)
    }

    /// The chain of ancestor task texts above `todo`, joined with chevrons, or nil if it's a root task.
    /// Walks the flat todo list backward, picking up one task at each shallower depth within the same
    /// session — the same structure the list indentation reflects.
    private func breadcrumb(for todo: Todo) -> String? {
        let list = store.todos
        guard let idx = list.firstIndex(where: {
            $0.sessionIndex == todo.sessionIndex && $0.lineIndex == todo.lineIndex
        }) else { return nil }
        var ancestors: [String] = []
        var wantDepth = todo.depth - 1
        var i = idx - 1
        while i >= 0, wantDepth >= 0 {
            let t = list[i]
            if t.sessionIndex == todo.sessionIndex, t.depth == wantDepth {
                ancestors.insert(t.text, at: 0)
                wantDepth -= 1
            }
            i -= 1
        }
        return ancestors.isEmpty ? nil : ancestors.joined(separator: "  ›  ")
    }

    /// Read-only due-date chip for the focused card (editing stays in list mode). Own dates read solid
    /// orange; an inherited date reads dashed and secondary, matching the list's `DueChip`.
    private func staticDueChip(_ todo: Todo) -> some View {
        let own = todo.dueDate
        let text = String((own ?? todo.effectiveDueDate ?? "").prefix(10))
        let color: Color = own != nil ? .orange : .secondary
        return Text(text)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(color, style: StrokeStyle(lineWidth: 1, dash: own != nil ? [] : [3]))
            )
            .foregroundStyle(color)
    }
}

/// How the panel's tasks area presents itself. Raw values persist via `@AppStorage`.
enum TasksMode: String {
    case focused, incomplete, all
}

/// The panel's two selectable lists. Whichever holds keyboard focus is the one arrow keys, ⌫, ⌘A and
/// ⌘C drive, and the one whose selection reads emphasized.
/// A visible task paired with the identity its row is diffed on — see `PanelView.identifiedTodos`.
struct IdentifiedTodo: Identifiable {
    let id: String
    let todo: Todo
}

/// The panel's height grip: a short grabber centred on the bottom edge, brightening on hover and
/// while held, with the vertical-resize cursor over its (taller than it looks) hit area.
///
/// The drag reports its *total* translation from where it began, and the controller applies that as
/// an absolute offset from the height at mouse-down — so the edge tracks the pointer exactly instead
/// of accumulating per-frame deltas.
private struct PanelResizeHandle: View {
    let onBegan: () -> Void
    let onChanged: (CGFloat) -> Void
    let onEnded: () -> Void

    @State private var hovering = false
    @State private var dragging = false
    /// Whether *this view* currently owns a pushed cursor. `NSCursor.push`/`pop` is a stack, so an
    /// unbalanced pair leaks: pop once too often and some other view's cursor is discarded; push once
    /// too often and the resize arrows stay on after the pointer has left. Hover-in/hover-out and
    /// drag-end can interleave in either order (a drag can end well outside the handle), so ownership
    /// is tracked explicitly rather than inferred from `hovering` and `dragging`.
    @State private var pushedCursor = false

    var body: some View {
        ZStack {
            Color.clear
            Capsule()
                .fill(Color.primary.opacity(dragging ? 0.45 : (hovering ? 0.3 : 0.12)))
                .frame(width: 32, height: 4)
        }
        .frame(maxWidth: .infinity)
        // Thin enough to sit inside the list's own bottom padding, so it isn't stealing clicks from
        // the last row.
        .frame(height: 9)
        .contentShape(Rectangle())
        // Without this the pull would be claimed by `isMovableByWindowBackground` and move the panel.
        .background(WindowDragExcluder())
        .onHover { inside in
            hovering = inside
            // Hold the cursor for the whole drag even if the pointer leaves the handle, which it will:
            // the handle stays at the window's bottom edge and the pointer runs ahead of it.
            if inside { pushCursor() } else if !dragging { popCursor() }
        }
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    if !dragging { dragging = true; onBegan() }
                    onChanged(value.translation.height)
                }
                .onEnded { _ in
                    dragging = false
                    onEnded()
                    if !hovering { popCursor() }
                }
        )
        .animation(.easeOut(duration: 0.12), value: hovering)
        // Toggling the sidebar off (or the takeover opening) removes the handle mid-hover, which would
        // otherwise leave the resize cursor pushed with nothing left to pop it.
        .onDisappear { popCursor() }
        .help("Drag to resize the panel")
        .accessibilityLabel("Resize panel")
    }

    private func pushCursor() {
        guard !pushedCursor else { return }
        pushedCursor = true
        NSCursor.resizeUpDown.push()
    }

    private func popCursor() {
        guard pushedCursor else { return }
        pushedCursor = false
        NSCursor.pop()
    }
}

extension View {
    /// Drop the system focus ring from a focusable container. The panel shows which pane has keyboard
    /// focus through its selection (emphasized vs muted) rather than a ring around the whole list, so
    /// the ring would be noise. `focusEffectDisabled` arrived in macOS 14; below it the ring stays.
    @ViewBuilder func focusRingOff() -> some View {
        if #available(macOS 14.0, *) { focusEffectDisabled() } else { self }
    }
}

/// Combined trigger for the tasks section's single implicit animation. It must fire on both the visible
/// task set changing *and* the details toggle, so the section animates on the same shared clock as the
/// details reveal above it rather than re-scoping to its own — see `tasksSection`.
private struct TasksMotionKey: Equatable {
    let todos: [Todo]
    let expanded: Bool
}

/// The panel's color-scheme override. Raw values persist via `@AppStorage`; `.system` maps to `nil`
/// so SwiftUI falls back to the OS appearance.
enum PanelColorMode: String {
    case system, light, dark
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}

/// Identifies which row has an open inline editor, and which kind. Task editors key on
/// "sessionIndex:lineIndex"; session editors key on "sess:<index>" (or "sess:new"), so the two
/// namespaces can't collide and only one editor is ever open at a time.
struct EditorTarget: Equatable {
    enum Kind { case add, due, edit, wrap, sessionLabel, sessionNote, sessionAddTask, sessionNew }
    let key: String
    let kind: Kind
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

private struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// The pinned header's natural height, measured separately from the scrollable body so the window's
/// auto-fit can target their sum (see `PanelView.reportMainHeight`).
private struct HeaderHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Applies the soft scroll-edge effect (macOS 26+) so scrolling content fades at the top/bottom edges
/// — under the pinned header and off the panel's bottom — rather than hard-clipping. A no-op on older
/// systems, where the plain clipped edge remains.
private struct SoftScrollEdges: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
        } else {
            content
        }
    }
}

// MARK: Hero edit transition (in-place wipe)

/// A soft, feathered mask reveal used when a task's text is edited in place. Editing isn't a spatial
/// event, so this deliberately avoids the directional slide of a navigation: a gently feathered edge
/// sweeps the new text in while it also crossfades (see `AnyTransition.wipe`), reading as the text
/// refreshing/shimmering in place rather than moving. Alpha-only, so it's correct in light and dark.
struct WipeModifier: ViewModifier, Animatable {
    /// 0 = fully masked (hidden), 1 = fully revealed.
    var animatableData: CGFloat

    /// Width of the soft reveal edge, as a fraction of the content — wide enough to read as a shimmer
    /// rather than a hard wipe line.
    private let feather: CGFloat = 0.35

    func body(content: Content) -> some View {
        let p = animatableData
        content.mask(
            GeometryReader { geo in
                LinearGradient(
                    stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black, location: p),
                        .init(color: .clear, location: min(1, p + feather)),
                        .init(color: .clear, location: 1),
                    ],
                    startPoint: .leading, endPoint: .trailing
                )
                .frame(width: geo.size.width, height: geo.size.height)
            }
        )
    }
}

extension AnyTransition {
    /// The in-place edit transition: a feathered mask wipe crossfaded with opacity, so an edit dissolves
    /// and shimmers in place instead of sliding like a move.
    static var wipe: AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .modifier(
                active: WipeModifier(animatableData: 0),
                identity: WipeModifier(animatableData: 1))),
            removal: .opacity
        )
    }

    /// A `push`-style slide that can travel diagonally. The built-in `.push(from:)` only moves along a
    /// single edge, but task-focus moves are usually diagonal: diving into a subtask travels
    /// down-and-right (the child is both deeper and further down the outline), and a completion bubbling
    /// up to a sibling-less ancestor travels up-and-left. `horizontal` and `vertical` name the edges the
    /// *incoming* content enters from (either may be nil for a purely vertical or horizontal move); the
    /// outgoing content leaves toward the opposite corner. Crossfaded so it reads like `.push`, and
    /// size-proportional (built from `.move`), so it scales to whatever it animates.
    static func cornerPush(horizontal: Edge?, vertical: Edge?) -> AnyTransition {
        func opposite(_ e: Edge) -> Edge {
            switch e {
            case .leading:  return .trailing
            case .trailing: return .leading
            case .top:      return .bottom
            case .bottom:   return .top
            }
        }
        var insertion: AnyTransition = .opacity
        var removal: AnyTransition = .opacity
        for edge in [horizontal, vertical].compactMap({ $0 }) {
            insertion = insertion.combined(with: .move(edge: edge))
            removal = removal.combined(with: .move(edge: opposite(edge)))
        }
        return .asymmetric(insertion: insertion, removal: removal)
    }
}

// MARK: Outside-click dismissal

/// The active inline editor reports its window-space frame so a mouse-down monitor can tell an
/// outside click (which cancels the editor) from a click within it. Only one editor is open at a
/// time, so the first non-nil frame wins.
private struct ActiveEditorFrameKey: PreferenceKey {
    static var defaultValue: CGRect?
    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) { value = value ?? nextValue() }
}

private extension View {
    /// Publish this editor's frame (SwiftUI global / window space) for the outside-click monitor.
    func reportEditorFrame() -> some View {
        background(GeometryReader { geo in
            Color.clear.preference(key: ActiveEditorFrameKey.self, value: geo.frame(in: .global))
        })
    }
}

/// Watches for left mouse-downs in its own window while an editor is open and cancels the editor when
/// the click lands outside its reported frame (swallowing that click so it only dismisses).
///
/// Scoped to one window: the app can have several project windows open, each with its own editor, and
/// a click in one of them must not dismiss another's. (It used to match on a single shared window
/// identifier, which was the same thing back when there was only ever one window.)
final class OutsideClickMonitor: ObservableObject {
    var editorFrame: CGRect?
    var onOutsideClick: (() -> Void)?
    /// The window this monitor belongs to; clicks anywhere else are left alone.
    weak var window: NSWindow?
    private var monitor: Any?

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self,
                  let window = event.window,
                  window === self.window
            else { return event }
            // SwiftUI's global space is top-left origin; AppKit's locationInWindow is bottom-left.
            guard let frame = self.editorFrame else { return event }
            let flipped = CGRect(x: frame.minX, y: window.frame.height - frame.maxY,
                                 width: frame.width, height: frame.height)
            if flipped.contains(event.locationInWindow) { return event }
            self.onOutsideClick?()
            return nil   // consume: an outside click only dismisses, it doesn't also act
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        editorFrame = nil
    }
}

/// Reports the `NSWindow` a SwiftUI subtree ended up in. Several behaviors here are per-window — the
/// outside-click monitor, the note editor's save-on-blur — and with more than one project window open
/// they need to know *which* window they're in, which SwiftUI doesn't otherwise say on macOS 13.
struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView { ReportingView(onResolve: onResolve) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ReportingView: NSView {
        let onResolve: (NSWindow?) -> Void
        init(onResolve: @escaping (NSWindow?) -> Void) {
            self.onResolve = onResolve
            super.init(frame: .zero)
        }
        @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // Deferred: `viewDidMoveToWindow` runs mid-layout, and the callback writes SwiftUI state.
            let window = self.window
            DispatchQueue.main.async { [onResolve] in onResolve(window) }
        }
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
    /// The pointer entering or leaving this row. The panel notes which row it's over so a right-click
    /// can move the highlight there before the menu opens — see `PanelView.selectForContextMenu`.
    var onHoverChanged: (Bool) -> Void = { _ in }
    /// The pasteboard payload for a drag starting on this row.
    var dragProvider: () -> NSItemProvider = { NSItemProvider() }
    var onDelete: ([Todo]) -> Void = { _ in }
    /// Commit the row's due editor. Routed through the parent so a date set on a row inside a
    /// multi-selection lands on the whole selection, like the context menu's version.
    var onSetDue: (String?) -> Void = { _ in }
    @State private var hovering = false
    /// Whether the panel's window is the key window — a selection in an inactive window is muted, as
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
    /// Hover-revealed controls (plus, "＋date") are suppressed while any editor is open, so the panel
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
                        let f = g.frame(in: .named(PanelView.taskListSpace))
                        Color.clear.preference(key: RowFramesKey.self, value: [RowFrame(
                            key: key, session: todo.sessionIndex, line: todo.lineIndex,
                            depth: todo.depth, minY: f.minY, maxY: f.maxY)])
                    })
                    // Carve the row out of the window-drag region so the mouse-drag starts an item
                    // reorder rather than moving the panel.
                    .background(WindowDragExcluder())
                    .contentShape(Rectangle())
                    // Dragging is off while any editor is open, so the panel stays calm in edit mode. No
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
                            // the panel's leftMouseUp monitor.)
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
    /// override the identity `ForEach` assigns it (see `PanelView.identifiedTodos`) and undo the
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

/// Right-click actions for a task, mirroring the hover controls plus completion/focus. Idiomatic
/// macOS per-task affordance: keyboard- and VoiceOver-accessible, and keeps the surface visually
/// clean. Shared by the task list rows and the focused-mode hero card so both offer the same menu.
/// Wording follows the rest of the app: the add positions match `AddEditor`'s Before/Subtask/After
/// picker (and Raycast's "Add Before"/"Add After"), due wording matches Raycast's "Set Due Date"/
/// "Remove Due Date", and an ellipsis marks actions that open a further input editor (as the
/// menubar does).
private struct TaskMenu: View {
    let todo: Todo
    /// The tasks the commands apply to — the whole selection when this row belongs to one, else just
    /// this row. Commands that need a single subject (edit, wrap, the positional adds) are hidden on
    /// a multi-selection rather than silently acting on one arbitrary member of it.
    var targets: [Todo] = []
    @ObservedObject var store: PMStore
    /// Open (never toggle) the given editor kind on this task.
    let openEditor: (EditorTarget.Kind) -> Void
    /// Seed the add position, then open the add editor.
    let openAdd: (TaskInsertPosition) -> Void
    var onDelete: ([Todo]) -> Void = { _ in }

    /// The set commands act on, never empty (a menu opened on a row always has that row).
    private var scope: [Todo] { targets.isEmpty ? [todo] : targets }
    private var isMulti: Bool { scope.count > 1 }
    /// A batch is "completing" unless every task in it is already done, matching `PMStore.toggleAll`.
    private var allChecked: Bool { scope.allSatisfy(\.checked) }

    var body: some View {
        if isMulti {
            Button { store.toggleAll(scope) } label: {
                allChecked
                    ? Label("Reopen \(scope.count) Tasks", systemImage: "arrow.uturn.backward")
                    : Label("Complete \(scope.count) Tasks", systemImage: "checkmark.circle")
            }
        } else if todo.checked {
            Button { store.toggle(todo) } label: { Label("Reopen", systemImage: "arrow.uturn.backward") }
        } else {
            Button { store.toggle(todo) } label: { Label("Complete", systemImage: "checkmark.circle") }
        }
        if !isMulti, !todo.checked, !todo.isFocused {
            Button { store.focus(todo) } label: { Label("Focus", systemImage: "arrow.right.circle") }
        }
        if !isMulti {
            Button { openEditor(.edit) } label: { Label("Edit Task…", systemImage: "pencil") }
        }
        Divider()
        Button { TaskPasteboard.copy(markdown: store.markdown(for: scope)) } label: {
            Label(isMulti ? "Copy \(scope.count) Tasks" : "Copy", systemImage: "doc.on.doc")
        }
        .keyboardShortcut("c", modifiers: .command)
        if !isMulti {
            Divider()
            // Add-position symbols match the menubar's Add submenu (Before ↑, Subtask ↳, After ↓).
            Button { openAdd(.before) } label: { Label("Add Before…", systemImage: "arrow.up") }
            Button { openAdd(.child) } label: { Label("Add Subtask…", systemImage: "arrow.turn.down.right") }
            Button { openAdd(.after) } label: { Label("Add After…", systemImage: "arrow.down") }
            Button { openEditor(.wrap) } label: {
                Label("Wrap Task…", systemImage: "arrow.up.and.down.and.arrow.left.and.right")
            }
            // Only a parent can be dissolved — an immediate action (no further input), so no ellipsis.
            if store.hasChildren(todo) {
                Button { store.unwrap(todo) } label: {
                    Label("Unwrap", systemImage: "arrow.up.left.and.arrow.down.right")
                }
            }
        }
        Divider()
        if isMulti {
            // A batch date needs one editor, not one per row, so it goes through the clicked row's.
            Button { openEditor(.due) } label: { Label("Set Due Date…", systemImage: "calendar") }
            if scope.contains(where: { $0.dueDate != nil }) {
                Button { store.setDueAll(scope, due: nil) } label: {
                    Label("Remove Due Dates", systemImage: "calendar.badge.minus")
                }
            }
        } else {
            Button { openEditor(.due) } label: { Label("Set Due Date…", systemImage: "calendar") }
            if todo.dueDate != nil {
                Button { store.setDue(todo, due: nil) } label: { Label("Remove Due Date", systemImage: "calendar.badge.minus") }
            }
        }
        Divider()
        // Deleting takes each task's whole subtree; the confirmation says how much that is.
        Button(role: .destructive) { onDelete(scope) } label: {
            Label(isMulti ? "Delete \(scope.count) Tasks…" : "Delete…", systemImage: "trash")
        }
        .keyboardShortcut(.delete, modifiers: .command)
        Divider()
        // Global document undo/redo — discoverable here; the ⌘Z / ⇧⌘Z shortcuts live on the panel.
        Button { store.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
            .disabled(!store.canUndo)
        Button { store.redo() } label: { Label("Redo", systemImage: "arrow.uturn.forward") }
            .disabled(!store.canRedo)
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

private extension View {
    /// Apply a modifier only when `condition` holds, leaving the view untouched otherwise. Used to
    /// attach `.onDrag` only while dragging is allowed (no open editor).
    @ViewBuilder func ifCondition<Transformed: View>(
        _ condition: Bool, transform: (Self) -> Transformed
    ) -> some View {
        if condition { transform(self) } else { self }
    }
}

/// A backing AppKit view that opts its region out of the panel's `isMovableByWindowBackground`, so a
/// mouse-drag that begins on it starts a SwiftUI `.onDrag` (item reorder) instead of being claimed by
/// AppKit as a window move. Placed behind the draggable task rows; the rest of the panel background
/// still moves the window as before.
struct WindowDragExcluder: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ExcluderView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ExcluderView: NSView {
        override var mouseDownCanMoveWindow: Bool { false }
    }
}

// MARK: Task status icon

/// A task's leading status glyph — an open circle, or a filled check when done. The inline editors
/// (edit / add / wrap / due) render it alongside their input so a task keeps the same visual identity
/// while it's being modified or created that it has as a normal row. `size` matches the surrounding
/// context (nil = the list row's default body size; the focused hero passes its larger 18pt). A
/// brand-new task (add / wrap) reads as an empty circle, since it isn't complete yet.
private struct TaskStatusIcon: View {
    var checked: Bool = false
    var size: CGFloat? = nil

    var body: some View {
        Image(systemName: checked ? "checkmark.circle.fill" : "circle")
            .font(size.map { Font.system(size: $0) } ?? .body)
            .foregroundStyle(checked ? Color.accentColor : Color.secondary)
            .symbolReplaceIfAvailable()
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

private struct DueEditor: View {
    let seed: String
    /// Optional leading status glyph, so the task keeps its identity while its due date is edited.
    let leadingIcon: AnyView?
    let onSet: (String?) -> Void
    let onCancel: () -> Void
    @State private var date: Date

    init(seed: String, leadingIcon: AnyView? = nil,
         onSet: @escaping (String?) -> Void, onCancel: @escaping () -> Void) {
        self.seed = seed
        self.leadingIcon = leadingIcon
        self.onSet = onSet
        self.onCancel = onCancel
        _date = State(initialValue: DueFormat.parse(seed) ?? Date())
    }

    var body: some View {
        HStack(spacing: 6) {
            if let leadingIcon { leadingIcon }
            DatePicker("", selection: $date, displayedComponents: .date)
                .datePickerStyle(.field)
                .labelsHidden()
            Button("Set") { onSet(DueFormat.string(date)) }
            Button("Clear") { onSet(nil) }
            Button("Cancel", action: onCancel)
        }
        .controlSize(.small)
        .padding(.vertical, 2)
    }
}

// MARK: Add editor

/// Text (+ optional due) entry for a new task. The insert position is chosen by the caller (via the
/// context menu / plus button) and previewed by where this form is placed in the row layout, so the
/// form no longer carries a position picker of its own.
private struct AddEditor: View {
    /// Optional leading status glyph (an empty circle for the not-yet-created task), so the new task
    /// reads with the same visual identity as a real row while it's being typed.
    var leadingIcon: AnyView? = nil
    let onAdd: (String, String?) -> Void
    let onCancel: () -> Void

    @State private var text = ""
    @State private var useDue = false
    @State private var date = Date()
    @FocusState private var textFocused: Bool

    var body: some View {
        // Icon leads the whole form, aligned to the text-field row; the controls below indent under
        // the field so the icon column stays clear, mirroring a task row's icon + text layout.
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let leadingIcon { leadingIcon }
            VStack(alignment: .leading, spacing: 4) {
                TextField("Task text", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .focused($textFocused)
                    .onSubmit(submit)

                HStack(spacing: 6) {
                    Toggle("Due", isOn: $useDue).toggleStyle(.checkbox)
                    if useDue {
                        DatePicker("", selection: $date, displayedComponents: .date)
                            .datePickerStyle(.field)
                            .labelsHidden()
                    }
                    Spacer()
                    Button("Add", action: submit).keyboardShortcut(.defaultAction)
                    Button("Cancel", action: onCancel)
                }
            }
        }
        .controlSize(.small)
        .padding(.vertical, 2)
        .onAppear { textFocused = true }
    }

    private func submit() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onAdd(trimmed, useDue ? DueFormat.string(date) : nil)
    }
}

// MARK: Single-field inline editor (edit text / wrap)

/// A one-line text editor used for the row's "Edit Task" (seeded with the current text) and "Wrap
/// Task" (empty, for the new parent) actions. Auto-focuses, submits on Return, cancels on Escape via
/// the panel's `handleEscape`. Matches the styling of `AddEditor`/`DueEditor`.
private struct InlineTextEditor: View {
    let placeholder: String
    let submitLabel: String
    /// Optional leading status glyph, so the task keeps its identity while its text is edited (the
    /// existing task's own checkbox state) or a wrap parent is named (an empty circle).
    let leadingIcon: AnyView?
    /// When true, an empty (blank) value is a valid submission — used by the session-label editor,
    /// where clearing the field removes the label. Task text editors leave this false so a blank
    /// submit is a no-op.
    let allowsEmpty: Bool
    let onSubmit: (String) -> Void
    let onCancel: () -> Void

    @State private var text: String
    @FocusState private var focused: Bool

    init(seed: String = "", placeholder: String, submitLabel: String, leadingIcon: AnyView? = nil,
         allowsEmpty: Bool = false,
         onSubmit: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.placeholder = placeholder
        self.submitLabel = submitLabel
        self.leadingIcon = leadingIcon
        self.allowsEmpty = allowsEmpty
        self.onSubmit = onSubmit
        self.onCancel = onCancel
        _text = State(initialValue: seed)
    }

    var body: some View {
        HStack(spacing: 6) {
            if let leadingIcon { leadingIcon }
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(submit)
            Button(submitLabel, action: submit).keyboardShortcut(.defaultAction)
            Button("Cancel", action: onCancel)
        }
        .controlSize(.small)
        .padding(.vertical, 2)
        .onAppear { focused = true }
    }

    private func submit() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard allowsEmpty || !trimmed.isEmpty else { return }
        onSubmit(trimmed)
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
            // whole panel with the rich editor — see PanelView.sessionNoteTakeover. The read view renders
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

/// The full-panel, focused editor for a session's prose note. The panel is taken over by a header
/// (Back button + the project name over the session name) and a rich `MarkdownTextEditor` with live
/// syntax highlighting and ⌘B/⌘I/⌘K shortcuts. There are no Save/Cancel buttons: the note **auto-saves**
/// whenever you leave — Back, Escape, an outside click (all remove the view → `onDisappear`), or the
/// panel losing key focus (blur-hide → `didResignKey`). `store.setSessionNote` is byte-idempotent, so a
/// repeated commit with no changes is a free no-op and yields no extra undo entry.
private struct SessionNoteTakeover: View {
    let index: Int
    let session: Session
    let projectName: String
    /// The panel height to occupy — sized by `PanelView.takeoverTargetHeight` so the takeover never
    /// shrinks the current panel, only grows a small one. Nil means "fill the window", which is the
    /// sidebar case: there the height is the user's and the takeover doesn't get to change it.
    let height: CGFloat?
    @ObservedObject var store: PMStore
    let onBack: () -> Void

    @State private var text: String
    /// The window this takeover is in, so the save-on-blur only fires for *this* window losing key.
    @State private var hostWindow: NSWindow?

    init(index: Int, session: Session, projectName: String, height: CGFloat?,
         store: PMStore, onBack: @escaping () -> Void) {
        self.index = index
        self.session = session
        self.projectName = projectName
        self.height = height
        self.store = store
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
        .ifCondition(height != nil) { $0.frame(height: height) }
        .ifCondition(height == nil) { $0.frame(maxHeight: .infinity) }
        // Cover the whole takeover as the "active editor" region so in-panel clicks count as inside it.
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
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 8)
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
    /// they're held aside verbatim and re-appended on save — the panel never destroys them.
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
    /// clickable links. Editing groups isn't supported in the panel (they round-trip untouched).
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

/// `due:` values are stored/displayed as `YYYY-MM-DD`.
enum DueFormat {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    static func parse(_ s: String) -> Date? { formatter.date(from: String(s.prefix(10))) }
    static func string(_ d: Date) -> String { formatter.string(from: d) }
}

private extension String {
    var trimmed: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
    var isBlank: Bool { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    func truncated(_ n: Int) -> String { count <= n ? self : String(prefix(n - 1)) + "…" }
}

/// SF Symbol animation modifiers, applied only where available (macOS 14+); no-ops below.
private extension View {
    @ViewBuilder func symbolReplaceIfAvailable() -> some View {
        if #available(macOS 14.0, *) { contentTransition(.symbolEffect(.replace)) } else { self }
    }
    @ViewBuilder func bounceIfAvailable<V: Equatable>(_ value: V) -> some View {
        if #available(macOS 14.0, *) { symbolEffect(.bounce, value: value) } else { self }
    }
}

/// The panel's translucent background: Liquid Glass (`NSGlassEffectView`) on macOS 26+, falling back
/// to `NSVisualEffectView` vibrancy below. Used as a SwiftUI `.background` so it fills the content's
/// layout and resizes with the auto-fit instead of fighting it.
/// The window is borderless, so this shape is the panel's shape: it rounds its own corners rather than
/// relying on the window frame to clip it, and the window's shadow follows from it.
struct PanelBackground: NSViewRepresentable {
    /// Whether the material rounds its own corners. The panel is borderless, so it has to; a real
    /// window's frame does the rounding, and doing it again inside would cut the content away from the
    /// window's own corners.
    var rounded: Bool = true

    func makeNSView(context: Context) -> NSView {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = rounded ? ProjectWindow.cornerRadius : 0
            return glass
        }
        let effect = MaskedVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.rounded = rounded
        return effect
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Pre-26 fallback background. `.behindWindow` vibrancy isn't clipped by a layer corner radius, so the
/// rounding has to go through `maskImage` — a nine-part rounded rect whose caps let AppKit stretch it to
/// whatever height the auto-fit lands on.
private final class MaskedVisualEffectView: NSVisualEffectView {
    var rounded = true

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard rounded, maskImage == nil else { return }
        let r = ProjectWindow.cornerRadius
        let side = r * 2 + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
        image.resizingMode = .stretch
        maskImage = image
    }
}

/// Fires on any left mouse-up in the app while the panel is shown. Used as a reliable end signal for a
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

/// Fires on any right mouse-down in the app while the panel is shown, so the task list can move its
/// highlight onto the row whose context menu is about to open.
///
/// This is an event monitor rather than something computed while the menu is built because SwiftUI
/// builds a row's `.contextMenu` content during the row's body pass, not on the click — so anything
/// that mutates state from there runs once per row per render (see `PanelView.contextTargets`). A
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
/// do for alternate items). Backed by a local `flagsChanged` monitor active while the panel is key.
final class ModifierMonitor: ObservableObject {
    @Published var optionDown = false
    private var monitor: Any?

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            // Only publish on a real change. `flagsChanged` fires for *every* modifier, press and
            // release — ⌘ and ⇧ included, which are exactly the keys held while multi-selecting — and
            // an unconditional write to an `@Published` republishes whether or not the value moved.
            // That rebuilt the whole panel body, sidebar list and all, several times per click.
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
