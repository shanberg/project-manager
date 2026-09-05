import Foundation
import PmLib

/// A task paired with the identity its row is diffed on.
///
/// Identity is the raw line *plus an occurrence number*. The raw line is what survives a reindex:
/// adding or deleting a task shifts every `"session:line"` key below it, so identifying rows by key
/// would make the whole tail read as new rows (they'd cross-fade instead of sliding). But a raw line
/// isn't unique on its own — two identical task lines in one session ("- [ ] Follow up" twice) collide,
/// and SwiftUI's diffing misbehaves on duplicate ids: rows flicker, and the wrong one animates out.
/// Counting occurrences keeps the stability and makes the ids unique.
struct IdentifiedTodo: Identifiable {
    let id: String
    let todo: Todo
}

/// One piece of a session's body, in the order it was written.
///
/// A session is a sitting written down: some prose, a checkbox, more prose explaining why, another
/// couple of checkboxes. The window used to render that as two separate things — the lines *above* the
/// first task, and then every task in the session gathered into a block underneath — which meant a
/// task no longer sat in the sentence that put it there, and any prose written after a task was on
/// disk and nowhere on screen. This is the body as it actually reads.
enum SessionBlock: Identifiable {
    /// A run of consecutive non-task lines, trimmed. Never empty — an empty run is dropped rather than
    /// drawn as a gap.
    case prose(id: String, text: String)
    case task(IdentifiedTodo)

    var id: String {
        switch self {
        case .prose(let id, _): return id
        case .task(let identified): return identified.id
        }
    }
}

enum SessionBody {
    /// Cut a session's body into blocks, matching each task line to the task the parser made from it.
    ///
    /// The matching is by `rawLine` against `tasks` in order, not by re-running a regex over the text.
    /// `parseTodos` walks the same body in the same direction and stores each line verbatim, so the
    /// k-th task line in the body is `tasks[k]` — an identity worth using rather than a second parser
    /// worth keeping in step with the first.
    ///
    /// - Parameters:
    ///   - body: the session's body, exactly as the store holds it.
    ///   - tasks: every task in the session, in body order — *including* ones filtered out of the
    ///     view. They have to be here or the walk loses its place: a hidden completed task still
    ///     occupies a line, and skipping it would shift every task after it onto the wrong line.
    ///   - visible: the row a task is being drawn as, or nil when the list is filtering it out (the
    ///     "incomplete only" mode, or a find query). A closure rather than a lookup table keyed by
    ///     `PMStore.key`, so this file stays free of the store — which is what lets it be compiled
    ///     into `PMViewTests` and driven directly.
    static func blocks(body: String, tasks: [Todo],
                       visible: (Todo) -> IdentifiedTodo?) -> [SessionBlock] {
        var out: [SessionBlock] = []
        var run: [String] = []
        var proseOrdinal = 0
        var cursor = 0

        func flushProse() {
            let text = run.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            run.removeAll()
            guard !text.isEmpty else { return }
            out.append(.prose(id: "prose#\(proseOrdinal)", text: text))
            proseOrdinal += 1
        }

        for line in body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if cursor < tasks.count, line == tasks[cursor].rawLine {
                let todo = tasks[cursor]
                cursor += 1
                flushProse()
                if let row = visible(todo) { out.append(.task(row)) }
            } else {
                run.append(line)
            }
        }
        flushProse()

        // Anything the walk didn't place goes at the end. It should never happen — the tasks came from
        // this body — but "should never happen" is a poor reason for a task to vanish from the window
        // it's being managed in. Falling back to the old hoisted-to-the-bottom rendering is a visible
        // oddity; silently dropping the row is a lost task.
        while cursor < tasks.count {
            if let row = visible(tasks[cursor]) { out.append(.task(row)) }
            cursor += 1
        }
        return out
    }
}
