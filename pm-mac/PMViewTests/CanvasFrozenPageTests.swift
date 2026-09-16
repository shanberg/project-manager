import XCTest
import AppKit
@testable import PMViewTests

/// The picture a card shows when it isn't running a page: how it is drawn, and how long it is kept.
@MainActor
final class CanvasFrozenPageTests: XCTestCase {

    private let card = "/Users/x/Vault/Work/docs/Board.canvas#n42"

    override func tearDown() {
        CanvasPageSnapshots.forget(card)
        super.tearDown()
    }

    private func image(_ size: NSSize, _ colour: NSColor) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        colour.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        return image
    }

    /// Whether the picture itself is drawn at `point`. Asked as "is it the picture's colour" rather
    /// than "is it not the background", because the background is `textBackgroundColor` and its value
    /// depends on the appearance the tests happen to run in.
    private func showsPicture(_ view: NSView, at point: NSPoint) -> Bool {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: rep)
        // `colorAt` is in the rep's own pixels, which on a Retina Mac is twice the view's points —
        // and sampling in points quietly reads a place a quarter of the way in.
        let x = Int(point.x / view.bounds.width * CGFloat(rep.pixelsWide))
        let y = Int(point.y / view.bounds.height * CGFloat(rep.pixelsHigh))
        guard let colour = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return false }
        return colour.blueComponent > 0.9 && colour.redComponent < 0.1
    }

    /// The one colour the background cannot be in either appearance.
    private let ink = NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)

    // MARK: How it is drawn

    /// The whole point of not being an `NSImageView` set to `scaleAxesIndependently`: a card that is a
    /// different shape from the picture shows the page's own proportions, not a squashed one.
    func testThePictureIsScaledToTheWidthAndAnchoredAtTheTop() {
        let view = CanvasFrozenPageView(frame: NSRect(x: 0, y: 0, width: 200, height: 300))
        view.image = image(NSSize(width: 100, height: 50), ink)

        // 100 wide drawn at 200 is a scale of 2, so 50 tall becomes 100 tall, from the top down.
        XCTAssertTrue(showsPicture(view, at: NSPoint(x: 100, y: 50)), "inside the picture")
        // And below it the page's own default ground, not the picture stretched to reach.
        XCTAssertFalse(showsPicture(view, at: NSPoint(x: 100, y: 200)), "below the picture")
    }

    /// The scale is a function of the width, so a tile dragged wider draws the picture bigger — rather
    /// than at the size it had when it was installed.
    func testResizingRedrawsItAtTheNewWidth() {
        let view = CanvasFrozenPageView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        view.image = image(NSSize(width: 100, height: 50), ink)
        // At 100 wide the picture is 50 tall, so three quarters of the way down is below it.
        XCTAssertFalse(showsPicture(view, at: NSPoint(x: 50, y: 75)))
        view.setFrameSize(NSSize(width: 200, height: 100))
        // At 200 wide it is 100 tall, and the same point is inside it.
        XCTAssertTrue(showsPicture(view, at: NSPoint(x: 50, y: 75)))
    }

    // MARK: How long it is kept

    func testACardWithNoPictureHasNone() {
        XCTAssertNil(CanvasPageSnapshots.of(card, tiled: false))
    }

    func testAPictureComesBackForTheCardItWasKeptFor() throws {
        CanvasPageSnapshots.keep(image(NSSize(width: 400, height: 300), ink), for: card, tiled: false)
        let back = try XCTUnwrap(CanvasPageSnapshots.of(card, tiled: false))
        XCTAssertEqual(back.size.width, 400)
        XCTAssertNil(CanvasPageSnapshots.of("/Users/x/Vault/Work/docs/Board.canvas#n43", tiled: false))
    }

    /// A Retina tile at full size would be megabytes a card, for detail nothing looks at long enough
    /// to want — the picture is crossed out by a loaded page in a fifth of a second.
    ///
    /// Awaited, because the shrink is deliberately off the main thread: `keep` is called as cards are
    /// recycled out of a scroll, and resampling them on the way through is the one thing this feature
    /// could do that costs more than it is worth. The full-size picture stands in until it lands.
    func testABigPictureIsShrunkAndKeepsItsShape() async throws {
        let edge = CanvasPageSnapshots.longestEdge
        CanvasPageSnapshots.keep(image(NSSize(width: edge * 2, height: edge), ink), for: card, tiled: false)
        XCTAssertEqual(CanvasPageSnapshots.of(card, tiled: false)?.size.width, CGFloat(edge * 2),
                       "the stand-in, at full size")

        try await until("the shrunk one lands") {
            CanvasPageSnapshots.of(card, tiled: false)?.size.width == CGFloat(edge)
        }
        let back = try XCTUnwrap(CanvasPageSnapshots.of(card, tiled: false))
        XCTAssertEqual(back.size.height, edge / 2, accuracy: 1, "and it keeps its shape")
    }

    private func until(_ what: String, timeout: TimeInterval = 5,
                       _ done: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !done() {
            if Date() > deadline { return XCTFail("timed out waiting for \(what)") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// A picture of the page a card used to point at is worse than no picture at all — at either shape.
    func testForgettingLeavesNothingBehind() {
        CanvasPageSnapshots.keep(image(NSSize(width: 400, height: 300), ink), for: card, tiled: false)
        CanvasPageSnapshots.keep(image(NSSize(width: 1200, height: 800), ink), for: card, tiled: true)
        CanvasPageSnapshots.forget(card)
        XCTAssertNil(CanvasPageSnapshots.of(card, tiled: false))
        XCTAssertNil(CanvasPageSnapshots.of(card, tiled: true))
    }

    /// **A card and its tile keep separate pictures** (backlog 35). A tile closed puts a window-shaped
    /// picture in the store, and handing that to the 400pt card showed a strip of its top-left corner;
    /// a card with a picture only at the other shape has none at this one, and shows its placeholder.
    func testATilesPictureIsNotTheCardsPicture() throws {
        CanvasPageSnapshots.keep(image(NSSize(width: 1200, height: 800), ink), for: card, tiled: true)
        XCTAssertNil(CanvasPageSnapshots.of(card, tiled: false), "the board was handed the tile's picture")
        XCTAssertEqual(try XCTUnwrap(CanvasPageSnapshots.of(card, tiled: true)).size.width, 1200)

        CanvasPageSnapshots.keep(image(NSSize(width: 400, height: 300), ink), for: card, tiled: false)
        XCTAssertEqual(try XCTUnwrap(CanvasPageSnapshots.of(card, tiled: false)).size.width, 400)
        XCTAssertEqual(try XCTUnwrap(CanvasPageSnapshots.of(card, tiled: true)).size.width, 1200,
                       "keeping the card's picture replaced the tile's")
    }
}
