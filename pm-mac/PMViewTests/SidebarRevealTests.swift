import XCTest
import AppKit
import SwiftUI

/// **A sidebar collapsed without animation can't be shown with it.**
///
/// Only a session's first project window opens with its sidebar; the rest open with it collapsed,
/// set directly in `ProjectSplitViewController.viewDidLoad`, and the auto-hide collapses it the same
/// way, as does dragging the divider to the edge. Showing the sidebar from there through the animated `toggleSidebar` leaves the item expanded
/// and its pane zero points wide — the window's only visible change is the task column moving over by
/// its safe-area inset. `ProjectSplitViewController.collapsedByToggle` shows it without animation
/// instead, unless the animated toggle is what hid it.
///
/// A model of the split view rather than the controller, which won't compile alone: the same items,
/// thicknesses, priorities and collapse behaviour.
@MainActor
final class SidebarRevealTests: XCTestCase {

    private final class Split: NSSplitViewController {
        let startsWithSidebar: Bool
        var sidebarItem: NSSplitViewItem!

        init(startsWithSidebar: Bool) {
            self.startsWithSidebar = startsWithSidebar
            super.init(nibName: nil, bundle: nil)
        }
        required init?(coder: NSCoder) { fatalError() }

        override func viewDidLoad() {
            super.viewDidLoad()
            let side = NSHostingController(rootView: List { Text("a"); Text("b") })
            side.sizingOptions = [.minSize]
            let content = NSHostingController(rootView: Color.gray)
            for view in [side.view, content.view] {
                view.setContentHuggingPriority(.defaultLow, for: .horizontal)
                view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            }
            sidebarItem = NSSplitViewItem(sidebarWithViewController: side)
            sidebarItem.minimumThickness = 180
            sidebarItem.maximumThickness = 360
            sidebarItem.canCollapse = true
            sidebarItem.holdingPriority = .defaultLow + 1
            sidebarItem.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
            let contentItem = NSSplitViewItem(viewController: content)
            contentItem.minimumThickness = 420
            contentItem.canCollapse = false
            contentItem.holdingPriority = .defaultLow
            for item in [sidebarItem!, contentItem] {
                item.allowsFullHeightLayout = true
                item.titlebarSeparatorStyle = .none
            }
            contentItem.automaticallyAdjustsSafeAreaInsets = true
            addSplitViewItem(sidebarItem)
            addSplitViewItem(contentItem)
            splitView.dividerStyle = .thin
            sidebarItem.isCollapsed = !startsWithSidebar
        }

        var sidebarWidth: CGFloat { splitView.arrangedSubviews[0].frame.width }
    }

    private var windows: [NSWindow] = []

    override func tearDown() {
        windows.forEach { $0.orderOut(nil) }
        windows = []
        super.tearDown()
    }

    private func open(startsWithSidebar: Bool) -> Split {
        TestApp.start()
        let split = Split(startsWithSidebar: startsWithSidebar)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1000, height: 700),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.contentViewController = split
        window.makeKeyAndOrderFront(nil)
        window.setFrame(NSRect(x: 100, y: 100, width: 1000, height: 700), display: true)
        windows.append(window)
        turn()
        return split
    }

    private func turn(_ seconds: TimeInterval = 0.8) {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(seconds))
    }

    /// The defect, so the workaround can be dropped the day AppKit stops needing it.
    func testAnAnimatedRevealOfAWindowOpenedWithoutTheSidebarIsZeroWide() {
        let split = open(startsWithSidebar: false)
        split.toggleSidebar(nil)
        turn()
        XCTAssertFalse(split.sidebarItem.isCollapsed)
        XCTAssertEqual(split.sidebarWidth, 0, "AppKit shows this sidebar now — `collapsedByToggle` can go")
    }

    func testTheAutoHideShapeIsTheSame() {
        let split = open(startsWithSidebar: true)
        split.sidebarItem.isCollapsed = true
        turn()
        split.toggleSidebar(nil)
        turn()
        XCTAssertEqual(split.sidebarWidth, 0, "AppKit shows this sidebar now — `collapsedByToggle` can go")
    }

    /// The workaround: shown directly once, and animated both ways from then on.
    func testADirectRevealShowsItAndAnimationWorksAfter() {
        let split = open(startsWithSidebar: false)
        split.sidebarItem.isCollapsed = false
        turn()
        XCTAssertGreaterThanOrEqual(split.sidebarWidth, 180)
        split.toggleSidebar(nil)
        turn()
        XCTAssertTrue(split.sidebarItem.isCollapsed)
        split.toggleSidebar(nil)
        turn()
        XCTAssertGreaterThanOrEqual(split.sidebarWidth, 180)
    }

    func testDraggingTheDividerToTheEdgeIsTheSame() {
        let split = open(startsWithSidebar: true)
        split.splitView.setPosition(0, ofDividerAt: 0)
        turn()
        XCTAssertTrue(split.sidebarItem.isCollapsed)
        split.toggleSidebar(nil)
        turn()
        XCTAssertEqual(split.sidebarWidth, 0, "AppKit shows this sidebar now — `collapsedByToggle` can go")
    }

    /// The control: hidden by the animated toggle, it animates back at its width.
    func testATogglesOwnCollapseRevealsAnimated() {
        let split = open(startsWithSidebar: true)
        split.toggleSidebar(nil)
        turn()
        split.toggleSidebar(nil)
        turn()
        XCTAssertGreaterThanOrEqual(split.sidebarWidth, 180)
    }
}
