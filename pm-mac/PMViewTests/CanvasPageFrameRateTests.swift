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

/// The speaker: WebKit's own "playing audio" flag, told as it changes (docs/spaces.md).
@MainActor
final class CanvasPageAudioTests: XCTestCase {
    /// A second of a quiet 440Hz tone, as a WAV data URI.
    private func tone() -> String {
        let rate = 22050, samples = rate
        var data = Data()
        func le<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); le(UInt32(36 + samples * 2)); data.append(contentsOf: Array("WAVEfmt ".utf8))
        le(UInt32(16)); le(UInt16(1)); le(UInt16(1)); le(UInt32(rate)); le(UInt32(rate * 2)); le(UInt16(2)); le(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); le(UInt32(samples * 2))
        for i in 0..<samples { le(Int16(sin(Double(i) * 2 * .pi * 440 / Double(rate)) * 600)) }
        return "data:audio/wav;base64," + data.base64EncodedString()
    }

    private func wait(_ seconds: TimeInterval, until done: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end, !done() { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        return done()
    }

    func testThePageSaysWhenItPlaysAndWhenItStops() throws {
        let configuration = WKWebViewConfiguration()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 300, height: 200),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let page = CanvasPageView(frame: NSRect(x: 0, y: 0, width: 300, height: 200), configuration: configuration)
        window.contentView?.addSubview(page)
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        var told = 0
        let watch = NotificationCenter.default.addObserver(forName: CanvasPageView.audioChanged, object: page, queue: .main) { _ in told += 1 }
        defer { NotificationCenter.default.removeObserver(watch) }
        page.loadHTMLString("<audio id=a loop src='\(tone())'></audio>", baseURL: nil)
        XCTAssertTrue(wait(5) { !page.isLoading })
        page.evaluateJavaScript("document.getElementById('a').play()")
        XCTAssertTrue(wait(5) { page.isPlayingAudio }, "playing")
        XCTAssertGreaterThan(told, 0)
        page.pauseAllMediaPlayback()
        XCTAssertTrue(wait(5) { !page.isPlayingAudio }, "stopped")
    }
}
