import XCTest
@testable import PmLib

/// parseTodos can throw notesRegexError only from regex compilation (internal constant); there is no user-input path that triggers a throw.
/// All tests here use valid session bodies; the regex is exercised by these tests and by NotesRoundTripTests.
final class NotesTodosTests: XCTestCase {

    /// Empty sessions yield no todos.
    func testParseTodosEmptySessions() throws {
        let notes = ProjectNotes(title: "T", sessions: [])
        let todos = try parseTodos(notes: notes)
        XCTAssertEqual(todos.count, 0)
    }

    /// Session with no body lines yields no todos.
    func testParseTodosEmptySessionBody() throws {
        let session = Session(date: "Wed, Feb 25, 2025", label: "", body: "")
        let notes = ProjectNotes(title: "T", sessions: [session])
        let todos = try parseTodos(notes: notes)
        XCTAssertEqual(todos.count, 0)
    }

    /// Unchecked todo: text, checked false, context is session date when label empty.
    func testParseTodosUncheckedTodo() throws {
        let session = Session(date: "Wed, Feb 25, 2025", label: "", body: "- [ ] First task")
        let notes = ProjectNotes(title: "T", sessions: [session])
        let todos = try parseTodos(notes: notes)
        XCTAssertEqual(todos.count, 1)
        XCTAssertEqual(todos[0].text, "First task")
        XCTAssertFalse(todos[0].checked)
        XCTAssertEqual(todos[0].context, "Wed, Feb 25, 2025")
        XCTAssertTrue(todos[0].rawLine.contains("[ ]"))
    }

    /// Checked todo: checked true.
    func testParseTodosCheckedTodo() throws {
        let session = Session(date: "Thu, Mar 6, 2025", label: "", body: "- [x] Done item")
        let notes = ProjectNotes(title: "T", sessions: [session])
        let todos = try parseTodos(notes: notes)
        XCTAssertEqual(todos.count, 1)
        XCTAssertEqual(todos[0].text, "Done item")
        XCTAssertTrue(todos[0].checked)
        XCTAssertEqual(todos[0].context, "Thu, Mar 6, 2025")
    }

    /// Session with label: context is "date · label".
    func testParseTodosSessionWithLabel() throws {
        let session = Session(date: "Thu, Mar 6, 2025", label: "Sprint 1", body: "- [ ] In progress")
        let notes = ProjectNotes(title: "T", sessions: [session])
        let todos = try parseTodos(notes: notes)
        XCTAssertEqual(todos.count, 1)
        XCTAssertEqual(todos[0].context, "Thu, Mar 6, 2025 · Sprint 1")
    }

    /// Multiple todos in one session; order preserved.
    func testParseTodosMultipleInSession() throws {
        let session = Session(
            date: "Wed, Feb 25, 2025",
            label: "",
            body: "- [ ] One\n- [x] Two\n- [ ] Three"
        )
        let notes = ProjectNotes(title: "T", sessions: [session])
        let todos = try parseTodos(notes: notes)
        XCTAssertEqual(todos.count, 3)
        XCTAssertEqual(todos[0].text, "One")
        XCTAssertFalse(todos[0].checked)
        XCTAssertEqual(todos[1].text, "Two")
        XCTAssertTrue(todos[1].checked)
        XCTAssertEqual(todos[2].text, "Three")
        XCTAssertFalse(todos[2].checked)
    }

    /// Multiple sessions: todos from each session with correct context.
    func testParseTodosMultipleSessions() throws {
        let s1 = Session(date: "Mon, Jan 1, 2025", label: "", body: "- [ ] A")
        let s2 = Session(date: "Tue, Jan 2, 2025", label: "Day 2", body: "- [x] B")
        let notes = ProjectNotes(title: "T", sessions: [s1, s2])
        let todos = try parseTodos(notes: notes)
        XCTAssertEqual(todos.count, 2)
        XCTAssertEqual(todos[0].text, "A")
        XCTAssertEqual(todos[0].context, "Mon, Jan 1, 2025")
        XCTAssertEqual(todos[1].text, "B")
        XCTAssertEqual(todos[1].context, "Tue, Jan 2, 2025 · Day 2")
    }

    /// Non-todo lines in body are ignored.
    func testParseTodosSkipsNonTodoLines() throws {
        let session = Session(
            date: "Wed, Feb 25, 2025",
            label: "",
            body: "Plain text\n- [ ] Only todo\n## Heading"
        )
        let notes = ProjectNotes(title: "T", sessions: [session])
        let todos = try parseTodos(notes: notes)
        XCTAssertEqual(todos.count, 1)
        XCTAssertEqual(todos[0].text, "Only todo")
    }
}
