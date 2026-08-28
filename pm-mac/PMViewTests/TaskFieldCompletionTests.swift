import XCTest
import AppKit
import PmLib

/// The same loop in the task list's inline editors — Add Task, Edit Task, Wrap.
///
/// This surface is the reason `CompletionController` was extracted at all: the loop first landed in
/// the note editor only, and the note editor is not where most tasks are written. Typing `@ven` into
/// the place you actually add a task produced a task literally called "@ven".
@MainActor
final class TaskFieldCompletionTests: XCTestCase {

    private func makeField(lendsTokenEditor: Bool = true) throws -> TaskField {
        try XCTUnwrap(TaskField(lendsTokenEditor: lendsTokenEditor),
                      "no field editor — the window never gave the field one")
    }

    func testReturnInsertsTheProjectRatherThanSubmitting() throws {
        let field = try makeField()
        field.type("@ven")
        XCTAssertTrue(field.listIsUp)
        field.command(#selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(field.text, "[[W-3 Vendor Contract]] ")
        XCTAssertEqual(field.box.value, "[[W-3 Vendor Contract]] ", "the binding should see it too")
        XCTAssertFalse(field.box.submitted, "the list claimed the key, so the editor must not commit")
    }

    func testReturnWithNoListStillSubmits() throws {
        let field = try makeField()
        field.reset("Ordinary task")
        field.command(#selector(NSResponder.insertNewline(_:)))
        XCTAssertTrue(field.box.submitted)
    }

    func testEscapeWithNoListStillCancels() throws {
        let field = try makeField()
        field.reset("Ordinary task")
        field.command(#selector(NSResponder.cancelOperation(_:)))
        XCTAssertTrue(field.box.cancelled)
    }

    /// Escape takes the list down *first*. One press should not both dismiss a menu and throw away
    /// what was being typed.
    func testEscapeTakesTheListDownBeforeCancelling() throws {
        let field = try makeField()
        field.type("@ven")
        field.command(#selector(NSResponder.cancelOperation(_:)))
        XCTAssertFalse(field.listIsUp)
        XCTAssertFalse(field.box.cancelled)
    }

    func testTheWholeLoopWorksWhereTasksAreActuallyWritten() throws {
        let field = try makeField()
        field.reset("Legal review")
        field.type(" /wait")
        XCTAssertTrue(field.listIsUp)
        field.command(#selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(field.text, "Legal review waiting: @")
        XCTAssertTrue(field.listIsUp, "the wait should hand over to the picker")
        field.type("vendor")
        field.command(#selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(field.text, "Legal review waiting: [[W-3 Vendor Contract]] ")

        let typed = TaskContent.split(field.text)
        XCTAssertEqual(typed.text, "Legal review")
        XCTAssertEqual(typed.waiting, "W-3 Vendor Contract")
    }

    func testABareAtIsTheFocusMarkerHereToo() throws {
        let field = try makeField()
        field.reset("Ship the thing")
        field.type(" @")
        XCTAssertFalse(field.listIsUp)
    }

    // MARK: one thing, here too

    func testBackspaceAfterATokenClearsTheWholeToken() throws {
        let field = try makeField()
        field.reset("waiting: [[W-1 Website Refresh]]")
        field.command(#selector(NSResponder.deleteBackward(_:)))
        XCTAssertEqual(field.text, "waiting: ")
        XCTAssertEqual(field.box.value, "waiting: ", "the binding should follow")
    }

    /// Declined rather than handled, so the field's own backspace runs — the override has to be
    /// invisible away from a token.
    func testOrdinaryBackspaceIsLeftToTheField() throws {
        let field = try makeField()
        field.reset("plain")
        XCTAssertFalse(field.command(#selector(NSResponder.deleteBackward(_:))))
    }

    func testLeftArrowStepsOverTheToken() throws {
        let field = try makeField()
        field.reset("a [[Website]] b")
        field.editor.setSelectedRange(NSRange(location: 13, length: 0))
        field.command(#selector(NSResponder.moveLeft(_:)))
        XCTAssertEqual(field.caret, 2)
    }

    /// The token is drawn as a token rather than as markup: a wash behind the name, the brackets
    /// quieter than what they carry, and the prose either side left alone.
    func testTheTokenIsStyledAsAToken() throws {
        let field = try makeField()
        field.reset("waiting: [[W-1 Website Refresh]]")
        field.coordinator.restyleFromField()
        let storage = try XCTUnwrap(field.editor.textStorage)
        let inName = storage.attributes(at: 12, effectiveRange: nil)
        let inProse = storage.attributes(at: 2, effectiveRange: nil)
        XCTAssertNotNil(inName[.backgroundColor])
        XCTAssertNil(inProse[.backgroundColor])
        XCTAssertNotEqual(storage.attributes(at: 9, effectiveRange: nil)[.foregroundColor] as? NSColor,
                          inName[.foregroundColor] as? NSColor)
    }

    // MARK: the field editor the window lends

    /// **The fill.** A window that lends a `TokenFieldEditor` gives the field a real
    /// `TokenLayoutManager` — the drawing half as well as the glyph half — so a token in a task field
    /// gets the same pill it gets in a note.
    ///
    /// The delegate route the coordinator falls back to can only carry the glyph half, because
    /// `drawBackground` is an override rather than a delegate method. That is what left the field
    /// showing a token's spacing with nothing inside it, and it reads as a layout bug rather than a
    /// style.
    func testALendingWindowGivesTheFieldARealTokenLayoutManager() throws {
        let field = try makeField(lendsTokenEditor: true)
        XCTAssertTrue(field.editor is TokenFieldEditor)
        XCTAssertTrue(field.editor.layoutManager is TokenLayoutManager,
                      "without this the pill is never drawn, only its padding")
    }

    /// Negative control, and the fallback: a plain window still gets the padding through the
    /// coordinator's delegate, and still isn't a `TokenLayoutManager`.
    func testAPlainWindowFallsBackToTheDelegate() throws {
        let field = try makeField(lendsTokenEditor: false)
        XCTAssertFalse(field.editor is TokenFieldEditor)
        XCTAssertFalse(field.editor.layoutManager is TokenLayoutManager)
        XCTAssertTrue(field.editor.layoutManager?.delegate === field.coordinator.glyphHider,
                      "the glyph half should still be installed where there's no real one")
    }

    /// The coordinator must not put its own delegate over a real layout manager: the removal on
    /// end-editing would then leave the lent editor with none at all for whatever was edited next.
    func testTheFallbackIsNotInstalledOverARealOne() throws {
        let field = try makeField(lendsTokenEditor: true)
        XCTAssertFalse(field.editor.layoutManager?.delegate === field.coordinator.glyphHider)
        XCTAssertTrue(field.editor.layoutManager?.delegate === field.editor.layoutManager,
                      "a TokenLayoutManager is its own delegate")
    }

    /// Only the token fields get one. A window also holds the find bar and the details form, and
    /// nothing in those contains a token to draw.
    func testOnlyTokenFieldsAreLentOne() {
        XCTAssertTrue(TokenFieldEditor.wants(TokenClickField()))
        XCTAssertFalse(TokenFieldEditor.wants(NSTextField()))
        XCTAssertFalse(TokenFieldEditor.wants(nil))
    }
}
