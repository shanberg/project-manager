import AppKit
import XCTest

/// Past its measure, the column stays that wide and sits in the middle. See
/// `MarkdownTextEditor.maxColumnWidth`.
@MainActor
final class NoteEditorMeasureTests: XCTestCase {
    func testAWideEditorCentresAColumnOfTheMeasure() {
        let editor = NoteEditor(width: 1000)
        editor.view.baseInset = NSSize(width: 9, height: 8)
        editor.view.maxColumnWidth = 400
        XCTAssertEqual(editor.view.textContainerInset, NSSize(width: 300, height: 8))
        XCTAssertEqual(editor.container.size.width, 400)
    }

    func testANarrowEditorKeepsItsOwnInset() {
        let editor = NoteEditor(width: 300)
        editor.view.baseInset = NSSize(width: 9, height: 8)
        editor.view.maxColumnWidth = 400
        XCTAssertEqual(editor.view.textContainerInset, NSSize(width: 9, height: 8))
        XCTAssertEqual(editor.container.size.width, 282)
    }

    /// The column follows a resize: the extra width goes to the margins, not the lines.
    func testResizingMovesTheMarginsNotTheColumn() {
        let editor = NoteEditor(width: 600)
        editor.view.baseInset = NSSize(width: 9, height: 8)
        editor.view.maxColumnWidth = 400
        editor.view.setFrameSize(NSSize(width: 900, height: 300))
        XCTAssertEqual(editor.view.textContainerInset.width, 250)
        XCTAssertEqual(editor.container.size.width, 400)
    }

    /// No measure is the old behaviour: the text runs to the host's edges.
    func testNoMeasureRunsEdgeToEdge() {
        let editor = NoteEditor(width: 1000)
        editor.view.baseInset = NSSize(width: 9, height: 8)
        XCTAssertEqual(editor.view.textContainerInset.width, 9)
        XCTAssertEqual(editor.container.size.width, 982)
    }
}
