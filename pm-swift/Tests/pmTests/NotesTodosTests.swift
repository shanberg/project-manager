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

    /// Depth from indent: 0 spaces = depth 0, 2 spaces = depth 1, 4 = depth 2.
    func testParseTodosDepthFromIndent() throws {
        let session = Session(
            date: "Wed, Feb 25, 2025",
            label: "",
            body: "- [ ] Root\n  - [ ] Child\n    - [ ] Grandchild"
        )
        let notes = ProjectNotes(title: "T", sessions: [session])
        let todos = try parseTodos(notes: notes)
        XCTAssertEqual(todos.count, 3)
        XCTAssertEqual(todos[0].depth, 0)
        XCTAssertEqual(todos[0].text, "Root")
        XCTAssertEqual(todos[1].depth, 1)
        XCTAssertEqual(todos[1].text, "Child")
        XCTAssertEqual(todos[2].depth, 2)
        XCTAssertEqual(todos[2].text, "Grandchild")
    }

    /// sessionIndex and lineIndex identify position.
    func testParseTodosSessionAndLineIndex() throws {
        let s1 = Session(date: "Mon, Jan 1, 2025", label: "", body: "- [ ] A\n- [ ] B")
        let s2 = Session(date: "Tue, Jan 2, 2025", label: "", body: "- [ ] C")
        let notes = ProjectNotes(title: "T", sessions: [s1, s2])
        let todos = try parseTodos(notes: notes)
        XCTAssertEqual(todos.count, 3)
        XCTAssertEqual(todos[0].sessionIndex, 0)
        XCTAssertEqual(todos[0].lineIndex, 0)
        XCTAssertEqual(todos[1].sessionIndex, 0)
        XCTAssertEqual(todos[1].lineIndex, 1)
        XCTAssertEqual(todos[2].sessionIndex, 1)
        XCTAssertEqual(todos[2].lineIndex, 0)
    }

    /// Task line ending with " @" is focused; text is stripped of suffix.
    func testParseTodosFocusMarker() throws {
        let session = Session(date: "Wed, Feb 25, 2025", label: "", body: "- [ ] First\n- [ ] Second @\n- [ ] Third")
        let notes = ProjectNotes(title: "T", sessions: [session])
        let todos = try parseTodos(notes: notes)
        XCTAssertEqual(todos.count, 3)
        XCTAssertFalse(todos[0].isFocused)
        XCTAssertEqual(todos[0].text, "First")
        XCTAssertTrue(todos[1].isFocused)
        XCTAssertEqual(todos[1].text, "Second")
        XCTAssertTrue(todos[1].rawLine.hasSuffix(" @"))
        XCTAssertFalse(todos[2].isFocused)
        XCTAssertEqual(todos[2].text, "Third")
    }

    /// Multiple "@" in file: only first (by session/line order) gets isFocused when parsing unnormalized notes.
    func testParseTodosMultipleFocusMarkersFirstWins() throws {
        let session = Session(
            date: "Wed, Feb 25, 2025",
            label: "",
            body: "- [ ] A @\n- [ ] B @\n- [ ] C @"
        )
        let notes = ProjectNotes(title: "T", sessions: [session])
        let todos = try parseTodos(notes: notes)
        XCTAssertEqual(todos.filter { $0.isFocused }.count, 1)
        XCTAssertTrue(todos[0].isFocused)
        XCTAssertFalse(todos[1].isFocused)
        XCTAssertFalse(todos[2].isFocused)
    }

    /// normalizeFocusMarker keeps first " @" and strips the rest from session bodies.
    func testNormalizeFocusMarkerKeepsFirstStripsRest() throws {
        let session = Session(
            date: "Wed, Feb 25, 2025",
            label: "",
            body: "- [ ] A @\n- [ ] B @\n- [ ] C @"
        )
        let notes = ProjectNotes(title: "T", sessions: [session])
        let normalized = normalizeFocusMarker(notes: notes)
        let bodyLines = normalized.sessions[0].body.split(separator: "\n").map(String.init)
        XCTAssertEqual(bodyLines.count, 3)
        XCTAssertTrue(bodyLines[0].hasSuffix(" @"))
        XCTAssertFalse(bodyLines[1].hasSuffix(" @"))
        XCTAssertFalse(bodyLines[2].hasSuffix(" @"))
        XCTAssertEqual(bodyLines[1], "- [ ] B")
        XCTAssertEqual(bodyLines[2], "- [ ] C")
    }

    /// Round-trip with focus marker: parse -> normalize -> serialize -> parse preserves single @ and isFocused.
    func testRoundTripWithFocusMarker() throws {
        let session = Session(date: "Wed, Feb 25, 2025", label: "", body: "- [ ] One\n- [ ] Two @\n- [ ] Three")
        let notes = ProjectNotes(title: "T", sessions: [session])
        let normalized = normalizeFocusMarker(notes: notes)
        let serialized = serializeNotes(normalized)
        let reparsed = try parseNotes(markdown: serialized)
        let todos = try parseTodos(notes: reparsed)
        XCTAssertEqual(todos.count, 3)
        let focused = todos.first(where: { $0.isFocused })
        XCTAssertNotNil(focused)
        XCTAssertEqual(focused?.text, "Two")
        XCTAssertTrue(reparsed.sessions[0].body.contains(" @"))
        let atCount = reparsed.sessions[0].body.split(separator: "\n").filter { $0.hasSuffix(" @") }.count
        XCTAssertEqual(atCount, 1)
    }

    /// completeTodoWithDescendants completes parent and all children.
    func testCompleteTodoWithDescendants() throws {
        let session = Session(
            date: "Wed, Feb 25, 2025",
            label: "",
            body: "- [ ] Root\n  - [ ] Child\n    - [ ] Grandchild\n- [ ] Sibling"
        )
        let notes = ProjectNotes(title: "T", sessions: [session])
        let updated = try completeTodoWithDescendants(notes: notes, sessionIndex: 0, lineIndex: 0, advanceFocus: false)
        let todos = try parseTodos(notes: updated)
        XCTAssertTrue(todos[0].checked)
        XCTAssertEqual(todos[0].text, "Root")
        XCTAssertTrue(todos[1].checked)
        XCTAssertEqual(todos[1].text, "Child")
        XCTAssertTrue(todos[2].checked)
        XCTAssertEqual(todos[2].text, "Grandchild")
        XCTAssertFalse(todos[3].checked)
        XCTAssertEqual(todos[3].text, "Sibling")
    }

    /// Advance focus uses now-style: previous sibling's last leaf, else next sibling's first leaf, else parent.
    func testCompleteAdvanceFocusNowStyle() throws {
        // Three root siblings: A (leaf), B with child B1, C (leaf). Focus B, complete B → focus should go to A (prev sibling's last leaf).
        let session = Session(
            date: "Wed, Feb 25, 2025",
            label: "",
            body: "- [ ] A\n- [ ] B @\n  - [ ] B1\n- [ ] C"
        )
        let notes = ProjectNotes(title: "T", sessions: [session])
        let updated = try completeTodoWithDescendants(notes: notes, sessionIndex: 0, lineIndex: 1, advanceFocus: true)
        let todos = try parseTodos(notes: updated)
        XCTAssertTrue(todos[1].checked, "B completed")
        XCTAssertTrue(todos[2].checked, "B1 completed")
        let focused = todos.first(where: { $0.isFocused })
        XCTAssertNotNil(focused)
        XCTAssertEqual(focused?.text, "A", "focus moves to previous sibling's last leaf (A)")
    }

    /// Complete first root → focus moves to next sibling's first leaf (B has child B1, so first leaf is B1).
    func testCompleteAdvanceFocusNextSiblingFirstLeaf() throws {
        let session = Session(
            date: "Wed, Feb 25, 2025",
            label: "",
            body: "- [ ] A @\n- [ ] B\n  - [ ] B1\n- [ ] C"
        )
        let notes = ProjectNotes(title: "T", sessions: [session])
        let updated = try completeTodoWithDescendants(notes: notes, sessionIndex: 0, lineIndex: 0, advanceFocus: true)
        let todos = try parseTodos(notes: updated)
        XCTAssertTrue(todos[0].checked, "A completed")
        let focused = todos.first(where: { $0.isFocused })
        XCTAssertNotNil(focused)
        XCTAssertEqual(focused?.text, "B1", "focus moves to next sibling B's first leaf (B1)")
    }

    /// Complete only child → focus moves to parent.
    func testCompleteAdvanceFocusToParent() throws {
        let session = Session(
            date: "Wed, Feb 25, 2025",
            label: "",
            body: "- [ ] A\n  - [ ] A1 @"
        )
        let notes = ProjectNotes(title: "T", sessions: [session])
        let updated = try completeTodoWithDescendants(notes: notes, sessionIndex: 0, lineIndex: 1, advanceFocus: true)
        let todos = try parseTodos(notes: updated)
        XCTAssertTrue(todos[1].checked, "A1 completed")
        let focused = todos.first(where: { $0.isFocused })
        XCTAssertNotNil(focused)
        XCTAssertEqual(focused?.text, "A", "focus moves to parent A")
    }

    /// Previous sibling has children → focus moves to that sibling's last leaf.
    func testCompleteAdvanceFocusPrevSiblingLastLeaf() throws {
        let session = Session(
            date: "Wed, Feb 25, 2025",
            label: "",
            body: "- [ ] A\n  - [ ] A1\n  - [ ] A2\n- [ ] B @\n- [ ] C"
        )
        let notes = ProjectNotes(title: "T", sessions: [session])
        let updated = try completeTodoWithDescendants(notes: notes, sessionIndex: 0, lineIndex: 3, advanceFocus: true)
        let todos = try parseTodos(notes: updated)
        XCTAssertTrue(todos[3].checked, "B completed")
        let focused = todos.first(where: { $0.isFocused })
        XCTAssertNotNil(focused)
        XCTAssertEqual(focused?.text, "A2", "focus moves to previous sibling A's last leaf (A2)")
    }

    /// Two roots: complete second → focus moves to first (previous sibling's last leaf).
    func testCompleteAdvanceFocusTwoRootsCompleteSecond() throws {
        let session = Session(
            date: "Wed, Feb 25, 2025",
            label: "",
            body: "- [ ] A\n- [ ] B @"
        )
        let notes = ProjectNotes(title: "T", sessions: [session])
        let updated = try completeTodoWithDescendants(notes: notes, sessionIndex: 0, lineIndex: 1, advanceFocus: true)
        let todos = try parseTodos(notes: updated)
        XCTAssertTrue(todos[1].checked, "B completed")
        let focused = todos.first(where: { $0.isFocused })
        XCTAssertNotNil(focused)
        XCTAssertEqual(focused?.text, "A", "focus moves to previous sibling A")
    }

    /// Single root, complete with advance → no structural candidate; focus cleared (all done).
    func testCompleteAdvanceFocusSingleRootClearsFocus() throws {
        let session = Session(
            date: "Wed, Feb 25, 2025",
            label: "",
            body: "- [ ] Only @"
        )
        let notes = ProjectNotes(title: "T", sessions: [session])
        let updated = try completeTodoWithDescendants(notes: notes, sessionIndex: 0, lineIndex: 0, advanceFocus: true)
        let todos = try parseTodos(notes: updated)
        XCTAssertTrue(todos[0].checked, "Only completed")
        let focusedCount = todos.filter { $0.isFocused }.count
        XCTAssertEqual(focusedCount, 0, "no focus when no open tasks left")
    }

    /// Three roots A, B, C — complete A → focus to B (next sibling; B is leaf so first leaf is B).
    func testCompleteAdvanceFocusNextSiblingIsLeaf() throws {
        let session = Session(
            date: "Wed, Feb 25, 2025",
            label: "",
            body: "- [ ] A @\n- [ ] B\n- [ ] C"
        )
        let notes = ProjectNotes(title: "T", sessions: [session])
        let updated = try completeTodoWithDescendants(notes: notes, sessionIndex: 0, lineIndex: 0, advanceFocus: true)
        let todos = try parseTodos(notes: updated)
        XCTAssertTrue(todos[0].checked, "A completed")
        let focused = todos.first(where: { $0.isFocused })
        XCTAssertNotNil(focused)
        XCTAssertEqual(focused?.text, "B", "focus moves to next sibling B (leaf)")
    }
}
