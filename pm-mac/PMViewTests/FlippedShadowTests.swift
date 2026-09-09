import XCTest
import AppKit

/// Which way a shadow falls out of a flipped, layer-backed view.
///
/// Every card sits in a flipped superview — `CanvasBoardView.isFlipped` — and AppKit places a layer
/// inside one by flipping the backing layer's *geometry*, which takes `shadowOffset` with it. So the
/// negative height that means "down" on an ordinary layer casts upwards there, and a board of cards was
/// lit from below until the sign was turned round.
///
/// **It is the superview's flippedness that decides, not the view's own**, which is the part worth
/// having a test for: a card declares `isFlipped` too, and reading that as the cause would be right
/// about the sign for the wrong reason — and wrong the moment something flipped is hosted in something
/// that isn't.
///
/// Asserted against the platform rather than against `CanvasNodeView`, deliberately: the thing that
/// could change under us is AppKit's behaviour, and the card is only one of the places that depends on
/// it (`CanvasNoticeBar` is the other). This renders a view and counts pixels, because the whole
/// question is what actually got drawn — reading the offset back would only tell us what we set.
@MainActor
final class FlippedShadowTests: XCTestCase {

    /// A view whose subviews are laid out top-down, or not — the board, or an ordinary AppKit view.
    private final class Ground: NSView {
        var flip = false
        override var isFlipped: Bool { flip }
    }

    /// A white square on a transparent ground, casting a black shadow `offset` points along y.
    private final class ShadowedBox: NSView {
        init(offset: CGFloat) {
            super.init(frame: NSRect(x: 30, y: 30, width: 40, height: 40))
            wantsLayer = true
            layer?.backgroundColor = NSColor.white.cgColor
            layer?.masksToBounds = false
            shadow = NSShadow()
            layer?.shadowColor = NSColor.black.cgColor
            layer?.shadowOpacity = 1
            layer?.shadowRadius = 2
            layer?.shadowOffset = CGSize(width: 0, height: offset)
        }

        required init?(coder: NSCoder) { fatalError() }
    }

    /// How much shadow landed above the box versus below it, in screen terms — y grows downward in the
    /// bitmap's own rows, so "below" is the higher row index.
    private func spill(offset: CGFloat, flipped: Bool) -> (above: Int, below: Int) {
        let host = Ground(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        host.flip = flipped
        host.wantsLayer = true
        host.addSubview(ShadowedBox(offset: offset))

        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)

        // **In pixels, not points.** `bitmapImageRepForCachingDisplay` hands back a rep at the
        // backing scale, so on a Retina machine a 100pt host is a 200px bitmap and `colorAt(x:y:)`
        // indexes the pixels. Read in points, the band below the box lands *inside* it and every case
        // "passes" by measuring white paint.
        let scale = Double(rep.pixelsHigh) / host.bounds.height

        // The box occupies 30..<70 in the host's own coordinates, which lands at 30..<70 of the bitmap
        // either way round — the frame is symmetric about the middle of a 100pt host, which is why
        // these numbers were chosen. Look at the bands just outside it and ask which one darkened.
        func darkness(points: Range<Double>) -> Int {
            var total = 0
            for y in Int(points.lowerBound * scale)..<Int(points.upperBound * scale) {
                for x in Int(25 * scale)..<Int(75 * scale) {
                    guard let colour = rep.colorAt(x: x, y: y) else { continue }
                    // Shadow on nothing: opaque black against a transparent ground.
                    total += Int(colour.alphaComponent * 100)
                }
            }
            return total
        }
        return (above: darkness(points: 20..<29), below: darkness(points: 71..<80))
    }

    /// The baseline, so a failure tells us whether AppKit changed or only our reading of it: in an
    /// ordinary unflipped superview, negative is down.
    func testAnUnflippedGroundCastsANegativeOffsetDownwards() {
        let (above, below) = spill(offset: -4, flipped: false)
        XCTAssertGreaterThan(below, above)
    }

    /// The rule the cards depend on.
    func testAFlippedGroundCastsAPositiveOffsetDownwards() {
        let (above, below) = spill(offset: 4, flipped: true)
        XCTAssertGreaterThan(below, above,
                             "A flipped ground flips the layer's geometry, and the shadow with it: "
                             + "positive height is down.")
    }

    /// And the bug, stated as a test, so nobody restores the sign by tidying.
    func testAFlippedGroundCastsANegativeOffsetUpwards() {
        let (above, below) = spill(offset: -4, flipped: true)
        XCTAssertGreaterThan(above, below)
    }
}
