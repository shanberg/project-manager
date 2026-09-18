import XCTest
@testable import PMViewTests

/// Where a dragged task lands (docs/sessions.md D1): a reorder within its sitting, a pick-up onto the
/// current one, and a move only with ⌥.
final class TaskDropResolverTests: XCTestCase {

    /// Today's sitting (0) with two rows, and an older one (1) with three, 20pt a row and a 20pt caption
    /// band between them.
    private let rows = [
        RowFrame(key: "0:0", session: 0, line: 0, depth: 0, minY: 20, maxY: 40),
        RowFrame(key: "0:1", session: 0, line: 1, depth: 0, minY: 40, maxY: 60),
        RowFrame(key: "1:0", session: 1, line: 0, depth: 0, minY: 80, maxY: 100),
        RowFrame(key: "1:1", session: 1, line: 1, depth: 0, minY: 100, maxY: 120),
        RowFrame(key: "1:2", session: 1, line: 2, depth: 0, minY: 120, maxY: 140),
    ]
    private let today = SessionFrame(index: 0, minY: 0, maxY: 60)

    private func drop(at y: CGFloat, dragging key: String, from source: Int?,
                      current: SessionFrame? = nil, moving: Bool = false) -> DropTarget? {
        TaskDropResolver.resolve(pointer: CGPoint(x: 20, y: y), rows: rows, sessionFrames: [],
                                 draggedSubtree: [key], contentInset: 20, indentStep: 16,
                                 from: source, pickingUpInto: current, moving: moving)
    }

    func testAnOldTaskDroppedAnywhereOnTodaysSittingIsPickedUpAndLightsItWhole() {
        for y: CGFloat in [5, 30, 50] {
            let target = drop(at: y, dragging: "1:2", from: 1, current: today)
            XCTAssertEqual(target?.destination, .pickUp(into: 0), "at \(y)")
            XCTAssertEqual(target?.lit, today)
        }
    }

    func testWithOptionTheSameDropMovesTheLine() {
        let target = drop(at: 45, dragging: "1:2", from: 1, current: today, moving: true)
        XCTAssertEqual(target?.destination, .beside(session: 0, line: 1, after: false))
        XCTAssertNil(target?.lit)
    }

    /// A reorder within the sitting it was written in is still a reorder.
    func testWithinItsOwnSittingATaskReorders() {
        let target = drop(at: 135, dragging: "1:0", from: 1, current: today)
        XCTAssertEqual(target?.destination, .beside(session: 1, line: 2, after: true))
    }

    /// Today's own tasks reorder inside today, lit block or not: there is nothing to pick up.
    func testTodaysOwnTaskReordersInsideToday() {
        let target = drop(at: 55, dragging: "0:0", from: 0, current: today)
        XCTAssertEqual(target?.destination, .beside(session: 0, line: 1, after: true))
        XCTAssertNil(target?.lit)
    }

    /// Dropping into an older sitting would rewrite it, and a move needs ⌥ — so there is nowhere to land.
    func testWithoutOptionThereIsNoSlotInAnotherSitting() {
        XCTAssertNil(drop(at: 110, dragging: "0:1", from: 0, current: today))
        XCTAssertEqual(drop(at: 110, dragging: "0:1", from: 0, current: today, moving: true)?.session, 1)
    }

    /// No current sitting on offer — the project has gone cold, or everything dragged is already there
    /// — and today is just another sitting the task wasn't written in.
    func testWithNothingToPickUpIntoTodayIsNoTarget() {
        XCTAssertNil(drop(at: 30, dragging: "1:2", from: 1))
    }

    /// Without a source the resolver is the plain geometry every list had before sittings were kept apart.
    func testWithoutASourceADropMovesAnywhere() {
        XCTAssertEqual(drop(at: 110, dragging: "0:1", from: nil)?.session, 1)
    }

    // MARK: The geometry

    /// The band between two sittings is two slots: the end of the one above, the start of the one below.
    func testTheBandBetweenSittingsSplitsIntoTwoSlots() {
        XCTAssertEqual(drop(at: 65, dragging: "1:2", from: nil)?.destination,
                       .beside(session: 0, line: 1, after: true))
        XCTAssertEqual(drop(at: 75, dragging: "1:2", from: nil)?.destination,
                       .beside(session: 1, line: 0, after: false))
    }

    /// Dragging rightward over the row above makes the task its child.
    func testDraggingRightNestsUnderTheRowAbove() {
        let target = TaskDropResolver.resolve(pointer: CGPoint(x: 36, y: 115), rows: rows, sessionFrames: [],
                                              draggedSubtree: ["1:2"], contentInset: 20, indentStep: 16)
        XCTAssertEqual(target?.depth, 1)
        XCTAssertEqual(target?.destination, .beside(session: 1, line: 1, after: true))
    }
}
