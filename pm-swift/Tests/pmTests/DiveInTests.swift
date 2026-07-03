import XCTest
@testable import PmLib

/// Behaviour of `nextDiveInLeaf` — the shared "Dive In" / "Next" target logic used by the macOS
/// menubar action, the panel's "Next" hint, and (in spirit) the Raycast Dive In command.
///
/// Fixtures are built from real session markdown so the tests exercise the actual `parseTodos`
/// ordering (grouped by session, then line) and indentation-based depth (2 spaces per level). A
/// trailing " @" marks the focused task.
final class DiveInTests: XCTestCase {

    private func todos(_ body: String, date: String = "Wed, Feb 25, 2025", label: String = "") throws -> [Todo] {
        let notes = ProjectNotes(title: "T", sessions: [Session(date: date, label: label, body: body)])
        return try parseTodos(notes: notes)
    }

    // MARK: Nothing focused

    /// No project / no todos → nil.
    func testEmptyIsNil() {
        XCTAssertNil(nextDiveInLeaf(todos: []))
    }

    /// Nothing focused → the first open leaf in document order.
    func testNothingFocusedPicksFirstOpenLeaf() throws {
        let t = try todos("""
        - [ ] One
        - [ ] Two
        """)
        XCTAssertEqual(nextDiveInLeaf(todos: t)?.text, "One")
    }

    /// Nothing focused, first task checked → the first *open* leaf, skipping the checked one.
    func testNothingFocusedSkipsChecked() throws {
        let t = try todos("""
        - [x] Done
        - [ ] Two
        """)
        XCTAssertEqual(nextDiveInLeaf(todos: t)?.text, "Two")
    }

    /// Nothing focused, everything checked → nil.
    func testNothingFocusedAllCheckedIsNil() throws {
        let t = try todos("""
        - [x] Done
        - [x] Also done
        """)
        XCTAssertNil(nextDiveInLeaf(todos: t))
    }

    // MARK: Dive deeper

    /// Focused parent with children → dives to the first open leaf beneath it.
    func testDivesIntoSubtree() throws {
        let t = try todos("""
        - [ ] Parent @
          - [ ] Child A
          - [ ] Child B
        """)
        XCTAssertEqual(nextDiveInLeaf(todos: t)?.text, "Child A")
    }

    /// Dives through multiple levels to the deepest first leaf of the first-child chain.
    func testDivesThroughMultipleLevels() throws {
        let t = try todos("""
        - [ ] Parent @
          - [ ] Middle
            - [ ] Leaf
        """)
        XCTAssertEqual(nextDiveInLeaf(todos: t)?.text, "Leaf")
    }

    /// A checked first child is skipped; dive lands on the first *open* leaf in the subtree.
    func testDiveSkipsCheckedChild() throws {
        let t = try todos("""
        - [ ] Parent @
          - [x] Child A
          - [ ] Child B
        """)
        XCTAssertEqual(nextDiveInLeaf(todos: t)?.text, "Child B")
    }

    // MARK: Advance to next (the bug that broke Dive In)

    /// Regression: a focused leaf in the *middle* of a flat list must advance to the NEXT leaf, not
    /// jump backward to the first task in the document. This is what made Dive In "not work".
    func testFocusedMiddleLeafAdvancesForward() throws {
        let t = try todos("""
        - [ ] One
        - [ ] Two @
        - [ ] Three
        """)
        XCTAssertEqual(nextDiveInLeaf(todos: t)?.text, "Three")
    }

    /// Focused first leaf → advances to the second task.
    func testFocusedFirstLeafAdvances() throws {
        let t = try todos("""
        - [ ] One @
        - [ ] Two
        """)
        XCTAssertEqual(nextDiveInLeaf(todos: t)?.text, "Two")
    }

    /// Focused last open leaf → nil (nothing to advance to; Dive In is a no-op, not a wrap-around).
    func testFocusedLastLeafIsNil() throws {
        let t = try todos("""
        - [ ] One
        - [ ] Two @
        """)
        XCTAssertNil(nextDiveInLeaf(todos: t))
    }

    /// After exhausting a focused subtree (all children checked), advance to the next open leaf
    /// *after* the subtree — never back into the subtree or before the focused parent.
    func testExhaustedSubtreeAdvancesPastIt() throws {
        let t = try todos("""
        - [ ] Alpha
        - [ ] Parent @
          - [x] Child A
          - [x] Child B
        - [ ] Omega
        """)
        XCTAssertEqual(nextDiveInLeaf(todos: t)?.text, "Omega")
    }

    /// The next open leaf after the focused subtree can be a deeper leaf of a following sibling; the
    /// advance still moves forward in document order.
    func testAdvanceLandsOnNextSubtreeLeaf() throws {
        let t = try todos("""
        - [ ] First @
        - [ ] Next
          - [ ] Deep leaf
        """)
        // "First" is a leaf; advance to the next open leaf, which is "Deep leaf" (Next is a parent).
        XCTAssertEqual(nextDiveInLeaf(todos: t)?.text, "Deep leaf")
    }

    // MARK: Multiple sessions

    /// A session boundary ends the subtree; advancing crosses into the next session's open leaf.
    func testAdvanceCrossesSessionBoundary() throws {
        let notes = ProjectNotes(title: "T", sessions: [
            Session(date: "Mon, Feb 23, 2025", label: "", body: "- [ ] Old @"),
            Session(date: "Wed, Feb 25, 2025", label: "", body: "- [ ] New"),
        ])
        let t = try parseTodos(notes: notes)
        XCTAssertEqual(nextDiveInLeaf(todos: t)?.text, "New")
    }
}
