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
    /// The task row under the pointer, which is what reveals its "＋date".
    @State private var hovering: String?
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
    @State private var rowFrames: [RowFrame] = []
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
    /// is measured against these, so they have to be the row's real metrics. A card's step is half the
    /// window's for the reason `indent(_:)` gives: a card is a narrower column.
    private static let rowContentInset: CGFloat = 12
    private static let indentStep: CGFloat = 11
    /// Associated-object key holding a drag's end sentinel on its item provider — see `DragEndSentinel`.
    private nonisolated(unsafe) static var dragSentinelKey: UInt8 = 0
    /// The session whose note has taken the card over, by index, or nil when the card is showing the
    /// project. Only the index is held here; the editor takes its own `SessionRef` on the way in and
    /// commits against that, which is what makes it safe for the list underneath to be reindexed by
    /// somebody else while it is open.
    @State private var openNote: Int?

    /// Whether the brief is being edited rather than read. The details view keeps the text; this is
    /// only which of its two faces is up.
    @State private var editingDetails = false

    /// The add editor that belongs to no task — the window's `quickAddTarget`, under the same key, for
    /// the same job: a task appended to the current session rather than placed against another one.
    private static let quickAdd = EditorTarget(key: "quick", kind: .quickAdd)

    private var notes: ProjectNotes? { store.notes }

    /// Reopen the note this card was left in, at the caret it was left at — see `returnTo`.
    ///
    /// Once: a return that has happened is spent, so stepping out of the list and back in again is the
    /// list. A session that can no longer be found — deleted, or edited out of recognition while you were
    /// in another tile — is a return with nowhere to go, and the card shows the project instead.
    private func returnToNote() {
        guard let returning = display.returnTo else { return }
        display.returnTo = nil
        guard let notes, let resolved = try? resolveSessionRef(returning.ref, notes: notes) else { return }
        display.returnCaret = returning.caret
        openNote = resolved.index
    }
    private var shows: CanvasCardShows { display.shows }

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
        (notes?.sessions ?? []).enumerated().map { (index: $0.offset, session: $0.element) }
    }

    /// Every visible task row's key, in the order the card is drawing them — what a ⇧-click ranges
    /// over, and what the selection is checked against when the document changes underneath it.
    private var visibleKeys: [String] {
        shownSessions.flatMap { index, session in
            blocks(for: session, at: index).compactMap { block in
                if case .task(let identified) = block { return PMStore.key(for: identified.todo) }
                return nil
            }
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
                                    startsAt: display.returnCaret,
                                    onSelectionChange: { display.noteCaret = $0 })
            } else {
                list
            }
        }
        // Stepping out closes whatever was open. An editor left standing on a card you have walked away
        // from is a text field with the keyboard nowhere near it, holding an edit that will never be
        // committed. The note takeover is the exception that proves it: it saves on the way out, so
        // closing it here is a commit rather than a discard.
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
            // The commands object outlives this view — it belongs to the node — so a card rebuilt
            // around a fresh, empty selection has to say so rather than leave the old count standing.
            commands.selectedRows = selection.count
        }
        .onDisappear { rightClick.stop(); mouseUp.stop() }
        // One place to let the dim go, whichever way the drag ended — dropped, cancelled outside, or
        // released without ever moving.
        .onChange(of: draggingKey) { _, key in if key == nil { draggedSubtree = [] } }
        // A note closed any way at all takes its caret with it, so the next one opened — by a
        // double-click, not a return — starts where a note starts.
        .onChange(of: openNote) { _, index in
            if index == nil { display.returnCaret = nil; display.noteCaret = nil }
        }
        .onChange(of: engagement.isEngaged) { _, engaged in
            if engaged {
                returnToNote()
            } else {
                // **Held for coming back**, before the note closes. Stepping out still closes it — one
                // card is engaged at a time, and the header, undo routing and New Session all lean on
                // that — but stepping back in reopens it where the caret was (backlog 24). By
                // reference, since the note is saved on the way out and the sessions can move before
                // you are back.
                display.returnTo = openNote.flatMap { index in
                    store.sessionRef(at: index).map { (ref: $0, caret: display.noteCaret) }
                }
                activeEditor = nil
                openNote = nil
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
        // A find narrows the list without touching the document, so the same reconcile applies — and
        // the count goes back to the field that asked for it. In `onChange` rather than in the body:
        // publishing from inside a view update is a write to the thing being drawn.
        .onChange(of: display.find) { _, _ in
            selection.keep(within: visibleKeys)
            reportMatches()
        }
        .onChange(of: store.todos) { _, _ in reportMatches() }
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
                        ProjectDetailsView(notes: notes, store: store, isEditing: $editingDetails,
                                           showsPlaceholders: false)
                    }
                    ForEach(shownSessions, id: \.index) { index, session in
                        session_(session, at: index)
                    }
                    footer
                }
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .coordinateSpace(name: TaskDropResolver.coordinateSpace)
                .onPreferenceChange(RowFramesKey.self) { rowFrames = $0 }
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
        if let target = dropTarget {
            HStack(spacing: 0) {
                Circle().fill(Color.accentColor).frame(width: 6, height: 6)
                Capsule().fill(Color.accentColor).frame(height: 2)
            }
            .padding(.leading, Self.rowContentInset + CGFloat(target.depth) * Self.indentStep)
            .padding(.trailing, 12)
            // Centre the 6pt dot on the boundary line.
            .offset(y: target.gapY - 3)
            .allowsHitTesting(false)
        }
    }

    /// Resolve a pointer into an insertion slot. The geometry is `TaskDropResolver`'s; this supplies
    /// only what the card knows — the rows it drew, and which of them are riding along in the drag.
    ///
    /// No session frames. A card captions a session only when that session puts something on it, so
    /// there is no empty session drawn here to drop *into* — the window's list is the surface where an
    /// empty sitting is a first-class row with somewhere to aim.
    private func computeDropTarget(at point: CGPoint) -> DropTarget? {
        guard let key = draggingKey,
              let dragged = store.todos.first(where: { PMStore.key(for: $0) == key })
        else { return nil }
        return TaskDropResolver.resolve(pointer: point,
                                        rows: rowFrames,
                                        sessionFrames: [],
                                        draggedSubtree: store.subtreeKeys(of: dragged),
                                        contentInset: Self.rowContentInset,
                                        indentStep: Self.indentStep)
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
            AddEditor(leadingIcon: AnyView(TaskStatusIcon()),
                      onOpenProject: onOpenProject) { text, due in
                store.addTodo(text: text, due: due)
                activeEditor = nil
            } onCancel: { activeEditor = nil }
                .padding(.horizontal, 12)
                .padding(.top, 4)
        } else if engagement.isEngaged, activeEditor == nil, store.hasLoaded {
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

    /// A dead end's way out: a plain row, in the task rows' own metrics, saying the one thing there is
    /// to do here. Quiet — it is scaffolding that disappears the moment it has been used once.
    private func startRow(_ title: String, symbol: String,
                          action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 11))
                Text(title).font(.system(size: 12.5))
            }
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 12)
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

    @ViewBuilder private var title: some View {
        let name = displayName
        if !name.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(name)
                    .font(.system(size: 14, weight: .semibold))
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
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
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

    @ViewBuilder private func session_(_ session: Session, at index: Int) -> some View {
        let blocks = blocks(for: session, at: index)
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
        if (!blocks.isEmpty || showsEmpty), !caption.isEmpty {
            Text(caption)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 12)
                .padding(.vertical, 3)
                .padding(.top, index == 0 ? 0 : 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { openNote = index }
                .contextMenu { sessionMenu(at: index) }
        }
        if showsEmpty { emptySession(at: index) }
        ForEach(blocks) { block in
            switch block {
            case .prose(_, let text):
                RenderedNote(prose: text, font: .systemFont(ofSize: 12.5),
                             noteURL: noteURL, maxImageHeight: 240)
                    .padding(.horizontal, 12)
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
        .padding(.horizontal, 12)
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

    @ViewBuilder private func row(_ todo: Todo) -> some View {
        let key = PMStore.key(for: todo)
        VStack(alignment: .leading, spacing: 0) {
            if activeEditor == EditorTarget(key: key, kind: .edit) {
                InlineTextEditor(seed: todo.text, placeholder: "Task text", submitLabel: "Save",
                                 leadingIcon: AnyView(TaskStatusIcon(checked: todo.checked)),
                                 onOpenProject: onOpenProject) { text in
                    store.editText(todo, text: text)
                    activeEditor = nil
                } onCancel: { activeEditor = nil }
                    .padding(.horizontal, 12)
            } else {
                line(todo)
            }
            if activeEditor == EditorTarget(key: key, kind: .due) {
                DueEditor(seed: todo.dueDate ?? "",
                          leadingIcon: AnyView(TaskStatusIcon(checked: todo.checked))) { due in
                    store.setDue(todo, due: due)
                    activeEditor = nil
                } onCancel: { activeEditor = nil }
                    .padding(.horizontal, 12)
            }
            if activeEditor == EditorTarget(key: key, kind: .waiting) {
                InlineTextEditor(seed: todo.waiting ?? "", placeholder: "Waiting on…",
                                 submitLabel: "Save",
                                 leadingIcon: AnyView(TaskStatusIcon(checked: todo.checked)),
                                 onOpenProject: onOpenProject) { text in
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    store.setWaiting(todo, waiting: trimmed.isEmpty ? nil : trimmed)
                    activeEditor = nil
                } onCancel: { activeEditor = nil }
                    .padding(.horizontal, 12)
            }
            if activeEditor == EditorTarget(key: key, kind: .add) {
                AddEditor(leadingIcon: AnyView(TaskStatusIcon()),
                          onOpenProject: onOpenProject) { text, due in
                    store.addTodo(text: text, due: due, relativeTo: todo, position: addPosition)
                    activeEditor = nil
                } onCancel: { activeEditor = nil }
                    .padding(.horizontal, 12)
                    .padding(.leading, indent(todo.depth + (addPosition == .child ? 1 : 0)))
            }
        }
    }

    /// One task: its status, its words, and when it is due — the window's `taskLine`, minus the
    /// controls a board has no room for and minus the drag a board would fight.
    private func line(_ todo: Todo) -> some View {
        let key = PMStore.key(for: todo)
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Button { store.toggle(todo) } label: {
                TaskStatusIcon(checked: todo.checked, size: 12.5)
            }
            .buttonStyle(.plain)
            .help(todo.checked ? "Reopen" : "Complete")

            TokenTextLabel(attributed: taskLineAttributed(todo, wait: store.wait(for: todo),
                                                          size: 12.5),
                           onOpenProject: onOpenProject)
                .alignmentGuide(.firstTextBaseline) { _ in
                    TokenTextLabel.firstBaseline(size: 12.5, focused: todo.isFocused)
                }
                .fixedSize(horizontal: false, vertical: true)
                // Sized before the spacer beside it: both are flexible, and an HStack splits what is
                // left between its flexible children — so without this the words and the empty gap take
                // half the card each and every task wraps.
                .layoutPriority(1)

            Spacer(minLength: 4)

            // Revealed on hover, exactly as in the window. Shown unconditionally it put a dashed
            // "＋date" on every dateless task on the card at once, which on a board of project cards is
            // a lot of empty controls competing with the tasks they are attached to. The card takes the
            // pointer once you have stepped into it, so it has a hover state to hang this off after all.
            DueChip(todo: todo,
                    isEditing: activeEditor == EditorTarget(key: key, kind: .due),
                    reveal: hovering == key,
                    onPick: { store.setDue(todo, due: $0) },
                    onPickCustom: { open(.due, on: todo) })
        }
        .onHover { inside in
            hovering = inside ? key : (hovering == key ? nil : hovering)
            rowHover.set(key, inside: inside)
        }
        .padding(.leading, 12 + indent(todo.depth))
        .padding(.trailing, 12)
        .padding(.vertical, 2)
        // Outside the depth indent, so a subtask's highlight starts where every other row's does — a
        // band that stepped in with the text would read as a second kind of row. The same view the
        // window's list paints, so a selection looks like a selection wherever you made it.
        //
        // "Emphasized" is the card being stepped into. That is what standing in this list means on a
        // board, and it is the same distinction AppKit draws between a selection in the focused
        // control and the same selection in one beside it.
        .background(RowSelectionBand(isSelected: selection.contains(key),
                                     isEmphasized: engagement.isEngaged,
                                     isHovering: hovering == key && activeEditor == nil))
        // The row's breathing room is *inside* the published frame, so adjacent rows tile edge to edge
        // and the gaps the drop delegate computes abut with no dead bands between them.
        .background(GeometryReader { geometry in
            let frame = geometry.frame(in: .named(TaskDropResolver.coordinateSpace))
            Color.clear.preference(key: RowFramesKey.self, value: [RowFrame(
                key: key, session: todo.sessionIndex, line: todo.lineIndex,
                depth: todo.depth, minY: frame.minY, maxY: frame.maxY)])
        })
        // In the background, so `ForEach`'s own identity for the row is left alone — an `.id` on the
        // row itself would replace it and undo the stable-across-reindex animations.
        .background(Color.clear.frame(width: 0, height: 0).id(key))
        .contentShape(Rectangle())
        // **Drag a task to move it**, which the card could not do before: reordering was the window's
        // and a board was where you read. It is the same drag, resolved by the same
        // `TaskDropResolver`, and rightward still means "make this a child of the row above".
        //
        // Off while an editor is open, so the list stays still in edit mode — and gated on the card
        // being stepped into, because until then the board owns this drag and it moves the card. That
        // is the same line `CanvasNodeView.takesItsOwnClicks` already draws; in a tiled view, where
        // there is nowhere to move a card to, the card has the drag from the first press.
        .ifCondition(activeEditor == nil && engagement.isEngaged) { view in
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
        .onTapGesture(count: 2) {
            if NSEvent.modifierFlags.contains(.option) || todo.checked {
                open(.edit, on: todo)
            } else {
                store.focus(todo)
            }
        }
        .onTapGesture { selection.click(key, modifiers: NSEvent.modifierFlags, in: visibleKeys) }
        .contextMenu {
            TaskMenu(todo: todo, targets: contextTargets(for: todo), store: store,
                     openEditor: { open($0, on: todo) },
                     openAdd: { position in
                         addPosition = position
                         open(.add, on: todo)
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
        }
    }

    /// A subtask's step in, half the window's. A card is a narrower column than a window's, and the
    /// nesting has to leave room for the sentence.
    private func indent(_ depth: Int) -> Double { Double(depth) * 11 }

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

    private func open(_ kind: EditorTarget.Kind, on todo: Todo) {
        activeEditor = EditorTarget(key: PMStore.key(for: todo), kind: kind)
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

    /// The session note that was open when the card was stepped out of, and where its caret was — so
    /// switching tiles and coming back is a return to the note rather than to the list (backlog 24).
    /// Held here because the node outlives the view, and nobody draws it.
    @ObservationIgnored
    var returnTo: (ref: SessionRef, caret: NSRange?)?
    /// The open note's caret, as it moves. Not observed: it is read only on the way out.
    @ObservationIgnored
    var noteCaret: NSRange?
    /// Where a note reopened by a return starts its caret; nil for a note opened any other way.
    @ObservationIgnored
    var returnCaret: NSRange?

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
                .foregroundStyle(hovering || configuration.isPressed ? .primary : .secondary)
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
