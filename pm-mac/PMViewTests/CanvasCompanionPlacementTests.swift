import AppKit
import XCTest

/// The session companion's corner beside its satellite. Screen coordinates, so a higher window has the
/// larger y. The screen here is 1440×876 above a 24-point menu bar's worth of nothing.
final class CanvasCompanionPlacementTests: XCTestCase {
    private typealias P = CanvasCompanionPlacement
    private let screen = NSRect(x: 0, y: 0, width: 1440, height: 876)
    private let size = NSSize(width: 300, height: 320)

    private func choose(_ window: NSRect, spot: P.Anchor? = nil) -> P.Choice {
        P.choose(spot: spot, size: size, window: window, screen: screen, header: 28)
    }

    /// A window left of centre gets the panel outside its right edge, top edges level.
    func testLeftWindowGetsOutsideTopRight() {
        let window = NSRect(x: 80, y: 400, width: 420, height: 400)
        XCTAssertEqual(choose(window), .init(anchor: .outsideTopRight, asPill: false))
        let frame = P.frame(at: .outsideTopRight, size: size, window: window, screen: screen)
        XCTAssertEqual(frame.minX, window.maxX + P.gap)
        XCTAssertEqual(frame.maxY, window.maxY)
    }

    /// A window right of centre faces the centre with its left side.
    func testRightWindowGetsOutsideTopLeft() {
        XCTAssertEqual(choose(NSRect(x: 840, y: 400, width: 560, height: 420)).anchor, .outsideTopLeft)
    }

    /// Against the screen's edge on the far side and too wide to have room facing the centre, it goes
    /// inside, still on the side facing the centre.
    func testNoRoomOutsideGoesInsideFacingTheCentre() {
        let window = NSRect(x: 20, y: 40, width: 1300, height: 800)
        XCTAssertEqual(choose(window), .init(anchor: .insideBottomRight, asPill: false))
        let frame = P.frame(at: .insideBottomRight, size: size, window: window, screen: screen)
        XCTAssertEqual(frame.maxX, window.maxX - P.inset)
        XCTAssertEqual(frame.minY, window.minY + P.inset)
    }

    /// Other windows never block: a neighbour right where the panel goes still gets covered.
    func testNeighboursDoNotBlock() {
        XCTAssertEqual(choose(NSRect(x: 500, y: 300, width: 400, height: 500)).anchor, .outsideTopRight)
    }

    /// Nothing fits: no room outside, and the window too short to hold it inside — a pill in the inside
    /// corner facing the centre.
    func testEverythingBlockedIsAPillInside() {
        XCTAssertEqual(choose(NSRect(x: 20, y: 40, width: 1300, height: 300)), .init(anchor: .insideBottomRight, asPill: true))
    }

    /// A dragged spot wins while it is clear, and gives way to auto order while it is blocked.
    func testSpotWinsUnlessBlocked() {
        let window = NSRect(x: 80, y: 400, width: 420, height: 400)
        XCTAssertEqual(choose(window, spot: .insideBottomLeft).anchor, .insideBottomLeft)
        XCTAssertEqual(choose(window, spot: .outsideTopLeft).anchor, .outsideTopRight)   // off the screen's left
    }

    /// A drop snaps to the nearest clear anchor, and never to a blocked one however near.
    func testDropSnapsToNearestClearAnchor() {
        let window = NSRect(x: 80, y: 400, width: 420, height: 400)
        let nearBottomLeft = NSRect(x: 100, y: 380, width: 300, height: 320)
        XCTAssertEqual(P.nearest(to: nearBottomLeft, size: size, window: window, screen: screen, header: 28), .insideBottomLeft)
        let offLeft = NSRect(x: -260, y: 480, width: 300, height: 320)
        XCTAssertNotEqual(P.nearest(to: offLeft, size: size, window: window, screen: screen, header: 28), .outsideTopLeft)
    }

    /// The panel stays on the screen top to bottom: a window running off the bottom pulls an inside panel up.
    func testFrameStaysOnScreenVertically() {
        let window = NSRect(x: 200, y: -200, width: 600, height: 500)
        XCTAssertEqual(P.frame(at: .insideBottomLeft, size: size, window: window, screen: screen).minY, 0)
    }
}
