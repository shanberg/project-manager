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

/// Where a task stands: still to do, done, or dropped — closed without being done.
///
/// Dropped exists because an old task you've decided against had two exits and both lied: tick it (it
/// wasn't done) or delete it (it was real, and the prose around it still mentions it). It is written
/// `- [-]`, the Obsidian Tasks plugin's spelling for "cancelled", so the file reads right in a vault
/// that has it. See docs/sessions.md D6.
public enum TaskState: String, Codable, Equatable, Sendable {
    case open, done, dropped

    /// The state a checkbox's one character spells, or nil when it isn't a task box PM reads.
    public init?(box: Character) {
        switch box {
        case " ": self = .open
        case "x", "X": self = .done
        case "-": self = .dropped
        default: return nil
        }
    }

    /// The character PM writes between the brackets. `X` is read as done and never written.
    public var box: Character {
        switch self {
        case .open: return " "
        case .done: return "x"
        case .dropped: return "-"
        }
    }

    /// Done or dropped: out of the way either way. What `Todo.checked` has always meant to every
    /// consumer that hides finished work, which is why dropping a task needed no change from them.
    public var isClosed: Bool { self != .open }
}

public struct Todo: Codable, Equatable {
    public var text: String
    /// Closed — done *or dropped*. Kept under its old name because every surface that filters on it
    /// (hide what's finished, count what's left) wants a dropped task treated exactly the same way.
    /// `state` is the one that tells the two apart.
    public var checked: Bool
    public var state: TaskState
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
    /// Parsed from inline `waiting: [[<target>]]` — the name this task is waiting on. Stored as-is.
    public var waiting: String?
    /// Effective wait for display: own `waiting` if set, else the *nearest* waiting ancestor's. Unlike
    /// a due date, which takes the earliest ancestor's because deadlines compete, a wait is inherited
    /// from whichever ancestor is closest — a subtree under a blocked parent is blocked by that parent,
    /// and a grandparent's older wait doesn't override it. Not stored in notes.
    public var effectiveWaiting: String?
    /// `taskDigest` of `text` — what a caller sends back to prove it still means this task.
    public var digest: String?
    /// The ISO date of this task's session, the stable half of a `TaskRef` coordinate.
    public var sessionISODate: String?
    /// Which of its day's sittings this task's is, counting from the first — the other half of naming a
    /// sitting by date, in a project sat down to twice that day. A reference without it names the first,
    /// and a line there with the same text and number is taken for this one.
    public var sessionOrdinal: Int = 0
    /// The latest sitting this task was picked up into, when it has been (docs/sessions.md D2). Filled
    /// in by a read that knows the project folder, since the picks live beside the notes, not in them.
    public var picked: PickMark?

    /// `state`, when given, wins over `checked`, so the two can't be constructed disagreeing.
    public init(text: String, checked: Bool, state: TaskState? = nil, rawLine: String, context: String, depth: Int = 0, sessionIndex: Int = 0, lineIndex: Int = 0, isFocused: Bool = false, dueDate: String? = nil, effectiveDueDate: String? = nil, waiting: String? = nil, effectiveWaiting: String? = nil, digest: String? = nil, sessionISODate: String? = nil) {
        let state = state ?? (checked ? .done : .open)
        self.text = text
        self.checked = state.isClosed
        self.state = state
        self.rawLine = rawLine
        self.context = context
        self.depth = depth
        self.sessionIndex = sessionIndex
        self.lineIndex = lineIndex
        self.isFocused = isFocused
        self.dueDate = dueDate
        self.effectiveDueDate = effectiveDueDate
        self.waiting = waiting
        self.effectiveWaiting = effectiveWaiting
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
    /// Every pick that still stands and still resolves, oldest first — what a sitting draws as the old
    /// tasks it picked up. Empty for a read made without the project folder to hand.
    public var picks: [TaskPick]

    public init(notes: ProjectNotes, todos: [Todo], focusedKey: String? = nil, revision: String,
                picks: [TaskPick] = []) {
        self.notes = notes
        self.todos = todos
        self.focusedKey = focusedKey
        self.revision = revision
        self.picks = picks
    }
}
