import XCTest
import AppKit
import WebKit

/// **An experiment, for backlog 39** — a drag inside a page that the page itself wants.
///
/// Figma's layer list cannot be reordered inside a card, and the entry blamed `CanvasPageView`'s drop
/// routing: a drag is the board's unless there is somewhere to type under the pointer, so the page
/// never sees it. That story is only true if the drag is an **AppKit drag** — one WebKit started
/// because the page used HTML5 drag-and-drop. A list that reorders itself on pointer events is not an
/// AppKit drag at all, and none of the routing is involved.
///
/// So this asks, in order: do synthetic mouse events reach a page at all, does a pointer-driven
/// reorder work inside one, does an HTML5 drag start a real dragging session, and — if it does — who
/// ends up holding it.
@MainActor
final class CanvasPageDragOriginTests: XCTestCase {

    private var window: NSWindow!
    private var page: CanvasPageView!
    private var board: DragRecorder!

    /// Two lists side by side. The left reorders on pointer events, the way an app that rolls its own
    /// dragging does; the right is HTML5 drag-and-drop, with a zone that claims the drop by preventing
    /// the default on `dragover`. Everything that arrives is counted in `window.seen`.
    private static let html = """
        <html><meta name="color-scheme" content="light dark"><body style="margin:0;font:12px system-ui">
        <div id="ptr" style="position:absolute;left:0;top:0;width:280px">
          <div class="row" data-id="A" style="height:60px;background:rgba(128,128,128,.15)">A</div>
          <div class="row" data-id="B" style="height:60px;background:rgba(128,128,128,.3)">B</div>
          <div class="row" data-id="C" style="height:60px;background:rgba(128,128,128,.45)">C</div>
        </div>
        <div id="dnd" style="position:absolute;left:300px;top:0;width:280px">
          <div id="grab" draggable="true" style="height:60px;background:rgba(64,96,255,.25)">grab</div>
          <div id="zone" style="height:120px;background:rgba(255,64,64,.25)">zone</div>
        </div>
        <script>
        window.seen = {};
        const kinds = ['pointerdown','pointermove','pointerup','mousedown','mousemove','mouseup',
                       'dragstart','dragover','drop','dragend'];
        for (const kind of kinds) {
          window.seen[kind] = 0;
          window.addEventListener(kind, () => { window.seen[kind]++; }, true);
        }
        const ptr = document.getElementById('ptr');
        let held = null;
        ptr.addEventListener('pointerdown', (e) => {
          held = e.target.closest('.row');
          window.seen.grabbed = held ? held.dataset.id : 'none';
        });
        window.addEventListener('pointerup', (e) => {
          if (!held) return;
          const under = document.elementFromPoint(e.clientX, e.clientY);
          const row = under && under.closest ? under.closest('.row') : null;
          if (row && row !== held) ptr.insertBefore(held, row.nextSibling);
          held = null;
        });
        window.order = () => [...ptr.querySelectorAll('.row')].map(r => r.dataset.id).join('');
        document.getElementById('grab').addEventListener('dragstart', (e) => {
          e.dataTransfer.setData('text/plain', 'grabbed');
          e.dataTransfer.setData('application/x-pm-test', 'grabbed');
        });
        const zone = document.getElementById('zone');
        zone.addEventListener('dragover', (e) => { e.preventDefault(); window.seen.zoneOver = (window.seen.zoneOver || 0) + 1; });
        zone.addEventListener('drop', (e) => { e.preventDefault(); window.dropped = e.dataTransfer.getData('text/plain'); });
        window.ready = true;
        </script>
        </body></html>
        """

    /// Row centres, in the view's own (top-left) coordinates.
    private let rowA = NSPoint(x: 140, y: 30)
    private let rowC = NSPoint(x: 140, y: 150)
    private let grab = NSPoint(x: 440, y: 30)
    private let zone = NSPoint(x: 440, y: 120)
    private let plain = NSPoint(x: 140, y: 350)

    override func setUp() async throws {
        try await super.setUp()
        TestApp.start()
        HeldButtons.stand(in: true)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                          styleMask: [.titled], backing: .buffered, defer: false)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        window.contentView = root
        board = DragRecorder(frame: root.bounds)
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
        HeldButtons.stand(in: false)
        try await super.tearDown()
    }

    // MARK: Does anything we post reach the page

    /// The baseline every other answer here depends on. A negative anywhere below means nothing unless
    /// this passes: a page that never hears a press is a limit of the harness, not a finding about PM.
    func testSyntheticMouseEventsReachThePage() async throws {
        press(at: rowA)
        drag(to: rowC, steps: 4)
        release(at: rowC)
        let seen = try await counts()
        XCTAssertGreaterThan(seen["mousedown"] ?? 0, 0, "seen: \(seen)")
        XCTAssertGreaterThan(seen["mousemove"] ?? 0, 0, "seen: \(seen)")
        XCTAssertGreaterThan(seen["mouseup"] ?? 0, 0, "seen: \(seen)")
    }

    /// Pointer events are the other half: a list that rolls its own dragging listens for these.
    func testPointerEventsReachThePage() async throws {
        press(at: rowA)
        drag(to: rowC, steps: 4)
        release(at: rowC)
        let seen = try await counts()
        XCTAssertGreaterThan(seen["pointerdown"] ?? 0, 0, "seen: \(seen)")
        XCTAssertGreaterThan(seen["pointermove"] ?? 0, 0, "seen: \(seen)")
        XCTAssertGreaterThan(seen["pointerup"] ?? 0, 0, "seen: \(seen)")
    }

    /// The question the entry is really about, asked of a list we wrote: drag the first row past the
    /// last and see whether the page reorders itself. Nothing in PM should be able to stop this one.
    func testAPointerDrivenListReordersInsideACard() async throws {
        let before = try await order()
        XCTAssertEqual(before, "ABC")
        press(at: rowA)
        drag(to: rowC, steps: 6)
        release(at: rowC)
        try await settle()
        let after = try await order()
        let seen = try await counts()
        XCTAssertEqual(after, "BCA", "the rows did not move; seen: \(seen)")
    }

    // MARK: Does an HTML5 drag become an AppKit drag

    /// Pressing on a `draggable` element and moving should make WebKit start a real dragging session.
    /// Seen out deliberately: an AppKit drag parks the main thread in a tracking loop until it is given
    /// a mouse-up, and an unattended one stops the whole bundle rather than failing.
    func testAnHTML5DragStarts() async throws {
        press(at: grab)
        // Not pumped: the loop is entered from a runloop observer, so turning the runloop here enters it
        // with nothing to end it. Everything is posted first and the runloop is turned below, where an
        // up is already at the head of the queue.
        drag(to: zone, steps: 6, pumping: false)
        HeldButtons.mask = 0  // the release is the up the loop is handed below
        seeOutAnyTrackingLoop(in: window, at: page.convert(zone, to: nil), for: 1.5)
        try await settle()
        let seen = try await counts()
        print("HTML5-DRAG seen=\(seen) board=\(board.calls) notes=\(board.notes)")
        XCTAssertGreaterThan(seen["dragstart"] ?? 0, 0, "no dragstart; seen: \(seen)")
    }

    // MARK: Who holds a drag the page wants

    /// A drag carrying what a script put on it, over a zone that would claim it. Today the board takes
    /// it, because nothing under the pointer is somewhere to type — this is the steal, written down.
    func testTheBoardTakesADragOverAPagesOwnDropZone() async throws {
        let drag = WebDrag(at: page.convert(zone, to: nil), in: window, carrying: .custom)
        _ = page.draggingEntered(drag)
        for _ in 0..<10 {
            _ = page.draggingUpdated(drag)
            try await settle()
        }
        let seen = try await counts()
        XCTAssertEqual(board.calls.first, "entered", "who held it: \(board.calls), seen: \(seen)")
    }

    /// **The go/no-go for "ask WebKit first".** With no board to fall back to, every drag goes to
    /// WebKit — so what it answers is the page's own opinion, and the question is whether that opinion
    /// tells a drop zone apart from bare page. Recorded rather than asserted: this is a measurement.
    func testWhatWebKitAnswersForEachPayload() async throws {
        page.dropFallback = nil
        var answers: [String: String] = [:]
        let cases: [(String, NSPoint, WebDrag.Payload)] = [
            ("custom-over-zone", zone, .custom),
            ("custom-over-plain", plain, .custom),
            ("strings-link-over-zone", zone, .linkAsStrings),
            ("strings-link-over-plain", plain, .linkAsStrings),
            ("url-link-over-zone", zone, .linkAsURL),
            ("url-link-over-plain", plain, .linkAsURL),
        ]
        for (what, point, payload) in cases {
            let drag = WebDrag(at: page.convert(point, to: nil), in: window, carrying: payload)
            var answer = page.draggingEntered(drag)
            for _ in 0..<8 {
                answer = page.draggingUpdated(drag)
                try await settle()
            }
            answers[what] = "\(answer.rawValue)"
            page.draggingExited(drag)
            try await settle()
        }
        print("WEBKIT-ANSWERS \(answers)")
        XCTAssertFalse(answers.isEmpty)
    }

    /// **Does WebKit still navigate a card that is dropped a link?** That is the hazard the whole
    /// override exists to prevent, and whether it is still real decides whether the page can simply be
    /// asked first. Written as a real `NSURL`, the way a browser writes a dragged link — a link spelled
    /// as strings is not the same offer.
    func testALinkDroppedOnABarePageWithNothingToFallBackOn() async throws {
        page.dropFallback = nil
        let before = page.url
        let drag = WebDrag(at: page.convert(plain, to: nil), in: window, carrying: .linkAsURL)
        var answer = page.draggingEntered(drag)
        for _ in 0..<8 {
            answer = page.draggingUpdated(drag)
            try await settle()
        }
        let prepared = page.prepareForDragOperation(drag)
        let performed = prepared ? page.performDragOperation(drag) : false
        for _ in 0..<20 { try await settle() }
        print("LINK-ON-BARE-PAGE answer=\(answer.rawValue) prepared=\(prepared) performed=\(performed) "
              + "was=\(before?.absoluteString ?? "nil") now=\(page.url?.absoluteString ?? "nil")")
        XCTAssertEqual(page.url, before, "the page navigated: a dropped link is still a place to visit")
    }

    /// **How WebKit's answer evolves.** The answer to the first ask and the answer after the page has
    /// been consulted are not the same thing — the page is in another process — and a rule built on the
    /// first one is a rule built on a guess. This records the whole sequence for each case.
    func testHowWebKitsAnswerSettles() async throws {
        page.dropFallback = nil
        let cases: [(String, NSPoint, WebDrag.Payload)] = [
            ("custom-over-zone", zone, .custom),
            ("url-link-over-plain", plain, .linkAsURL),
            ("url-link-over-zone", zone, .linkAsURL),
            ("custom-over-plain", plain, .custom),
        ]
        for (what, point, payload) in cases {
            let drag = WebDrag(at: page.convert(point, to: nil), in: window, carrying: payload)
            var answers = [page.draggingEntered(drag).rawValue]
            for _ in 0..<9 {
                try await settle()
                answers.append(page.draggingUpdated(drag).rawValue)
            }
            print("SETTLES \(what) \(answers)")
            page.draggingExited(drag)
            try await settle()
        }
    }

    // MARK: Driving

    private func press(at point: NSPoint) { post(.leftMouseDown, at: point) }
    private func release(at point: NSPoint) { post(.leftMouseUp, at: point) }

    private func drag(to point: NSPoint, steps: Int, pumping: Bool = true) {
        guard steps > 0 else { return }
        let from = lastPoint
        for step in 1...steps {
            let ratio = Double(step) / Double(steps)
            post(.leftMouseDragged, at: NSPoint(x: from.x + (point.x - from.x) * ratio,
                                                y: from.y + (point.y - from.y) * ratio),
                 pumping: pumping)
        }
    }

    private var lastPoint: NSPoint = .zero

    private func post(_ type: NSEvent.EventType, at point: NSPoint, pumping: Bool = true) {
        lastPoint = point
        let inWindow = page.convert(point, to: nil)
        guard let event = NSEvent.mouseEvent(with: type, location: inWindow, modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil,
                                             eventNumber: 0, clickCount: 1,
                                             pressure: type == .leftMouseUp ? 0 : 1) else {
            return XCTFail("could not make a \(type) event")
        }
        HeldButtons.mask = type == .leftMouseUp ? 0 : 1
        switch type {
        case .leftMouseDown: page.mouseDown(with: event)
        case .leftMouseDragged: page.mouseDragged(with: event)
        default: page.mouseUp(with: event)
        }
        if pumping { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    }

    // MARK: Asking

    private func counts() async throws -> [String: Int] {
        try await settle()
        let answer = try await page.evaluateJavaScript("JSON.stringify(window.seen)") as? String
        let data = (answer ?? "{}").data(using: .utf8) ?? Data()
        let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return raw.compactMapValues { $0 as? Int }
    }

    private func order() async throws -> String {
        (try await page.evaluateJavaScript("window.order()")) as? String ?? "?"
    }

    private func settle() async throws {
        for _ in 0..<5 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            await Task.yield()
        }
    }

    private func until(_ what: String, timeout: TimeInterval = 5, _ done: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !(await done()) {
            guard Date() < deadline else {
                XCTFail("timed out waiting for \(what)")
                throw CancellationError()
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }
}

/// **The buttons the page hears are down are the real mouse's, not the event's.** WebKit fills in a
/// mouse event's `buttons` from `NSEvent.pressedMouseButtons` — the hardware, whatever the event being
/// delivered says — and a `mouseup` while a button is still down is a chorded release, which the page
/// hears as a `pointermove` rather than a `pointerup`. So a run with someone clicking alongside it
/// loses its `pointerup` whenever a real click happens to be down at the release.
///
/// Stood in for while these tests run, so the page hears the buttons the posted events hold: down from
/// a press until its release, whatever anyone is doing with the real mouse.
private enum HeldButtons {
    nonisolated(unsafe) static var mask = 0
    private nonisolated(unsafe) static var standing = false

    static func stand(in on: Bool) {
        guard on != standing,
              let real = class_getClassMethod(NSEvent.self, #selector(getter: NSEvent.pressedMouseButtons)),
              let ours = class_getClassMethod(NSEvent.self, #selector(getter: NSEvent.pmHeldButtons)) else { return }
        method_exchangeImplementations(real, ours)
        standing = on
        mask = 0
    }
}

private extension NSEvent {
    @objc class var pmHeldButtons: Int { HeldButtons.mask }
}

/// A board that only says what it was asked.
private final class DragRecorder: NSView {
    var calls: [String] = []
    /// What each drag the board was offered was carrying, and where it came from — the two facts a
    /// source-based or payload-based rule would be built on.
    var notes: [String] = []
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        calls.append("entered")
        let types = (sender.draggingPasteboard.types ?? []).map(\.rawValue).joined(separator: ",")
        let source = sender.draggingSource.map { "\(type(of: $0))" } ?? "nil"
        notes.append("types=[\(types)] source=\(source)")
        return .copy
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { calls.append("updated"); return .copy }
    override func draggingExited(_ sender: NSDraggingInfo?) { calls.append("exited") }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { calls.append("performed"); return true }
}

/// A drag carrying either a link, or what a page's own script would have put on one: text plus the
/// custom type WebKit maps a `DataTransfer` entry to.
private final class WebDrag: NSObject, NSDraggingInfo {
    var draggingLocation: NSPoint
    let window: NSWindow
    let draggingPasteboard: NSPasteboard

    enum Payload {
        /// What a page's own script puts on a drag: WebKit's custom data, and nothing a board reads.
        case custom
        /// A link spelled as strings, which is how PM's own `dragLink` writes one.
        case linkAsStrings
        /// A link written as a real `NSURL`, which is how a browser writes one.
        case linkAsURL
    }

    init(at point: NSPoint, in window: NSWindow, carrying payload: Payload) {
        draggingLocation = point
        self.window = window
        draggingPasteboard = NSPasteboard.withUniqueName()
        draggingPasteboard.clearContents()
        switch payload {
        case .custom:
            let item = NSPasteboardItem()
            item.setString("grabbed", forType: .string)
            item.setString("grabbed", forType: NSPasteboard.PasteboardType("org.w3c.web-custom-data"))
            draggingPasteboard.writeObjects([item])
        case .linkAsStrings:
            let item = NSPasteboardItem()
            item.setString("https://x.dev/a", forType: .URL)
            item.setString("https://x.dev/a", forType: .string)
            draggingPasteboard.writeObjects([item])
        case .linkAsURL:
            draggingPasteboard.writeObjects([URL(string: "https://x.dev/a")! as NSURL])
        }
    }

    deinit { draggingPasteboard.releaseGlobally() }

    var draggingDestinationWindow: NSWindow? { window }
    var draggingSourceOperationMask: NSDragOperation { [.copy, .move, .generic] }
    var draggedImageLocation: NSPoint { draggingLocation }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 2 }
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
