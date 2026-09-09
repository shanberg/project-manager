import XCTest
import PmLib

/// The rules of an editing session in a card: what counts as your own edit coming back, and what
/// stepping out of the card comes to.
///
/// Asked of `CanvasCardEditing` rather than of the card, which cannot exist without a board, a window
/// and a document — see the type's own note.
final class CanvasCardEditingTests: XCTestCase {

    // MARK: Your own edit, coming back

    /// The reason the type exists: the keystroke you just made must not be read as news from the
    /// document, or the editor is rebuilt underneath the caret once per character.
    func testTheTextTheEditorJustWroteIsItsOwn() {
        var session = CanvasCardEditing(opening: "note")
        session.wrote("note!")
        XCTAssertTrue(session.echoes(.text("note!")))
    }

    func testSomebodyElsesTextIsNot() {
        var session = CanvasCardEditing(opening: "note")
        session.wrote("note!")
        XCTAssertFalse(session.echoes(.text("note from Obsidian")))
    }

    /// A session that has written nothing has nothing of its own to hear back — the state a card is in
    /// between stepping into it and the first keystroke.
    func testASessionThatHasWrittenNothingEchoesNothing() {
        let session = CanvasCardEditing(opening: "note")
        XCTAssertFalse(session.echoes(.text("note")))
    }

    /// A card that is not text at all is not this card's edit whatever it says.
    func testAnotherKindOfContentIsNeverItsOwn() {
        var session = CanvasCardEditing(opening: "")
        session.wrote("")
        XCTAssertFalse(session.echoes(.link(url: "https://example.com")))
    }

    /// A rebuilt editor is showing what the *document* says, so nothing is outstanding — and an
    /// outside edit that happens to arrive back at the same text has to rebuild rather than be
    /// mistaken for an echo of a write that has already landed.
    func testARebuiltEditorHasNothingOutstanding() {
        var session = CanvasCardEditing(opening: "note")
        session.wrote("note!")
        session.editorBuilt()
        XCTAssertFalse(session.echoes(.text("note!")))
    }

    // MARK: The one step the document gets

    /// The session's step is its *first* keystroke, so a fresh session is still owed one.
    func testASessionThatHasTypedNothingHasNotChangedTheDocument() {
        let session = CanvasCardEditing(opening: "note")
        XCTAssertFalse(session.hasWritten)
    }

    func testTheFirstKeystrokeOpensTheEdit() {
        var session = CanvasCardEditing(opening: "note")
        session.wrote("note!")
        XCTAssertTrue(session.hasWritten)
    }

    /// A rebuild is about what is on screen, not about what the document has already been told. The
    /// session must not open a *second* step because an outside edit replaced the editor mid-session.
    func testARebuiltEditorDoesNotOpenTheEditAgain() {
        var session = CanvasCardEditing(opening: "note")
        session.wrote("note!")
        session.editorBuilt()
        XCTAssertTrue(session.hasWritten)
    }

    // MARK: Stepping out

    func testACardWithWordsInItStays() {
        let session = CanvasCardEditing(opening: "before")
        XCTAssertEqual(session.stepOut(showing: "before and after"), .keepTheCard)
    }

    /// The double-click that landed somewhere you didn't mean.
    func testACardOpenedEmptyAndLeftEmptyIsDiscarded() {
        let session = CanvasCardEditing(opening: "")
        XCTAssertEqual(session.stepOut(showing: "   \n "), .discardTheCard)
    }

    func testACardOpenedEmptyAndTypedIntoIsKept() {
        let session = CanvasCardEditing(opening: "")
        XCTAssertEqual(session.stepOut(showing: "typed"), .keepTheCard)
    }

    /// The distinction the discard rule turns on: a card you *emptied* is an edit, and one ⌘Z has to
    /// be able to bring the text back — which it cannot do into a card that has been deleted.
    func testACardYouEmptiedIsKeptRatherThanDiscarded() {
        let session = CanvasCardEditing(opening: "words")
        XCTAssertEqual(session.stepOut(showing: ""), .keepTheCard)
    }

    /// Whitespace is not content, on the way in as much as on the way out.
    func testACardOpenedOnWhitespaceCountsAsEmpty() {
        let session = CanvasCardEditing(opening: "  ")
        XCTAssertEqual(session.stepOut(showing: ""), .discardTheCard)
    }
}
