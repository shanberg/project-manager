import Foundation

/// The quick bar's `>` list is `PMCommand` — the same table the menu bar and the menu extra build
/// themselves from. It used to be a parallel enum with its own titles, symbols and keywords, which is
/// how one action came to be "Undo Last Complete" here and "Undo Last Completion" in the menu bar.
///
/// What stays here is the part only this surface has: turning a *typed line* into a command. A menu
/// user points at the command they want; this one types at it, so it needs a split into verb and
/// argument and a ranking over partial words. Neither means anything to a menu.
typealias QuickBarCommand = PMCommand

extension PMCommand {
    /// The commands `>` offers, in declaration order — which is roughly how often each is wanted, so
    /// the bare `>` list opens on the things you actually came for.
    ///
    /// Reached by typing `>` at the head of the line. A sigil rather than prose matching, because the
    /// one thing this bar must never do is guess: a field that decides between "a task called complete
    /// the audit" and "the Complete command" by looking at the words is a field that will eventually
    /// swallow a task. `>` is a decision, not an inference.
    static var offeredInQuickBar: [PMCommand] { quickBarCommands }

    // MARK: What a typed line resolves to

    /// A command and the text meant for it.
    struct Parsed: Equatable {
        var command: PMCommand
        var argument: String
    }

    /// Split `input` into a verb and its argument, when it starts with one and has something after it.
    ///
    /// Only commands with a `verb` can be split this way. Without that restriction `>open finder` would
    /// come apart into "open" and "finder" and run the wrong thing with the right word as its argument.
    static func split(_ input: String, in commands: [PMCommand]) -> Parsed? {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        guard let space = trimmed.firstIndex(of: " ") else { return nil }
        let head = trimmed[trimmed.startIndex..<space].lowercased()
        let rest = trimmed[space...].trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty, let command = commands.first(where: { $0.verb == head }) else { return nil }
        return Parsed(command: command, argument: rest)
    }

    /// Order `commands` by how well they answer `query`, dropping the ones that don't.
    ///
    /// An empty query keeps the declared order.
    static func rank(_ commands: [PMCommand], query: String) -> [PMCommand] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return commands }
        return commands.enumerated().compactMap { index, command -> (Int, Int, PMCommand)? in
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
    ///
    /// Scored against the title with its ellipsis stripped, since the table's titles carry Mac menu
    /// punctuation — `…` is a promise about what happens next, not something anyone types at.
    private func score(for query: String) -> Int? {
        let title = searchableTitle
        if verb == query { return 1100 }
        if title.hasPrefix(query) { return 1000 }
        if title.split(separator: " ").contains(where: { $0.hasPrefix(query) }) { return 800 }
        if keywords.contains(where: { $0.hasPrefix(query) }) { return 600 }
        if title.contains(query) { return 300 }
        return nil
    }

    private var searchableTitle: String {
        title.lowercased().replacingOccurrences(of: "…", with: "")
    }
}
