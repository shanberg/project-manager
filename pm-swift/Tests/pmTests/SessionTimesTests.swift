import XCTest
import Foundation
@testable import PmLib

/// Giving sittings from before headings kept a time a best guess: from the record where there is one,
/// a placeholder where there isn't, and never out of order with the sittings either side.
final class SessionTimesTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }()

    private func at(_ day: Int, _ hour: Int, _ minute: Int, month: Int = 9) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }

    private func headings(_ markdown: String) -> [String] {
        markdown.components(separatedBy: "\n").filter { $0.hasPrefix("### ") }
    }

    private func document(_ sessions: String) -> String {
        """
        # Redesign

        ## Sessions

        \(sessions)
        """
    }

    func testASittingIsDatedByTheEarliestRecordThatDayRoundedDown() throws {
        let markdown = document("""
        ### Tue, Sep 15, 2026 Vendor call

        - [x] Pick a CMS
        """)
        let evidence = [
            SessionTimes.Evidence(at: at(15, 16, 2), session: "2026-09-15", source: .journal),
            SessionTimes.Evidence(at: at(15, 14, 13), session: "2026-09-15", source: .done),
        ]
        let result = try XCTUnwrap(SessionTimes.backfill(rawText: markdown, evidence: evidence, calendar: calendar))
        XCTAssertEqual(headings(result.rawText), ["### Tue, Sep 15, 2026 2:10 PM · Vendor call"])
        XCTAssertEqual(result.guesses.first?.basis, .done)
        XCTAssertEqual(result.guesses.first?.name, "Vendor call", "the name is kept")
    }

    func testASittingWithNothingOnRecordGetsThePlaceholder() throws {
        let markdown = document("### Sat, Aug 22, 2026\n\nKicked off.")
        let result = try XCTUnwrap(SessionTimes.backfill(rawText: markdown, evidence: [], calendar: calendar))
        XCTAssertEqual(headings(result.rawText), ["### Sat, Aug 22, 2026 9:00 AM"])
        XCTAssertEqual(result.guesses.first?.basis, .placeholder)
    }

    /// A task from the 2nd ticked on the 5th says nothing about when the 2nd began.
    func testARecordFromAnotherDayIsNotEvidence() throws {
        let markdown = document("### Tue, Sep 15, 2026\n\n- [x] Pick a CMS")
        let evidence = [SessionTimes.Evidence(at: at(17, 11, 0), session: "2026-09-15", source: .done)]
        let result = try XCTUnwrap(SessionTimes.backfill(rawText: markdown, evidence: evidence, calendar: calendar))
        XCTAssertEqual(result.guesses.first?.basis, .placeholder)
    }

    /// The day's later sitting began at 8:30, so the earlier one began before it: evidence after 8:30
    /// belongs to the later sitting, and the placeholder moves inside the gap.
    func testAGuessStaysBeforeTheNextSittingThatDay() throws {
        let markdown = document("""
        ### Tue, Sep 15, 2026 8:30 AM · Standup

        - [ ] Later thing

        ### Tue, Sep 15, 2026

        - [ ] Earlier thing
        """)
        let evidence = [SessionTimes.Evidence(at: at(15, 10, 0), session: "2026-09-15", source: .done)]
        let result = try XCTUnwrap(SessionTimes.backfill(rawText: markdown, evidence: evidence, calendar: calendar))
        XCTAssertEqual(headings(result.rawText), ["### Tue, Sep 15, 2026 8:30 AM · Standup",
                                                  "### Tue, Sep 15, 2026 8:00 AM"])
        XCTAssertEqual(result.guesses.map(\.basis), [.placeholder])
    }

    /// Two untimed sittings on one day are dated in order, each after the one before it.
    func testTwoUntimedSittingsOfADayAreDatedInOrder() throws {
        let markdown = document("""
        ### Tue, Sep 15, 2026 Afternoon

        - [x] Second

        ### Tue, Sep 15, 2026 Morning

        - [x] First
        """)
        let evidence = [
            SessionTimes.Evidence(at: at(15, 9, 42), session: "2026-09-15", source: .done),
            SessionTimes.Evidence(at: at(15, 15, 7), session: "2026-09-15", source: .done),
        ]
        let result = try XCTUnwrap(SessionTimes.backfill(rawText: markdown, evidence: evidence, calendar: calendar))
        XCTAssertEqual(headings(result.rawText), ["### Tue, Sep 15, 2026 3:05 PM · Afternoon",
                                                  "### Tue, Sep 15, 2026 9:40 AM · Morning"])
    }

    func testADocumentWhoseSittingsAllHaveTimesIsLeftAlone() throws {
        let markdown = document("### Fri, Sep 18, 2026 10:40 AM · Vendor call\n\n- [ ] Ask")
        XCTAssertNil(try SessionTimes.backfill(rawText: markdown, evidence: [], calendar: calendar))
    }

    /// A card pinned to a sitting before it had a time still finds it after — only a time is forgiven.
    func testAReferenceTakenBeforeTheTimeStillResolves() throws {
        let before = document("### Sat, Aug 22, 2026 Kickoff\n\nKicked off.")
        let ref = SessionRef(date: "2026-08-22", digest: sessionDigest("Kickoff"))
        let result = try XCTUnwrap(SessionTimes.backfill(rawText: before, evidence: [], calendar: calendar))
        let after = try parseNotes(markdown: result.rawText)
        XCTAssertEqual(try resolveSessionRef(ref, notes: after).index, 0)

        let renamed = try parseNotes(markdown: result.rawText.replacingOccurrences(of: "Kickoff", with: "Retro"))
        XCTAssertThrowsError(try resolveSessionRef(ref, notes: renamed), "a rename is still a different label")
    }
}
