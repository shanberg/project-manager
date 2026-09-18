import AppKit
import PmLib

/// What a Day row can be told to do (docs/views.md D6) — the project card's verbs for a row, less the
/// ones that need the rows around it (the positional adds, wrap).
enum CanvasDayAction: Equatable {
    case complete
    case reopen
    case drop
    case focus
    case pickUp
    case putBack
    case edit(String)

    /// Which of these a selection offers, from what its rows know. The store has the last word when the
    /// act lands — a project left long enough starts a new sitting, and then Pick Up means something
    /// after all — but a menu that says what it will usually do beats one that is always the same.
    ///
    /// A selection is one sitting's rows (`CanvasDaySelection`), so it is one project and every act on
    /// it is one step on that project's history.
    ///
    /// Pick Up only from a sitting that isn't the project's current one: a row in the current sitting is
    /// already there. Put Back only on a tree picked up into the current sitting, since that's the pick
    /// Put Back takes away. Focus and editing are for one row.
    static func offered(for rows: [CanvasDayRow], in sitting: SittingEntry) -> [CanvasDayAction] {
        guard !rows.isEmpty, rows.allSatisfy({ $0.ref != nil }) else { return [] }
        let open = rows.filter { $0.state == .open }
        var actions: [CanvasDayAction] = [open.isEmpty ? .reopen : .complete]
        if !open.isEmpty { actions.append(.drop) }
        if rows.count == 1, !open.isEmpty { actions.append(.focus) }
        if !open.isEmpty, !sitting.isCurrent { actions.append(.pickUp) }
        if sitting.isCurrent, rows.contains(where: \.pickedUp) { actions.append(.putBack) }
        return actions
    }

    static func offered(for row: CanvasDayRow, in sitting: SittingEntry) -> [CanvasDayAction] {
        offered(for: [row], in: sitting)
    }

    var title: String { title(count: 1) }

    /// The menu's words, with the count in when there's more than one — counting only the rows the act
    /// touches, as `TaskMenu` does. The rows it acts on are the caller's to count.
    func title(count: Int) -> String {
        let tasks = count == 1 ? "Task" : "Tasks"
        guard count > 1 else {
            switch self {
            case .complete: return "Complete"
            case .reopen: return "Reopen"
            case .drop: return "Drop Task"
            case .focus: return "Focus"
            case .pickUp: return "Pick Up"
            case .putBack: return "Put Back"
            case .edit: return "Edit Task…"
            }
        }
        switch self {
        case .complete: return "Complete \(count) \(tasks)"
        case .reopen: return "Reopen \(count) \(tasks)"
        case .drop: return "Drop \(count) \(tasks)"
        case .pickUp: return "Pick Up \(count) \(tasks)"
        case .putBack: return "Put Back \(count) \(tasks)"
        case .focus: return "Focus"
        case .edit: return "Edit Task…"
        }
    }

    /// How many of `rows` this act touches, for its title: every row for a tick or untick, the open ones
    /// for a drop, the trees for a pick (three subtasks of one task are one pick).
    func count(of rows: [CanvasDayRow], among all: [CanvasDayRow]) -> Int {
        switch self {
        case .complete, .reopen, .focus, .edit: return rows.count
        case .drop: return rows.filter { $0.state == .open }.count
        case .pickUp: return CanvasDayRows.roots(of: rows.filter { $0.state == .open }, in: all).count
        case .putBack: return CanvasDayRows.roots(of: rows, in: all).filter(\.pickedUp).count
        }
    }

    /// The symbols `TaskMenu` gives the same commands.
    var symbol: String {
        switch self {
        case .complete: return "checkmark.circle"
        case .reopen: return "arrow.uturn.backward"
        case .drop: return "xmark.circle"
        case .focus: return "arrow.right.circle"
        case .pickUp: return "arrow.down.to.line"
        case .putBack: return "arrow.uturn.up"
        case .edit: return "pencil"
        }
    }
}

/// Acting from a view: each act goes to the row's own project, through that project's store.
///
/// **Acquired on the act, not for the view.** A Day across forty projects mustn't open forty stores to
/// draw itself — it reads through `session.list` like every other surface. A store is taken from
/// `StoreRegistry` the first time a row of its project is acted on, and kept until the card goes: the
/// act is on that store's undo stack, and a store let go is a history thrown away, so ⌘Z would find
/// nothing to take back. A project card for the same project on the same board is the same store,
/// since the registry shares them.
///
/// **⌘Z.** An act that lands tells `onActed` which store it changed, and the node view makes that the
/// board's `lastEditedProject` — `CanvasUndoRoute`'s project route, the same one a tick on a project
/// card takes.
@MainActor
final class CanvasDayActions {
    /// A project's registry key from its folder name. The app's is `ProjectIndex`; a test gives its own.
    private let projectKey: (String) -> String?
    /// The store an act changed, once it has landed with a step on that store's history.
    var onActed: (PMStore) -> Void = { _ in }

    private var held: [String: PMStore] = [:]

    init(projectKey: @escaping (String) -> String?) {
        self.projectKey = projectKey
    }

    /// The projects this card is holding open, because something was done to them from it.
    var heldProjects: [String] { held.keys.sorted() }
    var heldStores: [PMStore] { Array(held.values) }

    /// Do `action` to `row`, a task in the project in `folder`.
    func perform(_ action: CanvasDayAction, on row: CanvasDayRow, inProject folder: String,
                 then: (@MainActor () -> Void)? = nil) {
        perform(action, on: [row], inProject: folder, then: then)
    }

    /// Do `action` to `rows` — one sitting's, so one project's — as one step on that project's history.
    /// `then` runs once it has settled, landed or refused, always, so a row drawn as it's about to be is
    /// never left that way.
    ///
    /// **All or nothing.** If any row's line has changed since the view last looked, nothing is done: the
    /// selection you acted on is no longer the one on disk, and doing part of it would be a guess.
    func perform(_ action: CanvasDayAction, on rows: [CanvasDayRow], inProject folder: String,
                 then: (@MainActor () -> Void)? = nil) {
        let finish: @MainActor () -> Void = { then?() }
        let refs = rows.compactMap(\.ref)
        guard !refs.isEmpty, refs.count == rows.count, let key = projectKey(folder) else {
            NSSound.beep()
            return finish()
        }
        let store = acquire(key)
        whenLoaded(store) {
            let todos = refs.compactMap { Self.todo($0, in: store) }
            guard todos.count == refs.count else {
                // A line moved or went since the view last looked. Looking again is the answer.
                NSSound.beep()
                return finish()
            }
            let before = store.undoStack.count
            let landed: @MainActor () -> Void = { [weak self] in
                if store.undoStack.count > before { self?.onActed(store) }
                finish()
            }
            let open = todos.filter { !$0.checked }
            switch action {
            case .complete:
                guard !open.isEmpty else { return finish() }
                if open.count == 1 { store.complete(open[0], advanceFocus: false, then: landed) }
                else { store.toggleAll(open, then: landed) }
            case .reopen:
                let closed = todos.filter(\.checked)
                guard !closed.isEmpty else { return finish() }
                if closed.count == 1 { store.undo(closed[0], then: landed) }
                else { store.toggleAll(closed, then: landed) }
            case .drop: store.drop(todos, then: landed)
            case .focus:
                guard todos.count == 1 else { return finish() }
                store.focus(todos[0], then: landed)
            case .pickUp:
                let pickable = store.trees(todos.filter(store.canPickUp))
                guard !pickable.isEmpty else { return finish() }
                store.pickUp(pickable, then: landed)
            case .putBack:
                let picked = store.trees(todos.filter { $0.picked != nil })
                guard !picked.isEmpty else { return finish() }
                store.putBack(picked, then: landed)
            case .edit(let text):
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard todos.count == 1, !trimmed.isEmpty, trimmed != todos[0].text else { return finish() }
                store.editText(todos[0], text: trimmed, then: landed)
            }
        }
    }

    /// Give back every store this card took. The card calls this when it goes.
    func releaseAll() {
        for key in held.keys { StoreRegistry.shared.release(key) }
        held = [:]
    }

    private func acquire(_ key: String) -> PMStore {
        if let store = held[key] { return store }
        let store = StoreRegistry.shared.acquire(key)
        held[key] = store
        return store
    }

    /// A store just made is still reading its project. Acting needs the tasks in hand.
    private func whenLoaded(_ store: PMStore, _ work: @escaping @MainActor () -> Void) {
        if store.hasLoaded { work() } else { store.reload(then: work) }
    }

    /// The task a view's row names, in the store's current read — refused if the line has moved on, so
    /// the act can't land on whatever took its place.
    static func todo(_ ref: TaskRefInput, in store: PMStore) -> Todo? {
        guard let notes = store.notes else { return nil }
        let taskRef = TaskRef(sessionDate: ref.session, sessionOrdinal: ref.sessionOrdinal ?? 0,
                              lineIndex: ref.line, digest: ref.digest)
        guard let resolved = try? resolveTaskRef(taskRef, notes: notes) else { return nil }
        return store.todos.first { $0.sessionIndex == resolved.sessionIndex && $0.lineIndex == resolved.lineIndex }
    }
}
