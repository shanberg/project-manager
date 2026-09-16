import XCTest
import Foundation
@testable import PmLib

/// The completion log's rules, then the log as surfaces actually reach it. See docs/done-report.md.
final class DoneLogTests: XCTestCase {

    private func todos(_ body: String) throws -> [Todo] {
        try parseTodos(notes: ProjectNotes(title: "T", sessions: [
            Session(date: "Mon, Sep 14, 2026", label: "", body: body),
        ]))
    }

    private func changes(_ before: String, _ after: String) throws -> [DoneEvent] {
        let old = try todos(before), new = try todos(after)
        return DoneLog.changes(from: DoneLog.counts(of: old), to: DoneLog.counts(of: new),
                               todos: new, at: "2026-09-16T10:00:00Z")
    }

    // MARK: What counts as a completion

    func testTickingATaskIsACompletion() throws {
        let events = try changes("- [ ] Email Dana\n- [ ] Book the venue",
                                 "- [x] Email Dana\n- [ ] Book the venue")
        XCTAssertEqual(events.map(\.event), [.completed])
        XCTAssertEqual(events.first?.text, "Email Dana")
        XCTAssertEqual(events.first?.session, "2026-09-14", "when it was written, beside when it was done")
    }

    func testUntickingIsAReopening() throws {
        XCTAssertEqual(try changes("- [x] Email Dana", "- [ ] Email Dana").map(\.event), [.reopened])
    }

    /// A session starting above everything moves every task. None of that is work.
    func testMovingTasksIsNothing() throws {
        XCTAssertEqual(try changes("- [ ] A\n- [x] B", "- [x] B\n  - [ ] A due: 2026-10-01").count, 0)
    }

    /// Written already done, or a finished task tidied: neither is something you did just now.
    func testATaskArrivingCheckedOrLeavingIsNothing() throws {
        XCTAssertEqual(try changes("- [ ] A", "- [ ] A\n- [x] Logged after the fact").count, 0)
        XCTAssertEqual(try changes("- [x] A\n- [ ] B", "- [ ] B").count, 0)
    }

    /// Two tasks with the same text are two tasks. Ticking one is one completion, not zero or two.
    func testDuplicateTextIsCounted() throws {
        let events = try changes("- [ ] Reply\n- [ ] Reply", "- [x] Reply\n- [ ] Reply")
        XCTAssertEqual(events.map(\.event), [.completed])
        XCTAssertEqual(try changes("- [ ] Reply\n- [ ] Reply", "- [x] Reply\n- [x] Reply").count, 2)
    }

    /// The focus marker and the due date aren't the task's text, so moving focus off a task as it's
    /// completed doesn't make it a different task.
    func testCompletingAFocusedTaskIsStillThatTask() throws {
        XCTAssertEqual(try changes("- [ ] A due: 2026-09-20 @", "- [x] A due: 2026-09-20").map(\.event),
                       [.completed])
    }

    // MARK: What still stands

    private func event(_ kind: DoneEvent.Kind, _ digest: String, _ at: String) -> DoneEvent {
        DoneEvent(at: at, event: kind, text: digest, digest: digest)
    }

    func testAReopeningCancelsTheCompletionBeforeIt() {
        let standing = DoneLog.standing([
            event(.completed, "a", "2026-09-01T10:00:00Z"),
            event(.completed, "b", "2026-09-01T11:00:00Z"),
            event(.reopened, "a", "2026-09-03T10:00:00Z"),
            event(.completed, "a", "2026-09-05T10:00:00Z"),
        ])
        XCTAssertEqual(standing.map(\.at), ["2026-09-01T11:00:00Z", "2026-09-05T10:00:00Z"])
    }

    func testAReopeningWithNothingToCancelIsIgnored() {
        XCTAssertEqual(DoneLog.standing([event(.reopened, "a", "2026-09-01T10:00:00Z")]).count, 0)
    }

    // MARK: Ranges

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        calendar.firstWeekday = 2
        return calendar
    }

    /// A report's today is the reader's today — 11pm in Los Angeles is tomorrow in UTC, and is still
    /// today here.
    func testTodayIsTheReadersDay() throws {
        let now = DoneLog.date("2026-09-16T18:00:00Z")!
        let range = try DoneRange.resolve(period: nil, since: nil, until: nil, now: now, calendar: calendar)
        XCTAssertTrue(range.contains(DoneLog.date("2026-09-17T06:00:00Z")!))
        XCTAssertFalse(range.contains(DoneLog.date("2026-09-17T07:00:00Z")!))
    }

    func testWeekAndExplicitDays() throws {
        let now = DoneLog.date("2026-09-16T18:00:00Z")!  // a Wednesday
        let week = try DoneRange.resolve(period: "week", since: nil, until: nil, now: now, calendar: calendar)
        XCTAssertTrue(week.contains(DoneLog.date("2026-09-14T08:00:00Z")!), "Monday morning")
        XCTAssertFalse(week.contains(DoneLog.date("2026-09-14T06:00:00Z")!), "Sunday night")

        let days = try DoneRange.resolve(period: nil, since: "2026-09-01", until: "2026-09-02", now: now,
                                         calendar: calendar)
        XCTAssertTrue(days.contains(DoneLog.date("2026-09-03T06:59:00Z")!), "until is inclusive")
        XCTAssertFalse(days.contains(DoneLog.date("2026-09-03T07:00:00Z")!))
        XCTAssertThrowsError(try DoneRange.resolve(period: nil, since: "last tuesday", until: nil,
                                                   calendar: calendar))
    }

    // MARK: Looking at a folder

    private var folder = ""

    override func setUp() {
        super.setUp()
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: folder)
        if !configDir.isEmpty {
            try? FileManager.default.removeItem(atPath: (configDir as NSString).deletingLastPathComponent)
        }
        super.tearDown()
    }

    private func notes(_ body: String) -> String {
        "# T\n\n## Sessions\n\n### Mon, Sep 14, 2026\n\n\(body)\n"
    }

    /// Tasks already done when PM first sees a project were done at a time nobody knows. The first look
    /// records them and logs nothing, or the first report would be a year long.
    func testTheFirstLookLogsNothing() {
        DoneLog.observe(projectPath: folder, rawText: notes("- [x] Old\n- [ ] New"))
        XCTAssertEqual(DoneLog.events(projectPath: folder).count, 0)
        DoneLog.observe(projectPath: folder, rawText: notes("- [x] Old\n- [x] New"))
        XCTAssertEqual(DoneLog.events(projectPath: folder).map(\.text), ["New"])
    }

    func testLookingTwiceAtTheSameThingLogsOnce() {
        DoneLog.observe(projectPath: folder, rawText: notes("- [ ] A"))
        DoneLog.observe(projectPath: folder, rawText: notes("- [x] A"))
        DoneLog.observe(projectPath: folder, rawText: notes("- [x] A"))
        XCTAssertEqual(DoneLog.events(projectPath: folder).count, 1)
    }

    // MARK: Through the binary

    private static var pmBinaryPath: String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
        return (root as NSString).appendingPathComponent(".build/debug/pm")
    }
    private var haveBinary: Bool { FileManager.default.isExecutableFile(atPath: Self.pmBinaryPath) }
    private var env: [String: String] = [:]
    private var configDir = ""
    private var active = ""

    private func vault() {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        configDir = (tmp as NSString).appendingPathComponent("config")
        active = (tmp as NSString).appendingPathComponent("active")
        let archive = (tmp as NSString).appendingPathComponent("archive")
        for path in [configDir, active, archive] {
            try? fm.createDirectory(atPath: path, withIntermediateDirectories: true)
        }
        let config: [String: Any] = ["activePath": active, "archivePath": archive,
                                     "domains": ["W": "Work"], "subfolders": ["docs"]]
        try? JSONSerialization.data(withJSONObject: config)
            .write(to: URL(fileURLWithPath: (configDir as NSString).appendingPathComponent("config.json")))
        env = ["PM_CONFIG_HOME": configDir, "PM_ACTIVE_PATH": active, "PM_ARCHIVE_PATH": archive]
        call("project.create", ["title": "Redesign", "domain": "W"])
        for text in ["Review the contract", "Book the venue"] {
            call("task.add", ["project": "W-1", "text": text])
        }
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

    private func reference(_ text: String) -> [String: Any] {
        let todos = call("task.list", ["project": "W-1", "includeCompleted": true])["data"] as? [[String: Any]] ?? []
        let todo = todos.first { $0["text"] as? String == text } ?? [:]
        return ["session": todo["sessionISODate"] as Any, "line": todo["lineIndex"] as Any,
                "digest": todo["digest"] as Any]
    }

    private func done(_ input: [String: Any] = [:]) -> [String] {
        (call("task.done", input)["data"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
    }

    func testACompletionThroughTheContractIsReported() throws {
        try XCTSkipUnless(haveBinary)
        vault()
        XCTAssertEqual(done(), [])
        call("task.complete", ["project": "W-1", "task": reference("Review the contract")])
        XCTAssertEqual(done(), ["Review the contract"])
        XCTAssertEqual(call("task.done")["summary"] as? String, "1 task done.")
    }

    /// Ticked by hand, in a file PM didn't write. The report looks before it answers.
    func testATickMadeOutsidePMIsReported() throws {
        try XCTSkipUnless(haveBinary)
        vault()
        let project = try XCTUnwrap(FileManager.default.contentsOfDirectory(atPath: active).first)
        let path = try XCTUnwrap(resolveNotesPath(projectPath: (active as NSString).appendingPathComponent(project)))
        let text = try String(contentsOfFile: path, encoding: .utf8)
        try text.replacingOccurrences(of: "- [ ] Book the venue", with: "- [x] Book the venue")
            .write(toFile: path, atomically: true, encoding: .utf8)
        XCTAssertEqual(done(["period": "week"]), ["Book the venue"])
    }

    func testReopeningTakesItBackOut() throws {
        try XCTSkipUnless(haveBinary)
        vault()
        call("task.complete", ["project": "W-1", "task": reference("Book the venue")])
        call("task.reopen", ["project": "W-1", "task": reference("Book the venue")])
        XCTAssertEqual(done(), [])
    }

    /// Deleting a finished task doesn't un-finish it.
    func testDeletedWorkStillCounts() throws {
        try XCTSkipUnless(haveBinary)
        vault()
        call("task.complete", ["project": "W-1", "task": reference("Book the venue")])
        call("task.delete", ["project": "W-1", "task": reference("Book the venue")])
        XCTAssertEqual(done(), ["Book the venue"])
    }

    func testOutOfRangeIsLeftOut() throws {
        try XCTSkipUnless(haveBinary)
        vault()
        call("task.complete", ["project": "W-1", "task": reference("Book the venue")])
        XCTAssertEqual(done(["since": "2020-01-01", "until": "2020-01-31"]), [])
    }
}
