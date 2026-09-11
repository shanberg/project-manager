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
        <script>window.ready = true</script>
        </body></html>
        """

    private let textarea = NSPoint(x: 100, y: 50)
    private let paragraph = NSPoint(x: 400, y: 50)

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
