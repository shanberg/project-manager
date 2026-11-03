import XCTest
import Foundation
@testable import PmLib

/// `time.count` and `time.aways` through the contract, against a vault and a log of their own.
/// See docs/away-time.md.
final class TimeCountTests: XCTestCase {
    private var root: URL!
    private var savedConfigHome: String?
    private var projects: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        projects = root.appendingPathComponent("Projects")
        let archive = root.appendingPathComponent("Archive")
        let areas = root.appendingPathComponent("Areas")
        for dir in [projects!, archive, areas] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try FileManager.default.createDirectory(at: projects.appendingPathComponent("W-001 Website"),
                                                withIntermediateDirectories: true)
        savedConfigHome = ProcessInfo.processInfo.environment["PM_CONFIG_HOME"]
        setenv("PM_CONFIG_HOME", root.path, 1)
        // No real transcript may lend evidence to a test's aways.
        setenv("PM_AGENT_TRANSCRIPTS", root.appendingPathComponent("transcripts").path, 1)
        try saveConfig(PmConfig(activePath: projects.path, archivePath: archive.path,
                                areasPath: areas.path, domains: ["W": "Work"], subfolders: ["docs"]))
    }

    override func tearDownWithError() throws {
        if let saved = savedConfigHome { setenv("PM_CONFIG_HOME", saved, 1) } else { unsetenv("PM_CONFIG_HOME") }
        unsetenv("PM_AGENT_TRANSCRIPTS")
        try? FileManager.default.removeItem(at: root)
    }

    /// 9:00 on 2026-09-01, in the machine's zone — a day that's safely past.
    private func at(_ hour: Int, _ minute: Int = 0) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 1, hour: hour, minute: minute))!
    }

    private func count(_ from: Date, _ to: Date, project: String? = nil, notWork: Bool? = nil,
                       dryRun: Bool = false) throws -> ApiResult {
        var input = ApiInput()
        input.from = DoneLog.timestamp(from)
        input.to = DoneLog.timestamp(to)
        input.project = project
        input.notWork = notWork
        return try performApi("time.count", input, options: ApiOptions(dryRun: dryRun, source: "test"))
    }

    private func decode<T: Decodable>(_ type: T.Type, _ value: JSONValue) throws -> T {
        try JSONDecoder().decode(type, from: JSONEncoder().encode(value))
    }

    // MARK: time.count

    func testCountingWritesOneAnswerSpelledLikeFocus() throws {
        let result = try count(at(11), at(11, 30), project: "W-001")
        XCTAssertEqual(result.summary.hasPrefix("Counted "), true, result.summary)
        let events = AttentionLog.events()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.event, .counted)
        XCTAssertEqual(events.first?.project, "W-001 Website")
        XCTAssertEqual(events.first?.key, "\(projects.path):W-001 Website", "the key project.focus writes")
        XCTAssertEqual(events.first?.from, DoneLog.timestamp(at(11)))
        XCTAssertEqual(events.first?.source, "test")
        XCTAssertEqual(result.data.flatMap { try? decode(AttentionEvent.self, $0) }?.id, events.first?.id,
                       "the event comes back, so undo can name it")
    }

    func testNotWorkWritesAnAnswerWithNoProject() throws {
        let result = try count(at(11), at(11, 30), notWork: true)
        let event = try XCTUnwrap(AttentionLog.events().first)
        XCTAssertEqual(result.data.flatMap { try? decode(AttentionEvent.self, $0) }?.id, event.id,
                       "returned for undo, like a project answer")
        XCTAssertEqual(event.event, .counted)
        XCTAssertNil(event.project)
        XCTAssertNil(event.key)
    }

    func testADryRunWritesNothing() throws {
        let result = try count(at(11), at(11, 30), project: "W-001", dryRun: true)
        XCTAssertTrue(result.summary.hasPrefix("Would count "), result.summary)
        XCTAssertEqual(AttentionLog.events(), [])
    }

    /// `notWork: false` and no project gets past the one-of check and says nothing.
    func testNotWorkFalseIsNotAnAnswer() {
        XCTAssertThrowsError(try count(at(11), at(11, 30), notWork: false)) { error in
            XCTAssertEqual((error as? ApiError)?.code, .missingField)
        }
    }

    func testTheStretchMustRunForwardAndHaveHappened() {
        XCTAssertThrowsError(try count(at(11, 30), at(11), project: "W-001"))
        XCTAssertThrowsError(try count(at(11), at(11), project: "W-001"))
        XCTAssertThrowsError(try count(Date(), Date().addingTimeInterval(3600), project: "W-001")) { error in
            XCTAssertEqual((error as? ApiError)?.detail, .string("to"))
        }
        XCTAssertEqual(AttentionLog.events(), [])
    }

    func testATimeWithoutAZoneIsRefused() {
        var input = ApiInput()
        input.from = "2026-09-01T11:00"
        input.to = "2026-09-01T11:30:00Z"
        input.project = "W-001"
        XCTAssertThrowsError(try performApi("time.count", input)) { error in
            XCTAssertEqual((error as? ApiError)?.code, .invalidField)
            XCTAssertEqual((error as? ApiError)?.detail, .string("from"))
        }
    }

    // MARK: time.aways

    private func aways(_ input: ApiInput = ApiInput()) throws -> [AttentionAway] {
        var input = input
        input.since = "2026-09-01"
        input.until = "2026-09-01"
        let result = try performApi("time.aways", input)
        return try decode([AttentionAway].self, XCTUnwrap(result.data))
    }

    private func edge(_ kind: AttentionEvent.Kind, _ when: Date, why: String? = nil) -> AttentionEvent {
        AttentionEvent(at: DoneLog.timestamp(when), event: kind, project: "W-001 Website",
                       key: "\(projects.path):W-001 Website", why: why)
    }

    /// The round trip the menubar will make: list, answer, and it's gone.
    func testAnAnsweredAwayLeavesTheList() throws {
        AttentionLog.append([edge(.began, at(9)), edge(.ended, at(10), why: "paused"),
                             edge(.began, at(10, 40), why: "resumed")])
        let listed = try aways()
        XCTAssertEqual(listed.count, 1)
        let away = try XCTUnwrap(listed.first)
        XCTAssertEqual(away.project, "W-001 Website")

        var input = ApiInput()
        input.from = away.from
        input.to = away.to
        input.project = "W-001"
        _ = try performApi("time.count", input)
        XCTAssertEqual(try aways(), [])

        let report = try timeSpent(in: try DoneRange.resolve(period: nil, since: "2026-09-01", until: "2026-09-01"),
                                   now: at(11))
        XCTAssertTrue(report.projects.first?.counted ?? false, "the report says some of it was counted")
        XCTAssertEqual(Int((report.seconds / 60).rounded()), 120)
    }

    func testAwaysFilterByTheProjectTheyInterrupted() throws {
        AttentionLog.append([edge(.began, at(9)), edge(.ended, at(10), why: "paused"),
                             edge(.began, at(10, 40), why: "resumed")])
        var mine = ApiInput()
        mine.projects = ["W-001"]
        XCTAssertEqual(try aways(mine).count, 1)
    }

    // MARK: The menu bar's one

    func testTheLatestAwayIsTodaysNewestUnanswered() {
        let day = Calendar.current.startOfDay(for: Date())
        func today(_ h: Int, _ m: Int = 0) -> Date { day.addingTimeInterval(Double(h * 3600 + m * 60)) }
        let yesterday = today(0).addingTimeInterval(-3 * 3600)
        AttentionLog.append([edge(.began, yesterday), edge(.ended, yesterday.addingTimeInterval(600), why: "paused"),
                             edge(.began, yesterday.addingTimeInterval(3000), why: "resumed"),
                             edge(.ended, today(9), why: "paused"), edge(.began, today(9, 30), why: "resumed"),
                             edge(.ended, today(11), why: "paused"), edge(.began, today(11, 40), why: "resumed")])
        let now = today(12)
        XCTAssertEqual(latestAway(now: now)?.fromDate, today(11))

        // Straight to the log: `time.count` would refuse a stretch later than the real clock.
        AttentionLog.counted(from: today(11), to: today(11, 40))
        XCTAssertEqual(latestAway(now: now)?.fromDate, today(9), "answered, so the one before it")
    }

    // MARK: Typing a moment

    func testMomentsAsTheyAreTyped() {
        let day = at(15)
        XCTAssertEqual(parseMoment("11:07", now: day), at(11, 7))
        XCTAssertEqual(parseMoment("14:05", now: day), at(14, 5))
        XCTAssertEqual(parseMoment("2:05pm", now: day), at(14, 5))
        XCTAssertEqual(parseMoment("2:05 PM", now: day), at(14, 5))
        XCTAssertEqual(parseMoment("12:30am", now: day), at(0, 30))
        XCTAssertEqual(parseMoment("12:30pm", now: day), at(12, 30))
        XCTAssertEqual(parseMoment(DoneLog.timestamp(at(9)), now: day), at(9), "ISO with a zone")
    }

    func testMomentsThatArentOne() {
        for text in ["noon", "25:00", "13:00pm", "0:30am", "11:7", "11:60", "11", "", "2026-09-01T11:00"] {
            XCTAssertNil(parseMoment(text, now: at(15)), text)
        }
    }
}

/// Reading the tail of the attention log, for a period near now, without reading it all.
final class AttentionLogTailTests: XCTestCase {
    private var root: URL!
    private var savedConfigHome: String?

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        savedConfigHome = ProcessInfo.processInfo.environment["PM_CONFIG_HOME"]
        setenv("PM_CONFIG_HOME", root.path, 1)
        // No real transcript may lend evidence to a test's aways.
        setenv("PM_AGENT_TRANSCRIPTS", root.appendingPathComponent("transcripts").path, 1)
    }

    override func tearDownWithError() throws {
        if let saved = savedConfigHome { setenv("PM_CONFIG_HOME", saved, 1) } else { unsetenv("PM_CONFIG_HOME") }
        unsetenv("PM_AGENT_TRANSCRIPTS")
        try? FileManager.default.removeItem(at: root)
    }

    private let start = Date(timeIntervalSince1970: 1_780_000_000)

    /// A day of a minute-by-minute log: far more than one chunk.
    private func writeLog(minutes: Int) {
        AttentionLog.append((0..<minutes).map { minute in
            AttentionEvent(at: DoneLog.timestamp(start.addingTimeInterval(Double(minute) * 60)),
                           event: minute.isMultiple(of: 2) ? .began : .ended, project: "W-1",
                           key: "/P:W-1", why: minute.isMultiple(of: 2) ? nil : "paused")
        })
    }

    func testTheTailIsExactlyWhatTheWholeLogSaysAfterTheCutoff() {
        writeLog(minutes: 1_500)
        for (cutoffMinute, chunk) in [(1_490, 512), (1_000, 512), (400, 4_096), (0, 700), (1_499, 64 * 1024)] {
            let cutoff = start.addingTimeInterval(Double(cutoffMinute) * 60)
            let whole = AttentionLog.events().filter { DoneLog.date($0.at)! >= cutoff }
            XCTAssertEqual(AttentionLog.events(since: cutoff, chunk: chunk), whole,
                           "cutoff \(cutoffMinute), chunk \(chunk)")
        }
    }

    /// Lines at the very start of the file that claim to be recent: a reader that went all the way
    /// back would return them, and one that stops once it's past the cutoff never sees them.
    func testItStopsReadingOnceItsPastTheCutoff() {
        let late = start.addingTimeInterval(10_000 * 60)
        AttentionLog.append((0..<5).map { _ in
            AttentionEvent(at: DoneLog.timestamp(late), event: .began, project: "W-9", key: "/P:W-9")
        })
        writeLog(minutes: 1_500)
        let cutoff = start.addingTimeInterval(1_490 * 60)
        XCTAssertEqual(AttentionLog.events().filter { DoneLog.date($0.at)! >= cutoff }.count, 15,
                       "a whole read finds the stale lines")
        XCTAssertEqual(AttentionLog.events(since: cutoff, chunk: 512).count, 10)
    }

    func testAnEmptyOrMissingLogIsNothing() {
        XCTAssertEqual(AttentionLog.events(since: start), [])
        AttentionLog.append([])
        XCTAssertEqual(AttentionLog.events(since: start), [])
    }
}

// MARK: - Count as a sitting, and the folders an answer claims

extension TimeCountTests {
    private var notesURL: URL {
        projects.appendingPathComponent("W-001 Website/docs/Notes - Website.md")
    }

    private func writeNotes(_ sessions: [String] = ["### Tue, Sep 1, 2026 4:00 PM", "Afternoon.",
                                                    "", "### Tue, Sep 1, 2026 9:00 AM", "Morning."]) throws {
        try FileManager.default.createDirectory(at: notesURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try (["---", "pm-color: blue", "---", "# Website", "", "## Sessions", ""] + sessions + [""])
            .joined(separator: "\n").write(to: notesURL, atomically: true, encoding: .utf8)
    }

    private func notes() throws -> String { try String(contentsOf: notesURL, encoding: .utf8) }

    private func headings() throws -> [String] {
        try notes().components(separatedBy: "\n").filter { $0.hasPrefix("### ") }
    }

    /// A Claude Code transcript in the test's transcripts folder, busy every minute of `from`..<`to`.
    private func transcript(_ folder: String, _ from: Date, _ to: Date) throws {
        let dir = root.appendingPathComponent("transcripts/x")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let lines = stride(from: from.timeIntervalSince1970, to: to.timeIntervalSince1970, by: 60).map {
            #"{"type":"assistant","cwd":"\#(folder)","timestamp":"\#(DoneLog.timestamp(Date(timeIntervalSince1970: $0)))"}"#
        }
        let url = dir.appendingPathComponent(UUID().uuidString + ".jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.creationDate: from], ofItemAtPath: url.path)
    }

    private func countAsSitting(_ from: Date, _ to: Date, dryRun: Bool = false) throws -> ApiResult {
        var input = ApiInput()
        input.from = DoneLog.timestamp(from)
        input.to = DoneLog.timestamp(to)
        input.project = "W-001"
        input.sitting = true
        return try performApi("time.count", input, options: ApiOptions(dryRun: dryRun, source: "test"))
    }

    func testASittingIsPlacedAmongTheOthersByTime() throws {
        try writeNotes()
        let result = try countAsSitting(at(11), at(12, 30))
        XCTAssertEqual(try headings(), ["### Tue, Sep 1, 2026 4:00 PM", "### Tue, Sep 1, 2026 11:00 AM",
                                        "### Tue, Sep 1, 2026 9:00 AM"])
        XCTAssertTrue(try notes().contains("### Tue, Sep 1, 2026 11:00 AM\n1h 30m counted.\n\n### Tue, Sep 1, 2026 9:00 AM"))
        XCTAssertTrue(result.summary.contains("as a session"), result.summary)
        XCTAssertEqual(AttentionLog.events().map(\.event), [.counted], "the time is counted as well")
        guard case .object(let fields)? = result.data else { return XCTFail("no data") }
        XCTAssertEqual(fields["session"].flatMap { if case .object(let s) = $0 { return s["index"] } else { return nil } },
                       .number(1))
        XCTAssertNotNil(try decode(AttentionEvent.self, XCTUnwrap(result.data)).id, "still decodes as the event")
    }

    func testASittingOlderThanEveryOtherGoesLast() throws {
        try writeNotes()
        _ = try countAsSitting(at(7), at(8))
        XCTAssertEqual(try headings().last, "### Tue, Sep 1, 2026 7:00 AM")
        XCTAssertTrue(try notes().hasSuffix("Morning.\n\n### Tue, Sep 1, 2026 7:00 AM\n1h counted.\n"))
    }

    func testADryRunSittingWritesNothing() throws {
        try writeNotes()
        let before = try notes()
        let result = try countAsSitting(at(11), at(12), dryRun: true)
        XCTAssertTrue(result.summary.hasPrefix("Would count "), result.summary)
        XCTAssertEqual(try notes(), before)
        XCTAssertEqual(AttentionLog.events(), [])
    }

    func testNotWorkCantBeASitting() throws {
        var input = ApiInput()
        input.from = DoneLog.timestamp(at(11))
        input.to = DoneLog.timestamp(at(12))
        input.notWork = true
        input.sitting = true
        XCTAssertThrowsError(try performApi("time.count", input)) { error in
            XCTAssertEqual((error as? ApiError)?.detail, .string("sitting"))
        }
        XCTAssertEqual(AttentionLog.events(), [])
    }

    /// Answering an away an unclaimed folder's agent was busy in gives the project that folder.
    func testAnAnswerClaimsTheFoldersNobodyHad() throws {
        try writeNotes()
        try transcript("/dev/designs", at(11), at(12))
        let result = try count(at(11), at(12), project: "W-001")
        XCTAssertTrue(result.summary.contains("gave it /dev/designs"), result.summary)
        let written = try notes()
        XCTAssertTrue(written.contains(#"pm-folders: ["/dev/designs"]"#), written)
        _ = try count(at(11), at(12), project: "W-001")
        XCTAssertEqual(projectAgentFolders(rawText: try notes()), ["/dev/designs"], "claimed once")
    }

    func testTheSittingSaysWhichFoldersWereBusy() throws {
        try writeNotes()
        try transcript("/dev/designs", at(11), at(12))
        _ = try countAsSitting(at(11), at(12))
        XCTAssertTrue(try notes().contains("### Tue, Sep 1, 2026 11:00 AM\n1h counted. Claude Code in /dev/designs.\n"))
    }

    /// A project with no notes isn't given a file just because an answer was counted for it.
    func testAPlainAnswerLeavesAProjectWithoutNotesAlone() throws {
        _ = try count(at(11), at(12), project: "W-001")
        XCTAssertFalse(FileManager.default.fileExists(atPath: notesURL.path))
    }

    // MARK: session.start at

    private func start(at moment: Date, label: String? = nil) throws -> ApiResult {
        var input = ApiInput()
        input.project = "W-001"
        input.at = DoneLog.timestamp(moment)
        input.label = label
        return try performApi("session.start", input)
    }

    func testStartingASessionAtATimePlacesIt() throws {
        try writeNotes()
        let result = try start(at: at(13, 5), label: "Review")
        XCTAssertEqual(try headings()[1], "### Tue, Sep 1, 2026 1:05 PM · Review")
        guard case .object(let fields)? = result.data else { return XCTFail("no data") }
        XCTAssertEqual(fields["index"], .number(1))
        XCTAssertEqual(fields["isoDate"], .string("2026-09-01"))
    }

    func testASessionCantStartInTheFuture() throws {
        try writeNotes()
        XCTAssertThrowsError(try start(at: Date().addingTimeInterval(3600))) { error in
            XCTAssertEqual((error as? ApiError)?.detail, .string("at"))
        }
    }

    /// Another day sorts by its date first: a sitting from last week goes below this week's.
    func testAnEarlierDaySortsBelow() throws {
        try writeNotes()
        _ = try start(at: Calendar.current.date(byAdding: .day, value: -3, to: at(22))!)
        XCTAssertEqual(try headings().last, "### Sat, Aug 29, 2026 10:00 PM")
    }
}
