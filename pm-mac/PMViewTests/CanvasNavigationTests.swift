import XCTest
import PmLib
@testable import PMViewTests

/// Moving the selection by direction — the navigation half of treating a board as a window manager.
@MainActor
final class CanvasNavigationTests: XCTestCase {
    /// A 3×3 board of cards on a 300pt pitch, named by column and row.
    private let cards: [(id: String, frame: CanvasRect)] = {
        var out: [(id: String, frame: CanvasRect)] = []
        for row in 0..<3 {
            for column in 0..<3 {
                out.append(("\(column)\(row)", CanvasRect(x: Double(column) * 300,
                                                          y: Double(row) * 300,
                                                          width: 200, height: 150)))
            }
        }
        return out
    }()

    private func frame(_ id: String) -> CanvasRect {
        cards.first { $0.id == id }!.frame
    }

    private func step(_ from: String, _ direction: CanvasNavigation.Direction) -> String? {
        CanvasNavigation.next(from: frame(from), direction: direction,
                              among: cards.filter { $0.id != from })
    }

    func testTheObviousNeighbourWins() {
        XCTAssertEqual(step("11", .left), "01")
        XCTAssertEqual(step("11", .right), "21")
        XCTAssertEqual(step("11", .up), "10")
        XCTAssertEqual(step("11", .down), "12")
    }

    func testTheEdgeOfTheBoardHasNothingBeyondIt() {
        XCTAssertNil(step("00", .left))
        XCTAssertNil(step("00", .up))
        XCTAssertNil(step("22", .right))
        XCTAssertNil(step("22", .down))
    }

    /// The off-axis penalty is what makes this feel like a direction rather than a nearest-card search:
    /// a card slightly nearer but well off to the side must not win over the one straight ahead.
    func testStraightAheadBeatsNearerButOffToTheSide() {
        let ahead = ("ahead", CanvasRect(x: 400, y: 0, width: 100, height: 100))
        let aside = ("aside", CanvasRect(x: 200, y: 600, width: 100, height: 100))
        let here = CanvasRect(x: 0, y: 0, width: 100, height: 100)
        XCTAssertEqual(CanvasNavigation.next(from: here, direction: .right, among: [ahead, aside]),
                       "ahead")
    }

    /// A card level with this one is a neighbour in the *other* axis. Stepping onto it would make the
    /// same key land somewhere different from one press to the next, depending on rounding.
    func testACardLevelWithThisOneIsNotAheadOfIt() {
        let level = ("level", CanvasRect(x: 0, y: 0, width: 100, height: 100))
        let here = CanvasRect(x: 0, y: 0, width: 100, height: 100)
        XCTAssertNil(CanvasNavigation.next(from: here, direction: .right, among: [level]))
    }
}
