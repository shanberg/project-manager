import Foundation
import PmLib

/// Where a sitting's picked-up tasks go, and what the pile of open work looks like — the drawing half
/// of docs/sessions.md D5, kept free of the store and of SwiftUI so it can be driven directly.
///
/// **One task, drawn in two places.** A task picked up into today's sitting stays on its line in the
/// sitting it was written in, and is *also* drawn in today's, under Picked up. Both rows are the same
/// task: ticking either ticks the line, and selecting either selects it. What tells them apart is the
/// place, which is what a row's identity is built from.
enum RowPlace: Hashable {
    /// On its own line, in the sitting it was written in.
    case origin
    /// Drawn again in the sitting at this index, which picked it up.
    case picked(into: Int)
}

/// A task's coordinates in one read of the document — what `PMStore.key` spells as a string.
struct TaskPosition: Hashable {
    let session: Int
    let line: Int

    init(session: Int, line: Int) {
        self.session = session
        self.line = line
    }

    init(_ todo: Todo) { self.init(session: todo.sessionIndex, line: todo.lineIndex) }
}

/// One row of the open pile, and whether it carries its origin chip.
struct PileRow {
    let todo: Todo
    let showsOrigin: Bool
}

enum SessionPicks {
    /// The older task trees picked up into the sitting at `index`, in the order they were picked up,
    /// each drawn whole: its root, carrying the origin chip, and every task under it, indented as in
    /// its own sitting.
    ///
    /// **A pick is a tree** (docs/sessions.md D3). A subtask on its own says too little — "Send the
    /// invoice" needs the line above it — so ticking one picks up the task it belongs to, and this draws
    /// the lot. A pick written before picks named trees can name a subtask; it draws its tree the same.
    ///
    /// A tree picked up into the same sitting twice (picked, put back, picked again, or two of its
    /// subtasks picked by an older build) is drawn once. The log's reader folds some of that already;
    /// this holds the line anyway, because a duplicate row id is what makes `ForEach` animate the wrong
    /// row.
    static func pickedUp(into index: Int, picks: [TaskPick], todos: [Todo]) -> [PileRow] {
        var byPosition: [TaskPosition: Todo] = [:]
        for todo in todos { byPosition[TaskPosition(todo)] = todo }
        let named = picks.filter { $0.intoIndex == index }
            .compactMap { byPosition[TaskPosition(session: $0.sessionIndex, line: $0.lineIndex)] }
        return TaskTree.roots(of: named, in: todos).flatMap { root in
            TaskTree.members(of: root, in: todos).map { PileRow(todo: $0, showsOrigin: TaskPosition($0) == TaskPosition(root)) }
        }
    }

    /// Every task picked up into the sitting at `index`, trees included, as positions.
    static func pickedPositions(into index: Int, picks: [TaskPick], todos: [Todo]) -> Set<TaskPosition> {
        Set(pickedUp(into: index, picks: picks, todos: todos).map { TaskPosition($0.todo) })
    }

    /// The pile: open work from every sitting in one group, newest origin first, in place of a caption
    /// per sitting (D5's **Still open**).
    ///
    /// - `excluding` is the sitting drawn above the pile, when there is one: its own tasks are already
    ///   on the card, and so is everything it picked up — drawing those again below would be the same
    ///   task twice on one screen for no reason.
    /// - `visible` is the card's narrowing — open only, and the find.
    ///
    /// **Newest origin first is document order.** Sittings are stored newest first, so sorting by
    /// session and then line is what the file already says, and it keeps a subtask under its parent.
    ///
    /// A row carries its chip when it starts a run from its sitting, or is a top-level task. A subtask
    /// drawn right under its parent would only be repeating the parent's chip.
    static func pile(todos: [Todo], excluding current: Int?, picks: [TaskPick],
                     visible: (Todo) -> Bool) -> [PileRow] {
        let alreadyDrawn = current.map { pickedPositions(into: $0, picks: picks, todos: todos) } ?? []
        let rows = todos
            .filter { $0.sessionIndex != current && !alreadyDrawn.contains(TaskPosition($0)) && visible($0) }
            .sorted { ($0.sessionIndex, $0.lineIndex) < ($1.sessionIndex, $1.lineIndex) }
        var previous: Int?
        return rows.map { todo in
            defer { previous = todo.sessionIndex }
            return PileRow(todo: todo, showsOrigin: todo.depth == 0 || previous != todo.sessionIndex)
        }
    }

    // MARK: Saying when

    /// A sitting's date, short: "Sep 2" this year, "Sep 2, 2025" otherwise. Nil for anything that isn't
    /// an ISO day, which is how a pick names its sitting and how a read names a task's.
    static func day(iso: String?, now: Date = Date(), calendar: Calendar = .current) -> String? {
        guard let iso, let date = isoDay.date(from: iso) else { return nil }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        return (sameYear ? thisYear : otherYear).string(from: date)
    }

    /// The trailing mark on a task that has been picked up since it was written — "picked up Sep 17" —
    /// so an old sitting says what became of its leftovers instead of looking abandoned.
    ///
    /// On a tree's top line only. Every line of a picked tree carries the fact, and the mark on each of
    /// them would say one thing as many times as the tree has lines.
    static func pickedMark(_ todo: Todo, now: Date = Date()) -> String? {
        guard todo.depth == 0, let picked = todo.picked, let day = day(iso: picked.into, now: now) else { return nil }
        return "picked up \(day)"
    }

    // MARK: The sentence it was written in

    /// What a task's origin chip says on hover: the paragraph written just before it in its sitting,
    /// which is almost always the sentence that explains it. Nil when the task opens its sitting.
    ///
    /// Walked with `SessionBody.blocks`, the same cut the card draws, so "just before" means the prose
    /// you would see above the row.
    static func sentence(before todo: Todo, body: String, tasks: [Todo]) -> String? {
        var last: String?
        let blocks = SessionBody.blocks(body: body, tasks: tasks) { task in
            IdentifiedTodo(id: "\(task.lineIndex)", todo: task)
        }
        for block in blocks {
            switch block {
            case .prose(_, let text):
                last = text
            case .task(let identified):
                if identified.todo.lineIndex == todo.lineIndex {
                    return last.flatMap(lastParagraph)
                }
                // Only the prose directly above: a task two rows down from a paragraph was written
                // beside the task between them, not beside the paragraph.
                last = nil
            }
        }
        return nil
    }

    /// The hover text for an origin chip.
    static func originHelp(_ todo: Todo, sessions: [Session], tasks: [Todo]) -> String {
        guard sessions.indices.contains(todo.sessionIndex) else { return "Written in an earlier session" }
        let session = sessions[todo.sessionIndex]
        let heading = session.label.isEmpty ? session.date : "\(session.date) · \(session.label)"
        let mine = tasks.filter { $0.sessionIndex == todo.sessionIndex }
        guard let sentence = sentence(before: todo, body: session.body, tasks: mine) else {
            return "Written \(heading)"
        }
        return "Written \(heading)\n\n\(truncate(sentence, 240))"
    }

    private static func lastParagraph(_ text: String) -> String? {
        let paragraphs = text.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return paragraphs.last
    }

    private static func truncate(_ text: String, _ limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
    }

    private static let isoDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let thisYear: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMM d")
        return formatter
    }()

    private static let otherYear: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMM d y")
        return formatter
    }()
}
