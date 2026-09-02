import XCTest
import AppKit

/// What counts as clicking *outside* an open editor.
///
/// The monitor dismisses the editor and swallows the mouse-down, which makes a false positive
/// expensive twice over: the editor closes and the click it ate never happens. The frame an editor
/// reports is only its own pane, so with the sidebar showing, the window's own chrome — the titlebar
/// strip above the sidebar, the left resize edge — lies outside the content column and used to read as
/// a dismissal. Reaching for a window to move it would close the session note and leave the window
/// exactly where it was.
@MainActor
final class OutsideClickTests: XCTestCase {

    /// A project window: content run up under a transparent titlebar, sidebar on the left, the editor
    /// filling the content column beside it.
    private let sidebarWidth: CGFloat = 220
    private var window: NSWindow!
    private var monitor: OutsideClickMonitor!
    private var dismissals = 0

    override func setUp() {
        super.setUp()
        TestApp.start()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable,
                                      .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.makeKeyAndOrderFront(nil)

        dismissals = 0
        monitor = OutsideClickMonitor()
        monitor.window = window
        monitor.onOutsideClick = { [weak self] in self?.dismissals += 1 }
        // As `reportEditorFrame` publishes it: SwiftUI global space, top-left origin, covering the
        // content column beside the sidebar.
        monitor.editorFrame = CGRect(x: sidebarWidth, y: 0,
                                     width: window.frame.width - sidebarWidth,
                                     height: window.frame.height)
        monitor.start()
    }

    override func tearDown() {
        monitor.stop()
        window.orderOut(nil)
        super.tearDown()
    }

    /// The strip you grab to move the window, on the sidebar's side of the divider.
    func testGrabbingTheTitlebarAboveTheSidebarDoesNotDismiss() {
        let titlebarHeight = window.frame.height - window.contentLayoutRect.maxY
        XCTAssertGreaterThan(titlebarHeight, 0, "no titlebar strip to test with")
        click(at: NSPoint(x: 120, y: window.frame.height - titlebarHeight / 2))
        XCTAssertEqual(dismissals, 0, "moving the window closed the editor")
    }

    /// The left resize edge, which is also over the sidebar.
    func testGrabbingTheResizeEdgeDoesNotDismiss() {
        click(at: NSPoint(x: 1, y: 300))
        XCTAssertEqual(dismissals, 0, "resizing the window closed the editor")
    }

    /// The sidebar proper still dismisses — that's the behaviour the monitor exists for, and a fix
    /// that stopped it would be a fix that turned the monitor off.
    func testClickingTheSidebarStillDismisses() {
        click(at: NSPoint(x: 120, y: 300))
        XCTAssertEqual(dismissals, 1, "a click on the sidebar no longer leaves the editor")
    }

    /// And a click on the editor itself never did.
    func testClickingInsideTheEditorDoesNotDismiss() {
        click(at: NSPoint(x: sidebarWidth + 200, y: 300))
        XCTAssertEqual(dismissals, 0)
    }

    /// Local monitors run from `sendEvent`, so the event has to go through `NSApp` rather than to the
    /// window directly.
    private func click(at pointInWindow: NSPoint) {
        guard let down = NSEvent.mouseEvent(with: .leftMouseDown, location: pointInWindow,
                                            modifierFlags: [], timestamp: 0,
                                            windowNumber: window.windowNumber, context: nil,
                                            eventNumber: 0, clickCount: 1, pressure: 1)
        else { return XCTFail("could not build a mouse-down") }
        NSApp.sendEvent(down)
    }
}
