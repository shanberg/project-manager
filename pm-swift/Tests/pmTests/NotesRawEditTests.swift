import XCTest
@testable import PmLib

final class NotesRawEditTests: XCTestCase {
    /// A file with intentionally non-canonical formatting that the serializer would "fix":
    /// YAML frontmatter, a bare `>` callout line, custom blank-line spacing, and a trailing tag.
    /// None of this is captured by ProjectNotes, so the model round-trip would destroy it.
    static let messyMarkdown = """
    ---
    tags: [project, design]
    aliases: ["PM"]
    ---
    # My Project

    > [!summary] Summary
    > One line summary.
    >
    > A second paragraph the parser collapses.



    > [!question] Problem
    > The problem statement.

    > [!info] Goals
    > 1.   First goal with extra spaces
    > 2.  Second goal
    > 3.  Third goal

    > [!info] Approach
    > How we approach it.

    ## Links

    - Label: https://example.com

    ## Learnings

    - Learning one

    ## Sessions

    ### Wed, Feb 25, 2025

    - [ ] Todo one
    - [ ] Todo two
    - [x] Todo three

    #project-tag
    """

    private func completeFirstTodo(_ raw: String) throws -> String? {
        try editTodosPreservingFormat(rawText: raw) { notes in
            let normalized = normalizeFocusMarker(notes: notes)
            return try completeTodoWithDescendants(notes: normalized, sessionIndex: 0, lineIndex: 0, advanceFocus: false)
        }
    }

    /// Completing a todo must change ONLY that one task line — every other byte is preserved.
    func testCompletePreservesEverythingElse() throws {
        let updated = try completeFirstTodo(Self.messyMarkdown)
        let result = try XCTUnwrap(updated)

        let originalLines = Self.messyMarkdown.components(separatedBy: "\n")
        let resultLines = result.components(separatedBy: "\n")
        XCTAssertEqual(resultLines.count, originalLines.count, "Line count must not change")

        let diffs = zip(originalLines, resultLines).enumerated().filter { $0.element.0 != $0.element.1 }
        XCTAssertEqual(diffs.count, 1, "Exactly one line should change")
        let changed = try XCTUnwrap(diffs.first)
        XCTAssertEqual(changed.element.0, "- [ ] Todo one")
        XCTAssertEqual(changed.element.1, "- [x] Todo one")

        // Frontmatter, bare `>` line, extra blank lines, non-canonical goal spacing, and the
        // trailing tag are all untouched.
        XCTAssertTrue(result.contains("tags: [project, design]"))
        XCTAssertTrue(result.contains("\n>\n"), "Bare `>` callout line preserved")
        XCTAssertTrue(result.contains("> 1.   First goal with extra spaces"))
        XCTAssertTrue(result.contains("#project-tag"))
    }

    /// The exact behavioral failure the user reported: the model round-trip mangles formatting.
    /// This documents the contrast — the surgical path above does not.
    func testModelRoundTripWouldCorruptFormatting() throws {
        let notes = try parseNotes(markdown: Self.messyMarkdown)
        let reserialized = serializeNotes(notes)
        XCTAssertNotEqual(reserialized, Self.messyMarkdown, "Sanity: the old path does rewrite the file")
        XCTAssertFalse(reserialized.contains("tags: [project, design]"), "Old path drops YAML frontmatter")
        XCTAssertFalse(reserialized.contains("> 1.   First goal"), "Old path normalizes goal spacing")
        XCTAssertFalse(reserialized.contains("\n>\n"), "Old path collapses the bare `>` callout line")
    }

    /// Undo flips only the target checkbox back.
    func testUndoPreservesEverythingElse() throws {
        // Start from a file where "Todo three" is checked; undo it.
        let updated = try editTodosPreservingFormat(rawText: Self.messyMarkdown) { notes in
            let normalized = normalizeFocusMarker(notes: notes)
            return try undoTodoAt(notes: normalized, sessionIndex: 0, lineIndex: 2)
        }
        let result = try XCTUnwrap(updated)
        let originalLines = Self.messyMarkdown.components(separatedBy: "\n")
        let resultLines = result.components(separatedBy: "\n")
        let diffs = zip(originalLines, resultLines).enumerated().filter { $0.element.0 != $0.element.1 }
        XCTAssertEqual(diffs.count, 1, "Only the unchecked line changes (no focus marker added to a fresh file's other lines)")
        XCTAssertEqual(diffs.first?.element.0, "- [x] Todo three")
        XCTAssertEqual(diffs.first?.element.1, "- [ ] Todo three @")
    }

    /// Completing an already-completed todo is a no-op → returns nil so the caller skips the write.
    func testNoChangeReturnsNil() throws {
        let updated = try editTodosPreservingFormat(rawText: Self.messyMarkdown) { notes in
            try completeTodoWithDescendants(notes: notes, sessionIndex: 0, lineIndex: 2, advanceFocus: false)
        }
        XCTAssertNil(updated, "Completing an already-checked todo with no focus advance changes nothing")
    }

    /// Adding a session prepends a heading and leaves the rest of the file verbatim.
    func testSessionAddPreservesFormatting() throws {
        let date = try parseSessionDateArgument("2025-03-10")
        let result = try XCTUnwrap(sessionAddPreservingFormat(rawText: Self.messyMarkdown, label: "Kickoff", date: date))

        XCTAssertTrue(result.contains("## Sessions\n\n### Mon, Mar 10, 2025 Kickoff\n\n### Wed, Feb 25, 2025"),
                      "New session inserted at top of the list with correct spacing")
        // Header content untouched.
        XCTAssertTrue(result.contains("tags: [project, design]"))
        XCTAssertTrue(result.contains("#project-tag"))
        // Existing session and its todos still present.
        XCTAssertTrue(result.contains("- [x] Todo three"))
    }

    /// Session add into a file with no existing sessions (empty Sessions section).
    func testSessionAddWithNoExistingSessions() throws {
        let template = notesTemplate.replacingOccurrences(of: "{{title}}", with: "Fresh")
        let date = try parseSessionDateArgument("2025-03-10")
        let result = try XCTUnwrap(sessionAddPreservingFormat(rawText: template, label: "", date: date))
        XCTAssertTrue(result.contains("## Sessions\n\n### Mon, Mar 10, 2025"))
        XCTAssertFalse(result.contains("Mon, Mar 10, 2025 "), "No trailing label when label is empty")
    }

    /// No "## Sessions" heading → returns nil so the caller can fall back.
    func testSessionAddReturnsNilWithoutSessionsHeading() throws {
        let date = try parseSessionDateArgument("2025-03-10")
        XCTAssertNil(sessionAddPreservingFormat(rawText: "# Title\n\nNo sessions here.", label: "x", date: date))
    }

    // MARK: - notes write (section splicing)

    /// Editing one field (learnings) rewrites only that section; frontmatter, callouts, the bare
    /// `>` line, weird goal spacing, links, and the whole Sessions region stay verbatim.
    func testWriteSplicesOnlyChangedSection() throws {
        var notes = try parseNotes(markdown: Self.messyMarkdown)
        notes.learnings = ["Brand new learning", "And another"]
        let result = try XCTUnwrap(writeNotesPreservingFormat(rawText: Self.messyMarkdown, incoming: notes))

        // Changed section reflects the new content.
        XCTAssertTrue(result.contains("## Learnings\n\n- Brand new learning\n- And another\n"))
        // Everything else preserved byte-for-byte.
        XCTAssertTrue(result.contains("tags: [project, design]"), "Frontmatter preserved")
        XCTAssertTrue(result.contains("\n>\n"), "Bare `>` callout line preserved")
        XCTAssertTrue(result.contains("> 1.   First goal with extra spaces"), "Untouched goal spacing preserved")
        XCTAssertTrue(result.contains("- Label: https://example.com"), "Untouched links preserved")
        XCTAssertTrue(result.contains("### Wed, Feb 25, 2025\n\n- [ ] Todo one\n- [ ] Todo two"),
                      "Sessions region preserved verbatim")
    }

    /// Editing a callout (summary) replaces only its body lines; the `> [!summary] Summary` header
    /// line and the blank line + double-blank spacing around it are preserved.
    func testWriteSplicesCalloutBodyOnly() throws {
        var notes = try parseNotes(markdown: Self.messyMarkdown)
        notes.summary = "Replaced summary text."
        let result = try XCTUnwrap(writeNotesPreservingFormat(rawText: Self.messyMarkdown, incoming: notes))

        XCTAssertTrue(result.contains("> [!summary] Summary\n> Replaced summary text.\n"))
        XCTAssertFalse(result.contains("> One line summary."), "Old summary body replaced")
        // Untouched sections preserved.
        XCTAssertTrue(result.contains("> 1.   First goal with extra spaces"))
        XCTAssertTrue(result.contains("tags: [project, design]"))
    }

    /// No changes → returns the document unchanged (every byte identical).
    func testWriteNoChangeIsByteIdentical() throws {
        let notes = try parseNotes(markdown: Self.messyMarkdown)
        let result = try XCTUnwrap(writeNotesPreservingFormat(rawText: Self.messyMarkdown, incoming: notes))
        XCTAssertEqual(result, Self.messyMarkdown, "No field changed → identical output")
    }

    /// A session change can't be spliced by notes write → returns nil so the caller falls back.
    func testWriteFallsBackWhenSessionsChange() throws {
        var notes = try parseNotes(markdown: Self.messyMarkdown)
        notes.sessions.insert(Session(date: "Mon, Mar 10, 2025", label: "", body: ""), at: 0)
        XCTAssertNil(try writeNotesPreservingFormat(rawText: Self.messyMarkdown, incoming: notes))
    }

    // MARK: - Edit text

    /// Editing a task's text rewrites only its content, preserving checkbox/due/focus/indent and
    /// every other line.
    func testSetTextPreservesCheckboxDueFocusAndOtherLines() throws {
        let raw = """
        ## Sessions

        ### Wed, Feb 25, 2025

        - [ ] Parent
          - [x] Child due: 2025-03-01 @
        """
        let updated = try XCTUnwrap(editTodosPreservingFormat(rawText: raw) { notes in
            setTextOnTodoAt(notes: normalizeFocusMarker(notes: notes), sessionIndex: 0, lineIndex: 1, text: "Renamed child")
        })
        XCTAssertTrue(updated.contains("  - [x] Renamed child due: 2025-03-01 @"),
                      "Checkbox, indent, due, and focus preserved; text swapped")
        XCTAssertTrue(updated.contains("- [ ] Parent"), "Sibling untouched")
    }

    // MARK: - Wrap

    /// Wrapping a leaf inserts a parent at its indent and pushes the task in one level, keeping focus.
    func testWrapLeafInsertsParentAndIndents() throws {
        let raw = """
        ## Sessions

        ### Wed, Feb 25, 2025

        - [ ] One
        - [ ] Two @
        """
        let updated = try XCTUnwrap(wrapTaskPreservingFormat(rawText: raw, sessionIndex: 0, lineIndex: 1, parentText: "Group"))
        XCTAssertTrue(updated.contains("- [ ] Group\n  - [ ] Two @"), "Parent inserted; task nested and focus kept")
        XCTAssertTrue(updated.contains("- [ ] One\n- [ ] Group"), "Sibling order preserved before the new parent")
    }

    /// Wrapping a task carries its whole subtree along (all deeper contiguous lines indent too).
    func testWrapCarriesSubtree() throws {
        let raw = """
        ## Sessions

        ### Wed, Feb 25, 2025

        - [ ] Task
          - [ ] Sub A
          - [ ] Sub B
        - [ ] After
        """
        let updated = try XCTUnwrap(wrapTaskPreservingFormat(rawText: raw, sessionIndex: 0, lineIndex: 0, parentText: "Wrapper"))
        XCTAssertTrue(updated.contains("- [ ] Wrapper\n  - [ ] Task\n    - [ ] Sub A\n    - [ ] Sub B"),
                      "Task and its subtree all indented under the new parent")
        XCTAssertTrue(updated.contains("- [ ] After"), "Following sibling at the original indent is left alone")
    }

    // MARK: - Unwrap

    /// Unwrapping a parent removes it and promotes its children one level shallower, into its place.
    func testUnwrapPromotesChildrenAndRemovesParent() throws {
        let raw = """
        ## Sessions

        ### Wed, Feb 25, 2025

        - [ ] One
        - [ ] Group
          - [ ] Two
          - [ ] Three
        - [ ] Four
        """
        let updated = try XCTUnwrap(unwrapTaskPreservingFormat(rawText: raw, sessionIndex: 0, lineIndex: 1))
        XCTAssertFalse(updated.contains("Group"), "Parent line is removed")
        XCTAssertTrue(updated.contains("- [ ] One\n- [ ] Two\n- [ ] Three\n- [ ] Four"),
                      "Children promoted to the parent's indent and position; siblings untouched")
    }

    /// Unwrapping carries nested subtrees along: grandchildren dedent by one level too, keeping their
    /// relative nesting under the promoted child.
    func testUnwrapPreservesNestedSubtree() throws {
        let raw = """
        ## Sessions

        ### Wed, Feb 25, 2025

        - [ ] Group
          - [ ] Child
            - [ ] Grandchild
        - [ ] After
        """
        let updated = try XCTUnwrap(unwrapTaskPreservingFormat(rawText: raw, sessionIndex: 0, lineIndex: 0))
        XCTAssertTrue(updated.contains("- [ ] Child\n  - [ ] Grandchild\n- [ ] After"),
                      "Child promoted to root, grandchild stays nested one level under it")
    }

    /// Unwrapping a leaf (no children) is a no-op — returns nil so the caller can skip the write.
    func testUnwrapLeafReturnsNil() throws {
        let raw = """
        ## Sessions

        ### Wed, Feb 25, 2025

        - [ ] One
        - [ ] Two
        """
        XCTAssertNil(unwrapTaskPreservingFormat(rawText: raw, sessionIndex: 0, lineIndex: 0),
                     "A task with no children can't be dissolved")
    }

    // MARK: - Move subtree (slot + depth drag-reorder)

    private static let moveFixture = """
    ## Sessions

    ### Wed, Feb 25, 2025

    - [ ] One
      - [ ] One child
    - [ ] Two
    - [ ] Three
    """

    /// Reorder among root siblings: insert before "One" at depth 0 (anchor "One", insert-before).
    func testMoveSubtreeBeforeSibling() throws {
        let updated = try XCTUnwrap(moveSubtreePreservingFormat(
            rawText: Self.moveFixture, sourceSessionIndex: 0, sourceLineIndex: 3,   // "Three"
            anchorSessionIndex: 0, anchorLineIndex: 0, insertAfterAnchor: false, depth: 0))
        XCTAssertTrue(updated.contains("- [ ] Three\n- [ ] One\n  - [ ] One child\n- [ ] Two"),
                      "Three moved to the top at depth 0")
    }

    /// Insert-after a parent's own line at the parent's depth+1 nests as the first child, above the
    /// parent's existing children.
    func testMoveSubtreeAsFirstChild() throws {
        let updated = try XCTUnwrap(moveSubtreePreservingFormat(
            rawText: Self.moveFixture, sourceSessionIndex: 0, sourceLineIndex: 2,   // "Two"
            anchorSessionIndex: 0, anchorLineIndex: 0, insertAfterAnchor: true, depth: 1))
        XCTAssertTrue(updated.contains("- [ ] One\n  - [ ] Two\n  - [ ] One child"),
                      "Two nested as One's first child, above the existing child")
    }

    /// Insert after the last row of a parent's subtree at that child's depth lands as the parent's
    /// last child — the depth is chosen independently of the slot.
    func testMoveSubtreeAsLastChild() throws {
        let updated = try XCTUnwrap(moveSubtreePreservingFormat(
            rawText: Self.moveFixture, sourceSessionIndex: 0, sourceLineIndex: 3,   // "Three"
            anchorSessionIndex: 0, anchorLineIndex: 1, insertAfterAnchor: true, depth: 1))  // after "One child" @1
        XCTAssertTrue(updated.contains("- [ ] One\n  - [ ] One child\n  - [ ] Three\n- [ ] Two"),
                      "Three placed as One's last child (sibling of One child, depth 1)")
    }

    /// Depth 0 after the deepest last row appends at the top level — the end-of-list slot that a
    /// trailing subtree used to make unreachable.
    func testMoveSubtreeToEndAtTopLevel() throws {
        let raw = """
        ## Sessions

        ### Wed, Feb 25, 2025

        - [ ] Mover
        - [ ] Parent
          - [ ] Child
        """
        // Anchor the deepest last row ("Child"), insert after it, at depth 0 → end of list, top level.
        let updated = try XCTUnwrap(moveSubtreePreservingFormat(
            rawText: raw, sourceSessionIndex: 0, sourceLineIndex: 0,   // "Mover"
            anchorSessionIndex: 0, anchorLineIndex: 2, insertAfterAnchor: true, depth: 0))
        XCTAssertTrue(updated.contains("- [ ] Parent\n  - [ ] Child\n- [ ] Mover"),
                      "Mover appended at the very end at the top level")
    }

    /// A moved subtree carries its descendants and re-indents them all by the same delta.
    func testMoveSubtreeCarriesAndReindents() throws {
        let raw = """
        ## Sessions

        ### Wed, Feb 25, 2025

        - [ ] Target
        - [ ] Mover
          - [ ] Child
            - [ ] Grandchild
        """
        let updated = try XCTUnwrap(moveSubtreePreservingFormat(
            rawText: raw, sourceSessionIndex: 0, sourceLineIndex: 1,   // "Mover"
            anchorSessionIndex: 0, anchorLineIndex: 0, insertAfterAnchor: true, depth: 1))  // first child of Target
        XCTAssertTrue(updated.contains("- [ ] Target\n  - [ ] Mover\n    - [ ] Child\n      - [ ] Grandchild"),
                      "Whole subtree moved and each line indented one level deeper")
    }

    /// The moved line travels verbatim — checkbox state, due date, and focus marker all ride along.
    func testMoveSubtreePreservesLineContentAndFocus() throws {
        let raw = """
        ## Sessions

        ### Wed, Feb 25, 2025

        - [ ] Anchor
        - [x] Done @ due: 2025-03-01
        """
        let updated = try XCTUnwrap(moveSubtreePreservingFormat(
            rawText: raw, sourceSessionIndex: 0, sourceLineIndex: 1,
            anchorSessionIndex: 0, anchorLineIndex: 0, insertAfterAnchor: false, depth: 0))
        XCTAssertTrue(updated.contains("- [x] Done @ due: 2025-03-01\n- [ ] Anchor"),
                      "Checkbox, focus marker, and due travel with the moved line")
    }

    /// Dropping relative to a row inside the moved subtree is illegal and returns nil.
    func testMoveSubtreeAnchorInsideSelfReturnsNil() throws {
        let raw = """
        ## Sessions

        ### Wed, Feb 25, 2025

        - [ ] Parent
          - [ ] Child
        """
        XCTAssertNil(moveSubtreePreservingFormat(
            rawText: raw, sourceSessionIndex: 0, sourceLineIndex: 0,   // "Parent" (subtree)
            anchorSessionIndex: 0, anchorLineIndex: 1, insertAfterAnchor: true, depth: 2),  // "Child" — inside self
            "A subtree can't be dropped relative to its own descendant")
    }

    /// Moves can cross session boundaries — the destination session is the anchor's.
    func testMoveSubtreeAcrossSessions() throws {
        let raw = """
        ## Sessions

        ### Wed, Mar 05, 2025

        - [ ] Newer

        ### Wed, Feb 25, 2025

        - [ ] Older
        """
        let updated = try XCTUnwrap(moveSubtreePreservingFormat(
            rawText: raw, sourceSessionIndex: 1, sourceLineIndex: 0,   // "Older"
            anchorSessionIndex: 0, anchorLineIndex: 0, insertAfterAnchor: true, depth: 1))  // first child of Newer
        XCTAssertTrue(updated.contains("- [ ] Newer\n  - [ ] Older"), "Task nested under a task in another session")
        XCTAssertTrue(updated.contains("### Wed, Feb 25, 2025\n"), "The now-empty older session heading is preserved")
    }

    /// A task move leaves all non-task content (frontmatter, callouts, tags) byte-for-byte intact.
    func testMoveSubtreePreservesUnrelatedFormatting() throws {
        let updated = try XCTUnwrap(moveSubtreePreservingFormat(
            rawText: Self.messyMarkdown, sourceSessionIndex: 0, sourceLineIndex: 2,   // "Todo three"
            anchorSessionIndex: 0, anchorLineIndex: 0, insertAfterAnchor: false, depth: 0))
        XCTAssertTrue(updated.contains("tags: [project, design]"))
        XCTAssertTrue(updated.contains("> 1.   First goal with extra spaces"))
        XCTAssertTrue(updated.contains("#project-tag"))
        XCTAssertTrue(updated.contains("- [x] Todo three\n- [ ] Todo one\n- [ ] Todo two"))
    }
}

