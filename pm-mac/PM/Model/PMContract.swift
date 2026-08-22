import AppKit
import Foundation
import PmLib

// MARK: - The in-process adapter
//
// PM links PmLib, so it calls the contract's dispatcher directly with native types — no JSON, no
// subprocess. That matters: a panel that redraws at 60fps can't afford a process spawn per keystroke,
// and the contract was designed so it doesn't have to.
//
// This is also the only adapter that can perform all three tiers. Mutations and queries go to the
// dispatcher like everywhere else; affordances — open a window, reveal a folder — are requests to a
// running app, which is what this is. `pm api` and `pm mcp` list them and refuse them.
//
// The reason to route the app's own writes through here rather than straight at `NotesService` isn't
// tidiness. The store holds the tasks from its last read, and the notes file is markdown the user
// also edits in Obsidian and by hand. A click acts on what was on screen, which may no longer be
// what's on disk. Going through the contract means every write carries the task's digest, so that
// case is caught instead of writing to whatever moved into the position. See docs/task-identity.md.

extension Todo {
    /// This task as the contract names it: session date, line, and the digest of its text.
    var reference: TaskRefInput {
        TaskRefInput(session: sessionISODate ?? String(sessionIndex),
                     line: lineIndex,
                     digest: digest)
    }
}

enum PMContract {
    /// Build an input for `project`, optionally about `task`.
    static func input(project: String?, task: Todo? = nil,
                      _ fill: (inout ApiInput) -> Void = { _ in }) -> ApiInput {
        var input = ApiInput()
        input.project = project
        input.task = task?.reference
        fill(&input)
        return input
    }

    /// Run a mutation or a query. Safe off the main actor — it is file work, and the store's writes
    /// happen on its IO queue.
    @discardableResult
    static func perform(_ action: String, _ input: ApiInput, dryRun: Bool = false) throws -> ApiResult {
        try performApi(action, input, options: ApiOptions(dryRun: dryRun, source: "app"))
    }

    /// What to put in front of a person when a write was refused.
    ///
    /// A stale reference isn't a failure so much as a race: the file changed under the read this
    /// click was based on. Saying "that task changed on disk" and reloading is the true and useful
    /// answer; the raw refusal reads like a bug in PM.
    static func message(for error: Error) -> String {
        guard let api = error as? ApiError else { return String(describing: error) }
        switch api.code {
        case .staleReference:
            return "That task changed on disk, so nothing was written. Reloading."
        case .ambiguousProject:
            return "More than one project matches that name."
        default:
            return api.message
        }
    }

    /// True when the right response is to re-read rather than to report a failure and stop.
    static func wantsReload(after error: Error) -> Bool {
        (error as? ApiError)?.code == .staleReference
    }

    // MARK: Affordances
    //
    // The tier the headless adapters can't serve. Same names as the manifest publishes, so the
    // vocabulary is one vocabulary even where only this adapter can act on it.

    @MainActor
    @discardableResult
    static func performAffordance(_ action: String, store: PMStore? = nil) -> Bool {
        switch action {
        case "app.openWindow":
            WindowManager.shared.openFocusedProject()
        case "app.openInFinder":
            guard let path = store?.projectPath else { return false }
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        case "app.openInObsidian":
            guard let store else { return false }
            ObsidianLink.open(store: store)
        case "app.showPanel":
            FocusPanelController.shared.toggle()
        case "app.settings":
            SettingsWindowController.shared.show()
        default:
            return false
        }
        return true
    }
}
