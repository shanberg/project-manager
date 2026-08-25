import XCTest
@testable import PmLib

/// The idle window: when a write joins the last sitting and when it starts a new one.
final class SessionWindowTests: XCTestCase {
    /// A project whose only session is today's, with a note and a task in it.
    private func fixture(today: Date) -> String {
        """
        # My Project

        ## Sessions

        ### \(formatSessionDate(today))

        Something I wrote this morning.

        - [ ] Todo one
        """
    }

    /// A file with a `## Sessions` heading and nothing under it.
    private static let empty = """
    # My Project

    ## Sessions
    """

    private let now = Date(timeIntervalSince1970: 1_756_000_000)   // Aug 2026, mid-afternoon UTC

    // MARK: The window itself

    func testColdOnlyPastTheWindow() {
        XCTAssertFalse(sessionHasGoneCold(lastEdited: now.addingTimeInterval(-60), now: now))
        XCTAssertFalse(sessionHasGoneCold(lastEdited: now.addingTimeInterval(-sessionIdleWindow + 1), now: now))
        XCTAssertTrue(sessionHasGoneCold(lastEdited: now.addingTimeInterval(-sessionIdleWindow - 1), now: now))
    }

    /// Not knowing when the file was last touched must never be read as "start a new session" — the
    /// document's shape is not something to guess at.
    func testUnknownLastEditIsNotCold() {
        XCTAssertFalse(sessionHasGoneCold(lastEdited: nil, now: now))
        XCTAssertEqual(sessionIdleWindow, 90 * 60, "The window is 90 minutes")
    }

    // MARK: Resolving the session to write into

    /// A warm project keeps writing into the session it already has.
    func testWarmProjectReusesItsSession() throws {
        let raw = fixture(today: now)
        let session = try XCTUnwrap(currentSessionPreservingFormat(
            rawText: raw, lastEdited: now.addingTimeInterval(-10 * 60), now: now))
        XCTAssertFalse(session.started)
        XCTAssertEqual(session.sessionIndex, 0)
        XCTAssertEqual(session.rawText, raw, "Nothing to write, so nothing changed")
    }

    /// Past the window, the same project gets a second session for the same day — above the first,
    /// and labelled with the time so the two headings can be told apart.
    func testColdProjectStartsASecondSessionToday() throws {
        let raw = fixture(today: now)
        let session = try XCTUnwrap(currentSessionPreservingFormat(
            rawText: raw, lastEdited: now.addingTimeInterval(-3 * 3600), now: now))
        XCTAssertTrue(session.started)
        XCTAssertEqual(session.sessionIndex, 0, "Sessions are newest-first, so the new one leads")

        let sessions = try parseNotes(markdown: session.rawText).sessions
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(sessions[0].date, sessions[1].date, "Both are today")
        XCTAssertEqual(sessions[0].label, sessionTimeLabel(now))
        XCTAssertFalse(sessions[0].label.isEmpty, "A same-day sibling needs telling apart")
        XCTAssertTrue(sessions[0].body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertTrue(sessions[1].body.contains("Todo one"), "The old session is untouched")
    }

    /// The day's first session carries no label, exactly as it always did.
    func testFirstSessionOfTheDayIsUnlabelled() throws {
        let session = try XCTUnwrap(currentSessionPreservingFormat(
            rawText: Self.empty, lastEdited: now.addingTimeInterval(-30 * 3600), now: now))
        XCTAssertTrue(session.started)
        let sessions = try parseNotes(markdown: session.rawText).sessions
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].label, "")
    }

    /// A heading with nothing under it is a sitting that never started, so writing into it starts it —
    /// however long ago it was made. Otherwise the rule would stack empty headings on empty headings.
    func testAnEmptySessionIsReusedHoweverStale() throws {
        let raw = """
        # My Project

        ## Sessions

        ### \(formatSessionDate(now))
        """
        let session = try XCTUnwrap(currentSessionPreservingFormat(
            rawText: raw, lastEdited: now.addingTimeInterval(-8 * 3600), now: now))
        XCTAssertFalse(session.started)
        XCTAssertEqual(try parseNotes(markdown: session.rawText).sessions.count, 1)
    }

    /// An explicit label wins over the automatic time — `session.start` passes the one the caller named.
    func testAGivenLabelWinsOverTheTime() throws {
        let session = try XCTUnwrap(currentSessionPreservingFormat(
            rawText: fixture(today: now), lastEdited: now.addingTimeInterval(-3 * 3600), now: now,
            label: "Standup"))
        XCTAssertEqual(try parseNotes(markdown: session.rawText).sessions[0].label, "Standup")
    }

    /// No `## Sessions` heading to splice into: nil, so the caller can fall back.
    func testNoSessionsSectionReturnsNil() throws {
        XCTAssertNil(try currentSessionPreservingFormat(rawText: "# Title\n\nNothing here.",
                                                        lastEdited: nil, now: now))
    }

    // MARK: The note path

    /// A note written into a cold project opens the new session rather than joining yesterday's entry.
    func testANoteIntoAColdProjectStartsASession() throws {
        let updated = try XCTUnwrap(appendSessionNotePreservingFormat(
            rawText: fixture(today: now), prose: "Back at it after lunch.",
            lastEdited: now.addingTimeInterval(-2 * 3600), date: now))
        let sessions = try parseNotes(markdown: updated).sessions
        XCTAssertEqual(sessions.count, 2)
        XCTAssertTrue(sessions[0].body.contains("Back at it after lunch."))
        XCTAssertFalse(sessions[1].body.contains("Back at it after lunch."),
                       "The morning's session keeps its own note")
        XCTAssertTrue(sessions[1].body.contains("Something I wrote this morning."))
    }

    /// A note written while the project is warm joins the running log, as it always has.
    func testANoteIntoAWarmProjectJoinsTheLog() throws {
        let updated = try XCTUnwrap(appendSessionNotePreservingFormat(
            rawText: fixture(today: now), prose: "One more thing.",
            lastEdited: now.addingTimeInterval(-5 * 60), date: now))
        let sessions = try parseNotes(markdown: updated).sessions
        XCTAssertEqual(sessions.count, 1)
        XCTAssertTrue(sessions[0].body.contains("Something I wrote this morning."))
        XCTAssertTrue(sessions[0].body.contains("One more thing."))
    }
}
