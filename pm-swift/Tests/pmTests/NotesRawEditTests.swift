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

    // MARK: - Delete subtree

    private static let deleteFixture = """
    ## Sessions

    ### Wed, Feb 25, 2025

    Some leading prose about the session.

    - [ ] One
    - [ ] Group
      - [ ] Two
        - [ ] Deep
    - [x] Four

    ### Tue, Feb 24, 2025

    - [ ] Earlier
    """

    /// Deleting a leaf removes exactly its line; its siblings and the session's prose are untouched.
    func testDeleteLeafRemovesOnlyThatLine() throws {
        let updated = try XCTUnwrap(deleteSubtreePreservingFormat(
            rawText: Self.deleteFixture, sessionIndex: 0, lineIndex: 0))   // "One"
        XCTAssertFalse(updated.contains("- [ ] One"), "The deleted line is gone")
        XCTAssertTrue(updated.contains("- [ ] Group\n  - [ ] Two\n    - [ ] Deep\n- [x] Four"),
                      "Every other task line is untouched")
        XCTAssertTrue(updated.contains("Some leading prose about the session."),
                      "Session prose is preserved")
    }

    /// Deleting a parent takes its whole subtree with it — a task never leaves orphaned children.
    func testDeleteParentRemovesWholeSubtree() throws {
        let updated = try XCTUnwrap(deleteSubtreePreservingFormat(
            rawText: Self.deleteFixture, sessionIndex: 0, lineIndex: 1))   // "Group"
        for gone in ["Group", "Two", "Deep"] {
            XCTAssertFalse(updated.contains(gone), "\(gone) removed with the subtree")
        }
        XCTAssertTrue(updated.contains("- [ ] One\n- [x] Four"), "Siblings close up around the hole")
    }

    /// A delete in one session leaves the others alone (indices are per-session).
    func testDeleteLeavesOtherSessionsAlone() throws {
        let updated = try XCTUnwrap(deleteSubtreePreservingFormat(
            rawText: Self.deleteFixture, sessionIndex: 1, lineIndex: 0))   // "Earlier"
        XCTAssertFalse(updated.contains("Earlier"), "Target removed from the second session")
        XCTAssertTrue(updated.contains("- [ ] One\n- [ ] Group"), "First session untouched")
    }

    /// A line index past the session's task count can't be located — nil, so the caller skips the write.
    func testDeleteMissingTaskReturnsNil() throws {
        XCTAssertNil(deleteSubtreePreservingFormat(rawText: Self.deleteFixture, sessionIndex: 0, lineIndex: 99))
    }

    /// The messy fixture's frontmatter, callout, and spacing survive a delete — the edit only ever
    /// removes the subtree's own lines.
    func testDeletePreservesSurroundingFormat() throws {
        let todos = try parseTodos(notes: parseNotes(markdown: Self.messyMarkdown))
        guard let first = todos.first else { return XCTFail("fixture has no todos") }
        let updated = try XCTUnwrap(deleteSubtreePreservingFormat(
            rawText: Self.messyMarkdown, sessionIndex: first.sessionIndex, lineIndex: first.lineIndex))
        XCTAssertTrue(updated.hasPrefix("---\ntags: [project, design]"), "Frontmatter preserved verbatim")
        XCTAssertTrue(updated.contains("> [!summary] Summary"), "Callout preserved verbatim")
        XCTAssertEqual(try parseTodos(notes: parseNotes(markdown: updated)).count, todos.count - 1,
                       "Exactly one task line removed (the first is a leaf in this fixture)")
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

    // MARK: - Session notes (reveal / create / rename / delete / prose)

    /// Three sessions: one with a label, leading prose, and a focused task; one bare with a task; one
    /// empty (no label content beyond its own, no prose, no tasks) that trails the file.
    private static let sessionFixture = """
    ## Sessions

    ### Wed, Mar 05, 2025 Today

    Kicked things off with a quick sync.

    - [ ] Current focus @
    - [ ] Another

    ### Mon, Mar 03, 2025

    - [ ] Old open

    ### Fri, Feb 28, 2025 Planning
    """

    /// Leading prose is the run of lines before a body's first task, trimmed; a body that opens with a
    /// task has none, and a task-free body is all prose.
    func testLeadingSessionProse() {
        XCTAssertEqual(leadingSessionProse(body: "Kicked things off.\n\n- [ ] Task"), "Kicked things off.")
        XCTAssertEqual(leadingSessionProse(body: "- [ ] Task first\nprose after"), "")
        XCTAssertEqual(leadingSessionProse(body: "Only prose\nmore prose"), "Only prose\nmore prose")
        XCTAssertEqual(leadingSessionProse(body: ""), "")
    }

    /// Creating a note on a session that has tasks but no prose inserts it between the heading and the
    /// first task, one blank line either side; the tasks are untouched.
    func testSetSessionNoteCreatesAboveTasks() throws {
        let updated = try XCTUnwrap(setSessionNotePreservingFormat(
            rawText: Self.sessionFixture, sessionIndex: 1, prose: "A note."))
        XCTAssertTrue(updated.contains("### Mon, Mar 03, 2025\n\nA note.\n\n- [ ] Old open"),
                      "Note sits between the heading and the first task")
    }

    /// Replacing an existing note swaps only the prose; the focused task and its marker ride through.
    func testSetSessionNoteReplacesExisting() throws {
        let updated = try XCTUnwrap(setSessionNotePreservingFormat(
            rawText: Self.sessionFixture, sessionIndex: 0, prose: "Rewritten."))
        XCTAssertTrue(updated.contains("### Wed, Mar 05, 2025 Today\n\nRewritten.\n\n- [ ] Current focus @"))
        XCTAssertFalse(updated.contains("Kicked things off"), "Old prose replaced")
    }

    /// An empty note clears the prose, leaving one blank line between heading and first task.
    func testSetSessionNoteClears() throws {
        let updated = try XCTUnwrap(setSessionNotePreservingFormat(
            rawText: Self.sessionFixture, sessionIndex: 0, prose: "   "))
        XCTAssertTrue(updated.contains("### Wed, Mar 05, 2025 Today\n\n- [ ] Current focus @"))
        XCTAssertFalse(updated.contains("Kicked things off"))
    }

    /// A note on the trailing empty session appends heading → blank → prose, with no spurious trailing.
    func testSetSessionNoteOnEmptyTrailingSession() throws {
        let updated = try XCTUnwrap(setSessionNotePreservingFormat(
            rawText: Self.sessionFixture, sessionIndex: 2, prose: "First entry."))
        XCTAssertTrue(updated.hasSuffix("### Fri, Feb 28, 2025 Planning\n\nFirst entry."))
    }

    // MARK: - Appending a note to a dated session

    /// A day pm itself would have written a heading for, so the fixture's date string and
    /// `formatSessionDate`'s agree exactly (the shared `sessionFixture` zero-pads its days, which pm
    /// never does).
    private static let noteDay = try! parseSessionDateArgument("2025-03-05")
    private static let otherDay = try! parseSessionDateArgument("2025-03-03")

    private static func datedFixture() -> String {
        """
        ## Sessions

        ### \(formatSessionDate(noteDay))

        Kicked things off with a quick sync.

        - [ ] Current focus @

        ### \(formatSessionDate(otherDay))

        - [ ] Old open
        """
    }

    /// A second note joins the first under a blank line rather than replacing it, and stays above the
    /// session's tasks.
    func testAppendSessionNoteJoinsExistingProse() throws {
        let updated = try XCTUnwrap(appendSessionNotePreservingFormat(
            rawText: Self.datedFixture(), prose: "Then reviewed the plan.", date: Self.noteDay))
        XCTAssertTrue(updated.contains("Kicked things off with a quick sync.\n\nThen reviewed the plan.\n\n- [ ] Current focus @"),
                      "Appended under the existing note, still above the tasks")
    }

    /// With no session for that day, one is created at the top of the list and takes the note.
    func testAppendSessionNoteCreatesMissingSession() throws {
        let day = try parseSessionDateArgument("2025-04-01")
        let updated = try XCTUnwrap(appendSessionNotePreservingFormat(
            rawText: Self.datedFixture(), prose: "Fresh start.", date: day))
        XCTAssertTrue(updated.contains("## Sessions\n\n### \(formatSessionDate(day))\n\nFresh start."),
                      "New session heads the list, carrying the note")
        XCTAssertTrue(updated.contains("Kicked things off with a quick sync."), "Older sessions untouched")
    }

    /// The other session's note is not the one appended to.
    func testAppendSessionNoteTargetsItsOwnDay() throws {
        let updated = try XCTUnwrap(appendSessionNotePreservingFormat(
            rawText: Self.datedFixture(), prose: "Only here.", date: Self.otherDay))
        XCTAssertTrue(updated.contains("### \(formatSessionDate(Self.otherDay))\n\nOnly here.\n\n- [ ] Old open"))
        XCTAssertEqual(updated.components(separatedBy: "Only here.").count - 1, 1)
    }

    /// Blank prose is a no-op: the file comes back byte-for-byte.
    func testAppendSessionNoteIgnoresBlankProse() throws {
        let raw = Self.datedFixture()
        XCTAssertEqual(try appendSessionNotePreservingFormat(rawText: raw, prose: "   \n "), raw)
    }

    /// Renaming adds/changes the trailing label, preserving the date and the session body verbatim.
    func testRenameSessionAddsLabel() throws {
        let updated = try XCTUnwrap(renameSessionPreservingFormat(
            rawText: Self.sessionFixture, sessionIndex: 1, label: "Standup"))
        XCTAssertTrue(updated.contains("### Mon, Mar 03, 2025 Standup\n\n- [ ] Old open"))
    }

    /// An empty label strips the trailing text back to a bare dated heading.
    func testRenameSessionRemovesLabel() throws {
        let updated = try XCTUnwrap(renameSessionPreservingFormat(
            rawText: Self.sessionFixture, sessionIndex: 0, label: ""))
        XCTAssertTrue(updated.contains("### Wed, Mar 05, 2025\n\nKicked things off"))
        XCTAssertFalse(updated.contains("Today"), "Label removed")
    }

    /// Deleting the trailing empty session removes it (and its separating blank) and leaves the rest.
    func testDeleteTrailingEmptySession() throws {
        let updated = try XCTUnwrap(deleteSessionPreservingFormat(
            rawText: Self.sessionFixture, sessionIndex: 2))
        XCTAssertFalse(updated.contains("Feb 28"))
        XCTAssertFalse(updated.contains("Planning"))
        XCTAssertTrue(updated.hasSuffix("- [ ] Old open"), "No dangling blank line left behind")
    }

    /// Deleting a middle session leaves its neighbours intact with a single blank between them.
    func testDeleteMiddleSessionKeepsNeighbours() throws {
        let updated = try XCTUnwrap(deleteSessionPreservingFormat(
            rawText: Self.sessionFixture, sessionIndex: 1))
        XCTAssertFalse(updated.contains("Old open"))
        XCTAssertTrue(updated.contains("- [ ] Another\n\n### Fri, Feb 28, 2025 Planning"),
                      "One blank line separates the surviving neighbours")
    }

    /// Pruning sweeps out the session with nothing under it and leaves every session that has content.
    func testPruneEmptySessions() throws {
        let result = try XCTUnwrap(pruneEmptySessionsPreservingFormat(rawText: Self.sessionFixture))
        XCTAssertEqual(result.removed, 1)
        XCTAssertFalse(result.rawText.contains("Feb 28"), "The heading-only session is gone")
        XCTAssertTrue(result.rawText.contains("Kicked things off"), "Prose survives")
        XCTAssertTrue(result.rawText.hasSuffix("- [ ] Old open"), "No dangling blank line left behind")
        XCTAssertEqual(try parseNotes(markdown: result.rawText).sessions.count, 2)
    }

    /// A session holding only a note (no tasks) is content — pruning must not take it.
    func testPruneKeepsNoteOnlySession() {
        let raw = """
        ## Sessions

        ### Fri, Feb 28, 2025 Planning

        Kickoff notes.
        """
        XCTAssertNil(pruneEmptySessionsPreservingFormat(rawText: raw), "Nothing to prune → no write")
    }

    /// Adjacent empty sessions all go in one pass, including the first one in the region, and content
    /// outside the Sessions region is untouched.
    func testPruneRemovesAdjacentEmptySessionsAndKeepsTrailingSection() throws {
        let raw = """
        ## Sessions

        ### Wed, Mar 05, 2025

        ### Mon, Mar 03, 2025

        ### Fri, Feb 28, 2025

        - [ ] Keep me

        ## Learnings

        - Something
        """
        let result = try XCTUnwrap(pruneEmptySessionsPreservingFormat(rawText: raw))
        XCTAssertEqual(result.removed, 2)
        let notes = try parseNotes(markdown: result.rawText)
        XCTAssertEqual(notes.sessions.count, 1)
        XCTAssertEqual(notes.sessions.first?.date, "Fri, Feb 28, 2025")
        XCTAssertTrue(result.rawText.contains("## Learnings\n\n- Something"))
        XCTAssertTrue(result.rawText.contains("## Sessions\n\n### Fri, Feb 28, 2025"))
    }

    /// A run of blank lines is still empty, and a file with no sessions at all prunes to nothing.
    func testPruneTreatsBlankBodyAsEmptyAndNoOpsWithoutSessions() throws {
        let blankBody = "## Sessions\n\n### Fri, Feb 28, 2025\n\n\n\n"
        let result = try XCTUnwrap(pruneEmptySessionsPreservingFormat(rawText: blankBody))
        XCTAssertEqual(result.removed, 1)
        XCTAssertEqual(try parseNotes(markdown: result.rawText).sessions.count, 0)
        XCTAssertNil(pruneEmptySessionsPreservingFormat(rawText: "## Learnings\n\n- Only this"))
    }

    /// Appending a task to an empty session drops it right under the heading.
    func testAppendTaskToEmptySession() throws {
        let result = try XCTUnwrap(appendTaskToSession(
            rawText: Self.sessionFixture, sessionIndex: 2, text: "New task", due: nil))
        XCTAssertTrue(result.rawText.contains("### Fri, Feb 28, 2025 Planning\n- [ ] New task"))
    }

    /// A first task appended to a session that has a prose note lands *after* the note, so the note
    /// stays leading (visible) rather than being stranded below the task.
    func testAppendTaskLandsAfterSessionNote() throws {
        let raw = """
        ## Sessions

        ### Fri, Feb 28, 2025 Planning

        Kickoff notes.
        """
        let result = try XCTUnwrap(appendTaskToSession(rawText: raw, sessionIndex: 0, text: "First task", due: nil))
        XCTAssertTrue(result.rawText.contains("Kickoff notes.\n- [ ] First task"))
        let session = try XCTUnwrap(parseNotes(markdown: result.rawText).sessions.first)
        XCTAssertEqual(leadingSessionProse(body: session.body), "Kickoff notes.",
                       "The note remains the session's leading prose")
    }

    // MARK: - Session note sanitization (structure-safe commits)

    static let commitBase = """
    ## Sessions

    ### Wed, Mar 05, 2025 Today

    My note.

    - [ ] Real task
    """

    /// Headings shallower than H4 clamp to H4 so they nest within the session instead of colliding with
    /// the `## Section` / `### <date>` structural markers.
    func testSanitizeDemotesShallowHeadings() {
        let (prose, tasks) = sanitizeSessionNoteProse("# One\n## Two\n### Wed, Mar 05, 2025\n#### Deep\nplain")
        XCTAssertEqual(prose, "#### One\n#### Two\n#### Wed, Mar 05, 2025\n#### Deep\nplain")
        XCTAssertTrue(tasks.isEmpty)
    }

    /// Checkbox lines are pulled out of the prose (to graduate into tasks), preserving their checked
    /// state and relative nesting, shifted so the shallowest sits at the root.
    func testSanitizeExtractsCheckboxesPreservingStructure() {
        let (prose, tasks) = sanitizeSessionNoteProse("note\n  - [ ] a\n    - [x] b\nmore")
        XCTAssertEqual(prose, "note\nmore")
        XCTAssertEqual(tasks, ["- [ ] a", "  - [x] b"])
    }

    /// A checkbox typed in a note graduates into a real task in the session's list; the note keeps only
    /// the prose.
    func testCommitGraduatesCheckboxToTask() throws {
        let updated = try XCTUnwrap(commitSessionNotePreservingFormat(
            rawText: Self.commitBase, sessionIndex: 0, prose: "kept note\n- [ ] Graduated"))
        let notes = try parseNotes(markdown: updated)
        let todos = try parseTodos(notes: notes)
        XCTAssertEqual(todos.map { $0.text }, ["Real task", "Graduated"])
        XCTAssertEqual(leadingSessionProse(body: notes.sessions[0].body), "kept note")
    }

    /// A stray `## ` in a note no longer ends the Sessions region — the session's tasks survive and the
    /// heading is clamped to H4.
    func testCommitH2DoesNotTruncateSessions() throws {
        let updated = try XCTUnwrap(commitSessionNotePreservingFormat(
            rawText: Self.commitBase, sessionIndex: 0, prose: "before\n## Random\nafter"))
        let notes = try parseNotes(markdown: updated)
        XCTAssertEqual(notes.sessions.count, 1)
        XCTAssertEqual(try parseTodos(notes: notes).count, 1, "Real task not lost")
        XCTAssertTrue(updated.contains("#### Random"))
    }

    /// A `### <date>` typed in a note no longer splits the session; it clamps to a harmless H4.
    func testCommitSessionHeadingDoesNotSplit() throws {
        let updated = try XCTUnwrap(commitSessionNotePreservingFormat(
            rawText: Self.commitBase, sessionIndex: 0, prose: "### Fri, Feb 28, 2025 Foo"))
        let notes = try parseNotes(markdown: updated)
        XCTAssertEqual(notes.sessions.count, 1)
        XCTAssertTrue(updated.contains("#### Fri, Feb 28, 2025 Foo"))
    }

    /// The corruption case: committing again (the editor adopts the cleaned prose after the first save)
    /// must be a byte-identical no-op — no duplicated tasks or headings.
    func testCommitIsIdempotentAfterAdoptingCleanProse() throws {
        let raw = "note\n### Fri, Feb 28, 2025 Foo\n- [ ] x"
        let first = try XCTUnwrap(commitSessionNotePreservingFormat(
            rawText: Self.commitBase, sessionIndex: 0, prose: raw))
        let cleaned = sanitizeSessionNoteProse(raw).prose   // what the editor now holds
        let second = try XCTUnwrap(commitSessionNotePreservingFormat(
            rawText: first, sessionIndex: 0, prose: cleaned))
        XCTAssertEqual(second, first, "Re-commit is a no-op")
        XCTAssertEqual(try parseTodos(notes: parseNotes(markdown: second)).count, 2, "Real task + one graduated x")
    }

    /// Every session editor returns nil for a session index that doesn't exist (caller skips the write).
    func testSessionEditsReturnNilForBadIndex() {
        XCTAssertNil(setSessionNotePreservingFormat(rawText: Self.sessionFixture, sessionIndex: 9, prose: "x"))
        XCTAssertNil(renameSessionPreservingFormat(rawText: Self.sessionFixture, sessionIndex: 9, label: "x"))
        XCTAssertNil(deleteSessionPreservingFormat(rawText: Self.sessionFixture, sessionIndex: 9))
    }

    /// Editing two callouts at once (the default template abuts them with no blank line between) must
    /// splice each independently — a body scan that ran past the next callout header used to overwrite
    /// the following callouts, silently dropping one of the two edits.
    func testWriteSplicesTwoAdjacentCallouts() throws {
        let template = serializeNotes(ProjectNotes(title: "T"))
        var incoming = try parseNotes(markdown: template)
        incoming.problem = "The problem"
        incoming.goals = ["First goal", "", ""]
        let spliced = try XCTUnwrap(writeNotesPreservingFormat(rawText: template, incoming: incoming))
        let reparsed = try parseNotes(markdown: spliced)
        XCTAssertEqual(reparsed.problem, "The problem")
        XCTAssertEqual(reparsed.goals.first, "First goal")
        XCTAssertTrue(spliced.contains("> [!info] Goals"), "Goals callout survived")
        XCTAssertTrue(spliced.contains("> [!info] Approach"), "Following Approach callout not clobbered")
    }

    /// Setting a session note leaves all unrelated content (frontmatter, tags, trailing prose) intact.
    func testSetSessionNotePreservesUnrelatedFormatting() throws {
        let updated = try XCTUnwrap(setSessionNotePreservingFormat(
            rawText: Self.messyMarkdown, sessionIndex: 0, prose: "Session recap."))
        XCTAssertTrue(updated.contains("tags: [project, design]"))
        XCTAssertTrue(updated.contains("#project-tag"))
        XCTAssertTrue(updated.contains("### Wed, Feb 25, 2025\n\nSession recap.\n\n- [ ] Todo one"))
    }
}

