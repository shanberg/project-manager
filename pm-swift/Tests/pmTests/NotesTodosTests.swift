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

    /// Inline due at end of task line is parsed; text excludes the due.
    func testParseTodosDueInline() throws {
        let session = Session(
            date: "Wed, Feb 25, 2025",
            label: "",
            body: "- [ ] Ship design due: 2026-03-11 00:00\n- [ ] Other"
        )
        let notes = ProjectNotes(title: "T", sessions: [session])
        let todos = try parseTodos(notes: notes)
        XCTAssertEqual(todos[0].text, "Ship design")
        XCTAssertEqual(todos[0].dueDate, "2026-03-11 00:00")
        XCTAssertNil(todos[1].dueDate)
    }

    /// Inline due supports optional time component.
    func testParseTodosDueInlineWithTime() throws {
        let session = Session(
            date: "Wed, Feb 25, 2025",
            label: "",
            body: "- [ ] Call client due: 2025-03-15 14:30\n- [ ] Other"
        )
        let notes = ProjectNotes(title: "T", sessions: [session])
        let todos = try parseTodos(notes: notes)
        XCTAssertEqual(todos[0].dueDate, "2025-03-15 14:30")
        XCTAssertNil(todos[1].dueDate)
    }

    /// Inline due supports no-space after colon and extra spacing before due.
    func testParseTodosDueInlineSpacing() throws {
        let session = Session(
            date: "Wed, Feb 25, 2025",
            label: "",
            body: "- [ ] A    due:2025-03-09\n- [ ] B"
        )
        let notes = ProjectNotes(title: "T", sessions: [session])
        let todos = try parseTodos(notes: notes)
        XCTAssertEqual(todos[0].dueDate, "2025-03-09")
        XCTAssertNil(todos[1].dueDate)
    }

    /// Inline due is parsed even when focus marker (@) follows.
    func testParseTodosDueInlineWithFocusMarker() throws {
        let session = Session(
            date: "Wed, Feb 25, 2025",
            label: "",
            body: "- [ ] Ship design due: 2026-03-11 00:00 @\n- [ ] Other"
        )
        let notes = ProjectNotes(title: "T", sessions: [session])
        let todos = try parseTodos(notes: notes)
        XCTAssertEqual(todos[0].text, "Ship design")
        XCTAssertEqual(todos[0].dueDate, "2026-03-11 00:00")
        XCTAssertTrue(todos[0].isFocused)
        XCTAssertNil(todos[1].dueDate)
    }

    /// effectiveDueDate: task with own due keeps it; child without due gets earliest ancestor due (nearest deadline).
    func testTodosWithEffectiveDueDates() throws {
        let session = Session(
            date: "Wed, Feb 25, 2025",
            label: "",
            body: """
                - [ ] Root due: 2026-06-15
                - [ ] Child no due
                - [ ] Parent due: 2025-12-01
                  - [ ] Grandchild no due
                """
        )
        let notes = ProjectNotes(title: "T", sessions: [session])
        let todos = try parseTodos(notes: notes)
        let withEffective = todosWithEffectiveDueDates(todos)
        XCTAssertEqual(withEffective[0].dueDate, "2026-06-15")
        XCTAssertEqual(withEffective[0].effectiveDueDate, "2026-06-15")
        XCTAssertNil(withEffective[1].dueDate)
        XCTAssertNil(withEffective[1].effectiveDueDate)
        XCTAssertEqual(withEffective[2].dueDate, "2025-12-01")
        XCTAssertEqual(withEffective[2].effectiveDueDate, "2025-12-01")
        XCTAssertNil(withEffective[3].dueDate)
        XCTAssertEqual(withEffective[3].effectiveDueDate, "2025-12-01")
    }

    /// effectiveDueDate when task has own due but ancestor has earlier due: uses earliest (parent wins).
    func testTodosWithEffectiveDueDatesEarliestAmongOwnAndAncestors() throws {
        let session = Session(
            date: "Wed, Feb 25, 2025",
            label: "",
            body: """
                - [ ] Parent due: 2025-06-01
                  - [ ] Child due: 2026-12-31
                """
        )
        let notes = ProjectNotes(title: "T", sessions: [session])
        let todos = try parseTodos(notes: notes)
        let withEffective = todosWithEffectiveDueDates(todos)
        XCTAssertEqual(withEffective[1].dueDate, "2026-12-31")
        XCTAssertEqual(withEffective[1].effectiveDueDate, "2025-06-01")
    }

    /// effectiveDueDate with multiple ancestors: uses nearest (earliest) due.
    func testTodosWithEffectiveDueDatesEarliestAncestorWins() throws {
        let session = Session(
            date: "Wed, Feb 25, 2025",
            label: "",
            body: """
                - [ ] Grandparent due: 2026-12-31
                  - [ ] Parent due: 2025-06-01
                    - [ ] Child no due
                """
        )
        let notes = ProjectNotes(title: "T", sessions: [session])
        let todos = try parseTodos(notes: notes)
        let withEffective = todosWithEffectiveDueDates(todos)
        XCTAssertEqual(withEffective[2].effectiveDueDate, "2025-06-01")
    }

    /// completeTodoWithDescendants preserves inline due when completing task.
    func testCompleteTodoPreservesDueInline() throws {
        let session = Session(
            date: "Wed, Feb 25, 2025",
            label: "",
            body: "- [ ] Do X due: 2027-01-01\n- [ ] Other"
        )
        let notes = ProjectNotes(title: "T", sessions: [session])
        let updated = try completeTodoWithDescendants(notes: notes, sessionIndex: 0, lineIndex: 0, advanceFocus: false)
        XCTAssertTrue(updated.sessions[0].body.contains("due: 2027-01-01"))
        let todos = try parseTodos(notes: updated)
        XCTAssertEqual(todos[0].dueDate, "2027-01-01")
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
        let serialized = serializeNotes(normalized, kind: .project)
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

    /// Advance focus uses now-style: parent's first leaf, else next sibling's first leaf, else parent.
    func testCompleteAdvanceFocusNowStyle() throws {
        // Three root siblings: A (leaf), B with child B1, C (leaf). Focus B, complete B → no parent (root) → focus goes to next sibling's first leaf (C).
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
        XCTAssertEqual(focused?.text, "C", "focus moves to next sibling's first leaf (C)")
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

    /// Parent P with children A (with A1), B — complete B → focus moves to parent's first leaf (A1).
    func testCompleteAdvanceFocusParentFirstLeaf() throws {
        let session = Session(
            date: "Wed, Feb 25, 2025",
            label: "",
            body: "- [ ] P\n  - [ ] A\n    - [ ] A1\n  - [ ] B @"
        )
        let notes = ProjectNotes(title: "T", sessions: [session])
        let updated = try completeTodoWithDescendants(notes: notes, sessionIndex: 0, lineIndex: 3, advanceFocus: true)
        let todos = try parseTodos(notes: updated)
        XCTAssertTrue(todos[3].checked, "B completed")
        let focused = todos.first(where: { $0.isFocused })
        XCTAssertNotNil(focused)
        XCTAssertEqual(focused?.text, "A1", "focus moves to parent P's first leaf (A1)")
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

    /// Roots A (with A1, A2), B, C — complete B (root) → no parent → focus moves to next sibling's first leaf (C).
    func testCompleteAdvanceFocusNextSiblingWhenRoot() throws {
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
        XCTAssertEqual(focused?.text, "C", "focus moves to next sibling's first leaf (C)")
    }

    /// Two roots: complete second → no parent, no next sibling → focus moves to first open leaf (A) via fallback.
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
        XCTAssertEqual(focused?.text, "A", "focus moves to first open leaf (A) via fallback")
    }

    /// Fallback uses first open leaf: A (with child A1), B; complete B → no structural candidate → focus moves to A1, not A.
    func testCompleteAdvanceFocusFallbackFirstOpenLeaf() throws {
        let session = Session(
            date: "Wed, Feb 25, 2025",
            label: "",
            body: "- [ ] A\n  - [ ] A1\n- [ ] B @"
        )
        let notes = ProjectNotes(title: "T", sessions: [session])
        let updated = try completeTodoWithDescendants(notes: notes, sessionIndex: 0, lineIndex: 2, advanceFocus: true)
        let todos = try parseTodos(notes: updated)
        XCTAssertTrue(todos[2].checked, "B completed")
        let focused = todos.first(where: { $0.isFocused })
        XCTAssertNotNil(focused)
        XCTAssertEqual(focused?.text, "A1", "focus moves to first open leaf (A1), not parent A")
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

    /// applyFocusToTodoAt: focus on second task → only second has @.
    func testApplyFocusToTodoAt() throws {
        let session = Session(
            date: "Wed, Feb 25, 2025",
            label: "",
            body: "- [ ] A @\n- [ ] B\n- [ ] C"
        )
        let notes = ProjectNotes(title: "T", sessions: [session])
        let updated = applyFocusToTodoAt(notes: notes, sessionIndex: 0, lineIndex: 1)
        let todos = try parseTodos(notes: updated)
        XCTAssertEqual(todos.count, 3)
        XCTAssertFalse(todos[0].isFocused, "A no longer focused")
        XCTAssertTrue(todos[1].isFocused, "B is focused")
        XCTAssertFalse(todos[2].isFocused, "C not focused")
    }

    /// undoTodoAt: completed task at (0,1) → unchecked and has @.
    func testUndoTodoAt() throws {
        let session = Session(
            date: "Wed, Feb 25, 2025",
            label: "",
            body: "- [ ] A @\n- [x] B\n- [ ] C"
        )
        let notes = ProjectNotes(title: "T", sessions: [session])
        let updated = try undoTodoAt(notes: notes, sessionIndex: 0, lineIndex: 1)
        let todos = try parseTodos(notes: updated)
        XCTAssertEqual(todos.count, 3)
        XCTAssertFalse(todos[0].isFocused, "A no longer focused")
        XCTAssertTrue(todos[1].isFocused, "B is focused after undo")
        XCTAssertFalse(todos[1].checked, "B unchecked")
        XCTAssertFalse(todos[2].isFocused, "C not focused")
    }

    // MARK: - waiting: [[target]]

    /// A bracketed wait target parses off the line and out of the text.
    func testParseTodosWaitingInline() throws {
        let session = Session(
            date: "Wed, Feb 25, 2025",
            label: "",
            body: "- [ ] Send the launch email waiting: [[Website Refresh]]\n- [ ] Other"
        )
        let notes = ProjectNotes(title: "T", sessions: [session])
        let todos = try parseTodos(notes: notes)
        XCTAssertEqual(todos[0].text, "Send the launch email")
        XCTAssertEqual(todos[0].waiting, "Website Refresh")
        XCTAssertNil(todos[1].waiting)
    }

    /// All three trailing tokens on one line, in canonical order.
    func testParseTodosWaitingWithDueAndFocus() throws {
        let session = Session(
            date: "Wed, Feb 25, 2025",
            label: "",
            body: "- [ ] Send it waiting: [[W-1 Website Refresh]] due: 2026-03-11 @"
        )
        let notes = ProjectNotes(title: "T", sessions: [session])
        let todos = try parseTodos(notes: notes)
        XCTAssertEqual(todos[0].text, "Send it")
        XCTAssertEqual(todos[0].waiting, "W-1 Website Refresh")
        XCTAssertEqual(todos[0].dueDate, "2026-03-11")
        XCTAssertTrue(todos[0].isFocused)
    }

    /// A line written with the tokens the other way round parses identically — the peel loop doesn't
    /// care about order, and `render` repairs it to canonical on the next edit.
    func testTaskContentSplitAcceptsAnyTokenOrder() {
        let canonical = TaskContent.split("Send it waiting: [[Site]] due: 2026-03-11 @")
        let scrambled = TaskContent.split("Send it @ due: 2026-03-11 waiting: [[Site]]")
        XCTAssertEqual(scrambled.text, "Send it")
        XCTAssertEqual(scrambled.waiting, "Site")
        XCTAssertEqual(scrambled.due, "2026-03-11")
        XCTAssertTrue(scrambled.focused)
        XCTAssertEqual(canonical, scrambled)
        XCTAssertEqual(scrambled.render(), "Send it waiting: [[Site]] due: 2026-03-11 @")
    }

    /// The word "waiting:" in a sentence is prose, not a token — this is what the brackets buy.
    func testParseTodosUnbracketedWaitingIsNotAToken() throws {
        let session = Session(
            date: "Wed, Feb 25, 2025",
            label: "",
            body: "- [ ] Stop waiting: it already shipped"
        )
        let notes = ProjectNotes(title: "T", sessions: [session])
        let todos = try parseTodos(notes: notes)
        XCTAssertNil(todos[0].waiting)
        XCTAssertEqual(todos[0].text, "Stop waiting: it already shipped")
    }

    /// A wait survives an edit that rewrites the line for another reason.
    func testCompleteTodoPreservesWaitingInline() throws {
        let session = Session(
            date: "Wed, Feb 25, 2025",
            label: "",
            body: "- [ ] Do X waiting: [[Vendor Contract]] due: 2027-01-01\n- [ ] Other"
        )
        let notes = ProjectNotes(title: "T", sessions: [session])
        let updated = try completeTodoWithDescendants(notes: notes, sessionIndex: 0, lineIndex: 0,
                                                      advanceFocus: false)
        XCTAssertTrue(updated.sessions[0].body.contains("waiting: [[Vendor Contract]]"))
        XCTAssertTrue(updated.sessions[0].body.contains("due: 2027-01-01"))
    }

    /// effectiveWaiting: an own wait stands; a child with none inherits its parent's.
    func testTodosWithEffectiveWaiting() throws {
        let session = Session(
            date: "Wed, Feb 25, 2025",
            label: "",
            body: """
                - [ ] Root waiting: [[Legal]]
                  - [ ] Child no wait
                - [ ] Unrelated
                """
        )
        let notes = ProjectNotes(title: "T", sessions: [session])
        let withWait = todosWithEffectiveWaiting(try parseTodos(notes: notes))
        XCTAssertEqual(withWait[0].effectiveWaiting, "Legal")
        XCTAssertNil(withWait[1].waiting)
        XCTAssertEqual(withWait[1].effectiveWaiting, "Legal")
        XCTAssertNil(withWait[2].effectiveWaiting)
    }

    /// A task's own wait beats an ancestor's — it's more specific, not competing.
    func testTodosWithEffectiveWaitingOwnBeatsAncestor() throws {
        let session = Session(
            date: "Wed, Feb 25, 2025",
            label: "",
            body: """
                - [ ] Parent waiting: [[Legal]]
                  - [ ] Child waiting: [[Finance]]
                """
        )
        let notes = ProjectNotes(title: "T", sessions: [session])
        let withWait = todosWithEffectiveWaiting(try parseTodos(notes: notes))
        XCTAssertEqual(withWait[1].effectiveWaiting, "Finance")
    }

    /// Nearest ancestor wins, not the outermost — the closest link in the chain is what blocks.
    func testTodosWithEffectiveWaitingNearestAncestorWins() throws {
        let session = Session(
            date: "Wed, Feb 25, 2025",
            label: "",
            body: """
                - [ ] Grandparent waiting: [[Legal]]
                  - [ ] Parent waiting: [[Finance]]
                    - [ ] Child no wait
                """
        )
        let notes = ProjectNotes(title: "T", sessions: [session])
        let withWait = todosWithEffectiveWaiting(try parseTodos(notes: notes))
        XCTAssertEqual(withWait[2].effectiveWaiting, "Finance")
    }

    // MARK: - waiting and focus

    /// Focus advance skips a waiting task and takes the next available one instead.
    func testCompleteAdvanceFocusSkipsWaitingTask() throws {
        let session = Session(
            date: "Wed, Feb 25, 2025",
            label: "",
            body: """
                - [ ] A @
                - [ ] B waiting: [[Legal]]
                - [ ] C
                """
        )
        let notes = ProjectNotes(title: "T", sessions: [session])
        let updated = try completeTodoWithDescendants(notes: notes, sessionIndex: 0, lineIndex: 0,
                                                      advanceFocus: true)
        let todos = try parseTodos(notes: updated)
        XCTAssertFalse(todos[1].isFocused, "B is waiting, so focus passes over it")
        XCTAssertTrue(todos[2].isFocused, "C is the next task that can actually be started")
    }

    /// A child of a waiting parent is waiting too, so focus skips the whole subtree.
    func testCompleteAdvanceFocusSkipsSubtreeUnderWaitingParent() throws {
        let session = Session(
            date: "Wed, Feb 25, 2025",
            label: "",
            body: """
                - [ ] A @
                - [ ] B waiting: [[Legal]]
                  - [ ] B1
                - [ ] C
                """
        )
        let notes = ProjectNotes(title: "T", sessions: [session])
        let updated = try completeTodoWithDescendants(notes: notes, sessionIndex: 0, lineIndex: 0,
                                                      advanceFocus: true)
        let todos = try parseTodos(notes: updated)
        XCTAssertFalse(todos[2].isFocused, "B1 inherits B's wait")
        XCTAssertTrue(todos[3].isFocused)
    }

    /// When everything left is waiting there is no next task, and focus clears rather than landing on
    /// work that can't start.
    func testCompleteAdvanceFocusClearsWhenAllRemainingAreWaiting() throws {
        let session = Session(
            date: "Wed, Feb 25, 2025",
            label: "",
            body: """
                - [ ] A @
                - [ ] B waiting: [[Legal]]
                """
        )
        let notes = ProjectNotes(title: "T", sessions: [session])
        let updated = try completeTodoWithDescendants(notes: notes, sessionIndex: 0, lineIndex: 0,
                                                      advanceFocus: true)
        let todos = try parseTodos(notes: updated)
        XCTAssertFalse(todos.contains(where: { $0.isFocused }))
        XCTAssertEqual(todos[1].waiting, "Legal", "and the wait itself survives untouched")
    }

    /// Dive In won't dive into blocked work either — same rule, same predicate.
    func testNextDiveInLeafSkipsWaiting() throws {
        let session = Session(
            date: "Wed, Feb 25, 2025",
            label: "",
            body: """
                - [ ] Parent @
                  - [ ] Blocked waiting: [[Vendor]]
                  - [ ] Doable
                """
        )
        let notes = ProjectNotes(title: "T", sessions: [session])
        let next = nextDiveInLeaf(todos: try parseTodos(notes: notes))
        XCTAssertEqual(next?.text, "Doable")
    }

    // MARK: - the three questions

    /// Each question gets a different answer for the same list.
    func testOpenAvailableAndWaitingPartitionTheList() throws {
        let session = Session(
            date: "Wed, Feb 25, 2025",
            label: "",
            body: """
                - [x] Done
                - [ ] Doable
                - [ ] Blocked waiting: [[Legal]]
                  - [ ] Under the blocked one
                """
        )
        let notes = ProjectNotes(title: "T", sessions: [session])
        let todos = todosWithEffectiveWaiting(try parseTodos(notes: notes))
        XCTAssertEqual(todos.openTasks.map(\.text), ["Doable", "Blocked", "Under the blocked one"])
        XCTAssertEqual(todos.availableTasks.map(\.text), ["Doable"])
        XCTAssertEqual(todos.waitingTasks.map(\.text), ["Blocked", "Under the blocked one"])
    }

    /// With nothing focused, the hero is the first task that could be picked up — not the first open
    /// one. This is the defect that made four surfaces offer work focus itself declined to.
    func testHeroTaskSkipsWaitingWhenNothingIsFocused() throws {
        let session = Session(
            date: "Wed, Feb 25, 2025",
            label: "",
            body: """
                - [ ] Blocked waiting: [[Legal]]
                - [ ] Doable
                """
        )
        let notes = ProjectNotes(title: "T", sessions: [session])
        let todos = todosWithEffectiveWaiting(try parseTodos(notes: notes))
        XCTAssertEqual(todos.heroTask?.text, "Doable")
    }

    /// A focused task that is waiting still wins: getting there took a deliberate act, and the hero
    /// reports what the document says rather than overruling it.
    func testHeroTaskKeepsAFocusedWaitingTask() throws {
        let session = Session(
            date: "Wed, Feb 25, 2025",
            label: "",
            body: """
                - [ ] Blocked waiting: [[Legal]] @
                - [ ] Doable
                """
        )
        let notes = ProjectNotes(title: "T", sessions: [session])
        let todos = todosWithEffectiveWaiting(try parseTodos(notes: notes))
        XCTAssertEqual(todos.heroTask?.text, "Blocked")
    }

    /// Everything blocked means there is no hero, which is the honest answer.
    func testHeroTaskIsNilWhenEverythingIsWaiting() throws {
        let session = Session(
            date: "Wed, Feb 25, 2025", label: "",
            body: "- [ ] Blocked waiting: [[Legal]]"
        )
        let notes = ProjectNotes(title: "T", sessions: [session])
        let todos = todosWithEffectiveWaiting(try parseTodos(notes: notes))
        XCTAssertNil(todos.heroTask)
    }
}
