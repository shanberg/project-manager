import XCTest
import Foundation
@testable import PmLib

/// The mutation journal, driven through the real binary — because what it is for is recording writes
/// that came from *somewhere else*, and a test that calls the dispatcher in-process can't tell one
/// caller from another. See docs/api-contract.md.
final class JournalTests: XCTestCase {

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
    private func call(_ action: String, _ input: [String: Any] = [:],
                      source: String? = nil, dryRun: Bool = false) -> [String: Any] {
        let json = String(data: (try? JSONSerialization.data(withJSONObject: input)) ?? Data(), encoding: .utf8) ?? "{}"
        var args = ["api", "call", action, json]
        if let source { args += ["--source", source] }
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
        for text in ["Review the contract", "Book the venue"] {
            call("task.add", ["project": "W-1", "text": text])
        }
    }

    private func reference(_ text: String) -> [String: Any] {
        let todos = call("task.list", ["project": "W-1"])["data"] as? [[String: Any]] ?? []
        let todo = todos.first { $0["text"] as? String == text } ?? [:]
        return ["session": todo["sessionISODate"] as Any, "line": todo["lineIndex"] as Any,
                "digest": todo["digest"] as Any]
    }

    private func entries() -> [[String: Any]] {
        call("journal.list", ["project": "W-1"])["data"] as? [[String: Any]] ?? []
    }

    private func texts() -> [String] {
        (call("task.list", ["project": "W-1", "includeCompleted": true])["data"] as? [[String: Any]] ?? [])
            .compactMap { $0["text"] as? String }
    }

    // MARK: Recording

    func testEveryWriteIsRecorded() throws {
        try XCTSkipUnless(haveBinary)
        seed()
        let recorded = entries()
        XCTAssertEqual(recorded.count, 3, "two tasks and the project")
        XCTAssertEqual(recorded.first?["action"] as? String, "task.add", "newest first")
        XCTAssertEqual(recorded.first?["summary"] as? String, "Added “Book the venue”")
    }

    /// The question the journal exists to answer: which surface did this?
    func testEntriesSayWhichAdapterWrote() throws {
        try XCTSkipUnless(haveBinary)
        seed()
        call("task.complete", ["project": "W-1", "task": reference("Review the contract")], source: "mcp")
        call("task.setDue", ["project": "W-1", "task": reference("Book the venue"), "due": "2026-12-01"],
             source: "raycast")
        XCTAssertEqual(entries().prefix(2).compactMap { $0["source"] as? String }, ["raycast", "mcp"])
    }

    /// A write with no document behind it is worth recording and can't be reversed; the entry says so
    /// rather than leaving a caller to discover it.
    func testWritesWithoutADocumentAreRecordedButNotReversible() throws {
        try XCTSkipUnless(haveBinary)
        seed()
        let created = entries().first { $0["action"] as? String == "project.create" }
        XCTAssertEqual(created?["undoable"] as? Bool, false)
        XCTAssertNil(created?["notesPath"])
    }

    func testADryRunIsNotAWrite() throws {
        try XCTSkipUnless(haveBinary)
        seed()
        let before = entries().count
        call("task.complete", ["project": "W-1", "task": reference("Book the venue")], dryRun: true)
        XCTAssertEqual(entries().count, before)
    }

    // MARK: Reversing

    func testUndoWalksBackThroughTheHistory() throws {
        try XCTSkipUnless(haveBinary)
        seed()
        call("task.complete", ["project": "W-1", "task": reference("Review the contract")], source: "mcp")
        call("task.setDue", ["project": "W-1", "task": reference("Book the venue"), "due": "2026-12-01"],
             source: "raycast")

        // Each undo takes back one more write — including two this process didn't make.
        XCTAssertEqual(call("journal.undo", ["project": "W-1"])["summary"] as? String,
                       "Reversed: Due 2026-12-01.")
        XCTAssertEqual(call("journal.undo", ["project": "W-1"])["summary"] as? String,
                       "Reversed: Completed “Review the contract”.")
        XCTAssertEqual(texts(), ["Review the contract", "Book the venue"])
        call("journal.undo", ["project": "W-1"])
        XCTAssertEqual(texts(), ["Review the contract"])
        call("journal.undo", ["project": "W-1"])
        XCTAssertEqual(texts(), [], "back to a project with nothing in it")
    }

    /// Reversals are writes too, so they're recorded — but they must not be what the next undo picks,
    /// or undo oscillates between two states instead of walking back.
    func testAReversalIsRecordedButIsntWhatUndoPicksNext() throws {
        try XCTSkipUnless(haveBinary)
        seed()
        call("journal.undo", ["project": "W-1"])
        let reversal = try XCTUnwrap(entries().first)
        XCTAssertEqual(reversal["action"] as? String, "journal.undo")
        XCTAssertNotNil(reversal["reverses"])
        XCTAssertEqual(reversal["undoable"] as? Bool, true, "a reversal can itself be reversed, by id")

        XCTAssertEqual(call("journal.undo", ["project": "W-1"])["summary"] as? String,
                       "Reversed: Added “Review the contract”.",
                       "the second undo should go further back, not undo the first undo")
    }

    /// The safety the whole design turns on: never discard an edit made since.
    func testUndoRefusesWhenTheFileHasChangedSince() throws {
        try XCTSkipUnless(haveBinary)
        seed()
        let path = try XCTUnwrap((call("project.get", ["project": "W-1"])["data"] as? [String: Any])?["notesPath"] as? String)
        let text = try String(contentsOfFile: path, encoding: .utf8)
        try (text + "\n- [ ] Typed straight into Obsidian\n").write(toFile: path, atomically: true, encoding: .utf8)

        let refused = call("journal.undo", ["project": "W-1"])
        XCTAssertEqual((refused["error"] as? [String: Any])?["code"] as? String, "conflict")
        XCTAssertTrue(try String(contentsOfFile: path, encoding: .utf8).contains("Obsidian"),
                      "the hand-written line must survive")
    }

    func testUndoPreviewsWithoutWriting() throws {
        try XCTSkipUnless(haveBinary)
        seed()
        let preview = call("journal.undo", ["project": "W-1"], dryRun: true)
        XCTAssertEqual(preview["summary"] as? String, "Would reverse: Added “Book the venue”.")
        XCTAssertEqual(texts(), ["Review the contract", "Book the venue"])
    }

    func testNothingToReverseIsSaidPlainly() throws {
        try XCTSkipUnless(haveBinary)
        call("project.create", ["title": "Empty", "domain": "W"])
        let refused = call("journal.undo", ["project": "W-1"])
        XCTAssertNotNil(refused["error"])
    }

    // MARK: Snapshots

    /// Snapshots are named by the hash of their content, so a document that passes through the same
    /// state twice is stored once.
    func testSnapshotsAreStoredByContent() throws {
        try XCTSkipUnless(haveBinary)
        seed()
        call("task.complete", ["project": "W-1", "task": reference("Book the venue")])
        call("journal.undo", ["project": "W-1"])

        let directory = (configDir as NSString).appendingPathComponent("journal")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        let recorded = entries().flatMap {
            [$0["revisionBefore"] as? String, $0["revisionAfter"] as? String].compactMap { $0 }
        }
        XCTAssertEqual(Set(files.map { ($0 as NSString).deletingPathExtension }), Set(recorded))
        XCTAssertLessThan(files.count, recorded.count, "the repeated state should be stored once")
    }
}
