import XCTest
@testable import PmLib

/// Tests for the format-preserving task-insertion primitives and inline due editing that back
/// `pm notes todo add` / `pm notes todo due`.
final class TaskAddDueTests: XCTestCase {
    static let markdown = """
    ---
    tags: [project]
    ---
    # My Project

    > [!summary] Summary
    > One line summary.

    ## Sessions

    ### Wed, Feb 25, 2025

    - [ ] Todo one
    - [ ] Todo two @
    - [x] Todo three

    #project-tag
    """

    /// Markdown with no session for "today" so quick-add must create one. Uses a 2-space indented child.
    static let nested = """
    # P

    ## Sessions

    ### Wed, Feb 25, 2025

    - [ ] Parent
      - [ ] Child A
    """

    private func todos(_ raw: String) throws -> [Todo] {
        try parseTodos(notes: parseNotes(markdown: raw))
    }

    // MARK: - insertTaskRelative

    func testInsertAfterKeepsIndentAndOrder() throws {
        let r = try XCTUnwrap(insertTaskRelative(
            rawText: Self.markdown, anchorSessionIndex: 0, anchorLineIndex: 0,
            text: "Inserted", due: nil, position: .after))
        XCTAssertEqual(r.sessionIndex, 0)
        XCTAssertEqual(r.lineIndex, 1)
        let parsed = try todos(r.rawText)
        XCTAssertEqual(parsed.map(\.text), ["Todo one", "Inserted", "Todo two", "Todo three"])
        XCTAssertEqual(parsed[1].depth, 0)
        XCTAssertFalse(parsed[1].checked)
        // Original focus on "Todo two" survives the insert.
        XCTAssertTrue(try XCTUnwrap(parsed.first { $0.text == "Todo two" }).isFocused)
    }

    func testInsertBeforeTakesAnchorSlot() throws {
        let r = try XCTUnwrap(insertTaskRelative(
            rawText: Self.markdown, anchorSessionIndex: 0, anchorLineIndex: 1,
            text: "Before two", due: nil, position: .before))
        XCTAssertEqual(r.lineIndex, 1)
        let parsed = try todos(r.rawText)
        XCTAssertEqual(parsed.map(\.text), ["Todo one", "Before two", "Todo two", "Todo three"])
    }

    func testInsertChildIndentsTwoSpaces() throws {
        let r = try XCTUnwrap(insertTaskRelative(
            rawText: Self.nested, anchorSessionIndex: 0, anchorLineIndex: 0,
            text: "New child", due: nil, position: .child))
        XCTAssertEqual(r.lineIndex, 1)
        let parsed = try todos(r.rawText)
        XCTAssertEqual(parsed.map(\.text), ["Parent", "New child", "Child A"])
        XCTAssertEqual(parsed[1].depth, 1, "Child sits one level deeper than its parent")
    }

    func testInsertWithDueRoundTrips() throws {
        let r = try XCTUnwrap(insertTaskRelative(
            rawText: Self.markdown, anchorSessionIndex: 0, anchorLineIndex: 2,
            text: "Deadlined", due: "2026-07-15", position: .after))
        let parsed = try todos(r.rawText)
        let added = try XCTUnwrap(parsed.first { $0.text == "Deadlined" })
        XCTAssertEqual(added.dueDate, "2026-07-15")
    }

    func testInsertReturnsNilForMissingAnchor() throws {
        XCTAssertNil(insertTaskRelative(
            rawText: Self.markdown, anchorSessionIndex: 9, anchorLineIndex: 0,
            text: "x", due: nil, position: .after))
    }

    // MARK: - appendTaskToSession

    func testAppendGoesAfterLastTask() throws {
        let r = try XCTUnwrap(appendTaskToSession(
            rawText: Self.markdown, sessionIndex: 0, text: "Appended", due: nil))
        XCTAssertEqual(r.lineIndex, 3)
        let parsed = try todos(r.rawText)
        XCTAssertEqual(parsed.map(\.text), ["Todo one", "Todo two", "Todo three", "Appended"])
    }

    func testAppendPreservesEverythingElse() throws {
        let r = try XCTUnwrap(appendTaskToSession(
            rawText: Self.markdown, sessionIndex: 0, text: "Appended", due: nil))
        let before = Self.markdown.components(separatedBy: "\n")
        let after = r.rawText.components(separatedBy: "\n")
        XCTAssertEqual(after.count, before.count + 1, "Exactly one line added")
        // Frontmatter and trailing tag untouched.
        XCTAssertEqual(after.first, "---")
        XCTAssertEqual(after.last, "#project-tag")
    }

    // MARK: - setDueOnTodoAt

    func testSetDuePreservesFocusMarker() throws {
        // "Todo two" (lineIndex 1) is the focused task.
        let updated = setDueOnTodoAt(
            notes: try parseNotes(markdown: Self.markdown), sessionIndex: 0, lineIndex: 1, due: "2026-08-01")
        let parsed = try parseTodos(notes: updated)
        let two = try XCTUnwrap(parsed.first { $0.text == "Todo two" })
        XCTAssertEqual(two.dueDate, "2026-08-01")
        XCTAssertTrue(two.isFocused, "Focus marker must survive setting a due date")
    }

    func testSetDueThenClear() throws {
        let withDue = setDueOnTodoAt(
            notes: try parseNotes(markdown: Self.markdown), sessionIndex: 0, lineIndex: 0, due: "2026-08-01")
        XCTAssertEqual(try XCTUnwrap(parseTodos(notes: withDue).first).dueDate, "2026-08-01")
        let cleared = setDueOnTodoAt(notes: withDue, sessionIndex: 0, lineIndex: 0, due: nil)
        XCTAssertNil(try XCTUnwrap(parseTodos(notes: cleared).first).dueDate)
        // Clearing returns the line to its original text.
        XCTAssertEqual(try XCTUnwrap(parseTodos(notes: cleared).first).text, "Todo one")
    }

    func testDueViaPreservingSplice() throws {
        // The full CLI path goes through editTodosPreservingFormat — verify it splices one line.
        let updated = try editTodosPreservingFormat(rawText: Self.markdown) { notes in
            setDueOnTodoAt(notes: notes, sessionIndex: 0, lineIndex: 0, due: "2026-09-09")
        }
        let result = try XCTUnwrap(updated)
        let diffs = zip(Self.markdown.components(separatedBy: "\n"), result.components(separatedBy: "\n"))
            .filter { $0 != $1 }
        XCTAssertEqual(diffs.count, 1, "Only the dated task line changes")
    }
}
