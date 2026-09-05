import XCTest
import PmLib
@testable import PMViewTests

/// Snapping a drag and a resize to the cards already on the board.
///
/// Every case here is one the eye would catch on a real board and the arithmetic would otherwise get
/// almost right: a column of cards whose left edges are within two points of each other, a row where
/// one card is 4pt wider than its neighbours. The point of snapping is that "almost" stops happening,
/// so these assert exact values.
final class CanvasSnappingTests: XCTestCase {

    private func rect(_ x: Double, _ y: Double, _ w: Double = 200, _ h: Double = 100) -> CanvasRect {
        CanvasRect(x: x, y: y, width: w, height: h)
    }

    private let reach = 7.0

    // MARK: Moving

    func testALeftEdgeSnapsToAnotherLeftEdge() {
        let result = CanvasSnapping.move(rect(0, 500), by: (dx: 103, dy: 0),
                                         against: [rect(100, 0)], reach: reach)
        XCTAssertEqual(result.frame.minX, 100, "pulled back the 3pt onto the other card's left edge")
        XCTAssertEqual(result.frame.minY, 500)
    }

    func testCentresSnapToCentres() {
        // The other card's centre is at x=200. Moving card is 200 wide, so its centre lands there when
        // its left edge is at 100.
        let result = CanvasSnapping.move(rect(0, 500), by: (dx: 104, dy: 0),
                                         against: [rect(100, 0)], reach: reach)
        XCTAssertEqual(result.frame.midX, 200)
    }

    /// The moving card's *right* edge finding another card's *left* edge — cards butted up in a row,
    /// which the naive "compare left to left" rule never catches.
    func testARightEdgeSnapsToALeftEdge() {
        let result = CanvasSnapping.move(rect(0, 0), by: (dx: 497, dy: 0),
                                         against: [rect(700, 0)], reach: reach)
        XCTAssertEqual(result.frame.maxX, 700)
    }

    func testBothAxesSnapIndependently() {
        let result = CanvasSnapping.move(rect(0, 0), by: (dx: 98, dy: 303),
                                         against: [rect(100, 300)], reach: reach)
        XCTAssertEqual(result.frame.minX, 100)
        XCTAssertEqual(result.frame.minY, 300)
        XCTAssertEqual(result.guides.count, 2)
    }

    /// Nothing to align to, so the grid gets its say — the fallback, not the rule.
    func testTheGridCatchesWhatAlignmentDoesnt() {
        let result = CanvasSnapping.move(rect(0, 0), by: (dx: 103, dy: 0),
                                         against: [rect(4000, 4000)], reach: reach)
        XCTAssertEqual(result.frame.minX, 100, "rounded to the 10pt grid")
        XCTAssertTrue(result.guides.isEmpty, "a grid snap has nothing to point at")
    }

    /// Alignment beats the grid where both apply. Snapping to another card is a much stronger
    /// statement of intent than snapping to an invisible lattice.
    func testAlignmentWinsOverTheGrid() {
        let result = CanvasSnapping.move(rect(0, 0), by: (dx: 100, dy: 0),
                                         against: [rect(103, 0)], reach: reach)
        XCTAssertEqual(result.frame.minX, 103, "not rounded away to 100")
    }

    /// ⌥ turns the lot off, which is what makes snapping safe to have on by default.
    func testNothingSnapsWhenSnappingIsOff() {
        let result = CanvasSnapping.move(rect(0, 0), by: (dx: 103, dy: 7),
                                         against: [rect(100, 0)], reach: 0, snapsToGrid: false)
        XCTAssertEqual(result.frame.minX, 103)
        XCTAssertEqual(result.frame.minY, 7)
        XCTAssertTrue(result.guides.isEmpty)
    }

    func testTheNearestCandidateWins() {
        // Two cards in range: one 3pt away, one 1pt away.
        let result = CanvasSnapping.move(rect(0, 0), by: (dx: 100, dy: 0),
                                         against: [rect(103, 0), rect(101, 0)], reach: reach)
        XCTAssertEqual(result.frame.minX, 101)
    }

    /// The guide reaches from the card being moved to the card it agreed with, and no further. A line
    /// the width of the board would be true and useless — the point is to show *which* cards agree.
    func testAGuideSpansOnlyTheCardsItConcerns() {
        let result = CanvasSnapping.move(rect(0, 500), by: (dx: 100, dy: 0),
                                         against: [rect(100, 0), rect(100, 3000)], reach: reach)
        guard case .alignment(let axis, let position, let from, let to)? = result.guides.first else {
            return XCTFail("expected an alignment guide")
        }
        XCTAssertEqual(axis, .vertical)
        XCTAssertEqual(position, 100)
        XCTAssertEqual(from, 0, "up to the topmost card that agrees")
        XCTAssertEqual(to, 3100, "down to the bottom of the lowest one")
    }

    // MARK: Resizing

    func testAGripOnlyMovesTheEdgesItTouches() {
        let result = CanvasSnapping.resize(rect(100, 100, 200, 200), handle: .right,
                                           against: [], reach: reach, snapsToGrid: false)
        XCTAssertEqual(result.frame.minX, 100)
        XCTAssertEqual(result.frame.minY, 100)
        XCTAssertEqual(result.frame.height, 200, "a right grip doesn't touch the height")
    }

    /// The one the request was really about: dragging a card's edge until it is exactly as wide as
    /// another card, and being told that's what happened.
    func testAWidthSnapsToAnotherCardsWidth() {
        // Moving card's left edge is at 0 and it is currently 337 wide; another card is 340 wide.
        let result = CanvasSnapping.resize(rect(0, 0, 337, 100), handle: .right,
                                           against: [rect(900, 900, 340, 80)],
                                           reach: reach, snapsToGrid: false)
        XCTAssertEqual(result.frame.width, 340)

        guard case .sameSize(let axis, let moving, let matched)? = result.guides.first else {
            return XCTFail("expected a same-size guide")
        }
        XCTAssertEqual(axis, .horizontal)
        XCTAssertEqual(moving.width, 340)
        XCTAssertEqual(matched.width, 340)
    }

    func testAHeightSnapsToAnotherCardsHeight() {
        let result = CanvasSnapping.resize(rect(0, 0, 100, 456), handle: .bottom,
                                           against: [rect(900, 900, 80, 460)],
                                           reach: reach, snapsToGrid: false)
        XCTAssertEqual(result.frame.height, 460)
        guard case .sameSize(let axis, _, _)? = result.guides.first else {
            return XCTFail("expected a same-size guide")
        }
        XCTAssertEqual(axis, .vertical)
    }

    /// Dragging a *left* grip to match a width grows the card leftward — the right edge is the one
    /// staying put, so the candidate position is `right - otherWidth`.
    func testALeftGripMatchesAWidthByMovingLeftwards() {
        // 335 wide with its right edge at 435, so matching a 340-wide card means the left edge moving
        // 5pt out to 95 — the right edge is the one staying put.
        let result = CanvasSnapping.resize(rect(100, 0, 335, 100), handle: .left,
                                           against: [rect(900, 900, 340, 80)],
                                           reach: reach, snapsToGrid: false)
        XCTAssertEqual(result.frame.width, 340)
        XCTAssertEqual(result.frame.minX, 95)
        XCTAssertEqual(result.frame.maxX, 435, "the right edge didn't move")
    }

    /// A corner grip snaps both dimensions, and can take one from an alignment and the other from a
    /// size match.
    func testACornerGripSnapsBothAxes() {
        let result = CanvasSnapping.resize(rect(0, 0, 198, 337), handle: .bottomRight,
                                           against: [rect(200, 900, 100, 340)],
                                           reach: reach, snapsToGrid: false)
        XCTAssertEqual(result.frame.maxX, 200, "right edge onto the other card's left edge")
        XCTAssertEqual(result.frame.height, 340, "height matched the other card's")
        XCTAssertEqual(result.guides.count, 2)
    }

    /// Where a position is both an alignment and a size match, it is reported as the alignment — the
    /// stronger and more obvious of the two readings.
    func testAlignmentIsPreferredToSizeAtTheSameDistance() {
        // The other card's left edge is at 340, and it is 340 wide, so both candidates are at 340.
        let result = CanvasSnapping.resize(rect(0, 0, 337, 100), handle: .right,
                                           against: [rect(340, 900, 340, 80)],
                                           reach: reach, snapsToGrid: false)
        XCTAssertEqual(result.frame.maxX, 340)
        guard case .alignment? = result.guides.first else {
            return XCTFail("expected the alignment reading, not the size one")
        }
    }

    func testACardCannotBeResizedInsideOut() {
        let result = CanvasSnapping.resize(CanvasRect(x: 100, y: 100, width: 5, height: 5),
                                           handle: .right, against: [], reach: reach)
        XCTAssertGreaterThanOrEqual(result.frame.width, 40)
        XCTAssertEqual(result.frame.minX, 100)
    }

    func testTheGridStillCatchesAResizeWithNothingToMatch() {
        let result = CanvasSnapping.resize(rect(0, 0, 203, 100), handle: .right,
                                           against: [], reach: reach)
        XCTAssertEqual(result.frame.width, 200)
    }
}
