import XCTest
import Foundation
@testable import PmLib

/// A day across projects: which sitting owns what, and the order they're told in. See docs/views.md D4,
/// D5 and D8.
final class SittingListTests: XCTestCase {
    /// Pinned, so "9:10 AM" is one moment whatever machine runs this.
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        return calendar
    }()

    private func moment(_ day: Int, _ hour: Int, _ minute: Int = 0, month: Int = 9) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }

    private func range(_ day: Int) -> DoneRange {
        DoneRange(start: moment(day, 0), end: moment(day + 1, 0))
    }

    private func event(_ kind: DoneEvent.Kind, _ text: String, _ at: Date) -> DoneEvent {
        DoneEvent(at: DoneLog.timestamp(at), event: kind, text: text, digest: taskDigest(text))
    }

    private func list(_ markdown: String, folder: String = "W-1 Redesign", events: [DoneEvent] = [],
                      picks: [PickEvent] = [], in range: DoneRange, notesModified: Date? = nil,
                      now: Date? = nil) throws -> SittingList {
        let notes = normalizeFocusMarker(notes: try parseNotes(markdown: markdown))
        let todos = try parseTodos(notes: notes)
        return sittings(projectFolder: folder, notes: notes, todos: todos,
                        picks: PickLog.resolve(PickLog.standing(picks), notes: notes, todos: todos),
                        doneEvents: events, in: range, notesModified: notesModified,
                        now: now ?? range.start, calendar: calendar)
    }

    private let twoSittings = """
    # Redesign

    ## Sessions

    ### Fri, Sep 18, 2026 2:15 PM · Afternoon

    Back on the spec.

    - [x] Draft the nav spec

    ### Fri, Sep 18, 2026 9:10 AM

    Came back to the nav.

    - [x] Email Dana
    - [ ] Book the venue
      - [ ] Call the second venue

    More after the list.

    """

    func testEachSittingCarriesItsTimeNameAndProse() throws {
        let day = try list(twoSittings, in: range(18))
        XCTAssertEqual(day.sittings.map(\.startTime), ["2:15 PM", "9:10 AM"], "As the file has them, before sorting")
        let afternoon = try XCTUnwrap(day.sittings.first)
        XCTAssertEqual(afternoon.name, "Afternoon")
        XCTAssertEqual(afternoon.session, "2026-09-18")
        XCTAssertEqual(afternoon.sessionOrdinal, 0)
        XCTAssertEqual(afternoon.startedAt, DoneLog.timestamp(moment(18, 14, 15)))
        let morning = day.sittings[1]
        XCTAssertEqual(morning.sessionOrdinal, 1)
        XCTAssertEqual(morning.prose, "Came back to the nav.\n\nMore after the list.",
                       "The task lines come out; the writing around them stays")
        XCTAssertEqual(morning.written.map(\.text), ["Email Dana", "Book the venue", "Call the second venue"])
        XCTAssertEqual(morning.written.map(\.depth), [0, 0, 1])
        XCTAssertEqual(morning.written.first?.ref?.session, "2026-09-18")
        XCTAssertEqual(morning.written.first?.ref?.sessionOrdinal, 1, "A ref that can act on the line")
    }

    /// The rule the done log needs: a completion belongs to the latest sitting that had begun by then.
    func testACompletionBelongsToTheSittingItFellIn() throws {
        let day = try list(twoSittings, events: [
            event(.completed, "Email Dana", moment(18, 10)),
            event(.completed, "Draft the nav spec", moment(18, 15)),
        ], in: range(18))
        XCTAssertEqual(day.sittings.first { $0.startTime == "9:10 AM" }?.finished.map(\.text), ["Email Dana"])
        XCTAssertEqual(day.sittings.first { $0.startTime == "2:15 PM" }?.finished.map(\.text), ["Draft the nav spec"])
        XCTAssertEqual(day.elsewhere, [])
    }

    /// A task written weeks ago and finished during today's sitting is today's sitting's work.
    func testAnOldTaskFinishedDuringASittingCountsForIt() throws {
        let doc = twoSittings + """
        ### Wed, Sep 2, 2026

        - [x] Renew the domain

        """
        let day = try list(doc, events: [event(.completed, "Renew the domain", moment(18, 14, 40))], in: range(18))
        let afternoon = try XCTUnwrap(day.sittings.first { $0.startTime == "2:15 PM" })
        XCTAssertEqual(afternoon.finished.map(\.text), ["Renew the domain"])
        XCTAssertEqual(afternoon.finished.first?.ref?.session, "2026-09-02", "Pointing at where the line is")
        XCTAssertEqual(day.sittings.count, 2, "Sep 2's sitting isn't in today's answer")
    }

    /// A tick before the day's first sitting began, in a project with no other sitting to own it.
    func testACompletionInNoSittingIsElsewhere() throws {
        let day = try list(twoSittings, events: [
            event(.completed, "Email Dana", moment(18, 8)),
            event(.dropped, "Book the venue", moment(18, 8, 30)),
        ], in: range(18))
        XCTAssertEqual(day.elsewhere.map(\.text), ["Email Dana", "Book the venue"])
        XCTAssertEqual(day.elsewhere.map(\.dropped), [false, true])
        XCTAssertTrue(day.sittings.allSatisfy { $0.finished.isEmpty && $0.dropped.isEmpty })
    }

    func testADropIsListedApartFromWhatWasFinished() throws {
        let day = try list(twoSittings, events: [event(.dropped, "Book the venue", moment(18, 11))], in: range(18))
        let morning = try XCTUnwrap(day.sittings.first { $0.startTime == "9:10 AM" })
        XCTAssertEqual(morning.dropped.map(\.text), ["Book the venue"])
        XCTAssertEqual(morning.finished, [])
    }

    private let lateNight = """
    # Redesign

    ## Sessions

    ### Thu, Sep 17, 2026 11:00 PM

    - [x] Email Dana
    - [x] Book the venue
    - [x] Draft the nav spec

    """

    /// Past midnight, within the idle window of the evening's last tick: still the evening's sitting,
    /// even though the tick's own day is the next one.
    func testACompletionAfterMidnightStaysWithTheEveningsSitting() throws {
        let events = [
            event(.completed, "Email Dana", moment(17, 23, 50)),
            event(.completed, "Book the venue", moment(18, 0, 40)),
            // Two hours after the last one: that sitting is over.
            event(.completed, "Draft the nav spec", moment(18, 2, 45)),
        ]
        let yesterday = try list(lateNight, events: events, in: range(17))
        XCTAssertEqual(yesterday.sittings.first?.finished.map(\.text), ["Email Dana", "Book the venue"])
        XCTAssertEqual(yesterday.elsewhere, [], "The 2:45 AM tick is the next day's, not this one's")

        let today = try list(lateNight, events: events, in: range(18))
        XCTAssertEqual(today.sittings, [], "The sitting is dated the day before")
        XCTAssertEqual(today.elsewhere.map(\.text), ["Draft the nav spec"],
                       "Only the tick nobody's sitting owns is today's, on its own")
    }

    /// The evening's earlier ticks fall before the span, and still count as the sitting's last activity.
    func testTheEveningsLastTickIsKnownFromTheDayBefore() throws {
        let events = [
            event(.completed, "Email Dana", moment(17, 23, 55)),
            event(.completed, "Book the venue", moment(18, 1, 20)),
        ]
        let today = try list(lateNight, events: events, in: range(18))
        XCTAssertEqual(today.elsewhere, [], "1:20 AM is within the window of 11:55 PM, so it's the evening's")
    }

    /// A sitting from before headings kept the time owns what happened that day before any timed one.
    func testAnUntimedSittingOwnsTheEarlierPartOfItsDay() throws {
        let doc = """
        # Redesign

        ## Sessions

        ### Fri, Sep 18, 2026 3:00 PM

        - [x] Draft the nav spec

        ### Fri, Sep 18, 2026

        - [x] Email Dana

        """
        let day = try list(doc, events: [event(.completed, "Email Dana", moment(18, 11))], in: range(18))
        let untimed = try XCTUnwrap(day.sittings.first { $0.startTime == nil })
        XCTAssertEqual(untimed.finished.map(\.text), ["Email Dana"])
        XCTAssertNil(untimed.startedAt)
    }

    /// A pick names a tree: the whole tree is drawn in the sitting it was picked up into, once.
    func testAPickedTreeIsDrawnWholeWithWhereItCameFrom() throws {
        let doc = """
        # Redesign

        ## Sessions

        ### Fri, Sep 18, 2026 9:10 AM

        Picking up the venue.

        ### Wed, Sep 2, 2026

        - [ ] Book the venue
          - [ ] Call the second venue

        """
        let notes = try parseNotes(markdown: doc)
        let todos = try parseTodos(notes: notes)
        let child = try XCTUnwrap(todos.first { $0.text == "Call the second venue" })
        let root = try XCTUnwrap(todos.first { $0.text == "Book the venue" })
        let into = try XCTUnwrap(PickLog.sitting(at: 0, in: notes))
        let picks = [
            PickEvent(id: "p1", at: DoneLog.timestamp(moment(18, 9, 20)), event: .picked,
                      task: try XCTUnwrap(PickLog.task(root, in: notes)), into: into),
            PickEvent(id: "p2", at: DoneLog.timestamp(moment(18, 9, 30)), event: .picked,
                      task: try XCTUnwrap(PickLog.task(child, in: notes)), into: into),
        ]
        let day = try list(doc, picks: picks, in: range(18))
        let sitting = try XCTUnwrap(day.sittings.first)
        XCTAssertEqual(sitting.picked.map(\.text), ["Book the venue", "Call the second venue"])
        XCTAssertEqual(sitting.picked.map(\.from), ["2026-09-02", "2026-09-02"])
        XCTAssertEqual(sitting.written, [])
    }

    func testTheNewestSittingWrittenInTheWindowIsNow() throws {
        let now = moment(18, 15)
        let live = try list(twoSittings, in: range(18), notesModified: moment(18, 14, 30), now: now)
        XCTAssertEqual(live.sittings.map(\.isCurrent), [true, false])
        let cold = try list(twoSittings, in: range(18), notesModified: moment(18, 12), now: now)
        XCTAssertEqual(cold.sittings.map(\.isCurrent), [false, false])
    }

    /// Across projects: the day in the order it went, with the untimed sittings first as "Earlier".
    func testSittingsAcrossProjectsAreToldInTheOrderTheDayWent() throws {
        let other = """
        # Home

        ## Sessions

        ### Fri, Sep 18, 2026 11:30 AM

        Taxes.

        ### Fri, Sep 18, 2026

        Something from before times were kept.

        ### Thu, Sep 17, 2026 8:00 PM

        Yesterday evening.

        """
        let week = DoneRange(start: moment(14, 0), end: moment(21, 0))
        let merged = try list(twoSittings, in: week).merged(with: try list(other, folder: "Home", in: week)).sorted()
        XCTAssertEqual(merged.sittings.map { "\($0.session) \($0.startTime ?? "Earlier") \($0.projectName)" }, [
            "2026-09-18 Earlier Home",
            "2026-09-18 9:10 AM Redesign",
            "2026-09-18 11:30 AM Home",
            "2026-09-18 2:15 PM Redesign",
            "2026-09-17 8:00 PM Home",
        ])
    }

    func testProseLeavesOutEveryKindOfTaskLine() {
        XCTAssertEqual(sittingProse("Intro\n- [ ] a\n  - [x] b\n* [-] c\n- plain bullet\n\n\n\nEnd"),
                       "Intro\n- plain bullet\n\nEnd")
    }

    func testYesterdayIsTheDayBefore() throws {
        let now = moment(18, 10)
        let yesterday = try DoneRange.resolve(period: "yesterday", since: nil, until: nil, now: now, calendar: calendar)
        XCTAssertEqual(yesterday, DoneRange(start: moment(17, 0), end: moment(18, 0)))
    }

    // MARK: Through the binary

    private static var pmBinaryPath: String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
        return (root as NSString).appendingPathComponent(".build/debug/pm")
    }
    private var haveBinary: Bool { FileManager.default.isExecutableFile(atPath: Self.pmBinaryPath) }
    private var env: [String: String] = [:]
    private var vaultRoot = ""

    override func tearDown() {
        if !vaultRoot.isEmpty { try? FileManager.default.removeItem(atPath: vaultRoot) }
        super.tearDown()
    }

    private func vault() {
        let fm = FileManager.default
        vaultRoot = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        let config = (vaultRoot as NSString).appendingPathComponent("config")
        let active = (vaultRoot as NSString).appendingPathComponent("active")
        let archive = (vaultRoot as NSString).appendingPathComponent("archive")
        for path in [config, active, archive] { try? fm.createDirectory(atPath: path, withIntermediateDirectories: true) }
        let json: [String: Any] = ["activePath": active, "archivePath": archive,
                                   "domains": ["W": "Work"], "subfolders": ["docs"]]
        try? JSONSerialization.data(withJSONObject: json)
            .write(to: URL(fileURLWithPath: (config as NSString).appendingPathComponent("config.json")))
        env = ["PM_CONFIG_HOME": config, "PM_ACTIVE_PATH": active, "PM_ARCHIVE_PATH": archive]
    }

    private func run(_ arguments: [String]) -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.pmBinaryPath)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(env) { _, e in e }
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        try? process.run()
        let data = (try? out.fileHandleForReading.readToEnd()) ?? Data()
        process.waitUntilExit()
        return data
    }

    @discardableResult
    private func call(_ action: String, _ input: [String: Any] = [:]) -> [String: Any] {
        let json = String(data: (try? JSONSerialization.data(withJSONObject: input)) ?? Data(), encoding: .utf8) ?? "{}"
        return ((try? JSONSerialization.jsonObject(with: run(["api", "call", action, json]))) as? [String: Any]) ?? [:]
    }

    /// Today's work in two projects, read back through the contract and through `pm day`.
    func testTodayAcrossProjectsThroughTheContract() throws {
        try XCTSkipUnless(haveBinary)
        vault()
        call("project.create", ["title": "Redesign", "domain": "W"])
        call("project.create", ["title": "Hiring", "domain": "W"])
        call("session.note", ["project": "W-1", "prose": "Came back to the nav."])
        call("task.add", ["project": "W-1", "text": "Email Dana"])
        call("task.add", ["project": "W-2", "text": "Write the posting"])
        let todos = call("task.list", ["project": "W-1"])["data"] as? [[String: Any]] ?? []
        let dana = try XCTUnwrap(todos.first { $0["text"] as? String == "Email Dana" })
        call("task.complete", ["project": "W-1", "task": ["session": dana["sessionISODate"] as Any,
                                                          "line": dana["lineIndex"] as Any,
                                                          "digest": dana["digest"] as Any]])

        let result = call("session.list")
        XCTAssertEqual(result["summary"] as? String, "2 sittings in 2 projects, 1 done.")
        let data = try XCTUnwrap(result["data"] as? [String: Any])
        let sittings = try XCTUnwrap(data["sittings"] as? [[String: Any]])
        XCTAssertEqual(Set(sittings.compactMap { $0["projectName"] as? String }), ["Redesign", "Hiring"])
        let redesign = try XCTUnwrap(sittings.first { $0["projectName"] as? String == "Redesign" })
        XCTAssertNotNil(redesign["startTime"] as? String, "Every new sitting carries its time")
        XCTAssertEqual(redesign["prose"] as? String, "Came back to the nav.")
        XCTAssertEqual((redesign["finished"] as? [[String: Any]])?.compactMap { $0["text"] as? String }, ["Email Dana"])
        XCTAssertEqual(redesign["isCurrent"] as? Bool, true)

        let only = call("session.list", ["projects": ["[[W-2]]"]])["data"] as? [String: Any]
        XCTAssertEqual((only?["sittings"] as? [[String: Any]])?.compactMap { $0["projectName"] as? String }, ["Hiring"])

        let text = String(data: run(["day"]), encoding: .utf8) ?? ""
        XCTAssertTrue(text.hasPrefix("Today · "), text)
        XCTAssertTrue(text.contains("2 sittings · 1 done"), text)
        XCTAssertTrue(text.contains("Came back to the nav."), text)
        XCTAssertTrue(text.contains("✓ Email Dana"), text)
        XCTAssertEqual(text.components(separatedBy: "Email Dana").count - 1, 1, "Written and finished here: listed once")
    }

    func testNothingInTheSpanSaysSo() throws {
        try XCTSkipUnless(haveBinary)
        vault()
        call("project.create", ["title": "Redesign", "domain": "W"])
        XCTAssertEqual(call("session.list", ["period": "yesterday"])["summary"] as? String, "No sittings.")
    }
}
