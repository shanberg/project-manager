import XCTest
import AppKit
import PmLib

/// Cut, copy and paste in a note — on a pasteboard of this suite's own.
///
/// **The clipboard is the user's, and a test suite that writes to it costs them whatever they had
/// copied.** So nothing here touches `NSPasteboard.general`: every test drives a uniquely named
/// pasteboard through `ShortcutTextView.pasteSource` (a paste) or hands one to
/// `writeSelection(to:type:)` (a copy — the call `copy(_:)` makes internally). `tearDown` asserts the
/// general pasteboard never changed, so a future test that reaches for it fails here rather than in
/// somebody's afternoon.
///
/// What this cannot reach, and why: `cut(_:)` and `copy(_:)` themselves, which write to the general
/// pasteboard with no seam of AppKit's to redirect — they are `NSTextView`'s own, this class doesn't
/// override them, and `writeSelection` is the part worth asserting anyway. `validateUserInterfaceItem`
/// for text, whose enabling half is `super`'s and reads the general pasteboard too — see
/// `NoteImagePasteTests`, which asserts that one as "we don't claim it".
@MainActor
final class NoteEditorClipboardTests: XCTestCase {

    private var generalChangeCount = 0

    override func setUp() {
        super.setUp()
        generalChangeCount = NSPasteboard.general.changeCount
    }

    override func tearDown() {
        XCTAssertEqual(NSPasteboard.general.changeCount, generalChangeCount,
                       "these tests must not write to the user's clipboard")
        super.tearDown()
    }

    /// A pasteboard of this test's own, emptied before use and given back afterwards.
    private func pasteboard() -> NSPasteboard {
        let board = NSPasteboard.withUniqueName()
        board.clearContents()
        addTeardownBlock { board.releaseGlobally() }
        return board
    }

    /// A copy, made the way `copy(_:)` makes one: declare the view's own writable types on the
    /// pasteboard, then let it write the selection into them. Two steps rather than one because
    /// `writeSelection` writes into types that have already been declared, and answers false when they
    /// haven't — which is the whole of what `copy(_:)` adds, minus the general pasteboard.
    @discardableResult
    private func copySelection(of editor: NoteEditor, to board: NSPasteboard) -> Bool {
        let types = editor.view.writablePasteboardTypes
        board.declareTypes(types, owner: nil)
        return editor.view.writeSelection(to: board, types: types)
    }

    private func paste(_ string: String, into editor: NoteEditor) {
        let board = pasteboard()
        board.setString(string, forType: .string)
        editor.view.pasteSource = board
        editor.view.paste(nil)
    }

    // MARK: Pasting

    func testPastedTextLandsAtTheCaret() {
        let editor = NoteEditor()
        editor.put("one three", caretAt: 4)
        paste("two ", into: editor)
        XCTAssertEqual(editor.text, "one two three")
    }

    func testPastedTextReplacesTheSelection() {
        let editor = NoteEditor()
        editor.put("one two", caretAt: 0)
        editor.view.setSelectedRange(NSRange(location: 4, length: 3))
        paste("three", into: editor)
        XCTAssertEqual(editor.text, "one three")
    }

    /// The markup is the point. A note is markdown source, and everything that makes it source — the
    /// markers, the wikilink's brackets, the leading `#` — has to survive a paste unaltered, including
    /// the quotes and dashes that a Mac text view is otherwise entitled to prettify.
    func testAWholeMarkdownDocumentPastesVerbatim() {
        let editor = NoteEditor()
        editor.reset()
        let source = """
        # Heading

        - a list item with **bold** and *italic*
          - a nested one, with a [[Wikilink]]
        - [ ] a task -- with "quotes" and 'apostrophes'

        > a quote

        ```
        code -- untouched
        ```
        """
        paste(source, into: editor)
        XCTAssertEqual(editor.text, source)
    }

    /// The app's own branch: a URL pasted over words links those words, which is what every markdown
    /// editor does with ⌘V on a selection.
    func testAURLPastedOverASelectionLinksIt() {
        let editor = NoteEditor()
        editor.put("the Apple site", caretAt: 0)
        editor.view.setSelectedRange(NSRange(location: 4, length: 5))
        paste("https://apple.com", into: editor)
        XCTAssertEqual(editor.text, "the [Apple](https://apple.com) site")
    }

    /// With nothing selected there is nothing to link, and a URL is text like any other.
    func testAURLPastedWithNoSelectionIsJustText() {
        let editor = NoteEditor()
        editor.reset("see ")
        paste("https://apple.com", into: editor)
        XCTAssertEqual(editor.text, "see https://apple.com")
    }

    /// Only a URL links a selection. Ordinary words replace it, or every paste over a selection would
    /// be a link.
    func testWordsPastedOverASelectionDoNotLinkIt() {
        let editor = NoteEditor()
        editor.put("the Apple site", caretAt: 0)
        editor.view.setSelectedRange(NSRange(location: 4, length: 5))
        paste("Orange", into: editor)
        XCTAssertEqual(editor.text, "the Orange site")
    }

    /// One ⌘Z takes back a paste, however many lines it put in — a paste is one thing you did.
    func testAPasteIsOneUndoStep() {
        let editor = NoteEditor()
        editor.reset("before\n")
        paste("one\ntwo\nthree", into: editor)
        XCTAssertEqual(editor.text, "before\none\ntwo\nthree")

        editor.window.undoManager?.undo()
        XCTAssertEqual(editor.text, "before\n")
    }

    /// A link made from a pasted URL is one step too, and taking it back leaves the words that were
    /// selected — not the URL, and not nothing.
    func testUndoingAPastedLinkLeavesTheWords() {
        let editor = NoteEditor()
        editor.put("the Apple site", caretAt: 0)
        editor.view.setSelectedRange(NSRange(location: 4, length: 5))
        paste("https://apple.com", into: editor)

        editor.window.undoManager?.undo()
        XCTAssertEqual(editor.text, "the Apple site")
    }

    // MARK: Copying

    /// What leaves the editor is the source, not the picture of it. `[[Project]]` is drawn as one pill
    /// and copied as its thirteen characters — a token that copied as what it looks like would paste
    /// into Obsidian as something that isn't a link.
    func testCopyingAWikilinkTakesTheMarkupNotThePill() {
        let editor = NoteEditor()
        editor.reset("see [[W-1 Website Refresh]] for more")
        editor.view.setSelectedRange(NSRange(location: 4, length: 23))

        let board = pasteboard()
        XCTAssertTrue(copySelection(of: editor, to: board))
        XCTAssertEqual(board.string(forType: .string), "[[W-1 Website Refresh]]")
    }

    /// A note is a plain-text view, so what it puts on the pasteboard is plain text — no RTF flavour
    /// carrying the fonts and colours the highlighter drew with into somebody else's document.
    func testCopyingOffersPlainTextAndNotRichText() {
        let editor = NoteEditor()
        editor.reset("# Heading with **bold**")
        editor.view.setSelectedRange(NSRange(location: 0, length: (editor.text as NSString).length))

        let board = pasteboard()
        XCTAssertTrue(copySelection(of: editor, to: board))
        XCTAssertFalse(editor.view.writablePasteboardTypes.contains(.rtf))
        XCTAssertNil(board.data(forType: .rtf))
        XCTAssertEqual(board.string(forType: .string), "# Heading with **bold**")
    }

    /// The round trip, which is the thing a person actually does: copy out of one note, paste into
    /// another, and get back exactly what was copied.
    func testCopyingOutOfOneNoteAndIntoAnotherIsExact() {
        let source = NoteEditor()
        source.reset("- [ ] a task with a [[Wikilink]] and **bold**")
        source.view.setSelectedRange(NSRange(location: 0, length: (source.text as NSString).length))

        let board = pasteboard()
        XCTAssertTrue(copySelection(of: source, to: board))

        let destination = NoteEditor()
        destination.reset()
        destination.view.pasteSource = board
        destination.view.paste(nil)

        XCTAssertEqual(destination.text, source.text)
    }
}
