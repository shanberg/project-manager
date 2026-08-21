import Foundation

/// The verbs the quick bar can run — what's left once "a line of text to keep" is taken care of.
///
/// Reached by typing `>` at the head of the line. A sigil rather than prose matching, because the one
/// thing this bar must never do is guess: a field that decides between "a task called complete the
/// audit" and "the Complete command" by looking at the words is a field that will eventually swallow a
/// task. `>` is a decision, not an inference.
///
/// The list is deliberately shorter than the menu bar's. These are the things worth doing without
/// leaving the app you're in; everything else is a menu away once you're in PM.
enum QuickBarCommand: String, CaseIterable, Identifiable {
    case complete
    case diveIn
    case sessionNote
    case undoLast
    case editTask
    case setDue
    case wrapTask
    case startSession
    case addLink
    case openWindow
    case openInFinder
    case openInObsidian
    case renameProject
    case newProject
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .complete: return "Complete Focused Task"
        case .diveIn: return "Dive In"
        case .sessionNote: return "Add Session Note"
        case .undoLast: return "Undo Last Complete"
        case .editTask: return "Edit Focused Task"
        case .setDue: return "Set Due Date"
        case .wrapTask: return "Wrap Focused Task"
        case .startSession: return "Start Today's Session"
        case .addLink: return "Add Link"
        case .openWindow: return "Open Project Window"
        case .openInFinder: return "Open in Finder"
        case .openInObsidian: return "Open in Obsidian"
        case .renameProject: return "Rename Project"
        case .newProject: return "New Project"
        case .settings: return "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .complete: return "checkmark.circle"
        case .diveIn: return "arrow.down.to.line"
        case .sessionNote: return "note.text"
        case .undoLast: return "arrow.uturn.backward"
        case .editTask: return "pencil"
        case .setDue: return "calendar"
        case .wrapTask: return "arrow.up.and.down.and.arrow.left.and.right"
        case .startSession: return "calendar.badge.plus"
        case .addLink: return "link"
        case .openWindow: return "macwindow"
        case .openInFinder: return "folder"
        case .openInObsidian: return "book.closed"
        case .renameProject: return "square.and.pencil"
        case .newProject: return "plus.square"
        case .settings: return "gearshape"
        }
    }

    /// The single word that introduces this command's text, for the commands that take any.
    ///
    /// One word, and never shared between two commands, because this is what splits a typed line into
    /// a verb and its argument — `>note had a call with Dana`. Two commands answering to the same verb
    /// would make that split a guess, which is the thing this whole mode exists to avoid.
    var verb: String? {
        switch self {
        case .sessionNote: return "note"
        case .setDue: return "due"
        case .startSession: return "session"
        default: return nil
        }
    }

    /// What the text after the verb is for, shown as a placeholder in the row.
    var argumentLabel: String? {
        switch self {
        case .sessionNote: return "what happened"
        case .setDue: return "tomorrow, friday, in 2w…"
        case .startSession: return "a label for today"
        default: return nil
        }
    }

    /// Extra words this command answers to, beyond the ones in its title.
    var keywords: [String] {
        switch self {
        case .complete: return ["done", "check", "finish", "tick"]
        case .diveIn: return ["next", "deeper"]
        case .sessionNote: return ["note", "log", "journal"]
        case .undoLast: return ["undo", "revert", "uncheck"]
        case .editTask: return ["retitle"]
        case .setDue: return ["due", "date", "defer", "schedule", "when"]
        case .wrapTask: return ["parent", "outdent"]
        case .startSession: return ["session", "today", "day"]
        case .addLink: return ["url", "bookmark"]
        case .openWindow: return ["show"]
        case .openInFinder: return ["reveal", "folder", "files"]
        case .openInObsidian: return ["notes", "markdown"]
        case .renameProject: return ["title"]
        case .newProject: return ["create", "start"]
        case .settings: return ["preferences", "config", "shortcuts"]
        }
    }

    // MARK: What a typed line resolves to

    /// A command and the text meant for it.
    struct Parsed: Equatable {
        var command: QuickBarCommand
        var argument: String
    }

    /// Split `input` into a verb and its argument, when it starts with one and has something after it.
    ///
    /// Only commands with a `verb` can be split this way. Without that restriction `>open finder` would
    /// come apart into "open" and "finder" and run the wrong thing with the right word as its argument.
    static func split(_ input: String, in commands: [QuickBarCommand]) -> Parsed? {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        guard let space = trimmed.firstIndex(of: " ") else { return nil }
        let head = trimmed[trimmed.startIndex..<space].lowercased()
        let rest = trimmed[space...].trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty, let command = commands.first(where: { $0.verb == head }) else { return nil }
        return Parsed(command: command, argument: rest)
    }

    /// Order `commands` by how well they answer `query`, dropping the ones that don't.
    ///
    /// An empty query keeps the declared order, which is roughly how often each is wanted — so the
    /// bare `>` list opens on the things you actually came for.
    static func rank(_ commands: [QuickBarCommand], query: String) -> [QuickBarCommand] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return commands }
        return commands.enumerated().compactMap { index, command -> (Int, Int, QuickBarCommand)? in
            guard let score = command.score(for: q) else { return nil }
            return (score, index, command)
        }
        .sorted { $0.0 != $1.0 ? $0.0 > $1.0 : $0.1 < $1.1 }
        .map(\.2)
    }

    /// How well this command answers `query`, or nil when it doesn't at all.
    ///
    /// Prefixes only, apart from the last tier: a bar you type two letters into wants the commands that
    /// *start* that way, and matching anywhere in the string is how "in" comes to offer everything with
    /// "in" buried in it.
    private func score(for query: String) -> Int? {
        let title = self.title.lowercased()
        if verb == query { return 1100 }
        if title.hasPrefix(query) { return 1000 }
        if title.split(separator: " ").contains(where: { $0.hasPrefix(query) }) { return 800 }
        if keywords.contains(where: { $0.hasPrefix(query) }) { return 600 }
        if title.contains(query) { return 300 }
        return nil
    }
}
