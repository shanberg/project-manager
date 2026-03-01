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

    public init(text: String, checked: Bool, rawLine: String, context: String, depth: Int = 0, sessionIndex: Int = 0, lineIndex: Int = 0, isFocused: Bool = false) {
        self.text = text
        self.checked = checked
        self.rawLine = rawLine
        self.context = context
        self.depth = depth
        self.sessionIndex = sessionIndex
        self.lineIndex = lineIndex
        self.isFocused = isFocused
    }
}

/// JSON output for `pm notes show` (notes + precomputed todos)
public struct NotesShowOutput: Codable {
    public var notes: ProjectNotes
    public var todos: [Todo]
    /// Key of the focused todo, if any: "sessionIndex:lineIndex" for stable identity.
    public var focusedKey: String?

    public init(notes: ProjectNotes, todos: [Todo], focusedKey: String? = nil) {
        self.notes = notes
        self.todos = todos
        self.focusedKey = focusedKey
    }
}
