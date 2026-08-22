import Foundation
import PmLib

// MARK: - `pm mcp`
//
// The stdio adapter: JSON-RPC on stdin and stdout, speaking MCP. Like `pm api`, it is transport and
// nothing else — the tool list is generated from `ApiRegistry` at startup, so a tool cannot describe
// itself differently from the action it calls, because there is only one description.
//
// It lives in the `pm` binary rather than a separate npm package so that wiring it up is a line of
// config against a command the user already has, with no second runtime to install and no second
// thing to keep at the same version as the first.

/// MCP revisions this speaks. A client asking for one of these gets it back; anything else is
/// answered with the newest we know, which is what the spec asks for.
private let supportedProtocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

/// Actions that lose something a person might want back. Held behind their own flag so that granting
/// a model the ability to tick tasks off doesn't also grant it the ability to delete them.
private let destructiveActions: Set<String> = [
    "task.delete", "session.delete", "project.archive", "config.set",
]

// MARK: - Tool names
//
// Actions are namespaced with dots; MCP tool names are conventionally `[a-zA-Z0-9_-]`, and clients
// do reject what falls outside it. The mapping is mechanical and total in both directions, since an
// action name is dotted lowercase and never contains an underscore of its own.

private func toolName(for action: String) -> String {
    action.replacingOccurrences(of: ".", with: "_")
}

private func actionName(for tool: String) -> String {
    tool.replacingOccurrences(of: "_", with: ".")
}

// MARK: - Generating the tool list

/// The schema a model sees, which is the published one with two changes.
///
/// Every task reference is required to carry its `digest`. The field is optional in the contract
/// because a human typing indices at a terminal is asserting nothing — but a model is exactly the
/// caller that reads a list, thinks, and acts later, and by then the position may mean another task.
/// Same dispatcher, stricter published schema.
///
/// Mutations also gain `dryRun`, because the envelope a dry run returns is identical to the one the
/// write returns, so a model can see what it is about to do and then decide.
private func toolSchema(for spec: ApiActionSpec) -> JSONValue {
    guard var schema = spec.inputSchema.objectValue,
          var properties = schema["properties"]?.objectValue else { return spec.inputSchema }

    for (name, value) in properties {
        guard var field = value.objectValue, field["type"]?.stringValue == "object",
              field["properties"]?.objectValue?["digest"] != nil else { continue }
        field["required"] = .array([.string("line"), .string("digest")])
        properties[name] = .object(field)
    }
    if spec.tier == .mutation {
        properties["dryRun"] = .object([
            "type": .string("boolean"),
            "description": .string("Report what this would do, without writing. The result is identical to the real call's."),
        ])
    }
    schema["properties"] = .object(properties)
    return .object(schema)
}

/// What a model is told a tool is for.
///
/// The action's own summary, plus the two things it can't infer: where a task reference comes from,
/// and that the write it is about to make is to a file a person is also editing.
private func toolDescription(for spec: ApiActionSpec) -> String {
    var text = spec.summary
    if spec.fields.contains(where: { $0.kind == .taskRef }) {
        text += " Task references come from task_list or notes_get — pass the task's session, line and digest back exactly as they were given to you."
    }
    if spec.tier == .mutation {
        text += " Writes to the user's notes file. Call with dryRun to see the effect first."
    }
    return text
}

private func tools(allowWrite: Bool, allowDestructive: Bool) -> [ApiActionSpec] {
    ApiRegistry.actions.filter { spec in
        switch spec.tier {
        case .query: return true
        case .mutation:
            guard allowWrite else { return false }
            return allowDestructive || !destructiveActions.contains(spec.name)
        case .affordance:
            // A request to a running app, which this adapter can't make. The contract says so and
            // the dispatcher would refuse anyway; not listing it saves a model discovering that.
            return false
        }
    }
}

// MARK: - JSON-RPC

private func write(_ message: JSONValue) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    guard let data = try? encoder.encode(message), let line = String(data: data, encoding: .utf8) else { return }
    print(line)
    fflush(stdout)
}

private func result(_ id: JSONValue, _ value: JSONValue) {
    write(.object(["jsonrpc": .string("2.0"), "id": id, "result": value]))
}

private func failure(_ id: JSONValue, _ code: Int, _ message: String) {
    write(.object(["jsonrpc": .string("2.0"), "id": id,
                   "error": .object(["code": .number(Double(code)), "message": .string(message)])]))
}

/// A tool's failure is content with `isError`, not a JSON-RPC error: the call reached the tool and
/// the tool refused, which is something the model should see and act on rather than a transport
/// fault it can do nothing about.
private func toolFailure(_ id: JSONValue, _ text: String) {
    result(id, .object([
        "content": .array([.object(["type": .string("text"), "text": .string(text)])]),
        "isError": .bool(true),
    ]))
}

private func toolText(_ id: JSONValue, _ text: String) {
    result(id, .object([
        "content": .array([.object(["type": .string("text"), "text": .string(text)])]),
    ]))
}

// MARK: - Handling

private func handleToolCall(id: JSONValue, params: JSONValue?, allowed: [ApiActionSpec]) {
    guard let object = params?.objectValue, let name = object["name"]?.stringValue else {
        return failure(id, -32602, "tools/call needs a tool name.")
    }
    let action = actionName(for: name)
    guard allowed.contains(where: { $0.name == action }) else {
        let reason = ApiRegistry.spec(action) == nil
            ? "No such tool: \(name)."
            : "\(name) isn't available in this session. It was started without the flag that permits it."
        return toolFailure(id, reason)
    }

    let arguments = object["arguments"] ?? .object([:])
    let dryRun = arguments.objectValue?["dryRun"]?.boolValue ?? false
    let input: ApiInput
    do {
        // Decode through the contract's own type, so a field the action doesn't have is ignored the
        // same way it is for every other adapter.
        let data = try JSONEncoder().encode(arguments)
        input = try JSONDecoder().decode(ApiInput.self, from: data)
    } catch {
        return toolFailure(id, "Those arguments don't fit \(name): \(error.localizedDescription)")
    }

    // The schema says a reference must carry its digest; saying so and not checking would leave the
    // promise to whichever client happens to validate. A model that has read the list has the digest
    // in front of it, so asking for it costs nothing and is worth a great deal when it hasn't.
    for (field, given) in [("task", input.task), ("anchor", input.anchor)] {
        guard let given, given.digest?.isEmpty != false else { continue }
        return toolFailure(id, "missingField: \(field) needs the task's digest. "
                           + "Call task_list or notes_get and pass that task's session, line and digest back.")
    }

    do {
        let outcome = try performApi(action, input, options: ApiOptions(dryRun: dryRun))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let envelope = (try? encoder.encode(JSONValue.encoding(outcome)))
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        toolText(id, "\(outcome.summary)\n\n\(envelope)")
    } catch {
        let apiError = ApiError.from(error)
        // The code matters more than the sentence: a stale reference means read again and retry,
        // which is a different move from a project that doesn't exist.
        toolFailure(id, "\(apiError.code.rawValue): \(apiError.message)")
    }
}

private func handle(_ message: JSONValue, allowed: [ApiActionSpec]) {
    guard let object = message.objectValue, let method = object["method"]?.stringValue else { return }
    // No id means a notification: acknowledge by doing the work and saying nothing.
    guard let id = object["id"], id != .null else { return }

    switch method {
    case "initialize":
        let asked = object["params"]?.objectValue?["protocolVersion"]?.stringValue
        let version = supportedProtocolVersions.contains(asked ?? "") ? asked! : supportedProtocolVersions[0]
        result(id, .object([
            "protocolVersion": .string(version),
            "capabilities": .object(["tools": .object(["listChanged": .bool(false)])]),
            "serverInfo": .object(["name": .string("pm"), "version": .string(pmVersion)]),
            "instructions": .string(
                "PM keeps each project's tasks in a markdown file the user also edits by hand. "
                + "Read with task_list or notes_get before acting, and pass task references back "
                + "exactly as given — they carry a digest that proves the task hasn't changed since "
                + "you read it. A staleReference means read again rather than retrying."),
        ]))
    case "ping":
        result(id, .object([:]))
    case "tools/list":
        result(id, .object(["tools": .array(allowed.map { spec in
            .object([
                "name": .string(toolName(for: spec.name)),
                "description": .string(toolDescription(for: spec)),
                "inputSchema": toolSchema(for: spec),
            ])
        })]))
    case "tools/call":
        handleToolCall(id: id, params: object["params"], allowed: allowed)
    case "resources/list":
        result(id, .object(["resources": .array([])]))
    case "prompts/list":
        result(id, .object(["prompts": .array([])]))
    default:
        failure(id, -32601, "Unsupported method: \(method)")
    }
}

// MARK: - Entry

func runMcp(args: [String]) {
    if args.contains("--help") || args.contains("-h") {
        stderr("""
        Usage: pm mcp [--allow-write] [--allow-destructive]

        Speaks MCP over stdin/stdout. Queries are always available; --allow-write adds the actions
        that change a project, and --allow-destructive adds the ones that lose something
        (\(destructiveActions.sorted().joined(separator: ", "))).

        In an MCP client's config: {"command": "pm", "args": ["mcp", "--allow-write"]}
        """)
        exit(0)
    }
    let allowWrite = args.contains("--allow-write")
    let allowDestructive = args.contains("--allow-destructive")
    let allowed = tools(allowWrite: allowWrite, allowDestructive: allowDestructive)

    // stderr, because stdout is the protocol.
    stderr("pm mcp: \(allowed.count) tools"
           + (allowWrite ? "" : " (queries only — pass --allow-write to change anything)"))

    while let line = readLine(strippingNewline: true) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { continue }
        guard let message = try? JSONDecoder().decode(JSONValue.self, from: Data(trimmed.utf8)) else {
            failure(.null, -32700, "Couldn't parse that as JSON.")
            continue
        }
        handle(message, allowed: allowed)
    }
}
