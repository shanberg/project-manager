import XCTest
@testable import PmLib

/// The lines between cards: which sides they use, and the shape they take.
final class CanvasRoutingTests: XCTestCase {

    private func rect(_ x: Double, _ y: Double, _ w: Double = 100, _ h: Double = 100) -> CanvasRect {
        CanvasRect(x: x, y: y, width: w, height: h)
    }

    // MARK: Choosing sides

    func testCardsSideBySideJoinAcross() {
        XCTAssertEqual(canvasPreferredSides(from: rect(0, 0), to: rect(400, 0)).0, .right)
        XCTAssertEqual(canvasPreferredSides(from: rect(0, 0), to: rect(400, 0)).1, .left)
        XCTAssertEqual(canvasPreferredSides(from: rect(400, 0), to: rect(0, 0)).0, .left)
    }

    func testCardsStackedJoinTopToBottom() {
        XCTAssertEqual(canvasPreferredSides(from: rect(0, 0), to: rect(0, 400)).0, .bottom)
        XCTAssertEqual(canvasPreferredSides(from: rect(0, 0), to: rect(0, 400)).1, .top)
        XCTAssertEqual(canvasPreferredSides(from: rect(0, 400), to: rect(0, 0)).0, .top)
    }

    /// The reason the axis is chosen on the gap rather than the centres. This wide card sits directly
    /// above the narrow one: their centres are 30pt apart horizontally and 400 apart vertically, but a
    /// centre-distance rule that compares |dx| to |dy| gets this right for the wrong reason — make the
    /// cards overlap horizontally and only the gap tells the truth.
    func testAWideCardAboveANarrowOneLeavesFromItsBottom() {
        let wide = rect(0, 0, 900, 100)
        let narrow = rect(430, 400, 120, 100)
        XCTAssertEqual(canvasPreferredSides(from: wide, to: narrow).0, .bottom)
        XCTAssertEqual(canvasPreferredSides(from: wide, to: narrow).1, .top)
    }

    // MARK: The curve

    func testTheCurveLeavesAndArrivesOnTheNamedSides() {
        let curve = canvasRoute(from: rect(0, 0), fromSide: .right, to: rect(400, 0), toSide: .left)
        XCTAssertEqual(curve.start, CanvasPoint(x: 100, y: 50))
        XCTAssertEqual(curve.end, CanvasPoint(x: 400, y: 50))
        XCTAssertEqual(curve.startSide, .right)
        XCTAssertEqual(curve.endSide, .left)
    }

    /// Perpendicular departure is what makes a canvas line look like one. Both control points sit
    /// straight out along their side's normal, so the tangent at each end is square to the card.
    func testItLeavesSquareToTheCard() {
        let curve = canvasRoute(from: rect(0, 0), fromSide: .right, to: rect(0, 600), toSide: .top)
        XCTAssertEqual(curve.control1.y, curve.start.y, accuracy: 0.0001, "leaves horizontally")
        XCTAssertGreaterThan(curve.control1.x, curve.start.x)
        XCTAssertEqual(curve.control2.x, curve.end.x, accuracy: 0.0001, "arrives vertically")
        XCTAssertLessThan(curve.control2.y, curve.end.y, "approaches the top edge from above")

        let out = curve.direction(at: 0)
        XCTAssertEqual(out.x, 1, accuracy: 0.001)
        XCTAssertEqual(out.y, 0, accuracy: 0.001)
    }

    /// A long line bows more than a short one, but neither runs away: the floor keeps two touching
    /// cards from getting a kink, and the ceiling keeps a line across a large board from swinging out
    /// into the middle of it.
    func testTheBowGrowsWithTheSpanButIsBounded() {
        func reach(_ span: Double) -> Double {
            let c = canvasRoute(from: rect(0, 0), fromSide: .right, to: rect(100 + span, 0), toSide: .left)
            return c.control1.x - c.start.x
        }
        XCTAssertEqual(reach(0), 40, accuracy: 0.001, "the floor")
        XCTAssertLessThan(reach(200), reach(600))
        XCTAssertEqual(reach(10_000), 300, accuracy: 0.001, "the ceiling")
    }

    func testSidesAreChosenWhenTheEdgeDoesntNameThem() {
        let curve = canvasRoute(from: rect(0, 0), fromSide: nil, to: rect(0, 500), toSide: nil)
        XCTAssertEqual(curve.startSide, .bottom)
        XCTAssertEqual(curve.endSide, .top)
        XCTAssertEqual(curve.start, CanvasPoint(x: 50, y: 100))
    }

    /// A side the edge *does* name is used even when it's the awkward one — the file said so, and a
    /// canvas people hand-route would be silently rearranged otherwise.
    func testANamedSideIsObeyedEvenWhenItIsTheLongWayRound() {
        let curve = canvasRoute(from: rect(0, 0), fromSide: .left, to: rect(400, 0), toSide: .right)
        XCTAssertEqual(curve.start, CanvasPoint(x: 0, y: 50))
        XCTAssertEqual(curve.end, CanvasPoint(x: 500, y: 50))
        XCTAssertLessThan(curve.control1.x, curve.start.x, "still leaves outward")
    }

    func testThePointAtTheEndsIsTheEnds() {
        let curve = canvasRoute(from: rect(0, 0), fromSide: .right, to: rect(400, 200), toSide: .left)
        XCTAssertEqual(curve.point(at: 0), curve.start)
        XCTAssertEqual(curve.point(at: 1), curve.end)
        let mid = curve.point(at: 0.5)
        XCTAssertGreaterThan(mid.x, curve.start.x)
        XCTAssertLessThan(mid.x, curve.end.x)
    }

    /// The hull of the four points really does contain the curve, which is what makes it safe to skip
    /// drawing a line whose bounds are off screen.
    func testBoundsContainEveryPointOnTheCurve() {
        let curve = canvasRoute(from: rect(0, 0), fromSide: .top, to: rect(600, 900), toSide: .left)
        let box = curve.bounds
        for step in 0...100 {
            let p = curve.point(at: Double(step) / 100)
            XCTAssertTrue(box.contains(x: p.x, y: p.y), "t=\(Double(step) / 100) escaped the bounds")
        }
    }

    func testADirectionIsAlwaysAUsableVector() {
        // Both cards in the same place, both control points on their anchors: the derivative vanishes.
        let curve = canvasRoute(from: rect(0, 0), fromSide: .right, to: rect(0, 0), toSide: .right)
        let d = curve.direction(at: 0.5)
        XCTAssertEqual((d.x * d.x + d.y * d.y).squareRoot(), 1, accuracy: 0.001)
    }

    // MARK: Against a document

    func testRoutingAnEdgeInADocument() throws {
        let doc = CanvasDocument(
            nodes: [CanvasNode(id: "a", content: .text("a"), frame: rect(0, 0)),
                    CanvasNode(id: "b", content: .text("b"), frame: rect(400, 0))],
            edges: [CanvasEdge(id: "e", fromNode: "a", fromSide: .right, toNode: "b", toSide: .left)])
        let curve = try XCTUnwrap(canvasRoute(for: doc.edges[0], in: doc))
        XCTAssertEqual(curve.start, CanvasPoint(x: 100, y: 50))
    }

    /// An edge naming a card that isn't there is drawn as nothing, not as a crash — a hand-edited or
    /// merged canvas can hold one, and the edge is still written back untouched.
    func testADanglingEdgeSimplyIsntDrawn() {
        let doc = CanvasDocument(nodes: [CanvasNode(id: "a", content: .text("a"), frame: rect(0, 0))],
                                 edges: [CanvasEdge(id: "e", fromNode: "a", toNode: "gone")])
        XCTAssertNil(canvasRoute(for: doc.edges[0], in: doc))
    }
}
