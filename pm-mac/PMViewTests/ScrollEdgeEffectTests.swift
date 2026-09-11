import XCTest
import AppKit

/// **Why the board draws its own soft edge** — docs/header-chrome.md P5.
///
/// The spec wanted the system's. A scroll view under this window's titlebar does get AppKit's edge
/// view — an `NSScrollPocket` exactly the height of the band the header floats in, with a soft layer
/// (`PocketBlur`, `PocketMask`) and a hard one (`NSHardPocketView`) inside it — but in this window it
/// never switches on. Measured on 2026-09-10, both layers stayed hidden at zero size with the titlebar
/// drawn or transparent, with or without a split-item accessory asking for the soft style, and with or
/// without items in the toolbar. The accessory, the one supported way to ask for a style, also added a
/// strip *below* the titlebar and took clicks; drawing the titlebar sent clicks in the band to the
/// titlebar rather than the board.
///
/// So `CanvasEdgeView` draws it. This keeps the evidence: if AppKit ever starts drawing the pocket for
/// this window, the test fails and the board can go back to the system's edge.
///
/// A window built the way `ProjectWindowController` builds one — full-size content, transparent
/// titlebar, hidden title, the empty unified toolbar — around a split item the way
/// `ProjectSplitViewController` builds the content pane, holding a scroll view set up like
/// `CanvasScrollView`.
@MainActor
final class ScrollEdgeEffectTests: XCTestCase {
    private var window: NSWindow!
    private var scroll: NSScrollView!

    override func tearDown() {
        window?.orderOut(nil)
        super.tearDown()
    }

    func testTheSystemEdgeStaysOffInThisWindow() throws {
        try open()
        let layers = pocketLayers()
        print("DIAG pocket: \(layers.isEmpty ? "none" : layers.map(\.description).joined(separator: " | "))")
        let drawing = layers.filter { $0.name != "NSScrollPocket" && $0.drawing }
        XCTAssertTrue(drawing.isEmpty,
                      "AppKit is drawing its own edge under this window's titlebar now — "
                          + "`CanvasEdgeView` may be able to give way to it (docs/header-chrome.md P5)")

        // And the band is still the board's: a click between the islands lands on it.
        let frame = try XCTUnwrap(window.contentView?.superview)
        let inBand = NSPoint(x: 500, y: window.frame.height - 30)
        let hit = frame.hitTest(frame.convert(inBand, from: nil))
        XCTAssertTrue(hit.map { $0.isDescendant(of: scroll) } ?? false,
                      "a click in the titlebar band no longer reaches the board")
    }

    // MARK: Building it

    private func open() throws {
        TestApp.start()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600),
                          styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        let toolbar = NSToolbar(identifier: "ScrollEdgeEffectTests")
        toolbar.allowsUserCustomization = false
        toolbar.showsBaselineSeparator = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified

        let pane = NSViewController()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 600))
        scroll = NSScrollView()
        scroll.drawsBackground = true
        scroll.backgroundColor = .windowBackgroundColor
        scroll.automaticallyAdjustsContentInsets = false
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 3000, height: 3000))
        document.wantsLayer = true
        document.layer?.backgroundColor = NSColor.systemTeal.withAlphaComponent(0.3).cgColor
        scroll.documentView = document
        scroll.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: container.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        pane.view = container

        let split = NSSplitViewController()
        let item = NSSplitViewItem(viewController: pane)
        item.allowsFullHeightLayout = true
        item.titlebarSeparatorStyle = .none
        item.automaticallyAdjustsSafeAreaInsets = true
        split.addSplitViewItem(item)
        window.contentViewController = split
        window.setContentSize(NSSize(width: 1000, height: 600))
        window.makeKeyAndOrderFront(nil)
        // Scrolled a little, so there is unambiguously content under the band.
        document.scroll(NSPoint(x: 400, y: 1400))
        settle(1.0)
    }

    private struct Layer: CustomStringConvertible {
        let name: String
        let frame: CGRect
        let hidden: Bool
        var drawing: Bool { !hidden && frame.width > 0 && frame.height > 0 }
        var description: String {
            "\(name) " + String(format: "w%.0f h%.0f %@", frame.width, frame.height, drawing ? "drawing" : "off")
        }
    }

    private func pocketLayers() -> [Layer] {
        var found: [Layer] = []
        func walk(_ view: NSView) {
            let name = String(describing: type(of: view))
            if name.lowercased().contains("pocket") {
                found.append(Layer(name: name, frame: view.convert(view.bounds, to: nil),
                                   hidden: view.isHiddenOrHasHiddenAncestor))
            }
            view.subviews.forEach(walk)
        }
        if let frame = window.contentView?.superview { walk(frame) }
        return found
    }

    private func settle(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        window.contentView?.layoutSubtreeIfNeeded()
    }
}
