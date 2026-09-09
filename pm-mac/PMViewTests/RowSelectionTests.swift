import XCTest
import AppKit

/// What clicking and arrowing around a list of rows does to the selection.
///
/// The rules read as obvious and are not: ⇧-click ranges from the anchor rather than from the nearest
/// end, ⌘-click leaves the anchor on the row you toggled whether you added it or took it away, ↑ into
/// an empty selection enters at the *bottom*, and a selection has to survive the list underneath it
/// being filtered without keeping keys nobody can see. Every one of those is a thing a person notices
/// only when it is wrong.
final class RowSelectionTests: XCTestCase {
    private let rows = ["a", "b", "c", "d", "e"]

    // MARK: Clicking

    func testAPlainClickTakesJustThatRowAndAnchorsThere() {
        var selection = RowSelection()
        selection.click("c", modifiers: [], in: rows)
        XCTAssertEqual(selection.keys, ["c"])
        XCTAssertEqual(selection.anchor, "c")
        XCTAssertEqual(selection.single, "c")

        selection.click("a", modifiers: [], in: rows)
        XCTAssertEqual(selection.keys, ["a"], "a plain click replaces rather than adds")
    }

    func testCommandClickTogglesARowInAndOut() {
        var selection = RowSelection()
        selection.click("b", modifiers: [], in: rows)
        selection.click("d", modifiers: .command, in: rows)
        XCTAssertEqual(selection.keys, ["b", "d"])
        XCTAssertEqual(selection.anchor, "d")
        XCTAssertNil(selection.single, "two rows is no single row")

        selection.click("b", modifiers: .command, in: rows)
        XCTAssertEqual(selection.keys, ["d"])
        XCTAssertEqual(selection.anchor, "b", "the anchor follows the row you touched, added or removed")
    }

    /// From the anchor, not from the nearest edge of what is already selected — and in either
    /// direction, because a range has two ends and neither of them is special.
    func testShiftClickRangesFromTheAnchorEitherWay() {
        var selection = RowSelection()
        selection.click("b", modifiers: [], in: rows)
        selection.click("d", modifiers: .shift, in: rows)
        XCTAssertEqual(selection.keys, ["b", "c", "d"])
        XCTAssertEqual(selection.anchor, "b", "extending does not move the anchor")

        selection.click("a", modifiers: .shift, in: rows)
        XCTAssertEqual(selection.keys, ["a", "b"], "the range is re-measured from the same anchor")
    }

    /// There is no range without two ends, so this is a plain click on the row you actually hit.
    func testShiftClickWithNoAnchorIsAPlainClick() {
        var selection = RowSelection()
        selection.click("c", modifiers: .shift, in: rows)
        XCTAssertEqual(selection.keys, ["c"])
        XCTAssertEqual(selection.anchor, "c")
    }

    /// A range whose anchor has been filtered off the screen collapses to the end that is still real,
    /// rather than selecting everything or nothing.
    func testAShiftClickPastAVanishedAnchorTakesOnlyTheClickedRow() {
        var selection = RowSelection()
        selection.click("gone", modifiers: [], in: rows)
        selection.click("c", modifiers: .shift, in: rows)
        XCTAssertEqual(selection.keys, ["c"])
    }

    // MARK: Arrowing

    /// Into a list from nowhere: ↓ enters at the top and ↑ at the bottom, so the first press lands on
    /// the row you are travelling towards rather than skipping it.
    func testArrowingIntoAnEmptySelectionEntersFromTheEndYouAreHeadingFrom() {
        var down = RowSelection()
        XCTAssertEqual(down.step(1, extending: false, in: rows), "a")
        XCTAssertEqual(down.keys, ["a"])

        var up = RowSelection()
        XCTAssertEqual(up.step(-1, extending: false, in: rows), "e")
        XCTAssertEqual(up.keys, ["e"])
    }

    /// ↓ leaves from the *last* selected row and ↑ from the first, which is what makes arrowing out of
    /// a range continue past it instead of walking back through it.
    func testArrowingLeavesARangeFromTheEndYouAreHeadingFor() {
        var selection = RowSelection()
        selection.click("b", modifiers: [], in: rows)
        selection.click("d", modifiers: .shift, in: rows)

        var down = selection
        XCTAssertEqual(down.step(1, extending: false, in: rows), "e")

        var up = selection
        XCTAssertEqual(up.step(-1, extending: false, in: rows), "a")
    }

    func testShiftArrowingExtendsFromTheAnchorAndKeepsIt() {
        var selection = RowSelection()
        selection.click("c", modifiers: [], in: rows)
        selection.step(1, extending: true, in: rows)
        XCTAssertEqual(selection.keys, ["c", "d"])
        selection.step(1, extending: true, in: rows)
        XCTAssertEqual(selection.keys, ["c", "d", "e"])
        XCTAssertEqual(selection.anchor, "c")

        // And back over itself, which shrinks rather than adding to the other side.
        selection.step(-1, extending: true, in: rows)
        XCTAssertEqual(selection.keys, ["c", "d"])
    }

    /// The same, from a range built *upwards*: the moving end is the top one, so ⇧↓ shrinks it.
    func testShiftArrowingShrinksARangeBuiltUpwards() {
        var selection = RowSelection()
        selection.click("d", modifiers: [], in: rows)
        selection.click("b", modifiers: .shift, in: rows)
        XCTAssertEqual(selection.keys, ["b", "c", "d"])

        selection.step(1, extending: true, in: rows)
        XCTAssertEqual(selection.keys, ["c", "d"])
        XCTAssertEqual(selection.anchor, "d")

        selection.step(-1, extending: true, in: rows)
        XCTAssertEqual(selection.keys, ["b", "c", "d"], "and grows again on the way back")
    }

    /// Shrinking all the way past the anchor and out the other side: the range flips rather than
    /// getting stuck on one row.
    func testShiftArrowingCrossesTheAnchor() {
        var selection = RowSelection()
        selection.click("c", modifiers: [], in: rows)
        selection.step(1, extending: true, in: rows)
        XCTAssertEqual(selection.keys, ["c", "d"])
        selection.step(-1, extending: true, in: rows)
        XCTAssertEqual(selection.keys, ["c"])
        selection.step(-1, extending: true, in: rows)
        XCTAssertEqual(selection.keys, ["b", "c"])
        XCTAssertEqual(selection.anchor, "c")
    }

    /// A list has ends. Arrowing at one stays put rather than wrapping — this is a selection, not the
    /// find bar, whose stepping wraps on purpose.
    func testArrowingStopsAtTheEnds() {
        var selection = RowSelection()
        selection.click("e", modifiers: [], in: rows)
        XCTAssertEqual(selection.step(1, extending: false, in: rows), "e")

        selection.click("a", modifiers: [], in: rows)
        XCTAssertEqual(selection.step(-1, extending: false, in: rows), "a")
    }

    func testArrowingAnEmptyListDoesNothing() {
        var selection = RowSelection()
        XCTAssertNil(selection.step(1, extending: false, in: []))
        XCTAssertTrue(selection.isEmpty)
    }

    // MARK: Keeping up with the list

    /// Completing a task hides it under the Incomplete filter, and a find narrows the list. What is
    /// left selected has to be what is left on screen.
    func testKeepingWithinTheRowsDropsWhatIsNoLongerThere() {
        var selection = RowSelection()
        selection.selectAll(in: rows)
        XCTAssertEqual(selection.keys, Set(rows))
        XCTAssertEqual(selection.anchor, "a")

        selection.keep(within: ["b", "d"])
        XCTAssertEqual(selection.keys, ["b", "d"])
        XCTAssertNil(selection.anchor, "an anchor that is no longer a row is no anchor")
    }

    func testKeepingWithinTheRowsLeavesALiveAnchorAlone() {
        var selection = RowSelection()
        selection.click("b", modifiers: [], in: rows)
        selection.click("d", modifiers: .shift, in: rows)
        selection.keep(within: ["b", "c"])
        XCTAssertEqual(selection.keys, ["b", "c"])
        XCTAssertEqual(selection.anchor, "b")
    }

    /// Collapsing the brief takes the session headers out of the list entirely — see
    /// `ProjectView.setDetails`.
    func testRemovingByPredicateTakesTheAnchorWithIt() {
        var selection = RowSelection()
        selection.click("sess:0", modifiers: [], in: ["sess:0", "a"])
        selection.click("a", modifiers: .command, in: ["sess:0", "a"])
        selection.remove { $0.hasPrefix("sess:") }
        XCTAssertEqual(selection.keys, ["a"])
        XCTAssertEqual(selection.anchor, "a", "the anchor was the task, and the task survived")

        selection.click("sess:0", modifiers: [], in: ["sess:0", "a"])
        selection.remove { $0.hasPrefix("sess:") }
        XCTAssertTrue(selection.isEmpty)
        XCTAssertNil(selection.anchor)
    }

    // MARK: What a command acts on

    /// Finder's rule, and the whole reason a right-click on an unselected row moves the highlight
    /// first: a menu opened inside a selection acts on all of it, and one opened outside acts on the
    /// row you actually pointed at.
    func testARowsCommandsActOnTheSelectionOnlyWhenTheRowIsInIt() {
        var selection = RowSelection()
        selection.click("b", modifiers: [], in: rows)
        selection.click("c", modifiers: .command, in: rows)

        XCTAssertEqual(selection.targets(clicked: "c"), ["b", "c"])
        XCTAssertEqual(selection.targets(clicked: "e"), ["e"])
    }

    func testRevealingForAContextMenuOnlyMovesTheHighlightFromOutside() {
        var selection = RowSelection()
        selection.click("b", modifiers: [], in: rows)
        selection.click("c", modifiers: .command, in: rows)

        XCTAssertFalse(selection.revealForContextMenu("c"), "a click inside the selection changes nothing")
        XCTAssertEqual(selection.keys, ["b", "c"])

        XCTAssertTrue(selection.revealForContextMenu("e"))
        XCTAssertEqual(selection.keys, ["e"])
        XCTAssertEqual(selection.anchor, "e")
    }

    /// A paste leaves what arrived selected, which is the only confirmation that it landed where you
    /// meant — and the anchor goes to the first of them, so ⇧↓ extends down the new block.
    func testSelectingWhatArrivedAnchorsOnItsFirstRow() {
        var selection = RowSelection()
        selection.click("a", modifiers: [], in: rows)
        selection.select(["c", "d"])
        XCTAssertEqual(selection.keys, ["c", "d"])
        XCTAssertEqual(selection.anchor, "c")

        selection.clear()
        XCTAssertTrue(selection.isEmpty)
        XCTAssertNil(selection.anchor)
    }
}
