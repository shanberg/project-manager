import Foundation

// MARK: - JSON
//
// The contract's boundary is JSON, but its callers aren't all remote: the panel and App Intents link
// PmLib and want native types. `JSONValue` is what lets one dispatcher serve both — a query builds a
// value, and the in-process adapter reads it directly while the CLI and MCP adapters encode it.

/// A JSON value, for the parts of the contract whose shape depends on the action.
public enum JSONValue: Codable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let v = try? c.decode(Bool.self) { self = .bool(v); return }
        if let v = try? c.decode(Double.self) { self = .number(v); return }
        if let v = try? c.decode(String.self) { self = .string(v); return }
        if let v = try? c.decode([JSONValue].self) { self = .array(v); return }
        if let v = try? c.decode([String: JSONValue].self) { self = .object(v); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "unsupported JSON value")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }

    /// Wrap any `Encodable` — how a query turns its own result type into contract output without a
    /// second, hand-written description of the same shape.
    public static func encoding<T: Encodable>(_ value: T) throws -> JSONValue {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    public var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    public var intValue: Int? { if case .number(let n) = self { return Int(n) }; return nil }
    public var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var objectValue: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }
    public var arrayValue: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
}

// MARK: - Input

/// A task address as it arrives over the wire. Mirrors `TaskRef`, kept separate so the contract's
/// spelling can stay stable while the internal type is free to change.
public struct TaskRefInput: Codable, Equatable {
    public var session: String?
    public var sessionOrdinal: Int?
    public var line: Int
    public var digest: String?

    public init(session: String? = nil, sessionOrdinal: Int? = nil, line: Int, digest: String? = nil) {
        self.session = session
        self.sessionOrdinal = sessionOrdinal
        self.line = line
        self.digest = digest
    }

    /// `session` is documented as a string, and is one either way — but a caller that reads
    /// "session index" and sends the number 0 has said something unambiguous, and refusing it on a
    /// type would be pedantry rather than safety.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let text = try? c.decode(String.self, forKey: .session) {
            session = text
        } else if let number = try? c.decode(Int.self, forKey: .session) {
            session = String(number)
        } else {
            session = nil
        }
        sessionOrdinal = try c.decodeIfPresent(Int.self, forKey: .sessionOrdinal)
        line = try c.decode(Int.self, forKey: .line)
        digest = try c.decodeIfPresent(String.self, forKey: .digest)
    }

    /// `session` is an ISO date or a session index, the same either-or the CLI accepts.
    public var ref: TaskRef {
        if let session, Int(session) == nil {
            return TaskRef(sessionDate: session, sessionOrdinal: sessionOrdinal ?? 0,
                           lineIndex: line, digest: digest)
        }
        return TaskRef(sessionIndex: session.flatMap(Int.init) ?? 0, lineIndex: line, digest: digest)
    }
}

/// Every action's input, in one shape.
///
/// One struct rather than a type per action, because the manifest already says which fields each
/// action takes and which are required — and validating against that same table is what keeps the
/// published schema and the actual check from ever disagreeing. A per-action type would be a second
/// description of the same thing, maintained by hand beside the first.
public struct ApiInput: Codable, Equatable {
    public var project: String?
    public var task: TaskRefInput?
    /// Several tasks, for the actions that can act on a selection in one write.
    public var tasks: [TaskRefInput]?
    /// The document the caller was looking at, from a read's `revision`.
    ///
    /// A digest says "this task is still the task I saw"; it says nothing about the tasks around it.
    /// A batch needs the stronger claim, because acting on a selection assembled from an earlier read
    /// only makes sense if the document is still that document.
    public var revision: String?
    public var anchor: TaskRefInput?
    public var position: String?
    public var session: String?
    public var sessionOrdinal: Int?
    public var text: String?
    public var due: String?
    public var clearDue: Bool?
    public var advanceFocus: Bool?
    public var label: String?
    public var prose: String?
    public var title: String?
    public var domain: String?
    public var scope: String?
    public var key: String?
    public var value: JSONValue?
    public var includeCompleted: Bool?
    public var limit: Int?
    public var now: String?
    /// A journal entry's id.
    public var entry: String?

    public init() {}
}

/// Options that apply to any action, kept out of `ApiInput` so an action's fields are exactly its own.
public struct ApiOptions: Equatable {
    /// Run the action and report what it would do, without writing.
    public var dryRun: Bool
    /// Which adapter is calling — "cli", "mcp", "app", "raycast". Recorded in the journal, so that
    /// "what did the model change?" is a question with an answer.
    public var source: String
    public init(dryRun: Bool = false, source: String = "api") {
        self.dryRun = dryRun
        self.source = source
    }
}

// MARK: - Result

/// One task the action touched.
public struct ApiChange: Codable, Equatable {
    public enum Kind: String, Codable {
        case added, removed, completed, reopened, retimed, renamed, moved, focused, unfocused
    }
    public var kind: Kind
    public var ref: TaskRefInput?
    public var was: String?
    public var now: String?

    public init(kind: Kind, ref: TaskRefInput?, was: String? = nil, now: String? = nil) {
        self.kind = kind
        self.ref = ref
        self.was = was
        self.now = now
    }
}

/// What every action returns.
///
/// The same envelope for a mutation, a query and a dry run. `summary` is the sentence a surface shows
/// — the panel's receipt line, Raycast's HUD, what a model reads back — and `changed` is what a UI
/// draws. `dryRun` fills both without writing, which is how a caller can show a change before
/// committing to it.
public struct ApiResult: Codable, Equatable {
    public var action: String
    public var summary: String
    /// mtime and content hash of the notes file after the action; nil for actions with no document.
    public var revision: String?
    public var changed: [ApiChange]
    /// Where the focused task ended up, when the action moved it.
    public var focus: TaskRefInput?
    /// True when a task reference had to be healed against a document that moved under the caller.
    public var relocated: Bool
    public var dryRun: Bool
    /// A query's payload.
    public var data: JSONValue?

    public init(action: String, summary: String, revision: String? = nil, changed: [ApiChange] = [],
                focus: TaskRefInput? = nil, relocated: Bool = false, dryRun: Bool = false,
                data: JSONValue? = nil) {
        self.action = action
        self.summary = summary
        self.revision = revision
        self.changed = changed
        self.focus = focus
        self.relocated = relocated
        self.dryRun = dryRun
        self.data = data
    }
}

// MARK: - Errors

/// A refusal with a code a client can branch on, rather than a sentence it has to read.
public struct ApiError: Error, Codable, Equatable {
    public enum Code: String, Codable {
        case unknownAction
        case unsupportedAction
        case missingField
        case invalidField
        case projectNotFound
        case ambiguousProject
        case notesNotFound
        case staleReference
        case invalidDue
        case emptyText
        case configNotFound
        /// The document moved since the read this action was based on — used when reversing a write
        /// that is no longer the newest thing to have happened to the file.
        case conflict
        case writeFailed
    }
    public var code: Code
    public var message: String
    /// The candidates for an ambiguous project, the field name for a bad field — whatever the client
    /// needs to recover without asking a human to read prose.
    public var detail: JSONValue?

    public init(_ code: Code, _ message: String, detail: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.detail = detail
    }

    /// Map the errors the domain already throws onto the published set, so one refusal vocabulary
    /// covers both the contract's own checks and everything underneath it.
    public static func from(_ error: Error) -> ApiError {
        if let api = error as? ApiError { return api }
        guard let pm = error as? PmError else {
            return ApiError(.writeFailed, error.localizedDescription)
        }
        switch pm {
        case .projectNotFound(let q): return ApiError(.projectNotFound, pm.description, detail: .string(q))
        case .ambiguousProject(let q): return ApiError(.ambiguousProject, pm.description, detail: .string(q))
        case .emptyProjectQuery: return ApiError(.missingField, pm.description, detail: .string("project"))
        case .notesNotFound: return ApiError(.notesNotFound, pm.description)
        case .staleReference: return ApiError(.staleReference, pm.description)
        case .invalidTodoDue(let v): return ApiError(.invalidDue, pm.description, detail: .string(v))
        case .emptyTodoText, .emptySessionNote: return ApiError(.emptyText, pm.description)
        case .configNotFound, .configMissingPaths: return ApiError(.configNotFound, pm.description)
        default: return ApiError(.writeFailed, pm.description)
        }
    }
}
