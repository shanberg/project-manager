import AppKit
import PmLib

/// What a Day row can be told to do (docs/views.md D6) — the project card's verbs for a row, less the
/// ones that need the rows around it (the positional adds, wrap, a selection).
enum CanvasDayAction: Equatable {
    case complete
    case reopen
    case drop
    case focus
    case pickUp
    case putBack
    case edit(String)

    /// Which of these a row offers, from what the row itself knows. The store has the last word when the
    /// act lands — a project left long enough starts a new sitting, and then Pick Up means something
    /// after all — but a menu that says what it will usually do beats one that is always the same.
    ///
    /// Pick Up only from a sitting that isn't the project's current one: a row in the current sitting is
    /// already there. Put Back only on a tree picked up into the current sitting, since that's the pick
    /// Put Back takes away.
    static func offered(for row: CanvasDayRow, in sitting: SittingEntry) -> [CanvasDayAction] {
        guard row.ref != nil else { return [] }
        switch row.state {
        case .open:
            var actions: [CanvasDayAction] = [.complete, .drop, .focus]
            if !sitting.isCurrent { actions.append(.pickUp) }
            if row.pickedUp, sitting.isCurrent { actions.append(.putBack) }
            return actions
        case .done, .dropped:
            return [.reopen]
        }
    }

    var title: String {
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

    /// Do `action` to `row`, a task in the project in `folder`. `then` runs once it has settled, landed
    /// or refused — always, so a row drawn as it's about to be is never left that way.
    func perform(_ action: CanvasDayAction, on row: CanvasDayRow, inProject folder: String,
                 then: (@MainActor () -> Void)? = nil) {
        let finish: @MainActor () -> Void = { then?() }
        guard let ref = row.ref, let key = projectKey(folder) else { NSSound.beep(); return finish() }
        let store = acquire(key)
        whenLoaded(store) {
            guard let todo = Self.todo(ref, in: store) else {
                // The line moved or went since the view last looked. Looking again is the answer.
                NSSound.beep()
                return finish()
            }
            let before = store.undoStack.count
            let landed: @MainActor () -> Void = { [weak self] in
                if store.undoStack.count > before { self?.onActed(store) }
                finish()
            }
            switch action {
            case .complete:
                guard !todo.checked else { return finish() }
                store.complete(todo, advanceFocus: false, then: landed)
            case .reopen:
                guard todo.checked else { return finish() }
                store.undo(todo, then: landed)
            case .drop: store.drop([todo], then: landed)
            case .focus: store.focus(todo, then: landed)
            case .pickUp:
                guard store.canPickUp(todo) else { return finish() }
                store.pickUp(store.trees([todo]), then: landed)
            case .putBack:
                guard todo.picked != nil else { return finish() }
                store.putBack(store.trees([todo]), then: landed)
            case .edit(let text):
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, trimmed != todo.text else { return finish() }
                store.editText(todo, text: trimmed, then: landed)
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
