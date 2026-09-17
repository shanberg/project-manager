import XCTest
import PmLib
@testable import PMViewTests

/// Size ▸ (backlog 27): a proportion keeps the width and the top-left; an exact size keeps the top-left.
final class CanvasCardSizeTests: XCTestCase {

    private func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> CanvasRect {
        CanvasRect(x: x, y: y, width: w, height: h)
    }
    private func ratio(_ title: String) throws -> CanvasCardSize.Ratio {
        try XCTUnwrap(CanvasCardSize.ratios.first { $0.title == title })
    }

    func testARatioKeepsTheWidthAndTheTopLeft() throws {
        XCTAssertEqual(CanvasCardSize.frame(rect(30, 40, 320, 500), at: try ratio("16:9")), rect(30, 40, 320, 180))
        XCTAssertEqual(CanvasCardSize.frame(rect(0, 0, 250, 100), at: try ratio("5:7")), rect(0, 0, 250, 350))
        XCTAssertEqual(CanvasCardSize.frame(rect(0, 0, 110, 100), at: try ratio("11:19")), rect(0, 0, 110, 190))
    }

    func testANarrowCardIsWidenedRatherThanFlattenedUnderTheFloor() throws {
        XCTAssertEqual(CanvasCardSize.frame(rect(0, 0, 50, 300), at: try ratio("16:9")), rect(0, 0, 71, 40))
    }

    func testAnExactSizeLeavesABlankAxisAlone() {
        XCTAssertEqual(CanvasCardSize.frame(rect(5, 5, 200, 300), width: 400, height: nil), rect(5, 5, 400, 300))
        XCTAssertEqual(CanvasCardSize.frame(rect(5, 5, 200, 300), width: 10, height: 120.4), rect(5, 5, 40, 120))
    }

    func testEachSelectedCardIsSetFromItsOwnWidthAndUnchangedOnesAreLeftOut() throws {
        let doc = CanvasDocument(nodes: [
            CanvasNode(id: "a", content: .text("a"), frame: rect(0, 0, 100, 50)),
            CanvasNode(id: "b", content: .text("b"), frame: rect(200, 0, 300, 300)),
            CanvasNode(id: "c", content: .text("c"), frame: rect(600, 0, 90, 10)),
        ])
        let square = try ratio("1:1")
        let plan = CanvasCardSize.plan(["a", "b"], in: doc) { CanvasCardSize.frame($0, at: square) }
        XCTAssertEqual(plan, ["a": rect(0, 0, 100, 100)])
    }

    func testTheTickNeedsEveryCardAtTheRatio() throws {
        let wide = try ratio("16:9")
        XCTAssertTrue(CanvasCardSize.all([rect(0, 0, 320, 180), rect(0, 0, 100, 56)], at: wide))
        XCTAssertFalse(CanvasCardSize.all([rect(0, 0, 320, 180), rect(0, 0, 100, 100)], at: wide))
        XCTAssertFalse(CanvasCardSize.all([], at: wide))
    }
}
