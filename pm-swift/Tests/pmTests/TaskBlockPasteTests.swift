import XCTest
@testable import PmLib

/// The block splice behind a paste or a text drop into the task list.
///
/// Worth its own suite because it is the one write that inserts several lines at once: everything else
/// adds a task, moves a subtree or deletes one. A block that lands at the wrong indent or inside the
/// anchor's own children is a corrupted outline that the app will happily go on editing.
final class TaskBlockPasteTests: XCTestCase {
    /// An anchor with children, so "after the subtree" and "after the line" give different answers.
    static let markdown = """
    # My Project

    ## Sessions

    ### Wed, Feb 25, 2025

    Some prose about the day.

    - [ ] Parent
      - [ ] Existing child
    - [ ] Sibling
    """

    private func tasks(_ raw: String) -> [String] {
        raw.components(separatedBy: "\n").filter { $0.contains("[ ]") || $0.contains("[x]") }
    }

    // MARK: Insertion point

    func testBlockLandsAfterTheAnchorsWholeSubtree() throws {
        let out = try XCTUnwrap(insertTaskBlockPreservingFormat(
            rawText: Self.markdown, anchorSessionIndex: 0, anchorLineIndex: 0,
            block: [PastedTask(depth: 0, text: "Pasted")]))
        XCTAssertEqual(tasks(out), [
            "- [ ] Parent",
            "  - [ ] Existing child",
            "- [ ] Pasted",
            "- [ ] Sibling",
        ])
    }

    func testBlockKeepsItsOwnNesting() throws {
        let out = try XCTUnwrap(insertTaskBlockPreservingFormat(
            rawText: Self.markdown, anchorSessionIndex: 0, anchorLineIndex: 2,
            block: [PastedTask(depth: 0, text: "A"),
                    PastedTask(depth: 1, text: "A1"),
                    PastedTask(depth: 2, text: "A1a"),
                    PastedTask(depth: 0, text: "B")]))
        XCTAssertEqual(tasks(out).suffix(4), [
            "- [ ] A",
            "  - [ ] A1",
            "    - [ ] A1a",
            "- [ ] B",
        ])
    }

    /// Pasting onto a child roots the block at the child's depth, not at the top level.
    func testBlockRootsAtTheAnchorsDepth() throws {
        let out = try XCTUnwrap(insertTaskBlockPreservingFormat(
            rawText: Self.markdown, anchorSessionIndex: 0, anchorLineIndex: 1,
            block: [PastedTask(depth: 0, text: "A"), PastedTask(depth: 1, text: "A1")]))
        XCTAssertEqual(tasks(out), [
            "- [ ] Parent",
            "  - [ ] Existing child",
            "  - [ ] A",
            "    - [ ] A1",
            "- [ ] Sibling",
        ])
    }

    func testCheckedAndDueSurvive() throws {
        let out = try XCTUnwrap(insertTaskBlockPreservingFormat(
            rawText: Self.markdown, anchorSessionIndex: 0, anchorLineIndex: 2,
            block: [PastedTask(depth: 0, text: "Done one", due: "2026-03-01", checked: true)]))
        XCTAssertTrue(out.contains("- [x] Done one due: 2026-03-01"))
    }

    func testNothingElseInTheDocumentMoves() throws {
        let out = try XCTUnwrap(insertTaskBlockPreservingFormat(
            rawText: Self.markdown, anchorSessionIndex: 0, anchorLineIndex: 0,
            block: [PastedTask(depth: 0, text: "Pasted")]))
        XCTAssertTrue(out.contains("Some prose about the day."))
        XCTAssertTrue(out.hasPrefix("# My Project"))
    }

    func testUnknownAnchorRefuses() {
        XCTAssertNil(insertTaskBlockPreservingFormat(
            rawText: Self.markdown, anchorSessionIndex: 0, anchorLineIndex: 99,
            block: [PastedTask(depth: 0, text: "Pasted")]))
    }

    func testEmptyBlockRefuses() {
        XCTAssertNil(insertTaskBlockPreservingFormat(
            rawText: Self.markdown, anchorSessionIndex: 0, anchorLineIndex: 0, block: []))
    }

    // MARK: Appending to a session

    func testAppendLandsAfterTheLastTask() throws {
        let out = try XCTUnwrap(appendTaskBlockToSession(
            rawText: Self.markdown, sessionIndex: 0,
            block: [PastedTask(depth: 0, text: "A"), PastedTask(depth: 1, text: "A1")]))
        XCTAssertEqual(tasks(out), [
            "- [ ] Parent",
            "  - [ ] Existing child",
            "- [ ] Sibling",
            "- [ ] A",
            "  - [ ] A1",
        ])
    }

    /// A session whose only content is its note: the block goes under the prose, not above it.
    func testAppendToSessionWithNoTasksStaysBelowTheNote() throws {
        let raw = """
        # My Project

        ## Sessions

        ### Wed, Feb 25, 2025

        Just a note today.
        """
        let out = try XCTUnwrap(appendTaskBlockToSession(
            rawText: raw, sessionIndex: 0, block: [PastedTask(depth: 0, text: "First")]))
        let lines = out.components(separatedBy: "\n")
        let note = try XCTUnwrap(lines.firstIndex(of: "Just a note today."))
        let task = try XCTUnwrap(lines.firstIndex(of: "- [ ] First"))
        XCTAssertLessThan(note, task)
    }

    // MARK: The list marker

    /// A document that spaces its markers `-   ` keeps writing `-   `. The block takes the anchor's
    /// prefix rather than a hardcoded `- `, for the same reason every other edit here is
    /// format-preserving. (`-` is the only marker PM reads as a task at all — see `rawTaskPattern` —
    /// so what varies is the spacing after it, not the character.)
    func testBlockAdoptsTheDocumentsMarkerSpacing() throws {
        let raw = """
        # My Project

        ## Sessions

        ### Wed, Feb 25, 2025

        -   [ ] Parent
        """
        let out = try XCTUnwrap(insertTaskBlockPreservingFormat(
            rawText: raw, anchorSessionIndex: 0, anchorLineIndex: 0,
            block: [PastedTask(depth: 0, text: "Pasted")]))
        XCTAssertTrue(out.contains("-   [ ] Pasted"), out)
    }

    // MARK: Round trip

    /// What the app's ⌘C writes must be what its ⌘V reads. The parser lives in the app, so this
    /// asserts the half that lives here: a block rendered by the splice parses back to the same
    /// indents it was given.
    func testRenderedBlockReparsesToTheSameShape() throws {
        let block = [PastedTask(depth: 0, text: "A"),
                     PastedTask(depth: 1, text: "A1"),
                     PastedTask(depth: 0, text: "B")]
        let out = try XCTUnwrap(insertTaskBlockPreservingFormat(
            rawText: Self.markdown, anchorSessionIndex: 0, anchorLineIndex: 2, block: block))
        let indents = tasks(out).suffix(3).map { $0.prefix { $0 == " " }.count }
        XCTAssertEqual(indents, [0, 2, 0])
    }
}
