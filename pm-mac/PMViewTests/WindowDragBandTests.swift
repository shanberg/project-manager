import XCTest
import AppKit
import SwiftUI

/// **What a mouse-down in the titlebar band lands on** — canvas-backlog.md 22, where dragging a tab at
/// the top of a tile and pressing the board's options menu both moved the window instead.
///
/// The project window runs its content under a transparent titlebar (`ProjectWindowController`), so the
/// top of the board is also the band AppKit reads a window drag out of. Which of the two a press means
/// is settled by `mouseDownCanMoveWindow`, and the bug was that several views up there answered it
/// wrong for reasons that are not guessable — so these state the mechanism as much as they guard the
/// fix, and each says what it would mean if it ever failed.
@MainActor
final class WindowDragBandTests: XCTestCase {

    // MARK: The rule AppKit actually applies

    /// **A view that overrides nothing hands presses to the window.** `CanvasBoardView` overrides
    /// nothing, which is why the strips over its tab bars have to carve themselves out one by one
    /// (`CanvasTileHandleView.refreshStripExcluders`) rather than the board simply saying no.
    func testAPlainViewAnswersTrue() {
        XCTAssertTrue(NSView().mouseDownCanMoveWindow,
                      "NSView's default has changed — a view that overrides nothing no longer offers "
                          + "itself to the window drag, and the carve-outs may be unnecessary")
    }

    /// **A subview answering no carves its own frame out of a superview answering yes**, and only its
    /// frame. This is the whole mechanism the tab strips lean on: the board goes on offering the empty
    /// band as somewhere to grab the window, and one small view over each strip takes back the part of
    /// it that is a control.
    func testASubviewCarvesOnlyItsOwnFrameOutOfItsParent() throws {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let carve = CarvingView(frame: NSRect(x: 40, y: 0, width: 60, height: 100))
        host.addSubview(carve)
        XCTAssertEqual(try dragging(across: host, over: host.bounds),
                       ["NSView"],
                       "a subview answering no no longer carves itself out of a parent answering yes, "
                           + "or has started carving out more than its frame")
        XCTAssertEqual(try dragging(across: host, over: carve.frame), [],
                       "the carve-out itself has started handing presses to the window")
    }

    // MARK: How deep the band reaches into the board

    /// **How far down the board the band reaches**, which is what decides whether this bug can touch a
    /// tile at all.
    ///
    /// The project window wears an empty unified toolbar purely for its metrics, and that is the taller
    /// titlebar — deeper than the 28pt a plain one gives. Printed rather than pinned to a number,
    /// because it is the system's to choose; what is asserted is that it reaches past `headerClearance`,
    /// where a workspace's tiles and their tab strips begin.
    func testTheBandReachesPastWhereTilesBegin() throws {
        let window = projectShapedWindow()
        let content = try XCTUnwrap(window.contentView)
        let band = content.bounds.height - window.contentLayoutRect.height
        print("DIAG titlebar band: \(band)pt; tiles begin at \(tilesBegin)pt, "
              + "so \(band - tilesBegin)pt of a \(tabStripHeight)pt tab strip is inside it")
        XCTAssertGreaterThan(band, tilesBegin,
                             "the titlebar band no longer reaches the tiles — a press on a tab strip "
                                 + "is out of the window drag's way by geometry alone, and the "
                                 + "carve-outs could go")
    }

    /// Where a workspace's first row of tiles starts: `CanvasBoardView.headerClearance` plus
    /// `CanvasTiling.edgeGap`, which is also exactly `CanvasSoftEdge.band` — the board's soft edge
    /// ends where the tiles begin, by construction. That flushness matters to the fix as well as to
    /// the drawing: the edge view is a sibling in front of the whole scroll view and answers the window
    /// drag with *true*, so a strip reaching even a point above this line would have the drag put back
    /// over it by something the board cannot carve out from inside.
    private let tilesBegin: CGFloat = 40 + 6
    /// `CanvasTiling.tabStrip`. Kept beside the test that reads it, since this target does not compile
    /// the files these come from and a change to either should fail here rather than drift quietly.
    private let tabStripHeight: CGFloat = 32

    // MARK: What SwiftUI puts in front of an excluder

    /// **A `Menu` defeats an excluder that is only a background**, which is what the header's capsules
    /// had and why the options menu in the top-right corner moved the window.
    ///
    /// A capsule of text and symbols contains no real AppKit views at all, so a background excluder was
    /// the frontmost view everywhere and the arrangement looked sound. A `Menu` is real — SwiftUI backs
    /// it with `_NSGraphicsView`s and a `_FocusRingView`, drawn in front, every one answering yes.
    func testAMenuDefeatsABackgroundExcluder() throws {
        let host = try open(BackgroundOnly())
        // Over the excluder's own frame, like the capsule tests: a hosting view is wider than the
        // content inside it and answers yes in the margin, which would pass this test without a menu
        // being involved at all.
        let dragging = try dragging(across: host, over: capsuleFrame(in: host))
        print("DIAG background-only + Menu, presses that move the window: \(dragging)")
        XCTAssertFalse(dragging.isEmpty,
                       "a Menu no longer draws a window-dragging view over a background excluder — "
                           + "HeaderCapsule's overlay may be unnecessary")
        XCTAssertFalse(dragging.contains("NSHostingView<AnyView>"),
                       "this is measuring the hosting view's margin rather than the menu")
    }

    /// **The real `HeaderCapsule` with a menu in it takes every press**, which is the fix: an overlay
    /// as well as a background, last in the capsule and so in front of whatever a control brought with
    /// it.
    func testTheHeaderCapsuleTakesEveryPressOnAMenu() throws {
        let host = try open(Capsule_(content: .menu))
        let dragging = try dragging(across: host, over: capsuleFrame(in: host))
        XCTAssertEqual(dragging, [],
                       "pressing a menu in a header capsule moves the window again: \(dragging)")
    }

    /// **And with a scrolling row of controls in it**, which is the other real AppKit view a capsule
    /// holds — `ProjectTabBar`'s chips, whose own drags were the first casualty of this.
    func testTheHeaderCapsuleTakesEveryPressOnAScrollingRow() throws {
        let host = try open(Capsule_(content: .scroller))
        let dragging = try dragging(across: host, over: capsuleFrame(in: host))
        XCTAssertEqual(dragging, [],
                       "dragging a chip in a scrolling header capsule moves the window again: "
                           + "\(dragging)")
    }

    // MARK: The shapes under test

    private struct Capsule_: View {
        enum Content { case plain, menu, scroller }
        let content: Content

        var body: some View {
            HeaderCapsule(chrome: .active, glass: "diag") {
                Text("Board")
                switch content {
                case .plain:
                    EmptyView()
                case .menu:
                    Menu { Button("Something") {} } label: { Image(systemName: "ellipsis") }
                case .scroller:
                    ScrollView(.horizontal) {
                        HStack { ForEach(0..<4, id: \.self) { i in Button("Tab \(i)") {} } }
                    }
                    .frame(width: 140)
                }
            }
        }
    }

    /// The capsule as it was before the fix: an excluder behind the contents and nothing over them.
    private struct BackgroundOnly: View {
        var body: some View {
            HStack {
                Text("Board")
                Menu { Button("Something") {} } label: { Image(systemName: "ellipsis") }
            }
            .padding(6)
            .background(WindowDragExcluder())
        }
    }

    // MARK: Pressing things

    /// Press along the middle of `strip` and report, by class, every view a press would land on that
    /// hands the event to the window instead.
    ///
    /// **Frontmost view containing the point, not `hitTest`.** The obvious reading — ask the window
    /// what a click lands on — says an excluder never works at all: `NSHostingView` answers its own hit
    /// tests for everything SwiftUI draws, so the excluder inside one is never returned, and the header
    /// would be undraggable-proof nowhere. It plainly does work, so the window drag is decided the
    /// other way: AppKit builds a region out of the view tree, in z-order, where a view answering no
    /// carves its frame out and a view in front of it answering yes puts that frame back. Which is also
    /// the only reading under which an *overlay* fixes anything a *background* could not.
    private func dragging(across host: NSView, over strip: NSRect) throws -> Set<String> {
        var found: Set<String> = []
        for x in stride(from: strip.minX + 1, to: strip.maxX - 1, by: 2) {
            let point = NSPoint(x: x, y: strip.midY)
            guard let front = frontmostView(at: point, in: host, from: host),
                  front.mouseDownCanMoveWindow else { continue }
            found.insert(String(describing: type(of: front)))
        }
        return found
    }

    /// The last view in back-to-front order whose frame contains the point — AppKit's rule above,
    /// modelled as plainly as it can be stated.
    private func frontmostView(at point: NSPoint, in view: NSView, from host: NSView) -> NSView? {
        guard view.convert(view.bounds, to: host).contains(point) else { return nil }
        var front: NSView = view
        for child in view.subviews {
            if let deeper = frontmostView(at: point, in: child, from: host) { front = deeper }
        }
        return front
    }

    /// Where the capsule is: its `WindowDragExcluder`'s frame. A hosting view is wider than the glass
    /// inside it and answers yes in the margin, so pressing its full width would only ever measure the
    /// margin. The same handle `HeaderChromeMotionTests` reads capsules by.
    private func capsuleFrame(in host: NSView) throws -> NSRect {
        try XCTUnwrap(excluderFrame(in: host, relativeTo: host),
                      "the capsule never built its WindowDragExcluder")
    }

    private func excluderFrame(in view: NSView, relativeTo host: NSView) -> NSRect? {
        if view is WindowDragExcluder.ExcluderView { return view.convert(view.bounds, to: host) }
        for child in view.subviews {
            if let found = excluderFrame(in: child, relativeTo: host) { return found }
        }
        return nil
    }

    // MARK: Standing things up

    /// A window with the project window's own chrome, so the band under test is the real one.
    private func projectShapedWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable,
                                          .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        let toolbar = NSToolbar(identifier: "DiagTitlebar")
        toolbar.allowsUserCustomization = false
        toolbar.showsBaselineSeparator = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        addTeardownBlock { @MainActor in window.orderOut(nil) }
        window.orderFront(nil)
        return window
    }

    private func open(_ view: some View) throws -> NSView {
        let window = projectShapedWindow()
        let host = NSHostingView(rootView: AnyView(view))
        host.frame = NSRect(x: 0, y: 330, width: 340, height: 44)
        window.contentView?.addSubview(host)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        return host
    }

    private final class CarvingView: NSView {
        override var mouseDownCanMoveWindow: Bool { false }
    }
}
