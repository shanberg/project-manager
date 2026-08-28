import AppKit
import PmLib

/// Runs a `PMCommand` against the focused project — the one execution path the menu bar and the menu
/// extra share.
///
/// Both surfaces act on the same thing: whatever `focused.json` names, held as one `PMStore` by
/// `StoreRegistry`. So there was never a reason for them to have two implementations of Complete, and
/// having two is how the menu extra came to offer Rename and Archive while the menu bar didn't.
///
/// The quick bar deliberately doesn't come through here. It runs the same commands, but it has an
/// argument to hand them (`>due friday`), a preview to draw beforehand and a receipt to give after,
/// and it stays open across the write — none of which a menu does. Sharing the *table* is what stops
/// the three drifting; sharing the execution too would mean bending one surface's needs around
/// another's.
@MainActor
enum PMCommandRunner {
    static func run(_ command: PMCommand, store: PMStore) {
        switch command {
        // The task in hand. These are the three the store answers directly.
        case .complete:
            guard let focused = store.focusedTodo else { return }
            store.complete(focused)
        case .undoLast:
            store.undoLast()
        case .diveIn:
            store.diveIn()

        // The editors. All five open in the focus panel, which is a non-activating HUD — so typing
        // into one from a menu doesn't pull you out of whatever app you were in. That property is the
        // whole reason these live there rather than in a window.
        case .narrowFocus:
            FocusPanelController.shared.show(editor: .add, position: .child)
        case .addAfter:
            FocusPanelController.shared.show(editor: .add, position: .after)
        case .addBefore:
            FocusPanelController.shared.show(editor: .add, position: .before)
        case .editTask:
            FocusPanelController.shared.show(editor: .edit)
        case .wrapTask:
            FocusPanelController.shared.show(editor: .wrap)
        case .setDue:
            FocusPanelController.shared.show(editor: .due)

        // The session. Both open the current session's note in a window, starting a session first
        // when there isn't one to continue — the note goes in the notes, so this opens the place that
        // edits them rather than offering a second, smaller editor for the same text.
        case .startSession, .sessionNote:
            WindowManager.shared.openFocusedProject().newSession(nil)

        // The project. Three of these are contract affordances, performed under the same names the
        // manifest publishes rather than through a second vocabulary — see `PMContract`.
        case .openWindow:
            PMContract.performAffordance("app.openWindow", store: store)
        case .openInFinder:
            PMContract.performAffordance("app.openInFinder", store: store)
        case .openInObsidian:
            PMContract.performAffordance("app.openInObsidian", store: store)
        case .openInEditor:
            guard let path = store.projectPath else { return }
            CodeEditor.open(path: path)
        case .editDetails:
            WindowManager.shared.openFocusedProject().editDetails()
        case .addLink:
            ProjectPrompts.addLink(store: store)
        case .renameProject:
            guard let name = store.projectName else { return }
            ProjectPrompts.rename(projectNamed: name,
                                  isArchived: PMCommand.Context.isArchived(key: store.projectKey))
        case .archiveProject, .unarchiveProject:
            guard let name = store.projectName else { return }
            do {
                try ProjectLifecycle.move(projectNamed: name,
                                          from: command == .archiveProject ? .active : .archive)
            } catch {
                ProjectLifecycle.present(error, doing: command == .archiveProject
                                         ? "Couldn't archive “\(name)”" : "Couldn't unarchive “\(name)”")
            }

        // The app.
        case .newProject:
            ProjectPrompts.newProject { key in WindowManager.shared.open(projectKey: key) }
        case .settings:
            PMContract.performAffordance("app.settings", store: store)
        }
    }
}
