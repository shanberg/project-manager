import XCTest
import AppKit

/// The things any text editor has to get right, asked of the note editor: what typing puts in the
/// buffer, what one press of ⌫ takes out of it, what one ⌘Z takes back, and where the markdown keys
/// leave the text.
///
/// Driven through the view — real `NSEvent`s, the view's own `insertText`, the window's undo manager —
/// because the transforms themselves are pure functions with their own tests in PmLib
/// (`MarkdownEditingTests`), and what is unproven without a view is the wiring: which key reaches
/// which transform, and what the edit leaves behind on the undo stack.
@MainActor
final class NoteEditorEditingTests: XCTestCase {

    /// End the runloop turn. `UndoManager` groups by turn, so anywhere these tests mean "two separate
    /// keystrokes" rather than "one burst" they have to let the turn between them end — otherwise a
    /// test of the view's own typing coalescing would be proving the run loop instead.
    private func settle() {
        let turn = expectation(description: "the runloop turn ends")
        DispatchQueue.main.async { turn.fulfill() }
        wait(for: [turn], timeout: 1)
    }

    /// Type character by character, a turn apart, the way a keyboard does it.
    private func type(_ text: String, into editor: NoteEditor) {
        for character in text {
            editor.view.insertText(String(character), replacementRange: editor.view.selectedRange())
            settle()
        }
    }

    /// A key equivalent — ⌘B and friends, which arrive before the responder chain.
    @discardableResult
    private func command(_ character: String, _ editor: NoteEditor,
                         shift: Bool = false) -> Bool {
        var flags: NSEvent.ModifierFlags = .command
        if shift { flags.insert(.shift) }
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: editor.window.windowNumber, context: nil,
            characters: character, charactersIgnoringModifiers: character,
            isARepeat: false, keyCode: 0) else { return false }
        return editor.view.performKeyEquivalent(with: event)
    }

    /// An ⌥ arrow, which the view claims in `keyDown` before AppKit's own paragraph navigation.
    private func optionArrow(up: Bool, _ editor: NoteEditor) {
        let characters = up ? "\u{F700}" : "\u{F701}"
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .option, timestamp: 0,
            windowNumber: editor.window.windowNumber, context: nil,
            characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: up ? 126 : 125) else { return }
        editor.view.keyDown(with: event)
    }

    // MARK: What typing puts in the buffer

    /// A note is markdown *source*: what reaches the file is what was typed, with no substitutions
    /// made on the way. Quotes stay straight and `--` stays two hyphens, or the markup stops being
    /// the markup.
    func testTypingIsVerbatim() {
        let editor = NoteEditor()
        editor.reset()
        editor.type("\"quoted\" -- 'and' ...")
        XCTAssertEqual(editor.text, "\"quoted\" -- 'and' ...")
    }

    func testTypingOverASelectionReplacesIt() {
        let editor = NoteEditor()
        editor.put("one two", caretAt: 0)
        editor.view.setSelectedRange(NSRange(location: 0, length: 3))
        editor.type("ONE")
        XCTAssertEqual(editor.text, "ONE two")
    }

    /// The one deliberate exception, and the reason the rule above is worth pinning: a *marker* typed
    /// over a selection wraps it rather than replacing it. See `ShortcutTextView.insertText`.
    func testAMarkerTypedOverASelectionWrapsIt() {
        let editor = NoteEditor()
        editor.put("one two", caretAt: 0)
        editor.view.setSelectedRange(NSRange(location: 0, length: 3))
        editor.type("*")
        XCTAssertEqual(editor.text, "*one* two")
    }

    // MARK: What one ⌫ takes out

    /// One press, one thing. An emoji is several UTF-16 units and one character to anybody typing.
    func testBackspaceTakesAWholeEmoji() {
        let editor = NoteEditor()
        editor.reset("a👍")
        editor.view.deleteBackward(nil)
        XCTAssertEqual(editor.text, "a")
    }

    /// A flag is a pair of regional indicators, and a family is several people joined by zero-width
    /// joiners — the cases where "one character" and "one code point" part company most violently.
    func testBackspaceTakesAWholeJoinedCluster() {
        let editor = NoteEditor()
        editor.reset("x👩‍👩‍👧")
        editor.view.deleteBackward(nil)
        XCTAssertEqual(editor.text, "x")
    }

    func testBackspaceTakesACombiningAccentWithItsLetter() {
        let editor = NoteEditor()
        editor.reset("cafe\u{301}")
        editor.view.deleteBackward(nil)
        XCTAssertEqual(editor.text, "caf")
    }

    // MARK: What one ⌘Z takes back

    /// A burst of typing is one thing you did, not one per character — the coalescing every Mac text
    /// view does, and the reason a card's editor gets its own undo manager to do it on.
    func testUndoTakesBackAWholeTypingBurst() {
        let editor = NoteEditor()
        editor.reset()
        type("hello", into: editor)

        editor.window.undoManager?.undo()
        XCTAssertEqual(editor.text, "")
    }

    func testRedoPutsTheTypingBack() {
        let editor = NoteEditor()
        editor.reset()
        type("hello", into: editor)

        editor.window.undoManager?.undo()
        editor.window.undoManager?.redo()
        XCTAssertEqual(editor.text, "hello")
    }

    /// A command is its own step, and must not swallow the typing before it. Without the
    /// `breakUndoCoalescing` in `applyIfPossible`, one ⌘Z took back the sentence *and* the bolding.
    func testAFormattingCommandIsItsOwnUndoStep() {
        let editor = NoteEditor()
        editor.reset()
        type("hello", into: editor)
        editor.view.setSelectedRange(NSRange(location: 0, length: 5))
        XCTAssertTrue(command("b", editor))
        XCTAssertEqual(editor.text, "**hello**")

        editor.window.undoManager?.undo()
        XCTAssertEqual(editor.text, "hello", "the bolding goes back on its own")

        editor.window.undoManager?.undo()
        XCTAssertEqual(editor.text, "")
    }

    /// Undo leaves the caret somewhere the next keystroke can go — inside the text it just restored.
    func testUndoLeavesTheCaretInTheText() {
        let editor = NoteEditor()
        editor.reset()
        type("hello", into: editor)
        editor.view.setSelectedRange(NSRange(location: 0, length: 5))
        command("b", editor)
        editor.window.undoManager?.undo()

        let selection = editor.view.selectedRange()
        XCTAssertLessThanOrEqual(selection.location + selection.length,
                                 (editor.text as NSString).length)
    }

    // MARK: Where the markdown keys leave the text

    func testReturnCarriesTheListOn() {
        let editor = NoteEditor()
        editor.reset("- one")
        editor.key(.returnKey)
        XCTAssertEqual(editor.text, "- one\n- ")
    }

    func testReturnOnAnEmptyItemEndsTheList() {
        let editor = NoteEditor()
        editor.reset("- one\n- ")
        editor.key(.returnKey)
        XCTAssertEqual(editor.text, "- one\n")
    }

    func testTabIndentsInsideAList() {
        let editor = NoteEditor()
        editor.reset("- one\n- two")
        editor.key(.tab)
        XCTAssertEqual(editor.text, "- one\n  - two")
    }

    /// Tab in prose means the next field, which in a note means "not a tab character in the markup".
    func testTabInProseTypesNothing() {
        let editor = NoteEditor()
        editor.reset("prose")
        editor.key(.tab)
        XCTAssertEqual(editor.text, "prose")
    }

    func testCommandIItalicises() {
        let editor = NoteEditor()
        editor.put("word", caretAt: 0)
        editor.view.setSelectedRange(NSRange(location: 0, length: 4))
        XCTAssertTrue(command("i", editor))
        XCTAssertEqual(editor.text, "*word*")
    }

    func testCommandKMakesALink() {
        let editor = NoteEditor()
        editor.put("Apple", caretAt: 0)
        editor.view.setSelectedRange(NSRange(location: 0, length: 5))
        XCTAssertTrue(command("k", editor))
        // The destination is left as a placeholder for you to replace — see `wrapLink`.
        XCTAssertEqual(editor.text, "[Apple](url)")
    }

    func testShiftCommandDDuplicatesTheLine() {
        let editor = NoteEditor()
        editor.reset("one")
        XCTAssertTrue(command("d", editor, shift: true))
        XCTAssertEqual(editor.text, "one\none")
    }

    func testOptionDownMovesTheLine() {
        let editor = NoteEditor()
        editor.put("one\ntwo", caretAt: 0)
        optionArrow(up: false, editor)
        XCTAssertEqual(editor.text, "two\none")
    }

    // MARK: Edges

    /// Nothing to swap with: stay put rather than beep, and above all don't lose a line.
    func testOptionUpOnTheFirstLineLeavesTheTextAlone() {
        let editor = NoteEditor()
        editor.put("one\ntwo", caretAt: 0)
        optionArrow(up: true, editor)
        XCTAssertEqual(editor.text, "one\ntwo")
    }

    /// Offsets are counted in UTF-16 by AppKit and in characters by the transforms. A note with an
    /// emoji in it is where those two disagree, and where a wrong conversion puts the markers in the
    /// middle of the word — or off the end of the string.
    func testAFormattingCommandLandsRightAfterAnEmoji() {
        let editor = NoteEditor()
        editor.put("👍 item", caretAt: 0)
        let start = ("👍 " as NSString).length
        editor.view.setSelectedRange(NSRange(location: start, length: 4))
        XCTAssertTrue(command("b", editor))
        XCTAssertEqual(editor.text, "👍 **item**")
    }

    func testFormattingAnEmptyNoteDoesNotFallOffTheEnd() {
        let editor = NoteEditor()
        editor.reset()
        command("b", editor)
        let selection = editor.view.selectedRange()
        XCTAssertLessThanOrEqual(selection.location + selection.length,
                                 (editor.text as NSString).length)
    }
}
