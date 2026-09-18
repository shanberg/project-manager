import XCTest
@testable import PmLib

/// A task closed without being done — `- [-]`. See docs/sessions.md D6.
final class DroppedTaskTests: XCTestCase {

    private func notes(_ body: String) -> ProjectNotes {
        ProjectNotes(title: "T", sessions: [Session(date: "Mon, Sep 14, 2026", label: "", body: body)])
    }

    private func body(_ notes: ProjectNotes) -> String { notes.sessions[0].body }

    // MARK: Reading

    func testEachBoxReadsAsItsState() throws {
        let todos = try parseTodos(notes: notes("- [ ] Open\n- [x] Done\n- [X] Shouted\n- [-] Dropped"))
        XCTAssertEqual(todos.map(\.state), [.open, .done, .done, .dropped])
        XCTAssertEqual(todos.map(\.checked), [false, true, true, true],
                       "checked means closed, so everything that hides finished work hides dropped work too")
    }

    /// Before this, `- [-]` wasn't a task line at all — it was prose, and didn't take a line index. It
    /// is one now, so the task after it counts it.
    func testADroppedLineTakesAPosition() throws {
        let todos = try parseTodos(notes: notes("- [-] Dropped\n- [ ] After"))
        XCTAssertEqual(todos.last?.lineIndex, 1)
    }

    func testAnUnknownBoxIsStillProse() throws {
        XCTAssertEqual(try parseTodos(notes: notes("- [?] A question\n- [ ] Task")).map(\.text), ["Task"])
    }

    // MARK: Dropping

    func testDroppingTakesTheOpenSubtreeAndLeavesTheDoneAlone() throws {
        let before = notes("- [ ] Parent\n  - [ ] Open child\n  - [x] Done child\n- [ ] Next")
        let after = try dropTodoWithDescendants(notes: before, sessionIndex: 0, lineIndex: 0, advanceFocus: false)
        XCTAssertEqual(body(after), "- [-] Parent\n  - [-] Open child\n  - [x] Done child\n- [ ] Next",
                       "a child that was done was done — dropping its parent doesn't rewrite that")
    }

    func testCompletingLeavesADroppedChildDropped() throws {
        let before = notes("- [ ] Parent\n  - [-] Let go\n  - [ ] Still to do")
        let after = try completeTodoWithDescendants(notes: before, sessionIndex: 0, lineIndex: 0, advanceFocus: false)
        XCTAssertEqual(body(after), "- [x] Parent\n  - [-] Let go\n  - [x] Still to do")
    }

    /// A dropped task is as finished with as a done one, as far as what to do next goes.
    func testFocusMovesOnFromADroppedTask() throws {
        let before = notes("- [ ] First @\n- [ ] Second")
        let after = try dropTodoWithDescendants(notes: before, sessionIndex: 0, lineIndex: 0, advanceFocus: true)
        XCTAssertEqual(body(after), "- [-] First\n- [ ] Second @")
    }

    /// Only the line being closed changes: an `X` elsewhere stays an `X`, since the file is someone's.
    func testOtherLinesAreLeftAsWritten() throws {
        let before = notes("- [X] Shouted\n- [ ] Drop me")
        let after = try dropTodoWithDescendants(notes: before, sessionIndex: 0, lineIndex: 1, advanceFocus: false)
        XCTAssertEqual(body(after), "- [X] Shouted\n- [-] Drop me")
    }

    func testReopeningADroppedTaskOpensItAndFocusesIt() throws {
        let after = try undoTodoAt(notes: notes("- [-] Changed my mind\n- [ ] Other @"), sessionIndex: 0, lineIndex: 0)
        XCTAssertEqual(body(after), "- [ ] Changed my mind @\n- [ ] Other")
    }

    // MARK: What the contract says about it

    func testTheDiffCallsItADrop() throws {
        let before = try parseTodos(notes: notes("- [ ] A\n  - [ ] B"))
        let after = try parseTodos(notes: dropTodoWithDescendants(notes: notes("- [ ] A\n  - [ ] B"),
                                                                  sessionIndex: 0, lineIndex: 0, advanceFocus: false))
        let changes = diffTodos(before: before, after: after)
        XCTAssertEqual(changes.map(\.kind), [.dropped, .dropped])
        XCTAssertEqual(summarize(action: "task.drop", changes: changes).past, "Dropped \u{201C}A\u{201D} and 1 subtask")
    }

    func testMovingBetweenDoneAndDroppedIsReported() throws {
        let before = try parseTodos(notes: notes("- [x] A"))
        let after = try parseTodos(notes: notes("- [-] A"))
        XCTAssertEqual(diffTodos(before: before, after: after).map(\.kind), [.dropped])
    }

    // MARK: Elsewhere

    func testAPastedDroppedTaskStaysDropped() throws {
        let raw = "# P\n\n## Sessions\n\n### Mon, Sep 14, 2026\n\n- [ ] Anchor\n"
        let out = try XCTUnwrap(insertTaskBlockPreservingFormat(
            rawText: raw, anchorSessionIndex: 0, anchorLineIndex: 0,
            block: [PastedTask(depth: 0, text: "Let go", state: .dropped)]))
        XCTAssertTrue(out.contains("- [-] Let go"))
    }

    /// Return on a dropped task's line starts a fresh, open one — the same as after a done one.
    func testTheEditorContinuesADroppedLineWithAnOpenBox() {
        let prefix = markdownListPrefix(of: "- [-] Dropped")
        XCTAssertEqual(prefix?.checkbox, "[-]")
        XCTAssertEqual(prefix?.next, "- [ ] ")
    }
}
