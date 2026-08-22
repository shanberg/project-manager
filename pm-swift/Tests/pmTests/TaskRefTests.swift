import XCTest
@testable import PmLib

/// A task reference is a position plus two defences: a session named by date rather than index, and a
/// digest of the task's text. These cover what each one is for — the session shift that renumbers
/// every index, the insert that shifts a line within its session, and the rename that must break a
/// reference rather than be acted through. See docs/task-identity.md.
final class TaskRefTests: XCTestCase {

    /// Yesterday's session with four tasks, so "today" is genuinely absent to begin with.
    private let yesterday = "Fri, Aug 21, 2026"
    private let yesterdayISO = "2026-08-21"

    private func fixture() -> String {
        """
        # Redesign

        ## Sessions

        ### \(yesterday) planning

        - [ ] Draft the summary
        - [ ] Email Dana about pricing
        - [ ] Review the contract @
        - [ ] Book the venue
        """
    }

    private func todos(_ markdown: String) throws -> [Todo] {
        try parseTodos(notes: parseNotes(markdown: markdown))
    }

    private func text(_ markdown: String, _ at: ResolvedTaskRef) throws -> String? {
        try todos(markdown).first {
            $0.sessionIndex == at.sessionIndex && $0.lineIndex == at.lineIndex
        }?.text
    }

    /// A morning's captures: a session is created and four tasks land in it, which is what shifts
    /// every existing task from (0, l) to (1, l).
    private func afterAMorning(_ markdown: String) -> String {
        var out = sessionAddPreservingFormat(rawText: markdown, label: "", date: Date())!
        for t in ["Call the printer", "Reply to Sam", "Book travel", "Check the invoice"] {
            out = appendTaskToSession(rawText: out, sessionIndex: 0, text: t, due: nil)!.rawText
        }
        return out
    }

    // MARK: Digest

    /// The digest is over the task's text, so the edits that don't change what a task is don't
    /// change its digest either.
    func testDigestIsStableAcrossNonRenamingEdits() throws {
        let before = fixture()
        let target = try todos(before).first { $0.text == "Review the contract" }!
        let original = taskDigest(target.text)

        let edits: [(String, (ProjectNotes) throws -> ProjectNotes)] = [
            ("complete", { try completeTodoWithDescendants(
                notes: $0, sessionIndex: 0, lineIndex: 2, advanceFocus: true) }),
            ("focus elsewhere", { applyFocusToTodoAt(notes: $0, sessionIndex: 0, lineIndex: 0) }),
            ("set a due date", { setDueOnTodoAt(notes: $0, sessionIndex: 0, lineIndex: 2, due: "2026-12-01") }),
        ]
        for (name, mutate) in edits {
            let after = try editTodosPreservingFormat(rawText: before) {
                try mutate(normalizeFocusMarker(notes: $0))
            } ?? before
            XCTAssertTrue(try todos(after).contains { taskDigest($0.text) == original },
                          "digest should survive \(name)")
        }
    }

    /// A rename is the one edit that must invalidate a reference.
    func testDigestBreaksOnRename() throws {
        let renamed = try editTodosPreservingFormat(rawText: fixture()) {
            setTextOnTodoAt(notes: normalizeFocusMarker(notes: $0), sessionIndex: 0, lineIndex: 2,
                            text: "Review the contract with legal")
        }!
        let original = taskDigest("Review the contract")
        XCTAssertFalse(try todos(renamed).contains { taskDigest($0.text) == original })
    }

    /// Whitespace and Unicode form are normalized, so a reference doesn't break on a cosmetic
    /// difference in how the same text was written.
    func testDigestNormalizes() {
        XCTAssertEqual(taskDigest("Review the contract"), taskDigest("  Review the contract  "))
        XCTAssertEqual(taskDigest("Cafe\u{0301} visit"), taskDigest("Caf\u{00E9} visit"))
        XCTAssertNotEqual(taskDigest("Review the contract"), taskDigest("Review the contracts"))
    }

    // MARK: Session dates

    func testSessionDateRoundTrips() throws {
        XCTAssertEqual(sessionISODate(heading: yesterday), yesterdayISO)
        XCTAssertEqual(try sessionHeadingDate(iso: yesterdayISO), yesterday)
        XCTAssertNil(sessionISODate(heading: "not a session heading"))
    }

    /// Every task carries the ISO date of its session, so a reader never re-derives it.
    func testParseTodosCarriesISODateAndDigest() throws {
        let first = try todos(fixture())[0]
        XCTAssertEqual(first.sessionISODate, yesterdayISO)
        XCTAssertEqual(first.digest, taskDigest("Draft the summary"))
    }

    // MARK: Resolution

    /// The defect this exists for: starting a session renumbers everything below it, so a position
    /// read beforehand comes to name a different, real task.
    func testDateCoordinateSurvivesTheSessionShift() throws {
        let before = fixture()
        let target = try todos(before).first { $0.text == "Review the contract" }!
        let after = afterAMorning(before)

        // What the position alone now means.
        let atOldPosition = try todos(after).first {
            $0.sessionIndex == 0 && $0.lineIndex == target.lineIndex
        }
        XCTAssertNotNil(atOldPosition)
        XCTAssertNotEqual(atOldPosition?.text, target.text)

        let ref = TaskRef(sessionDate: yesterdayISO, lineIndex: target.lineIndex,
                          digest: taskDigest(target.text))
        let resolved = try resolveTaskRef(ref, rawText: after)
        XCTAssertFalse(resolved.relocated, "a date coordinate shouldn't need healing for this")
        XCTAssertEqual(try text(after, resolved), "Review the contract")
    }

    /// An index-addressed reference lands on the wrong task without a digest, and is healed with one.
    func testDigestRelocatesAnIndexReference() throws {
        let before = fixture()
        let target = try todos(before).first { $0.text == "Review the contract" }!
        let after = afterAMorning(before)

        let blind = TaskRef(sessionIndex: 0, lineIndex: target.lineIndex)
        XCTAssertNotEqual(try text(after, try resolveTaskRef(blind, rawText: after)), target.text)

        let asserted = TaskRef(sessionIndex: 0, lineIndex: target.lineIndex, digest: taskDigest(target.text))
        let healed = try resolveTaskRef(asserted, rawText: after)
        XCTAssertTrue(healed.relocated)
        XCTAssertEqual(try text(after, healed), "Review the contract")
    }

    /// A date coordinate doesn't help with an insert *inside* the session; the digest does.
    func testDigestRelocatesAfterAnInsertWithinTheSession() throws {
        let before = fixture()
        let target = try todos(before).first { $0.text == "Review the contract" }!
        let inserted = insertTaskRelative(rawText: before, anchorSessionIndex: 0, anchorLineIndex: 0,
                                          text: "Check with Priya", due: nil, position: .before)!.rawText
        let ref = TaskRef(sessionDate: yesterdayISO, lineIndex: target.lineIndex,
                          digest: taskDigest(target.text))
        let resolved = try resolveTaskRef(ref, rawText: inserted)
        XCTAssertTrue(resolved.relocated)
        XCTAssertEqual(try text(inserted, resolved), "Review the contract")
    }

    /// Two sessions can share a date — `pm notes session add` doesn't check for today's the way the
    /// panel does — so the ordinal has to be able to tell them apart.
    func testSessionOrdinalDisambiguatesOneDate() throws {
        let today = Date()
        var markdown = sessionAddPreservingFormat(rawText: fixture(), label: "morning", date: today)!
        markdown = sessionAddPreservingFormat(rawText: markdown, label: "evening", date: today)!
        markdown = appendTaskToSession(rawText: markdown, sessionIndex: 0, text: "Evening task", due: nil)!.rawText
        markdown = appendTaskToSession(rawText: markdown, sessionIndex: 1, text: "Morning task", due: nil)!.rawText

        let todayISO = sessionISODate(heading: formatSessionDate(today))!
        let sessions = try parseNotes(markdown: markdown).sessions.filter {
            $0.date == formatSessionDate(today)
        }
        XCTAssertEqual(sessions.count, 2)

        let first = try resolveTaskRef(TaskRef(sessionDate: todayISO, sessionOrdinal: 0, lineIndex: 0),
                                       rawText: markdown)
        let second = try resolveTaskRef(TaskRef(sessionDate: todayISO, sessionOrdinal: 1, lineIndex: 0),
                                        rawText: markdown)
        XCTAssertEqual(try text(markdown, first), "Evening task")
        XCTAssertEqual(try text(markdown, second), "Morning task")
    }

    // MARK: Refusal

    func testRenamedTaskRefuses() throws {
        let renamed = try editTodosPreservingFormat(rawText: fixture()) {
            setTextOnTodoAt(notes: normalizeFocusMarker(notes: $0), sessionIndex: 0, lineIndex: 2,
                            text: "Review the contract with legal")
        }!
        let ref = TaskRef(sessionDate: yesterdayISO, lineIndex: 2, digest: taskDigest("Review the contract"))
        XCTAssertThrowsError(try resolveTaskRef(ref, rawText: renamed)) { error in
            guard case PmError.staleReference = error else { return XCTFail("expected staleReference, got \(error)") }
        }
    }

    /// Duplicate text is ordinary, so once the position check has failed there is nothing safe to do.
    func testAmbiguousDigestRefuses() throws {
        let markdown = """
        # T

        ## Sessions

        ### \(yesterday)

        - [ ] Follow up
        - [ ] Something else
        - [ ] Follow up
        """
        let ref = TaskRef(sessionDate: yesterdayISO, lineIndex: 1, digest: taskDigest("Follow up"))
        XCTAssertThrowsError(try resolveTaskRef(ref, rawText: markdown)) { error in
            guard case PmError.staleReference = error else { return XCTFail("expected staleReference, got \(error)") }
        }
    }

    func testUnknownSessionDateRefuses() {
        let ref = TaskRef(sessionDate: "2020-01-01", lineIndex: 0, digest: taskDigest("Draft the summary"))
        XCTAssertThrowsError(try resolveTaskRef(ref, rawText: fixture()))
    }

    /// Without a digest there is nothing to verify, but a position that names nothing is still an
    /// error worth reporting as one.
    func testMissingPositionRefusesEvenWithoutADigest() {
        XCTAssertThrowsError(try resolveTaskRef(TaskRef(sessionIndex: 0, lineIndex: 99), rawText: fixture()))
        XCTAssertThrowsError(try resolveTaskRef(TaskRef(sessionIndex: 7, lineIndex: 0), rawText: fixture()))
    }

    /// A digest-less reference is the old behaviour exactly: act on the position given.
    func testDigestlessReferenceActsOnThePosition() throws {
        let resolved = try resolveTaskRef(TaskRef(sessionIndex: 0, lineIndex: 1), rawText: fixture())
        XCTAssertFalse(resolved.relocated)
        XCTAssertEqual(try text(fixture(), resolved), "Email Dana about pricing")
    }
}
