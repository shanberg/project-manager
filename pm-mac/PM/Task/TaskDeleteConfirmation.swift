import SwiftUI
import PmLib

/// "Delete these?" — the prompt a list puts up before cutting into itself.
///
/// **Inline rather than an alert or a sheet**: this is a confirmation, not an interruption. It names
/// what is about to go without blocking the surface, so you can still look at the list you are about
/// to cut into. Return deletes, Escape cancels.
///
/// **It earns its place even though ⌘Z reverses a delete**, because the subtasks riding along are the
/// part you cannot see from the rows you picked, and this is where they get named.
///
/// **Written once because two lists now delete.** The project window's column has asked this since it
/// had rows; the project card is the same list on a board and can delete a whole selection at a time
/// as of docs/canvas-workspaces.md §7d. Pinned under the header in the window and above the rows on a
/// card — where it sits is the caller's business, what it says is not.
struct TaskDeleteConfirmation: View {
    /// The tasks about to go. Empty draws nothing, so a caller can hand its state straight in.
    let todos: [Todo]
    @ObservedObject var store: PMStore
    var confirm: () -> Void
    var cancel: () -> Void

    var body: some View {
        if !todos.isEmpty {
            let summary = store.deletionSummary(todos)
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(prompt(summary))
                        .font(.callout.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    if summary.descendants > 0 {
                        Text("Also deletes \(Self.count(summary.descendants, "subtask")).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    Button("Cancel", action: cancel)
                        .keyboardShortcut(.cancelAction)
                    Button("Delete", role: .destructive, action: confirm)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .controlSize(.small)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.06))
            Divider()
        }
    }

    /// "Delete “Ship the thing”?" for one task, "Delete 4 tasks?" for a set — the same shape a Mac
    /// alert would use, naming the single case and counting the plural one.
    private func prompt(_ summary: (tasks: Int, descendants: Int)) -> String {
        if summary.tasks == 1, let only = store.outermost(todos).first {
            return "Delete “\(only.text.truncated(60))”?"
        }
        return "Delete \(Self.count(summary.tasks, "task"))?"
    }

    static func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }
}
