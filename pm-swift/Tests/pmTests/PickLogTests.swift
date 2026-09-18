import XCTest
import Foundation
@testable import PmLib

/// Picking up: an old task drawn in today's sitting without moving its line. See docs/sessions.md D2.
final class PickLogTests: XCTestCase {

    // MARK: The rules, without a file

    /// Today, and a sitting from two weeks ago that left two tasks open. Newest first, as a document
    /// holds them.
    private let doc = """
    # Redesign

    ## Sessions

    ### Thu, Sep 17, 2026

    Picking the venue back up.

    ### Wed, Sep 2, 2026

    Called about the venue; Dana has the shortlist.

    - [ ] Email Dana
    - [ ] Book the venue

    """

    private func read(_ markdown: String) throws -> (notes: ProjectNotes, todos: [Todo]) {
        let notes = normalizeFocusMarker(notes: try parseNotes(markdown: markdown))
        return (notes, try parseTodos(notes: notes))
    }

    /// A pick of `text` into the sitting at `into`, as the dispatcher would write it.
    private func pick(_ text: String, into: Int, in markdown: String, id: String,
                      at: String = "2026-09-17T15:00:00Z") throws -> PickEvent {
        let (notes, todos) = try read(markdown)
        let todo = try XCTUnwrap(todos.first { $0.text == text })
        return PickEvent(id: id, at: at, event: .picked,
                         task: try XCTUnwrap(PickLog.task(todo, in: notes)),
                         into: try XCTUnwrap(PickLog.sitting(at: into, in: notes)))
    }

    private func resolve(_ events: [PickEvent], in markdown: String) throws -> [PickLog.Resolved] {
        let (notes, todos) = try read(markdown)
        return PickLog.resolve(PickLog.standing(events), notes: notes, todos: todos)
    }

    func testAPickIsDrawnInTheSittingThatPickedItUp() throws {
        let picks = try resolve([try pick("Email Dana", into: 0, in: doc, id: "p1")], in: doc)
        XCTAssertEqual(picks.count, 1)
        XCTAssertEqual(picks.first?.sessionIndex, 1, "The task is still where it was written")
        XCTAssertEqual(picks.first?.lineIndex, 0)
        XCTAssertEqual(picks.first?.intoIndex, 0, "…and drawn in today's sitting")
    }

    /// The shift every reference in this app is built to survive: a sitting started above both.
    func testAPickSurvivesASittingSplicedInAbove() throws {
        let event = try pick("Email Dana", into: 0, in: doc, id: "p1")
        let later = doc.replacingOccurrences(of: "## Sessions\n\n",
                                             with: "## Sessions\n\n### Fri, Sep 18, 2026\n\n")
        let picks = try resolve([event], in: later)
        XCTAssertEqual(picks.first?.sessionIndex, 2)
        XCTAssertEqual(picks.first?.intoIndex, 1)
    }

    /// Put Back, or undo, takes back one pick — not the same task's pick into another sitting.
    func testAReleaseCancelsOnlyThePickItNames() throws {
        let three = doc.replacingOccurrences(of: "### Wed, Sep 2, 2026",
                                             with: "### Wed, Sep 16, 2026\n\nYesterday.\n\n### Wed, Sep 2, 2026")
        let yesterday = try pick("Email Dana", into: 1, in: three, id: "p1", at: "2026-09-16T10:00:00Z")
        let today = try pick("Email Dana", into: 0, in: three, id: "p2")
        let putBack = PickEvent(id: "r1", at: "2026-09-17T16:00:00Z", event: .released,
                                task: today.task, into: today.into, reverses: "p2")
        let picks = try resolve([yesterday, today, putBack], in: three)
        XCTAssertEqual(picks.map(\.event.id), ["p1"])
        XCTAssertEqual(picks.first?.intoIndex, 1, "Yesterday's pick still stands")
    }

    /// A release with no name — hand-written, or from an older writer — takes back the latest pick of
    /// the same task into the same sitting, the way a reopening takes back the latest completion.
    func testAnUnnamedReleaseCancelsTheLatestMatchingPick() throws {
        let first = try pick("Email Dana", into: 0, in: doc, id: "p1")
        let other = try pick("Book the venue", into: 0, in: doc, id: "p2")
        let release = PickEvent(id: "r1", at: "2026-09-17T16:00:00Z", event: .released,
                                task: first.task, into: first.into)
        XCTAssertEqual(try resolve([first, other, release], in: doc).map(\.event.id), ["p2"])
    }

    /// Renamed in Obsidian, the task no longer carries the digest the pick names. It stops being drawn —
    /// no error, and no guess at which task it might have become.
    func testAStalePickDropsOutQuietly() throws {
        let event = try pick("Email Dana", into: 0, in: doc, id: "p1")
        let renamed = doc.replacingOccurrences(of: "Email Dana", with: "Email Dana the shortlist")
        XCTAssertEqual(try resolve([event], in: renamed), [])

        let sittingGone = doc.replacingOccurrences(of: "### Thu, Sep 17, 2026\n\nPicking the venue back up.\n\n",
                                                   with: "")
        XCTAssertEqual(try resolve([event], in: sittingGone), [], "Its sitting was deleted")
    }

    /// A rename through PM appends `retargeted`, and the pick follows the new text.
    func testARetargetCarriesAPickThroughARename() throws {
        let event = try pick("Email Dana", into: 0, in: doc, id: "p1")
        let renamed = doc.replacingOccurrences(of: "Email Dana", with: "Email Dana the shortlist")
        var task = event.task
        task.text = "Email Dana the shortlist"
        let retarget = PickEvent(id: "t1", at: "2026-09-17T15:30:00Z", event: .retargeted, task: task,
                                 retargets: ["p1"], to: taskDigest("Email Dana the shortlist"))
        let picks = try resolve([event, retarget], in: renamed)
        XCTAssertEqual(picks.map(\.event.id), ["p1"])
        XCTAssertEqual(picks.first?.event.task.text, "Email Dana the shortlist")
    }

    /// Every task read says whether the task was picked up, and where into; the read lists the picks.
    func testAReadCarriesItsPicks() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: folder) }
        try PickLog.append([try pick("Email Dana", into: 0, in: doc, id: "p1")], projectPath: folder)

        let read = try notesShow(rawText: doc, projectPath: folder)
        XCTAssertEqual(read.todos.first { $0.text == "Email Dana" }?.picked,
                       PickMark(into: "2026-09-17", at: "2026-09-17T15:00:00Z"))
        XCTAssertNil(read.todos.first { $0.text == "Book the venue" }?.picked)
        XCTAssertEqual(read.picks.map(\.id), ["p1"])

        // And the same log against a document where the pick no longer resolves is simply a read with
        // nothing picked up.
        let stale = try notesShow(rawText: doc.replacingOccurrences(of: "Email Dana", with: "Email Sam"),
                                  projectPath: folder)
        XCTAssertEqual(stale.picks, [])
        XCTAssertTrue(stale.todos.allSatisfy { $0.picked == nil })
    }

    func testTheLogIsOneEventPerLineAndSkipsWhatItCantRead() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: folder) }
        try PickLog.append([try pick("Email Dana", into: 0, in: doc, id: "p1")], projectPath: folder)
        let handle = try XCTUnwrap(FileHandle(forWritingAtPath: PickLog.logPath(projectPath: folder)))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("not json\n".utf8))
        try handle.close()
        try PickLog.append([try pick("Book the venue", into: 0, in: doc, id: "p2")], projectPath: folder)
        XCTAssertEqual(PickLog.events(projectPath: folder).map(\.id), ["p1", "p2"])
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

    /// A project with a task in today's sitting and two left open in one from two weeks ago.
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
        // Appended: `## Sessions` is the last section and sittings run newest first, so the end of the
        // file is the oldest one.
        let text = try String(contentsOfFile: notesPath, encoding: .utf8)
        try (text + "\n### Wed, Sep 2, 2026\n\nCalled about the venue.\n\n- [ ] Email Dana\n- [ ] Book the venue\n")
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

    private func picked(_ text: String) -> [String: Any]? {
        tasks().first { $0["text"] as? String == text }?["picked"] as? [String: Any]
    }

    private var today: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    func testPickingUpLeavesTheTaskWhereItWasWritten() throws {
        try XCTSkipUnless(haveBinary)
        try vault()
        let before = try String(contentsOfFile: notesPath, encoding: .utf8)
        let result = call("task.pick", ["project": "W-1", "task": reference("Email Dana")])
        XCTAssertEqual(result["summary"] as? String, "Picked up \u{201C}Email Dana\u{201D}.")
        XCTAssertEqual(try String(contentsOfFile: notesPath, encoding: .utf8), before,
                       "The notes are exactly as they were")
        XCTAssertEqual(picked("Email Dana")?["into"] as? String, today)
        XCTAssertNil(picked("Book the venue"))
    }

    func testPickingUpWhatIsAlreadyHereIsAFinding() throws {
        try XCTSkipUnless(haveBinary)
        try vault()
        let here = call("task.pick", ["project": "W-1", "task": reference("Review the contract")])
        XCTAssertEqual(here["summary"] as? String, "That task is already in this session.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: PickLog.logPath(projectPath: projectPath)),
                       "Nothing to record, so no log")

        call("task.pick", ["project": "W-1", "task": reference("Email Dana")])
        let again = call("task.pick", ["project": "W-1", "task": reference("Email Dana")])
        XCTAssertEqual(again["summary"] as? String, "That task is already picked up.")
        XCTAssertEqual(PickLog.events(projectPath: projectPath).count, 1)
    }

    func testPickingUpASelectionSaysTheCount() throws {
        try XCTSkipUnless(haveBinary)
        try vault()
        let result = call("task.pick", ["project": "W-1",
                                        "tasks": [reference("Email Dana"), reference("Book the venue")]])
        XCTAssertEqual(result["summary"] as? String, "Picked up 2 tasks.")
        XCTAssertNotNil(picked("Email Dana"))
        XCTAssertNotNil(picked("Book the venue"))
    }

    func testPuttingBackTakesThePickAwayAndLeavesTheTask() throws {
        try XCTSkipUnless(haveBinary)
        try vault()
        call("task.pick", ["project": "W-1", "task": reference("Email Dana")])
        let result = call("task.release", ["project": "W-1", "task": reference("Email Dana")])
        XCTAssertEqual(result["summary"] as? String, "Put back \u{201C}Email Dana\u{201D}.")
        XCTAssertNil(picked("Email Dana"))
        XCTAssertNotNil(tasks().first { $0["text"] as? String == "Email Dana" })

        let again = call("task.release", ["project": "W-1", "task": reference("Email Dana")])
        XCTAssertEqual(again["summary"] as? String, "That task isn't picked up.")
    }

    /// A rename through PM keeps the pick; the same rename made by hand would lose it.
    func testARenameThroughPMKeepsItsPick() throws {
        try XCTSkipUnless(haveBinary)
        try vault()
        call("task.pick", ["project": "W-1", "task": reference("Email Dana")])
        call("task.setText", ["project": "W-1", "task": reference("Email Dana"),
                              "text": "Email Dana the shortlist"])
        XCTAssertEqual(picked("Email Dana the shortlist")?["into"] as? String, today)
        XCTAssertEqual(PickLog.events(projectPath: projectPath).map(\.event), [.picked, .retargeted])

        // Renaming a task nobody picked up writes nothing to the log.
        call("task.setText", ["project": "W-1", "task": reference("Book the venue"), "text": "Book a venue"])
        XCTAssertEqual(PickLog.events(projectPath: projectPath).count, 2)
    }

    /// Coming back to a project after the idle window starts a new sitting, and a pick is what started
    /// it — the one change to the notes a pick makes.
    func testPickingUpInAColdProjectStartsASitting() throws {
        try XCTSkipUnless(haveBinary)
        try vault()
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-6 * 3600)],
                                              ofItemAtPath: notesPath)
        let headings = { try String(contentsOfFile: self.notesPath, encoding: .utf8)
            .components(separatedBy: "\n").filter { $0.hasPrefix("### ") }.count }
        let before = try headings()
        let result = call("task.pick", ["project": "W-1", "task": reference("Email Dana")])
        XCTAssertEqual(result["summary"] as? String, "Picked up \u{201C}Email Dana\u{201D}.")
        XCTAssertEqual(try headings(), before + 1)
        let data = result["data"] as? [String: Any]
        XCTAssertEqual(data?["intoIndex"] as? Int, 0, "Into the sitting it just started")
    }

    /// Nothing picked, nothing started: a cold project asked to pick up a selection that has since
    /// gone doesn't get an empty heading for its trouble.
    func testAPickThatPicksNothingStartsNothing() throws {
        try XCTSkipUnless(haveBinary)
        try vault()
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-6 * 3600)],
                                              ofItemAtPath: notesPath)
        let before = try String(contentsOfFile: notesPath, encoding: .utf8)
        var gone = reference("Email Dana")
        gone["digest"] = "deadbeef"
        call("task.pick", ["project": "W-1", "tasks": [gone]])
        XCTAssertEqual(try String(contentsOfFile: notesPath, encoding: .utf8), before)
    }
    // MARK: Focus picks up (D3), and undo takes it back (D4)

    private func focused() -> String? {
        tasks().first { $0["isFocused"] as? Bool == true }?["text"] as? String
    }

    func testFocusingAnOldTaskPicksItUp() throws {
        try XCTSkipUnless(haveBinary)
        try vault()
        let result = call("task.focus", ["project": "W-1", "task": reference("Email Dana")])
        XCTAssertEqual(result["summary"] as? String, "Picked up and focused \u{201C}Email Dana\u{201D}.")
        XCTAssertEqual(focused(), "Email Dana")
        XCTAssertEqual(picked("Email Dana")?["into"] as? String, today)
        XCTAssertEqual((result["sidecar"] as? [[String: Any]])?.count, 1,
                       "The result names what it appended, so the app can take it back")
    }

    func testFocusingWithoutPickIsOnlyNavigation() throws {
        try XCTSkipUnless(haveBinary)
        try vault()
        call("task.focus", ["project": "W-1", "task": reference("Email Dana"), "pick": false])
        XCTAssertEqual(focused(), "Email Dana")
        XCTAssertNil(picked("Email Dana"))
    }

    func testFocusingATaskAlreadyHerePicksNothingUp() throws {
        try XCTSkipUnless(haveBinary)
        try vault()
        let result = call("task.focus", ["project": "W-1", "task": reference("Review the contract")])
        XCTAssertNil(result["sidecar"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: PickLog.logPath(projectPath: projectPath)))
    }

    /// The whole gesture, reversed as one: focus goes back and the pick is released.
    func testUndoingAFocusThatPickedUpTakesBothBack() throws {
        try XCTSkipUnless(haveBinary)
        try vault()
        let focusBefore = focused()
        call("task.focus", ["project": "W-1", "task": reference("Email Dana")])
        let undone = call("journal.undo", ["project": "W-1"])
        XCTAssertNotNil(undone["revision"], "\(undone)")
        XCTAssertEqual(focused(), focusBefore)
        XCTAssertNil(picked("Email Dana"))
        XCTAssertEqual(PickLog.events(projectPath: projectPath).map(\.event), [.picked, .released])
    }

    /// A pick with no document change behind it is still reversible from another surface.
    func testUndoingAPickThatChangedNoNotesReleasesIt() throws {
        try XCTSkipUnless(haveBinary)
        try vault()
        call("task.pick", ["project": "W-1", "task": reference("Email Dana")])
        let undone = call("journal.undo", ["project": "W-1"])
        XCTAssertEqual(undone["summary"] as? String, "Reversed: Picked up \u{201C}Email Dana\u{201D}.", "\(undone)")
        XCTAssertNil(picked("Email Dana"))

        // And reversing the reversal picks it up again, as a new event.
        let entries = call("journal.list", ["project": "W-1"])["data"] as? [[String: Any]] ?? []
        let reversal = try XCTUnwrap(entries.first?["id"] as? String)
        call("journal.undo", ["entry": reversal])
        XCTAssertEqual(picked("Email Dana")?["into"] as? String, today)
        let events = PickLog.events(projectPath: projectPath)
        XCTAssertEqual(events.map(\.event), [.picked, .released, .picked])
        XCTAssertEqual(Set(events.map(\.id)).count, 3)
    }

    /// All or nothing: when the file has moved on, the document half is refused and the pick stays.
    func testAnUndoTheDocumentRefusesLeavesThePickAlone() throws {
        try XCTSkipUnless(haveBinary)
        try vault()
        call("task.focus", ["project": "W-1", "task": reference("Email Dana")])
        let text = try String(contentsOfFile: notesPath, encoding: .utf8)
        try (text + "\nA line written in Obsidian.\n").write(toFile: notesPath, atomically: true, encoding: .utf8)
        let refused = call("journal.undo", ["project": "W-1"])
        XCTAssertEqual((refused["error"] as? [String: Any])?["code"] as? String, "conflict", "\(refused)")
        XCTAssertEqual(picked("Email Dana")?["into"] as? String, today)
        XCTAssertEqual(PickLog.events(projectPath: projectPath).count, 1)
    }

    /// Undoing a rename puts the pick back on the old words, so it keeps being drawn.
    func testUndoingARenameKeepsThePick() throws {
        try XCTSkipUnless(haveBinary)
        try vault()
        call("task.pick", ["project": "W-1", "task": reference("Email Dana")])
        call("task.setText", ["project": "W-1", "task": reference("Email Dana"), "text": "Email Dana today"])
        call("journal.undo", ["project": "W-1"])
        XCTAssertEqual(picked("Email Dana")?["into"] as? String, today)
    }

    func testReversingIsTheMirrorOfEachEvent() throws {
        let picked = try pick("Email Dana", into: 0, in: doc, id: "p1")
        let released = PickEvent(id: "r1", at: "t", event: .released, task: picked.task, into: picked.into,
                                 reverses: "p1")
        var renamedTask = picked.task
        renamedTask.digest = "old"
        let retargeted = PickEvent(id: "t1", at: "t", event: .retargeted, task: renamedTask,
                                   retargets: ["p1"], to: "new")
        let back = PickLog.reversing([picked, released, retargeted], source: "app", at: "now")
        XCTAssertEqual(back.map(\.event), [.retargeted, .picked, .released], "Newest first")
        XCTAssertEqual(back[0].task.digest, "new")
        XCTAssertEqual(back[0].to, "old")
        XCTAssertEqual(back[0].retargets, ["p1"])
        XCTAssertNotEqual(back[1].id, "p1", "A pick restored is a new event")
        XCTAssertEqual(back[2].reverses, "p1")
    }
}
