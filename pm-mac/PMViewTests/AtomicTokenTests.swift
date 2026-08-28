import XCTest
import AppKit
import PmLib

/// A `[[…]]` behaves as one thing in the note editor: the caret steps over it, backspace takes all of
/// it, and a selection that touches it covers it.
///
/// Behavioural rather than structural, and that is the design. The text on disk is still markdown
/// Obsidian reads and `NotesRawEdit` splices — nothing here substitutes an attachment for the
/// characters, because every offset in the document still has to count them.
@MainActor
final class AtomicTokenTests: XCTestCase {

    func testBackspaceAfterATokenTakesAllOfIt() {
        let editor = NoteEditor()
        editor.put("waiting: [[W-1 Website Refresh]]", caretAt: 32)
        editor.view.deleteBackward(nil)
        XCTAssertEqual(editor.text, "waiting: ", "a bracket left behind is markup the writer didn't ask for")
    }

    func testBackspaceElsewhereIsStillOrdinary() {
        let editor = NoteEditor()
        editor.put("plain text", caretAt: 10)
        editor.view.deleteBackward(nil)
        XCTAssertEqual(editor.text, "plain tex")
    }

    func testLeftArrowStepsOverAWholeToken() {
        let editor = NoteEditor()
        editor.put("a [[Website]] b", caretAt: 13)
        editor.view.moveLeft(nil)
        XCTAssertEqual(editor.caret, 2, "one press should clear the token, not land in the brackets")
    }

    func testRightArrowStepsOverAWholeToken() {
        let editor = NoteEditor()
        editor.put("a [[Website]] b", caretAt: 2)
        editor.view.moveRight(nil)
        XCTAssertEqual(editor.caret, 13)
    }

    /// Away from a token the arrows are AppKit's again — the override has to be invisible everywhere
    /// else, or the editor feels like it has a mind of its own.
    func testArrowsAwayFromATokenMoveOneCharacter() {
        let editor = NoteEditor()
        editor.put("abc", caretAt: 1)
        editor.view.moveRight(nil)
        XCTAssertEqual(editor.caret, 2)
    }

    func testAClickInsideATokenSnapsToTheNearerEdge() {
        let editor = NoteEditor()
        editor.put("a [[Website]] b", caretAt: 0)
        let snapped = editor.view.selectionRange(forProposedRange: NSRange(location: 5, length: 0),
                                                 granularity: .selectByCharacter)
        XCTAssertEqual(snapped, NSRange(location: 2, length: 0))
    }

    func testAPartialSelectionWidensToTheWholeToken() {
        let editor = NoteEditor()
        editor.put("a [[Website]] b", caretAt: 0)
        let widened = editor.view.selectionRange(forProposedRange: NSRange(location: 0, length: 6),
                                                 granularity: .selectByCharacter)
        XCTAssertEqual((editor.text as NSString).substring(with: widened), "a [[Website]]")
    }

    /// Which is what makes typing over one replace all of it — no separate rule, just the selection
    /// having covered the whole thing before the keystroke arrived.
    func testTypingOverATokenReplacesAllOfIt() {
        let editor = NoteEditor()
        editor.put("a [[Website]] b", caretAt: 0)
        editor.view.setSelectedRange(
            editor.view.selectionRange(forProposedRange: NSRange(location: 2, length: 4),
                                       granularity: .selectByCharacter))
        editor.view.insertText("X", replacementRange: editor.view.selectedRange())
        XCTAssertEqual(editor.text, "a X b")
    }
}
