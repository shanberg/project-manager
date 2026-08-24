import XCTest
import Foundation
import PmLib

/// The MCP adapter, driven the way a client drives it: newline-delimited JSON-RPC over stdio.
///
/// What's worth testing here isn't the protocol so much as the two claims the adapter makes — that
/// its tool list is generated from the same registry the dispatcher runs, and that it publishes a
/// stricter schema to a model than the contract requires of a human. See docs/api-contract.md.
final class McpTests: XCTestCase {

    private static var packageRoot: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
    }
    private static var pmBinaryPath: String {
        (packageRoot as NSString).appendingPathComponent(".build/debug/pm")
    }

    private var env: [String: String] = [:]
    private var configDir = ""

    override func setUp() {
        super.setUp()
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: Self.pmBinaryPath) else { return }
        let tmp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        configDir = (tmp as NSString).appendingPathComponent("config")
        let active = (tmp as NSString).appendingPathComponent("active")
        let archive = (tmp as NSString).appendingPathComponent("archive")
        for path in [configDir, active, archive] {
            try? fm.createDirectory(atPath: path, withIntermediateDirectories: true)
        }
        let config: [String: Any] = ["activePath": active, "archivePath": archive,
                                     "domains": ["W": "Work"], "subfolders": ["docs"]]
        try? JSONSerialization.data(withJSONObject: config)
            .write(to: URL(fileURLWithPath: (configDir as NSString).appendingPathComponent("config.json")))
        env = ["PM_CONFIG_HOME": configDir, "PM_ACTIVE_PATH": active, "PM_ARCHIVE_PATH": archive]
    }

    override func tearDown() {
        if !configDir.isEmpty {
            try? FileManager.default.removeItem(atPath: (configDir as NSString).deletingLastPathComponent)
        }
        super.tearDown()
    }

    private var haveBinary: Bool { FileManager.default.isExecutableFile(atPath: Self.pmBinaryPath) }

    private func run(_ args: [String], stdin: String? = nil) -> (out: String, code: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.pmBinaryPath)
        process.arguments = args
        process.environment = ProcessInfo.processInfo.environment.merging(env) { _, e in e }
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        if let stdin {
            let inPipe = Pipe()
            process.standardInput = inPipe
            try? process.run()
            try? inPipe.fileHandleForWriting.write(contentsOf: Data(stdin.utf8))
            try? inPipe.fileHandleForWriting.close()
        } else {
            try? process.run()
        }
        let out = (try? outPipe.fileHandleForReading.readToEnd()) ?? Data()
        _ = try? errPipe.fileHandleForReading.readToEnd()
        process.waitUntilExit()
        return (String(data: out, encoding: .utf8) ?? "", process.terminationStatus)
    }

    /// Send a batch of requests and read the replies in order. The server handles one line at a
    /// time, so a batch and a conversation are the same thing to it.
    private func mcp(_ requests: [[String: Any]], flags: [String] = ["--allow-write"]) -> [[String: Any]] {
        let handshake: [String: Any] = ["jsonrpc": "2.0", "id": 0, "method": "initialize",
                                        "params": ["protocolVersion": "2025-06-18", "capabilities": [:],
                                                   "clientInfo": ["name": "test", "version": "1"]]]
        let lines = ([handshake] + requests).compactMap { request -> String? in
            guard let data = try? JSONSerialization.data(withJSONObject: request) else { return nil }
            return String(data: data, encoding: .utf8)
        }
        let (out, _) = run(["mcp"] + flags, stdin: lines.joined(separator: "\n") + "\n")
        return out.split(separator: "\n").compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
        }
    }

    private func tools(flags: [String] = ["--allow-write"]) -> [[String: Any]] {
        let replies = mcp([["jsonrpc": "2.0", "id": 1, "method": "tools/list"]], flags: flags)
        let result = replies.last?["result"] as? [String: Any]
        return result?["tools"] as? [[String: Any]] ?? []
    }

    private func callResult(_ replies: [[String: Any]]) -> (isError: Bool, text: String) {
        guard let result = replies.last?["result"] as? [String: Any],
              let content = result["content"] as? [[String: Any]],
              let text = content.first?["text"] as? String else { return (true, "") }
        return (result["isError"] as? Bool ?? false, text)
    }

    private func call(_ tool: String, _ arguments: [String: Any],
                      flags: [String] = ["--allow-write"]) -> (isError: Bool, text: String) {
        callResult(mcp([["jsonrpc": "2.0", "id": 1, "method": "tools/call",
                         "params": ["name": tool, "arguments": arguments]]], flags: flags))
    }

    // MARK: Handshake

    func testInitializeAnswersWithTheVersionAsked() throws {
        try XCTSkipUnless(haveBinary)
        let result = mcp([]).first?["result"] as? [String: Any]
        XCTAssertEqual(result?["protocolVersion"] as? String, "2025-06-18")
        XCTAssertNotNil((result?["capabilities"] as? [String: Any])?["tools"])
        XCTAssertEqual((result?["serverInfo"] as? [String: Any])?["name"] as? String, "pm")
    }

    func testNotificationsGetNoReply() throws {
        try XCTSkipUnless(haveBinary)
        let replies = mcp([["jsonrpc": "2.0", "method": "notifications/initialized", "params": [:]],
                           ["jsonrpc": "2.0", "id": 2, "method": "ping"]])
        XCTAssertEqual(replies.count, 2, "only initialize and ping should have answered")
    }

    func testUnknownMethodIsAProtocolError() throws {
        try XCTSkipUnless(haveBinary)
        let replies = mcp([["jsonrpc": "2.0", "id": 1, "method": "frobnicate"]])
        XCTAssertEqual((replies.last?["error"] as? [String: Any])?["code"] as? Int, -32601)
    }

    // MARK: The tool list is generated, not written

    func testToolListMatchesTheRegistry() throws {
        try XCTSkipUnless(haveBinary)
        let published = Set(tools(flags: ["--allow-write", "--allow-destructive"])
            .compactMap { $0["name"] as? String })
        let expected = Set(ApiRegistry.actions.filter { $0.tier != .affordance }
            .map { $0.name.replacingOccurrences(of: ".", with: "_") })
        XCTAssertEqual(published, expected)
    }

    /// MCP tool names are conventionally `[a-zA-Z0-9_-]`, and clients reject what isn't.
    func testToolNamesAvoidTheDotsActionsUse() throws {
        try XCTSkipUnless(haveBinary)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        for name in tools().compactMap({ $0["name"] as? String }) {
            XCTAssertTrue(name.unicodeScalars.allSatisfy(allowed.contains), name)
        }
    }

    /// An affordance is a request to a running app. The dispatcher would refuse it; not listing it
    /// saves a model finding that out the hard way.
    func testAffordancesAreNotOffered() throws {
        try XCTSkipUnless(haveBinary)
        let names = tools(flags: ["--allow-write", "--allow-destructive"]).compactMap { $0["name"] as? String }
        XCTAssertFalse(names.contains { $0.hasPrefix("app_") })
    }

    // MARK: The published schema is stricter than the contract

    func testTaskReferencesMustCarryTheirDigest() throws {
        try XCTSkipUnless(haveBinary)
        let complete = tools().first { $0["name"] as? String == "task_complete" }
        let schema = complete?["inputSchema"] as? [String: Any]
        let properties = schema?["properties"] as? [String: Any]
        let task = properties?["task"] as? [String: Any]
        XCTAssertEqual(Set(task?["required"] as? [String] ?? []), ["line", "digest"])
        // And the contract itself still doesn't require it, which is the point of saying so here.
        XCTAssertNil(ApiRegistry.spec("task.complete")?.fields.first { $0.kind == .taskRef }?.allowed)
    }

    func testOnlyMutationsOfferDryRun() throws {
        try XCTSkipUnless(haveBinary)
        for tool in tools() {
            guard let name = tool["name"] as? String,
                  let spec = ApiRegistry.spec(name.replacingOccurrences(of: "_", with: ".")),
                  let properties = (tool["inputSchema"] as? [String: Any])?["properties"] as? [String: Any]
            else { continue }
            XCTAssertEqual(properties["dryRun"] != nil, spec.tier == .mutation, name)
        }
    }

    // MARK: Scopes

    func testWritesAreWithheldByDefault() throws {
        try XCTSkipUnless(haveBinary)
        let names = tools(flags: []).compactMap { $0["name"] as? String }
        XCTAssertFalse(names.isEmpty)
        for name in names {
            XCTAssertEqual(ApiRegistry.spec(name.replacingOccurrences(of: "_", with: "."))?.tier, .query, name)
        }
    }

    func testDestructiveToolsNeedTheirOwnFlag() throws {
        try XCTSkipUnless(haveBinary)
        XCTAssertFalse(tools().contains { $0["name"] as? String == "task_delete" })
        XCTAssertTrue(tools(flags: ["--allow-write", "--allow-destructive"])
            .contains { $0["name"] as? String == "task_delete" })
    }

    /// A withheld tool refused for a reason a model can act on, rather than pretending not to exist.
    func testAWithheldToolSaysWhy() throws {
        try XCTSkipUnless(haveBinary)
        let outcome = call("task_delete", ["project": "W-1", "task": ["session": "0", "line": 0, "digest": "abc"]])
        XCTAssertTrue(outcome.isError)
        XCTAssertTrue(outcome.text.contains("flag"), outcome.text)
    }

    func testUnknownToolIsRefused() throws {
        try XCTSkipUnless(haveBinary)
        let outcome = call("task_incinerate", [:])
        XCTAssertTrue(outcome.isError)
        XCTAssertTrue(outcome.text.contains("No such tool"), outcome.text)
    }

    // MARK: Against a real project

    /// Make a project with one task, and return the reference a model would be given for it.
    private func seedProject() throws -> [String: Any] {
        _ = run(["api", "call", "project.create", #"{"title":"Redesign","domain":"W"}"#])
        _ = run(["api", "call", "task.add", #"{"project":"W-1","text":"Review the contract"}"#])
        let (listing, _) = run(["api", "call", "task.list", #"{"project":"W-1"}"#])
        let result = (try? JSONSerialization.jsonObject(with: Data(listing.utf8))) as? [String: Any]
        let todos = result?["data"] as? [[String: Any]] ?? []
        let todo = try XCTUnwrap(todos.first { $0["text"] as? String == "Review the contract" })
        return ["session": todo["sessionISODate"] as Any, "line": todo["lineIndex"] as Any,
                "digest": todo["digest"] as Any]
    }

    func testDryRunReportsWithoutWriting() throws {
        try XCTSkipUnless(haveBinary)
        let reference = try seedProject()
        let preview = call("task_complete", ["project": "W-1", "task": reference, "dryRun": true])
        XCTAssertFalse(preview.isError, preview.text)
        XCTAssertTrue(preview.text.hasPrefix("Would complete"), preview.text)

        let before = call("task_list", ["project": "W-1"])
        XCTAssertTrue(before.text.contains("Review the contract"), "the dry run should have written nothing")

        let done = call("task_complete", ["project": "W-1", "task": reference])
        XCTAssertFalse(done.isError, done.text)
        XCTAssertTrue(done.text.hasPrefix("Completed"), done.text)
        XCTAssertFalse(call("task_list", ["project": "W-1"]).text.contains("Review the contract"))
    }

    /// Publishing `digest` as required and then not checking it would leave the promise to whichever
    /// client happens to validate.
    func testAReferenceWithoutADigestIsRefused() throws {
        try XCTSkipUnless(haveBinary)
        var reference = try seedProject()
        reference["digest"] = nil
        let outcome = call("task_complete", ["project": "W-1", "task": reference])
        XCTAssertTrue(outcome.isError)
        XCTAssertTrue(outcome.text.contains("missingField"), outcome.text)
    }

    func testAStaleReferenceIsRefusedByCode() throws {
        try XCTSkipUnless(haveBinary)
        var reference = try seedProject()
        reference["digest"] = "deadbeef"
        let outcome = call("task_complete", ["project": "W-1", "task": reference])
        XCTAssertTrue(outcome.isError)
        XCTAssertTrue(outcome.text.hasPrefix("staleReference"), outcome.text)
    }

    /// An affordance is refused for a different reason than a flag-gated tool, and has to say so.
    ///
    /// Both used to answer "It was started without the flag that permits it." For `app_openWindow`
    /// that isn't true — no flag enables it, because the server has no app to ask — so a model was
    /// sent looking for a restart that would never help.
    func testAnAffordanceSaysNoFlagWillHelp() throws {
        try XCTSkipUnless(haveBinary)
        let affordance = call("app_openWindow", [:], flags: ["--allow-write", "--allow-destructive"])
        XCTAssertTrue(affordance.isError)
        XCTAssertFalse(affordance.text.contains("flag that permits"), affordance.text)
        XCTAssertTrue(affordance.text.contains("running PM app"), affordance.text)

        // And the flag-gated case still says the thing that is true of it.
        let gated = call("task_delete", [:], flags: [])
        XCTAssertTrue(gated.isError)
        XCTAssertTrue(gated.text.contains("flag that permits"), gated.text)
    }

    /// A bad argument refuses one call. It used to kill the process.
    ///
    /// `limit: -1` reached `prefix(-1)`, which traps — and a trap in a stdio server is not one failed
    /// tool call, it is the end of the session: every request after it goes unanswered, including ones
    /// already in flight. So this checks the refusal *and* that the server is still there behind it.
    func testAnOutOfRangeArgumentDoesntTakeTheServerDown() throws {
        try XCTSkipUnless(haveBinary)
        _ = try seedProject()
        let replies = mcp([
            ["jsonrpc": "2.0", "id": 1, "method": "tools/call",
             "params": ["name": "task_list", "arguments": ["project": "W-1", "limit": -1]]],
            ["jsonrpc": "2.0", "id": 2, "method": "ping"],
        ])
        let refusal = replies.first { $0["id"] as? Int == 1 }
        let result = try XCTUnwrap(refusal?["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)
        let text = ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        XCTAssertTrue(text.hasPrefix("invalidField"), text)

        XCTAssertNotNil(replies.first { $0["id"] as? Int == 2 },
                        "the server didn't survive to answer the next request")
    }
}
