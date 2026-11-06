import XCTest
@testable import PMViewTests

/// A sidebar row closes on a middle-click (`MiddleClickArea`). The view takes no hits, so what is
/// asserted is its decision: a middle release inside it fires, anything else doesn't. (The monitor that
/// calls it is two lines; `NSEvent(cgEvent:)` loses the window, so a posted event can't reach it.)
@MainActor
final class MiddleClickTests: XCTestCase {
    private var window: NSWindow!
    private var view: MiddleClickView!
    private var fired = 0

    override func setUpWithError() throws {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled],
                          backing: .buffered, defer: false)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        window.contentView = content
        view = MiddleClickView(frame: NSRect(x: 0, y: 100, width: 300, height: 32))
        view.action = { [unowned self] in fired += 1 }
        content.addSubview(view)
    }

    override func tearDown() { window = nil; view = nil }

    private func release(_ button: Int, atY y: CGFloat, in target: NSWindow? = nil) {
        _ = view.handle(button: button, in: target ?? window, at: NSPoint(x: 50, y: y))
    }

    func testMiddleReleaseInsideFires() {
        release(2, atY: 110)
        XCTAssertEqual(fired, 1)
    }

    func testMiddleReleaseOutsideDoesNotFire() {
        release(2, atY: 20)
        XCTAssertEqual(fired, 0)
    }

    func testOtherButtonsDoNotFire() {
        release(0, atY: 110); release(1, atY: 110); release(3, atY: 110)
        XCTAssertEqual(fired, 0)
    }

    func testAnotherWindowDoesNotFire() {
        let other = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        release(2, atY: 110, in: other)
        XCTAssertEqual(fired, 0)
    }

    func testDisabledDoesNotFire() {
        view.enabled = false
        release(2, atY: 110)
        XCTAssertEqual(fired, 0)
    }
}
