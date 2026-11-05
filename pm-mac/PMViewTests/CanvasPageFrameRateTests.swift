import AppKit
import WebKit
import XCTest

/// Stepping into a tile raises its page's frame rate with one frame of "hidden" — never under a held
/// button, where it swallowed the press that stepped in (docs/spaces.md: a click on a tile clicks through).
@MainActor
final class CanvasPageFrameRateTests: XCTestCase {
    private var window: NSWindow!
    private var page: CanvasPageView!
    private let realButton = CanvasPageView.buttonHeld

    override func setUpWithError() throws {
        window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 400, height: 300),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.backgroundColor = .windowBackgroundColor
        page = CanvasPageView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: WKWebViewConfiguration())
        window.contentView?.addSubview(page)
        window.orderBack(nil)
    }

    override func tearDownWithError() throws {
        CanvasPageView.buttonHeld = realButton
        window.orderOut(nil)
    }

    private func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    func testWithNoButtonDownThePageHidesForOneFrameAtOnce() {
        CanvasPageView.buttonHeld = { false }
        page.setFullFrameRate(true)
        XCTAssertTrue(page.isHiddenOrHasHiddenAncestor, "the frame WebKit needs to read the rate")
        spin(0.1)
        XCTAssertFalse(page.isHiddenOrHasHiddenAncestor)
    }

    func testUnderAHeldButtonThePageStaysVisibleUntilRelease() {
        var held = true
        CanvasPageView.buttonHeld = { held }
        page.setFullFrameRate(true)
        XCTAssertTrue(page.fullFrameRate, "the rate is set at once")
        XCTAssertFalse(page.isHiddenOrHasHiddenAncestor, "the press that stepped in has to reach the page")
        spin(0.1)
        XCTAssertFalse(page.isHiddenOrHasHiddenAncestor, "still held")
        held = false
        let deadline = Date().addingTimeInterval(1)
        var pulsed = false
        while Date() < deadline, !pulsed {
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
            pulsed = page.isHiddenOrHasHiddenAncestor
        }
        XCTAssertTrue(pulsed, "released: the pulse runs")
    }
}

/// Arc's dead space: a press at the top of a tile's page on nothing usable moves the window.
@MainActor
final class CanvasPageDeadSpaceTests: XCTestCase {
    func testOnlyThePlainArrowOverNothingUsableIsDeadSpace() {
        XCTAssertTrue(CanvasPageView.isDeadSpace(cursor: .arrow, interactive: false))
        XCTAssertFalse(CanvasPageView.isDeadSpace(cursor: .arrow, interactive: true), "a link, image, media or field")
        XCTAssertFalse(CanvasPageView.isDeadSpace(cursor: .pointingHand, interactive: false), "cursor: pointer")
        XCTAssertFalse(CanvasPageView.isDeadSpace(cursor: .iBeam, interactive: false), "text to select")
        XCTAssertFalse(CanvasPageView.isDeadSpace(cursor: nil, interactive: false))
    }

    func testTheBandIsTheTopOfThePageOnly() {
        let page = CanvasPageView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: WKWebViewConfiguration())
        let top: (CGFloat) -> NSPoint = { down in NSPoint(x: 200, y: page.isFlipped ? down : 300 - down) }
        XCTAssertTrue(page.isInDeadSpaceBand(top(2)))
        XCTAssertTrue(page.isInDeadSpaceBand(top(CanvasPageView.deadSpaceBand)))
        XCTAssertFalse(page.isInDeadSpaceBand(top(CanvasPageView.deadSpaceBand + 1)), "the page's body is the page's")
        XCTAssertFalse(page.isInDeadSpaceBand(NSPoint(x: 500, y: page.isFlipped ? 2 : 298)), "outside the page")
    }

    func testOffByDefaultOutsideASpace() {
        let page = CanvasPageView(frame: .zero, configuration: WKWebViewConfiguration())
        XCTAssertFalse(page.dragsWindowFromDeadSpace())
    }
}
