import XCTest
import Foundation
@testable import PmLib

/// `AgentMomentsMemo`: off by default, and when on, an answer is reused only for its lifetime.
final class AgentMomentsMemoTests: XCTestCase {
    private let range = DoneRange(start: Date(timeIntervalSince1970: 1_000_000), end: Date(timeIntervalSince1970: 1_086_400))
    private let moment = AgentMoment(minute: Date(timeIntervalSince1970: 1_000_060), folder: "/tmp/x", project: "X")

    override func tearDown() {
        AgentMomentsMemo.lifetime = 0
        super.tearDown()
    }

    func testOffByDefaultKeepsNothing() {
        AgentMomentsMemo.lifetime = 0
        let now = Date()
        AgentMomentsMemo.keep([moment], for: range, now: now)
        XCTAssertNil(AgentMomentsMemo.lookup(range, now: now), "a pm run must always look again")
    }

    func testAnAnswerIsReusedWithinItsLifetimeAndNotAfter() {
        AgentMomentsMemo.lifetime = 10
        let now = Date()
        AgentMomentsMemo.keep([moment], for: range, now: now)
        XCTAssertEqual(AgentMomentsMemo.lookup(range, now: now.addingTimeInterval(9)), [moment])
        XCTAssertNil(AgentMomentsMemo.lookup(range, now: now.addingTimeInterval(10)))
    }

    func testAnotherRangeIsAnotherQuestion() {
        AgentMomentsMemo.lifetime = 10
        let now = Date()
        AgentMomentsMemo.keep([moment], for: range, now: now)
        let other = DoneRange(start: range.start, end: range.end.addingTimeInterval(60))
        XCTAssertNil(AgentMomentsMemo.lookup(other, now: now))
    }

    func testTurningItOffForgets() {
        AgentMomentsMemo.lifetime = 10
        let now = Date()
        AgentMomentsMemo.keep([moment], for: range, now: now)
        AgentMomentsMemo.lifetime = 0
        AgentMomentsMemo.lifetime = 10
        XCTAssertNil(AgentMomentsMemo.lookup(range, now: now))
    }
}
