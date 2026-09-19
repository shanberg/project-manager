import AppKit
import SwiftUI
import PmLib

/// A project's notes, on a card, drawn and edited the way the project window draws and edits them.
///
/// A file card pointing at `docs/Notes - <Title>.md` is not a card showing a markdown file. It is the
/// card `createProjectCanvas` puts on every new board, and on a real board it is usually the reason the
/// board exists. Rendered as prose it came out as the raw document: `- [ ] Ship the thing due: friday`
/// as a bullet with the syntax showing, sessions as bare `## 2026-08-14` headings, `[[Other Project]]`
/// as brackets. Everything the project window spends its effort making legible, spelled out.
///
/// So it uses the same pieces, and not lookalikes: the status circle, the tokenised text through
/// `taskLineAttributed` and `TokenTextLabel`, the due chip through `DueChip`, the row's commands
/// through `TaskMenu`, the editors through `InlineTextEditor` / `DueEditor` / `AddEditor`, the prose
/// through `RenderedNote`, and the body cut into blocks by `SessionBody` — the same cut, so a task sits
/// in the sentence that put it there rather than being gathered under it.
///
/// **The store is the project's own.** It comes from `StoreRegistry`, which is the same instance the
/// project window holds, so ticking a task on a board is the same act as ticking it in the window: one
/// document, one undo stack, both surfaces updating each other with nothing to keep in step. That is
/// also why this takes a store rather than a parsed file — a snapshot would be stale the moment
/// anything else touched the project.
///
/// **Editing needs stepping in first.** Like a web card, and for the same reason: a board is mostly
/// read and moved around, and a checkbox that fired on the first click that landed near it would make
/// the board hazardous to pan across. One click steps in, and from then on the card is a project.
///
/// **Everything the window does to the notes, this does too.** It used to be tasks and nothing else —
/// tick, retype, set a date — on a premise stated out loud elsewhere: "the board is read-only", with
/// Go to Project as the way in to actually doing something. That premise is retired. A board is a
/// thinking space you also act and write in, so a session starts here, its note is written here, and
/// the brief is edited here. The line the card does *not* cross is the project as a thing on disk —
/// archiving, renaming, revealing it — which is what Go to Project is now for, rather than an
/// admission that this surface cannot do the work.
///
/// **In a tiled view that click is the same click.** There is nothing to pan across and no doubt about
/// which card you meant, so a tile takes its clicks outright and the one you click in is stepped into
/// by the act of clicking in it — see `CanvasBoardView.tileClicked`. The card cannot tell the two
/// apart and does not need to: either way, by the time a row opens an editor the keyboard is here.
struct CanvasProjectNote: View {
    var store: PMStore
    /// Whether the card has been stepped into. Only the open editor depends on it — everything else is
    /// gated by the card refusing to hit-test at all until then (`CanvasNodeView.takesItsOwnClicks`,
    /// which a tiled view grants outright), and the wheel reaches this scroll view either way
    /// (`CanvasBoardView.scrollWheel`).
    var engagement: CanvasCardEngagement
    /// The notes file itself, so a relative image embed resolves against the folder it lives in.
    let noteURL: URL
    /// Opens a project a `[[…]]` names, exactly as the window's rows do.
    var onOpenProject: (String) -> Void
    /// What the board is asking of this card — New Session and New Task, when it is the one you are
    /// standing in. See `CanvasProjectCardCommands`.
    var commands: CanvasProjectCardCommands
    /// How much of the project this card draws. See `CanvasCardShows`.
    var display: CanvasProjectCardDisplay

    /// The open inline editor, if any. One at a time, exactly as in the task list and the focus panel.
    @State private var activeEditor: EditorTarget?
    /// Which position a freshly opened add editor seeds to, set by the menu's Add commands before the
    /// editor opens.
    @State private var addPosition: TaskInsertPosition = .after
    /// The task row under the pointer, which is what reveals its "＋date". Held in an object the card's
    /// own body never reads — only `RowHoverReader`s do — so moving the pointer from row to row redraws
    /// those two rows' highlights and not the whole card. See `RowHoverState`.
    @State private var hover = RowHoverState()
    /// The picked rows. The card is the project window's list on a board, so it selects the way that
    /// list selects — the rules are `RowSelection`'s, held here rather than restated.
    ///
    /// Only tasks are rows. A session's caption is a quiet separator between groups, exactly as it is
    /// in the window's compact list, and stopping on one every few presses would only lengthen the
    /// walk from one task to the next. The window makes captions selectable only in the mode where a
    /// session is a first-class heading with its own note and commands.
    @State private var selection = RowSelection()
    /// The row under the pointer, again — as a reference, so the right-click monitor's closure reads
    /// the live value rather than the copy it captured. See `RowHoverTracker`.
    @State private var rowHover = RowHoverTracker()
    /// Moves the highlight onto a right-clicked row that isn't already picked (Finder's rule).
    @State private var rightClick = RightMouseDownMonitor()
    /// Tasks awaiting the delete confirmation. Empty when none is pending.
    @State private var pendingDelete: [Todo] = []
    /// The key of the task subtree being dragged, or nil when none is. See `TaskDropResolver`.
    @State private var draggingKey: String?
    /// The keys riding along with it, so those rows dim in place under the floating ghost. Held rather
    /// than derived per row: working it out from the store inside each row's body would walk the task
    /// list once per row, which is a quadratic redraw for a cosmetic dim.
    @State private var draggedSubtree: Set<String> = []
    /// Every visible task row's extent and depth, collected by preference, in the card's own
    /// coordinate space. What the drop delegate resolves the pointer against.
    ///
    /// In a plain box rather than `@State`: only a drop reads them, and a `@State` write re-runs the
    /// card's whole body whether or not the body reads it. Every layout that moved a row — a tile's
    /// divider being dragged, a window resized, a line wrapping differently — published new frames and
    /// so cost a second pass over every row on top of the layout itself.
    @State private var frames = DropFrames()
    /// Every drawn sitting's whole block, so a drag can light the current one to pick up into it.
    /// The one resolved insertion slot for the drag in flight — where the indicator goes and where the
    /// drop will land.
    @State private var dropTarget: DropTarget?
    /// Clears drag state on a press that never moved, which releases no provider and so fires no
    /// `DragEndSentinel`.
    @State private var mouseUp = LeftMouseUpMonitor()
    /// A row Find Next has just moved onto, for the scroll view to reveal. Bumped rather than set, so
    /// two steps onto the same row are two distinct requests.
    @State private var scrollTarget: String?
    @State private var scrollToken = 0

    /// Where a depth-0 row's content begins, and what one level of nesting costs — the pointer's depth
    /// is measured against these, so they have to be the row's real metrics. See `TaskRowMetrics`.
    private static let rowContentInset: CGFloat = TaskRowMetrics.margin
    private static let indentStep: CGFloat = TaskRowMetrics.indentStep
    /// The card's margin, either side — every block on it lines up on this.
    private static let margin: CGFloat = TaskRowMetrics.margin
    /// Where the brief and the member projects start: under the title's words, past its progress pie.
    private static let briefInset: CGFloat = TaskRowMetrics.margin + 16 + 8
    /// Associated-object key holding a drag's end sentinel on its item provider — see `DragEndSentinel`.
    private nonisolated(unsafe) static var dragSentinelKey: UInt8 = 0
    /// The session whose note has taken the card over, by index, or nil when the card is showing the
    /// project. Only the index is held here; the editor takes its own `SessionRef` on the way in and
    /// commits against that, which is what makes it safe for the list underneath to be reindexed by
    /// somebody else while it is open.
    @State private var openNote: Int?

    /// Every open parent's subtasks, done and all — see `countSubtasks`. Held rather than worked out per
    /// row, which would walk the task list once for every row drawn.
    @State private var subtaskCounts: [String: (done: Int, total: Int)] = [:]

    /// Whether the brief is being edited rather than read. The details view keeps the text; this is
    /// only which of its two faces is up.
    @State private var editingDetails = false

    /// The add editor that belongs to no task — the window's `quickAddTarget`, under the same key, for
    /// the same job: a task appended to the current session rather than placed against another one.
    private static let quickAdd = EditorTarget(key: "quick", kind: .quickAdd)

    private var notes: ProjectNotes? { store.notes }

    /// What the card draws: its lens, except a `sitting` card whose sitting can't be found, which draws
    /// the project — the fallback a typo in `pmShows` gets (docs/views.md D7).
    private var shows: CanvasCardShows {
        display.shows == .sitting && pinnedSession == nil ? .everything : display.shows
    }

    /// The one sitting a `sitting` card draws, by its index in the document.
    private var pinnedSession: Int? {
        guard display.shows == .sitting, let ref = display.sitting, let notes else { return nil }
        return CanvasSittingPin.index(of: ref, in: notes)
    }

    /// The sessions this card draws, each with the index it has in the document.
    ///
    /// The index travels with the session rather than being the position in this list, because
    /// everything downstream is addressed by it — which tasks belong to a sitting, which note a
    /// double-click opens. Index 0 is the most recent, because `addSession` inserts at the front.
    ///
    /// **Every sitting, always.** Narrowing happens in `blocks(for:at:)`, one block at a time, and it
    /// has to: a card scoped to the latest sitting's *prose* still draws the open tasks of every
    /// sitting before it, so there is no prefix of this list that describes what such a card shows. A
    /// session that ends up contributing nothing loses its caption on its own — see `session_`.
    private var shownSessions: [(index: Int, session: Session)] {
        let all = (notes?.sessions ?? []).enumerated().map { (index: $0.offset, session: $0.element) }
        guard shows == .sitting, let pinned = pinnedSession else { return all }
        return all.filter { $0.index == pinned }
    }

    /// Every visible task row's key, in the order the card is drawing them — what a ⇧-click ranges
    /// over, and what the selection is checked against when the document changes underneath it.
    ///
    /// A task drawn twice — on its own line and again under the sitting that picked it up — is one row
    /// to the selection, at the first place it is drawn: selecting it is selecting the task.
    private var visibleKeys: [String] {
        var seen = Set<String>()
        return drawnTodos.map(PMStore.key(for:)).filter { seen.insert($0).inserted }
    }

    /// Every task row the card draws, in the order it draws them, copies included.
    private var drawnTodos: [Todo] {
        func sitting(_ index: Int, _ session: Session) -> [Todo] {
            blocks(for: session, at: index).compactMap { block in
                if case .task(let identified) = block { return identified.todo }
                return nil
            } + pickedRows(into: index).map(\.row.todo)
        }
        switch shows.layout {
        case .sittings:
            return shownSessions.flatMap { sitting($0.index, $0.session) }
        case .pile(let withLatest):
            let latest = withLatest ? shownSessions.first.map { sitting($0.index, $0.session) } ?? [] : []
            return latest + pileRows(withLatest: withLatest).map(\.todo)
        }
    }

    /// The tasks whose own line is drawn somewhere on the card — where an origin chip can scroll to.
    private var originKeys: Set<String> {
        switch shows.layout {
        case .sittings:
            return Set(shownSessions.flatMap { index, session in
                blocks(for: session, at: index).compactMap { block -> String? in
                    if case .task(let identified) = block { return PMStore.key(for: identified.todo) }
                    return nil
                }
            })
        case .pile(let withLatest):
            var keys = Set(pileRows(withLatest: withLatest).map { PMStore.key(for: $0.todo) })
            if withLatest, let first = shownSessions.first {
                for case .task(let identified) in blocks(for: first.session, at: first.index) {
                    keys.insert(PMStore.key(for: identified.todo))
                }
            }
            return keys
        }
    }

    /// The tasks a row's commands act on: the whole selection when the clicked row is inside it, and
    /// just that row when it is not — `RowSelection.targets(clicked:)`, resolved back to tasks in
    /// document order.
    ///
    /// Pure, and it has to stay that way: SwiftUI builds a `.contextMenu`'s content while it builds
    /// the row, so this runs for every visible row on every pass.
    private func contextTargets(for todo: Todo) -> [Todo] {
        let keys = selection.targets(clicked: PMStore.key(for: todo))
        guard keys.count > 1 else { return [todo] }
        return store.todos.filter { keys.contains(PMStore.key(for: $0)) }
    }

    var body: some View {
        card
            .onChange(of: commands.rowStepRequest) { _, _ in
                moveSelection(commands.rowStep, extending: commands.rowStepExtends)
            }
            .onChange(of: commands.selectAllRowsRequest) { _, _ in
                selection.selectAll(in: visibleKeys)
            }
            .onChange(of: commands.deleteRowsRequest) { _, _ in requestDelete(selectedTodos) }
            // The board asks this before it decides whether ⌫ was about the rows, and it has to be
            // true *before* the key arrives — so it is published on every change to the selection
            // rather than read across the seam on demand.
            .onChange(of: selection.count) { _, count in commands.selectedRows = count }
            .onChange(of: commands.copyRowsRequest) { _, _ in
                TaskPasteboard.copy(markdown: store.markdown(for: selectedTodos))
            }
            .onChange(of: commands.pasteRowsRequest) { _, _ in pasteTasks() }
            .onChange(of: commands.openRowRequest) { _, _ in
                guard selectedTodos.count == 1, let todo = selectedTodos.first else { return }
                store.focus(todo)
            }
    }

    /// The card itself. Split from `body` only because the two together are more than the type checker
    /// will take in one expression.
    private var card: some View {
        Group {
            // Writing prose takes the card over, exactly as it takes the window's column over. Not an
            // inline field: a card is already a narrow column, and an editor inside a rendered note
            // would be a narrower one inside it. The same view as the window's, too, rather than a
            // lookalike — it has learnt things a second copy would have to learn again, starting with
            // not writing your note into whichever session has since moved into that index.
            if let index = openNote, let sessions = notes?.sessions, sessions.indices.contains(index) {
                SessionNoteTakeover(index: index, session: sessions[index],
                                    projectName: displayName, store: store,
                                    onOpenProject: onOpenProject,
                                    onBack: { openNote = nil },
                                    isActive: engagement.isEngaged,
                                    onSelectionChange: { display.noteCaret = $0 },
                                    onTypingUndo: { stack, open in
                                        // Closing one note and opening another can report in either
                                        // order, so only the stack that is leaving clears.
                                        if open { display.noteUndo = stack }
                                        else if display.noteUndo === stack { display.noteUndo = nil }
                                    })
            } else {
                list
            }
        }
        // Stepping out closes the small editors but not the session note: that one stays open where you
        // left it, and saves as focus leaves (`SessionNoteTakeover.isActive`), so an edit is never held
        // back by a card nobody is in.
        .onAppear {
            rightClick.onRightMouseDown = {
                // Only the card you are standing in. A global monitor is global, and moving the
                // highlight in a card across the board from the one you right-clicked would be a
                // selection changing where you are not looking.
                guard engagement.isEngaged, let key = rowHover.key else { return }
                selection.revealForContextMenu(key)
            }
            rightClick.start()
            mouseUp.onMouseUp = { if draggingKey != nil { draggingKey = nil; dropTarget = nil } }
            mouseUp.start()
            ProjectIndex.shared.retain()
            ProjectIndex.shared.warmAllProjects()
            // The commands object outlives this view — it belongs to the node — so a card rebuilt
            // around a fresh, empty selection has to say so rather than leave the old count standing.
            commands.selectedRows = selection.count
        }
        .onDisappear { rightClick.stop(); mouseUp.stop(); ProjectIndex.shared.release() }
        // One place to let the dim go, whichever way the drag ended — dropped, cancelled outside, or
        // released without ever moving.
        .onChange(of: draggingKey) { _, key in if key == nil { draggedSubtree = [] } }
        // A note closed any way at all takes its caret with it, so the next one opened starts where a
        // note starts.
        .onChange(of: openNote) { _, index in
            if index == nil { display.noteCaret = nil }
        }
        .onChange(of: engagement.isEngaged) { _, engaged in
            if !engaged {
                activeEditor = nil
                // A selection is a thing you are about to act on, and stepping out of the card is
                // saying you are not. Left standing it would also be a highlight on a card nobody is
                // in, which on a board of them reads as "this one is somehow current".
                selection.clear()
                pendingDelete = []
                draggingKey = nil
                dropTarget = nil
                // A card left filtered by a search you have walked away from is a card showing three
                // of its nineteen tasks with nothing on it saying why.
                display.find = ""
                // The brief's fields commit as they are left, and leaving the card is leaving the
                // field — so this closes an editor that has already written, not one being abandoned.
                editingDetails = false
            }
        }
        // Keys are document positions, so a task completed, moved or deleted — here or in the window,
        // which is the same store — leaves the selection naming rows nobody can see. Narrowing the
        // card does the same thing without touching the document, which is why the setting is watched
        // beside the tasks.
        .onChange(of: store.todos) { _, _ in
            selection.keep(within: visibleKeys)
            // A completed move reindexes the todos, so the key in the air names a different task.
            draggingKey = nil
            dropTarget = nil
        }
        .onChange(of: display.shows) { _, _ in selection.keep(within: visibleKeys) }
        // A pick made from `pm` or Raycast changes which rows are drawn without touching a task.
        .onChange(of: store.picks) { _, _ in selection.keep(within: visibleKeys) }
        // A find narrows the list without touching the document, so the same reconcile applies — and
        // the count goes back to the field that asked for it. In `onChange` rather than in the body:
        // publishing from inside a view update is a write to the thing being drawn.
        .onChange(of: display.find) { _, _ in
            selection.keep(within: visibleKeys)
            reportMatches()
        }
        .onChange(of: store.todos) { _, _ in reportMatches() }
        .onChange(of: store.todos, initial: true) { _, todos in subtaskCounts = Self.countSubtasks(todos) }
        .onChange(of: display.findStepRequest) { _, _ in stepFind(display.findStepDirection) }
        .onChange(of: commands.newSessionRequest) { _, _ in
            beginCurrentSession(forcingNew: commands.newSessionForcing)
        }
        .onChange(of: commands.newTaskRequest) { _, _ in beginTask() }
        .onChange(of: commands.editDetailsRequest) { _, _ in
            openNote = nil
            activeEditor = nil
            editingDetails = true
        }
    }

    // MARK: The list's keyboard

    /// ↑/↓ move the selection one row; ⇧ extends it from the anchor instead. With nothing selected, ↓
    /// starts at the top and ↑ at the bottom. Left and right are left alone — depth in this outline is
    /// a drag, not a keystroke, and on a board they are the board's.
    ///
    /// The rule itself is `RowSelection.step`, shared with the window's column. What is here is only
    /// the scroll that has to follow it: a selection moved past the edge of a card is a selection you
    /// cannot see, and a card is a much smaller window onto the list than the column ever was.
    private func moveSelection(_ delta: Int, extending: Bool) {
        guard let key = selection.step(delta, extending: extending, in: visibleKeys) else { return }
        scrollToken &+= 1
        scrollTarget = key
    }

    /// The tasks the selection names, in document order — what ⌘⌫ and ⌘A act on.
    ///
    /// Not `contextTargets`, which answers the different question a right-click asks (the selection, or
    /// the row you clicked outside it). A keystroke has no row under it.
    private var selectedTodos: [Todo] {
        store.todos.filter { selection.contains(PMStore.key(for: $0)) }
    }

    /// Ask to delete `todos`, surfacing the confirmation above the rows.
    ///
    /// Confirmation earns its place even though ⌘Z reverses a delete: the subtasks that ride along are
    /// the part you cannot see from the row you picked, and the prompt is where they get named. Same
    /// argument, same view, as the window's — see `TaskDeleteConfirmation`.
    private func requestDelete(_ todos: [Todo]) {
        guard !todos.isEmpty, store.projectName != nil else { return }
        activeEditor = nil
        pendingDelete = todos
    }

    /// ⌘V. Land whatever text is on the pasteboard as tasks, after the selected row's subtree — or at
    /// the end of the current session when nothing is selected.
    ///
    /// The selection moves to what arrived, the way every Mac list leaves a paste selected: it is what
    /// you would act on next, and on a card it is also the only way to see where the thing went, since
    /// a card shows a few rows of a list that may be long.
    private func pasteTasks() {
        let block = TaskPasteboard.tasksOnPasteboard()
        guard !block.isEmpty, store.projectName != nil else { return NSSound.beep() }
        let anchor = selectedTodos.count == 1 ? selectedTodos.first : nil
        let before = Set(visibleKeys)
        store.pasteTasks(block, after: anchor) {
            let arrived = visibleKeys.filter { !before.contains($0) }
            guard !arrived.isEmpty else { return }
            selection.select(arrived)
            guard let first = arrived.first else { return }
            scrollToken &+= 1
            scrollTarget = first
        }
    }

    private var list: some View {
        VStack(spacing: 0) {
            // Above the rows rather than over them, and outside the scroll view so it cannot be
            // scrolled away from: a refused batch is about the selection, and the selection is in the
            // rows right below this line.
            TaskDeleteConfirmation(
                todos: pendingDelete, store: store,
                confirm: {
                    store.deleteTasks(pendingDelete)
                    pendingDelete = []
                    // Keys are document positions, so after a delete the survivors name different
                    // tasks. Starting clean beats silently reselecting the neighbours.
                    selection.clear()
                },
                cancel: { pendingDelete = [] })
            ScrollViewReader { scroller in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    title
                    // The brief, above the work, exactly where the window puts it — and the same view,
                    // so it reads as the same printed page and edits the same way (double-click, then
                    // live rows). Drawn only when there is one: an empty brief on a card would be six
                    // lines of "Add summary…" standing between you and the sessions.
                    // `|| editingDetails`, and that is the whole of "display is not capability": a card
                    // set not to show the brief can still be told to edit it, and the brief appears for
                    // as long as you are in it. Hiding it would make Edit Details on such a card do
                    // nothing visible.
                    if shows.brief || editingDetails {
                        // Read under the title's words; edited at the card's full width, where the
                        // fields have the room they need.
                        ProjectDetailsView(notes: notes, store: store, isEditing: $editingDetails,
                                           showsPlaceholders: false,
                                           leadingInset: editingDetails ? Self.margin : Self.briefInset,
                                           trailingInset: Self.margin)
                    }
                    if shows.brief { members }
                    switch shows.layout {
                    case .sittings:
                        ForEach(shownSessions, id: \.index) { index, session in
                            session_(session, at: index)
                        }
                    case .pile(let withLatest):
                        if withLatest, let first = shownSessions.first {
                            session_(first.session, at: first.index)
                        }
                        pile(withLatest: withLatest)
                    }
                    footer
                }
                .padding(.top, 14)
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .coordinateSpace(name: TaskDropResolver.coordinateSpace)
                .onPreferenceChange(RowFramesKey.self) { frames.rows = $0 }
                .onPreferenceChange(SessionFramesKey.self) { frames.sessions = $0 }
                .overlay(alignment: .topLeading) { dropIndicator }
                // **Only the app's own tasks.** The window's list also takes text and files dragged in
                // from elsewhere; a card cannot, because the board underneath it is already the target
                // for those — a file dropped on a board becomes a card, and a card that quietly ate
                // the drop instead would make where you let go matter in a way nothing says.
                .onDrop(of: [TaskPasteboard.taskKeysType], delegate: ListDropDelegate(
                    isActive: { draggingKey != nil },
                    onCompute: { computeDropTarget(at: $0) },
                    onUpdate: { dropTarget = $0 },
                    onPerform: { performListDrop($0) },
                    onComputeExternal: { _ in nil },
                    onDropExternal: { _, _ in false }
                ))
            }
            .onChange(of: scrollToken) { _, _ in
                guard let key = scrollTarget else { return }
                withAnimation(.easeOut(duration: 0.15)) { scroller.scrollTo(key, anchor: .center) }
            }
            }
        }
    }

    /// The single insertion indicator: a caret dot and a rule at the resolved slot's Y, indented to the
    /// depth the drop will use. The same mark the window's list paints, so a reorder looks like a
    /// reorder on either surface.
    @ViewBuilder private var dropIndicator: some View {
        // A pick-up lands on the whole sitting, not between two of its rows, so the whole sitting is
        // what lights (docs/sessions.md D1). A gap there would promise a position the pick won't take.
        if let target = dropTarget, let lit = target.lit {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.accentColor.opacity(0.08))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor, lineWidth: 1.5))
                .frame(height: max(lit.maxY - lit.minY, 0))
                .padding(.horizontal, 6)
                .offset(y: lit.minY)
                .allowsHitTesting(false)
        } else if let target = dropTarget {
            HStack(spacing: 0) {
                Circle().fill(Color.accentColor).frame(width: 6, height: 6)
                Capsule().fill(Color.accentColor).frame(height: 2)
            }
            .padding(.leading, Self.rowContentInset + CGFloat(target.depth) * Self.indentStep)
            .padding(.trailing, Self.margin)
            // Centre the 6pt dot on the boundary line.
            .offset(y: target.gapY - 3)
            .allowsHitTesting(false)
        }
    }

    /// Resolve a pointer into an insertion slot. The geometry is `TaskDropResolver`'s; this supplies
    /// only what the card knows — the rows it drew, and which of them are riding along in the drag.
    ///
    /// No session frames as slots. A card captions a session only when that session puts something on
    /// it, so there is no empty session drawn here to drop *into*.
    ///
    /// **Across sittings it picks up** (D1): the current sitting's block is offered whole, when
    /// something in the drag can still be picked up into it, and ⌥ — read live, so pressing it
    /// mid-drag changes the answer — turns that back into a move.
    private func computeDropTarget(at point: CGPoint) -> DropTarget? {
        guard let key = draggingKey,
              let dragged = store.todos.first(where: { PMStore.key(for: $0) == key })
        else { return nil }
        let current = pickTarget(for: dragged).flatMap { index in frames.sessions.first { $0.index == index } }
        return TaskDropResolver.resolve(pointer: point,
                                        rows: frames.rows,
                                        sessionFrames: [],
                                        draggedSubtree: store.subtreeKeys(of: dragged),
                                        contentInset: Self.rowContentInset,
                                        indentStep: Self.indentStep,
                                        from: dragged.sessionIndex,
                                        pickingUpInto: current,
                                        moving: NSEvent.modifierFlags.contains(.option))
    }

    /// The sitting a drag of `todo` would pick up into: the current one, when it is the latest drawn and
    /// not about to be replaced by a new one, and something in the drag isn't already there. A project
    /// left past the idle window has no current sitting on the card to aim at — the pick would start
    /// one — so there, a drag only reorders.
    private func pickTarget(for todo: Todo) -> Int? {
        guard !store.willStartNewSession, let current = store.todaySessionIndex,
              contextTargets(for: todo).contains(where: store.canPickUp)
        else { return nil }
        return current
    }

    /// Commit a resolved drop: move the dragged subtree, then clear the drag.
    private func performListDrop(_ target: DropTarget) -> Bool {
        guard let key = draggingKey,
              let source = store.todos.first(where: { PMStore.key(for: $0) == key })
        else { return false }
        switch target.destination {
        case let .beside(session, line, after):
            guard let anchor = store.todos.first(where: {
                $0.sessionIndex == session && $0.lineIndex == line
            }) else { return false }
            store.moveSubtree(source, anchor: anchor, insertAfter: after, depth: target.depth)
        case let .endOfSession(index):
            store.moveSubtree(source, toSession: index)
        case .pickUp:
            // The whole drag, the way it was lifted: a selection picks up together, as one step.
            store.pickUp(contextTargets(for: source).filter(store.canPickUp))
        }
        draggingKey = nil
        dropTarget = nil
        return true
    }

    /// What a dragged row carries: the whole selection when the row you grabbed is part of one, else
    /// just that row — the same rule the window's drag follows, and the same rule its context menu
    /// follows. Private keys for this list's own drop, markdown for every other app.
    private func dragProvider(for todo: Todo) -> NSItemProvider {
        let dragged = contextTargets(for: todo)
        return TaskPasteboard.itemProvider(keys: dragged.map(PMStore.key(for:)),
                                           markdown: store.markdown(for: dragged))
    }

    /// The quick add, and the two dead ends.
    ///
    /// **The dead ends keep their row even now the title has buttons**, because the two say different
    /// things. A `+` is a verb you already know you want; "Start a session" on a project that has never
    /// had one is a sentence telling you what this surface is for. It is scaffolding, and it goes away
    /// the moment it has been used once — which is the test for whether an empty state has earned its
    /// place.
    @ViewBuilder private var footer: some View {
        if activeEditor == Self.quickAdd {
            // Drawn under the sitting it writes to when the card draws one (`quickAddEditor`); here only
            // for a card with no sitting to put it in, such as a Tasks card.
            if quickAddHost == nil { quickAddEditor }
        } else if engagement.actsImmediately, activeEditor == nil, store.hasLoaded {
            // `hasLoaded`, because a store that has not read the file yet has no sessions and no tasks
            // — which is indistinguishable from a project that has neither, and would put "Start a
            // session" on a card that is about to show you six.
            if notes?.sessions.isEmpty != false {
                startRow("Start a session", symbol: "calendar.badge.plus") { beginCurrentSession() }
            } else if store.todos.isEmpty, shows.tasks != .none {
                startRow("Add a task", symbol: "plus") { activeEditor = Self.quickAdd }
            }
        }
    }

    /// The sitting the quick add is drawn under: the latest, which is the one an unanchored add joins
    /// (`PMStore.addTodo`). Nil when this card draws no sitting, and the editor falls to the footer.
    private var quickAddHost: Int? {
        if case .pile(false) = shows.layout { return nil }
        return shownSessions.first?.index
    }

    private var quickAddEditor: some View {
        AddEditor(leadingIcon: AnyView(TaskStatusIcon()),
                  onOpenProject: onOpenProject) { text, due in
            store.addTodo(text: text, due: due)
            activeEditor = nil
        } onCancel: { activeEditor = nil }
            .padding(.horizontal, Self.margin)
            .padding(.top, 4)
    }

    /// A dead end's way out: a plain row, in the task rows' own metrics, saying the one thing there is
    /// to do here. Quiet — it is scaffolding that disappears the moment it has been used once.
    private func startRow(_ title: String, symbol: String,
                          action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 11))
                Text(title).font(.system(size: TaskRowMetrics.textSize))
            }
            .foregroundStyle(.tertiary)
            .padding(.horizontal, Self.margin)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The document's own title. The project window puts this in its header pill; a card has no header,
    /// so it goes where the file actually keeps it — at the top, as a heading.
    ///
    /// Named from the *filename* until the store's first read lands. Acquiring a store starts a file
    /// read, and until it finishes `notes` is nil — so a board of project cards came up as a screenful
    /// of blank rectangles for as long as that took, which is exactly the moment a card most needs to
    /// say what it is. The notes file is named for its project, so the name is already in hand.
    /// What this card calls the project — its own title once the store has read it, the filename until
    /// then. Also what the note takeover puts in its header, which is why it is a property rather than
    /// a local.
    private var displayName: String {
        notes?.title.isEmpty == false ? notes!.title : filenameTitle
    }

    /// This project's row in the folder scan — where its master and members are known.
    private var indexEntry: PMStore.ProjectEntry? {
        guard let key = store.projectKey else { return nil }
        return store.allProjects.first { $0.projectKey == key }
    }

    /// A master's members, and a member's master (docs/combining-projects.md M1).
    ///
    /// With the brief, since both are facts about what the project *is* rather than about its work. The
    /// members are the folder scan's rows, so each carries its own progress and next task, and a click
    /// opens that project the way a `[[…]]` does. The card holds the scan open while it is up
    /// (`ProjectIndex.retain`), since a board with no sidebar would otherwise never warm it.
    @ViewBuilder private var members: some View {
        let entry = indexEntry
        let rows = (entry?.members ?? []).compactMap { name in store.allProjects.first { $0.name == name } }
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                BriefLabel("Projects")
                    .padding(.bottom, 1)
                ForEach(rows) { member in
                    Button { onOpenProject(member.name) } label: { memberRow(member) }
                        .buttonStyle(.plain)
                }
            }
            .padding(.leading, Self.briefInset)
            .padding(.trailing, Self.margin)
            .padding(.bottom, 12)
        }
    }

    /// A member project, the way Things lists a project in an area: its progress as a pie, its name,
    /// and what is next in it, quietly, after.
    private func memberRow(_ member: PMStore.ProjectEntry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Group {
                if member.isArchived {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                } else {
                    ProgressPie(done: member.ownDone, total: member.ownTotal, tint: .secondary,
                                showsProgress: member.showsProgress)
                        .frame(width: 11, height: 11)
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                }
            }
            .help(member.isArchived ? "Done"
                  : !member.showsProgress ? "Ongoing"
                  : member.ownTotal > 0 ? "\(member.ownDone) of \(member.ownTotal) done" : "No tasks")
            Text(member.shortName)
                .font(.system(size: 12.5))
                .lineLimit(1)
                .layoutPriority(1)
            if let task = member.nextTask {
                Text(task)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .opacity(member.isArchived ? 0.6 : 1)
    }

    @ViewBuilder private var title: some View {
        let name = displayName
        if !name.isEmpty {
            // A member's master, as the crumb above the title — where a thing's parent goes — rather
            // than a line under it that read like the first line of the brief.
            if let master = indexEntry?.partOf {
                Button { onOpenProject(master) } label: {
                    HStack(spacing: 3) {
                        Text(projectTitle(fromFolderName: master))
                        Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Part of \(projectTitle(fromFolderName: master))")
                .padding(.horizontal, Self.margin)
                .padding(.bottom, 3)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                // How far through the project is, as a pie before its name — Things' project mark.
                // Not before the file has been read: an empty pie there would be a claim of nothing
                // done that the next moment contradicts.
                let progress = store.progress
                ProgressPie(done: progress.done, total: progress.total, tint: .accentColor,
                            showsProgress: store.kind.showsProgress)
                    .frame(width: 16, height: 16)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
                    .opacity(store.hasLoaded ? 1 : 0)
                    .help(!store.kind.showsProgress ? "Ongoing — nothing to finish"
                          : progress.total > 0 ? "\(progress.done) of \(progress.total) done" : "No tasks yet")
                Text(name)
                    .font(.system(size: 17, weight: .semibold))
                    .lineLimit(2)
                    .foregroundStyle(store.hasLoaded ? AnyShapeStyle(.primary)
                                                     : AnyShapeStyle(.secondary))
                Spacer(minLength: 8)
                // Only once the file has been read. A store still loading has no project to add to,
                // and a button that does nothing on the press you actually make is worse than one that
                // arrives a moment later.
                if store.hasLoaded, store.projectName != nil {
                    titleButton("plus", "New Task", action: beginTask)
                    // ⌥ on the click is ⌥ New Session, as it is in the File menu.
                    titleButton("calendar.badge.plus", "New Session",
                                help: "New Session — hold ⌥ to start another, unless this one is still empty") {
                        beginCurrentSession(forcingNew: NSEvent.modifierFlags.contains(.option))
                    }
                }
            }
            .padding(.horizontal, Self.margin)
            .padding(.bottom, 6)
        }
    }

    /// The two verbs a project card is for, beside the name of the project they act on.
    ///
    /// **These are the first controls this card has grown**, and the rule they break was worth
    /// breaking. Everything else here is reached the way the window reaches it — a menu, a key —
    /// because a card that grew buttons the window has not got would be saying the two surfaces are
    /// different things. They are not two surfaces any more: the window's notes *are* this card
    /// (docs/canvas-workspaces.md §7d), so a control here is a control there, and starting a session
    /// or adding a task is not something you should have to know a menu to do.
    ///
    /// On a board, the first click steps into the card and the second presses the button — the same
    /// rule that governs every other target on it (`CanvasNodeView.takesItsOwnClicks`). In a tiled view
    /// the tile takes its clicks outright, so the press lands first time.
    private func titleButton(_ symbol: String, _ title: String, help: String? = nil,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(CardTitleButtonStyle())
        .help(help ?? title)
        .accessibilityLabel(Text(title))
    }

    /// `Notes - Walkable.md` is the Walkable project. The prefix is the convention `getNotesPath`
    /// writes; the rest is the title.
    private var filenameTitle: String {
        let name = noteURL.deletingPathExtension().lastPathComponent
        return name.hasPrefix("Notes - ") ? String(name.dropFirst("Notes - ".count)) : name
    }

    /// A sitting, published whole so a drag can light it (`TaskDropResolver`, D1). One stack with no
    /// spacing inside a list with none, so wrapping it changes nothing drawn.
    private func session_(_ session: Session, at index: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) { sessionContent(session, at: index) }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(SessionFrameReporter(index: index))
    }

    @ViewBuilder private func sessionContent(_ session: Session, at index: Int) -> some View {
        let blocks = blocks(for: session, at: index)
        let picked = pickedRows(into: index)
        let caption = session.label.isEmpty ? session.date : "\(session.date) · \(session.label)"
        // A sitting is captioned when it puts something on the card. Narrowed to tasks, a session whose
        // whole content was prose contributes nothing and would otherwise leave a date standing over
        // the next session's work.
        //
        // **Except a session with nothing in it at all**, which is a heading in the file and has to be
        // one on the card too — or New Session makes something you can't see, and can't delete
        // (docs/tile-sessions.md D3). Only where the card shows this session's prose, since writing in
        // it is the first thing an empty sitting is for, and not while a find is narrowing the card.
        let isEmpty = session.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let showsEmpty = isEmpty && shows.showsProse(ofSessionAt: index) && display.find.isEmpty
        if (!blocks.isEmpty || !picked.isEmpty || showsEmpty), !caption.isEmpty {
            SessionHeading(session: session)
                .padding(.horizontal, Self.margin)
                .padding(.top, 10)
                .padding(.bottom, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { openNote = index }
                .contextMenu { sessionMenu(at: index) }
        }
        if showsEmpty { emptySession(at: index) }
        ForEach(blocks) { block in
            switch block {
            case .prose(_, let text):
                RenderedNote(prose: text, font: .systemFont(ofSize: TaskRowMetrics.textSize),
                             noteURL: noteURL, maxImageHeight: 240)
                    .padding(.horizontal, Self.margin)
                    .padding(.vertical, 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    // The window's gesture, on the window's object: double-clicking a session's prose
                    // opens its note. Same act, same surface, whichever one you are looking at it
                    // through — which is the rule the task row's double-click already follows.
                    .onTapGesture(count: 2) { openNote = index }
                    .contextMenu { sessionMenu(at: index) }
            case .task(let identified):
                row(identified.todo)
            }
        }
        // The new-task field at the end of the sitting's own tasks — where the task it makes will be.
        if activeEditor == Self.quickAdd, quickAddHost == index { quickAddEditor }
        // **Picked up**: the older tasks taken up in this sitting, after its own, each still carrying
        // where it came from. Drawn here *and* on its own line — one task in two places, both showing
        // its state — because moving it here would take it out of the sentence that explains it
        // (docs/sessions.md D5).
        if !picked.isEmpty {
            groupCaption("Picked up")
            ForEach(picked) { entry in
                row(entry.row.todo, place: .picked(into: index), showsOrigin: entry.row.showsOrigin)
            }
        }
    }

    /// D5's pile: every open task not already on the card, in one group, newest origin first — in place
    /// of a caption per sitting, each row carrying the chip that says which sitting it is from.
    ///
    /// Captioned **Still open** under the latest sitting, where it is the second of two groups; a Tasks
    /// card is nothing but the pile, and a caption over the only thing on the card says nothing.
    @ViewBuilder private func pile(withLatest: Bool) -> some View {
        let rows = pileRows(withLatest: withLatest)
        if !rows.isEmpty, withLatest {
            groupCaption("Still open").padding(.top, shownSessions.isEmpty ? 0 : 8)
        }
        ForEach(rows) { entry in
            row(entry.row.todo, showsOrigin: entry.row.showsOrigin)
        }
    }

    /// A group's caption inside the card — Picked up and Still open — in the brief's label style: a
    /// sub-heading under a sitting's heading, not a second kind of heading.
    private func groupCaption(_ text: String) -> some View {
        BriefLabel(text)
            .padding(.horizontal, Self.margin)
            .padding(.top, 8)
            .padding(.bottom, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The task trees picked up into the sitting at `index` that this card draws: the finished lines
    /// only where the card draws finished work, and only what the find leaves standing. Each tree's
    /// root carries the origin chip; the lines under it are indented beneath it and don't repeat it.
    private func pickedRows(into index: Int) -> [PileEntry] {
        SessionPicks.pickedUp(into: index, picks: store.picks, todos: store.todos)
            .filter { shows.showsTask(checked: $0.todo.checked) && matches($0.todo) }
            .map { PileEntry(id: "picked\(index)/\(PMStore.key(for: $0.todo))", row: $0) }
    }

    /// The pile's rows, identified the way a sitting's are — by raw line and occurrence within its
    /// sitting — so a completion that reindexes the list slides the rows below rather than
    /// cross-fading them.
    private func pileRows(withLatest: Bool) -> [PileEntry] {
        var seen: [String: Int] = [:]
        let latest = withLatest ? shownSessions.first?.index : nil
        return SessionPicks.pile(todos: store.todos, excluding: latest, picks: store.picks) {
            shows.showsTask(checked: $0.checked) && matches($0)
        }.map { row in
            let occurrence = "\(row.todo.sessionIndex)/\(row.todo.rawLine)"
            let n = seen[occurrence, default: 0]
            seen[occurrence] = n + 1
            return PileEntry(id: "\(occurrence)#\(n)", row: row)
        }
    }

    /// What an empty session offers in place of content: the two things a sitting with nothing in it
    /// yet is for. Quiet, in the caption's own tone, because it is scaffolding for a moment rather than
    /// part of the project.
    ///
    /// **Add a task only on today's newest session**, because that is where an unanchored add lands —
    /// an empty heading is always the one a write joins. Offered on an older empty session it would
    /// put the task somewhere else, which is the button lying about where it writes.
    @ViewBuilder private func emptySession(at index: Int) -> some View {
        HStack(spacing: 10) {
            quietAction("Write a note", symbol: "square.and.pencil") { openNote = index }
            if index == store.todaySessionIndex {
                quietAction("Add a task", symbol: "plus") { beginTask() }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Self.margin)
        .padding(.vertical, 2)
        .contextMenu { sessionMenu(at: index) }
    }

    private func quietAction(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .labelStyle(.titleAndIcon)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: A task, and the editors that open on it

    @ViewBuilder private func row(_ todo: Todo, place: RowPlace = .origin,
                                  showsOrigin: Bool = false) -> some View {
        let key = rowID(todo, place)
        VStack(alignment: .leading, spacing: 0) {
            if activeEditor == EditorTarget(key: key, kind: .edit) {
                InlineTextEditor(seed: todo.text, placeholder: "Task text", submitLabel: "Save",
                                 leadingIcon: AnyView(TaskStatusIcon(state: todo.state)),
                                 onOpenProject: onOpenProject) { text in
                    store.editText(todo, text: text)
                    activeEditor = nil
                } onCancel: { activeEditor = nil }
                    .padding(.horizontal, Self.margin)
            } else {
                line(todo, place: place, showsOrigin: showsOrigin)
            }
            if activeEditor == EditorTarget(key: key, kind: .due) {
                DueEditor(seed: todo.dueDate ?? "",
                          leadingIcon: AnyView(TaskStatusIcon(state: todo.state))) { due in
                    store.setDue(todo, due: due)
                    activeEditor = nil
                } onCancel: { activeEditor = nil }
                    .padding(.horizontal, Self.margin)
            }
            if activeEditor == EditorTarget(key: key, kind: .waiting) {
                InlineTextEditor(seed: todo.waiting ?? "", placeholder: "Waiting on…",
                                 submitLabel: "Save",
                                 leadingIcon: AnyView(TaskStatusIcon(state: todo.state)),
                                 onOpenProject: onOpenProject) { text in
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    store.setWaiting(todo, waiting: trimmed.isEmpty ? nil : trimmed)
                    activeEditor = nil
                } onCancel: { activeEditor = nil }
                    .padding(.horizontal, Self.margin)
            }
            if activeEditor == EditorTarget(key: key, kind: .add) {
                AddEditor(leadingIcon: AnyView(TaskStatusIcon()),
                          onOpenProject: onOpenProject) { text, due in
                    store.addTodo(text: text, due: due, relativeTo: todo, position: addPosition)
                    activeEditor = nil
                } onCancel: { activeEditor = nil }
                    .padding(.horizontal, Self.margin)
                    .padding(.leading, indent(todo.depth + (addPosition == .child ? 1 : 0)))
            }
        }
    }

    /// One task: its status, its words, and when it is due — the window's `taskLine`, minus the
    /// controls a board has no room for and minus the drag a board would fight.
    private func line(_ todo: Todo, place: RowPlace, showsOrigin: Bool) -> some View {
        // Two keys, because a picked-up task is drawn twice. `key` is the task — what the selection,
        // the context menu and the right-click reveal act on, so either row selects the same thing.
        // `rowID` is this drawing of it — what hover and an open editor belong to, so pointing at one
        // copy doesn't light up the other and an editor opens where you asked for it.
        let key = PMStore.key(for: todo)
        let rowID = rowID(todo, place)
        let isOrigin = place == .origin
        let size = TaskRowMetrics.textSize
        let editingDue = activeEditor == EditorTarget(key: rowID, kind: .due)
        let editorClosed = activeEditor == nil
        let dueChip = RowHoverReader(hover: hover, id: rowID) { hovering in
            DueChip(todo: todo,
                    isEditing: editingDue,
                    reveal: hovering,
                    onPick: { store.setDue(todo, due: $0) },
                    onPickCustom: { open(.due, on: todo, place: place) })
        }
        return HStack(alignment: .firstTextBaseline, spacing: TaskRowMetrics.gap) {
            Button { store.toggle(todo) } label: {
                TaskStatusIcon(state: todo.state, size: TaskRowMetrics.boxSize(depth: todo.depth))
                    .frame(width: TaskRowMetrics.boxColumn)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(todo.checked ? "Reopen" : "Complete")

            // The words, what follows them, and "＋date" on hover — see `TaskLineLayout` for why the
            // badges give way to the words rather than the other way round.
            TaskLineLayout {
                TokenTextLabel(attributed: taskLineAttributed(todo, wait: store.wait(for: todo),
                                                              size: size),
                               onOpenProject: onOpenProject)
                    .alignmentGuide(.firstTextBaseline) { _ in
                        TokenTextLabel.firstBaseline(size: size, focused: todo.isFocused)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    // Said on the task's own line, and in the pile: the sitting it was written in has
                    // since picked it up. Not on the copy under Picked up, which is standing in that
                    // sitting.
                    if isOrigin, let day = SessionPicks.pickedDay(todo) {
                        HStack(alignment: .firstTextBaseline, spacing: 2) {
                            Image(systemName: "arrow.up.right")
                            Text(day)
                        }
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .fixedSize()
                        .help("Picked up on \(day)")
                    }
                    if showsOrigin { originChip(todo) }
                    // A parent says how far through its subtasks it is, the way Things counts a
                    // checklist. Only while it is open: a finished parent's count is a record nobody is
                    // working from.
                    if todo.state == .open, let count = subtaskCounts[key], count.total > 0 {
                        Text("\(count.done)/\(count.total)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .fixedSize()
                            .help("\(count.done) of \(count.total) subtasks done")
                    }
                    if todo.dueDate != nil {
                        dueChip
                    } else if let due = InheritedOverdueDot.due(for: todo) {
                        InheritedOverdueDot(due: due)
                    }
                }

                // Revealed on hover, exactly as in the window, and over the words' end rather than
                // beside them. Shown unconditionally it put a dashed "＋date" on every dateless task on
                // the card at once; laid out invisibly it cost every one of them the chip's width.
                if todo.dueDate == nil {
                    dueChip.background {
                        let selected = selection.contains(key)
                        let emphasized = engagement.isEngaged
                        RowHoverReader(hover: hover, id: rowID) { hovering in
                            if hovering || editingDue {
                                DueGhostBacking(isSelected: selected, isEmphasized: emphasized,
                                                isHovering: hovering && editorClosed)
                            }
                        }
                    }
                }
            }
        }
        .onHover { inside in
            hover.set(rowID, inside: inside)
            rowHover.set(key, inside: inside)
        }
        .padding(.leading, Self.margin + indent(todo.depth))
        .padding(.trailing, Self.margin)
        .padding(.vertical, 3)
        // Before the band in the chain, so drawn over its tint: a selected subtask keeps its threads.
        .background(TaskThreads(depth: todo.depth, leading: Self.margin))
        // Outside the depth indent, so a subtask's highlight starts where every other row's does — a
        // band that stepped in with the text would read as a second kind of row. The same view the
        // window's list paints, so a selection looks like a selection wherever you made it.
        //
        // "Emphasized" is the card being stepped into. That is what standing in this list means on a
        // board, and it is the same distinction AppKit draws between a selection in the focused
        // control and the same selection in one beside it.
        .background(bandView(key: key, rowID: rowID, editorClosed: editorClosed))
        // The row's breathing room is *inside* the published frame, so adjacent rows tile edge to edge
        // and the gaps the drop delegate computes abut with no dead bands between them.
        //
        // Only a task's own line: a drop is resolved against where lines *are*, and a copy under
        // Picked up is not where its line is.
        .ifCondition(isOrigin) { view in view.background(GeometryReader { geometry in
            let frame = geometry.frame(in: .named(TaskDropResolver.coordinateSpace))
            Color.clear.preference(key: RowFramesKey.self, value: [RowFrame(
                key: key, session: todo.sessionIndex, line: todo.lineIndex,
                depth: todo.depth, minY: frame.minY, maxY: frame.maxY)])
        }) }
        // In the background, so `ForEach`'s own identity for the row is left alone — an `.id` on the
        // row itself would replace it and undo the stable-across-reindex animations.
        .background(Color.clear.frame(width: 0, height: 0).id(rowID))
        .contentShape(Rectangle())
        // **Drag a task to move it**, which the card could not do before: reordering was the window's
        // and a board was where you read. It is the same drag, resolved by the same
        // `TaskDropResolver`, and rightward still means "make this a child of the row above".
        //
        // Off while an editor is open, so the list stays still in edit mode — and gated on the card
        // being stepped into, because until then the board owns this drag and it moves the card. That
        // is the same line `CanvasNodeView.takesItsOwnClicks` already draws; in a tiled view, where
        // there is nowhere to move a card to, the card has the drag from the first press.
        //
        // Not the copy under Picked up, for the reason it publishes no frame. Dragging an old task onto
        // today's sitting picks it up (D1); ⌥ makes it a move.
        .ifCondition(isOrigin && activeEditor == nil && engagement.actsImmediately) { view in
            view.onDrag {
                let dragged = key
                draggingKey = dragged
                draggedSubtree = store.subtreeKeys(of: todo)
                let provider = dragProvider(for: todo)
                // The drag's real end — a drop, or a cancel outside — releases the provider and so
                // this sentinel, which is the only notice `.onDrag` gives that it is over.
                let sentinel = DragEndSentinel { [dragging = $draggingKey] in
                    if dragging.wrappedValue == dragged { dragging.wrappedValue = nil }
                }
                objc_setAssociatedObject(provider, &Self.dragSentinelKey, sentinel,
                                         .OBJC_ASSOCIATION_RETAIN)
                return provider
            }
        }
        // Dim the dragged subtree in place, under the ghost floating over it.
        .opacity(draggedSubtree.contains(key) ? 0.35 : 1)
        .animation(.easeOut(duration: 0.15), value: draggedSubtree.contains(key))
        // Double-click *activates* — focuses the task — exactly as it does in the project window. It
        // used to open the text editor here, which meant the same gesture on the same object meant two
        // different things depending on which surface you were looking at it through. The surface is
        // not the thing; the task is.
        //
        // ⌥ double-click edits the text, and so does the context menu's Edit.
        //
        // **A single click selects**, which it did not use to: the card had no selection to keep, so a
        // click that changed nothing visible would have looked broken. It has one now — the window's,
        // with the window's ⇧ and ⌘ — because a list you can only act on one row at a time is a list
        // missing the thing this app says out loud everywhere else: you say which ones, then you say
        // what to do. The gesture is the row's, not the checkbox's, so the whole band is one target.
        //
        // **One tap gesture that reads the click count, not a `count: 2` gesture beside a single one.**
        // A double-tap gesture on the row makes SwiftUI hold every single click inside it for the
        // system's double-click interval, to see whether a second one follows — and that includes the
        // checkbox's Button, so ticking a task painted a third of a second (or more) after the click.
        // Reading `clickCount` fires on each click as it lands: the first selects, the second
        // activates, which is also the order Finder does it in.
        .onTapGesture {
            if NSApp.currentEvent?.clickCount == 2 {
                if NSEvent.modifierFlags.contains(.option) || todo.checked {
                    open(.edit, on: todo, place: place)
                } else {
                    store.focus(todo)
                }
            } else {
                selection.click(key, modifiers: NSEvent.modifierFlags, in: visibleKeys)
            }
        }
        .contextMenu { LazyMenu {
            TaskMenu(todo: todo, targets: contextTargets(for: todo), store: store,
                     openEditor: { open($0, on: todo, place: place) },
                     openAdd: { position in
                         addPosition = position
                         open(.add, on: todo, place: place)
                     },
                     // Asked rather than done, exactly as the window asks — and now for the reason the
                     // window gives, since a card can delete a whole selection at once and the
                     // subtasks riding along are the part you cannot see from the rows you picked.
                     onDelete: { todos in
                         guard !todos.isEmpty, store.projectName != nil else { return }
                         activeEditor = nil
                         pendingDelete = todos
                     },
                     onGoToProject: { key in
                         guard let folder = PMFiles.projectName(fromKey: key) else { return }
                         onOpenProject(folder)
                     })
        } }
    }

    /// The row's selection band, reading the hover itself so the row's body doesn't have to.
    private func bandView(key: String, rowID: String, editorClosed: Bool) -> some View {
        let selected = selection.contains(key)
        let emphasized = engagement.isEngaged
        return RowHoverReader(hover: hover, id: rowID) { hovering in
            RowSelectionBand(isSelected: selected, isEmphasized: emphasized,
                             isHovering: hovering && editorClosed)
        }
    }

    /// A subtask's step in: its box under its parent's first word. See `TaskRowMetrics`.
    private func indent(_ depth: Int) -> Double { Double(depth) * TaskRowMetrics.indentStep }

    /// How many of each task's descendants are done, keyed like a row. One walk, in document order,
    /// with the ancestors on a stack — a task is a descendant of everything above it on the stack.
    /// A dropped subtask is neither done nor left to do, so it is not counted at all.
    static func countSubtasks(_ todos: [Todo]) -> [String: (done: Int, total: Int)] {
        var out: [String: (done: Int, total: Int)] = [:]
        var stack: [Todo] = []
        for todo in todos {
            if let last = stack.last, last.sessionIndex != todo.sessionIndex { stack.removeAll() }
            while let last = stack.last, last.depth >= todo.depth { stack.removeLast() }
            if todo.state != .dropped {
                for ancestor in stack {
                    let key = PMStore.key(for: ancestor)
                    var count = out[key] ?? (0, 0)
                    count.total += 1
                    if todo.state == .done { count.done += 1 }
                    out[key] = count
                }
            }
            stack.append(todo)
        }
        return out
    }

    /// Whether a task survives the find. Its own text only, not its ancestors': filtering by a parent
    /// would pull in every child of a matching task and read as "3 matches" over a dozen rows — the
    /// same call the window's list makes.
    private func matches(_ todo: Todo) -> Bool {
        guard let query = display.find.trimmed?.lowercased() else { return true }
        return todo.text.lowercased().contains(query)
    }

    /// What a session offers on a card: its note, the next sitting, and — for a session with no tasks —
    /// deleting it.
    ///
    /// Renaming happens in the note takeover's header, where the label is shown beside the date it
    /// decorates. Delete is offered only where the write would take it: `session.delete` refuses a
    /// session with tasks, and a menu item that fails is worse than one that isn't there
    /// (docs/tile-sessions.md D2). New Session has its ⌥ alternate here as in the File menu.
    @ViewBuilder private func sessionMenu(at index: Int) -> some View {
        Button(sessionHasNote(index) ? "Edit Note" : "Add Note") { openNote = index }
        Divider()
        Button("New Session") { beginCurrentSession() }
            .modifierKeyAlternate(.option) {
                Button("Start a New Session") { beginCurrentSession(forcingNew: true) }
            }
        Button("New Task") { beginTask() }
        if !store.hasTasks(sessionIndex: index), let ref = store.sessionRef(at: index) {
            Divider()
            Button("Delete Session") {
                if openNote == index { openNote = nil }
                store.deleteSession(ref)
            }
        }
    }

    private func sessionHasNote(_ index: Int) -> Bool {
        guard let sessions = notes?.sessions, sessions.indices.contains(index) else { return false }
        return !sessionNoteBody(body: sessions[index].body)
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// New Session, meaning the *current* one: the sitting the project is already in, or a new one when
    /// it has none for today or has been left alone long enough that this counts as new work. The same
    /// `openCurrentSession` the window's File ▸ New Session calls, so a session started from a board and
    /// a session started from a window are the same session and obey the same idle window.
    ///
    /// It lands in the note with the caret ready, for the window's reason: a session you have just asked
    /// for is one you are about to write in, and dropping an empty heading into the card and leaving you
    /// to find your way into it would be the long way round to the same place.
    private func beginCurrentSession(forcingNew: Bool = false) {
        guard store.projectName != nil else { return }
        activeEditor = nil
        // Only on success: a session that couldn't be opened leaves whatever note was showing alone.
        store.openCurrentSession(forcingNew: forcingNew) { index in if let index { openNote = index } }
    }

    /// New Task: appended to the current session rather than placed against a row, which is what the
    /// window's own no-anchor add does. The anchored kinds live on `TaskMenu`, where the anchor is the
    /// row the menu was opened on.
    private func beginTask() {
        guard store.projectName != nil else { return }
        openNote = nil
        activeEditor = Self.quickAdd
    }

    /// ⌘G / ⇧⌘G. This find narrows rather than highlighting, so there is no "next highlight" to jump
    /// to: the shortened list *is* the matches, and stepping means moving the selection down it — the
    /// the same answer the page find gives. Wraps at both ends, as every find in the system does.
    private func stepFind(_ direction: Int) {
        let keys = visibleKeys
        guard !keys.isEmpty else { return NSSound.beep() }
        let current = selection.single.flatMap(keys.firstIndex(of:))
        let next = current.map { ($0 + direction + keys.count) % keys.count }
            ?? (direction > 0 ? 0 : keys.count - 1)
        selection.select([keys[next]])
        scrollTarget = keys[next]
        scrollToken &+= 1
    }

    /// Tell the find field how many rows its query left standing. Guarded, because writing the same
    /// number back would publish a change and ask for another pass to say it again.
    private func reportMatches() {
        let count = display.find.trimmed == nil ? nil : visibleKeys.count
        if display.matches != count { display.matches = count }
    }

    private func open(_ kind: EditorTarget.Kind, on todo: Todo, place: RowPlace = .origin) {
        activeEditor = EditorTarget(key: rowID(todo, place), kind: kind)
    }

    /// This drawing of a task: its key on its own line, and the key under the sitting that picked it up
    /// for the copy drawn there.
    private func rowID(_ todo: Todo, _ place: RowPlace) -> String {
        switch place {
        case .origin: return PMStore.key(for: todo)
        case .picked(let into): return "picked\(into)/\(PMStore.key(for: todo))"
        }
    }

    /// Where an old task came from, quietly: its sitting's date. Hovering says the sentence it was
    /// written beside; clicking goes there — to its own line when the card draws it, and otherwise into
    /// that sitting's note, which is the one place its sentence is always drawn.
    private func originChip(_ todo: Todo) -> some View {
        Button {
            let key = PMStore.key(for: todo)
            if originKeys.contains(key) {
                selection.select([key])
                scrollTarget = key
                scrollToken &+= 1
            } else {
                openNote = todo.sessionIndex
            }
        } label: {
            Text(SessionPicks.day(iso: todo.sessionISODate) ?? "Earlier")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color.primary.opacity(0.06)))
                .fixedSize()
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(SessionPicks.originHelp(todo, sessions: notes?.sessions ?? [], tasks: store.todos))
    }

    /// The session's body, cut where its tasks are, and narrowed to what this card shows.
    ///
    /// **Both narrowings land here, and they are asked separately** — `showsProse(ofSessionAt:)` takes
    /// the index, `showsTask(checked:)` takes the task — which is what lets one card draw the latest
    /// sitting's words alongside every sitting's open work. The id is built the way the window builds
    /// it, raw line plus occurrence, because two identical task lines in one session are two rows and
    /// `ForEach` misbehaves on duplicate ids.
    private func blocks(for session: Session, at index: Int) -> [SessionBlock] {
        var seen: [String: Int] = [:]
        let all = SessionBody.blocks(body: session.body,
                                     tasks: store.todos.filter { $0.sessionIndex == index }) { todo in
            // The closure that answers "is this row being drawn" — which on a card used to always say
            // yes, there being no Incomplete filter and no find bar to narrow it. Now the card has a
            // narrowing of its own, and this is where it lands. Every task is still *passed in*, hidden
            // or not, or the walk loses its place against the body's lines.
            //
            // The find comes last because it is the cheap test that most often fails on a card nobody
            // is searching: `matches` short-circuits to true when there is no query.
            guard shows.showsTask(checked: todo.checked), self.matches(todo) else { return nil }
            let n = seen[todo.rawLine, default: 0]
            seen[todo.rawLine] = n + 1
            return IdentifiedTodo(id: "\(index)/\(todo.rawLine)#\(n)", todo: todo)
        }
        guard !shows.showsProse(ofSessionAt: index) else { return all }
        return all.filter { if case .prose = $0 { return false } else { return true } }
    }
}

/// What the last layout published about where the rows are — read when a drop resolves, and by nothing
/// that draws. See `CanvasProjectNote.frames`.
@MainActor
final class DropFrames {
    var rows: [RowFrame] = []
    var sessions: [SessionFrame] = []
}

/// A row's context menu, built only when the menu opens.
///
/// SwiftUI runs a `.contextMenu`'s content closure for every row on every pass — twice, in practice —
/// and it is the closure that decides the menu's targets, which with a selection is a walk of the whole
/// task list per selected row. A view's *body* is not run until the menu is shown, so the work is put
/// there, and reads the selection as it is at that moment rather than as it was at the last pass.
private struct LazyMenu<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View { content() }
}

/// Which row drawing the pointer is over.
///
/// Observed, and read **only** by `RowHoverReader`. The card used to hold this as `@State`, which made
/// every hover change an invalidation of the card's whole body: every row rebuilt, re-attributed and
/// re-measured to move a 5% tint from one row to the next. Read from a leaf view instead, the same
/// change re-runs a handful of leaf bodies and nothing that lays text out.
@MainActor
@Observable
final class RowHoverState {
    private(set) var current: String?

    /// `inside` false only clears the row that is still current — rows can report leaving after the
    /// next one reports entering. Writes only on a change, since an observed write announces itself
    /// whether or not the value moved.
    func set(_ id: String, inside: Bool) {
        if inside {
            if current != id { current = id }
        } else if current == id {
            current = nil
        }
    }
}

/// A leaf that reads the hover for one row and hands the answer to `content`, so the row around it
/// isn't the thing that depends on the pointer.
private struct RowHoverReader<Content: View>: View {
    let hover: RowHoverState
    let id: String
    @ViewBuilder let content: (Bool) -> Content

    var body: some View { content(hover.current == id) }
}

/// A row of the pile with the identity it is diffed on.
private struct PileEntry: Identifiable {
    let id: String
    let row: PileRow
    var todo: Todo { row.todo }
}

/// What the board asks of the project card you are standing in.
///
/// **Counters, not flags**, on the pattern `ProjectWindowState` already uses for the window's File menu:
/// a command is an event, and the same command given twice in a row has to fire twice. A flag set to
/// true and back would be a change SwiftUI might never see.
///
/// The board cannot call into this card's SwiftUI directly — the card is an `NSHostingView` inside an
/// `NSView` — and this is the seam the window already has for the same problem, in the same shape.
@MainActor
@Observable
final class CanvasProjectCardCommands {
    private(set) var newSessionRequest = 0
    /// Whether the last New Session asked for a new sitting outright — ⌥ New Session. Read with the
    /// request rather than observed on its own.
    @ObservationIgnored
    private(set) var newSessionForcing = false
    private(set) var newTaskRequest = 0
    private(set) var editDetailsRequest = 0

    func requestNewSession(forcingNew: Bool = false) {
        newSessionForcing = forcingNew
        newSessionRequest &+= 1
    }
    func requestNewTask() { newTaskRequest &+= 1 }
    func requestEditDetails() { editDetailsRequest &+= 1 }

    // MARK: The list's keyboard

    /// ↑/↓, ⌘A and ⌘⌫, which reach a card through the board rather than through SwiftUI focus.
    ///
    /// **The board is the only place that can tell what they mean.** Every one of the three is a key
    /// the board already answers about its *cards* — arrow to the next one, select them all, delete
    /// them — and a card that claimed them from inside SwiftUI would be claiming them for the whole
    /// window, whether or not you were standing in it. So the board asks first, exactly as it does for
    /// find and for the zoom commands: inside a card, they mean the card. See
    /// `CanvasBoardView.projectCardTakes(_:)`.
    private(set) var rowStepRequest = 0
    @ObservationIgnored
    private(set) var rowStep = 1
    @ObservationIgnored
    private(set) var rowStepExtends = false
    private(set) var selectAllRowsRequest = 0
    private(set) var deleteRowsRequest = 0

    /// How many rows are selected, written back by the card. The board reads it to decide whether ⌫
    /// is about the rows at all — with nothing picked out, a delete in a project card is not a delete
    /// of nothing, it is a delete of the *card*, which is what the board would have done anyway.
    var selectedRows = 0

    func stepRows(_ step: Int, extending: Bool) {
        rowStep = step
        rowStepExtends = extending
        rowStepRequest &+= 1
    }

    func requestSelectAllRows() { selectAllRowsRequest &+= 1 }
    func requestDeleteRows() { deleteRowsRequest &+= 1 }

    private(set) var copyRowsRequest = 0
    private(set) var pasteRowsRequest = 0
    private(set) var openRowRequest = 0

    func requestCopyRows() { copyRowsRequest &+= 1 }
    func requestPasteRows() { pasteRowsRequest &+= 1 }
    func requestOpenRow() { openRowRequest &+= 1 }
}

/// How much of its project a card is drawing, published so a change made from the menu **redraws**
/// rather than rebuilds.
///
/// The setting lives on the node in the document (`CanvasCardShows`); this is the card's live copy of
/// it. Rebuilding the hosting view would work and would be simpler, and it would also throw away the
/// scroll position and any open editor — for a change whose whole purpose is to adjust what you are
/// looking at while you look at it.
@MainActor
@Observable
final class CanvasProjectCardDisplay {
    var shows = CanvasCardShows.default
    /// The sitting a `sitting` card draws, from `pmSitting`.
    var sitting: SessionRef?

    /// What the board's find is looking for, while this is the card you are standing in.
    ///
    /// **Not persisted, unlike `shows`.** A card's parts are something you set and would resent
    /// forgetting; a search is something you are doing right now, and a card that came back tomorrow
    /// still showing three of its nineteen tasks would be a card that looked broken.
    ///
    /// It narrows rather than highlighting, which is what the window's find bar does to the same list —
    /// see `visibleKeys`. The board's own find selects matching *cards*, and the page
    /// card's goes into the page; this is the third of the same rule, which is that find looks inside
    /// whatever you have stepped into.
    var find = ""

    /// The open note's caret, as it moves. Not observed: it is read only on the way out.
    @ObservationIgnored
    var noteCaret: NSRange?
    /// The open note's own undo stack, while a note is open — what ⌘Z means on this card until it
    /// closes. See `CanvasBoardView.engagedCardUndoManager` and `SessionNoteTakeover.typing`.
    @ObservationIgnored
    var noteUndo: UndoManager?

    /// How many task rows the query left standing, written back by the card so the find field can say
    /// so. Nil while nothing is being searched for — which is not the same as zero, and the field says
    /// nothing rather than "0" for it.
    var matches: Int?

    /// Find Next / Find Previous, as a counter for the reason `CanvasProjectCardCommands` gives: the
    /// same command twice in a row has to fire twice, and a flag set and unset is a change nobody sees.
    private(set) var findStepRequest = 0
    @ObservationIgnored
    private(set) var findStepDirection = 1

    func stepFind(_ direction: Int) {
        findStepDirection = direction
        findStepRequest &+= 1
    }
}

/// Whether a card has been stepped into, published so its SwiftUI content can react.
///
/// The engagement itself belongs to `CanvasNodeView`, which is AppKit and tells nobody. A card whose
/// content needs to know — to start taking scroll wheels, to drop an open editor on the way out — gets
/// one of these and the node view writes through it.
@MainActor
@Observable
final class CanvasCardEngagement {
    var isEngaged = false
    /// Whether the board is currently tiled — kept in step by `CanvasFileNodeView.refreshTiledness`,
    /// which is `CanvasNodeView.takesItsOwnClicks` for this card's SwiftUI content: a tile takes its
    /// clicks outright, so a control gated on "has this card been stepped into" should read as stepped
    /// into from the first press in a tile, rather than waiting for the click `isEngaged` is earned by
    /// on a freeform board.
    var isTiled = false
    /// Whether a control that only makes sense once the card is "yours" should act — stepped into on a
    /// freeform board, or in any tile at all. See `isTiled`.
    var actsImmediately: Bool { isEngaged || isTiled }
}

/// The project a notes file belongs to, and the store that holds it.
///
/// Nil when the file isn't one of PM's notes files, or when the folder names no project PM knows — in
/// either case the card falls back to rendering it as the markdown it is, which is the right failure: a
/// note PM cannot make sense of is still a note somebody wrote, and showing it plainly beats showing
/// nothing.
///
/// The store is retained here and must be given back — see `CanvasFileNodeView.prepareForRemoval`.
@MainActor
enum CanvasProjectSource {
    static func projectKey(for url: URL) -> String? {
        guard let folder = projectFolder(ofNotesPath: url.path) else { return nil }
        return ProjectIndex.shared.projectKey(forFolder: (folder as NSString).lastPathComponent)
    }
}

/// A project card's title buttons: a glyph that says it is a button when the pointer is on it.
///
/// Plain, they were two grey glyphs that did nothing under the pointer until pressed — the only
/// controls on the card with no hover at all, and nothing about them said they were controls. The
/// highlight is the toolbar's: a rounded fill that comes up under the glyph, a little stronger while
/// pressed, and the glyph going from secondary to primary.
private struct CardTitleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Hovered(configuration: configuration)
    }

    private struct Hovered: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false

        var body: some View {
            configuration.label
                // Tertiary at rest: two verbs beside the title, there when you look for them and not
                // competing with the name they act on.
                .foregroundStyle(hovering || configuration.isPressed ? .primary : .tertiary)
                .padding(3)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(.quaternary)
                        .opacity(configuration.isPressed ? 1 : hovering ? 0.7 : 0)
                )
                .padding(-3)
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
    }
}

/// Progress as Things draws it beside a project: a ring, filled as a pie by how much is done.
///
/// A pie rather than a bar or "3/8", because it is read at a glance and at eleven points — the fraction
/// is in the tooltip for anyone who wants the number.
///
/// Something with nothing to finish — an area — gets the dashed ring the menubar and the switcher give
/// it, rather than a pie stuck at empty that would say it hadn't been started.
struct ProgressPie: View {
    let done: Int
    let total: Int
    var tint: Color = .accentColor
    var showsProgress = true

    private var fraction: Double { total > 0 ? min(Double(done) / Double(total), 1) : 0 }

    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            let line = max(side / 11, 1.1)
            ZStack {
                if showsProgress {
                    Circle().strokeBorder(tint, lineWidth: line)
                    PieSlice(fraction: fraction)
                        .fill(tint)
                        .padding(line * 2)
                } else {
                    Circle().strokeBorder(tint, style: StrokeStyle(lineWidth: line, dash: [line * 1.6]))
                }
            }
            .frame(width: side, height: side)
        }
        .accessibilityElement()
        .accessibilityLabel(Text(showsProgress ? "\(done) of \(total) done" : "Ongoing"))
    }

    private struct PieSlice: Shape {
        var fraction: Double
        var animatableData: Double {
            get { fraction }
            set { fraction = newValue }
        }

        func path(in rect: CGRect) -> Path {
            var path = Path()
            guard fraction > 0 else { return path }
            let center = CGPoint(x: rect.midX, y: rect.midY)
            path.move(to: center)
            path.addArc(center: center, radius: min(rect.width, rect.height) / 2,
                        startAngle: .degrees(-90), endAngle: .degrees(-90 + 360 * fraction),
                        clockwise: false)
            path.closeSubpath()
            return path
        }
    }
}

/// A sitting's heading on a card: which day it was, in the accent, its name after it, and the date and
/// time it began at the far end — with a hairline under it, so a card of sittings reads as sections of one
/// document rather than as one list with dates scattered through it. Things' heading, Craft's rule.
struct SessionHeading: View {
    let session: Session

    var body: some View {
        let heading = SessionDay.heading(session.date, time: session.startTime)
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                // The name, not the label: the label on disk carries the time too, which is said at
                // the far end with the date rather than run into the name.
                (Text(heading.day).foregroundStyle(Color.accentColor)
                 + Text(session.name.isEmpty ? "" : " · \(session.name)").foregroundStyle(.secondary)
                    .fontWeight(.regular))
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
                Spacer(minLength: 8)
                if let detail = heading.detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            Rectangle()
                .fill(Color.primary.opacity(0.09))
                .frame(height: 1)
        }
        .help(heading.full)
    }
}

/// What the hover "＋date" sits on: the card and the row's band over it, faded in from the left, so the
/// chip reads as laid on the end of the words rather than printed across them.
private struct DueGhostBacking: View {
    let isSelected: Bool
    let isEmphasized: Bool
    let isHovering: Bool
    var fade: CGFloat = 16

    var body: some View {
        ZStack {
            Color(nsColor: CanvasPalette.card)
            RowSelectionFill(isSelected: isSelected, isEmphasized: isEmphasized, isHovering: isHovering)
        }
        .mask {
            HStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                    .frame(width: fade)
                Color.black
            }
        }
        .padding(.leading, -fade)
        .padding(.vertical, -2)
        .allowsHitTesting(false)
    }
}
