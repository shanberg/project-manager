import XCTest
import AppKit

/// Fill or fit, and what the card actually does with the answer.
///
/// A picture card used to letterbox every picture, so a board of photographs was a board of grey
/// margins in a dozen proportions. A card that is nearly the picture's shape now fills instead — see
/// `CanvasPictureView`, which also argues why the tolerance is a constant rather than a setting.
@MainActor
final class CanvasPictureFitTests: XCTestCase {

    private let photo = CGSize(width: 4032, height: 3024)   // 4:3, straight off a phone

    /// The case this exists for: a card made roughly right for its picture stops showing bands of
    /// empty surface and just shows the picture.
    func testACardNearlyTheRightShapeFills() {
        XCTAssertTrue(CanvasPictureFit.fills(card: CGSize(width: 400, height: 300), picture: photo))
        XCTAssertTrue(CanvasPictureFit.fills(card: CGSize(width: 400, height: 310), picture: photo))
        XCTAssertTrue(CanvasPictureFit.fills(card: CGSize(width: 400, height: 290), picture: photo))
    }

    /// And the other half of the design: a card deliberately shaped against its picture is a decision,
    /// and filling it would throw away the composition the card was made for.
    func testACardDeliberatelyTheWrongShapeGoesOnFitting() {
        XCTAssertFalse(CanvasPictureFit.fills(card: CGSize(width: 400, height: 400), picture: photo),
                       "a square card under a 4:3 photo is a choice")
        XCTAssertFalse(CanvasPictureFit.fills(card: CGSize(width: 900, height: 300), picture: photo))
        XCTAssertFalse(CanvasPictureFit.fills(card: CGSize(width: 300, height: 900), picture: photo))
    }

    /// The disagreement is read as a ratio, so it is the same disagreement whichever way up the two
    /// are — a 3:2 card under a 2:3 picture is not "nearly right" in one direction only.
    func testTheAnswerDoesNotDependOnWhichWayUpTheyAre() {
        let tall = CGSize(width: 2, height: 3), wide = CGSize(width: 3, height: 2)
        XCTAssertEqual(CanvasPictureFit.fills(card: tall, picture: wide),
                       CanvasPictureFit.fills(card: wide, picture: tall))
        XCTAssertTrue(CanvasPictureFit.fills(card: tall, picture: CGSize(width: 200, height: 300)))
    }

    /// Nothing to compare is not a licence to crop. A card with no height yet — the frame a view has
    /// before its first layout — must not decide anything.
    func testNothingToGoOnMeansFit() {
        XCTAssertFalse(CanvasPictureFit.fills(card: .zero, picture: photo))
        XCTAssertFalse(CanvasPictureFit.fills(card: CGSize(width: 400, height: 300), picture: .zero))
    }

    // MARK: What the view does with it

    /// Filling is done by layout rather than by drawing — the image view is given the smallest frame
    /// of the picture's own shape that covers the card, and this clips. So the assertion is about
    /// where that subview ends up: covering the card, centred, and proportional.
    func testFillingCoversTheCardWithTheOverflowSplitBetweenBothEdges() throws {
        let view = CanvasPictureView(frame: NSRect(x: 0, y: 0, width: 400, height: 280))
        view.image = NSImage(size: NSSize(width: 4032, height: 3024))
        view.layoutSubtreeIfNeeded()

        let inside = try XCTUnwrap(view.subviews.first)
        XCTAssertGreaterThanOrEqual(inside.frame.width, view.bounds.width)
        XCTAssertGreaterThanOrEqual(inside.frame.height, view.bounds.height)
        XCTAssertEqual(inside.frame.midX, view.bounds.midX, accuracy: 1, "the crop is off centre")
        XCTAssertEqual(inside.frame.midY, view.bounds.midY, accuracy: 1, "the crop is off centre")
        XCTAssertEqual(inside.frame.width / inside.frame.height, 4032 / 3024, accuracy: 0.01,
                       "the picture is being stretched rather than covered")
    }

    /// And fitting leaves the image view exactly the card, which is what letterboxes it.
    func testFittingLeavesTheImageViewTheWholeCard() throws {
        let view = CanvasPictureView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        view.image = NSImage(size: NSSize(width: 4032, height: 3024))
        view.layoutSubtreeIfNeeded()

        XCTAssertEqual(try XCTUnwrap(view.subviews.first).frame, view.bounds)
    }

    /// A card with no picture in it is not a card with a stale frame in it.
    func testNoPictureLeavesTheViewTheCard() throws {
        let view = CanvasPictureView(frame: NSRect(x: 0, y: 0, width: 400, height: 280))
        view.layoutSubtreeIfNeeded()

        XCTAssertEqual(try XCTUnwrap(view.subviews.first).frame, view.bounds)
    }
}
