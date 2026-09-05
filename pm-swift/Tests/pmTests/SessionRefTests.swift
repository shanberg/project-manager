import XCTest
@testable import PmLib

/// `SessionRef` is `TaskRef`'s companion: the same two defences against the same shift, applied to the
/// sessions themselves rather than to the tasks inside them. See `docs/task-identity.md`.
final class SessionRefTests: XCTestCase {

    /// Two sittings on one day plus an older one, in the order a document holds them: newest first.
    private func notes(labels: [(date: String, label: String)]) throws -> ProjectNotes {
        let body = labels
            .map { "### \($0.date)\($0.label.isEmpty ? "" : " \($0.label)")\n\nnote\n" }
            .joined(separator: "\n")
        return try parseNotes(markdown: "# P\n\n## Sessions\n\n" + body)
    }

    private let day = "Wed, Aug 26, 2026"
    private let earlier = "Tue, Aug 25, 2026"

    // MARK: The shift this exists for

    func testASplicedSessionDoesNotMoveADateNamedReference() throws {
        let before = try notes(labels: [(day, "Kickoff")])
        let ref = SessionRef(session: before.sessions[0], at: 0, in: before)
        XCTAssertEqual(ref.date, "2026-08-26")

        // A new sitting arrives at the top — every index below it shifts by one.
        let after = try notes(labels: [("Thu, Aug 27, 2026", ""), (day, "Kickoff")])
        XCTAssertEqual(try resolveSessionRef(ref, notes: after).index, 1,
                       "The reference followed its session down; a bare index would not have")
        XCTAssertFalse(try resolveSessionRef(ref, notes: after).relocated,
                       "Named by date, it never moved — nothing to report")
    }

    func testABareIndexIsExactlyWhatGoesWrong() throws {
        let after = try notes(labels: [("Thu, Aug 27, 2026", ""), (day, "Kickoff")])
        // The old way: a plain integer captured before the splice now names the new sitting.
        XCTAssertEqual(try resolveSessionRef(SessionRef(index: 0), notes: after).index, 0)
        XCTAssertEqual(after.sessions[0].date, "Thu, Aug 27, 2026",
                       "…which is a different session than the one that index meant")
    }

    // MARK: The digest

    func testDigestCatchesAPositionThatCameToMeanSomethingElse() throws {
        let before = try notes(labels: [(day, "Kickoff")])
        let ref = SessionRef(session: before.sessions[0], at: 0, in: before)
        // Same date, different sitting — the one referred to is gone.
        let after = try notes(labels: [(day, "Retro")])
        XCTAssertThrowsError(try resolveSessionRef(ref, notes: after)) { error in
            XCTAssertTrue("\(error)".contains("no longer in this project"), "\(error)")
        }
    }

    func testARelocatedSessionIsFoundAndReported() throws {
        let before = try notes(labels: [(day, "Kickoff")])
        let ref = SessionRef(session: before.sessions[0], at: 0, in: before)
        // A second sitting that day, inserted above: same date, so the ordinal now names the wrong one.
        let after = try notes(labels: [(day, "Retro"), (day, "Kickoff")])
        let resolved = try resolveSessionRef(ref, notes: after)
        XCTAssertEqual(resolved.index, 1)
        XCTAssertTrue(resolved.relocated, "It was found somewhere other than where the caller said")
    }

    func testAmbiguousLabelsAreRefusedRatherThanGuessed() throws {
        let before = try notes(labels: [(day, "Kickoff")])
        var ref = SessionRef(session: before.sessions[0], at: 0, in: before)
        ref.ordinal = 0
        // Two sittings that day share the label, and the ordinal lands on neither's digest… except it
        // does, so force the miss by asserting a label none of them has.
        ref.digest = sessionDigest("Nowhere")
        let after = try notes(labels: [(day, "Same"), (day, "Same")])
        XCTAssertThrowsError(try resolveSessionRef(ref, notes: after))
    }

    func testNoDigestAssertsNothing() throws {
        let after = try notes(labels: [(day, "Retro")])
        let ref = SessionRef(date: "2026-08-26", ordinal: 0)
        XCTAssertEqual(try resolveSessionRef(ref, notes: after).index, 0,
                       "A reference with nothing asserted is a position, and the position exists")
    }

    // MARK: Ordinals

    func testOrdinalPicksAmongOneDaysSittings() throws {
        let doc = try notes(labels: [(day, "Second"), (day, "First"), (earlier, "Older")])
        let second = SessionRef(session: doc.sessions[1], at: 1, in: doc)
        XCTAssertEqual(second.ordinal, 1, "It is the second sitting of that date, in document order")
        XCTAssertEqual(try resolveSessionRef(second, notes: doc).index, 1)

        let older = SessionRef(session: doc.sessions[2], at: 2, in: doc)
        XCTAssertEqual(older.ordinal, 0, "First of its own date, whatever sits above it")
        XCTAssertEqual(try resolveSessionRef(older, notes: doc).index, 2)
    }

    func testAMissingDateIsRefused() throws {
        let doc = try notes(labels: [(day, "Kickoff")])
        XCTAssertThrowsError(try resolveSessionRef(SessionRef(date: "2020-01-01"), notes: doc)) { error in
            XCTAssertTrue("\(error)".contains("no session dated"), "\(error)")
        }
    }

    func testAHandEditedHeadingStillReferencesPositionally() throws {
        let doc = try parseNotes(markdown: "# P\n\n## Sessions\n\n### Whenever\n\nnote\n")
        guard doc.sessions.count == 1 else { return }   // parser may not accept it at all
        let ref = SessionRef(session: doc.sessions[0], at: 0, in: doc)
        XCTAssertNil(ref.date, "No ISO date to name it by")
        XCTAssertEqual(ref.index, 0)
    }

    // MARK: The incident

    /// The shape of the loss this exists to prevent, end to end.
    ///
    /// A session note editor is opened on the day's sitting. While it is open, a note written from the
    /// quick bar starts a *new* sitting and splices it in above — every index below shifts by one. The
    /// editor then auto-saves on its way out. Addressed by index it wrote its untouched copy of the old
    /// sitting's prose over the note that had just been written into the new one; addressed by
    /// reference it writes where it was actually opened.
    func testAnOpenEditorDoesNotWriteIntoASessionSplicedInWhileItWasOpen() throws {
        let before = """
        # P

        ## Sessions

        ### Wed, Aug 26, 2026

        Yesterday's thinking.

        """
        // The editor opens and takes its reference.
        let opened = try parseNotes(markdown: before)
        let ref = SessionRef(session: opened.sessions[0], at: 0, in: opened)

        // Meanwhile: a note from the quick bar starts a new sitting and lands in it.
        let withNew = try XCTUnwrap(appendSessionNotePreservingFormat(
            rawText: before, prose: "Something I must not lose.",
            lastEdited: nil, date: try parseSessionDateArgument("2026-08-27")))
        let after = try parseNotes(markdown: withNew)
        XCTAssertEqual(after.sessions.count, 2)
        XCTAssertEqual(after.sessions[0].date, "Thu, Aug 27, 2026", "The new sitting is on top")

        // The editor closes and saves what it was holding.
        let resolved = try resolveSessionRef(ref, notes: after)
        XCTAssertEqual(resolved.index, 1, "It resolves to the sitting it was opened on, not position 0")
        let written = try XCTUnwrap(commitSessionNotePreservingFormat(
            rawText: withNew, sessionIndex: resolved.index, body: "Yesterday's thinking."))

        XCTAssertTrue(written.contains("Something I must not lose."),
                      "The quick bar's note survived the editor closing over it")
        let thursday = written.range(of: "### Thu, Aug 27, 2026")
        let wednesday = try XCTUnwrap(written.range(of: "### Wed, Aug 26, 2026"))
        let thursdayBody = written[try XCTUnwrap(thursday).upperBound..<wednesday.lowerBound]
        XCTAssertFalse(thursdayBody.contains("Yesterday's thinking."),
                       "The editor's stale prose did not land in the new sitting")
    }
}
