import Foundation
import PmLib

/// What a project card draws of the project it is showing.
///
/// **A board is the one surface that shows several projects at once, and it was showing all of each of
/// them.** A project card rendered the whole notes document — the brief, every session, every task —
/// so six projects on a board was six of everything, when what you wanted from five of them was the
/// current state and the open work.
///
/// The setting exists for a second reason that turned out to matter more: it is what makes two
/// workspaces different. "The project and Jira" beside "its tasks and Figma" are two cards on the same
/// project, and without this they are the same card twice. `StoreRegistry` refcounts, so both hold one
/// store and stay in step with each other and with the window.
///
/// **What a card shows is not what a card can do.** A card set to tasks can still start a session,
/// write its note, and edit the brief — the brief simply appears while you are editing it and goes back
/// to being hidden when you leave. This is a lens on one document, not a smaller version of the
/// surface: a tasks-only card in the workspace you work through tasks in is exactly where you most need
/// to be able to write down what you did.
///
/// **Kept on the node, in the file**, which is the bargain `CanvasCardZoom`, `CanvasCardSession` and
/// `CanvasCardMedia` all made before it, in the same words: this is something you *set*, and a card
/// that forgot it every time the window closed would be worse than not offering the choice. It is a
/// fact about a card rather than about a machine, it is a list of words rather than anything private,
/// and a board opened in Obsidian carrying it is a feature.
struct CanvasCardShows: Equatable {
    /// The three things a card can be made of. A card must draw at least one of them, or it is a
    /// rectangle with a title on it.
    ///
    /// Sessions are *two* parts and not one, because the two are read for different reasons: the prose
    /// is what happened, and the tasks are what is left. A card of one without the other is a thing
    /// people actually want, and it is most of what this setting is for.
    enum Part: String, CaseIterable {
        /// The summary, problem, goals, approach, links and learnings — the brief.
        case brief
        /// What was written in each session.
        case notes
        /// The checkboxes.
        case tasks

        /// What the menu calls it. Here rather than in the menu, so the word a card is set by and the
        /// word written into the file cannot drift apart.
        var title: String {
            switch self {
            case .brief: return "Brief"
            case .notes: return "Notes"
            case .tasks: return "Tasks"
            }
        }
    }

    var brief = true
    var notes = true
    var tasks = true
    /// Whether finished tasks are drawn beside the open ones. Independent of `tasks` in the same way
    /// the window's Incomplete filter is independent of having a task list at all.
    var completed = true
    /// Only the most recent sitting, rather than the whole history. The narrowing you reach for when a
    /// card is answering "where is this now", which is most of the time on a board.
    var latestOnly = false

    /// A card nobody has narrowed: the whole document, which is what every project card drew before
    /// this existed and what a new one still draws.
    static let everything = CanvasCardShows()

    func shows(_ part: Part) -> Bool {
        switch part {
        case .brief: return brief
        case .notes: return notes
        case .tasks: return tasks
        }
    }

    /// This card with `part` on or off — or **nil when that would leave it showing nothing**, which is
    /// the one arrangement of these five flags that is not a view of a project.
    ///
    /// Refused here rather than in the menu, so the rule has one home and the menu can *ask* about it:
    /// an item that would refuse is dimmed, which is better than a click that silently does nothing.
    func setting(_ part: Part, to on: Bool) -> CanvasCardShows? {
        var out = self
        switch part {
        case .brief: out.brief = on
        case .notes: out.notes = on
        case .tasks: out.tasks = on
        }
        return out.isEmpty ? nil : out
    }

    /// Nothing to draw but the title.
    var isEmpty: Bool { !brief && !notes && !tasks }

    // MARK: On the node

    /// The key PM writes. Prefixed, because a `.canvas` is a shared document.
    static let key = "pmShows"

    /// What this card shows, as the file says — or everything, which is both the default and what a
    /// list PM cannot make sense of falls back to.
    ///
    /// The fallback is deliberate and it is not "trust the file": a `.canvas` is hand-editable and
    /// syncs between machines, so `pmShows: "task"` is a typo somebody will make, and the honest
    /// recovery from "this names no part of a project" is to show the project rather than a blank
    /// rectangle nobody can work out how to fix.
    static func of(_ node: CanvasNode) -> CanvasCardShows {
        guard case .string(let raw)? = node.extra[key] else { return everything }
        return parse(raw)
    }

    static func parse(_ raw: String) -> CanvasCardShows {
        let tokens = Set(raw.lowercased()
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty })
        var out = CanvasCardShows(brief: tokens.contains(Part.brief.rawValue),
                                  notes: tokens.contains(Part.notes.rawValue),
                                  tasks: tokens.contains(Part.tasks.rawValue),
                                  completed: tokens.contains(completedToken),
                                  latestOnly: tokens.contains(latestToken))
        if out.isEmpty { out = everything }
        return out
    }

    /// Put this on a card — as the absence of the key when it is showing everything, so a card narrowed
    /// and widened again leaves the file exactly as it found it.
    static func set(_ shows: CanvasCardShows, on node: inout CanvasNode) {
        node.extra[key] = shows == everything ? nil : .string(shows.written)
    }

    /// The tokens, in a fixed order, so a card written twice with the same setting produces the same
    /// bytes and a `.canvas` under git does not churn.
    var written: String {
        var tokens: [String] = []
        for part in Part.allCases where shows(part) { tokens.append(part.rawValue) }
        if completed { tokens.append(Self.completedToken) }
        if latestOnly { tokens.append(Self.latestToken) }
        return tokens.joined(separator: ",")
    }

    private static let completedToken = "completed"
    private static let latestToken = "latest"
}
