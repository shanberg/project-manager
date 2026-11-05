import XCTest

/// The ⌥Tab switcher's selection and hold rules. docs/spaces.md § Switcher.
final class SwitcherModelTests: XCTestCase {
    private func card(_ key: String, workspaces: [(String, [(String, String)])] = []) -> SwitcherModel.Card {
        var card = SwitcherModel.Card(key: key, title: key)
        card.entries = SwitcherModel.entries(workspaces: workspaces.map { ($0.0, $0.1.map { (id: $0.0, title: $0.1) }) })
        return card
    }

    func testOpensOnTheCardAfterTheFrontOneAsCommandTabDoes() {
        XCTAssertEqual(SwitcherModel(cards: [card("a"), card("b"), card("c")]).index, 1)
        XCTAssertEqual(SwitcherModel(cards: [card("a")]).index, 0, "one window: that one")
        XCTAssertTrue(SwitcherModel(cards: []).isEmpty)
    }

    func testTabWrapsBothWays() {
        var model = SwitcherModel(cards: [card("a"), card("b"), card("c")])
        model.move(by: 1); model.move(by: 1)
        XCTAssertEqual(model.selectedCard?.key, "a", "past the end wraps to the front")
        model.move(by: -1)
        XCTAssertEqual(model.selectedCard?.key, "c", "⇧Tab from the front wraps to the end")
    }

    func testEntriesAreNotesThenEachWorkspaceWithItsTiles() {
        let rows = SwitcherModel.entries(workspaces: [("Flyout", [(id: "n1", title: "Figma"), (id: "n2", title: "concepts.md")]),
                                                      ("Release", [])])
        XCTAssertEqual(rows.map(\.title), ["Notes", "Flyout", "Figma", "concepts.md", "Release"])
        XCTAssertEqual(rows[1].count, 2)
        XCTAssertEqual(rows[2].target, .tile(workspace: "Flyout", card: "n1"))
        XCTAssertEqual(SwitcherModel.entries(workspaces: [("Flyout", [(id: "n1", title: "Figma")])], showingTiles: false)
            .map(\.title), ["Notes", "Flyout"])
    }

    func testDownGoesIntoTheListAndUpComesBackToTheCard() {
        var model = SwitcherModel(cards: [card("a"), card("b", workspaces: [("W", [("t", "Tile")])])])
        model.moveEntry(by: 1)
        XCTAssertEqual(model.selectedEntry?.target, .notes)
        model.moveEntry(by: 5)
        XCTAssertEqual(model.selectedEntry?.target, .tile(workspace: "W", card: "t"), "stops at the last row")
        model.moveEntry(by: -3)
        XCTAssertNil(model.entry, "up from the first row is the card again")
        model.moveEntry(by: 1)
        model.move(by: 1)
        XCTAssertNil(model.entry, "moving along the row leaves the list")
    }

    func testPointingPicksACardOrARowAndIgnoresOneThatIsGone() {
        var model = SwitcherModel(cards: [card("a"), card("b", workspaces: [("W", [])])])
        model.point(at: 1, entry: 1)
        XCTAssertEqual(model.selectedEntry?.target, .workspace("W"))
        model.point(at: 0, entry: 7)
        XCTAssertEqual(model.index, 0)
        XCTAssertNil(model.entry)
        model.point(at: 9, entry: nil)
        XCTAssertEqual(model.index, 0)
    }

    func testAHeldOpenCommitsOnReleaseOnceAndRevealsAfterTheDelay() {
        let start = Date(timeIntervalSince1970: 0)
        var hold = SwitcherHold(held: true, at: start)
        XCTAssertFalse(hold.shouldReveal(at: start.addingTimeInterval(0.05)), "a quick tap draws nothing")
        XCTAssertTrue(hold.shouldReveal(at: start.addingTimeInterval(SwitcherHold.revealDelay)))
        XCTAssertTrue(hold.released())
        XCTAssertFalse(hold.released(), "only the first release commits")
    }

    func testAnUnheldOpenShowsAtOnceAndNeverCommitsOnRelease() {
        var hold = SwitcherHold(held: false, at: Date())
        XCTAssertTrue(hold.shouldReveal(at: Date()))
        XCTAssertFalse(hold.released())
    }
}

/// Project colours on the switcher's glass.
final class SwitcherInkTests: XCTestCase {
    func testBlackIsLiftedOnDarkGlassAndLeftAloneOnLight() {
        let lifted = SwitcherInk.legible(.black, dark: true)
        XCTAssertGreaterThan(SwitcherInk.luminance(lifted), 0.45, "readable on dark glass")
        XCTAssertEqual(SwitcherInk.legible(.black, dark: false), .black)
    }

    func testWhiteIsDeepenedOnLightGlass() {
        XCTAssertLessThan(SwitcherInk.luminance(SwitcherInk.legible(.white, dark: false)), 0.6)
        XCTAssertEqual(SwitcherInk.legible(.white, dark: true), .white)
    }

    func testAMidColourIsUntouchedEitherWay() {
        let blue = NSColor(srgbRed: 0.23, green: 0.47, blue: 0.91, alpha: 1)
        XCTAssertEqual(SwitcherInk.legible(blue, dark: true), blue)
        XCTAssertEqual(SwitcherInk.legible(blue, dark: false), blue)
    }

    func testTextOnALiftedBlackFillIsBlackOrWhiteByContrast() {
        XCTAssertFalse(SwitcherInk.onFillIsDark(.black))
        XCTAssertTrue(SwitcherInk.onFillIsDark(.white))
    }
}
