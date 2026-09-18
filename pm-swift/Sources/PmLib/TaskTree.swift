import Foundation

// MARK: - Task trees
//
// A task with subtasks is one piece of work, and the top-level line is what says what it is. "Send the
// invoice" means nothing on its own; under "Wrap up the Acme job" it's obvious. So anything that takes
// a task somewhere as a *record* — a pick, above all (docs/sessions.md D3) — takes the whole tree it
// belongs to, named by its root: touching any line of a tree is working on the tree.
//
// The shape is the one every subtree operation already uses: a task, and the contiguous run of deeper
// tasks right after it in its own sitting. Trees never cross a sitting heading.

public enum TaskTree {
    /// The top-level task `todo` sits under in its own sitting — `todo` itself when it's top-level.
    ///
    /// A sitting that opens on an indented task (a hand edit) has no top-level line above it; the walk
    /// stops at the first task, and if that doesn't reach back as far as `todo`'s tree, `todo` is its
    /// own root rather than a guess.
    public static func root(of todo: Todo, in todos: [Todo]) -> Todo {
        let sitting = tasks(inSessionOf: todo, todos)
        guard var i = sitting.firstIndex(where: { $0.lineIndex == todo.lineIndex }) else { return todo }
        while i > 0, sitting[i].depth > 0 { i -= 1 }
        let root = sitting[i]
        return run(from: i, in: sitting).contains { $0.lineIndex == todo.lineIndex } ? root : todo
    }

    /// `root` and every task under it, in document order.
    public static func members(of root: Todo, in todos: [Todo]) -> [Todo] {
        let sitting = tasks(inSessionOf: root, todos)
        guard let i = sitting.firstIndex(where: { $0.lineIndex == root.lineIndex }) else { return [root] }
        return run(from: i, in: sitting)
    }

    /// The distinct trees `todos` belong to, as their roots, in the order they're first reached.
    public static func roots(of selection: [Todo], in todos: [Todo]) -> [Todo] {
        var seen = Set<String>()
        return selection.compactMap { todo in
            let root = root(of: todo, in: todos)
            return seen.insert("\(root.sessionIndex):\(root.lineIndex)").inserted ? root : nil
        }
    }

    private static func tasks(inSessionOf todo: Todo, _ todos: [Todo]) -> [Todo] {
        todos.filter { $0.sessionIndex == todo.sessionIndex }.sorted { $0.lineIndex < $1.lineIndex }
    }

    private static func run(from i: Int, in sitting: [Todo]) -> [Todo] {
        var out = [sitting[i]]
        var j = i + 1
        while j < sitting.count, sitting[j].depth > sitting[i].depth {
            out.append(sitting[j])
            j += 1
        }
        return out
    }
}
