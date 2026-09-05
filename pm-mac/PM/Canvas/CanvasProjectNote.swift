import AppKit
import SwiftUI
import PmLib

/// A project's notes, on a card, drawn the way the project window draws them.
///
/// A file card pointing at `docs/Notes - <Title>.md` is not a card showing a markdown file. It is a
/// card showing a *project* — it is the card `createProjectCanvas` puts on every new board, and on a
/// real board it is usually the reason the board exists. Rendered as prose it came out as the raw
/// document: `- [ ] Ship the thing due: friday` as a bullet with the syntax showing, sessions as bare
/// `## 2026-08-14` headings, `[[Other Project]]` as brackets. Everything the project window spent its
/// effort making legible, spelled out.
///
/// So it uses the same pieces. The status circle, the tokenised text through `taskLineAttributed` and
/// `TokenTextLabel`, the due badge through `DueBadge` and its shared severity scale, the prose through
/// `RenderedNote`, and the body cut into blocks by `SessionBody` — which is the same cut the window
/// makes, so a task sits in the sentence that put it there rather than being gathered under it.
///
/// **Read-only, and it looks it.** No checkbox you can click, no ＋date, no menus. A card is a
/// clipping: the same principle that stops a web card from being a browser. What it offers instead is a
/// way *in* — the card's menu opens the project — which is the honest version of "you can act on this".
struct CanvasProjectNote: View {
    let notes: ProjectNotes
    let todos: [Todo]
    /// The notes file itself, so a relative image embed resolves against the folder it lives in.
    let noteURL: URL
    /// Opens a project a `[[…]]` names, exactly as the window's rows do.
    var onOpenProject: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The document's own title. The project window puts this in its header pill; a card has no
            // header, so it goes where the file actually keeps it — at the top, as a heading.
            if !notes.title.isEmpty {
                Text(notes.title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(2)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }

            ForEach(Array(notes.sessions.enumerated()), id: \.offset) { index, session in
                let caption = context(for: session)
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
                        line(identified.todo)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One task: its status, its words, and when it is due — the window's `taskLine`, minus everything
    /// on it that was a control.
    private func line(_ todo: Todo) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: todo.checked ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(todo.checked ? Color.accentColor : Color.secondary)
            TokenTextLabel(attributed: taskLineAttributed(todo, wait: nil, size: 12.5),
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
            DueBadge.reading(todo)
        }
        // Indented by depth, so a subtask reads as one. Half the window's step, because a card is a
        // narrower column than a window's and the nesting has to leave room for the sentence.
        .padding(.leading, 12 + Double(todo.depth) * 11)
        .padding(.trailing, 12)
        .padding(.vertical, 2)
    }

    /// A session's caption: its date, and its label when it has one. The window's `sessionContext`.
    private func context(for session: Session) -> String {
        session.label.isEmpty ? session.date : "\(session.date) · \(session.label)"
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
                                  tasks: todos.filter { $0.sessionIndex == index }) { todo in
            let n = seen[todo.rawLine, default: 0]
            seen[todo.rawLine] = n + 1
            return IdentifiedTodo(id: "\(index)/\(todo.rawLine)#\(n)", todo: todo)
        }
    }
}

/// A project's notes file, read and parsed for a card.
///
/// Nil when the file isn't one of PM's notes files, or when it won't parse — in either case the card
/// falls back to rendering it as the markdown it is, which is the right failure: a note that PM cannot
/// make sense of is still a note somebody wrote, and showing it plainly beats showing nothing.
enum CanvasProjectNoteSource {
    static func read(_ url: URL) -> (notes: ProjectNotes, todos: [Todo])? {
        guard projectFolder(ofNotesPath: url.path) != nil,
              let text = try? String(contentsOf: url, encoding: .utf8),
              let notes = try? parseNotes(markdown: text),
              let todos = try? parseTodos(notes: notes)
        else { return nil }
        return (notes, todos)
    }
}
