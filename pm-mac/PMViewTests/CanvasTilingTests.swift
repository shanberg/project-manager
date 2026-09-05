import XCTest
import PmLib
@testable import PMViewTests

/// The geometry a tiled view is made of, and the order it puts cards in.
///
/// Worth testing without a board because it is the part that is easy to get subtly wrong and hard to
/// see: a grid that ignores the shape of the window it is filling produces letterboxed tiles, and an
/// order that ignores where the cards were produces an arrangement that has thrown away the one thing
/// the board knew.
@MainActor
final class CanvasTilingTests: XCTestCase {
    private let wide = CanvasRect(x: 0, y: 0, width: 1200, height: 600)
    private let tall = CanvasRect(x: 0, y: 0, width: 600, height: 1200)

    private func card(_ id: String, _ x: Double, _ y: Double,
                      _ w: Double = 200, _ h: Double = 150) -> (id: String, frame: CanvasRect) {
        (id, CanvasRect(x: x, y: y, width: w, height: h))
    }

    // MARK: Order

    /// Reading order of where the cards actually sit — rows top to bottom, each left to right. This is
    /// what makes it a canvas's tiling rather than a generic one.
    func testCardsTileInTheReadingOrderOfTheBoard() {
        let cards = [card("br", 400, 400), card("tl", 0, 0), card("tr", 400, 0), card("bl", 0, 400)]
        XCTAssertEqual(CanvasTiling.order(cards), ["tl", "tr", "bl", "br"])
    }

    /// A row is a band as tall as the median card, not a fixed number — a board of 400pt dashboard
    /// tiles and a board of 60pt stickies disagree about "the same row" by an order of magnitude.
    func testCardsRoughlyLevelCountAsOneRow() {
        let cards = [card("b", 0, 30), card("a", 300, 0)]
        XCTAssertEqual(CanvasTiling.order(cards), ["b", "a"],
                       "30 points apart on a 150pt card is one row, so they sort by x")
    }

    func testCardsWellApartAreSeparateRows() {
        let cards = [card("lower", 0, 900), card("upper", 300, 0)]
        XCTAssertEqual(CanvasTiling.order(cards), ["upper", "lower"])
    }

    // MARK: Grid

    /// The column count follows the area's proportions rather than being ceil(sqrt(n)): six tiles in a
    /// wide window want three across, and the same six in a tall one want two.
    func testTheGridFollowsTheShapeOfTheWindow() {
        let across = Set(CanvasTiling.grid(count: 6, in: wide).map(\.minX)).count
        let down = Set(CanvasTiling.grid(count: 6, in: tall).map(\.minX)).count
        XCTAssertEqual(across, 3)
        XCTAssertEqual(down, 2)
    }

    func testTilesStayInsideTheAreaAndDoNotOverlap() {
        let tiles = CanvasTiling.grid(count: 7, in: wide)
        for tile in tiles {
            XCTAssertGreaterThanOrEqual(tile.minX, wide.minX - 0.5)
            XCTAssertLessThanOrEqual(tile.maxX, wide.maxX + 0.5)
            XCTAssertGreaterThanOrEqual(tile.minY, wide.minY - 0.5)
            XCTAssertLessThanOrEqual(tile.maxY, wide.maxY + 0.5)
        }
        for (a, b) in pairs(tiles) {
            XCTAssertFalse(a.inset(by: -1).intersects(b.inset(by: -1)), "tiles must not overlap")
        }
    }

    /// A grid whose last row is short leaves a gap. Pushed to the left it reads as a mistake; centred
    /// it reads as the end of a list.
    ///
    /// The *row* is centred, not the last tile — those are only the same thing when the row holds one.
    /// Asserting the tile was the first version of this test and it was wrong about the feature.
    func testAShortLastRowIsCentred() {
        for count in [5, 7, 10] {
            let tiles = CanvasTiling.grid(count: count, in: wide)
            let lastRowY = tiles.last!.minY
            let lastRow = tiles.filter { abs($0.minY - lastRowY) < 0.5 }
            guard lastRow.count < tiles.filter({ abs($0.minY - tiles[0].minY) < 0.5 }).count else {
                continue  // a full last row has nothing to centre
            }
            let span = (lastRow.first!.minX + lastRow.last!.maxX) / 2
            XCTAssertEqual(span, wide.midX, accuracy: 0.5, "\(count) tiles")
        }
    }

    // MARK: Master and stack

    func testTheMasterTakesItsShareAndTheStackTakesTheRest() {
        let tiles = CanvasTiling.masterStack(count: 4, in: wide, fraction: 0.6)
        XCTAssertEqual(tiles[0].height, wide.height, accuracy: 0.5, "the master is full height")
        XCTAssertEqual(tiles[0].width, (wide.width - CanvasTiling.gap) * 0.6, accuracy: 0.5)
        for tile in tiles.dropFirst() {
            XCTAssertEqual(tile.maxX, wide.maxX, accuracy: 0.5, "the stack is flush to the trailing edge")
        }
        for (a, b) in pairs(tiles) {
            XCTAssertFalse(a.inset(by: -1).intersects(b.inset(by: -1)))
        }
    }

    /// A fraction dragged past either end is clamped rather than producing a tile with no width — the
    /// divider can be thrown at the window's edge and the arrangement has to survive it.
    func testTheSplitIsClamped() {
        for fraction in [-2.0, 0.0, 1.0, 5.0] {
            let tiles = CanvasTiling.masterStack(count: 3, in: wide, fraction: fraction)
            for tile in tiles { XCTAssertGreaterThan(tile.width, 1, "fraction \(fraction)") }
        }
    }

    // MARK: One card

    /// ⌘Return with one card selected is "fill the window with this", which is the same command and
    /// has to produce one tile filling the area whichever arrangement is up.
    func testOneCardFillsTheWindow() {
        for arrangement in CanvasTiling.Arrangement.allCases {
            let tiles = CanvasTiling.frames(arrangement, count: 1, in: wide, masterFraction: 0.62)
            XCTAssertEqual(tiles.count, 1)
            XCTAssertLessThan(tiles[0].width, wide.width, "inset from the edges")
            XCTAssertGreaterThan(tiles[0].width, wide.width - 4 * CanvasTiling.gap)
        }
    }

    private func pairs(_ tiles: [CanvasRect]) -> [(CanvasRect, CanvasRect)] {
        var out: [(CanvasRect, CanvasRect)] = []
        for i in tiles.indices { for j in tiles.indices where j > i { out.append((tiles[i], tiles[j])) } }
        return out
    }
}
