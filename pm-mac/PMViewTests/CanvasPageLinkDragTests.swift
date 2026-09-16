import XCTest
import AppKit
import WebKit

/// **A link dragged out of a page is written to the drag pasteboard after the drag has begun** — for
/// backlog 42, where the second link dragged off a web card made a card of the first.
///
/// The drag pasteboard is shared, and keeps the last drag's contents until something writes over them.
/// WebKit starts a link's drag from the press and then writes the link from the web process, clearing
/// the pasteboard and writing it again over the next few hundredths of a second. A destination asked
/// in that window reads the previous link, or nothing. The board is asked in that window whenever the
/// drag starts on a page, since the pointer is over the board from the start, and it used to read once
/// on the way in and keep what it read. `CanvasDropSession.pasteboardChange` is how it reads again.
///
/// Sampled rather than caught at the moment a destination is asked: a hostless app is never active, so
/// AppKit never asks a destination here. What can be measured is the pasteboard itself, every
/// millisecond, while a real drag started by a real page runs.
@MainActor
final class CanvasPageLinkDragTests: XCTestCase {
    private var window: NSWindow!
    private var page: CanvasPageView!

    private static let html = """
        <html><body style="margin:0;font:16px system-ui">
        <a href="https://one.example/first" style="position:absolute;left:20px;top:20px;display:block;width:200px;height:40px">first</a>
        <a href="https://two.example/second" style="position:absolute;left:20px;top:120px;display:block;width:200px;height:40px">second</a>
        <script>window.ready = true;</script>
        </body></html>
        """

    override func setUp() async throws {
        try await super.setUp()
        TestApp.start()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                          styleMask: [.titled], backing: .buffered, defer: false)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        page = CanvasPageView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), configuration: configuration)
        window.contentView = page
        window.makeKeyAndOrderFront(nil)
        page.loadHTMLString(Self.html, baseURL: URL(string: "https://page.invalid/"))
        let deadline = Date().addingTimeInterval(5)
        while (try? await page.evaluateJavaScript("window.ready === true")) as? Bool != true {
            guard Date() < deadline else { return XCTFail("the page never loaded") }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }

    override func tearDown() async throws {
        window?.orderOut(nil)
        try await super.tearDown()
    }

    func testTheSecondLinksDragStartsOnTheFirstLinksPasteboard() {
        let first = dragLink(from: NSPoint(x: 100, y: 40))
        XCTAssertEqual(first.last?.url, "https://one.example/first", "the first drag never wrote its link")

        let second = dragLink(from: NSPoint(x: 100, y: 140))
        XCTAssertEqual(second.first?.url, "https://one.example/first",
                       "the premise: a drag begins on the pasteboard the last one left")
        XCTAssertEqual(second.last?.url, "https://two.example/second", "the second drag never wrote its link")
        let states = Set(second.map(\.change)).count
        XCTAssertGreaterThan(states, 2,
                             "the link was written once, before anything could ask: \(second)")
    }

    private struct Sample: Equatable {
        let change: Int
        let url: String?
    }

    /// Press on a link, drag it well away, let go, and say every state the drag pasteboard went through.
    private func dragLink(from: NSPoint) -> [Sample] {
        var samples: [Sample] = []
        func sample() {
            let pasteboard = NSPasteboard(name: .drag)
            let url = (pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL])?.first?.absoluteString
            let now = Sample(change: pasteboard.changeCount, url: url)
            if samples.last != now { samples.append(now) }
        }
        sample()
        let sampler = Timer(timeInterval: 0.001, repeats: true) { _ in MainActor.assumeIsolated { sample() } }
        RunLoop.main.add(sampler, forMode: .common)
        defer { sampler.invalidate() }

        let to = NSPoint(x: 450, y: 300)
        post(.leftMouseDown, at: from)
        for step in 1...8 {
            let ratio = Double(step) / 8
            // Not pumped: the drag's tracking loop is entered from the run loop, and turning it here would
            // enter it with nothing queued to end it. See `seeOutAnyTrackingLoop`.
            post(.leftMouseDragged, at: NSPoint(x: from.x + (to.x - from.x) * ratio,
                                                y: from.y + (to.y - from.y) * ratio))
        }
        seeOutAnyTrackingLoop(in: window, at: page.convert(to, to: nil), for: 1.5)
        for _ in 0..<10 { RunLoop.current.run(until: Date().addingTimeInterval(0.03)) }
        return samples
    }

    private func post(_ type: NSEvent.EventType, at point: NSPoint) {
        guard let event = NSEvent.mouseEvent(with: type, location: page.convert(point, to: nil),
                                             modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                             clickCount: 1, pressure: 1) else {
            return XCTFail("could not make a \(type) event")
        }
        type == .leftMouseDown ? page.mouseDown(with: event) : page.mouseDragged(with: event)
    }
}
