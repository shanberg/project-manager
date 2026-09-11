import XCTest
@testable import PMViewTests

/// Which board runs a card's page when two tabs are showing the card.
///
/// Every tab is a board of its own, so the canvas and a workspace each hold a view of the same web
/// card. These are the rules for which of them has the page — the part that, got wrong, either loses
/// the page you were using or has two tabs passing it back and forth.
@MainActor
final class CanvasPageHandoverTests: XCTestCase {
    /// The complaint: a page scrolled, signed in to or half filled in on the canvas, and a fresh copy
    /// of it in the workspace's tile.
    func testTheTabYouSwitchToTakesThePageFromTheOneYouLeft() {
        XCTAssertEqual(CanvasPageHandover.decide(inSight: true, holder: .outOfSight), .adopt)
    }

    /// Two windows on one project. Taking the page would empty a card in front of you.
    func testAPageSomebodyCanSeeIsNotTaken() {
        XCTAssertEqual(CanvasPageHandover.decide(inSight: true, holder: .inSight), .start)
    }

    func testACardNobodyElseIsRunningStartsItsOwn() {
        XCTAssertEqual(CanvasPageHandover.decide(inSight: true, holder: nil), .start)
    }

    /// The tab behind never takes the page back — or the two would trade it on every budget pass — and
    /// never builds one of its own, which would be a renderer nobody can see.
    func testATabBehindAnotherLeavesThePageAlone() {
        XCTAssertEqual(CanvasPageHandover.decide(inSight: false, holder: .inSight), .wait)
        XCTAssertEqual(CanvasPageHandover.decide(inSight: false, holder: .outOfSight), .wait)
        XCTAssertEqual(CanvasPageHandover.decide(inSight: false, holder: nil), .wait)
    }

    /// Where a paused page had got to belongs to the card, so whichever board wakes it finds it.
    func testAPausedPageResumesOnWhicheverBoardWakesIt() {
        let canvas = URL(fileURLWithPath: "/tmp/Board.canvas")
        let key = CanvasPageHandover.key(canvas: canvas, card: "c1")
        defer { CanvasPageHandover.resumes[key] = nil }
        CanvasPageHandover.resumes[key] = .init(state: "session",
                                                url: URL(string: "https://example.com/deep"))

        let sameCard = CanvasPageHandover.key(canvas: URL(fileURLWithPath: "/tmp/./Board.canvas"),
                                              card: "c1")
        XCTAssertEqual(CanvasPageHandover.resumes[sameCard]?.url?.path, "/deep")
        XCTAssertNil(CanvasPageHandover.resumes[CanvasPageHandover.key(canvas: canvas, card: "c2")],
                     "another card on the same board is another page")
    }
}
