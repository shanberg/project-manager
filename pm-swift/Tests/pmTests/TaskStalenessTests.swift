import XCTest
import Foundation
@testable import PmLib

/// Gone stale: open work untouched for three weeks, folded away and offered for review. See
/// docs/stale-tasks.md.
final class TaskStalenessTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// Noon on Fri, Nov 27, 2026.
    private let now = ISO8601DateFormatter().date(from: "2026-11-27T12:00:00Z")!

    private func task(_ text: String, on day: String, session: Int = 0, line: Int = 0, depth: Int = 0,
                      checked: Bool = false, due: String? = nil, focused: Bool = false) -> Todo {
        var todo = Todo(text: text, checked: checked, rawLine: "- [ ] \(text)", context: "", depth: depth,
                        sessionIndex: session, lineIndex: line, isFocused: focused, dueDate: due,
                        sessionISODate: day)
        todo.effectiveDueDate = due
        return todo
    }

    // MARK: One line

    func testATaskFromLastMonthIsStaleAndOneFromLastWeekIsnt() {
        XCTAssertTrue(TaskStaleness.isStale(task("Old", on: "2026-10-20"), now: now, calendar: calendar))
        XCTAssertFalse(TaskStaleness.isStale(task("Recent", on: "2026-11-16"), now: now, calendar: calendar))
    }

    /// Three weeks counts from the end of the day it was written.
    func testTheEdgeIsThreeWeeksFromTheEndOfItsDay() {
        // Written Nov 5: touched until midnight Nov 6, so stale from midnight Nov 27.
        XCTAssertTrue(TaskStaleness.isStale(task("Edge", on: "2026-11-05"), now: now, calendar: calendar))
        XCTAssertFalse(TaskStaleness.isStale(task("Edge", on: "2026-11-06"), now: now, calendar: calendar))
    }

    func testAPickOrAKeepMakesItFreshAgain() {
        var picked = task("Picked", on: "2026-09-01")
        picked.picked = PickMark(into: "2026-11-20", at: "2026-11-20T09:00:00Z")
        XCTAssertFalse(TaskStaleness.isStale(picked, now: now, calendar: calendar))

        var kept = task("Kept", on: "2026-09-01")
        kept.kept = "2026-11-25T09:00:00Z"
        XCTAssertFalse(TaskStaleness.isStale(kept, now: now, calendar: calendar))

        var keptLongAgo = task("Kept long ago", on: "2026-09-01")
        keptLongAgo.kept = "2026-10-01T09:00:00Z"
        XCTAssertTrue(TaskStaleness.isStale(keptLongAgo, now: now, calendar: calendar))
    }

    /// A date already says when it matters, and the focused task is the one you're on.
    func testDatedFocusedAndClosedTasksArentStale() {
        XCTAssertFalse(TaskStaleness.isStale(task("Dated", on: "2026-09-01", due: "2026-12-10"), now: now, calendar: calendar))
        XCTAssertFalse(TaskStaleness.isStale(task("Focused", on: "2026-09-01", focused: true), now: now, calendar: calendar))
        XCTAssertFalse(TaskStaleness.isStale(task("Done", on: "2026-09-01", checked: true), now: now, calendar: calendar))
    }

    func testAnUndatedHeadingIsNeverStale() {
        var todo = task("Somewhere", on: "2026-09-01")
        todo.sessionISODate = nil
        XCTAssertNil(TaskStaleness.lastTouched(todo, calendar: calendar))
        XCTAssertFalse(TaskStaleness.isStale(todo, now: now, calendar: calendar))
    }

    // MARK: Trees

    /// A tree is stale only when every open line in it is; one dated subtask keeps the tree in sight.
    func testATreeIsStaleOnlyWhenAllOfItIs() {
        let todos = [
            task("Plan the offsite", on: "2026-09-01", session: 1, line: 0),
            task("Find a room", on: "2026-09-01", session: 1, line: 1, depth: 1),
            task("Book catering", on: "2026-09-01", session: 1, line: 2, depth: 1, due: "2026-12-01"),
            task("Email Dana", on: "2026-09-01", session: 1, line: 3),
            task("Finished thing", on: "2026-09-01", session: 1, line: 4, checked: true),
            task("Today's", on: "2026-11-27", session: 0, line: 0),
        ]
        let stale = TaskStaleness.staleLines(in: todos, now: now, calendar: calendar)
        XCTAssertEqual(stale, ["1:3"], "Only Email Dana: the offsite has a dated step, the finished one is closed")
    }

    func testAClosedParentWithOpenChildrenFoldsWhole() {
        let todos = [
            task("Parent", on: "2026-09-01", session: 0, line: 0, checked: true),
            task("Child", on: "2026-09-01", session: 0, line: 1, depth: 1),
        ]
        XCTAssertEqual(TaskStaleness.staleLines(in: todos, now: now, calendar: calendar), ["0:0", "0:1"])
    }

    /// The review goes longest-forgotten first, one tree at a time, by its root.
    func testStaleRootsAreOldestFirst() {
        var keptInOctober = task("Kept in October", on: "2026-08-01", session: 2, line: 0)
        keptInOctober.kept = "2026-10-15T09:00:00Z"
        let todos = [
            task("September", on: "2026-09-10", session: 1, line: 0),
            task("Its step", on: "2026-09-10", session: 1, line: 1, depth: 1),
            keptInOctober,
            task("August", on: "2026-08-01", session: 2, line: 1),
        ]
        let roots = TaskStaleness.staleRoots(in: todos, now: now, calendar: calendar).map(\.text)
        XCTAssertEqual(roots, ["August", "September", "Kept in October"])
    }

    // MARK: The log

    func testAKeepIsReversedByAReleaseAndBack() throws {
        let task = PickedTask(session: "2026-09-02", line: 0, digest: "abcd1234", text: "Email Dana")
        let kept = PickEvent(id: "k1", at: "2026-11-27T10:00:00Z", event: .kept, task: task)
        let back = PickLog.reversing([kept], source: nil, at: "t")
        XCTAssertEqual(back.map(\.event), [.released])
        XCTAssertEqual(back.first?.reverses, "k1")
        XCTAssertNil(back.first?.into)
        XCTAssertEqual(PickLog.keeps([kept] + back), [], "The release cancels the keep")

        let again = PickLog.reversing(back, source: nil, at: "t2")
        XCTAssertEqual(again.map(\.event), [.kept], "Undoing the undo keeps it again")
        XCTAssertEqual(PickLog.keeps([kept] + back + again).map(\.id), [again[0].id])
    }

    /// A keep isn't a pick: it draws nothing in any sitting.
    func testAKeepIsNotAPick() {
        let task = PickedTask(session: "2026-09-02", line: 0, digest: "abcd1234", text: "Email Dana")
        let kept = PickEvent(id: "k1", at: "2026-11-27T10:00:00Z", event: .kept, task: task)
        XCTAssertEqual(PickLog.standing([kept]), [])
    }

    // MARK: Through the contract

    private static var pmBinaryPath: String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
        return (root as NSString).appendingPathComponent(".build/debug/pm")
    }
    private var haveBinary: Bool { FileManager.default.isExecutableFile(atPath: Self.pmBinaryPath) }
    private var env: [String: String] = [:]
    private var root = ""
    private var projectPath = ""
    private var notesPath = ""

    /// A project with a task today and a sitting from September that left a tree open.
    private func vault() throws {
        let fm = FileManager.default
        root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        let configDir = (root as NSString).appendingPathComponent("config")
        let active = (root as NSString).appendingPathComponent("active")
        let archive = (root as NSString).appendingPathComponent("archive")
        for path in [configDir, active, archive] {
            try fm.createDirectory(atPath: path, withIntermediateDirectories: true)
        }
        let config: [String: Any] = ["activePath": active, "archivePath": archive,
                                     "domains": ["W": "Work"], "subfolders": ["docs"]]
        try JSONSerialization.data(withJSONObject: config)
            .write(to: URL(fileURLWithPath: (configDir as NSString).appendingPathComponent("config.json")))
        env = ["PM_CONFIG_HOME": configDir, "PM_ACTIVE_PATH": active, "PM_ARCHIVE_PATH": archive]
        call("project.create", ["title": "Redesign", "domain": "W"])
        call("task.add", ["project": "W-1", "text": "Review the contract"])
        let folder = try XCTUnwrap(fm.contentsOfDirectory(atPath: active).first)
        projectPath = (active as NSString).appendingPathComponent(folder)
        notesPath = try XCTUnwrap(resolveNotesPath(projectPath: projectPath))
        let text = try String(contentsOfFile: notesPath, encoding: .utf8)
        try (text + "\n### Wed, Sep 2, 2026\n\nOffsite.\n\n- [ ] Plan the offsite\n  - [ ] Find a room\n- [ ] Email Dana\n")
            .write(toFile: notesPath, atomically: true, encoding: .utf8)
    }

    override func tearDown() {
        if !root.isEmpty { try? FileManager.default.removeItem(atPath: root) }
        super.tearDown()
    }

    @discardableResult
    private func call(_ action: String, _ input: [String: Any] = [:]) -> [String: Any] {
        let json = String(data: (try? JSONSerialization.data(withJSONObject: input)) ?? Data(), encoding: .utf8) ?? "{}"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.pmBinaryPath)
        process.arguments = ["api", "call", action, json]
        process.environment = ProcessInfo.processInfo.environment.merging(env) { _, e in e }
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        try? process.run()
        let data = (try? out.fileHandleForReading.readToEnd()) ?? Data()
        process.waitUntilExit()
        return ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
    }

    private func tasks() -> [[String: Any]] {
        call("task.list", ["project": "W-1", "includeCompleted": true])["data"] as? [[String: Any]] ?? []
    }

    private func reference(_ text: String) -> [String: Any] {
        let todo = tasks().first { $0["text"] as? String == text } ?? [:]
        return ["session": todo["sessionISODate"] as Any, "line": todo["lineIndex"] as Any,
                "digest": todo["digest"] as Any]
    }

    private func kept(_ text: String) -> String? {
        tasks().first { $0["text"] as? String == text }?["kept"] as? String
    }

    /// Keep touches the whole tree, leaves the notes alone, and picks nothing up.
    func testKeepingMarksTheTreeAndChangesNothingElse() throws {
        try XCTSkipUnless(haveBinary)
        try vault()
        let before = try String(contentsOfFile: notesPath, encoding: .utf8)
        let result = call("task.keep", ["project": "W-1", "task": reference("Find a room")])
        XCTAssertEqual(result["summary"] as? String, "Kept \u{201C}Plan the offsite\u{201D}.", "\(result)")
        XCTAssertEqual(try String(contentsOfFile: notesPath, encoding: .utf8), before)
        XCTAssertNotNil(kept("Plan the offsite"))
        XCTAssertNotNil(kept("Find a room"), "The tree goes together")
        XCTAssertNil(kept("Email Dana"))
        XCTAssertNil(tasks().first { $0["text"] as? String == "Plan the offsite" }?["picked"] as? [String: Any])
        XCTAssertEqual(PickLog.events(projectPath: projectPath).map(\.event), [.kept])
    }

    func testUndoingAKeepTakesItBack() throws {
        try XCTSkipUnless(haveBinary)
        try vault()
        call("task.keep", ["project": "W-1", "tasks": [reference("Email Dana"), reference("Plan the offsite")]])
        XCTAssertNotNil(kept("Email Dana"))
        call("journal.undo", ["project": "W-1"])
        XCTAssertNil(kept("Email Dana"))
        XCTAssertNil(kept("Plan the offsite"))
    }
}
