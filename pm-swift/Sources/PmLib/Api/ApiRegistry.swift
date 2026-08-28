import Foundation

// MARK: - The action table
//
// One table describing every action: what it's called, which tier it belongs to, and what it takes.
// The published JSON Schema is generated from it and so is the validation that runs before an action
// executes, which is the point — a schema maintained beside the check it describes is a schema that
// eventually disagrees with it. `pm api describe` is this table, encoded.

/// What kind of thing an action is, which decides which adapters get to publish it.
public enum ApiTier: String, Codable, CaseIterable {
    /// Changes the project. Published everywhere.
    case mutation
    /// Reads. No side effects. Published everywhere.
    case query
    /// A request to a running app — open a window, reveal a folder. Meaningless headless, so the
    /// stdio and argv adapters list it and refuse it; only the in-process and URL adapters do it.
    case affordance
}

public struct ApiField: Equatable {
    public enum Kind: String, Equatable {
        case string, integer, boolean, taskRef, taskRefList, any
    }
    public let name: String
    public let kind: Kind
    public let required: Bool
    public let description: String
    public let allowed: [String]?
    /// The smallest value an integer field accepts. Published *and* enforced, like `allowed` and
    /// `required` — an unchecked integer reaches `prefix`/`suffix` and traps the process, which for
    /// `pm mcp` means the server dies mid-session rather than refusing one call.
    public let minimum: Int?

    init(_ name: String, _ kind: Kind, required: Bool = false, _ description: String,
         allowed: [String]? = nil, minimum: Int? = nil) {
        self.name = name
        self.kind = kind
        self.required = required
        self.description = description
        self.allowed = allowed
        self.minimum = minimum
    }
}

public struct ApiActionSpec: Equatable {
    public let name: String
    public let tier: ApiTier
    public let summary: String
    public let fields: [ApiField]
    /// Groups of fields, of each of which exactly one must be given — `task` or `tasks` for the
    /// actions that take either, `due` or `clearDue` for the one that both sets and clears. A plain
    /// `required` list can't say "one of these", and an action that quietly accepted both would have
    /// to invent a rule about which wins. More than one group because `task.setDue` needs two, and an
    /// action that could only express one would have had to leave the second unchecked.
    public let oneOf: [[String]]

    init(name: String, tier: ApiTier, summary: String, fields: [ApiField], oneOf: [[String]] = []) {
        self.name = name
        self.tier = tier
        self.summary = summary
        self.fields = fields
        self.oneOf = oneOf
    }
}

private let tasks = ApiField("tasks", .taskRefList,
                             "Several tasks, acted on in one write. Give this or `task`, not both.")
private let revision = ApiField("revision", .string,
                                "The `revision` from the read this came from. When given, the write "
                                + "happens only if the document is still that one.")

/// The contract version. Clients assert a minimum against this and say "update pm" in one place,
/// rather than each discovering an older binary by having a call fail oddly.
public let apiContractVersion = "1.5.0"

private let project = ApiField("project", .string, required: true,
                               "Project name or unambiguous prefix.")
private let optionalProject = ApiField("project", .string,
                                       "Project name or prefix. Defaults to the focused project.")
private let task = ApiField("task", .taskRef, required: true, "The task to act on.")
private let optionalTask = ApiField("task", .taskRef, "The task to act on. Give this or `tasks`, not both.")

public enum ApiRegistry {
    public static let actions: [ApiActionSpec] = [
        // MARK: Tasks
        ApiActionSpec(name: "task.add", tier: .mutation,
                      summary: "Add a task, to the current session or beside an existing task.",
                      fields: [project,
                               ApiField("text", .string, required: true, "The task's text."),
                               ApiField("due", .string, "Due date, YYYY-MM-DD."),
                               ApiField("anchor", .taskRef, "Insert relative to this task instead of appending to the current session."),
                               ApiField("position", .string, "Where the new task goes relative to the anchor.",
                                        allowed: ["before", "after", "child"])]),
        ApiActionSpec(name: "task.complete", tier: .mutation,
                      summary: "Complete a task, or several, along with their subtrees.",
                      fields: [project, optionalTask, tasks, revision,
                               ApiField("advanceFocus", .boolean, "Move focus onward afterwards. Default true.")],
                      oneOf: [["task", "tasks"]]),
        ApiActionSpec(name: "task.reopen", tier: .mutation,
                      summary: "Re-open a completed task, or several, and put focus back.",
                      fields: [project, optionalTask, tasks, revision],
                      oneOf: [["task", "tasks"]]),
        ApiActionSpec(name: "task.focus", tier: .mutation,
                      summary: "Make this the project's focused task.",
                      fields: [project, task]),
        ApiActionSpec(name: "task.diveIn", tier: .mutation,
                      summary: "Move focus to the first open leaf under the focused task.",
                      fields: [project]),
        ApiActionSpec(name: "task.setDue", tier: .mutation,
                      summary: "Set or clear the due date on a task, or on several.",
                      fields: [project, optionalTask, tasks, revision,
                               ApiField("due", .string, "Due date, YYYY-MM-DD."),
                               ApiField("clearDue", .boolean, "Remove the due date instead of setting one.")],
                      // Both pairs, because omitting `due` used to mean "clear it" — so a caller that
                      // meant to set a date and left the field out silently lost the one already there.
                      oneOf: [["task", "tasks"], ["due", "clearDue"]]),
        ApiActionSpec(name: "task.setWaiting", tier: .mutation,
                      summary: "Set or clear what a task is waiting on, or do it to several.",
                      fields: [project, optionalTask, tasks, revision,
                               ApiField("waiting", .string,
                                        "What it's waiting on: a project, an area, or a person's name."),
                               ApiField("clearWaiting", .boolean,
                                        "Remove the wait instead of setting one.")],
                      // Both pairs, for the reason `task.setDue` needs both: a caller that meant to
                      // set a target and left the field out would otherwise silently clear the one
                      // already there.
                      oneOf: [["task", "tasks"], ["waiting", "clearWaiting"]]),
        ApiActionSpec(name: "task.setText", tier: .mutation,
                      summary: "Rename a task in place.",
                      fields: [project, task,
                               ApiField("text", .string, required: true, "The new text.")]),
        ApiActionSpec(name: "task.wrap", tier: .mutation,
                      summary: "Wrap a task and its subtree in a new parent task.",
                      fields: [project, task,
                               ApiField("text", .string, required: true, "The new parent's text.")]),
        ApiActionSpec(name: "task.unwrap", tier: .mutation,
                      summary: "Dissolve a parent task, promoting its children.",
                      fields: [project, task]),
        ApiActionSpec(name: "task.delete", tier: .mutation,
                      summary: "Delete a task, or several, along with their subtrees.",
                      fields: [project, optionalTask, tasks, revision],
                      oneOf: [["task", "tasks"]]),

        // MARK: Sessions
        ApiActionSpec(name: "session.start", tier: .mutation,
                      summary: "Start a session, unless the current one is still open.",
                      fields: [project, ApiField("label", .string, "Optional label for the session.")]),
        ApiActionSpec(name: "session.note", tier: .mutation,
                      summary: "Append a note to the current session, starting one if needed.",
                      fields: [project, ApiField("prose", .string, required: true, "The note.")]),
        ApiActionSpec(name: "session.rename", tier: .mutation,
                      summary: "Change a session's label. Its date is preserved.",
                      fields: [project,
                               ApiField("session", .string, required: true, "Session ISO date or index."),
                               ApiField("sessionOrdinal", .integer, "Which session of that date. Default 0.", minimum: 0),
                               ApiField("sessionDigest", .string, "Digest of the label you read, to catch a session that has since changed."),
                               ApiField("label", .string, required: true, "The new label.")]),
        ApiActionSpec(name: "session.delete", tier: .mutation,
                      summary: "Delete a session that has no tasks in it.",
                      fields: [project,
                               ApiField("session", .string, required: true, "Session ISO date or index."),
                               ApiField("sessionOrdinal", .integer, "Which session of that date. Default 0.", minimum: 0),
                               ApiField("sessionDigest", .string, "Digest of the label you read, to catch a session that has since changed.")]),

        // MARK: Notes
        ApiActionSpec(name: "notes.setDetail", tier: .mutation,
                      summary: "Replace one of the project's detail sections.",
                      fields: [project,
                               ApiField("key", .string, required: true, "Which section.",
                                        allowed: ["title", "summary", "problem", "approach", "goals", "learnings"]),
                               ApiField("value", .any, required: true,
                                        "A string, or an array of strings for goals and learnings.")]),
        ApiActionSpec(name: "notes.addLink", tier: .mutation,
                      summary: "Add a link to the project's links section.",
                      fields: [project,
                               ApiField("text", .string, required: true, "The URL."),
                               ApiField("label", .string, "Link label.")]),

        // MARK: Projects
        ApiActionSpec(name: "project.create", tier: .mutation,
                      summary: "Create a project, numbered within its domain, or an unnumbered area.",
                      fields: [ApiField("title", .string, required: true, "Project or area title."),
                               ApiField("kind", .string, "What to make. Default project.",
                                        allowed: ProjectKind.allCases.map(\.rawValue)),
                               ApiField("domain", .string, "Domain code, e.g. W. Required for a project, refused for an area.")]),
        ApiActionSpec(name: "project.adopt", tier: .mutation,
                      summary: "Take an existing folder in the areas root on as an area, by writing notes into it.",
                      fields: [ApiField("folder", .string, required: true,
                                        "The folder's name, as `project.adoptable` lists it.")]),
        ApiActionSpec(name: "project.rename", tier: .mutation,
                      summary: "Rename a project, keeping its domain and number.",
                      fields: [project, ApiField("title", .string, required: true, "The new title.")]),
        ApiActionSpec(name: "project.archive", tier: .mutation,
                      summary: "Move a project or area to the archive.", fields: [project]),
        ApiActionSpec(name: "project.unarchive", tier: .mutation,
                      summary: "Move a project or area back out of the archive, to wherever its kind lives.",
                      fields: [project]),
        ApiActionSpec(name: "project.focus", tier: .mutation,
                      summary: "Make this the focused project.", fields: [project]),

        // MARK: Queries
        ApiActionSpec(name: "project.list", tier: .query,
                      summary: "Every project and area, each with its kind.",
                      fields: [ApiField("scope", .string, "Which folder to list. Default active.",
                                        allowed: ["active", "areas", "archive", "all"]),
                               ApiField("kind", .string, "Only this kind. Default both.",
                                        allowed: ProjectKind.allCases.map(\.rawValue))]),
        ApiActionSpec(name: "project.adoptable", tier: .query,
                      summary: "Folders in the areas root that could become areas but haven't yet.",
                      fields: []),
        ApiActionSpec(name: "project.get", tier: .query,
                      summary: "One project's paths and domain.", fields: [project]),
        ApiActionSpec(name: "notes.get", tier: .query,
                      summary: "A project's notes, tasks, and focused task.", fields: [project]),
        ApiActionSpec(name: "task.list", tier: .query,
                      summary: "A project's tasks, each with the reference needed to act on it.",
                      fields: [optionalProject,
                               ApiField("includeCompleted", .boolean, "Include completed tasks. Default false."),
                               ApiField("limit", .integer, "Cap the number returned.", minimum: 0)]),
        ApiActionSpec(name: "task.whatsDue", tier: .query,
                      summary: "Open tasks with a due date, soonest first.",
                      fields: [optionalProject, ApiField("limit", .integer, "Cap the number returned.", minimum: 0)]),
        ApiActionSpec(name: "task.progress", tier: .query,
                      summary: "How many of a project's tasks are done.", fields: [optionalProject]),
        ApiActionSpec(name: "focus.get", tier: .query,
                      summary: "The focused project and its focused task.", fields: []),
        ApiActionSpec(name: "config.get", tier: .query, summary: "The pm configuration.", fields: []),
        ApiActionSpec(name: "config.set", tier: .mutation,
                      summary: "Set one configuration key.",
                      fields: [ApiField("key", .string, required: true, "Configuration key."),
                               ApiField("value", .any, required: true, "The new value.")]),

        ApiActionSpec(name: "task.search", tier: .query,
                      summary: "Find open tasks across every project by the words in them.",
                      fields: [ApiField("query", .string, required: true, "Words to look for, in any order."),
                               ApiField("project", .string, "Break ties toward this project. Defaults to the focused one."),
                               ApiField("scope", .string, "Which projects to search. Default all.",
                                        allowed: ["active", "archive", "all"]),
                               ApiField("limit", .integer, "How many to return. Default 20.", minimum: 0)]),
        ApiActionSpec(name: "capture.parse", tier: .query,
                      summary: "Read a typed capture line: its text, its due date, and the project it names.",
                      fields: [ApiField("text", .string, required: true,
                                        "A line as somebody would type it, e.g. \"Email Dana due:friday @redesign\"."),
                               ApiField("now", .string, "Today's date, YYYY-MM-DD. Defaults to today.")]),

        // MARK: Journal
        ApiActionSpec(name: "journal.list", tier: .query,
                      summary: "Recent writes made through the contract, newest first.",
                      fields: [ApiField("project", .string, "Only this project's writes."),
                               ApiField("limit", .integer, "How many entries. Default 50.", minimum: 0)]),
        ApiActionSpec(name: "journal.undo", tier: .mutation,
                      summary: "Reverse a write, if the file is still exactly as that write left it.",
                      fields: [ApiField("entry", .string, "Which entry, from journal.list. Default the most recent reversible one."),
                               ApiField("project", .string, "Only consider this project's writes.")]),

        // MARK: Affordances — listed so the boundary is documented, refused by the headless adapters.
        ApiActionSpec(name: "app.openWindow", tier: .affordance,
                      summary: "Open the project's window in PM.", fields: [optionalProject]),
        ApiActionSpec(name: "app.openInFinder", tier: .affordance,
                      summary: "Reveal the project's folder in Finder.", fields: [optionalProject]),
        ApiActionSpec(name: "app.openInObsidian", tier: .affordance,
                      summary: "Open the project's notes in Obsidian.", fields: [optionalProject]),
        ApiActionSpec(name: "app.showPanel", tier: .affordance,
                      summary: "Show PM's focus panel.", fields: []),
        ApiActionSpec(name: "app.settings", tier: .affordance,
                      summary: "Open PM's settings.", fields: []),
    ]

    public static func spec(_ name: String) -> ApiActionSpec? {
        actions.first { $0.name == name }
    }
}

// MARK: - Schema

extension ApiField {
    /// This field as JSON Schema. The one description of the field's shape, used to publish and to
    /// validate.
    var schema: JSONValue {
        var out: [String: JSONValue] = ["description": .string(description)]
        switch kind {
        case .string: out["type"] = .string("string")
        case .integer: out["type"] = .string("integer")
        case .boolean: out["type"] = .string("boolean")
        case .any: break  // a string, a number, or an array of strings, depending on the key
        case .taskRefList:
            out["type"] = .string("array")
            out["items"] = ApiField("item", .taskRef, description).schema
        case .taskRef:
            out["type"] = .string("object")
            out["required"] = .array([.string("line")])
            out["properties"] = .object([
                "session": .object([
                    "type": .string("string"),
                    "description": .string("The session's ISO date (preferred) or its index."),
                ]),
                "sessionOrdinal": .object([
                    "type": .string("integer"),
                    "minimum": .number(0),
                    "description": .string("Which session of that date, when a project has more than one. Default 0."),
                ]),
                "line": .object([
                    "type": .string("integer"),
                    "minimum": .number(0),
                    "description": .string("The task's ordinal among the task lines of its session."),
                ]),
                "digest": .object([
                    "type": .string("string"),
                    "description": .string("The task's digest, from a read. Proves the reference still names the task you saw."),
                ]),
            ])
        }
        if let allowed { out["enum"] = .array(allowed.map { .string($0) }) }
        if let minimum { out["minimum"] = .number(Double(minimum)) }
        return .object(out)
    }
}

extension ApiActionSpec {
    public var inputSchema: JSONValue {
        var properties: [String: JSONValue] = [:]
        for field in fields { properties[field.name] = field.schema }
        var out: [String: JSONValue] = [
            "type": .string("object"),
            "properties": .object(properties),
        ]
        let required = fields.filter(\.required).map { JSONValue.string($0.name) }
        if !required.isEmpty { out["required"] = .array(required) }
        if !oneOf.isEmpty {
            out["allOf"] = .array(oneOf.map { group in
                .object(["oneOf": .array(group.map { .object(["required": .array([.string($0)])]) })])
            })
        }
        return .object(out)
    }

    var manifestEntry: JSONValue {
        .object([
            "name": .string(name),
            "tier": .string(tier.rawValue),
            "summary": .string(summary),
            "input": inputSchema,
        ])
    }
}

/// The manifest: what a client generates its tool list, its flags, or its typed client from.
///
/// `tiers` names which of them an adapter should publish. A headless adapter takes mutation and
/// query and leaves affordances alone; the panel takes all three.
public func apiManifest() -> JSONValue {
    .object([
        "contractVersion": .string(apiContractVersion),
        "tiers": .object([
            "mutation": .string("Changes the project. Every adapter publishes these."),
            "query": .string("Reads, with no side effects. Every adapter publishes these."),
            "affordance": .string("Requests to a running app. Only the in-process and URL adapters can perform these."),
        ]),
        "actions": .array(ApiRegistry.actions.map(\.manifestEntry)),
    ])
}
