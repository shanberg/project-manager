import SwiftUI
import PmLib

/// Right-click actions for a task, mirroring the hover controls plus completion/focus. Idiomatic
/// macOS per-task affordance: keyboard- and VoiceOver-accessible, and keeps the surface visually
/// clean. Shared by the project window's task rows and the focus panel's card so both offer the same
/// menu. Wording follows the rest of the app: the add positions match `AddEditor`'s Before/Subtask/After
/// picker (and Raycast's "Add Before"/"Add After"), due wording matches Raycast's "Set Due Date"/
/// "Remove Due Date", and an ellipsis marks actions that open a further input editor (as the
/// menubar does).
struct TaskMenu: View {
    let todo: Todo
    /// The tasks the commands apply to — the whole selection when this row belongs to one, else just
    /// this row. Commands that need a single subject (edit, wrap, the positional adds) are hidden on
    /// a multi-selection rather than silently acting on one arbitrary member of it.
    var targets: [Todo] = []
    @ObservedObject var store: PMStore
    /// Open (never toggle) the given editor kind on this task.
    let openEditor: (EditorTarget.Kind) -> Void
    /// Seed the add position, then open the add editor.
    let openAdd: (TaskInsertPosition) -> Void
    var onDelete: ([Todo]) -> Void = { _ in }

    /// The set commands act on, never empty (a menu opened on a row always has that row).
    private var scope: [Todo] { targets.isEmpty ? [todo] : targets }
    private var isMulti: Bool { scope.count > 1 }
    /// A batch is "completing" unless every task in it is already done, matching `PMStore.toggleAll`.
    private var allChecked: Bool { scope.allSatisfy(\.checked) }

    var body: some View {
        if isMulti {
            Button { store.toggleAll(scope) } label: {
                allChecked
                    ? Label("Reopen \(scope.count) Tasks", systemImage: "arrow.uturn.backward")
                    : Label("Complete \(scope.count) Tasks", systemImage: "checkmark.circle")
            }
        } else if todo.checked {
            Button { store.toggle(todo) } label: { Label("Reopen", systemImage: "arrow.uturn.backward") }
        } else {
            Button { store.toggle(todo) } label: { Label("Complete", systemImage: "checkmark.circle") }
        }
        if !isMulti, !todo.checked, !todo.isFocused {
            Button { store.focus(todo) } label: { Label("Focus", systemImage: "arrow.right.circle") }
        }
        if !isMulti {
            Button { openEditor(.edit) } label: { Label("Edit Task…", systemImage: "pencil") }
        }
        Divider()
        Button { TaskPasteboard.copy(markdown: store.markdown(for: scope)) } label: {
            Label(isMulti ? "Copy \(scope.count) Tasks" : "Copy", systemImage: "doc.on.doc")
        }
        .keyboardShortcut("c", modifiers: .command)
        if !isMulti {
            Divider()
            // Add-position symbols match the menubar's Add submenu (Before ↑, Subtask ↳, After ↓).
            Button { openAdd(.before) } label: { Label("Add Before…", systemImage: "arrow.up") }
            Button { openAdd(.child) } label: { Label("Add Subtask…", systemImage: "arrow.turn.down.right") }
            Button { openAdd(.after) } label: { Label("Add After…", systemImage: "arrow.down") }
            Button { openEditor(.wrap) } label: {
                Label("Wrap Task…", systemImage: "arrow.up.and.down.and.arrow.left.and.right")
            }
            // Only a parent can be dissolved — an immediate action (no further input), so no ellipsis.
            if store.hasChildren(todo) {
                Button { store.unwrap(todo) } label: {
                    Label("Unwrap", systemImage: "arrow.up.left.and.arrow.down.right")
                }
            }
        }
        Divider()
        if isMulti {
            // A batch date needs one editor, not one per row, so it goes through the clicked row's.
            Button { openEditor(.due) } label: { Label("Set Due Date…", systemImage: "calendar") }
            if scope.contains(where: { $0.dueDate != nil }) {
                Button { store.setDueAll(scope, due: nil) } label: {
                    Label("Remove Due Dates", systemImage: "calendar.badge.minus")
                }
            }
        } else {
            Button { openEditor(.due) } label: { Label("Set Due Date…", systemImage: "calendar") }
            if todo.dueDate != nil {
                Button { store.setDue(todo, due: nil) } label: { Label("Remove Due Date", systemImage: "calendar.badge.minus") }
            }
        }
        Divider()
        // Deleting takes each task's whole subtree; the confirmation says how much that is.
        Button(role: .destructive) { onDelete(scope) } label: {
            Label(isMulti ? "Delete \(scope.count) Tasks…" : "Delete…", systemImage: "trash")
        }
        .keyboardShortcut(.delete, modifiers: .command)
        Divider()
        // Global document undo/redo — discoverable here; the ⌘Z / ⇧⌘Z shortcuts live on the surface.
        Button { store.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
            .disabled(!store.canUndo)
        Button { store.redo() } label: { Label("Redo", systemImage: "arrow.uturn.forward") }
            .disabled(!store.canRedo)
    }
}
