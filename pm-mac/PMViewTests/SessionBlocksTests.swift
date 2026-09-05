import XCTest
import PmLib
@testable import PMViewTests

/// Cutting a session's body into the blocks the window draws.
///
/// The behaviour under test is that nothing moves: a task line is a row where it sits in the body, and
/// the prose either side of it is prose either side of it. The window used to render a session as its
/// leading prose followed by every task in it, which put a task nowhere near the sentence that
/// explained it and dropped prose written after a task on the floor.
final class SessionBlocksTests: XCTestCase {
    /// The tasks `parseTodos` makes from a body, which is exactly what the store hands the view.
    private func tasks(in body: String) throws -> [Todo] {
        let notes = ProjectNotes(title: "T", sessions: [Session(date: "Wed, Mar 05, 2025", label: "", body: body)])
        return try parseTodos(notes: notes)
    }

    /// Every task shown, identified by its text so the assertions read.
    private func allVisible(_ todo: Todo) -> IdentifiedTodo? {
        IdentifiedTodo(id: todo.rawLine, todo: todo)
    }

    private func shape(_ blocks: [SessionBlock]) -> [String] {
        blocks.map { block in
            switch block {
            case .prose(_, let text): return "prose: \(text)"
            case .task(let row): return "task: \(row.todo.text)"
            }
        }
    }

    /// A body of alternating prose and tasks comes back alternating, in document order.
    func testProseAndTasksInterleaveInDocumentOrder() throws {
        let body = """
        Started on the parser.

        - [ ] Fix the tokenizer

        The lexer is the real problem.

        - [ ] Rewrite the lexer
        """
        let blocks = SessionBody.blocks(body: body, tasks: try tasks(in: body), visible: allVisible)
        XCTAssertEqual(shape(blocks), [
            "prose: Started on the parser.",
            "task: Fix the tokenizer",
            "prose: The lexer is the real problem.",
            "task: Rewrite the lexer",
        ])
    }

    /// Prose written *after* the last task is a block of its own. It used to be invisible: the window
    /// read a session's note as the lines above its first task, so this paragraph was on disk and
    /// nowhere on screen.
    func testProseAfterTheLastTaskIsDrawn() throws {
        let body = "- [ ] Ring the vet\n\nThey close at five."
        let blocks = SessionBody.blocks(body: body, tasks: try tasks(in: body), visible: allVisible)
        XCTAssertEqual(shape(blocks), ["task: Ring the vet", "prose: They close at five."])
    }

    /// Consecutive task lines produce no prose blocks between them — a run of tasks is a run of rows,
    /// with nothing invented to separate them.
    func testConsecutiveTasksHaveNoProseBetweenThem() throws {
        let body = "Notes.\n\n- [ ] One\n- [ ] Two\n  - [ ] Nested"
        let blocks = SessionBody.blocks(body: body, tasks: try tasks(in: body), visible: allVisible)
        XCTAssertEqual(shape(blocks), ["prose: Notes.", "task: One", "task: Two", "task: Nested"])
    }

    /// A body with no tasks is one prose block; a body with nothing in it is no blocks at all.
    func testProseOnlyAndEmptyBodies() throws {
        XCTAssertEqual(shape(SessionBody.blocks(body: "Just a note.", tasks: [], visible: allVisible)),
                       ["prose: Just a note."])
        XCTAssertTrue(SessionBody.blocks(body: "", tasks: [], visible: allVisible).isEmpty)
        XCTAssertTrue(SessionBody.blocks(body: "\n\n  \n", tasks: [], visible: allVisible).isEmpty)
    }

    /// Two identical task lines are two rows, in order — the walk advances a cursor rather than
    /// searching, so a duplicate line can't match the same task twice.
    func testDuplicateTaskLinesBecomeTwoRows() throws {
        let body = "- [ ] Follow up\n- [ ] Follow up"
        let blocks = SessionBody.blocks(body: body, tasks: try tasks(in: body), visible: allVisible)
        XCTAssertEqual(shape(blocks), ["task: Follow up", "task: Follow up"])
    }

    /// A filtered-out task is stepped over, and the tasks after it stay on their own lines. This is the
    /// alignment the walk depends on: the hidden task still occupies a body line, so it has to be
    /// matched and then dropped rather than left out of `tasks`.
    func testAHiddenTaskDoesNotShiftTheOnesAfterIt() throws {
        let body = """
        Morning.

        - [x] Done already

        Afternoon.

        - [ ] Still open
        """
        let all = try tasks(in: body)
        let blocks = SessionBody.blocks(body: body, tasks: all,
                                        visible: { $0.checked ? nil : self.allVisible($0) })
        XCTAssertEqual(shape(blocks), [
            "prose: Morning.",
            "prose: Afternoon.",
            "task: Still open",
        ])
    }

    /// The safety net: tasks the walk couldn't place in the body still get rows, at the end. It should
    /// never fire — they come from this body — but a task quietly disappearing from the window it's
    /// managed in is the worse failure.
    func testUnplaceableTasksStillGetRows() throws {
        let stray = Todo(text: "Orphan", checked: false, rawLine: "- [ ] Orphan", context: "")
        let blocks = SessionBody.blocks(body: "Only prose here.", tasks: [stray], visible: allVisible)
        XCTAssertEqual(shape(blocks), ["prose: Only prose here.", "task: Orphan"])
    }
}
