import Foundation

/// What ranking needs to know about a task, so the same ranking serves a live scan and a cached one.
///
/// The macOS app keeps a warmed index of every project's open tasks and doesn't want it re-read to
/// search it; the CLI and a model have no index and want the answer now. Both conform.
public protocol SearchableTask {
    var text: String { get }
    /// Whether this is its project's focused task, which floats it up the ranking.
    var isFocused: Bool { get }
    var isArchived: Bool { get }
    /// The project this task belongs to, for the tie-break toward the one you're already in.
    var projectKey: String { get }
}


/// Ranks open tasks against what's been typed into the quick bar's `/` mode.
///
/// Separate from `ProjectSearch` because the two are matching different kinds of string. A project is
/// a short name you half-remember, so initials and fragments have to work — "hmax" finds "H-004
/// Maxwell Carmody". A task is a sentence somebody wrote, and what you remember of it is words:
/// "audit dana", not "audna". So this splits the query on spaces and asks every word to appear
/// somewhere, in any order, which is how you actually recall a line you wrote three weeks ago.
public enum TaskSearch {
    /// Matches for `query`, best first. An empty query matches nothing — the caller shows the focused
    /// project's own tasks instead, which is a different list with a different order.
    public static func rank<Task: SearchableTask>(_ tasks: [Task], query: String,
                                                 focusedProjectKey: String?) -> [Task] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return [] }
        let words = needle.split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }
        return tasks
            .compactMap { task -> (task: Task, score: Int)? in
                guard let score = score(task, needle: needle, words: words,
                                       focusedProjectKey: focusedProjectKey) else { return nil }
                return (task, score)
            }
            .sorted { $0.score > $1.score }
            .map(\.task)
    }

    /// A task's score for a query, or nil when any word of the query is missing from it.
    ///
    /// Every word has to match *something* — a task that answers half your query is a task you didn't
    /// mean, and letting it through is how a list of one right answer becomes a list of nine wrong
    /// ones. The words are then averaged rather than summed, so a two-word query and a five-word one
    /// produce scores in the same range and the bonuses below mean the same thing in both.
    public static func score(_ task: some SearchableTask, needle: String, words: [String],
                             focusedProjectKey: String?) -> Int? {
        let text = task.text.lowercased()
        var total = 0
        for word in words {
            guard let word = wordScore(text, needle: word) else { return nil }
            total += word
        }
        var score = total / words.count

        // The query as one phrase, found as one phrase. This is the difference between recalling a
        // task and merely sharing vocabulary with it, so it outweighs every tier above.
        if text.contains(needle) { score += 500 }
        if text.hasPrefix(needle) { score += 300 }
        // The project's own focused task: of everything in a project, this is the line most likely to
        // be the one being looked for.
        if task.isFocused { score += 120 }
        // A tie between two projects goes to the one you're already in.
        if let focusedProjectKey, task.projectKey == focusedProjectKey { score += 60 }
        // Shorter tasks win ties: with two equally good matches, the one carrying less other text is
        // the one the query described more completely.
        score -= min(task.text.count, 99)
        // Archived projects still match — tasks get looked up long after the work stopped — but never
        // ahead of live work.
        if task.isArchived { score -= 2000 }
        return score
    }

    /// How well one word of the query is answered by the task's text, or nil when it isn't at all.
    ///
    /// Coarse bands, like `ProjectSearch.score`, and for the same reason: an order you can explain is
    /// an order you can trust. The start of a word reads as deliberate, anywhere inside one is a
    /// weaker but real match, and scattered letters are the last resort.
    private static func wordScore(_ text: String, needle: String) -> Int? {
        if text == needle { return 1000 }
        if text.hasPrefix(needle) { return 800 }
        if wordPrefixMatch(text, needle: needle) { return 600 }
        guard needle.count >= minLooseMatchLength else { return nil }
        if text.contains(needle) { return 400 }
        if isSubsequence(needle, of: text) { return 200 }
        return nil
    }

    /// Below this length, a query word has to *start* a word of the task.
    ///
    /// Same threshold as `ProjectSearch`, for the same reason: at one or two characters the loose
    /// tiers stop discriminating and start returning everything. "to" is inside most sentences in
    /// English, and a search that matches most sentences is not a search.
    private static let minLooseMatchLength = 3

    /// True when `needle` starts any word of `haystack`. Punctuation counts as a break, so "dana"
    /// finds "…to Dana," and "api" finds "the (API) doc".
    private static func wordPrefixMatch(_ haystack: String, needle: String) -> Bool {
        haystack
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .contains { $0.hasPrefix(needle) }
    }

    /// True when every character of `needle` appears in `haystack`, in order.
    private static func isSubsequence(_ needle: String, of haystack: String) -> Bool {
        var remaining = Substring(needle)
        for character in haystack {
            if character == remaining.first { remaining = remaining.dropFirst() }
            if remaining.isEmpty { return true }
        }
        return remaining.isEmpty
    }
}

/// A task found by a search, with everything needed to act on it next.
///
/// The contract's search result. It carries the reference — session date, line, digest — because a
/// search that made you look the task up again before doing anything with it would be half an answer.
public struct TaskSearchHit: Codable, Equatable, SearchableTask {
    public let projectFolder: String
    public let projectName: String
    public let projectKey: String
    public let isArchived: Bool
    public let text: String
    public let due: String?
    public let isFocused: Bool
    public let session: String?
    public let line: Int
    public let digest: String?
}

/// Every open task in every project, for a search with no index behind it.
///
/// The macOS app keeps a warmed index and doesn't call this; the CLI and a model have nothing warmed
/// and would rather pay one scan than maintain one. A project whose notes can't be read is skipped
/// rather than failing the search — one unreadable file shouldn't hide every other project's work.
public func searchableTasks(includeArchived: Bool = true, includeActive: Bool = true) throws -> [TaskSearchHit] {
    let (config, paths) = try loadConfigAndPaths(skipPathValidation: true)
    let codes = Array(config.domains.keys)
    // "Active" means everything in hand, which is both the projects and the areas — an area's tasks are
    // no less findable for the thing they belong to not having an end.
    var scopes: [ProjectScope] = []
    if includeActive { scopes.append(contentsOf: [.active, .areas]) }
    if includeArchived { scopes.append(.archive) }

    var hits: [TaskSearchHit] = []
    for scope in scopes {
        let base = scope.path(in: paths)
        let archived = scope.isArchived
        for folder in (try? getFolders(basePath: base, scope: scope, domainCodes: codes)) ?? [] {
            let projectPath = (base as NSString).appendingPathComponent(folder)
            guard let notesPath = (try? resolveNotesPath(projectPath: projectPath)) ?? nil,
                  let rawText = try? String(contentsOfFile: notesPath, encoding: .utf8),
                  let notes = try? parseNotes(markdown: rawText),
                  let todos = try? parseTodos(notes: normalizeFocusMarker(notes: notes)) else { continue }
            for todo in todosWithEffectiveDueDates(todos) where !todo.checked {
                hits.append(TaskSearchHit(
                    projectFolder: folder,
                    projectName: projectTitle(fromFolderName: folder),
                    projectKey: "\(base):\(folder)",
                    isArchived: archived,
                    text: todo.text,
                    due: todo.effectiveDueDate ?? todo.dueDate,
                    isFocused: todo.isFocused,
                    session: todo.sessionISODate,
                    line: todo.lineIndex,
                    digest: todo.digest))
            }
        }
    }
    return hits
}
