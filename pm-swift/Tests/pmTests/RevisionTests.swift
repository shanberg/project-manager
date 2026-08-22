import XCTest
import Foundation
@testable import PmLib

/// The revision: what a read reports and a batch sends back, driven through the real binary.
///
/// End-to-end rather than in-process because the thing being checked is a round trip — the token a
/// read hands out has to be the one a write will accept, and a test that computed it itself would
/// prove only that it agrees with itself. See docs/api-contract.md.
final class RevisionTests: XCTestCase {

    private static var packageRoot: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
    }
    private static var pmBinaryPath: String {
        (packageRoot as NSString).appendingPathComponent(".build/debug/pm")
    }
    private var haveBinary: Bool { FileManager.default.isExecutableFile(atPath: Self.pmBinaryPath) }

    private var env: [String: String] = [:]
    private var configDir = ""

    override func setUp() {
        super.setUp()
        let fm = FileManager.default
        guard haveBinary else { return }
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

    @discardableResult
    private func call(_ action: String, _ input: [String: Any] = [:], dryRun: Bool = false) -> [String: Any] {
        let json = String(data: (try? JSONSerialization.data(withJSONObject: input)) ?? Data(), encoding: .utf8) ?? "{}"
        var args = ["api", "call", action, json]
        if dryRun { args.append("--dry-run") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.pmBinaryPath)
        process.arguments = args
        process.environment = ProcessInfo.processInfo.environment.merging(env) { _, e in e }
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try? process.run()
        let data = (try? out.fileHandleForReading.readToEnd()) ?? Data()
        _ = try? err.fileHandleForReading.readToEnd()
        process.waitUntilExit()
        return ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
    }

    private func seed() {
        call("project.create", ["title": "Redesign", "domain": "W"])
        for text in ["Review the contract", "Book the venue", "Send the invoice"] {
            call("task.add", ["project": "W-1", "text": text])
        }
    }

    private func todos() -> [[String: Any]] {
        call("task.list", ["project": "W-1", "includeCompleted": true])["data"] as? [[String: Any]] ?? []
    }

    private func reference(_ text: String) -> [String: Any] {
        let todo = todos().first { $0["text"] as? String == text } ?? [:]
        return ["session": todo["sessionISODate"] as Any, "line": todo["lineIndex"] as Any,
                "digest": todo["digest"] as Any]
    }

    private func open() -> [String] {
        (call("task.list", ["project": "W-1"])["data"] as? [[String: Any]] ?? [])
            .compactMap { $0["text"] as? String }
    }

    private func notesPath() throws -> String {
        try XCTUnwrap((call("project.get", ["project": "W-1"])["data"] as? [String: Any])?["notesPath"] as? String)
    }

    /// The guard is only usable if the read tells you what to ask about — so every read reports one,
    /// not just the one action named after reading.
    func testEveryReadReportsARevision() throws {
        try XCTSkipUnless(haveBinary)
        seed()
        let revisions = ["notes.get", "task.list", "task.whatsDue", "task.progress"].map {
            call($0, ["project": "W-1"])["revision"] as? String
        }
        XCTAssertFalse(revisions.contains(where: { $0 == nil }), "a read with no revision can't be acted on")
        XCTAssertEqual(Set(revisions).count, 1, "four reads of one unchanged document, one answer")
    }

    /// The payload carries it too. A caller that holds onto a read holds onto the revision with it,
    /// rather than keeping the two in separate variables that can drift apart.
    func testTheReadCarriesItsRevisionInThePayload() throws {
        try XCTSkipUnless(haveBinary)
        seed()
        let result = call("notes.get", ["project": "W-1"])
        let payload = result["data"] as? [String: Any]
        XCTAssertEqual(payload?["revision"] as? String, result["revision"] as? String)
    }

    /// The round trip: the token a read hands out is the one a write accepts, and the token that write
    /// reports back is what the *next* one takes.
    func testAWriteReportsTheRevisionTheNextOneNeeds() throws {
        try XCTSkipUnless(haveBinary)
        seed()
        let read = try XCTUnwrap(call("task.list", ["project": "W-1"])["revision"] as? String)
        let wrote = call("task.complete", ["project": "W-1", "revision": read,
                                           "tasks": [reference("Review the contract")]])
        let after = try XCTUnwrap(wrote["revision"] as? String)
        XCTAssertNotEqual(after, read, "the document changed, so the revision did")
        XCTAssertEqual(call("task.list", ["project": "W-1"])["revision"] as? String, after,
                       "a write and the read after it must describe the same bytes — the Mac app "
                       + "re-reads the file to catch its revision up rather than taking it from the result")

        let again = call("task.complete", ["project": "W-1", "revision": after,
                                           "tasks": [reference("Book the venue")]])
        XCTAssertNil(again["error"], "the revision a write reports must be the one the next write sends")
        XCTAssertEqual(open(), ["Send the invoice"])
    }

    /// What the whole thing is for. A batch skips a reference it can't resolve — right when the batch
    /// itself removed it, wrong when Obsidian did — and this is the difference.
    func testABatchWontSilentlySkipATaskSomeoneElseEdited() throws {
        try XCTSkipUnless(haveBinary)
        seed()
        let selection = [reference("Review the contract"), reference("Book the venue")]
        let read = try XCTUnwrap(call("task.list", ["project": "W-1"])["revision"] as? String)

        // The file changes under the selection: one of the two tasks is reworded by hand.
        let path = try notesPath()
        let text = try String(contentsOfFile: path, encoding: .utf8)
        try text.replacingOccurrences(of: "Book the venue", with: "Book the venue for March")
            .write(toFile: path, atomically: true, encoding: .utf8)

        let refused = call("task.complete", ["project": "W-1", "revision": read, "tasks": selection])
        XCTAssertEqual((refused["error"] as? [String: Any])?["code"] as? String, "conflict")
        XCTAssertEqual(open(), ["Review the contract", "Book the venue for March", "Send the invoice"],
                       "nothing was written — not even the half of the selection that still resolved")

        // Without the revision the same batch goes ahead and completes only what it could still find,
        // which is the behaviour the guard exists to make optional rather than inevitable.
        call("task.complete", ["project": "W-1", "tasks": selection])
        XCTAssertEqual(open(), ["Book the venue for March", "Send the invoice"])
    }

    /// A stale revision stops the write before the transform runs, so a preview of it is a refusal
    /// too. A dry run that succeeded where the real call would fail is worse than no preview.
    func testAPreviewIsRefusedWhereTheWriteWouldBe() throws {
        try XCTSkipUnless(haveBinary)
        seed()
        let refused = call("task.delete", ["project": "W-1", "revision": "0000000000",
                                           "tasks": [reference("Send the invoice")]], dryRun: true)
        XCTAssertEqual((refused["error"] as? [String: Any])?["code"] as? String, "conflict")
    }

    /// Unsent, the field is absent rather than empty — a single-task write says nothing about the rest
    /// of the document, and shouldn't be refused because a line elsewhere in it moved.
    func testASingleWriteIsUnaffectedByTheRestOfTheDocument() throws {
        try XCTSkipUnless(haveBinary)
        seed()
        let target = reference("Send the invoice")
        let path = try notesPath()
        let text = try String(contentsOfFile: path, encoding: .utf8)
        try (text + "\n- [ ] Typed straight into Obsidian\n").write(toFile: path, atomically: true, encoding: .utf8)

        let result = call("task.complete", ["project": "W-1", "task": target])
        XCTAssertNil(result["error"])
        XCTAssertEqual(open(), ["Review the contract", "Book the venue", "Typed straight into Obsidian"])
    }
}
