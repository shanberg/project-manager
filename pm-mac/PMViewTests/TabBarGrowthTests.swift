import XCTest
import AppKit
import SwiftUI

/// **Whether the tab bar may animate its own width** — docs/header-chrome.md P4.
///
/// Every other header view is forbidden to (`HeaderChromeMotionTests`): Auto Layout gives a hosting view
/// its new width in one step while SwiftUI interpolates what is inside it, and for a view pinned on the
/// right and growing left, that throws the contents sideways by the whole change. The bar is pinned on
/// the *left*, to the pill, which no longer changes width — so its origin should never move, and a
/// capsule stretching rightward inside a host that has already snapped may simply look like growing.
///
/// The real `ProjectTabBar`, in a host built the way `CanvasPaneController` builds the real one. Its
/// capsule carries a `WindowDragExcluder`, a real `NSView`, which is where these read the capsule from.
@MainActor
final class TabBarGrowthTests: XCTestCase {
    private var window: NSWindow!
    private var host: NSHostingView<Harness>!
    private var model: Model!

    override func tearDown() {
        window?.orderOut(nil)
        super.tearDown()
    }

    /// Adding a chip — ⌘Return making a workspace, which also selects it.
    func testAddingAChipGrowsTheBarWithoutMovingItsPinnedEdge() throws {
        try open(names: ["Notes", "Research"])
        let start = try XCTUnwrap(capsuleFrame(), "the bar never drew its capsule")
        let track = sample(for: 0.5) {
            self.model.items.append(Self.item("Detective Depictions"))
            self.model.selected = "Detective Depictions"
        }
        report("add", start: start, track: track)
        XCTAssertLessThan(leadingDrift(from: start, in: track), 1, "the bar's pinned edge moved")
        let end = try XCTUnwrap(track.last?.capsule)
        XCTAssertGreaterThan(end.width, start.width + 20, "the bar never grew")
        // **What P4 found: it doesn't grow, it snaps.** The host and the capsule are at their final
        // width by the first frame — the row measures itself (`TabRowWidthKey`) and the bar's width
        // follows a pass later, with no animation to carry it — so there is no stretch to watch and
        // the new chip fading in is the whole of the arrival (docs/header-chrome.md Q4, option B). If
        // this starts failing, the bar has begun to grow smoothly and option C is back on the table.
        let first = try XCTUnwrap(track.first?.capsule)
        XCTAssertEqual(first.width, end.width, accuracy: 1,
                       "the bar has started growing smoothly — see docs/header-chrome.md Q4")
    }

    /// Removing one — deleting a workspace.
    func testRemovingAChipShrinksTheBarWithoutMovingItsPinnedEdge() throws {
        try open(names: ["Notes", "Research", "Detective Depictions"])
        let start = try XCTUnwrap(capsuleFrame(), "the bar never drew its capsule")
        let track = sample(for: 0.5) {
            self.model.items.removeLast()
            self.model.selected = "Research"
        }
        report("remove", start: start, track: track)
        XCTAssertLessThan(leadingDrift(from: start, in: track), 1, "the bar's pinned edge moved")
        // Whether the shrinking capsule is ever drawn past a host that has already snapped narrower —
        // the other half of P4, which only matters if the host clips.
        let overhang = track.map { $0.capsule.maxX - $0.host.maxX }.max() ?? 0
        print("DIAG remove: host clips=\(host.clipsToBounds) layerMasks=\(host.layer?.masksToBounds ?? false) "
              + String(format: "largest overhang past the host %.1fpt", overhang))
    }

    // MARK: The shape under test

    final class Model: ObservableObject {
        @Published var items: [ProjectTabItem] = []
        @Published var selected = "canvas"
    }

    struct Harness: View {
        @ObservedObject var model: Model

        var body: some View {
            ProjectTabBar(items: model.items, selectedID: model.selected, chrome: .active,
                          select: { _ in }, close: { _ in }, move: { _, _ in },
                          renameWorkspace: { _ in }, duplicateWorkspace: { _ in },
                          deleteWorkspace: { _ in }, renameTab: { _, _ in })
        }
    }

    static func item(_ name: String) -> ProjectTabItem {
        ProjectTabItem(id: name, name: name, workspaceName: name, closable: false)
    }

    // MARK: Putting it on screen

    private func open(names: [String]) throws {
        TestApp.start()
        model = Model()
        model.items = [ProjectTabItem(id: "canvas", name: "Canvas", isCanvas: true, closable: false)]
            + names.map(Self.item)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 120),
                          styleMask: [.titled], backing: .buffered, defer: false)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 1200, height: 120))
        window.contentView = container
        host = NSHostingView(rootView: Harness(model: model))
        host.sizingOptions = [.intrinsicContentSize]
        host.safeAreaRegions = []
        host.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(host)
        NSLayoutConstraint.activate([
            host.topAnchor.constraint(equalTo: container.topAnchor),
            host.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 200),
        ])
        window.makeKeyAndOrderFront(nil)
        settle(0.6)
    }

    /// The capsule: the tallest excluder in the bar. The row carries one too, an item high, inside it.
    private func capsuleFrame() -> CGRect? {
        var found: [CGRect] = []
        func walk(_ view: NSView) {
            if view is WindowDragExcluder.ExcluderView, view.frame.width > 1 {
                found.append(view.convert(view.bounds, to: nil))
            }
            view.subviews.forEach(walk)
        }
        walk(host)
        return found.max { $0.height < $1.height }
    }

    private func sample(for seconds: TimeInterval,
                        _ change: () -> Void) -> [(capsule: CGRect, host: CGRect)] {
        change()
        var track: [(capsule: CGRect, host: CGRect)] = []
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.016))
            window.contentView?.layoutSubtreeIfNeeded()
            if let capsule = capsuleFrame() {
                track.append((capsule, host.convert(host.bounds, to: nil)))
            }
        }
        return track
    }

    private func leadingDrift(from start: CGRect, in track: [(capsule: CGRect, host: CGRect)]) -> Double {
        track.map { abs($0.capsule.minX - start.minX) }.max() ?? 0
    }

    private func settle(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        window.contentView?.layoutSubtreeIfNeeded()
    }

    /// Leading edge and width, so the result says whether the width interpolated or snapped.
    private func report(_ what: String, start: CGRect, track: [(capsule: CGRect, host: CGRect)]) {
        let line = track.prefix(30)
            .map { String(format: "%.0f+%.0f/%.0f", $0.capsule.minX, $0.capsule.width, $0.host.width) }
            .joined(separator: " ")
        print("DIAG tab bar \(what): started "
              + String(format: "%.0f+%.0f", start.minX, start.width) + "; then \(line)")
    }
}
