import XCTest
import PmLib

/// The timekeeper's rules on a test's clock: pauses, leaves and not-work apps, and what each one
/// writes to a log of its own. See docs/away-time.md.
@MainActor
final class AttentionKeeperTests: XCTestCase {
    private var root: URL!
    private var savedConfigHome: String?
    private var keeper: AttentionKeeper!
    private var now = Date(timeIntervalSince1970: 1_790_000_000)
    /// When anyone last touched the machine, on the test's clock.
    private var lastInput = Date(timeIntervalSince1970: 1_790_000_000)

    private let key = "/PARA/Projects:W-1 Website"
    private let news = "com.example.news"

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        savedConfigHome = ProcessInfo.processInfo.environment["PM_CONFIG_HOME"]
        setenv("PM_CONFIG_HOME", root.path, 1)

        keeper = AttentionKeeper()
        keeper.schedulesTimers = false
        keeper.clock = { [unowned self] in now }
        keeper.idle = { [unowned self] in now.timeIntervalSince(lastInput) }
        keeper.notWork = { [news] in [news] }
    }

    override func tearDown() {
        if let saved = savedConfigHome { setenv("PM_CONFIG_HOME", saved, 1) } else { unsetenv("PM_CONFIG_HOME") }
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Driving it

    private func wait(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
    private func touch() { lastInput = now }
    private func minutes(_ n: Double) -> TimeInterval { n * 60 }

    private var log: [AttentionEvent] { AttentionLog.events() }
    private var last: AttentionEvent? { log.last }
    private func at(_ event: AttentionEvent?) -> Date? { event.flatMap { DoneLog.date($0.at) } }

    /// Focused on W-1, working, at the start of the clock.
    private func working() {
        touch()
        keeper.focusMoved(to: key)
        XCTAssertEqual(log.map(\.event), [.began])
    }

    // MARK: Pauses and returns

    func testTenQuietMinutesEndTheSpanAtTheLastInput() {
        working()
        wait(minutes(3)); touch()
        let hands = now
        wait(minutes(11))
        keeper.check()
        XCTAssertEqual(last?.event, .ended)
        XCTAssertEqual(last?.why, "paused")
        XCTAssertEqual(at(last), hands, "back-dated to the last input")
    }

    func testAReturnIsStampedAtTheInputThatShowedIt() {
        working()
        wait(minutes(11))
        keeper.check()
        wait(minutes(2)); touch()
        let back = now
        wait(3)
        keeper.check()
        XCTAssertEqual(last?.event, .began)
        XCTAssertEqual(last?.why, "resumed")
        XCTAssertEqual(at(last), back)
    }

    /// The fix for the log's 0-minute sleep/resume pairs: a lock seconds after the last keystroke
    /// leaves that keystroke recent, and it isn't a return.
    func testALeaveIsNotUndoneByTheInputBeforeIt() {
        working()
        wait(5)
        keeper.leave(why: "locked")
        XCTAssertEqual(last?.why, "locked")
        wait(minutes(1))
        keeper.check()
        XCTAssertEqual(last?.event, .ended, "no return without input since the lock")
    }

    func testALockDuringAPauseIsWrittenInsideTheGap() {
        working()
        wait(minutes(11))
        keeper.check()
        wait(minutes(2))
        keeper.leave(why: "locked")
        XCTAssertEqual(log.suffix(2).map(\.why), ["paused", "locked"])
        XCTAssertEqual(at(last), now)
    }

    // MARK: Not-work apps

    /// A glance counts as the work it interrupted: nothing is written.
    func testAGlanceIsNotAStop() {
        working()
        wait(minutes(5)); touch()
        keeper.frontmostChanged(to: news)
        wait(30); touch()
        keeper.check()
        keeper.frontmostChanged(to: "com.example.editor")
        wait(minutes(1)); touch()
        keeper.check()
        XCTAssertEqual(log.map(\.event), [.began])
    }

    func testStayingEndsTheSpanWhenTheAppCameUp() {
        working()
        wait(minutes(5)); touch()
        keeper.frontmostChanged(to: news)
        let opened = now
        wait(minutes(1.5)); touch()
        keeper.check()
        XCTAssertEqual(last?.event, .ended)
        XCTAssertEqual(last?.why, "elsewhere")
        XCTAssertEqual(at(last), opened)
    }

    /// Typing in a news reader is still reading the news.
    func testInputInTheAppIsNotAReturn() {
        working()
        keeper.frontmostChanged(to: news)
        wait(minutes(2)); touch()
        keeper.check()
        wait(minutes(5)); touch()
        keeper.check()
        XCTAssertEqual(log.map(\.event), [.began, .ended])
    }

    func testLeavingTheAppIsAReturn() {
        working()
        keeper.frontmostChanged(to: news)
        wait(minutes(2)); touch()
        keeper.check()
        wait(minutes(10))
        keeper.frontmostChanged(to: "com.example.editor")
        touch()
        wait(3)
        keeper.check()
        XCTAssertEqual(log.map(\.event), [.began, .ended, .began])
        XCTAssertEqual(last?.why, "resumed")
        XCTAssertEqual(AttentionLog.aways(from: log), [], "an elsewhere gap is never asked about")
    }

    /// Already quiet when the app came up: said inside the gap, so it's neither focus nor asked.
    func testTheAppDuringAPauseMarksTheGap() {
        working()
        wait(minutes(3)); touch()
        wait(minutes(11))
        keeper.check()
        keeper.frontmostChanged(to: news)
        let opened = now
        wait(minutes(1.5)); touch()
        keeper.check()
        XCTAssertEqual(log.suffix(2).map(\.why), ["paused", "elsewhere"])
        XCTAssertEqual(at(last), opened)

        keeper.frontmostChanged(to: "com.example.editor")
        wait(minutes(1)); touch()
        keeper.check()
        XCTAssertEqual(last?.why, "resumed")
        XCTAssertEqual(AttentionLog.aways(from: log), [])
        wait(minutes(2))
        let spans = AttentionLog.spans(from: log, now: now)
        XCTAssertEqual(spans.map { Int(($0.seconds / 60).rounded()) }, [3, 2],
                       "the gap wasn't filled as quiet focus")
    }

    /// Written once per stretch in the app, however many checks see it.
    func testTheStopIsWrittenOnce() {
        working()
        keeper.frontmostChanged(to: news)
        for _ in 0..<5 { wait(minutes(1)); touch(); keeper.check() }
        XCTAssertEqual(log.filter { $0.why == "elsewhere" }.count, 1)
    }

    /// Focusing a project from inside the app starts its time there; the stop can't land before it.
    func testFocusingFromInsideTheAppStartsFromTheFocus() {
        working()
        keeper.frontmostChanged(to: news)
        wait(30)
        keeper.focusMoved(to: "/PARA/Projects:W-2 Brand")
        let focused = now
        wait(minutes(2)); touch()
        keeper.check()
        XCTAssertEqual(last?.project, "W-2 Brand")
        XCTAssertEqual(last?.why, "elsewhere")
        XCTAssertEqual(at(last), focused)
    }

    func testAnAppOffTheListIsWork() {
        working()
        keeper.frontmostChanged(to: "com.example.editor")
        wait(minutes(5)); touch()
        keeper.check()
        XCTAssertEqual(log.map(\.event), [.began])
    }
}
