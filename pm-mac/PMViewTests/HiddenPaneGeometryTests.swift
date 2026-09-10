import XCTest
import AppKit

/// **A tab you are not looking at is a pane with a size and nothing to lay out into.**
///
/// A project window keeps every tab's pane mounted and hides the ones that are not up — see
/// `ProjectContentPane.show`. Auto Layout goes on resizing a hidden pane, so it goes on getting the
/// frame-change notifications a visible one gets, and `CanvasScrollView.clipResized` answers them by
/// re-tiling. What it re-tiles *into* is `CanvasBoardView.tileableRect`, which is built from
/// `visibleRect` — and that is the thing a hidden view stops reporting.
///
/// So every window resize reached the workspaces you were not in and laid their tiles out into an
/// empty rectangle, which `tileableRect` floors at 80×80 somewhere off the board. Switching to one
/// showed a board with no tiles on it until you resized the window, which ran the same code again with
/// a real rectangle. `retileForWindowSize` now declines while there is nothing to fill, and
/// `CanvasPaneController.paneBecameVisible` runs it when the pane comes back.
///
/// This pins the AppKit half of that — the pair of facts the guard rests on, which are not obvious and
/// are the reason a size was mistaken for a place to lay things out.
@MainActor
final class HiddenPaneGeometryTests: XCTestCase {

    private var window: NSWindow!

    override func setUp() {
        super.setUp()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.orderFront(nil)
    }

    override func tearDown() {
        window?.orderOut(nil)
        window = nil
        super.tearDown()
    }

    /// Two panes mounted the way a project window mounts its tabs: both pinned to the container, one
    /// hidden.
    private func mountTwoPanes() -> (shown: NSView, hidden: NSView) {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        window.contentView = container
        let panes = (0..<2).map { _ -> NSView in
            let pane = NSView()
            pane.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(pane)
            NSLayoutConstraint.activate([
                pane.topAnchor.constraint(equalTo: container.topAnchor),
                pane.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                pane.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                pane.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
            return pane
        }
        panes[1].isHidden = true
        window.layoutIfNeeded()
        return (panes[0], panes[1])
    }

    /// **The fact the bug was built on:** hidden, a pane still has the window's size and reports no
    /// visible rectangle at all. A resize handler that reads one and trusts the other is laying things
    /// out into nowhere.
    func testAHiddenPaneKeepsItsSizeAndLosesItsVisibleRect() {
        let (shown, hidden) = mountTwoPanes()

        XCTAssertEqual(hidden.frame.size, shown.frame.size,
                       "a hidden pane is still laid out to the container")
        XCTAssertFalse(shown.visibleRect.isEmpty)
        XCTAssertTrue(hidden.visibleRect.isEmpty,
                      "a hidden pane has no visible rectangle — which is what tileableRect is built from")
    }

    /// **And it goes on being resized while hidden**, which is why the resize handler runs at all on a
    /// tab nobody is looking at. The frame follows the window; the visible rectangle stays empty.
    func testAHiddenPaneIsStillResizedWithTheWindow() {
        let (_, hidden) = mountTwoPanes()
        var resizes = 0
        hidden.postsFrameChangedNotifications = true
        let token = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: hidden, queue: nil) { _ in resizes += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        window.setContentSize(NSSize(width: 900, height: 500))
        window.layoutIfNeeded()

        XCTAssertEqual(hidden.frame.width, 900, "the hidden pane followed the window")
        XCTAssertGreaterThan(resizes, 0, "and said so, which is what triggers the re-tile")
        XCTAssertTrue(hidden.visibleRect.isEmpty,
                      "with still nowhere to lay anything out — the state the guard now declines")
    }

    /// The negative control: unhidden, the same pane reports the region the tiles are meant to fill.
    /// Without this the two tests above would pass on a view that was simply never laid out.
    func testShowingThePaneGivesTheRegionBack() {
        let (_, hidden) = mountTwoPanes()
        hidden.isHidden = false
        window.layoutIfNeeded()

        XCTAssertFalse(hidden.visibleRect.isEmpty)
        XCTAssertEqual(hidden.visibleRect.width, hidden.frame.width)
    }
}
