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
        <html><meta name="color-scheme" content="light dark"><body style="margin:0">
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
        <div id="zone" style="position:absolute;left:210px;top:150px;width:80px;height:60px">zone</div>
        <script>
        document.getElementById('zone').addEventListener('dragover', (e) => e.preventDefault());
        window.ready = true
        </script>
        </body></html>
        """

    private let textarea = NSPoint(x: 100, y: 50)
    private let paragraph = NSPoint(x: 400, y: 50)
    /// The page's own drop zone: the one place on this page that claims a drop.
    private let zone = NSPoint(x: 250, y: 180)
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
        // Quiet for anyone working while this runs: the page opts into dark, and so does the frame before it paints.
        page.underPageBackgroundColor = .windowBackgroundColor
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

        var pageTakesFiles = false
    }

    // MARK: Who gets the drag

    // The four rows of the rule, in one place. The page is offered every drag and the board takes what
    // the page declines, so what decides each of these is whether anything on the page claimed the drop.

    /// **A drag the page claims is the page's.** The zone prevents the default on `dragover`, which is
    /// how an element says a drop is its own — this is the row the old rule got wrong, and the reason a
    /// layer list could not be reordered inside a card: HTML5 drag-and-drop is a real dragging session,
    /// and the board was taking it off the page that started it.
    func testADragThePageClaimsIsThePages() async throws {
        let drag = FakeDrag(at: page.convert(zone, to: nil), in: window, carrying: Self.webCustomData)
        _ = page.draggingEntered(drag)
        // "exited" is the board being told it has lost the drag, which is the page claiming it. Waiting
        // for merely "not entered" would stop one ask early, on WebKit's `.none` second reply.
        try await settle(drag, until: "the page claims it") { self.board.calls.last == "exited" }
        _ = page.prepareForDragOperation(drag)
        _ = page.performDragOperation(drag)
        XCTAssertFalse(board.calls.contains("performed"), "the board was given a drop the page claimed")
    }

    /// **A link let go over ordinary page is the board's**, and becomes a card. Nothing on the page
    /// claims it, so asking the page first costs the board nothing — which is the whole case for asking.
    func testADropAwayFromAnythingThatClaimsItIsTheBoards() async throws {
        let drag = FakeDrag(at: page.convert(paragraph, to: nil), in: window)
        _ = page.draggingEntered(drag)
        try await settle(drag, until: "the board holds it") { self.board.calls.last != nil }
        XCTAssertTrue(page.prepareForDragOperation(drag))
        XCTAssertTrue(page.performDragOperation(drag))
        XCTAssertEqual(board.calls.last, "performed")
    }

    /// **A drop over a field is the page's.** The old rule reached the same answer by asking the page in
    /// JavaScript; this one is WebKit answering for its own fields, which also covers the ones a script
    /// built and the ones inside a shadow root.
    func testADropOverAFieldIsThePages() async throws {
        let drag = FakeDrag(at: page.convert(textarea, to: nil), in: window)
        _ = page.draggingEntered(drag)
        try await settle(drag, until: "the page claims the field") { self.board.calls.last == "exited" }
        _ = page.prepareForDragOperation(drag)
        _ = page.performDragOperation(drag)
        XCTAssertFalse(board.calls.contains("performed"), "the board was given a drop over a field")
    }

    /// **A drop made before any of that has settled is the board's.** WebKit's first reply is an
    /// optimistic `.copy` for everything, so the answer is not worth anything until the page has
    /// actually been asked — and while it is unknown the drag belongs to the side that can make a card
    /// of it rather than the side that may be about to refuse it.
    func testADropInTheFirstFrameIsTheBoards() {
        let drag = FakeDrag(at: page.convert(zone, to: nil), in: window, carrying: Self.webCustomData)
        XCTAssertEqual(page.draggingEntered(drag), .copy)
        XCTAssertEqual(board.calls, ["entered"], "the page was given a drag on WebKit's first reply")
    }

    /// Crossing works in both directions within the one page: onto something that claims the drop and
    /// back off it, with the board told each time it gains or loses the drag.
    func testTheDragCrossesBetweenThePageAndTheBoard() async throws {
        let drag = FakeDrag(at: page.convert(paragraph, to: nil), in: window)
        _ = page.draggingEntered(drag)
        try await settle(drag, until: "the board holds it") { self.board.calls.last != nil }

        drag.draggingLocation = page.convert(zone, to: nil)
        try await settle(drag, until: "the page takes it") { self.board.calls.last == "exited" }

        drag.draggingLocation = page.convert(paragraph, to: nil)
        try await settle(drag, until: "the board takes it back") { self.board.calls.last == "entered" }
        XCTAssertTrue(page.performDragOperation(drag))
        XCTAssertEqual(board.calls.last, "performed")
    }

    /// Keep the drag alive the way AppKit does — it re-asks on a timer while a drag holds still — until
    /// `done`, since the page's answer arrives a round trip after the question.
    private func settle(_ drag: NSDraggingInfo, until what: String, _ done: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !done() {
            guard Date() < deadline else { return XCTFail("timed out waiting for \(what)") }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            _ = page.draggingUpdated(drag)
        }
    }

    /// What a page's own script puts on a drag: WebKit's custom data, and nothing a board can read.
    private static var webCustomData: NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString("grabbed",
                       forType: NSPasteboard.PasteboardType("com.apple.WebKit.custom-pasteboard-data"))
        return item
    }

    // MARK: Files, on a page you are working in

    /// A file dropped on a tile goes into the page — Figma's canvas, a mail composer — and not onto the
    /// board beside it, wherever on the page it lands.
    func testFilesAreThePagesWhereThePageTakesThem() {
        let host = MenuHost()
        host.pageTakesFiles = true
        page.linkHost = host
        let drag = FakeDrag(at: page.convert(paragraph, to: nil), in: window, carrying: Self.file)
        _ = page.draggingEntered(drag)
        _ = page.draggingUpdated(drag)
        XCTAssertEqual(board.calls, [], "the board is never offered it")
    }

    /// Anywhere else, a file away from a field is still the board's.
    func testFilesAreTheBoardsWhereThePageDoesNotTakeThem() {
        let host = MenuHost()
        page.linkHost = host
        let drag = FakeDrag(at: page.convert(paragraph, to: nil), in: window, carrying: Self.file)
        _ = page.draggingEntered(drag)
        XCTAssertEqual(board.calls, ["entered"])
    }

    /// **A link dropped on a tile is still the board's**, and goes up as a tile beside the others —
    /// the fourth row of the rule above. Only files are the page's wherever they land.
    func testALinkIsStillTheBoardsOnAPageThatTakesFiles() {
        let host = MenuHost()
        host.pageTakesFiles = true
        page.linkHost = host
        let drag = FakeDrag(at: page.convert(paragraph, to: nil), in: window)
        _ = page.draggingEntered(drag)
        XCTAssertEqual(board.calls, ["entered"])
    }

    private static let file = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("drop.txt") as NSURL

    // MARK: The side buttons

    /// Back and Forward on a mouse's fourth and fifth buttons walk the page's own history.
    func testTheSideButtonsGoBackAndForward() async throws {
        // Two real navigations, so there is a history to walk: `loadHTMLString` leaves no entry behind,
        // and WebKit skips entries a script pushes without a user gesture.
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("side-buttons-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = folder.appendingPathComponent("first.html")
        let second = folder.appendingPathComponent("second.html")
        try "<p>first</p>".write(to: first, atomically: true, encoding: .utf8)
        try "<p>second</p>".write(to: second, atomically: true, encoding: .utf8)

        page.loadFileURL(first, allowingReadAccessTo: folder)
        try await until("the first page loads") { self.page.url?.lastPathComponent == "first.html" }
        try await until("the first page finishes") { !self.page.isLoading }
        page.loadFileURL(second, allowingReadAccessTo: folder)
        try await until("the second page finishes") {
            self.page.url?.lastPathComponent == "second.html" && !self.page.isLoading
        }
        XCTAssertTrue(page.canGoBack, "back list: \(page.backForwardList.backList.map(\.url)), "
                      + "current: \(String(describing: page.backForwardList.currentItem?.url))")

        page.otherMouseDown(with: try sideButton(3))
        try await until("Back returns to the first page") {
            self.page.url?.lastPathComponent == "first.html" && !self.page.isLoading && self.page.canGoForward
        }
        page.otherMouseDown(with: try sideButton(4))
        try await until("Forward returns to the second") { self.page.url?.lastPathComponent == "second.html" }
    }

    private func sideButton(_ number: UInt32) throws -> NSEvent {
        let button = try XCTUnwrap(CGMouseButton(rawValue: number))
        let event = try XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: .otherMouseDown,
                                          mouseCursorPosition: .zero, mouseButton: button))
        return try XCTUnwrap(NSEvent(cgEvent: event))
    }

    // MARK: Pointer lock

    /// The Escape that takes the pointer back from a page does only that; the next one steps out of
    /// the card, as every Escape the page doesn't want does.
    ///
    /// The lock itself can't be taken here — WebKit wants an active window, and the test app never is
    /// one — so `holdsPointer` is set by hand, the way the card's delegate sets it when WebKit grants
    /// and ends a lock. The second Escape is the control: it proves the key really does come back up
    /// the chain in this harness, so the first one staying put means something.
    func testEscapeThatReleasesThePointerDoesNotAlsoStepOut() async throws {
        page.nextResponder = board
        window.makeFirstResponder(page)
        _ = try await page.evaluateJavaScript(
            "window.keys = 0; addEventListener('keydown', () => window.keys++); true")

        page.holdsPointer = true
        page.keyDown(with: try escape())
        try await until("the page sees the first Escape") {
            (try? await self.page.evaluateJavaScript("window.keys")) as? Int == 1
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(board.calls.contains("cancel"), "calls: \(board.calls)")

        // What WebKit's `_webViewDidLosePointerLock:` tells the card, and the card tells the page.
        page.holdsPointer = false
        page.keyDown(with: try escape())
        try await until("the second Escape reaches the card") { self.board.calls.contains("cancel") }
    }

    private func escape() throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                       timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: window.windowNumber, context: nil,
                                       characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                       isARepeat: false, keyCode: 53))
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
    override func cancelOperation(_ sender: Any?) { calls.append("cancel") }
}

/// A drag of one thing — a link, unless it is given something else — at a point in window coordinates.
private final class FakeDrag: NSObject, NSDraggingInfo {
    var draggingLocation: NSPoint
    let window: NSWindow
    let draggingPasteboard: NSPasteboard

    init(at point: NSPoint, in window: NSWindow,
         carrying item: NSPasteboardWriting = URL(string: "https://x.dev/a")! as NSURL) {
        draggingLocation = point
        self.window = window
        draggingPasteboard = NSPasteboard.withUniqueName()
        draggingPasteboard.clearContents()
        draggingPasteboard.writeObjects([item])
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
