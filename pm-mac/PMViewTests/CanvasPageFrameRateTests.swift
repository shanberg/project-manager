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

/// What the page itself says is under a press in the band: Figma's arrow-cursored buttons, its
/// canvas, and the header of a panel floating over it are the page's, not dead space.
@MainActor
final class CanvasPageUsesTests: XCTestCase {
    private var window: NSWindow!
    private var page: CanvasPageView!

    /// 600×300. Top 40pt: a full-width header with a `<button>` at 300–340 and a `role=button` div at
    /// 360–400. Below it at y 50–90: a floating panel (absolute, inset, Figma's Variables) at 100–300
    /// whose header is plain, a dialog at 320–420, a canvas at 440–540. A fixed bar touching the right
    /// edge (Apple Music's header beside its sidebar) is the header's own right 100pt, y 0–40 — under it
    /// at 560 is blank. The app root is `tabindex=-1`, as an SPA's is.
    private static let html = """
        <style>body{margin:0} div,button,canvas{position:absolute;box-sizing:border-box}</style>
        <div id=root tabindex=-1 style="left:0;top:0;width:600px;height:300px">
          <div style="left:0;top:0;width:600px;height:40px;position:fixed">
            <button style="left:300px;top:5px;width:40px;height:30px"></button>
            <div role=button style="left:360px;top:5px;width:40px;height:30px"></div>
          </div>
          <div style="left:500px;top:0;width:100px;height:40px;position:fixed"></div>
          <div style="left:100px;top:50px;width:200px;height:100px"><div style="left:0;top:0;width:200px;height:40px"></div></div>
          <div role=dialog style="position:static"><div style="left:320px;top:50px;width:100px;height:40px;position:fixed;right:auto"></div></div>
          <canvas style="left:440px;top:50px;width:100px;height:40px"></canvas>
          <div tabindex=0 style="left:320px;top:110px;width:260px;height:190px">
            <video style="display:block;width:260px;height:190px"></video>
            <button style="left:20px;top:10px;width:40px;height:30px"></button>
          </div>
        </div>
        <script>window.downs = 0; window.clicks = 0;
          document.addEventListener('mousedown', () => window.downs++);
          document.addEventListener('click', () => window.clicks++);</script>
        """

    override func setUpWithError() throws {
        window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 600, height: 300),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.backgroundColor = .windowBackgroundColor
        page = CanvasPageView(frame: NSRect(x: 0, y: 0, width: 600, height: 300), configuration: WKWebViewConfiguration())
        window.contentView?.addSubview(page)
        window.orderBack(nil)
        page.loadHTMLString(Self.html, baseURL: nil)
        let end = Date().addingTimeInterval(5)
        while Date() < end, page.isLoading { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    }

    override func tearDownWithError() throws { window.orderOut(nil) }

    /// `down` from the page's top, in points.
    private func at(_ x: CGFloat, _ down: CGFloat) -> NSPoint {
        NSPoint(x: x, y: page.isFlipped ? down : 300 - down)
    }

    func testControlsCanvasAndFloatingBoxesAreThePages() async {
        let header = await page.pageUses(at: at(150, 20))
        XCTAssertFalse(header, "the blank of a full-width header is dead space, under an app's tabindex=-1 root")
        let besideSidebar = await page.pageUses(at: at(560, 20))
        XCTAssertFalse(besideSidebar, "a fixed bar touching the right edge is a header")
        let button = await page.pageUses(at: at(320, 20))
        XCTAssertTrue(button, "a <button> with the arrow cursor (Figma's toolbar)")
        let roleButton = await page.pageUses(at: at(380, 20))
        XCTAssertTrue(roleButton, "role=button")
        let panel = await page.pageUses(at: at(200, 60))
        XCTAssertTrue(panel, "the plain header of a panel floating over the page (Figma's Variables)")
        let dialog = await page.pageUses(at: at(370, 60))
        XCTAssertTrue(dialog, "inside role=dialog")
        let canvas = await page.pageUses(at: at(490, 60))
        XCTAssertTrue(canvas, "a canvas draws its own UI")
    }

    /// 260×190 at 320,110, inside a player wrapper with `tabindex=0` (how a player takes the space bar)
    /// and a button over its top left. Its foot, the last 96pt, is where controls live.
    func testTheVideoPicturePressIsItsOwnAnswer() async {
        let picture = await page.press(at: at(450, 160))
        XCTAssertEqual(picture, .video, "the picture, under a tabindex=0 wrapper that only holds it")
        let button = await page.press(at: at(350, 130))
        XCTAssertEqual(button, .page, "a control over the picture")
        let foot = await page.press(at: at(450, 260))
        XCTAssertEqual(foot, .page, "the strip along the foot is the player's controls")
        let usesVideo = await page.pageUses(at: at(450, 160))
        XCTAssertTrue(usesVideo, "a video is not dead space: a press on it is held, not taken")
    }

    /// A press on a video's picture is held: the page hears nothing until the button comes up, and then
    /// hears a click — so a player still pauses on a click. (A drag hands the press to the window, which
    /// `performDrag` runs a tracking loop for; not driven here.)
    @MainActor
    func testAClickOnAVideoReachesThePageOnReleaseNotOnPress() {
        page.dragsWindowFromDeadSpace = { true }
        page.hoverMoved(at: at(450, 160))
        XCTAssertTrue(wait { self.page.pageIsOnVideo() })
        func event(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: page.convert(at(450, 160), to: nil), modifierFlags: [],
                               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                               context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        func count(_ name: String) -> Int {
            var result = -1
            page.evaluateJavaScript("window.\(name)") { value, _ in result = (value as? Int) ?? -1 }
            _ = wait { result >= 0 }
            return result
        }
        page.mouseDown(with: event(.leftMouseDown))
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(count("downs"), 0, "held: the page has not been told")
        page.mouseUp(with: event(.leftMouseUp))
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(count("downs"), 1, "released unmoved: the press is replayed")
        XCTAssertEqual(count("clicks"), 1, "and it is a click")
    }

    func testAPressIsDeadSpaceOnlyOnceThePageHasAnsweredForTheLatestHover() {
        page.dragsWindowFromDeadSpace = { true }
        XCTAssertFalse(page.pageLeavesDeadSpace(), "no answer yet: the press is the page's")
        page.hoverMoved(at: at(150, 20))
        XCTAssertTrue(wait { self.page.pageLeavesDeadSpace() }, "answered: dead space")
        page.hoverMoved(at: at(320, 20))
        XCTAssertFalse(page.pageLeavesDeadSpace(), "a new hover: the old answer is for something else")
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertFalse(page.pageLeavesDeadSpace(), "a button is the page's")
        page.hoverMoved(at: at(150, 20))
        XCTAssertTrue(wait { self.page.pageLeavesDeadSpace() }, "back on the blank: dead space again")
    }

    func testOutsideALayoutNothingIsAsked() {
        page.hoverMoved(at: at(150, 20))
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertFalse(page.pageLeavesDeadSpace())
    }

    private func wait(_ done: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(3)
        while Date() < end, !done() { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        return done()
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
