import XCTest

/// How far a board may be pushed around inside its window — `CanvasPanBounds`.
@MainActor
final class CanvasPanBoundsTests: XCTestCase {

    /// A 1200×800 window over a board four screens wide, and a board that has not been sized yet.
    private let window = CGRect(x: 0, y: 0, width: 1200, height: 800)
    private let board = CGRect(x: 0, y: 0, width: 4800, height: 3200)

    private func settled(at origin: CGPoint, on held: CGRect) -> CGRect? {
        CanvasPanBounds.constrain(CGRect(origin: origin, size: window.size), holding: held)
    }

    // MARK: What panning is for

    func testAPositionInsideTheBoardIsLeftAlone() {
        XCTAssertEqual(settled(at: CGPoint(x: 300, y: 200), on: board)?.origin,
                       CGPoint(x: 300, y: 200))
    }

    /// The whole point of the override: a board smaller than the window can still be pushed aside.
    func testABoardThatFitsCanStillBePannedAway() {
        let small = CGRect(x: 0, y: 0, width: 600, height: 400)
        XCTAssertEqual(settled(at: CGPoint(x: 200, y: 0), on: small)?.origin.x, 200)
    }

    func testYouCannotPushTheBoardCompletelyOutOfTheWindow() {
        // Far enough right that the board would be off the left edge entirely.
        let settled = settled(at: CGPoint(x: 9000, y: 0), on: board)
        // `keep` of the board is still in the window: the window's left edge stops that far in from
        // the board's right edge.
        XCTAssertEqual(settled?.minX, board.maxX - CanvasPanBounds.keep)
    }

    func testNorTheOtherWay() {
        let settled = settled(at: CGPoint(x: -9000, y: 0), on: board)
        XCTAssertEqual(settled?.maxX, board.minX + CanvasPanBounds.keep)
    }

    // MARK: The board that isn't there yet

    /// The bug this was extracted for. A canvas is installed before its document is read, so the
    /// document view is briefly a point at the origin — and the old rule, asked then, permitted only
    /// origins around −`keep`: the window pinned above and left of the board, every card off the
    /// bottom-right, and a jump on the first pan when the real board arrived.
    func testAnUnsizedBoardHasNoOpinion() {
        XCTAssertNil(settled(at: .zero, on: .zero))
        XCTAssertNil(settled(at: CGPoint(x: 40, y: 40), on: CGRect(x: 0, y: 0, width: 0, height: 900)))
    }

    /// The old arithmetic, stated so the regression is named rather than implied: with a zero-sized
    /// board it answers a position outside every one the board can be seen at.
    func testTheOldRuleWouldHavePinnedAnUnsizedBoardOffScreen() {
        let empty = CGRect.zero
        let x = min(max(0, empty.minX - window.width + CanvasPanBounds.keep),
                    empty.maxX - CanvasPanBounds.keep)
        XCTAssertEqual(x, -CanvasPanBounds.keep)
    }

    /// And the near miss it shades into: a board narrower than `keep` cannot spare `keep`.
    func testABoardSmallerThanTheSliverIsStillReachable() {
        let sliver = CGRect(x: 0, y: 0, width: 40, height: 40)
        let settled = settled(at: .zero, on: sliver)
        XCTAssertEqual(settled?.origin, .zero, "The board is at the window's origin and visible there.")
    }

    // MARK: Which rectangle is held

    /// The board's frame is its cards grown by `CanvasBoardView.margin` — 1600pt a side — and the two
    /// rules that follow are not close to each other. Held against the frame you may sit a whole
    /// window away from the last card and still be "on the board"; held against the cards you may not.
    /// `CanvasClipView.held` is the one line that chooses, and this is the difference it makes.
    func testHoldingTheFrameLetsYouLoseEveryCard() {
        let cards = CGRect(x: 1600, y: 1600, width: 900, height: 700)
        let frame = cards.insetBy(dx: -1600, dy: -1600)
        // As far up and left as each rule permits — the board pushed as far the other way as it goes.
        let onFrame = settled(at: CGPoint(x: -9000, y: -9000), on: frame)!
        let onCards = settled(at: CGPoint(x: -9000, y: -9000), on: cards)!

        XCTAssertLessThan(onFrame.minX, onCards.minX,
                          "The frame rule permits the further travel — that is the bug.")
        XCTAssertFalse(onFrame.intersects(cards),
                       "Held by the frame, every card is off screen and nothing says which way back.")
        XCTAssertTrue(onCards.intersects(cards), "Held by the cards, a card is always on screen.")
    }

    /// And it costs none of the room it was protecting: a sliver of card at one edge leaves the rest
    /// of the window — most of a screenful — empty to spread into.
    func testHoldingTheCardsStillLeavesRoomToThink() {
        let cards = CGRect(x: 1600, y: 1600, width: 900, height: 700)
        let onCards = settled(at: CGPoint(x: -9000, y: 0), on: cards)!.origin.x
        XCTAssertEqual(cards.minX - onCards, window.width - CanvasPanBounds.keep)
    }
}
