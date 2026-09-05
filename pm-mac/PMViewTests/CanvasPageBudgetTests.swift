import XCTest
@testable import PMViewTests

/// Which cards get to run a page.
///
/// The rule is a comparison between cards, so it is a value rather than a method on a view — which
/// means the interesting cases (more of the board on screen than the budget covers, a card you are
/// using while the board is zoomed out) can be asserted directly instead of through a window and a
/// scroll position.
final class CanvasPageBudgetTests: XCTestCase {
    /// A card that wants to run, `distance` points from the middle of the window.
    private func card(_ id: String, distance: Double, visible: Bool = true,
                      engaged: Bool = false, wants: Bool = true,
                      goneFor: Double = 0) -> CanvasPageBudget.Candidate {
        .init(id: id, wantsPage: wants, isVisible: visible, isEngaged: engaged,
              distanceFromCentre: distance, secondsSinceVisible: goneFor)
    }

    func testAQuietBoardRunsEverythingOnScreen() {
        let cards = (0..<5).map { card("\($0)", distance: Double($0) * 100) }
        XCTAssertEqual(CanvasPageBudget.live(among: cards).count, 5)
    }

    /// The complaint that produced the grace period: panning is how you read a board, and a page that
    /// died the moment it crossed the edge of the window made you think about where the edge was.
    func testPanningPastACardDoesNotCostYouIt() {
        let live = CanvasPageBudget.live(among: [card("here", distance: 10),
                                                card("justPast", distance: 4000, visible: false,
                                                     goneFor: 4)])
        XCTAssertEqual(live, ["here", "justPast"], "there is room for both, so both keep running")
    }

    func testACardNobodyHasBeenNearForAWhileGivesUpItsSlot() {
        let live = CanvasPageBudget.live(among: [card("here", distance: 10),
                                                card("longGone", distance: 4000, visible: false,
                                                     goneFor: CanvasPageBudget.offFrameGrace + 1)])
        XCTAssertEqual(live, ["here"])
    }

    /// Under pressure the window wins. A card you can see is worth more than a card you saw.
    func testWhatIsOnScreenTakesTheSlotsFirst() {
        var cards = (0..<8).map { card("onScreen\($0)", distance: Double($0) * 100) }
        cards.append(card("recent", distance: 5000, visible: false, goneFor: 1))
        let live = CanvasPageBudget.live(among: cards)
        XCTAssertEqual(live.count, CanvasPageBudget.livePages)
        XCTAssertFalse(live.contains("recent"), "eight on screen leaves nothing for one off it")
    }

    /// And among the ones off screen, the one you left most recently is the one you are likeliest to
    /// come back to.
    func testTheMostRecentlySeenKeepsItsSlot() {
        var cards = (0..<6).map { card("onScreen\($0)", distance: Double($0) * 100) }
        cards.append(card("left5s", distance: 5000, visible: false, goneFor: 5))
        cards.append(card("left50s", distance: 5000, visible: false, goneFor: 50))
        cards.append(card("left80s", distance: 5000, visible: false, goneFor: 80))
        let live = CanvasPageBudget.live(among: cards)
        XCTAssertTrue(live.contains("left5s"))
        XCTAssertTrue(live.contains("left50s"))
        XCTAssertFalse(live.contains("left80s"), "two slots left, and it was third in line")
    }

    func testTheBudgetKeepsWhatIsNearestTheMiddle() {
        // Twelve cards on screen — what zooming out on a dashboard looks like.
        let cards = (0..<12).map { card("card\($0)", distance: Double($0) * 100) }
        let live = CanvasPageBudget.live(among: cards)
        XCTAssertEqual(live.count, CanvasPageBudget.livePages)
        XCTAssertTrue(live.contains("card0"))
        XCTAssertTrue(live.contains("card7"), "the eighth nearest still makes it")
        XCTAssertFalse(live.contains("card8"), "the ninth is where the board stops paying")
    }

    /// The card under your pointer is the one case where the budget doesn't get a say.
    func testACardYouAreUsingStaysLive() {
        var cards = (0..<12).map { card("card\($0)", distance: Double($0) * 100) }
        cards[11].isEngaged = true
        let live = CanvasPageBudget.live(among: cards)
        XCTAssertTrue(live.contains("card11"), "furthest from the middle, but you are using it")
        XCTAssertEqual(live.count, CanvasPageBudget.livePages)
    }

    func testACardYouAreUsingStaysLiveEvenOffScreen() {
        let live = CanvasPageBudget.live(among: [card("held", distance: 9000, visible: false,
                                                      engaged: true)])
        XCTAssertEqual(live, ["held"], "engaged wins over out of frame")
    }

    /// Zoomed out past the point a page is worth drawing, no card wants one — so nothing runs, budget
    /// or no budget.
    func testACardThatDoesNotWantAPageNeverGetsOne() {
        let cards = (0..<3).map { card("\($0)", distance: 0, wants: false) }
        XCTAssertTrue(CanvasPageBudget.live(among: cards).isEmpty)
    }

    /// Two cards the same distance from the middle must not swap places on every scroll — each swap
    /// would be a renderer killed and a renderer started.
    func testTheAnswerIsStableWhenTwoCardsTie() {
        let tied = (0..<10).map { card("card\($0)", distance: 500) }
        let once = CanvasPageBudget.live(among: tied)
        XCTAssertEqual(once, CanvasPageBudget.live(among: tied.reversed()))
        XCTAssertEqual(once.count, CanvasPageBudget.livePages)
    }
}
