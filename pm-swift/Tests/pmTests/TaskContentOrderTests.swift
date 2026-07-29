import XCTest
@testable import PmLib

/// Tests for `TaskContent` — the one place that knows how a task line encodes its text, inline
/// `due:` and ` @` focus marker. Canonical storage order is "<text> due: <date> @", but a line
/// written by an older or third-party client can carry the two tokens the other way round. Every
/// mutation must read such a line correctly (rather than missing the marker with a raw suffix check
/// and silently dropping focus) and write it back canonically.
final class TaskContentOrderTests: XCTestCase {
    /// A session whose focused task stores its due *after* the marker — the legacy inverted order.
    static let inverted = """
    # P

    ## Sessions

    ### Wed, Feb 25, 2025

    - [ ] Todo one
    - [ ] Todo two @ due: 2026-08-04 22:21
    - [ ] Todo three
    """

    // MARK: - split / render

    func testSplitAcceptsBothOrders() {
        let canonical = TaskContent.split("Write it up due: 2026-08-04 22:21 @")
        let legacy = TaskContent.split("Write it up @ due: 2026-08-04 22:21")
        XCTAssertEqual(canonical, legacy)
        XCTAssertEqual(canonical.text, "Write it up")
        XCTAssertEqual(canonical.due, "2026-08-04 22:21")
        XCTAssertTrue(canonical.focused)
    }

    func testRenderIsCanonical() {
        XCTAssertEqual(
            TaskContent.split("Write it up @ due: 2026-08-04 22:21").render(),
            "Write it up due: 2026-08-04 22:21 @")
    }

    func testSplitLeavesOrdinaryTextAlone() {
        let parts = TaskContent.split("Email bob@example.com about due dates")
        XCTAssertEqual(parts.text, "Email bob@example.com about due dates")
        XCTAssertNil(parts.due)
        XCTAssertFalse(parts.focused)
        XCTAssertEqual(parts.render(), "Email bob@example.com about due dates")
    }

    func testSplitHandlesEachTokenAlone() {
        let dueOnly = TaskContent.split("Ship it due: 2026-08-04")
        XCTAssertEqual(dueOnly.due, "2026-08-04")
        XCTAssertFalse(dueOnly.focused)
        XCTAssertEqual(dueOnly.text, "Ship it")

        let focusOnly = TaskContent.split("Ship it @")
        XCTAssertNil(focusOnly.due)
        XCTAssertTrue(focusOnly.focused)
        XCTAssertEqual(focusOnly.text, "Ship it")
    }

    // MARK: - parsing

    func testParseReadsInvertedLine() throws {
        let todos = try parseTodos(notes: parseNotes(markdown: Self.inverted))
        let two = try XCTUnwrap(todos.first { $0.text == "Todo two" })
        XCTAssertEqual(two.dueDate, "2026-08-04 22:21")
        XCTAssertTrue(two.isFocused)
    }

    // MARK: - mutations on an inverted line

    func testSetDueKeepsFocusOnInvertedLine() throws {
        let updated = setDueOnTodoAt(
            notes: try parseNotes(markdown: Self.inverted), sessionIndex: 0, lineIndex: 1, due: "2026-09-01")
        let two = try XCTUnwrap(parseTodos(notes: updated).first { $0.text == "Todo two" })
        XCTAssertEqual(two.dueDate, "2026-09-01")
        XCTAssertTrue(two.isFocused, "Setting a due must not eat the focus marker")
        XCTAssertEqual(two.rawLine, "- [ ] Todo two due: 2026-09-01 @", "Rewritten in canonical order")
    }

    func testSetTextKeepsDueAndFocusOnInvertedLine() throws {
        let updated = setTextOnTodoAt(
            notes: try parseNotes(markdown: Self.inverted), sessionIndex: 0, lineIndex: 1, text: "Todo two, revised")
        let two = try XCTUnwrap(parseTodos(notes: updated).first { $0.text == "Todo two, revised" })
        XCTAssertEqual(two.dueDate, "2026-08-04 22:21")
        XCTAssertTrue(two.isFocused)
    }

    func testClearingDueOnInvertedLineKeepsFocus() throws {
        let updated = setDueOnTodoAt(
            notes: try parseNotes(markdown: Self.inverted), sessionIndex: 0, lineIndex: 1, due: nil)
        let two = try XCTUnwrap(parseTodos(notes: updated).first { $0.text == "Todo two" })
        XCTAssertNil(two.dueDate)
        XCTAssertTrue(two.isFocused)
        XCTAssertEqual(two.rawLine, "- [ ] Todo two @")
    }

    func testCompleteKeepsDueAndDropsFocusOnInvertedLine() throws {
        let updated = try completeTodoWithDescendants(
            notes: parseNotes(markdown: Self.inverted), sessionIndex: 0, lineIndex: 1, advanceFocus: false)
        let two = try XCTUnwrap(parseTodos(notes: updated).first { $0.text == "Todo two" })
        XCTAssertTrue(two.checked)
        XCTAssertEqual(two.dueDate, "2026-08-04 22:21")
        XCTAssertFalse(two.isFocused)
    }

    // MARK: - normalization / repair

    func testNormalizeSeesInvertedMarkerAndRepairsOrder() throws {
        // The inverted line holds focus; a canonical marker further down must lose it, not win.
        let raw = Self.inverted.replacingOccurrences(of: "- [ ] Todo three", with: "- [ ] Todo three @")
        let normalized = normalizeFocusMarker(notes: try parseNotes(markdown: raw))
        let todos = try parseTodos(notes: normalized)
        XCTAssertEqual(todos.filter(\.isFocused).map(\.text), ["Todo two"])
        XCTAssertEqual(
            try XCTUnwrap(todos.first { $0.text == "Todo two" }).rawLine,
            "- [ ] Todo two due: 2026-08-04 22:21 @")
        XCTAssertEqual(try XCTUnwrap(todos.first { $0.text == "Todo three" }).rawLine, "- [ ] Todo three")
    }

    func testInvertedLineIsRepairedByTheSplicePath() throws {
        // The CLI path: any edit runs normalizeFocusMarker first, so a stored inverted line is
        // rewritten canonically in the raw markdown while every other byte stays put.
        let updated = try XCTUnwrap(editTodosPreservingFormat(rawText: Self.inverted) { notes in
            normalizeFocusMarker(notes: notes)
        })
        XCTAssertTrue(updated.contains("- [ ] Todo two due: 2026-08-04 22:21 @"))
        XCTAssertFalse(updated.contains("@ due:"))
        let diffs = zip(Self.inverted.components(separatedBy: "\n"), updated.components(separatedBy: "\n"))
            .filter { $0 != $1 }
        XCTAssertEqual(diffs.count, 1, "Only the inverted line changes")
    }

    func testCanonicalNotesAreLeftUntouched() throws {
        // Normalization must be a no-op on a file that's already canonical (no spurious writes).
        let canonical = Self.inverted.replacingOccurrences(
            of: "- [ ] Todo two @ due: 2026-08-04 22:21",
            with: "- [ ] Todo two due: 2026-08-04 22:21 @")
        XCTAssertNil(try editTodosPreservingFormat(rawText: canonical) { notes in
            normalizeFocusMarker(notes: notes)
        })
    }
}
