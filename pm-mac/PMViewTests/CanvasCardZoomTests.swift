import XCTest
import PmLib
@testable import PMViewTests

/// A card's own zoom: the ladder ⌘+ walks, and what it writes into the file.
final class CanvasCardZoomTests: XCTestCase {

    private func card(_ extra: [String: JSONValue] = [:]) -> CanvasNode {
        CanvasNode(content: .link(url: "https://example.com"),
                   frame: CanvasRect(x: 0, y: 0, width: 400, height: 300),
                   extra: extra)
    }

    func testACardNobodyZoomedIsAtOneHundredPercent() {
        XCTAssertEqual(CanvasCardZoom.of(card()), 1)
    }

    /// Back at 100% the key goes, so a card you zoomed and unzoomed leaves the file as it found it.
    func testReturningToNormalTakesTheKeyOutOfTheFile() {
        var node = card()
        CanvasCardZoom.set(1.5, on: &node)
        XCTAssertNotNil(node.extra[CanvasCardZoom.key])
        CanvasCardZoom.set(1, on: &node)
        XCTAssertNil(node.extra[CanvasCardZoom.key], "not written as the default")
        XCTAssertEqual(node.extra.count, 0)
    }

    /// Somebody else's keys are none of PM's business, which is the whole bargain `extra` makes.
    func testZoomingLeavesEveryOtherKeyAlone() {
        var node = card(["styleAttributes": .object(["shape": .string("pill")])])
        CanvasCardZoom.set(2, on: &node)
        XCTAssertEqual(node.extra["styleAttributes"], .object(["shape": .string("pill")]))
    }

    func testTheLadderStepsToTheNextStopInEachDirection() {
        XCTAssertEqual(CanvasCardZoom.stepped(1, by: 1), 1.1)
        XCTAssertEqual(CanvasCardZoom.stepped(1, by: -1), 0.9)
    }

    /// A card that arrived at some number from somewhere else joins the ladder rather than walking a
    /// private sequence of its own.
    func testAnOffLadderZoomLandsOnTheNextStop() {
        XCTAssertEqual(CanvasCardZoom.stepped(1.37, by: 1), 1.5)
        XCTAssertEqual(CanvasCardZoom.stepped(1.37, by: -1), 1.25)
    }

    /// The ends are ends: ⌘+ at the top does nothing rather than growing forever.
    func testTheLadderHasEnds() {
        XCTAssertEqual(CanvasCardZoom.stepped(3, by: 1), 3)
        XCTAssertEqual(CanvasCardZoom.stepped(0.5, by: -1), 0.5)
    }

    /// The number came out of a file somebody else may have written.
    func testAnAbsurdZoomInTheFileIsClamped() {
        XCTAssertEqual(CanvasCardZoom.of(card([CanvasCardZoom.key: .number(400)])), 3)
        XCTAssertEqual(CanvasCardZoom.of(card([CanvasCardZoom.key: .number(-1)])), 0.5)
        XCTAssertEqual(CanvasCardZoom.of(card([CanvasCardZoom.key: .string("big")])), 1,
                       "a key of the wrong type is a key that says nothing")
    }
}
