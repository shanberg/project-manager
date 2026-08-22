import Foundation

public struct LinkEntry: Codable, Equatable {
    public var label: String?
    public var url: String?
    public var children: [LinkEntry]?

    public init(label: String? = nil, url: String? = nil, children: [LinkEntry]? = nil) {
        self.label = label
        self.url = url
        self.children = children
    }
}

public struct Session: Codable, Equatable {
    public var date: String
    public var label: String
    public var body: String

    public init(date: String, label: String, body: String) {
        self.date = date
        self.label = label
        self.body = body
    }
}

public struct ProjectNotes: Codable, Equatable {
    public var title: String
    public var summary: String
    public var problem: String
    public var goals: [String]
    public var approach: String
    public var links: [LinkEntry]
    public var learnings: [String]
    public var sessions: [Session]

    public init(title: String, summary: String = "", problem: String = "", goals: [String] = ["", "", ""], approach: String = "", links: [LinkEntry] = [LinkEntry(label: nil, url: nil)], learnings: [String] = [""], sessions: [Session] = []) {
        self.title = title
        self.summary = summary
        self.problem = problem
        self.goals = goals
        self.approach = approach
        self.links = links
        self.learnings = learnings
        self.sessions = sessions
    }
}

public struct Todo: Codable, Equatable {
    public var text: String
    public var checked: Bool
    public var rawLine: String
    public var context: String
    /// Indent depth: 0 = root, 1 = one level in (2 spaces), etc. Derived from leading spaces before "- ".
    public var depth: Int
    /// Index of the session in notes.sessions.
    public var sessionIndex: Int
    /// Index of the task line within that session's body (by line order).
    public var lineIndex: Int
    /// True if this task line ends with " @" (the single focused item in the notes file).
    public var isFocused: Bool
    /// Parsed from inline `due: <date>` at end of task line. Stored as-is for display.
    public var dueDate: String?
    /// Effective due date for display: own dueDate if set, else earliest due among ancestors (nearest deadline). Not stored in notes; computed when producing notes show output.
    public var effectiveDueDate: String?
    /// `taskDigest` of `text` — what a caller sends back to prove it still means this task.
    public var digest: String?
    /// The ISO date of this task's session, the stable half of a `TaskRef` coordinate.
    public var sessionISODate: String?

    public init(text: String, checked: Bool, rawLine: String, context: String, depth: Int = 0, sessionIndex: Int = 0, lineIndex: Int = 0, isFocused: Bool = false, dueDate: String? = nil, effectiveDueDate: String? = nil, digest: String? = nil, sessionISODate: String? = nil) {
        self.text = text
        self.checked = checked
        self.rawLine = rawLine
        self.context = context
        self.depth = depth
        self.sessionIndex = sessionIndex
        self.lineIndex = lineIndex
        self.isFocused = isFocused
        self.dueDate = dueDate
        self.effectiveDueDate = effectiveDueDate
        self.digest = digest
        self.sessionISODate = sessionISODate
    }
}

/// JSON output for `pm notes show` (notes + precomputed todos)
public struct NotesShowOutput: Codable {
    public var notes: ProjectNotes
    public var todos: [Todo]
    /// Key of the focused todo, if any: "sessionIndex:lineIndex" for stable identity.
    public var focusedKey: String?
    /// The revision of the exact bytes these tasks were parsed from — the token a write sends back to
    /// say "this is the document I was looking at". It rides *in* the payload rather than beside it so
    /// a caller that holds onto a read holds onto the revision too; a revision kept in a separate
    /// variable from the tasks it describes is a pair that can drift, and the whole point of it is
    /// that it can't. See docs/api-contract.md.
    public var revision: String

    public init(notes: ProjectNotes, todos: [Todo], focusedKey: String? = nil, revision: String) {
        self.notes = notes
        self.todos = todos
        self.focusedKey = focusedKey
        self.revision = revision
    }
}
