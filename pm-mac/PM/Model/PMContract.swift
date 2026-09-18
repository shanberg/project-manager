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
        // The ordinal too, when the date names the sitting: without it a reference means the day's first
        // sitting, and a line there with the same text and number would be taken for this one.
        TaskRefInput(session: sessionISODate ?? String(sessionIndex),
                     sessionOrdinal: sessionISODate != nil && sessionOrdinal > 0 ? sessionOrdinal : nil,
                     line: lineIndex,
                     digest: digest)
    }
}

extension ApiInput {
    /// The names of the fields this input actually sets.
    ///
    /// By reflection rather than by encoding it: the synthesised `Codable` conformance omits nil
    /// optionals, so the JSON keys would answer the same question — but that is a detail of how the
    /// compiler happens to synthesise an encoder, and this is a check whose whole job is to be
    /// trustworthy. `Mirror` asks the struct directly.
    ///
    /// Only used by the debug-build completeness check below, so the cost of reflection is paid in
    /// builds that are already paying for assertions.
    var givenFieldNames: Set<String> {
        var names: Set<String> = []
        for child in Mirror(reflecting: self).children {
            guard let label = child.label else { continue }
            // An optional that is set reflects as `.some`; one that is nil has no children at all.
            if Mirror(reflecting: child.value).displayStyle == .optional,
               Mirror(reflecting: child.value).children.isEmpty { continue }
            names.insert(label)
        }
        return names
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
    ///
    /// Takes a `PMAction` rather than a string, so a misspelled action is a compile error here the way
    /// it already was in Raycast's generated client. See `PMActions.generated.swift`.
    @discardableResult
    static func perform(_ action: PMAction, _ input: ApiInput, dryRun: Bool = false) throws -> ApiResult {
        assertInputIsComplete(for: action, input)
        let result = try performApi(action.rawValue, input,
                                    options: ApiOptions(dryRun: dryRun, source: "app"))
        // A reference that had to move to find its task. The write happened and was right; this is the
        // app noticing that the list a click was based on had gone out of date underneath it, which is
        // worth saying once and quietly. See `relocations`, and docs/task-identity.md.
        if result.relocated { relocations.noteOne() }
        return result
    }

    /// **A missing required field, said at the call site rather than three frames down.**
    ///
    /// `ApiInput` is one struct of twenty-nine optional fields serving forty-three actions, so the
    /// compiler cannot tell that `task.setDue` without a `due` is incomplete — the dispatcher refuses
    /// it at runtime, and the app turns that into "that task changed on disk", which is the wrong
    /// sentence for a bug in PM. Debug builds trap on it instead, naming the action and the field.
    ///
    /// Debug only, deliberately: in a release build the dispatcher's refusal is still the right
    /// behaviour, and trapping in front of a person over a programming error is not.
    private static func assertInputIsComplete(for action: PMAction, _ input: ApiInput) {
        #if DEBUG
        let given = input.givenFieldNames
        for field in action.requiredFields where !given.contains(field) {
            assertionFailure("\(action.rawValue) needs `\(field)`, which this input does not set")
        }
        for group in action.exclusiveGroups where group.filter(given.contains).count != 1 {
            assertionFailure("\(action.rawValue) needs exactly one of \(group.joined(separator: ", "))")
        }
        #endif
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
}
