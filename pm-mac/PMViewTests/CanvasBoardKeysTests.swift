import AppKit
import XCTest

/// Which key means what on the board, in the two modes that take the keyboard.
///
/// These were decided inline in `CanvasBoardView.keyDown` and could not be checked, because nothing in
/// this bundle can build a board. Each case pins a rule the code's comments give a reason for.
final class CanvasBoardKeysTests: XCTestCase {

    private typealias Keys = CanvasBoardKeys
    private let step = 64.0

    private func workspace(_ press: Keys.Press, choosing: Bool = false, focused: Bool = true) -> Keys.WorkspaceCommand? {
        Keys.workspace(press, choosingPlacement: choosing, hasFocusedTile: focused, step: step)
    }

    private func chars(_ c: String, _ flags: NSEvent.ModifierFlags = []) -> Keys.Press {
        Keys.Press(characters: c, flags: flags)
    }

    private func arrow(_ key: NSEvent.SpecialKey, _ flags: NSEvent.ModifierFlags = []) -> Keys.Press {
        Keys.Press(specialKey: key, flags: flags)
    }

    // MARK: The workspace

    /// **Never with ⌘ or ⌃**, so a menu's key equivalents stay the menu's.
    func testCommandAndControlAreNeverTheWorkspaces() {
        XCTAssertNil(workspace(chars("=", [.option, .command])))
        XCTAssertNil(workspace(arrow(.leftArrow, [.option, .control])))
        XCTAssertNil(workspace(arrow(.leftArrow, .command), choosing: true))
    }

    /// Without ⌥ the workspace takes nothing — unless it is choosing where the next card goes.
    func testPlainKeysAreNotTakenUnlessAPlacementIsBeingChosen() {
        XCTAssertNil(workspace(arrow(.leftArrow)))
        XCTAssertNil(workspace(chars("\r")))
        XCTAssertNil(workspace(chars("t")))

        XCTAssertEqual(workspace(arrow(.leftArrow), choosing: true), .choosePlacement(.left))
        XCTAssertEqual(workspace(arrow(.upArrow), choosing: true), .choosePlacement(.above))
        XCTAssertEqual(workspace(arrow(.downArrow), choosing: true), .choosePlacement(.below))
        XCTAssertEqual(workspace(chars("\r"), choosing: true), .confirmPlacement)
        XCTAssertEqual(workspace(chars("T"), choosing: true), .choosePlacement(.tab))
    }

    func testOptionArrowsMoveTheFocusAndShiftMovesTheTile() {
        XCTAssertEqual(workspace(arrow(.rightArrow, .option)), .moveFocus(.right))
        XCTAssertEqual(workspace(arrow(.rightArrow, [.option, .shift])), .moveTile(.right))
    }

    /// **Shift changes the character, not only the flags**: ⌥⇧= arrives as "+", and has to grow the tile
    /// the other way rather than falling through as an unknown key.
    func testShiftedGrowKeysArriveAsTheirShiftedCharacters() {
        XCTAssertEqual(workspace(chars("=", .option)), .grow(vertically: false, by: step))
        XCTAssertEqual(workspace(chars("+", [.option, .shift])), .grow(vertically: true, by: step))
        XCTAssertEqual(workspace(chars("-", .option)), .grow(vertically: false, by: -step))
        XCTAssertEqual(workspace(chars("_", [.option, .shift])), .grow(vertically: true, by: -step))
    }

    func testTheRestOfTheWorkspaceKeys() {
        XCTAssertEqual(workspace(chars("0", .option)), .balance)
        XCTAssertEqual(workspace(chars(")", [.option, .shift])), .sizeToContent)
        XCTAssertEqual(workspace(chars("b", .option)), .beginPicking)
        XCTAssertEqual(workspace(chars("`", .option)), .focusPrevious)
        XCTAssertEqual(workspace(chars("[", .option)), .stepTab(-1))
        XCTAssertEqual(workspace(chars("]", .option)), .stepTab(1))
        XCTAssertEqual(workspace(arrow(.delete, .option)), .removeTile)
        XCTAssertNil(workspace(chars("q", .option)), "a key the workspace doesn't use goes on to the board")
    }

    /// ⌥T pulls the focused tile's tab out, and says so when there's no tile to pull from.
    func testPullingATabOutWithNoTileFocusedBeeps() {
        XCTAssertEqual(workspace(chars("t", .option), focused: true), .pullTabOut)
        XCTAssertEqual(workspace(chars("t", .option), focused: false), .beep)
    }

    /// ⌥N starts choosing where the next card goes, and the same key while choosing stops.
    func testOptionNTogglesChoosingAPlacement() {
        XCTAssertEqual(workspace(chars("n", .option)), .beginPlacing)
        XCTAssertEqual(workspace(chars("n", .option), choosing: true), .cancelPlacement)
    }

    // MARK: Picking

    /// **Picking takes the keyboard whole.** ⌫ in particular must not reach the board, where it would
    /// delete a card off the board you are only choosing from.
    func testPickingSwallowsKeysThatMeanNothingThere() {
        XCTAssertEqual(Keys.picking(Keys.Press(specialKey: .delete), peeking: false, hovering: true), .swallow)
        XCTAssertEqual(Keys.picking(chars("x"), peeking: true, hovering: true), .swallow)
    }

    func testSpacePeeksAtTheHoveredCardAndBeepsWithNothingUnderThePointer() {
        XCTAssertEqual(Keys.picking(chars(" "), peeking: false, hovering: true), .beginPeek)
        XCTAssertEqual(Keys.picking(chars(" "), peeking: false, hovering: false), .beep)
    }

    /// A held Space would otherwise peek and un-peek at key-repeat rate.
    func testAHeldSpaceDoesNotFlickerThePeek() {
        XCTAssertEqual(Keys.picking(Keys.Press(characters: " ", isRepeat: true), peeking: false, hovering: true), .swallow)
        XCTAssertEqual(Keys.picking(Keys.Press(characters: " ", isRepeat: true), peeking: true, hovering: true), .swallow)
    }

    func testPeekingSpaceOrEscapePutsTheCardBackAndReturnAddsIt() {
        XCTAssertEqual(Keys.picking(chars(" "), peeking: true, hovering: true), .endPeek)
        XCTAssertEqual(Keys.picking(chars("\u{1b}"), peeking: true, hovering: true), .endPeek)
        XCTAssertEqual(Keys.picking(chars("\r"), peeking: true, hovering: true), .finishPeek)
    }

    func testEscapeReturnAndOptionBGoBackToTheWorkspace() {
        XCTAssertEqual(Keys.picking(chars("\u{1b}"), peeking: false, hovering: false), .endPicking)
        XCTAssertEqual(Keys.picking(chars("\r"), peeking: false, hovering: false), .endPicking)
        XCTAssertEqual(Keys.picking(chars("b", .option), peeking: true, hovering: true), .endPicking,
                       "⌥B leaves picking even from inside a peek")
    }

    // MARK: The board

    /// Space alone holds the board, and so does every repeat of a held Space.
    func testSpaceHoldsTheBoardToPan() {
        XCTAssertTrue(Keys.holdsToPan(chars(" ")))
        XCTAssertTrue(Keys.holdsToPan(Keys.Press(characters: " ", isRepeat: true)))
        XCTAssertTrue(Keys.holdsToPan(chars(" ", .capsLock)), "Caps Lock is a state, not a modifier")
    }

    /// A modified Space is somebody's shortcut — ⌃Space is the input source, ⌘Space is Spotlight — and
    /// any other key is not a hold at all.
    func testAModifiedSpaceOrAnotherKeyIsNotAHold() {
        XCTAssertFalse(Keys.holdsToPan(chars(" ", .command)))
        XCTAssertFalse(Keys.holdsToPan(chars(" ", .control)))
        XCTAssertFalse(Keys.holdsToPan(chars(" ", .shift)))
        XCTAssertFalse(Keys.holdsToPan(chars("h")))
        XCTAssertFalse(Keys.holdsToPan(Keys.Press(specialKey: .leftArrow)))
    }
}
