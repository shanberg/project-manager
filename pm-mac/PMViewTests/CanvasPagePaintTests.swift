import XCTest
import AppKit

/// Telling a page from a blank web view, which is the whole of how a card decides it is ready.
///
/// A card used to wait for `didFinish` and so sat behind its placeholder through everything an app
/// shell does after its first screenful. It now takes a small snapshot every 300ms from `didCommit`
/// and asks this whether there is a page on it — see `CanvasLinkNodeView.startProbingForPaint`, and
/// `CanvasPagePaint` for why a snapshot answers a question the API won't.
///
/// The cases here are the three things a suppressed web view actually comes back as, and the least a
/// real page paints. The numbers in `CanvasPagePaint` are only defensible against those, so they are
/// pinned against them rather than described.
@MainActor
final class CanvasPagePaintTests: XCTestCase {

    /// **A blank view is not necessarily a white one.** WebKit uses the ground the page will presume:
    /// white where it never mentions `color-scheme`, its dark canvas where it opts in. Both are a
    /// card with nothing to look at.
    func testAFlatGroundIsNotAPageInEitherAppearance() {
        XCTAssertFalse(CanvasPagePaint.hasSomethingOnIt(flat(white: 1)))
        XCTAssertFalse(CanvasPagePaint.hasSomethingOnIt(flat(white: 0.11)))
        XCTAssertFalse(CanvasPagePaint.hasSomethingOnIt(flat(white: 0)))
    }

    /// The least an app shell paints — a bar across the top — and the reveal this was written for.
    func testABarAcrossTheTopIsAPage() {
        let shell = drawn { context, size in
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(CGRect(origin: .zero, size: size))
            context.setFillColor(gray: 0.2, alpha: 1)
            context.fill(CGRect(x: 0, y: size.height - 3, width: size.width, height: 3))
        }
        XCTAssertTrue(CanvasPagePaint.hasSomethingOnIt(shell))
    }

    /// A spinner in the middle of an otherwise empty page: about 4% of the picture at this size, which
    /// is the case the 2% share exists for.
    func testASpinnerAloneIsEnough() {
        let spinner = drawn { context, size in
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(CGRect(origin: .zero, size: size))
            context.setFillColor(gray: 0.4, alpha: 1)
            context.fillEllipse(in: CGRect(x: size.width / 2 - 4, y: size.height / 2 - 4,
                                           width: 8, height: 8))
        }
        XCTAssertTrue(CanvasPagePaint.hasSomethingOnIt(spinner))
    }

    /// **And a few stray pixels are not.** A subpixel-antialiased edge, a hairline, a rounded corner
    /// against the card — a card revealed on one of those is a card revealed onto nothing.
    func testAHandfulOfPixelsIsNotAPage() {
        let speck = drawn { context, size in
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(CGRect(origin: .zero, size: size))
            context.setFillColor(gray: 0, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 3, height: 3))
        }
        XCTAssertFalse(CanvasPagePaint.hasSomethingOnIt(speck))
    }

    /// A ground that isn't perfectly even — a gradient, a compression artefact — is still a ground,
    /// which is what the tolerance is for.
    func testAGroundThatIsAlmostEvenIsStillAGround() {
        let nearly = drawn { context, size in
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(CGRect(origin: .zero, size: size))
            context.setFillColor(gray: 0.98, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: size.width, height: size.height / 2))
        }
        XCTAssertFalse(CanvasPagePaint.hasSomethingOnIt(nearly))
    }

    /// Nothing to go on is not evidence of a page. A snapshot of a card with no size, or one WebKit
    /// declined to take, must not reveal it.
    func testTooSmallToJudgeIsNotAPage() {
        XCTAssertFalse(CanvasPagePaint.hasSomethingOnIt(flat(white: 1, size: NSSize(width: 1, height: 1))))
    }

    // MARK: Building the pictures

    /// The proportions a snapshot comes back in: 48 points wide, on a card about half again as wide as
    /// it is tall. The share threshold is a fraction of *these* pixels, so the fixtures are that size.
    private static let snapshot = NSSize(width: 48, height: 32)

    private func flat(white: CGFloat, size: NSSize = CanvasPagePaintTests.snapshot) -> NSImage {
        drawn(size: size) { context, size in
            context.setFillColor(gray: white, alpha: 1)
            context.fill(CGRect(origin: .zero, size: size))
        }
    }

    private func drawn(size: NSSize = CanvasPagePaintTests.snapshot,
                       _ paint: (CGContext, CGSize) -> Void) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocusFlipped(false)
        if let context = NSGraphicsContext.current?.cgContext {
            paint(context, CGSize(width: size.width, height: size.height))
        }
        image.unlockFocus()
        return image
    }
}
