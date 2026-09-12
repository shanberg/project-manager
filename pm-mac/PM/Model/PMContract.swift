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
    /// How often this app's writes have had their reference healed against a document that moved.
    ///
    /// **A counter to be sampled either side of a write, rather than a callback**, which is the shape
    /// the app already uses for the other thing a write can report out of band: see
    /// `PMStore.WriteFailure` and `QuickBarController.settle`, which compares the refusal count before
    /// and after to tell "this write failed" from "an unrelated reload failed". The same reasoning
    /// applies here and for the same reason — writes run on a background queue and more than one store
    /// can be writing.
    ///
    /// A count and nothing else: the words belong to whichever surface is speaking. The contract's own
    /// sentence already carries the clause for anything that shows `summary` — see
    /// `Phrase.tellingItHadMoved` — and the quick bar composes its own receipt, so it appends its own.
    static let relocations = Relocations()

    final class Relocations: @unchecked Sendable {
        private let lock = NSLock()
        private var tally = 0
        var count: Int { lock.lock(); defer { lock.unlock() }; return tally }
        fileprivate func noteOne() { lock.lock(); tally += 1; lock.unlock() }
    }

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
        let result = try performApi(action, input, options: ApiOptions(dryRun: dryRun, source: "app"))
        // A reference that had to move to find its task. The write happened and was right; this is the
        // app noticing that the list a click was based on had gone out of date underneath it, which is
        // worth saying once and quietly. See `relocations`, and docs/task-identity.md.
        if result.relocated { relocations.noteOne() }
        return result
    }

    /// What to put in front of a person when a write was refused.
    ///
    /// Neither refusal is a failure so much as a race: the file changed under the read this click was
    /// based on. Saying so plainly is the true and useful answer; the raw refusal reads like a bug in
    /// PM. There's no "should I reload?" to ask alongside it — every write the store makes reloads
    /// afterwards regardless, so by the time the sentence is on screen the list under it is current.
    static func message(for error: Error) -> String {
        guard let api = error as? ApiError else { return String(describing: error) }
        switch api.code {
        case .staleReference:
            return "That task changed on disk, so nothing was written. Reloading."
        case .conflict:
            // Only a batch can raise this, and only because it sent a revision. Say what a person can
            // act on: the selection is the thing that went out of date, and it's in front of them.
            return "This project changed on disk, so the selection was left alone. Try again."
        case .ambiguousProject:
            return "More than one project matches that name."
        default:
            return api.message
        }
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
