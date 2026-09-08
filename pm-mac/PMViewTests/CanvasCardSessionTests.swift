import XCTest
import PmLib
@testable import PMViewTests

/// Which browser session a card uses, and what that writes into a shared document.
final class CanvasCardSessionTests: XCTestCase {

    private func card(_ extra: [String: JSONValue] = [:]) -> CanvasNode {
        CanvasNode(content: .link(url: "https://example.com"),
                   frame: CanvasRect(x: 0, y: 0, width: 400, height: 300),
                   extra: extra)
    }

    func testACardNobodyChangedIsOnTheSharedSession() {
        XCTAssertNil(CanvasCardSession.of(card()))
    }

    func testAProfileIsKeptOnTheNode() {
        var node = card()
        CanvasCardSession.set("Work", on: &node)
        XCTAssertEqual(CanvasCardSession.of(node), "Work")
    }

    /// The `CanvasCardZoom` bargain: back at the default, the key goes rather than being written out,
    /// so a card put on a profile and taken off leaves the file as it found it.
    func testGoingBackToSharedTakesTheKeyOutOfTheFile() {
        var node = card()
        CanvasCardSession.set("Work", on: &node)
        CanvasCardSession.set(nil, on: &node)
        XCTAssertNil(node.extra[CanvasCardSession.key])
        XCTAssertEqual(node.extra.count, 0)
    }

    func testAnEmptyNameIsTheSharedSession() {
        var node = card()
        CanvasCardSession.set("   ", on: &node)
        XCTAssertNil(node.extra[CanvasCardSession.key])
        XCTAssertNil(CanvasCardSession.of(node))
    }

    func testANameIsTrimmed() {
        var node = card()
        CanvasCardSession.set("  Work  ", on: &node)
        XCTAssertEqual(node.extra[CanvasCardSession.key], .string("Work"))
    }

    /// Somebody else's keys are none of PM's business, which is the whole bargain `extra` makes.
    func testChoosingASessionLeavesEveryOtherKeyAlone() {
        var node = card(["styleAttributes": .object(["shape": .string("pill")])])
        CanvasCardSession.set("Personal", on: &node)
        XCTAssertEqual(node.extra["styleAttributes"], .object(["shape": .string("pill")]))
    }

    /// A canvas another program wrote can hold anything at all under a key PM reads.
    func testANonsenseValueReadsAsTheSharedSession() {
        XCTAssertNil(CanvasCardSession.of(card([CanvasCardSession.key: .number(4)])))
    }
}
