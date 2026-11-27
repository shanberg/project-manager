import Foundation

// MARK: - Gone stale
//
// A task doesn't age on its own: its age is the date of the sitting it was written in. A project you
// come back to after a month has every task from every sitting still open at full weight, and the pile
// is what makes coming back hard. So open work is split in two: what you've touched lately, and what
// has sat untouched long enough to have **gone stale**. Stale work is folded out of the way on the
// surfaces you glance at (a project card's pile, the dock's card, the menubar), and a catch-up review
// goes through it one tree at a time: Keep, Pick Up or Drop. See docs/stale-tasks.md.
//
// "Touched" is what PM already records. Nothing new is stamped onto task lines:
//
// - **written**: the day of the sitting it's in;
// - **picked up**: the pick log's latest pick of its tree (`Todo.picked`), which focusing, ticking or
//   editing an old task also writes;
// - **kept**: the pick log's latest `kept` of its tree (`Todo.kept`), what Keep writes in a review.
//
// Whichever is latest is when it was last touched. A tree is the unit, as it is for a pick: it's stale
// only when every open line in it is.

/// How long open work can go untouched before it counts as stale: three weeks, so a task from the
/// week before last is still in plain sight, and one from last month isn't.
public let taskStaleAfter: TimeInterval = 21 * 86_400

public enum TaskStaleness {
    /// When `todo` was last touched — written, picked up or kept, whichever is latest. Nil for a task
    /// under a heading PM can't date: with no "when" it can't be old.
    public static func lastTouched(_ todo: Todo, calendar: Calendar = .current) -> Date? {
        guard let iso = todo.sessionISODate, let written = try? DoneRange.localDay(iso, calendar: calendar)
        else { return nil }
        // The sitting's day counts from its end: a task written at 11 PM on the 1st was touched on the 1st.
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: written) ?? written
        let picked = todo.picked.flatMap { DoneLog.date($0.at) }
        let kept = todo.kept.flatMap(DoneLog.date)
        return [endOfDay, picked, kept].compactMap { $0 }.max()
    }

    /// Whether one line, on its own, has gone stale: open, not focused, with no date of its own or
    /// inherited (a dated task already says when it matters), and untouched for `taskStaleAfter`.
    public static func isStale(_ todo: Todo, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard todo.state == .open, !todo.isFocused, (todo.effectiveDueDate ?? todo.dueDate) == nil,
              let touched = lastTouched(todo, calendar: calendar) else { return false }
        return now.timeIntervalSince(touched) > taskStaleAfter
    }

    /// The key every surface names a line by here: `"sessionIndex:lineIndex"`.
    public static func key(_ todo: Todo) -> String { "\(todo.sessionIndex):\(todo.lineIndex)" }

    /// Every line, by `key`, of every tree that has gone stale: a tree is stale when it has an open
    /// line and every open line in it is stale. Its closed lines are in the set too, so a surface can
    /// fold a tree whole.
    ///
    /// One pass over the list, so a card can ask on every draw.
    public static func staleLines(in todos: [Todo], now: Date = Date(),
                                  calendar: Calendar = .current) -> Set<String> {
        var out = Set<String>()
        var bySitting: [Int: [Todo]] = [:]
        for todo in todos { bySitting[todo.sessionIndex, default: []].append(todo) }
        for sitting in bySitting.values {
            let lines = sitting.sorted { $0.lineIndex < $1.lineIndex }
            var i = 0
            while i < lines.count {
                // A tree: a line and the run of deeper lines after it (`TaskTree`).
                var j = i + 1
                while j < lines.count, lines[j].depth > lines[i].depth { j += 1 }
                let tree = lines[i..<j]
                let open = tree.filter { $0.state == .open }
                if !open.isEmpty, open.allSatisfy({ isStale($0, now: now, calendar: calendar) }) {
                    for todo in tree { out.insert(key(todo)) }
                }
                i = j
            }
        }
        return out
    }

    /// The trees of `todos` that have gone stale, by their roots, oldest touch first — the order a
    /// catch-up review goes through them, so the longest-forgotten comes up first.
    public static func staleRoots(in todos: [Todo], now: Date = Date(),
                                  calendar: Calendar = .current) -> [Todo] {
        let stale = staleLines(in: todos, now: now, calendar: calendar)
        let roots = TaskTree.roots(of: todos.filter { stale.contains(key($0)) && $0.state == .open }, in: todos)
        return roots.sorted { a, b in
            let (x, y) = (lastTouched(a, calendar: calendar) ?? .distantPast,
                          lastTouched(b, calendar: calendar) ?? .distantPast)
            return x != y ? x < y : (a.sessionIndex, a.lineIndex) > (b.sessionIndex, b.lineIndex)
        }
    }
}
