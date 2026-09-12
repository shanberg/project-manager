import XCTest
@testable import PMViewTests

/// Where a wandered card comes back to, and when it stops being wandered.
///
/// The cases that matter are the two erasures. A card put back on its own address must *lose* its row,
/// or the next launch would undo Home; and a card pointed somewhere else must lose it too, or it would
/// open at a page belonging to an address it no longer has.
final class CanvasPageVisitsTests: XCTestCase {

    private let card = "/Users/x/Vault/Work/docs/Board.canvas#n17"

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "PMCanvasPageVisits")
        super.tearDown()
    }

    func testACardThatHasNotWanderedHasNoRow() {
        XCTAssertNil(CanvasPageVisits.of(card))
    }

    func testWhereACardWentSurvivesBeingWrittenDown() {
        CanvasPageVisits.remember(URL(string: "https://x.dev/docs/api")!, for: card)
        XCTAssertEqual(CanvasPageVisits.of(card)?.absoluteString, "https://x.dev/docs/api")
    }

    func testTheLatestPlaceWins() {
        CanvasPageVisits.remember(URL(string: "https://x.dev/one")!, for: card)
        CanvasPageVisits.remember(URL(string: "https://x.dev/two")!, for: card)
        XCTAssertEqual(CanvasPageVisits.of(card)?.absoluteString, "https://x.dev/two")
    }

    func testForgettingLeavesNothingBehind() {
        CanvasPageVisits.remember(URL(string: "https://x.dev/one")!, for: card)
        CanvasPageVisits.forget(card)
        XCTAssertNil(CanvasPageVisits.of(card))
    }

    /// One card on one board. The same card id on another board is a different card, because the two
    /// boards are two documents that happen to have been copied from each other.
    func testTheBoardIsPartOfTheKey() {
        CanvasPageVisits.remember(URL(string: "https://x.dev/one")!, for: card)
        XCTAssertNil(CanvasPageVisits.of("/Users/x/Vault/Other/docs/Board.canvas#n17"))
    }

    /// A store with no ceiling is a defaults key that grows for as long as the app is installed.
    func testTheOldestRowsGoWhenThereAreTooMany() {
        for index in 0...CanvasPageVisits.capacity {
            CanvasPageVisits.remember(URL(string: "https://x.dev/\(index)")!, for: "board#\(index)")
        }
        XCTAssertNil(CanvasPageVisits.of("board#0"), "the first one written is the first one dropped")
        XCTAssertNotNil(CanvasPageVisits.of("board#\(CanvasPageVisits.capacity)"))
    }
}
