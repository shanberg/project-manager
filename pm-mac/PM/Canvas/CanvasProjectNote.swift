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
    @ObservedObject var store: PMStore
    /// Whether the card has been stepped into. Only the open editor depends on it — everything else is
    /// gated by the card refusing to hit-test at all until then (`CanvasNodeView.takesItsOwnClicks`,
    /// which a tiled view grants outright), and the wheel reaches this scroll view either way
    /// (`CanvasBoardView.scrollWheel`).
    @ObservedObject var engagement: CanvasCardEngagement
    /// The notes file itself, so a relative image embed resolves against the folder it lives in.
    let noteURL: URL
    /// Opens a project a `[[…]]` names, exactly as the window's rows do.
    var onOpenProject: (String) -> Void
    /// What the board is asking of this card — New Session and New Task, when it is the one you are
    /// standing in. See `CanvasProjectCardCommands`.
    @ObservedObject var commands: CanvasProjectCardCommands

    /// The open inline editor, if any. One at a time, exactly as in the task list and the focus panel.
    @State private var activeEditor: EditorTarget?
    /// Which position a freshly opened add editor seeds to, set by the menu's Add commands before the
    /// editor opens.
    @State private var addPosition: TaskInsertPosition = .after
    /// The task row under the pointer, which is what reveals its "＋date".
    @State private var hovering: String?
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

    var body: some View {
        Group {
            // Writing prose takes the card over, exactly as it takes the window's column over. Not an
            // inline field: a card is already a narrow column, and an editor inside a rendered note
            // would be a narrower one inside it. The same view as the window's, too, rather than a
            // lookalike — it has learnt things a second copy would have to learn again, starting with
            // not writing your note into whichever session has since moved into that index.
            if let index = openNote, let sessions = notes?.sessions, sessions.indices.contains(index) {
                SessionNoteTakeover(index: index, session: sessions[index],
                                    projectName: displayName, store: store,
                                    placement: .card, onOpenProject: onOpenProject,
                                    onBack: { openNote = nil })
            } else {
                list
            }
        }
        // Stepping out closes whatever was open. An editor left standing on a card you have walked away
        // from is a text field with the keyboard nowhere near it, holding an edit that will never be
        // committed. The note takeover is the exception that proves it: it saves on the way out, so
        // closing it here is a commit rather than a discard.
        .onChange(of: engagement.isEngaged) { _, engaged in
            if !engaged {
                activeEditor = nil
                openNote = nil
                // The brief's fields commit as they are left, and leaving the card is leaving the
                // field — so this closes an editor that has already written, not one being abandoned.
                editingDetails = false
            }
        }
        .onChange(of: commands.newSessionRequest) { _, _ in beginCurrentSession() }
        .onChange(of: commands.newTaskRequest) { _, _ in beginTask() }
        .onChange(of: commands.editDetailsRequest) { _, _ in
            openNote = nil
            activeEditor = nil
            editingDetails = true
        }
    }

    private var list: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                title
                // The brief, above the work, exactly where the window puts it — and the same view, so
                // it reads as the same printed page and edits the same way (double-click, then live
                // rows). Drawn only when there is one: an empty brief on a card would be six lines of
                // "Add summary…" standing between you and the sessions.
                ProjectDetailsView(notes: notes, store: store, isEditing: $editingDetails,
                                   showsPlaceholders: false)
                ForEach(Array((notes?.sessions ?? []).enumerated()), id: \.offset) { index, session in
                    session_(session, at: index)
                }
                footer
            }
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The quick add, and the two dead ends.
    ///
    /// **Only the dead ends get a row of their own.** Everything else on this card is reached the way
    /// the window reaches it — a menu, a key — because a card that grew buttons the window has not got
    /// would be saying the two surfaces are different things. But a project with no sessions and a
    /// project with no tasks each have nothing to right-click, and a surface whose only affordance is
    /// on an object you do not have yet is a surface that looks broken. So: one row, revealed once you
    /// have stepped in, in the place the window puts its own add editor.
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
                startRow("Start a session", symbol: "calendar.badge.plus", action: beginCurrentSession)
            } else if store.todos.isEmpty {
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
            Text(name)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(2)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
                .foregroundStyle(store.hasLoaded ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        }
    }

    /// `Notes - Walkable.md` is the Walkable project. The prefix is the convention `getNotesPath`
    /// writes; the rest is the title.
    private var filenameTitle: String {
        let name = noteURL.deletingPathExtension().lastPathComponent
        return name.hasPrefix("Notes - ") ? String(name.dropFirst("Notes - ".count)) : name
    }

    @ViewBuilder private func session_(_ session: Session, at index: Int) -> some View {
        let caption = session.label.isEmpty ? session.date : "\(session.date) · \(session.label)"
        if !caption.isEmpty {
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
        ForEach(blocks(for: session, at: index)) { block in
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
        .onHover { inside in hovering = inside ? key : (hovering == key ? nil : hovering) }
        .padding(.leading, 12 + indent(todo.depth))
        .padding(.trailing, 12)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        // Double-click *activates* — focuses the task — exactly as it does in the project window. It
        // used to open the text editor here, which meant the same gesture on the same object meant two
        // different things depending on which surface you were looking at it through. The surface is
        // not the thing; the task is.
        //
        // ⌥ double-click edits the text, and so does the context menu's Edit. No single-click
        // selection: a card has no selection to keep, and a click that did nothing visible would be a
        // click that looked broken.
        .onTapGesture(count: 2) {
            if NSEvent.modifierFlags.contains(.option) || todo.checked {
                open(.edit, on: todo)
            } else {
                store.focus(todo)
            }
        }
        .contextMenu {
            TaskMenu(todo: todo, store: store,
                     openEditor: { open($0, on: todo) },
                     openAdd: { position in
                         addPosition = position
                         open(.add, on: todo)
                     },
                     onDelete: { store.deleteTasks($0) },
                     onGoToProject: { key in
                         guard let folder = PMFiles.projectName(fromKey: key) else { return }
                         onOpenProject(folder)
                     })
        }
    }

    /// A subtask's step in, half the window's. A card is a narrower column than a window's, and the
    /// nesting has to leave room for the sentence.
    private func indent(_ depth: Int) -> Double { Double(depth) * 11 }

    /// What a session offers on a card: its note, and the next sitting.
    ///
    /// Deliberately shorter than the window's `SessionMenu`. Renaming happens in the note takeover's
    /// header, where the label is shown beside the date it decorates; deleting a session is the kind of
    /// thing the window keeps, being an edit to the shape of the document rather than to its contents.
    @ViewBuilder private func sessionMenu(at index: Int) -> some View {
        Button(sessionHasNote(index) ? "Edit Note" : "Add Note") { openNote = index }
        Divider()
        Button("New Session") { beginCurrentSession() }
        Button("New Task") { beginTask() }
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
    private func beginCurrentSession() {
        guard store.projectName != nil else { return }
        activeEditor = nil
        store.openCurrentSession { index in openNote = index }
    }

    /// New Task: appended to the current session rather than placed against a row, which is what the
    /// window's own no-anchor add does. The anchored kinds live on `TaskMenu`, where the anchor is the
    /// row the menu was opened on.
    private func beginTask() {
        guard store.projectName != nil else { return }
        openNote = nil
        activeEditor = Self.quickAdd
    }

    private func open(_ kind: EditorTarget.Kind, on todo: Todo) {
        activeEditor = EditorTarget(key: PMStore.key(for: todo), kind: kind)
    }

    /// The session's body, cut where its tasks are.
    ///
    /// Every task is visible here — a card has no Incomplete filter and no find bar to narrow it, so
    /// the closure that exists in the window to answer "is this row being drawn" always says yes. The
    /// id is built the way the window builds it, raw line plus occurrence, because two identical task
    /// lines in one session are two rows and `ForEach` misbehaves on duplicate ids.
    private func blocks(for session: Session, at index: Int) -> [SessionBlock] {
        var seen: [String: Int] = [:]
        return SessionBody.blocks(body: session.body,
                                  tasks: store.todos.filter { $0.sessionIndex == index }) { todo in
            let n = seen[todo.rawLine, default: 0]
            seen[todo.rawLine] = n + 1
            return IdentifiedTodo(id: "\(index)/\(todo.rawLine)#\(n)", todo: todo)
        }
    }
}

/// What the board asks of the project card you are standing in.
///
/// **Counters, not flags**, on the pattern `ProjectViewState` already uses for the window's File menu:
/// a command is an event, and the same command given twice in a row has to fire twice. A flag set to
/// true and back would be a change SwiftUI might never see.
///
/// The board cannot call into this card's SwiftUI directly — the card is an `NSHostingView` inside an
/// `NSView` — and this is the seam the window already has for the same problem, in the same shape.
@MainActor
final class CanvasProjectCardCommands: ObservableObject {
    @Published private(set) var newSessionRequest = 0
    @Published private(set) var newTaskRequest = 0
    @Published private(set) var editDetailsRequest = 0

    func requestNewSession() { newSessionRequest &+= 1 }
    func requestNewTask() { newTaskRequest &+= 1 }
    func requestEditDetails() { editDetailsRequest &+= 1 }
}

/// Whether a card has been stepped into, published so its SwiftUI content can react.
///
/// The engagement itself belongs to `CanvasNodeView`, which is AppKit and tells nobody. A card whose
/// content needs to know — to start taking scroll wheels, to drop an open editor on the way out — gets
/// one of these and the node view writes through it.
@MainActor
final class CanvasCardEngagement: ObservableObject {
    @Published var isEngaged = false
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
