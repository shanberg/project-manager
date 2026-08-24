import XCTest
import Foundation
@testable import PmLib

/// A dry run writes nothing — for *every* mutation, not for the ones somebody remembered to check.
///
/// The contract states this without qualification, `pm mcp` publishes `dryRun` on every mutation, and
/// its description tells a model the call reports "without writing". Five actions — the ones that move
/// folders rather than edit a document — sat outside the pipeline that honours the flag and wrote
/// anyway, reporting `dryRun: false` and a past tense while they did it. A preview of `project.archive`
/// archived the project.
///
/// So this drives every mutation the registry publishes and compares the whole world before and after:
/// both project folders, every file in them, and the config directory with its focus, journal and
/// snapshots. `inputs` must name every mutation, so an action added to the contract fails here until
/// somebody says how to preview it, rather than joining the group that quietly writes.
final class DryRunTests: XCTestCase {

    private static var packageRoot: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
    }
    private static var pmBinaryPath: String {
        (packageRoot as NSString).appendingPathComponent(".build/debug/pm")
    }
    private var haveBinary: Bool { FileManager.default.isExecutableFile(atPath: Self.pmBinaryPath) }

    private var env: [String: String] = [:]
    private var root = ""
    private var configDir = ""

    override func setUp() {
        super.setUp()
        guard haveBinary else { return }
        let fm = FileManager.default
        root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        configDir = (root as NSString).appendingPathComponent("config")
        let active = (root as NSString).appendingPathComponent("active")
        let archive = (root as NSString).appendingPathComponent("archive")
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
        if !root.isEmpty { try? FileManager.default.removeItem(atPath: root) }
        super.tearDown()
    }

    @discardableResult
    private func call(_ action: String, _ input: [String: Any] = [:],
                      dryRun: Bool = false) -> [String: Any] {
        let json = String(data: (try? JSONSerialization.data(withJSONObject: input)) ?? Data(),
                          encoding: .utf8) ?? "{}"
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

    /// Enough of a world that every action has something real to act on: a parent with a child, a
    /// completed task, a link, and a second project sitting in the archive for `project.unarchive`.
    private func seed() {
        call("project.create", ["title": "Redesign", "domain": "W"])
        call("project.create", ["title": "Retired", "domain": "W"])
        call("project.archive", ["project": "W-2"])
        for text in ["Review the contract", "Book the venue", "Send the invoice"] {
            call("task.add", ["project": "W-1", "text": text])
        }
        call("task.add", ["project": "W-1", "text": "Chase the deposit",
                          "anchor": reference("Book the venue"), "position": "child"])
        call("task.complete", ["project": "W-1", "task": reference("Send the invoice")])
        call("notes.addLink", ["project": "W-1", "text": "https://example.com", "label": "Brief"])
        call("project.focus", ["project": "W-1"])
    }

    private func reference(_ text: String) -> [String: Any] {
        let todos = call("task.list", ["project": "W-1", "includeCompleted": true])["data"]
            as? [[String: Any]] ?? []
        let todo = todos.first { $0["text"] as? String == text } ?? [:]
        return ["session": todo["sessionISODate"] as Any, "line": todo["lineIndex"] as Any,
                "digest": todo["digest"] as Any]
    }

    private func revision(ofProject project: String) -> String {
        call("notes.get", ["project": project])["revision"] as? String ?? ""
    }

    /// Every file under `root`, by path and content. Not just the notes file: the bugs this is here
    /// for moved folders and wrote `focused.json`, neither of which a notes-only check would notice.
    private func world() -> [String: String] {
        let fm = FileManager.default
        var out: [String: String] = [:]
        guard let walker = fm.enumerator(atPath: root) else { return out }
        for case let relative as String in walker {
            let full = (root as NSString).appendingPathComponent(relative)
            var isDirectory: ObjCBool = false
            fm.fileExists(atPath: full, isDirectory: &isDirectory)
            out[relative] = isDirectory.boolValue
                ? "<dir>"
                : ((try? String(contentsOfFile: full, encoding: .utf8)) ?? "<binary>")
        }
        return out
    }

    /// One plausible call per mutation. Keyed by action so the coverage check below can compare this
    /// against the registry rather than trusting that the list was kept up.
    private func inputs() -> [String: [String: Any]] {
        [
            "task.add": ["project": "W-1", "text": "Draft the brief"],
            "task.complete": ["project": "W-1", "task": reference("Review the contract")],
            "task.reopen": ["project": "W-1", "task": reference("Send the invoice")],
            "task.focus": ["project": "W-1", "task": reference("Book the venue")],
            "task.diveIn": ["project": "W-1"],
            "task.setDue": ["project": "W-1", "task": reference("Book the venue"), "due": "2026-12-01"],
            "task.setText": ["project": "W-1", "task": reference("Book the venue"), "text": "Book a venue"],
            "task.wrap": ["project": "W-1", "task": reference("Review the contract"), "text": "Paperwork"],
            "task.unwrap": ["project": "W-1", "task": reference("Book the venue")],
            "task.delete": ["project": "W-1", "task": reference("Review the contract")],
            "session.start": ["project": "W-1"],
            "session.note": ["project": "W-1", "prose": "Spoke to the vendor."],
            "session.rename": ["project": "W-1", "session": "0", "label": "Kickoff"],
            "session.delete": ["project": "W-1", "session": "0"],
            "notes.setDetail": ["project": "W-1", "key": "summary", "value": "A new summary."],
            "notes.addLink": ["project": "W-1", "text": "https://example.org"],
            "project.create": ["title": "Something New", "domain": "W"],
            "project.rename": ["project": "W-1", "title": "Rebuild"],
            "project.archive": ["project": "W-1"],
            "project.unarchive": ["project": "W-2"],
            "project.focus": ["project": "W-2"],
            "config.set": ["key": "activePath", "value": "/tmp/somewhere-else"],
            "journal.undo": ["project": "W-1"],
        ]
    }

    /// The actions this fixture can't make succeed. Empty, deliberately: "wrote nothing" is trivially
    /// true of a call that refused, so an action that can't be made to run here proves nothing, and
    /// the escape hatch is named rather than silent so that stays visible.
    private static let refusedByThisFixture: Set<String> = []

    // MARK: The invariant

    func testEveryMutationCanBePreviewedWithoutWriting() throws {
        try XCTSkipUnless(haveBinary)
        seed()

        var succeeded: Set<String> = []
        for (action, input) in inputs().sorted(by: { $0.key < $1.key }) {
            let before = world()
            let result = call(action, input, dryRun: true)
            XCTAssertEqual(world(), before, "\(action) wrote something during a dry run")

            if let error = result["error"] as? [String: Any] {
                XCTAssertTrue(Self.refusedByThisFixture.contains(action),
                              "\(action) refused unexpectedly: \(error["message"] ?? "")")
                continue
            }
            succeeded.insert(action)
            // The envelope has to say it was a preview, and say what *would* happen. An action that
            // found nothing to do returns a statement instead, which has no future tense to take.
            XCTAssertEqual(result["dryRun"] as? Bool, true, "\(action) didn't report itself as a dry run")
            let summary = result["summary"] as? String ?? ""
            XCTAssertFalse(summary.isEmpty, "\(action) previewed without saying what it would do")
            if action != "session.start" {  // idempotent: "Today's session was already there."
                XCTAssertTrue(summary.hasPrefix("Would "),
                              "\(action) previewed in the past tense: \(summary)")
            }
        }
        XCTAssertEqual(succeeded, Set(inputs().keys).subtracting(Self.refusedByThisFixture))
    }

    /// Put the files back exactly as they were. Not by seeding again — `seed()` creates the next
    /// numbered project each time, so calling it twice builds a different world, and the second round
    /// of `project.archive` would be archiving something that isn't there.
    private func restore(_ snapshot: [String: String]) {
        let fm = FileManager.default
        try? fm.removeItem(atPath: root)
        for (relative, content) in snapshot.sorted(by: { $0.key < $1.key }) {
            let full = (root as NSString).appendingPathComponent(relative)
            if content == "<dir>" {
                try? fm.createDirectory(atPath: full, withIntermediateDirectories: true)
            } else {
                try? fm.createDirectory(atPath: (full as NSString).deletingLastPathComponent,
                                        withIntermediateDirectories: true)
                try? content.write(toFile: full, atomically: true, encoding: .utf8)
            }
        }
    }

    /// A preview is only worth something if the write it previews is real. Same fixture, same inputs,
    /// run for real — so an action whose dry run writes nothing because the action itself is broken
    /// fails here rather than passing above.
    func testTheSameActionsDoWriteWhenItIsntADryRun() throws {
        try XCTSkipUnless(haveBinary)
        seed()
        let seeded = world()
        let cases = inputs()

        for (action, input) in cases.sorted(by: { $0.key < $1.key })
        where !Self.refusedByThisFixture.contains(action) {
            restore(seeded)
            let result = call(action, input, dryRun: false)
            XCTAssertNil(result["error"], "\(action) failed for real: \(result)")
            XCTAssertEqual(result["dryRun"] as? Bool, false, action)
            // `session.start` is idempotent and today's session is already there, so it alone is
            // allowed to leave the world as it found it.
            if action != "session.start" {
                XCTAssertNotEqual(world(), seeded, "\(action) claimed to write and didn't")
            }
        }
    }

    /// The registry is the list, not this file. An action added to the contract and not given a
    /// preview here fails until somebody says how to call it.
    func testEveryPublishedMutationIsCovered() {
        let published = Set(ApiRegistry.actions.filter { $0.tier == .mutation }.map(\.name))
        XCTAssertEqual(Set(inputs().keys), published,
                       "mutations with no dry-run case: \(published.subtracting(inputs().keys))")
    }

    // MARK: The specific regressions

    func testPreviewingAnArchiveLeavesTheProjectWhereItIs() throws {
        try XCTSkipUnless(haveBinary)
        seed()
        let result = call("project.archive", ["project": "W-1"], dryRun: true)
        XCTAssertEqual(result["summary"] as? String, "Would archive W-1 Redesign.")
        XCTAssertEqual(result["dryRun"] as? Bool, true)
        // Still readable where it was, which is the only proof that matters.
        XCTAssertFalse(revision(ofProject: "W-1").isEmpty)
        XCTAssertNil(call("project.get", ["project": "W-1"])["error"])
    }

    func testPreviewingAProjectWriteIsntJournalled() throws {
        try XCTSkipUnless(haveBinary)
        seed()
        let before = (call("journal.list", ["limit": 0])["data"] as? [[String: Any]] ?? []).count
        for action in ["project.create", "project.rename", "project.archive", "config.set"] {
            call(action, inputs()[action] ?? [:], dryRun: true)
        }
        let after = (call("journal.list", ["limit": 0])["data"] as? [[String: Any]] ?? []).count
        XCTAssertEqual(after, before, "a preview was recorded as a write")
    }
}
