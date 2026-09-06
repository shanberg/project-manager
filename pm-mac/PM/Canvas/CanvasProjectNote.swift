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
struct CanvasProjectNote: View {
    @ObservedObject var store: PMStore
    /// Whether the card has been stepped into. Only the open editor depends on it — everything else is
    /// gated by the card refusing to hit-test at all until then (`CanvasNodeView.hitTest`), and the
    /// wheel reaches this scroll view either way (`CanvasBoardView.scrollWheel`).
    @ObservedObject var engagement: CanvasCardEngagement
    /// The notes file itself, so a relative image embed resolves against the folder it lives in.
    let noteURL: URL
    /// Opens a project a `[[…]]` names, exactly as the window's rows do.
    var onOpenProject: (String) -> Void

    /// The open inline editor, if any. One at a time, exactly as in the task list and the focus panel.
    @State private var activeEditor: EditorTarget?
    /// Which position a freshly opened add editor seeds to, set by the menu's Add commands before the
    /// editor opens.
    @State private var addPosition: TaskInsertPosition = .after
    /// The task row under the pointer, which is what reveals its "＋date".
    @State private var hovering: String?

    private var notes: ProjectNotes? { store.notes }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                title
                ForEach(Array((notes?.sessions ?? []).enumerated()), id: \.offset) { index, session in
                    session_(session, at: index)
                }
            }
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Stepping out closes whatever was open. An editor left standing on a card you have walked away
        // from is a text field with the keyboard nowhere near it, holding an edit that will never be
        // committed.
        .onChange(of: engagement.isEngaged) { _, engaged in
            if !engaged { activeEditor = nil }
        }
    }

    /// The document's own title. The project window puts this in its header pill; a card has no header,
    /// so it goes where the file actually keeps it — at the top, as a heading.
    ///
    /// Named from the *filename* until the store's first read lands. Acquiring a store starts a file
    /// read, and until it finishes `notes` is nil — so a board of project cards came up as a screenful
    /// of blank rectangles for as long as that took, which is exactly the moment a card most needs to
    /// say what it is. The notes file is named for its project, so the name is already in hand.
    @ViewBuilder private var title: some View {
        let name = notes?.title.isEmpty == false ? notes!.title : filenameTitle
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
        }
        ForEach(blocks(for: session, at: index)) { block in
            switch block {
            case .prose(_, let text):
                RenderedNote(prose: text, font: .systemFont(ofSize: 12.5),
                             noteURL: noteURL, maxImageHeight: 240)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 3)
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
