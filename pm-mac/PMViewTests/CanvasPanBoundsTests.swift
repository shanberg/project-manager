import XCTest

/// How far a board may be pushed around inside its window — `CanvasPanBounds`. The frame is the cards
/// plus `room` a side, and the scroll view's own edge is the limit, so these are about the frame.
@MainActor
final class CanvasPanBoundsTests: XCTestCase {
    private let window = CGSize(width: 1200, height: 800)
    private let cards = CGRect(x: 1600, y: 1600, width: 900, height: 700)

    /// The frame `CanvasBoardView.recomputeContent` makes, and the furthest the window's origin goes
    /// each way inside it.
    private func frame(visible: CGSize, scale: CGFloat = 1) -> CGRect {
        let room = CanvasPanBounds.room(visible: visible, scale: scale, cards: cards.size)
        return cards.insetBy(dx: -room.width, dy: -room.height)
    }

    func testAtTheLeadingEdgeKeepIsStillShowing() {
        let frame = frame(visible: window)
        // The window as far left as the frame allows: its right edge is `keep` into the cards.
        XCTAssertEqual(frame.minX + window.width - cards.minX, CanvasPanBounds.keep)
        XCTAssertEqual(frame.minY + window.height - cards.minY, CanvasPanBounds.keep)
    }

    func testAtTheTrailingEdgeKeepIsStillShowing() {
        let frame = frame(visible: window)
        // As far right: the window's left edge is `keep` short of the cards' right edge.
        XCTAssertEqual(cards.maxX - (frame.maxX - window.width), CanvasPanBounds.keep)
        XCTAssertEqual(cards.maxY - (frame.maxY - window.height), CanvasPanBounds.keep)
    }

    /// The whole point of the room: a board smaller than the window can still be pushed aside.
    func testABoardThatFitsCanStillBePanned() {
        let frame = frame(visible: CGSize(width: 4000, height: 3000))
        XCTAssertGreaterThan(frame.width, 4000)
        XCTAssertGreaterThan(frame.height, 3000)
    }

    /// `keep` is screen points: zoomed out to 10%, a board point is a tenth of a pixel, so 120pt on
    /// screen is 1200 of the board's. Held in board points it was 12 pixels — gone, in practice.
    func testKeepIsOnScreenAtAnyZoom() {
        let zoomedOut = CGSize(width: window.width * 10, height: window.height * 10)
        let room = CanvasPanBounds.room(visible: zoomedOut, scale: 10, cards: CGSize(width: 9000, height: 9000))
        XCTAssertEqual(zoomedOut.width - room.width, 1200)
    }

    /// A board narrower than the sliver cannot spare it: all of it stays.
    func testABoardSmallerThanTheSliverIsHeldWhole() {
        let room = CanvasPanBounds.room(visible: window, scale: 1, cards: CGSize(width: 40, height: 40))
        XCTAssertEqual(room.width, window.width - 40)
    }

    /// No window yet (a board installed before its pane is laid out): no room is no room, never less.
    func testNoWindowIsNoRoom() {
        XCTAssertEqual(CanvasPanBounds.room(visible: .zero, scale: 1, cards: cards.size), .zero)
    }
}
