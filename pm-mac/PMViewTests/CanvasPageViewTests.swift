import XCTest
import AppKit
import WebKit

/// A web card's page takes a drop only where it has somewhere to put it, and hands every other drop to
/// the board. See `CanvasPageView`.
///
/// Against a real page: the question of what is under the pointer is WebKit's to answer, and a
/// stand-in for it would only be asserting what the stand-in was told. The drag itself is a fake
/// `NSDraggingInfo` — AppKit only makes a real one for a real mouse — delivered straight to the view.
@MainActor
final class CanvasPageViewTests: XCTestCase {

    private var window: NSWindow!
    private var page: CanvasPageView!
    private var board: Recorder!

    /// Six regions, one kind of thing each. Positioned absolutely so the points below are exact.
    private static let html = """
        <html><body style="margin:0">
        <textarea style="position:absolute;left:0;top:0;width:200px;height:100px"></textarea>
        <p style="position:absolute;left:300px;top:0;width:200px;height:100px;margin:0">words</p>
        <input type="checkbox" style="position:absolute;left:0;top:150px;width:40px;height:40px">
        <input type="text" style="position:absolute;left:300px;top:150px;width:200px;height:40px">
        <textarea readonly style="position:absolute;left:0;top:250px;width:200px;height:100px"></textarea>
        <div contenteditable style="position:absolute;left:300px;top:250px;width:200px;height:100px">edit</div>
        <a href="mailto:someone@x.dev" style="position:absolute;left:0;top:110px;width:200px;height:30px">Mail</a>
        <a href="https://x.dev/near" style="position:absolute;left:210px;top:10px;width:80px;height:40px">Near</a>
        <a href="https://x.dev/docs" style="position:absolute;left:0;top:360px;width:200px;height:30px">
           The   Docs </a>
        <a href="https://x.dev/pictures" aria-label="Pictures"
           style="position:absolute;left:300px;top:360px;width:200px;height:30px"
           ><img alt="" src="data:image/gif;base64,R0lGODlhAQABAAAAACH5BAEKAAEALAAAAAABAAEAAAICTAEAOw=="
                 style="width:100%;height:30px"></a>
        <script>window.ready = true</script>
        </body></html>
        """

    private let textarea = NSPoint(x: 100, y: 50)
    private let paragraph = NSPoint(x: 400, y: 50)
    private let link = NSPoint(x: 100, y: 375)
    private let iconLink = NSPoint(x: 400, y: 375)

    override func setUp() async throws {
        try await super.setUp()
        TestApp.start()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                          styleMask: [.titled], backing: .buffered, defer: false)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        window.contentView = root
        board = Recorder(frame: root.bounds)
        root.addSubview(board)

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        page = CanvasPageView(frame: root.bounds, configuration: configuration)
        page.dropFallback = board
        root.addSubview(page)
        window.orderFront(nil)

        page.loadHTMLString(Self.html, baseURL: URL(string: "https://page.invalid/"))
        try await until("the page loads") {
            (try? await self.page.evaluateJavaScript("window.ready === true")) as? Bool == true
        }
    }

    override func tearDown() async throws {
        window?.orderOut(nil)
        try await super.tearDown()
    }

    // MARK: What the page says is under the pointer

    func testTheFieldsOnAPageAreWhereItTakesTyping() async {
        let asked: [(NSPoint, Bool, String)] = [
            (textarea, true, "textarea"),
            (paragraph, false, "paragraph"),
            (NSPoint(x: 20, y: 170), false, "checkbox"),
            (NSPoint(x: 400, y: 170), true, "text field"),
            (NSPoint(x: 100, y: 300), false, "read-only textarea"),
            (NSPoint(x: 400, y: 300), true, "contenteditable"),
        ]
        for (point, expected, what) in asked {
            let answer = await page.acceptsTyping(at: point)
            XCTAssertEqual(answer, expected, what)
        }
    }

    /// The card zooms its page, and the question has to be asked in the page's own pixels.
    func testAZoomedPageIsAskedInItsOwnPixels() async {
        page.pageZoom = 2
        // (300, 150) is the paragraph unzoomed, and the middle of the textarea at 2×.
        let answer = await page.acceptsTyping(at: NSPoint(x: 300, y: 150))
        XCTAssertTrue(answer)
    }

    // MARK: What the page says the link under the pointer is

    func testALinkIsFoundWithTheNameThePageGivesIt() async {
        let found = await page.link(at: link)
        XCTAssertEqual(found?.url.absoluteString, "https://x.dev/docs")
        // Written across two lines and indented in the source, and it means one label.
        XCTAssertEqual(found?.name, "The Docs")
    }

    /// Clicking the picture inside a link is clicking the link — `closest` is what makes that true.
    func testTheImageInsideALinkIsTheLink() async {
        let found = await page.link(at: iconLink)
        XCTAssertEqual(found?.url.absoluteString, "https://x.dev/pictures")
        // Nothing to read, so what it tells a screen reader is the name.
        XCTAssertEqual(found?.name, "Pictures")
    }

    func testPlainTextIsNotALink() async {
        let found = await page.link(at: paragraph)
        XCTAssertNil(found)
    }

    /// A card is what every caller is about to make out of this, and `mailto:` is not a card.
    func testOnlyWebLinksComeBack() async {
        let found = await page.link(at: NSPoint(x: 100, y: 125))
        XCTAssertNil(found)
    }

    /// The card zooms its page, and this question is asked in the page's own pixels too.
    ///
    /// A near link rather than one of the two above: at 2× the viewport is 300×200 of the page's own
    /// pixels, and `elementFromPoint` answers nothing for a point outside it.
    func testAZoomedPageIsAskedForLinksInItsOwnPixels() async {
        page.pageZoom = 2
        // (250, 30) in the page is drawn at twice that in the view.
        let found = await page.link(at: NSPoint(x: 500, y: 60))
        XCTAssertEqual(found?.url.absoluteString, "https://x.dev/near")
    }

    // MARK: The card's items on the page's menu

    func testTheCardsItemsGoAboveWebKitsWithASeparator() {
        let host = MenuHost()
        page.linkHost = host
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Reload", action: nil, keyEquivalent: ""))
        page.willOpenMenu(menu, with: NSEvent())
        XCTAssertEqual(menu.items.map(\.title), ["Add Page to Something", "", "Reload"])
        XCTAssertTrue(menu.items[1].isSeparatorItem)
    }

    /// A page with no card behind it is a page with WebKit's own menu, untouched.
    func testAPageWithNoHostKeepsTheMenuItWasGiven() {
        page.linkHost = nil
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Reload", action: nil, keyEquivalent: ""))
        page.willOpenMenu(menu, with: NSEvent())
        XCTAssertEqual(menu.items.map(\.title), ["Reload"])
    }

    private final class MenuHost: CanvasPageLinkHost {
        func pageMenuItems(for link: PageLink?) -> [NSMenuItem] {
            [NSMenuItem(title: "Add Page to Something", action: nil, keyEquivalent: "")]
        }

        func openInNewCard(_ link: PageLink) {}
    }

    // MARK: Who gets the drag

    func testADropAwayFromAFieldIsTheBoards() {
        let drag = FakeDrag(at: page.convert(paragraph, to: nil), in: window)
        XCTAssertEqual(page.draggingEntered(drag), .copy)
        XCTAssertTrue(page.performDragOperation(drag))
        XCTAssertEqual(board.calls, ["entered", "performed"])
    }

    /// Until the page has answered, the drag is the board's; once it says there is a field under the
    /// pointer, the board is told the drag has left it, and moving off the field brings it back.
    func testTheDragCrossesToThePageOverAFieldAndBack() async throws {
        let drag = FakeDrag(at: page.convert(textarea, to: nil), in: window)
        _ = page.draggingEntered(drag)
        XCTAssertEqual(board.calls, ["entered"], "the board holds the drag before the page has answered")

        try await until("the page takes the drag") {
            _ = self.page.draggingUpdated(drag)
            return self.board.calls.last == "exited"
        }

        drag.draggingLocation = page.convert(paragraph, to: nil)
        try await until("the board takes it back") {
            _ = self.page.draggingUpdated(drag)
            return self.board.calls.last == "entered" || self.board.calls.last == "updated"
        }
        XCTAssertTrue(page.performDragOperation(drag))
        XCTAssertEqual(board.calls.last, "performed")
    }

    // MARK: Helpers

    private func until(_ what: String, timeout: TimeInterval = 5, _ done: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !(await done()) {
            guard Date() < deadline else {
                XCTFail("timed out waiting for \(what)")
                throw CancellationError()
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}

/// Stands in for the board: says yes to every drag and writes down what it was told.
private final class Recorder: NSView {
    var calls: [String] = []
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { calls.append("entered"); return .copy }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { calls.append("updated"); return .copy }
    override func draggingExited(_ sender: NSDraggingInfo?) { calls.append("exited") }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { calls.append("performed"); return true }
}

/// A drag of one link, at a point in window coordinates.
private final class FakeDrag: NSObject, NSDraggingInfo {
    var draggingLocation: NSPoint
    let window: NSWindow
    let draggingPasteboard: NSPasteboard

    init(at point: NSPoint, in window: NSWindow) {
        draggingLocation = point
        self.window = window
        draggingPasteboard = NSPasteboard.withUniqueName()
        draggingPasteboard.clearContents()
        draggingPasteboard.writeObjects([URL(string: "https://x.dev/a")! as NSURL])
    }

    deinit { draggingPasteboard.releaseGlobally() }

    var draggingDestinationWindow: NSWindow? { window }
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggedImageLocation: NSPoint { draggingLocation }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?,
                                classes classArray: [AnyClass],
                                searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
}
