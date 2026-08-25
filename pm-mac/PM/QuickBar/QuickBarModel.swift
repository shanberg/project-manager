import PmLib
import SwiftUI

extension NSEvent.ModifierFlags {
    /// SwiftUI's vocabulary for the same keys. The quick bar reads its modifiers from `onKeyPress`,
    /// which reports them this way, so a click has to say the same thing a keystroke would.
    var eventModifiers: EventModifiers {
        var out: EventModifiers = []
        if contains(.command) { out.insert(.command) }
        if contains(.option) { out.insert(.option) }
        if contains(.control) { out.insert(.control) }
        if contains(.shift) { out.insert(.shift) }
        return out
    }
}

/// What the quick bar is for at the moment it was summoned.
///
/// Two hotkeys, one panel. Capture and navigation want the same window and the same keyboard handling,
/// but they read a typed line in opposite ways — one as text to keep, the other as a query to throw
/// away — and a single field that guesses between them is the way to fill a project's notes with
/// half-typed project names. Which mode you're in is a decision you made before you started typing,
/// which is exactly what a hotkey records. Tab still switches, for when you reach for the wrong one.
enum QuickBarMode: CaseIterable {
    case capture
    case findTask
    case goToProject
    case command
    /// Prose for today's session, written in an editor rather than typed into a field.
    ///
    /// The odd one out on purpose. The other four read a line: three of them as a query to throw away,
    /// one as text to keep, all of them one line long because a task *is* one line. A session note is
    /// not — the file joins paragraphs with a blank line between them and always could — so this mode
    /// swaps the field for the app's own markdown editor and the row list for the one thing ⌘↩ does.
    /// It was the fourth `CapturePlacement` for a long time, wearing the clothes of three siblings it
    /// has nothing in common with, and that is the whole reason its input was a single line.
    case note

    /// The character that puts the bar in this mode when it's the line's first.
    ///
    /// Capture has none, so it's what an ordinary line is. The other two are earned by a keystroke you
    /// meant — which is the whole point: the bar must never decide between "a task called complete the
    /// audit" and "the Complete command" by reading the words, because that decision goes wrong by
    /// writing a command into somebody's notes.
    var sigil: Character? {
        switch self {
        case .capture: return nil
        case .findTask: return "/"
        case .goToProject: return "@"
        case .command: return ">"
        // None, and not for want of a spare character. A sigil is a first keystroke you spend to say
        // what the *rest* of the line is for, which works when the rest of the line is a query. Prose
        // has no character it can't legitimately begin with, and a note that silently lost its first
        // one to a mode switch would be the field editing you. Reached by ⌃⌥N, by ⇧⏎ out of a capture
        // line, and by `>note` — three deliberate keystrokes, none of them a character you might type.
        case .note: return nil
        }
    }

    var placeholder: String {
        switch self {
        case .capture: return "Add a task…"
        case .findTask: return "Find a task…"
        case .goToProject: return "Go to project…"
        case .command: return "Run a command…"
        case .note: return "Write a note for today…"
        }
    }

    /// The mode's name as a destination, for the ⇥ hint to name what it switches to.
    ///
    /// The placeholder says the same words with an ellipsis on them, which reads as an invitation to
    /// type rather than as somewhere to go — and "⇥ switch" on its own never said there was anywhere
    /// to switch *to*, which is the only way the other two modes get discovered by someone who never
    /// learned the second hotkey.
    var shortTitle: String {
        switch self {
        case .capture: return "Add a task"
        case .findTask: return "Find a task"
        case .goToProject: return "Go to project"
        case .command: return "Run a command"
        case .note: return "Write a note"
        }
    }

    var symbol: String {
        switch self {
        case .capture: return "plus.circle"
        case .findTask: return "text.magnifyingglass"
        case .goToProject: return "magnifyingglass"
        case .command: return "chevron.right"
        case .note: return "note.text"
        }
    }

    /// Where ⇥ goes next.
    ///
    /// Ordered as the four things you might have meant, from writing to acting: put a line somewhere,
    /// find a line, find a project, do something to one. A mode you reached by pressing ⇥ once too
    /// many times is three more presses from home, which is the whole reason the cycle is short.
    ///
    /// Note is deliberately *not* in the cycle. Two reasons, and either would do: ⇥ inside the editor
    /// already means indent-this-list-item, which is worth more there than a mode switch; and turning
    /// a launcher into a writing surface is too large a change to be one press away from a key people
    /// hit by accident. Its own value here is what Escape falls back to.
    var next: QuickBarMode {
        switch self {
        case .capture: return .findTask
        case .findTask: return .goToProject
        case .goToProject: return .command
        case .command: return .capture
        case .note: return .capture
        }
    }

    /// The mode a line's first character asks for, if any.
    static func sigilMode(of query: String) -> QuickBarMode? {
        guard let first = query.first else { return nil }
        return allCases.first { $0.sigil == first }
    }
}

/// A project a capture line was redirected to with a trailing `@…`.
struct CaptureTarget: Equatable {
    var key: String
    /// The folder name, codes and all, and the same name without its "CODE-NNN " prefix.
    var name: String
    var shortName: String

    /// Whichever of the two this app has been told to write. See `QuickBarModel.display`.
    var displayName: String { QuickBarModel.display(name, short: shortName) }
}

/// Where a line typed into the quick bar goes.
///
/// One field, several destinations, chosen from a list rather than by a modifier — because the app has
/// more than two of them and a bar you summon from another app is the wrong place to be recalling which
/// chord meant which. The order is the menubar's Add ▸ order so both surfaces teach the same thing, and
/// narrowing leads because that's the app's primary action: a new task nested under the one in hand,
/// which is what you're usually typing when you summon this mid-task. Adding at the end of today's
/// session is the other thing — a task that belongs to the project but not to the task in hand — and
/// it's one ↓ away.
enum CapturePlacement: String, CaseIterable {
    case narrow
    case after
    case sessionEnd
    case sessionNote

    /// Whether this placement is relative to a task, and so needs there to be one.
    var needsAnchor: Bool { self == .narrow || self == .after }

    /// The row's glyph. It flips with the label under ⌥, so the arrow never points the opposite way
    /// from the words next to it.
    func symbol(optionDown: Bool) -> String {
        switch self {
        case .narrow: return "arrow.turn.down.right"
        case .after: return optionDown ? "arrow.up" : "arrow.down"
        case .sessionEnd: return "plus"
        case .sessionNote: return "note.text"
        }
    }

    /// What ⏎ on this row will do, spelled out. `optionDown` flips the sibling row to "before" — the
    /// same alternate the menubar's Add ▸ offers under the same key, live, so holding ⌥ shows you what
    /// you're about to get rather than asking you to trust it.
    func title(anchor: String?, optionDown: Bool) -> String {
        switch self {
        case .narrow: return "Narrow under \(quoted(anchor))"
        case .after: return optionDown ? "Add before \(quoted(anchor))" : "Add after \(quoted(anchor))"
        case .sessionEnd: return "Add to end of the current session"
        case .sessionNote: return "New session note"
        }
    }

    /// What to say once this has run and the bar has gone. Past tense, and naming the same thing the
    /// row named, so the confirmation reads as the answer to the row you chose.
    func confirmation(anchor: String?, optionDown: Bool) -> String {
        switch self {
        case .narrow: return "Added under \(quoted(anchor))"
        case .after: return optionDown ? "Added before \(quoted(anchor))" : "Added after \(quoted(anchor))"
        case .sessionEnd: return "Added to the current session"
        case .sessionNote: return "Added to the session note"
        }
    }

    /// The row's label while the preview is drawing the anchor.
    ///
    /// "it" rather than the task's name, because the name is on screen: the preview highlights the
    /// anchor, so the row can point at it instead of repeating it. Two rows quoting the same 38
    /// characters was the list's noisiest feature, and it was there to answer a question a picture
    /// answers better. What VoiceOver hears is still the full sentence — see `QuickBarRow.spokenTitle`
    /// — because a reader with no preview has no "it" to look at.
    func shortTitle(optionDown: Bool) -> String {
        switch self {
        case .narrow: return "Narrow under it"
        case .after: return optionDown ? "Add before it" : "Add after it"
        case .sessionEnd: return "Add to end of the current session"
        case .sessionNote: return "New session note"
        }
    }

    /// What to say when the write didn't land. The same sentence in the negative, because the failure
    /// has to name the thing you asked for — "couldn't save" tells you nothing about which of the four
    /// rows you pressed.
    func failure(anchor: String?, optionDown: Bool) -> String {
        switch self {
        case .narrow: return "Couldn't add under \(quoted(anchor))"
        case .after:
            return optionDown ? "Couldn't add before \(quoted(anchor))"
                              : "Couldn't add after \(quoted(anchor))"
        case .sessionEnd: return "Couldn't add to the current session"
        case .sessionNote: return "Couldn't add to the session note"
        }
    }

    private func quoted(_ anchor: String?) -> String {
        guard let anchor, !anchor.isEmpty else { return "the focused task" }
        return "“\(QuickBarModel.truncate(anchor, 38))”"
    }
}

/// A task in the focused project, flattened for the preview to draw.
///
/// A copy rather than the `Todo` itself: the preview wants five fields and the model has no business
/// holding the store's value type, its raw line or its context. The two indices are identity — which
/// line the anchor is, and where the new one goes relative to it.
struct PreviewTodo: Equatable {
    var text: String
    var depth: Int
    var checked: Bool
    var isFocused: Bool
    var due: String?
    var sessionIndex: Int
    var lineIndex: Int
}

/// A session heading, for the preview to name what it's showing.
struct PreviewSession: Equatable {
    var date: String
    var label: String
}

/// What the selected row will do to a line.
///
/// Derived by diffing the project against itself-after-the-command, so nothing here needs to know
/// which command produced it — see `QuickBarModel.changes(before:after:added:)`. That's the whole
/// point of running the real transform: the preview can't invent a change the write won't make, and
/// it can't miss one the write will.
enum PreviewChange: Equatable {
    case none
    /// A line that doesn't exist yet: a captured task, an appended note, a parent being wrapped round.
    case adding
    case completing
    case reopening
    /// The project's focus lands here.
    case focusing
    /// Its due date becomes this.
    case retiming(String?)
    /// Its indent changes — what wrapping does to the task it wraps and to everything under it.
    case reindenting

    /// Whether this line is one of the ones the command touches. Everything true here is drawn in the
    /// tint; everything false is context.
    var isChange: Bool { self != .none }
}

/// One drawn line of the session preview.
struct PreviewLine: Equatable, Identifiable {
    enum Kind: Equatable {
        case task, note, blank
        /// A change that fell outside the window, named on the last line rather than left unsaid.
        case elsewhere(below: Bool)
    }
    /// Content-derived, so `ForEach` gives a task that hasn't moved the same identity across a
    /// rebuild and the ghost keeps its own — which is what lets the ghost *slide* between positions
    /// as you arrow, while the tasks around it stay still.
    var id: String
    var kind: Kind
    var change: PreviewChange = .none
    var text: String = ""
    var depth: Int = 0
    var checked = false
    var isFocused = false
    /// The task the selected placement is relative to. Drawn at full contrast while the rest of the
    /// context is dimmed, because it's the "it" the row's label points at.
    var isAnchor = false
    var due: String?

    /// The line being added, which is the one the capture preview is entirely about.
    var isGhost: Bool { change == .adding }

    static func blank(_ n: Int) -> PreviewLine { PreviewLine(id: "blank:\(n)", kind: .blank) }
}

/// The project as a command will leave it, produced by running the real transform against a copy.
///
/// The model diffs this against what's there now and never learns what any individual command does.
/// `added` is the one thing a diff by position can't work out for itself: which line is new, so
/// everything after it lines up against the right predecessor.
struct PreviewOutcome: Equatable {
    var todos: [PreviewTodo]
    var added: Int?
}

/// The session, with the line being typed already in it.
///
/// The rows name a position in prose; this shows it. The two are not equivalent — `insertTaskRelative`
/// puts a child immediately after its anchor, so "Narrow under it" lands the new task *above* that
/// task's existing children, which is a fact a sentence can state and only a picture can make obvious.
struct SessionPreview: Equatable {
    var heading: String
    /// The session's label, or what's odd about it — "new session" when today's doesn't exist yet.
    var detail: String?
    var lines: [PreviewLine]
    /// Whether `detail` is something the command is about to change rather than something that's
    /// already true — `>session standup` renames today's session, which happens in the heading.
    var detailIsChanging = false
    /// Where the ghost sits and how deep, for the view to animate on. Two rows that put the line in
    /// the same place at the same depth shouldn't move anything.
    var ghostIndex: Int
    var ghostDepth: Int
}

/// What the bar says once a row has run: the sentence, and whether it's good news.
///
/// A failure is a receipt too, and it was the one the bar didn't give. A write that didn't land used
/// to close the panel exactly like a write that did, on the reasoning that the app's own failure
/// notification would say so — but a banner arrives somewhere else, some time later, and says what the
/// *store* complained about rather than which of your four rows it was. The bar knows both, at the
/// moment you're still looking at it.
struct QuickBarReceipt: Equatable {
    var message: String
    /// The store's own complaint, under the sentence. Only a failure has one — a success has nothing
    /// left to explain.
    var detail: String?
    var isFailure = false

    static func done(_ message: String) -> QuickBarReceipt { QuickBarReceipt(message: message) }

    static func failed(_ message: String, _ detail: String?) -> QuickBarReceipt {
        QuickBarReceipt(message: message, detail: detail, isFailure: true)
    }

    /// The whole thing as one sentence, for VoiceOver and for measuring how long it takes to read.
    var spoken: String { [message, detail].compactMap { $0 }.joined(separator: ". ") }
}

/// A way out of a list that has nothing in it.
///
/// Every other row in this bar is a thing to do; these are what stand in when there's nothing to do
/// yet. A bar that answers "no focused project" with a sentence is a bar you have to close and start
/// again, and the fix — go and pick a project — is one it could have offered you. So the empty states
/// are rows like any other, and ⏎ takes them.
enum QuickBarAction: Equatable {
    /// Switch to project search, to go and pick somewhere for a line to land.
    case findProject
    /// Switch to capture, keeping what's been typed — for a task you went looking for and didn't find.
    case captureHere(String)
    case newProject
    /// Put back the line the last summon was closed on. See `QuickBarModel.restorable`.
    case restore(String)

    var id: String {
        switch self {
        case .findProject: return "action:findProject"
        case .captureHere: return "action:captureHere"
        case .newProject: return "action:newProject"
        case .restore: return "action:restore"
        }
    }

    var title: String {
        switch self {
        case .findProject: return "Go to a project…"
        case .captureHere(let text): return "Add “\(QuickBarModel.truncate(text, 38))” as a task"
        case .newProject: return "New Project…"
        case .restore(let text): return "Pick up “\(QuickBarModel.truncate(text, 38))”"
        }
    }

    var subtitle: String? {
        switch self {
        case .findProject: return "Then this line has somewhere to go"
        case .captureHere: return nil
        case .newProject: return nil
        case .restore: return "What you were typing last time"
        }
    }

    var symbol: String {
        switch self {
        case .findProject: return "magnifyingglass"
        case .captureHere: return "plus.circle"
        case .newProject: return "plus.square"
        case .restore: return "arrow.uturn.backward"
        }
    }
}

/// One row the quick bar can act on.
enum QuickBarRow: Identifiable, Equatable {
    /// A destination for the line being typed, as parsed — so the due date it picked up is visible
    /// before ⏎, and so is which task it would land under. `text` is empty before you've typed
    /// anything, which is what makes the row a preview of where a line would go rather than something
    /// ⏎ can run; see `isRunnable`.
    case capture(placement: CapturePlacement, text: String, due: String?, anchor: String?,
                 target: CaptureTarget?)
    case project(key: String, name: String, shortName: String, domain: String, isArchived: Bool)
    /// An open task, anywhere. Carries the whole index entry because acting on it means going to
    /// another project: the row has to name where the task lives, and running it has to get there.
    case task(ProjectIndex.TaskEntry)
    /// A verb from the `>` list, with the text typed after it — empty when it was given none, which is
    /// the signal to open the full editor for it rather than to run it on nothing.
    case command(QuickBarCommand, argument: String)
    /// A way out of an otherwise empty list.
    case action(QuickBarAction)

    /// Identity is what the row *is*, never what's been typed into it.
    ///
    /// The rows rebuild on every keystroke, and an id carrying the typed text would hand every row a
    /// new identity each character. `ForEach` would tear down and re-create the views, which re-runs
    /// `.onHover` — so a mouse resting anywhere over the list would take the selection back from the
    /// arrow keys on every letter typed. It's also what the selection is carried across a rebuild by:
    /// see `QuickBarModel.rebuild`.
    var id: String {
        switch self {
        case .capture(let placement, _, _, _, _): return "capture:\(placement.rawValue)"
        case .project(let key, _, _, _, _): return "project:\(key)"
        case .task(let task): return "task:\(task.id)"
        case .command(let command, _): return "command:\(command.rawValue)"
        case .action(let action): return action.id
        }
    }

    /// Whether ⏎ on this row would do anything.
    ///
    /// Only capture rows are ever inert, and only for want of text: they're shown from the moment the
    /// bar opens so that it answers "where would this go?" before you commit to typing, which is the
    /// question you actually have when you summon it over another app.
    var isRunnable: Bool {
        if case .capture(_, let text, _, _, _) = self { return !text.isEmpty }
        return true
    }

    /// What the row says it does. A capture row is titled by its action, not by what you typed — the
    /// typed line is in the field directly above, and four rows repeating it back is noise where the
    /// difference between them is the whole point.
    ///
    /// Here rather than in the view because the row has to describe itself twice: once on screen and
    /// once to VoiceOver, which reads the selection without ever being able to see it.
    func title(optionDown: Bool) -> String {
        switch self {
        case .capture(let placement, _, _, _, _):
            return placement.shortTitle(optionDown: optionDown)
        case .project(_, _, let shortName, _, _): return shortName
        case .task(let task): return QuickBarModel.truncate(task.text, 60)
        case .command(let command, _): return command.title
        case .action(let action): return action.title
        }
    }

    var subtitle: String? {
        switch self {
        case .capture: return nil
        case .project(_, let name, _, let domain, _):
            let code = name.split(separator: " ").first.map(String.init) ?? name
            return domain.isEmpty ? code : "\(code)  ·  \(domain)"
        // Which project it's in, always — a task's text is the same sentence wherever it lives, and
        // "reply to the draft" means two different jobs in two different projects.
        case .task(let task): return QuickBarModel.display(task.projectName, short: task.projectShortName)
        // The text a verb was given, echoed back — or, for a command sitting in the list with none
        // yet, the text it would take and the word that introduces it.
        case .command(let command, let argument):
            if !argument.isEmpty { return argument }
            guard let verb = command.verb, let label = command.argumentLabel else { return nil }
            // Written the way you'd type it, sigil and all, rather than described. The sigil is
            // redundant once you're already in this mode, but it's the form that works from anywhere.
            return ">\(verb) \(label)"
        case .action(let action): return action.subtitle
        }
    }

    func symbol(optionDown: Bool) -> String {
        switch self {
        case .capture(let placement, _, _, _, _): return placement.symbol(optionDown: optionDown)
        case .project(_, _, _, _, let isArchived): return isArchived ? "archivebox" : "folder"
        // The project's own focused task gets the app's focus glyph, so the line you'd have found by
        // going there looks the same here as it does there.
        case .task(let task): return task.isFocused ? "scope" : "circle"
        case .command(let command, _): return command.symbol
        case .action(let action): return action.symbol
        }
    }

    /// The right-hand column. Only a project row has anything to say here — a capture row's due date
    /// and its redirect are shown once, up in the field, since every row shares them.
    var trailing: String? {
        switch self {
        case .capture, .command, .action: return nil
        case .project(_, _, _, _, let isArchived): return isArchived ? "Archived" : nil
        // The badge form, the same three characters a task wears everywhere else in the app. An
        // archived task says so instead: that it's due at all is the less useful fact about it.
        case .task(let task):
            if task.isArchived { return "Archived" }
            return task.due.map { RelativeDue.short($0) }
        }
    }

    /// The row's label with nothing left implicit.
    ///
    /// A capture row on screen says "Narrow under it" and leans on the preview to say what "it" is.
    /// Read aloud there is no preview, so the anchor has to be named — this is the same sentence the
    /// rows carried before the preview existed.
    func spokenTitle(optionDown: Bool) -> String {
        guard case .capture(let placement, _, _, let anchor, _) = self else {
            return title(optionDown: optionDown)
        }
        return placement.title(anchor: anchor, optionDown: optionDown)
    }

    /// One line for VoiceOver, which has no columns to read the parts out of — so the trailing column
    /// joins the sentence rather than being dropped with the layout that carried it.
    func spokenDescription(optionDown: Bool) -> String {
        [spokenTitle(optionDown: optionDown), subtitle, trailing]
            .compactMap { $0 }
            .joined(separator: ", ")
    }
}

/// What a capture line currently reads as.
///
/// Recomputed with the rows, from the query alone, so the field's badges and the rows below them are
/// two views of one reading rather than two parses that can disagree about what ⏎ is going to do.
struct CaptureReading: Equatable {
    var text: String = ""
    var due: String?
    /// A `due:` phrase that couldn't be read as a date. It stays in `text`; this is what the field
    /// says so with.
    var unreadableDue: String?
    /// Where a trailing `@…` redirected the line, when it named a project that exists.
    var target: CaptureTarget?
}

/// The quick bar's state and what its rows do.
///
/// Held apart from the view because the controller re-seeds it on every summon and because the row
/// building is the part worth testing: what a typed line resolves to shouldn't need a window on screen
/// to find out.
@MainActor
final class QuickBarModel: ObservableObject {
    /// What the hotkey asked for, and what ⇥ cycles through. A sigil at the head of the line overrides
    /// it for as long as it's there.
    @Published private(set) var baseMode: QuickBarMode = .capture { didSet { rebuild() } }
    @Published var query: String = "" {
        didSet {
            guard query != oldValue else { return }
            // A receipt is about the line before this one. The moment there's a new line being typed
            // it's history, and leaving it up would have the footer reporting one thing while the
            // field is plainly busy with another.
            receipt = nil
            rebuild()
        }
    }

    /// The mode in force.
    ///
    /// A sigil wins over the summoned mode, and deleting it hands the line back to whatever you
    /// summoned — so a project search you started with `@` in the middle of a capture can't quietly
    /// turn into task text as you delete, and one you summoned with ⌃⌥O never can at all.
    var mode: QuickBarMode { QuickBarMode.sigilMode(of: query) ?? baseMode }

    /// The note being written, in note mode. Empty otherwise.
    ///
    /// Held apart from `query` rather than reusing it, and the separation is load-bearing. `query` is
    /// read for a leading sigil, a trailing `@project`, and a `due:` phrase — three things that must
    /// never be read out of prose. "@dana pushed back" would silently file the note in someone else's
    /// project; "due: end of week" would be eaten out of the middle of a sentence. So the note body
    /// goes somewhere nothing parses it, and the one thing a note does need from that vocabulary — a
    /// project other than the focused one — is decided before the writing starts, in `noteTarget`.
    @Published var noteText: String = "" {
        didSet {
            guard noteText != oldValue else { return }
            receipt = nil
            rebuild()
            onNoteChanged(noteText)
        }
    }

    /// Where the note goes, when that isn't the focused project.
    ///
    /// Set on the way in — carried over from the `@…` of the capture line that was promoted — and then
    /// fixed for as long as the note is being written. See `noteText` for why it can't be re-read.
    @Published var noteTarget: CaptureTarget? { didSet { if noteTarget != oldValue { rebuild() } } }

    /// Bumped every time the writing surface opens, so the editor knows to take the caret even when
    /// SwiftUI has kept the one from last time. See `MarkdownTextEditor.focusRequest`.
    @Published private(set) var noteFocusToken = 0

    /// What the mode acts on: the line with its sigil taken off.
    ///
    /// The sigil has to be the very first character, which is also the escape hatch — a task that
    /// genuinely begins "@Dana" is typed with a leading space, and the capture parser trims that back
    /// off before the task is written.
    var argument: String {
        QuickBarMode.sigilMode(of: query) == nil ? query : String(query.dropFirst())
    }
    @Published private(set) var rows: [QuickBarRow] = []
    /// Index into `rows`. Kept pointing at the row it was on across a rebuild; see `rebuild`.
    @Published var selection: Int = 0

    /// What the typed line reads as, in capture. Empty in the other two modes, which read their line
    /// as a query rather than as something to keep.
    @Published private(set) var reading = CaptureReading()

    /// What the bar says once a row has run and the change has landed or didn't — one line in the
    /// footer, where the hint usually is, for as long as it takes to read. Nil while the bar is being
    /// typed into.
    ///
    /// Deliberately not the whole panel and deliberately not a dialog. The bar stays up after a row
    /// runs so the next one can be typed straight away, which means the receipt has to share the
    /// screen with a field that still has the keyboard: it takes nothing away, it's cleared by the
    /// first keystroke of the next line, and until then it's the only evidence that the last one
    /// landed somewhere you can't see.
    @Published var receipt: QuickBarReceipt?

    /// The focused project's display name, or nil when there isn't one — capture has nowhere to go
    /// unless the line named somewhere with `@`.
    ///
    /// This and the four values below are what the rows are derived from besides the query, and each
    /// rebuilds on being set. The controller seeds them together and could just as well rebuild once at
    /// the end, but then the order it happened to write them in would be load-bearing — and a row list
    /// that silently reflects four of five inputs is the kind of wrong that looks right.
    @Published var focusedProjectName: String? { didSet { if focusedProjectName != oldValue { rebuild() } } }

    /// The task a captured line would be placed relative to. Nil when the project has no open tasks,
    /// which is what takes the two anchored placements off the list.
    ///
    /// The whole task rather than its text: the preview needs to know which line it is and how deep,
    /// and a second source for the same fact is a second thing that can disagree with the write.
    @Published var anchor: PreviewTodo? { didSet { if anchor != oldValue { rebuild() } } }

    /// What the rows call the anchor.
    var focusedTaskText: String? { anchor?.text }

    /// Every task in the focused project, in file order, for the preview to draw a window of.
    ///
    /// Already loaded — this is the same `todos` the menubar and any open window are showing — so the
    /// preview costs no read. It is a snapshot like everything else the bar holds, and it's refreshed
    /// by `QuickBarController.refreshContext` on the same signal the anchor is.
    @Published var projectTodos: [PreviewTodo] = [] {
        didSet {
            guard projectTodos != oldValue else { return }
            outcomeCache = nil
            rebuild()
        }
    }

    /// The project's session headings, indexed the way `PreviewTodo.sessionIndex` indexes them.
    @Published var sessions: [PreviewSession] = []

    /// Which session is today's, or nil when the project hasn't got one yet — which is worth drawing,
    /// because a placement silently creating a session is the bar's quietest side effect.
    @Published var todaySession: Int?

    /// Whether the next thing written into the focused project opens a session of its own — because
    /// the project has none for today, or has been left alone past `PmLib.sessionIdleWindow`. The
    /// preview draws the new heading either way, so the side effect is on screen before you commit to
    /// it rather than discovered in the file afterwards.
    @Published var startsNewSession = false

    /// The current session's note as it stands, for the note placement to append its ghost to.
    @Published var todayNote: String?

    /// Whether there's a completion to take back — what puts Undo Last Complete on the `>` list.
    @Published var canUndoCompletion = false { didSet { if canUndoCompletion != oldValue { rebuild() } } }

    /// Whether diving in would land anywhere. A command that would quietly do nothing is worse than a
    /// command that isn't offered.
    @Published var hasNextTask = false { didSet { if hasNextTask != oldValue { rebuild() } } }

    /// Which of Archive and Unarchive the focused project can be on the receiving end of. Only ever
    /// one of the two, since it's already in one folder or the other.
    @Published var focusedProjectIsArchived = false { didSet { if focusedProjectIsArchived != oldValue { rebuild() } } }

    /// The focused project's key, for ranking: a task in the project you're already in wins a tie
    /// against the same words somewhere else.
    @Published var focusedProjectKey: String? { didSet { if focusedProjectKey != oldValue { rebuild() } } }

    /// Whether ⌥ is held right now, published by the controller's flags monitor. Only the labels want
    /// it — running a row reads the modifiers off the keystroke that ran it.
    @Published var optionDown = false

    /// How many matches the row list is not showing. Zero when it's showing them all.
    ///
    /// A list capped at `rowLimit` and silent about it looks exactly like a list of everything that
    /// matched, and the difference is whether your query needs narrowing or your task doesn't exist.
    @Published private(set) var overflow = 0

    /// The rest of the project name the top row would give you, for the field to ghost after what
    /// you've typed. Nil unless what you've typed is a genuine prefix of it — see `completion(for:)`.
    @Published private(set) var completion: String?

    /// Whether a change to the bar's height should be animated.
    ///
    /// The panel's height is the content's height — the controller measures one and sets the other —
    /// so this is the only place the growing and shrinking can be animated without the window frame
    /// and the corner masks becoming separate interpolations of the same edge. Held off for the
    /// length of a summon: this object and its view both outlive the panel being ordered out, so the
    /// first layout of a new summon would otherwise animate away from the last one's rows.
    @Published var animatesLayout = false

    /// Recent projects (empty query) and everything (a query), supplied by the controller so the model
    /// stays free of the scan.
    var recents: [ProjectIndex.Recent] = []
    var allProjects: [ProjectIndex.ProjectEntry] = []

    /// Every open task the bar can search, supplied by the controller from the project index with the
    /// focused project's own tasks read live over the top. See `QuickBarController.seed`.
    var allTasks: [ProjectIndex.TaskEntry] = []

    /// The line the last summon was closed on, if it was closed on one recently enough to still be
    /// wanted. Offered as a row rather than typed back into the field: a bar that opens with the last
    /// thing you typed already in it is a bar you have to clear before you can use it, and the whole
    /// point of catching this is that it costs nothing when you didn't want it.
    var restorable: String?

    /// Ask the app what the project looks like once a command has run.
    ///
    /// Set by the controller, which is where PmLib lives. The point of asking rather than working it
    /// out here is that the answer comes from the same function the write calls: a preview that
    /// reimplements a command is a second implementation, and the two drift apart on the day one of
    /// them is fixed.
    var dryRun: (QuickBarCommand, _ argument: String) -> PreviewOutcome? = { _, _ in nil }

    /// The last answer `dryRun` gave, and to what. See `outcome(for:argument:)`.
    private var outcomeCache: (key: String, outcome: PreviewOutcome?)?

    /// Runs a chosen row. Set by the controller, which owns what "go to a project" means.
    var onRun: (QuickBarRow, _ modifiers: EventModifiers) -> Void = { _, _ in }
    var onDismiss: () -> Void = {}
    /// Every edit to the note body, for the controller to keep a draft of. Prose is worth more than a
    /// task line and there is more of it, so it is written down as it's typed rather than caught on the
    /// way out — see `QuickBarController.saveNoteDraft`.
    var onNoteChanged: (String) -> Void = { _ in }
    /// The writing surface opening, however it was asked for. The controller answers with the draft
    /// belonging to wherever the note is going.
    var onEnterNote: (CaptureTarget?) -> Void = { _ in }

    // MARK: Rows

    func reset(mode: QuickBarMode) {
        // Cleared before anything else so the rebuilds below have no previous row to carry a selection
        // over from. A summon starts at the top of its list; the last one's is not an answer to it.
        rows = []
        selection = 0
        receipt = nil
        query = ""
        // Emptied here and filled by the controller straight afterwards when there's a draft to put
        // back — a summon must never inherit the last one's prose by accident, only on purpose.
        noteText = ""
        noteTarget = nil
        baseMode = mode
        optionDown = false
        // A summon into the writing surface is as much a request for the caret as a promotion into it
        // is; the editor may be the very one the last summon left mounted.
        if mode == .note { noteFocusToken += 1 }
        rebuild()
    }

    /// Turn the bar into the writing surface, with `text` already in it.
    ///
    /// `target` is spent on the way in and then frozen: it comes from the `@…` of the capture line this
    /// was promoted out of, which is the last moment anything is entitled to read a project name out of
    /// what you typed. See `noteText`.
    func enterNote(text: String, target: CaptureTarget?) {
        receipt = nil
        selection = 0
        optionDown = false
        query = ""
        noteTarget = target
        noteText = text
        baseMode = .note
        noteFocusToken += 1
        rebuild()
        onEnterNote(target)
    }

    /// What ⇧⏎ does to a capture line: keeps the words, drops the field.
    ///
    /// The one inference the bar allows itself, and it isn't one — a newline is a keystroke you meant,
    /// exactly as `>` is, and the rule this bar keeps is that it never decides between a task and a
    /// note by *reading the words*. What it takes across is the line as capture had already parsed it:
    /// the text without its `@…` suffix, and the project that suffix named.
    ///
    /// The trailing newline is the keystroke itself, honoured. You asked for a new line; here it is,
    /// with the caret on it.
    func promoteToNote() {
        guard mode == .capture else { return }
        let seed = reading.text.trimmingCharacters(in: .whitespacesAndNewlines)
        enterNote(text: seed.isEmpty ? "" : seed + "\n", target: reading.target)
    }

    /// What Escape does in note mode: back to the launcher, empty-handed.
    ///
    /// Not a dismiss. Escape in a writing surface means "out of the writing surface", and the bar has
    /// somewhere to be that isn't gone — so it lands on capture, where a second press closes it if that
    /// is what was wanted. Nothing is lost on the way: the controller has been writing the draft down
    /// since the first keystroke, and puts it back on the next summon.
    func leaveNote() {
        noteText = ""
        noteTarget = nil
        switchTo(.capture, text: "")
    }

    /// Ready the line for the next thing, a row having just run — without touching the receipt for it.
    ///
    /// The near-twin of `reset`, and the difference is the whole point of both. `reset` is a summon:
    /// a mode arrives with it and nothing on screen survives. This is the bar carrying on — same
    /// summon, same mode, same panel, one more line to type. It drops the sigil with the text, so a
    /// `>` command you just ran hands the field back to the mode you actually summoned rather than
    /// leaving you queued up to run another one.
    ///
    /// `clearingText: false` is for a row that didn't land. The line in the field is then the only
    /// copy of what you typed, and emptying it would be the bar throwing away a sentence *because*
    /// it failed to write it.
    func resume(clearingText: Bool) {
        optionDown = false
        if clearingText {
            query = ""
            noteText = ""
        }
        rebuild()
        // After the rebuild, not before: `rebuild` carries the selection over by identity, and what's
        // wanted here is the top of the list. The row you arrowed to was an answer to the line you
        // just spent, not to the empty one replacing it.
        selection = 0
    }

    /// Rebuild the rows, keeping the selection on the row it was on.
    ///
    /// By identity, never by index. The two failures this sits between are both real: an index left
    /// alone points at a different row after every keystroke, and ⏎ then runs something you glanced at
    /// three characters ago; an index reset to zero throws away a destination you deliberately arrowed
    /// to, which in capture — where the four rows are fixed and only the text changes — happens on
    /// every letter of the sentence you're still typing. Following the id does neither: you stay on
    /// what you chose while it's on offer, and fall back to the top when it isn't.
    func rebuild() {
        let previous = selectedRow?.id
        reading = mode == .capture ? readCapture() : CaptureReading()
        let built = buildRows()
        rows = built.rows
        overflow = built.overflow
        completion = completion(for: built.rows)
        selection = previous.flatMap { id in rows.firstIndex { $0.id == id } } ?? 0
    }

    /// The rest of the name the top row would give you, when what you've typed is the start of it.
    ///
    /// Only ever a project name, and only ever a prefix. The ranking finds projects by initials and by
    /// fragments too — "hmax" for "H-004 Maxwell Carmody" — and there is no honest way to ghost the
    /// rest of a match the typed letters are scattered through: the completion has to be text that
    /// appears immediately after the caret, or it's a lie about what pressing → would do.
    ///
    /// Case is the typed line's, not the project's. Ghosting "axwell Carmody" after a typed "m" is
    /// right; silently correcting the "m" to "M" as you accept it is the field editing you.
    private func completion(for rows: [QuickBarRow]) -> String? {
        let typed: String
        switch mode {
        case .goToProject: typed = argument
        // The `@…` on the end of a capture line is the same search, so it gets the same help — and
        // this is where a project name is most tedious to type, because it's the tail of a sentence
        // you're already most of the way through.
        case .capture: typed = QuickCaptureParser.splitTarget(argument)?.projectQuery ?? ""
        case .findTask, .command, .note: return nil
        }
        let needle = typed.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return nil }
        let names: [String]
        switch mode {
        case .capture:
            guard let target = reading.target else { return nil }
            names = [target.shortName, target.name]
        default:
            guard case .project(_, let name, let shortName, _, _) = rows.first else { return nil }
            names = [shortName, name]
        }
        // The short name first: it's what the row shows, so it's what accepting should agree with.
        for name in names where name.count > needle.count {
            if name.lowercased().hasPrefix(needle.lowercased()) {
                return String(name.dropFirst(needle.count))
            }
        }
        return nil
    }

    /// Read the capture line: where it's going, what it says, and what date it carries.
    private func readCapture() -> CaptureReading {
        let split = QuickCaptureParser.splitTarget(argument)
        let target = split.flatMap { resolveTarget($0.projectQuery) }
        // The redirect comes off before the date is read, so `due:friday @maxwell` gets both. Typed the
        // other way round the `@` token swallows the date phrase and resolves to nothing, and the whole
        // line falls through to being read as text with a date on it — which is the right answer for
        // that order too. Either way the rule to teach is that the redirect goes last.
        let line = target == nil ? argument : (split?.text ?? argument)
        let parsed = QuickCaptureParser.parse(line)
        return CaptureReading(text: parsed.text, due: parsed.due,
                              unreadableDue: parsed.unreadableDue, target: target)
    }

    /// The project a `@…` names, or nil when it names none.
    ///
    /// The top of the same ranking the `@` mode lists, so the project a query redirects to is the one
    /// that query would have taken you to. Nil is the safe answer and the common one: "email @dana"
    /// with no project called Dana stays a task about Dana.
    private func resolveTarget(_ query: String) -> CaptureTarget? {
        let matches = ProjectSearch.rank(allProjects, query: query) { entry in
            ProjectSearch.Candidate(name: entry.name, shortName: entry.shortName,
                                    code: entry.code, isArchived: entry.isArchived)
        }
        guard let best = matches.first else { return nil }
        return CaptureTarget(key: best.projectKey, name: best.name, shortName: best.shortName)
    }

    /// A row list and how much of the match it isn't showing.
    private struct RowSet {
        var rows: [QuickBarRow]
        var overflow = 0

        /// Cap a list of matches at `rowLimit`, remembering what got left off.
        static func capped<T>(_ matches: [T], _ row: (T) -> QuickBarRow) -> RowSet {
            RowSet(rows: matches.prefix(QuickBarModel.rowLimit).map(row),
                   overflow: max(0, matches.count - QuickBarModel.rowLimit))
        }
    }

    private func buildRows() -> RowSet {
        switch mode {
        // One row, never drawn.
        //
        // The note surface has no list to choose from — there is one destination and ⌘↩ goes to it —
        // and the view knows not to render one. But the row is what the controller runs: `isRunnable`
        // gates an empty note, `spokenDescription` is what VoiceOver reads, and `apply(.sessionNote…)`
        // is reached the same way it is from the capture list. A second path to the same write would
        // be a second place for it to go wrong.
        case .note:
            let text = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
            return RowSet(rows: [.capture(placement: .sessionNote, text: text, due: nil,
                                          anchor: nil, target: noteTarget)])

        case .capture:
            // Somewhere to put it: the project you're in, or the one the line named. With neither,
            // the only useful thing the bar can offer is a way to get one.
            guard reading.target != nil || focusedProjectName != nil else {
                return RowSet(rows: [.action(.findProject), .action(.newProject)])
            }
            // The line the last summon was closed on, before it's been typed over. Only on an empty
            // field: once there's a line in the bar, the old one is not what you're doing.
            var rows: [QuickBarRow] = []
            if reading.text.isEmpty, let restorable, !restorable.isEmpty {
                rows.append(.action(.restore(restorable)))
            }
            rows += CapturePlacement.allCases
                .filter(isOffered)
                .map { .capture(placement: $0, text: reading.text, due: reading.due,
                                anchor: focusedTaskText, target: reading.target) }
            return RowSet(rows: rows)

        case .command:
            let available = QuickBarCommand.allCases.filter(isAvailable)
            // A verb with text after it is one command with one argument, not a list to choose from —
            // you already named it.
            if let parsed = QuickBarCommand.split(argument, in: available) {
                return RowSet(rows: [.command(parsed.command, argument: parsed.argument)])
            }
            let matches = QuickBarCommand.rank(available, query: argument)
            // Nothing answers to the word, and the reason is usually that the commands which would
            // have are the ones with no project to act on.
            if matches.isEmpty {
                return RowSet(rows: focusedProjectName == nil ? [.action(.findProject)] : [])
            }
            return RowSet.capped(matches) { .command($0, argument: "") }

        case .findTask:
            if argument.trimmingCharacters(in: .whitespaces).isEmpty {
                // Nothing typed: the project you're in, top to bottom. The same answer `@` gives with
                // an empty line — here's what's nearest, before you've told me what you want.
                let here = allTasks.filter { $0.projectKey == focusedProjectKey }
                return RowSet(rows: here.prefix(Self.rowLimit).map { .task($0) })
            }
            let matches = TaskSearch.rank(allTasks, query: argument,
                                          focusedProjectKey: focusedProjectKey)
            // A task you went looking for and couldn't find is very often a task that doesn't exist
            // yet, and you have already typed it.
            if matches.isEmpty { return RowSet(rows: [.action(.captureHere(argument))]) }
            return RowSet.capped(matches) { .task($0) }

        case .goToProject:
            if argument.trimmingCharacters(in: .whitespaces).isEmpty {
                return RowSet(rows: recents.prefix(Self.rowLimit).map {
                    .project(key: $0.projectKey, name: $0.name,
                             shortName: shortName(of: $0.name), domain: "", isArchived: false)
                })
            }
            let matches = ProjectSearch.rank(allProjects, query: argument) { entry in
                ProjectSearch.Candidate(name: entry.name, shortName: entry.shortName,
                                        code: entry.code, isArchived: entry.isArchived)
            }
            // No project answers to it — so the useful reading of what you typed is a name for one
            // that doesn't exist yet.
            if matches.isEmpty { return RowSet(rows: [.action(.newProject)]) }
            return RowSet.capped(matches) {
                .project(key: $0.projectKey, name: $0.name, shortName: $0.shortName,
                         domain: $0.domain, isArchived: $0.isArchived)
            }
        }
    }

    /// Whether a placement is on offer for the line as it currently reads.
    private func isOffered(_ placement: CapturePlacement) -> Bool {
        // A dated line is a task by definition, so the note row stands down rather than offering to
        // write a due date into prose that can't carry one.
        if placement == .sessionNote, reading.due != nil { return false }
        guard reading.target == nil else {
            // A redirected line has no anchor. The only task the bar could name is the focused one,
            // which belongs to the project you're *in* rather than the one you're sending this to, and
            // it can't name a task in a project it hasn't loaded. So the two relative placements come
            // off the list rather than being offered against the wrong task.
            return !placement.needsAnchor
        }
        if placement.needsAnchor { return focusedTaskText != nil }
        return true
    }

    /// Whether a command has anything to act on right now. What isn't offered can't be run into a
    /// no-op from a bar you can't see the consequences of.
    private func isAvailable(_ command: QuickBarCommand) -> Bool {
        switch command {
        case .newProject, .settings: return true
        case .complete, .editTask, .setDue, .wrapTask: return focusedTaskText != nil
        case .undoLast: return canUndoCompletion
        case .diveIn: return hasNextTask
        case .archiveProject: return focusedProjectName != nil && !focusedProjectIsArchived
        case .unarchiveProject: return focusedProjectName != nil && focusedProjectIsArchived
        default: return focusedProjectName != nil
        }
    }

    /// How many rows the bar will show. Enough to choose from, few enough to read without scrolling —
    /// past this the answer is a better query, not a longer list.
    ///
    /// `nonisolated` because `RowSet.capped` is a plain generic helper on a nested type and has no
    /// business hopping to the main actor to read an integer.
    nonisolated static let rowLimit = 7

    /// Shorten a task's text to fit in a row's title, on a word boundary where there is one.
    nonisolated static func truncate(_ text: String, _ limit: Int) -> String {
        guard text.count > limit else { return text }
        let cut = text.prefix(limit)
        let trimmed = cut.contains(" ") ? cut[cut.startIndex..<cut.lastIndex(of: " ")!] : cut
        return trimmed.trimmingCharacters(in: .whitespaces) + "…"
    }

    /// A folder name without its "CODE-NNN " prefix.
    ///
    /// Static because the view wants it too: the sidebar's `PMSidebarShowCode` decides whether a name
    /// is shown with its code, and the bar has only ever been handed the full name.
    nonisolated static func shortName(of name: String) -> String {
        guard let dash = name.firstIndex(of: "-"),
              let space = name[dash...].firstIndex(of: " ") else { return name }
        let rest = name[name.index(after: space)...].trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? name : rest
    }

    /// The recents list carries only the full folder name, so the title has to come off the front here.
    private func shortName(of name: String) -> String { Self.shortName(of: name) }

    /// A project's folder name as this app has been told to write them.
    ///
    /// `PMSidebarShowCode` is the sidebar's preference by name and the app's by meaning: it's a choice
    /// about codes, not about one list, and a bar that spells out a code the rest of the app has been
    /// told to leave off is the app disagreeing with itself. Read from defaults rather than bound
    /// through `@AppStorage` because the controller composes its receipts outside any view — and the
    /// bar is never on screen at the same time as Settings, so there is nothing for a live binding to
    /// keep up with.
    ///
    /// `short` is passed when the caller already has the name parsed — the project index splits the
    /// prefix off as it scans, and its answer is the authoritative one.
    nonisolated static func display(_ full: String, short: String? = nil) -> String {
        guard UserDefaults.standard.object(forKey: "PMSidebarShowCode") as? Bool ?? true else {
            return short ?? shortName(of: full)
        }
        return full
    }

    /// A due date spelled out — "Sat, Aug 22". Shared so the field's badge and a receipt written after
    /// the bar has gone say the date the same way.
    nonisolated static func dueLabel(_ date: Date) -> String { dueFormatter.string(from: date) }

    // MARK: Keyboard

    func moveSelection(by delta: Int) {
        guard !rows.isEmpty else { return }
        selection = (selection + delta + rows.count) % rows.count
    }

    func runSelection(modifiers: EventModifiers = []) {
        guard let row = selectedRow, row.isRunnable else { return }
        onRun(row, modifiers)
    }

    func switchMode() {
        // The line keeps its text but loses its sigil: a `>` left in place would contradict the mode ⇥
        // just chose, and the sigil is what wins.
        switchTo(mode.next, text: argument)
    }

    /// Put the bar in a mode with a given line in it — what an empty state's row does when the way out
    /// of it is a different mode. Goes through `baseMode` rather than writing a sigil, so deleting
    /// your way back through the text can't strand you somewhere you never asked to be.
    func switchTo(_ next: QuickBarMode, text: String) {
        query = text
        baseMode = next
        selection = 0
    }

    /// Take the ghosted completion into the field. Returns whether there was one to take.
    ///
    /// Appended, never spliced: the completion is only ever offered for text that runs to the end of
    /// the line — a whole `@` query, or the `@…` suffix of a capture line — so the end of the string
    /// is where the caret is whenever this can fire.
    func acceptCompletion() -> Bool {
        guard let completion, !completion.isEmpty else { return false }
        query += completion
        return true
    }

    /// What Escape does: empty the line, or dismiss when it's already empty.
    ///
    /// Two presses rather than one, because one press was unrecoverable — a sentence you were most of
    /// the way through went with the bar, and re-summoning gave you a blank field. It costs the quick
    /// dismiss nothing: a bar you summoned by mistake has an empty line in it, and still closes on the
    /// first press. Clearing takes any sigil with it, which hands the line back to the mode you
    /// summoned — the same thing deleting the sigil by hand does.
    func clearOrDismiss() {
        if query.isEmpty { onDismiss() } else { query = "" }
    }

    // MARK: The session preview

    /// The session with the line being typed already in it, or nil when there's nothing to show.
    ///
    /// Computed rather than published, because it depends on the *selection* as much as on the query —
    /// and the selection moves without a rebuild. A stored copy would need every mover to remember to
    /// refresh it; a computed one is re-read whenever the view re-renders, which is every time any of
    /// its inputs is `@Published`.
    var preview: SessionPreview? {
        switch mode {
        case .capture: return capturePreview()
        case .command: return commandPreview()
        case .findTask, .goToProject: return nil
        // The note surface has `noteTail` instead. A five-line diagram of a session is the right answer
        // to "where would this line go" and the wrong one to "what am I adding to": once the thing
        // being written is ten lines of prose, the useful context is the prose it joins, in its own
        // words, not a picture of the tasks underneath it.
        case .note: return nil
        }
    }

    /// The tail of today's note, for the editor to be writing at the end of.
    ///
    /// The last two paragraphs, which is what `notePreview` showed as ghost-lines and is the right
    /// amount for the same reason: you are continuing a train of thought, and the thought you are
    /// continuing is the last one. The whole note is a scroll away in the window; this is the part that
    /// changes what you're about to write.
    var noteTail: [String] {
        guard mode == .note, noteTarget == nil else { return [] }
        guard let existing = todayNote?.trimmingCharacters(in: .whitespacesAndNewlines),
              !existing.isEmpty else { return [] }
        return existing.split(separator: "\n").map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .suffix(2)
    }

    private func capturePreview() -> SessionPreview? {
        guard let placement = previewPlacement else { return nil }
        let ghost = ghostLine(depth: 0)

        // A redirected line goes to a project this bar hasn't read — deliberately; see
        // `QuickBarModel.isOffered`. So the honest preview is where it's going and nothing else,
        // rather than a window onto the session you happen to be standing in.
        if let target = reading.target {
            return SessionPreview(heading: target.displayName, detail: "today's session",
                                  lines: [ghost], ghostIndex: 0, ghostDepth: 0)
        }

        switch placement {
        case .narrow, .after: return anchoredPreview(placement)
        case .sessionEnd: return endPreview()
        case .sessionNote: return notePreview()
        }
    }

    // MARK: The preview in command mode

    /// The session as the selected command will leave it.
    ///
    /// The tinted lines are the ones the command touches, worked out by diffing the project against
    /// the result of running the command's own transform on a copy of it. A command that touches no
    /// task draws the session unchanged and untinted — which holds the box's height steady as you
    /// arrow down the list, and says the useful thing about those commands in the only way that can't
    /// be misread: nothing here lights up.
    private func commandPreview() -> SessionPreview? {
        guard let (command, argument) = previewCommand, focusedProjectName != nil else { return nil }
        // A note is prose at the head of the session, not a line among the tasks — the same shape the
        // capture placement draws, with the verb's own text in it.
        if command == .sessionNote {
            return notePreview(text: argument.isEmpty ? "" : argument)
        }

        let outcome = outcome(for: command, argument: argument)
        let after = outcome?.todos ?? projectTodos
        let marks = changes(before: projectTodos, after: after, added: outcome?.added)

        // Whichever session the change is in — a focus left on Tuesday's task is exactly when a
        // command acts somewhere other than where you assume it does.
        let changed = marks.firstIndex(where: \.isChange)
        let session = changed.map { after[$0].sessionIndex }
            ?? anchor?.sessionIndex ?? todaySession
        guard let session else { return nil }

        var lines: [PreviewLine] = []
        var focus: Int?
        for (index, task) in after.enumerated() where task.sessionIndex == session {
            if index == changed { focus = lines.count }
            lines.append(line(task, change: marks[index]))
        }
        guard !lines.isEmpty || changed != nil else {
            // A project with tasks, but none in the session we settled on. Nothing to draw and nothing
            // honest to draw instead.
            return nil
        }
        // Nothing changed, so there's no "here" but where you already are.
        let around = focus ?? lines.firstIndex { $0.isAnchor } ?? max(0, lines.count - 1)
        var preview = windowed(lines, around: around, session: session, depth: 0)
        preview = naming(offWindow: marks, after: after, session: session, in: preview)
        if command == .startSession { preview = relabelled(preview, to: argument) }
        // Seeing what's about to go into the archive is the point of showing the box at all here.
        if command == .archiveProject { preview.detail = "→ archive" ; preview.detailIsChanging = true }
        return preview
    }

    /// Which command the preview is drawing — the selected one, or the first, on the same reasoning
    /// `previewPlacement` uses.
    private var previewCommand: (QuickBarCommand, String)? {
        if case .command(let command, let argument) = selectedRow { return (command, argument) }
        for row in rows { if case .command(let c, let a) = row { return (c, a) } }
        return nil
    }

    /// Line-by-line, what the command does to the project.
    ///
    /// Positional, with one allowance for the single line a command can insert: everything after it
    /// compares against its own predecessor rather than sliding by one and reporting the whole tail as
    /// changed. Precedence is by how much the change matters to look at — a task that is completed and
    /// also loses focus is a completion, not a defocus.
    private func changes(before: [PreviewTodo], after: [PreviewTodo], added: Int?) -> [PreviewChange] {
        after.enumerated().map { index, task in
            if index == added { return .adding }
            let peer = (added.map { index > $0 } ?? false) ? index - 1 : index
            guard before.indices.contains(peer) else { return .adding }
            let was = before[peer]
            if was.checked != task.checked { return task.checked ? .completing : .reopening }
            if was.depth != task.depth { return .reindenting }
            if was.due != task.due { return .retiming(task.due) }
            if !was.isFocused, task.isFocused { return .focusing }
            return .none
        }
    }

    /// Spend the box's last line on a change that fell outside the window.
    ///
    /// Completing a task strikes its whole subtree in one place and moves the focus to another, and
    /// those can be further apart than the box is tall — so the half of the answer you most wanted
    /// could sit just off the bottom. A box that quietly showed five lines of a six-line story would
    /// be worse than one that showed four and said so.
    private func naming(offWindow marks: [PreviewChange], after: [PreviewTodo], session: Int,
                        in preview: SessionPreview) -> SessionPreview {
        let shown = Set(preview.lines.map(\.id))
        let visible = after.indices.filter { shown.contains(Self.identity(after[$0])) }
        let offWindow = after.indices.filter { index in
            marks[index].isChange && after[index].sessionIndex == session
                && !shown.contains(Self.identity(after[index]))
        }
        // The one that says something the box isn't already saying. Completing a parent strikes its
        // whole subtree and then moves the focus; when the subtree is longer than the window, the
        // first thing off the bottom is another struck-through child — which you can already see four
        // of — and the thing actually worth a line is the focus landing somewhere else entirely. So
        // prefer a kind of change that isn't on screen, and fall back to document order.
        let onScreen = Set(preview.lines.map(\.change).filter(\.isChange).map(Self.kindName))
        let missed = offWindow.first { !onScreen.contains(Self.kindName(marks[$0])) } ?? offWindow.first
        guard let missed, !preview.lines.isEmpty else { return preview }
        let below = visible.max().map { missed > $0 } ?? true
        var preview = preview
        preview.lines[preview.lines.count - 1] = PreviewLine(
            id: "elsewhere", kind: .elsewhere(below: below), change: marks[missed],
            text: Self.phrase(marks[missed], Self.truncate(after[missed].text, 38)))
        return preview
    }

    /// `>session standup` renames today's session, which is a change to the heading rather than to
    /// anything in the list under it.
    private func relabelled(_ preview: SessionPreview, to label: String) -> SessionPreview {
        var preview = preview
        if label.isEmpty {
            if todaySession == nil { preview.detail = "new session"; preview.detailIsChanging = true }
        } else {
            preview.detail = label
            preview.detailIsChanging = true
        }
        return preview
    }

    /// The project after a command, asked of the app and remembered until the question changes.
    ///
    /// Cached because `preview` is computed on every render and this is a real transform plus a parse.
    /// The key is the whole question; the cache is dropped outright whenever the project moves under
    /// the bar, which is what `projectTodos`' setter does.
    private func outcome(for command: QuickBarCommand, argument: String) -> PreviewOutcome? {
        let key = "\(command.rawValue)\u{1}\(argument)"
        if let cached = outcomeCache, cached.key == key { return cached.outcome }
        let outcome = dryRun(command, argument)
        outcomeCache = (key, outcome)
        return outcome
    }

    /// Which placement the preview is drawing.
    ///
    /// The selected row when it's a capture row, and otherwise the first one that is. The restore row
    /// sits above the placements and would otherwise blank the box out from under them — and a box
    /// that comes and goes as the selection moves takes the hint line and the panel's height with it.
    private var previewPlacement: CapturePlacement? {
        if case .capture(let placement, _, _, _, _) = selectedRow { return placement }
        for row in rows { if case .capture(let placement, _, _, _, _) = row { return placement } }
        return nil
    }

    /// The line being typed, as it will be written.
    ///
    /// `reading.text` is what the parser kept, so an unreadable `due:thurdsay` is still in it — which
    /// means the preview shows the marker sitting in the task's title exactly as the file will have
    /// it. That's a stronger answer than the field's warning badge: you see the mistake in the task
    /// rather than being told about it.
    private func ghostLine(depth: Int, kind: PreviewLine.Kind = .task,
                          text: String? = nil, due: String? = nil) -> PreviewLine {
        PreviewLine(id: "ghost", kind: kind, change: .adding, text: text ?? reading.text,
                    depth: depth, due: due ?? reading.due)
    }

    private func line(_ todo: PreviewTodo, change: PreviewChange = .none) -> PreviewLine {
        PreviewLine(id: Self.identity(todo), kind: .task, change: change,
                    text: todo.text, depth: todo.depth, checked: todo.checked,
                    isFocused: todo.isFocused,
                    isAnchor: anchor.map { $0.sessionIndex == todo.sessionIndex
                                        && $0.lineIndex == todo.lineIndex } ?? false,
                    due: todo.due)
    }

    /// A task's identity as a drawn line: where it is in the file. Content-derived so `ForEach` keeps
    /// a line that hasn't moved, and so the window can be asked what it's already showing.
    private static func identity(_ todo: PreviewTodo) -> String {
        "task:\(todo.sessionIndex):\(todo.lineIndex)"
    }

    /// A change's kind, ignoring what it's changing to — so two tasks taking different dates count as
    /// the same kind of news.
    private static func kindName(_ change: PreviewChange) -> String {
        if case .retiming = change { return "retiming" }
        return "\(change)"
    }

    /// A change named in one clause, for the line that reports what's off the bottom of the box.
    private static func phrase(_ change: PreviewChange, _ text: String) -> String {
        switch change {
        case .focusing: return "focus moves to “\(text)”"
        case .completing: return "“\(text)” completes too"
        case .reopening: return "“\(text)” reopens"
        case .retiming: return "“\(text)” takes the date"
        case .reindenting: return "“\(text)” moves with it"
        case .adding: return "“\(text)” is added"
        case .none: return text
        }
    }

    /// The two placements that are relative to a task, drawn in that task's own session — which is not
    /// necessarily today's. Naming the session the anchor is actually in is the point: a focus left on
    /// a task from Tuesday is exactly the case where "Add after it" surprises you.
    private func anchoredPreview(_ placement: CapturePlacement) -> SessionPreview? {
        guard let anchor else { return nil }
        var lines = projectTodos.filter { $0.sessionIndex == anchor.sessionIndex }.map { line($0) }
        guard let at = lines.firstIndex(where: { $0.isAnchor }) else { return nil }
        let before = placement == .after && optionDown
        let index = before ? at : at + 1
        let depth = placement == .narrow ? anchor.depth + 1 : anchor.depth
        lines.insert(ghostLine(depth: depth), at: index)
        return windowed(lines, around: index, session: anchor.sessionIndex, depth: depth)
    }

    /// The unanchored add: the end of the current session, or the session it's about to create.
    private func endPreview() -> SessionPreview? {
        guard let today = todaySession, !startsNewSession else {
            return SessionPreview(heading: Self.todayHeading, detail: "new session",
                                  lines: padded([ghostLine(depth: 0)]), ghostIndex: 0, ghostDepth: 0)
        }
        var lines = projectTodos.filter { $0.sessionIndex == today }.map { line($0) }
        lines.append(ghostLine(depth: 0))
        return windowed(lines, around: lines.count - 1, session: today, depth: 0)
    }

    /// A note is prose at the head of the session, not a task in it — so the ghost goes above the
    /// tasks rather than among them, which is where `appendNoteToCurrentSession` puts it.
    private func notePreview(text: String? = nil) -> SessionPreview? {
        let ghost = ghostLine(depth: 0, kind: .note, text: text)
        guard let today = todaySession, !startsNewSession else {
            return SessionPreview(heading: Self.todayHeading, detail: "new session",
                                  lines: padded([ghost]), ghostIndex: 0, ghostDepth: 0)
        }
        var lines: [PreviewLine] = []
        // Only the tail of an existing note: what a new paragraph lands under, not the whole note.
        if let existing = todayNote?.trimmingCharacters(in: .whitespacesAndNewlines), !existing.isEmpty {
            let paragraphs = existing.split(separator: "\n").map(String.init)
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            lines += paragraphs.suffix(2).enumerated().map { offset, text in
                PreviewLine(id: "note:\(offset)", kind: .note, text: text)
            }
        }
        let index = lines.count
        lines.append(ghost)
        lines += projectTodos.filter { $0.sessionIndex == today }.map { line($0) }
        return windowed(lines, around: index, session: today, depth: 0)
    }

    /// Pad a short list out to the box's height.
    ///
    /// The rule the box keeps is that its height may change when the *bar's state* does — a redirect
    /// resolving takes two rows off the list at the same moment — but never as the selection moves
    /// within one state. A project whose today's session doesn't exist yet is the case that broke it:
    /// the anchored placements draw a five-line window onto whichever session the anchor is in, and
    /// the two unanchored ones had nothing to draw, so ↑/↓ resized the panel by four lines.
    private func padded(_ lines: [PreviewLine]) -> [PreviewLine] {
        guard lines.count < Self.previewLines else { return lines }
        return lines + (lines.count..<Self.previewLines).map(PreviewLine.blank)
    }

    /// A fixed number of lines around the ghost, padded when the session is shorter than that.
    ///
    /// Constant height is the whole discipline here. The box sits under the rows, so if it grew and
    /// shrank as the selection moved, the hint line and the panel's own height would move on every
    /// ↑/↓ — and the panel resizing under a selection you are about to press ⏎ on is the thing this
    /// bar has been most careful to avoid everywhere else.
    private func windowed(_ lines: [PreviewLine], around ghost: Int, session: Int,
                          depth: Int) -> SessionPreview {
        var shown = lines
        var index = ghost
        if lines.count > Self.previewLines {
            // Two lines of context above where there are two to give, and the shortfall handed to the
            // side that has room — so the ghost is centred in the middle of a session and pinned near
            // the edge at either end of one.
            var start = ghost - (Self.previewLines - 1) / 2
            start = min(max(0, start), lines.count - Self.previewLines)
            shown = Array(lines[start..<(start + Self.previewLines)])
            index = ghost - start
        } else {
            shown = padded(shown)
        }
        let heading = sessions.indices.contains(session) ? sessions[session] : nil
        let isToday = session == todaySession
        return SessionPreview(
            heading: isToday ? Self.todayHeading : (heading?.date ?? "Session"),
            detail: heading.map { $0.label.isEmpty ? nil : $0.label } ?? nil,
            lines: shown, ghostIndex: index, ghostDepth: depth)
    }

    /// How many lines the preview draws. Enough to see the shape around the insertion point, few
    /// enough that the box stays a glance rather than a list to read.
    static let previewLines = 5

    /// Today's session heading, named the way the session list names it.
    private static var todayHeading: String { "Today · \(formatSessionDate())" }

    /// Whether the list is standing in for one that came back empty — every row on offer is a way out
    /// rather than an answer. What the hint line keys its "nothing matched" sentence on.
    ///
    /// Not simply "no rows": the rows are never empty any more, which is the point. A capture list
    /// with a restore row on top of four real placements isn't an empty state, so this asks whether
    /// *all* of them are actions rather than whether any is.
    var isEmptyState: Bool {
        guard !rows.isEmpty else { return false }
        return rows.allSatisfy { if case .action = $0 { return true } else { return false } }
    }

    /// The selected row, for the hint line to describe.
    var selectedRow: QuickBarRow? {
        rows.indices.contains(selection) ? rows[selection] : nil
    }

    /// The due date the typed line parsed to, spelled out — "Sat, Aug 22", or "Sat, Aug 22 3:00 PM"
    /// when a time was typed too — or nil when it carries no date. Written in full where a task's own
    /// badge would say "in 1w": a badge on an existing task tells you how much time is left, while this
    /// confirms that the "friday 3pm" you just typed landed on the day and time you meant.
    var parsedDueLabel: String? {
        guard let due = reading.due, let date = RelativeDue.parse(due) else { return nil }
        let day = Self.dueLabel(date)
        return RelativeDue.carriesTime(due) ? "\(day) \(RelativeDue.timeLabel(date))" : day
    }

    /// What to say about a `due:` the parser couldn't read.
    ///
    /// The phrase stays in the task text, deliberately — losing "due:thurdsay" to a typo is worse than
    /// a task with a typo in its title. But a line that kept its marker as prose looks exactly like a
    /// line that never had one, and by the time you could tell the difference the bar has closed and
    /// you're somewhere else. Said where the date would have been, so the one slot answers the one
    /// question: what date is this getting?
    var unreadableDueLabel: String? {
        guard let phrase = reading.unreadableDue else { return nil }
        return "“\(Self.truncate(phrase, 18))” isn't a date"
    }

    nonisolated private static let dueFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEE MMM d")
        return formatter
    }()
}
