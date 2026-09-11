import XCTest
import AppKit
import SwiftUI

/// **Why the window's trailing chrome does not animate its own width.**
///
/// `CanvasHeaderTrailingChrome` is one hosting view holding a row of capsules, sized to its own
/// contents and pinned to the window's trailing edge. The point of that arrangement is that the row
/// grows *leftward*: stepping into a web card, or opening find, must not shove Add and the options menu
/// out from under a pointer already on its way to one of them.
///
/// It holds only while the row's width and the offsets inside it change together, and they do not. A
/// stack lays its children out from its leading edge, and that edge is what moves when the row changes
/// width. Auto Layout resolves the origin from `intrinsicContentSize`, which is the *settled* size and
/// arrives in one step; SwiftUI interpolates the offsets over the animation's duration. Two clocks for
/// one number: a child's place on screen is origin plus offset, so for a fifth of a second every
/// capsule in the row is somewhere neither of them meant.
///
/// These measure that, at both scales, and they measure the one alternative that would have kept the
/// animation — a row with a fixed box and its capsules right-aligned inside it, whose leading edge
/// therefore never moves. That door is closed by hit-testing, which is the third test.
///
/// A model of the shape rather than the header itself, for the reason `SidebarClickTests` models a
/// list: the real chrome reaches for half the app to compile. The marker views are real `NSView`s,
/// which is the only handle a test has on where SwiftUI actually put things — the same trick the real
/// capsules make available through the `WindowDragExcluder` each one carries.
@MainActor
final class HeaderChromeMotionTests: XCTestCase {
    private var window: NSWindow!
    /// The row under test — `Row`, or `MaterializingRow` — as the plain view the marker walk needs.
    private var host: NSView!
    private var pill: NSHostingView<Pill>!
    /// Stands in for the tab row, which is pinned to the pill's trailing anchor and so is the thing
    /// that moves if the pill's width ever depends on which mode is up.
    private var neighbour: NSView!
    private var model: RowModel!

    override func tearDown() {
        window?.orderOut(nil)
        super.tearDown()
    }

    /// **A row that animates a capsule away throws every other capsule sideways first.**
    ///
    /// Not a drift of a point or two: the trailing capsule jumps by the whole width of the one that
    /// left — out past the window's edge — and then slides back to where it already was.
    func testAnAnimatedRowThrowsItsTrailingCapsuleSideways() throws {
        try openRow(animated: true)
        let before = try XCTUnwrap(capsules().last, "no capsules on screen")
        let track = sample(for: 0.5) { self.model.showsPage = false }
        report("animated", before: before, track: track)
        XCTAssertGreaterThan(drift(of: .last, from: before, in: track), 20,
                             "the animated row no longer moves its trailing capsule — if AppKit has "
                                + "started animating intrinsicContentSize in step, the header may "
                                + "have its transitions back")
    }

    /// **The same row with no animation on it holds perfectly still**, which is the rule the header
    /// now follows: a capsule appears or disappears in one frame, and nothing beside it moves.
    func testAnUnanimatedRowHoldsStill() throws {
        try openRow(animated: false)
        let before = try XCTUnwrap(capsules().last, "no capsules on screen")
        let track = sample(for: 0.3) { self.model.showsPage = false }
        report("unanimated", before: before, track: track)
        XCTAssertLessThan(drift(of: .last, from: before, in: track), 1,
                          "an unanimated row moved its trailing capsule")
    }

    /// **And one scale down**: a single capsule that grows an item at its leading edge — which is what
    /// opening the find field does — throws its own glyphs the same way, for the same reason. This is
    /// why the fix reaches inside the capsules and not only across the row.
    func testAnAnimatedCapsuleThrowsItsOwnGlyphsSideways() throws {
        try openRow(animated: true, growing: true)
        let before = try XCTUnwrap(capsules().last, "no capsules on screen")
        let track = sample(for: 0.5) { self.model.showsPage = false }
        report("growing", before: before, track: track)
        XCTAssertGreaterThan(drift(of: .last, from: before, in: track), 20,
                             "a capsule growing an item no longer moves the glyphs beside it")
    }

    /// **The door that is closed.** The animation could have been kept by giving the row a fixed box
    /// and right-aligning the capsules in it, so that nothing about its frame depends on its contents.
    /// A hosting view takes every click inside its frame, though, empty or not — so a row wide enough
    /// to hold still is a strip across the top of the board that swallows clicks on the cards up there,
    /// which is the thing this header is islands to avoid.
    func testAWideRowSwallowsClicksInItsEmptyHalf() throws {
        TestApp.start()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 120),
                          styleMask: [.titled], backing: .buffered, defer: false)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 1200, height: 120))
        window.contentView = container
        model = RowModel()
        let wide = NSHostingView(rootView: WideRow(model: model))
        wide.safeAreaRegions = []
        wide.frame = NSRect(x: 0, y: 0, width: 1000, height: 60)
        container.addSubview(wide)
        window.makeKeyAndOrderFront(nil)
        settle(0.4)

        let empty = container.hitTest(NSPoint(x: 60, y: 30))
        let onCapsule = container.hitTest(NSPoint(x: 960, y: 30))
        print("DIAG hit: empty=\(empty.map { String(describing: type(of: $0)) } ?? "nil") "
              + "capsule=\(onCapsule.map { String(describing: type(of: $0)) } ?? "nil")")
        XCTAssertNotNil(onCapsule, "the capsule itself has to take a click")
        XCTAssertTrue(empty is NSHostingView<WideRow>,
                      "a hosting view has started letting clicks through its empty areas — a "
                          + "fixed-box row would now be an option, and with it the animation")
    }

    // MARK: The way a capsule comes and goes now (docs/header-chrome.md P1)

    /// **A capsule that materializes out leaves the row exactly where it was**, and does leave in its
    /// own time: it fades in place for a while before the row closes up, which is what separates this
    /// from the cut it replaces. `HeaderPresence` is the real one, not a model of it.
    func testAMaterializingCapsuleLeavesWithoutMovingTheRow() throws {
        try openRow(animated: false, materializing: true)
        let before = try XCTUnwrap(capsules().last, "no capsules on screen")
        let track = sample(for: 0.6) { self.model.showsPage = false }
        report("materializing out", before: before, track: track)
        XCTAssertLessThan(drift(of: .last, from: before, in: track), 1,
                          "a capsule materializing out moved the capsule beside it")
        XCTAssertGreaterThan(track.filter { $0.count == 3 }.count, 2,
                             "the capsule was cut rather than faded out where it stood")
        XCTAssertEqual(track.last?.count, 2, "the capsule never left")
    }

    /// **And arriving, the same**: the row snaps to make room in one frame, and the capsule comes in
    /// where it already stands.
    func testAMaterializingCapsuleArrivesWithoutMovingTheRow() throws {
        try openRow(animated: false, materializing: true, startsShowing: false)
        let before = try XCTUnwrap(capsules().last, "no capsules on screen")
        let track = sample(for: 0.6) { self.model.showsPage = true }
        report("materializing in", before: before, track: track)
        XCTAssertLessThan(drift(of: .last, from: before, in: track), 1,
                          "a capsule materializing in moved the capsule beside it")
        XCTAssertEqual(track.last?.count, 3, "the capsule never arrived")
    }

    // MARK: The pill, at the other end of the band

    /// **Why the pill keeps its inset over a tiled board**, where there is no glass for it to be the
    /// inset of.
    ///
    /// Taking it off both sides narrows the pill by twenty-eight points. That is a change of
    /// `intrinsicContentSize`, so Auto Layout resizes the hosting view — and the whole change then
    /// arrives in a single frame: measured here, the name and the row are both at their final places
    /// by the first sample, with nothing in between. Not the two clocks of the tests above, but worse
    /// — the animation lost outright, and a row of tab chips jumping twenty-eight points sideways to
    /// pay for it.
    func testDroppingTheInsetOnBothSidesJumpsTheTabRow() throws {
        try openPill()
        let start = try XCTUnwrap(titleFrame(), "SwiftUI never built the title")
        let startNeighbour = neighbour.convert(neighbour.bounds, to: nil)
        let samples = trackPill(for: 0.5) { self.model.tiled = true }
        reportPill("dropping both", from: start, neighbour: startNeighbour, samples: samples)

        let rowDrift = samples.map { abs($0.neighbour.minX - startNeighbour.minX) }.max() ?? 0
        XCTAssertGreaterThan(rowDrift, 10,
                             "a pill that narrows no longer moves the row pinned to its trailing "
                                 + "anchor — if Auto Layout has started animating intrinsicContentSize "
                                 + "in step, the pill could simply drop its inset")
        let slid = samples.filter { $0.title.minX < start.minX - 2 && $0.title.minX > start.minX - 12 }
        XCTAssertTrue(slid.isEmpty,
                      "the name is now sliding even though the pill's own width is changing under "
                          + "it: SwiftUI has started interpolating a layout whose hosting view is "
                          + "being resized, and `CanvasTitlePill` could be the simpler scheme")
    }

    // MARK: The shapes under test

    final class RowModel: ObservableObject {
        @Published var showsPage = true
        /// Whether a workspace is up — the pill's one piece of state. See `CanvasTitlePill`.
        @Published var tiled = false
        var animated = true
        /// The other scale: one capsule that grows an item at its leading edge, rather than a row that
        /// gains a whole capsule.
        var growing = false
    }

    /// A marker that is a real view, the way every `HeaderCapsule` carries a `WindowDragExcluder`.
    struct Marker: NSViewRepresentable {
        func makeNSView(context: Context) -> NSView { MarkerView() }
        func updateNSView(_ view: NSView, context: Context) {}
        final class MarkerView: NSView {}
    }

    struct Row: View {
        @ObservedObject var model: RowModel

        var body: some View {
            HStack(alignment: .bottom, spacing: 8) {
                if model.growing {
                    HStack(spacing: 8) {
                        if model.showsPage { capsule(width: 170) }
                        capsule(width: 60)
                        capsule(width: 120)
                    }
                    .padding(.horizontal, 6)
                    .background(Color.gray.opacity(0.1))
                } else {
                    if model.showsPage { capsule(width: 340).transition(.blurReplace) }
                    capsule(width: 60)
                    capsule(width: 120)
                }
            }
            .animation(model.animated ? .snappy(duration: 0.22) : nil, value: model.showsPage)
        }

        private func capsule(width: CGFloat) -> some View {
            Color.gray.opacity(0.2)
                .frame(width: width, height: 28)
                .background(Marker())
        }
    }

    /// The row the header draws now: the leading capsule comes and goes through the real
    /// `HeaderPresence`, and nothing about the row is animated.
    struct MaterializingRow: View {
        @ObservedObject var model: RowModel
        @State private var page = HeaderPresence<Bool>()

        var body: some View {
            HStack(alignment: .bottom, spacing: 8) {
                if page.shown != nil {
                    capsule(width: 340).headerMaterialized(page.materialized)
                }
                capsule(width: 60)
                capsule(width: 120)
            }
            .headerPresence(of: model.showsPage ? true : nil, in: $page)
        }

        private func capsule(width: CGFloat) -> some View {
            Color.gray.opacity(0.2)
                .frame(width: width, height: 28)
                .background(Marker())
        }
    }

    /// The pill at the other end of the band, modelled the same way: a name in an intrinsically-sized
    /// hosting view, with the tab row pinned to its trailing anchor.
    ///
    /// Going to a workspace takes the glass off it, and a name that starts fourteen points inside its
    /// own island with nothing drawn around it looks like it wants to go flush. This is that version,
    /// which `CanvasTitlePill` does not take.
    struct Pill: View {
        @ObservedObject var model: RowModel

        private let inset: CGFloat = 14

        var body: some View {
            Text("A Board With A Name")
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .background(Marker())
                .padding(.horizontal, model.tiled ? 0 : inset)
                .padding(.vertical, 7)
                .animation(.easeOut(duration: 0.18), value: model.tiled)
        }
    }

    /// The alternative: a box that does not depend on its contents, with the capsule at its edge.
    struct WideRow: View {
        @ObservedObject var model: RowModel
        var body: some View {
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Color.gray.opacity(0.2).frame(width: 120, height: 28).background(Marker())
            }
        }
    }

    // MARK: Putting it on screen

    /// Built the way `CanvasPaneController.buildContent` builds the real one: intrinsic size, no safe
    /// area, pinned to the trailing edge and free to grow leftward.
    private func openRow(animated: Bool, growing: Bool = false, materializing: Bool = false,
                         startsShowing: Bool = true) throws {
        TestApp.start()
        model = RowModel()
        model.animated = animated
        model.growing = growing
        model.showsPage = startsShowing
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 120),
                          styleMask: [.titled], backing: .buffered, defer: false)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 1200, height: 120))
        window.contentView = container
        func hosting<V: View>(_ root: V) -> NSView {
            let view = NSHostingView(rootView: root)
            view.sizingOptions = [.intrinsicContentSize]
            view.safeAreaRegions = []
            return view
        }
        host = materializing ? hosting(MaterializingRow(model: model)) : hosting(Row(model: model))
        host.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(host)
        NSLayoutConstraint.activate([
            host.topAnchor.constraint(equalTo: container.topAnchor),
            host.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
        ])
        window.makeKeyAndOrderFront(nil)
        settle(0.5)
        XCTAssertEqual(capsules().count, startsShowing ? 3 : 2, "SwiftUI never built the capsules")
    }

    /// Built the way `CanvasPaneController.buildContent` builds the leading half: an intrinsically-sized
    /// pill pinned to the leading edge, and the tab row pinned to *its* trailing anchor.
    private func openPill() throws {
        TestApp.start()
        model = RowModel()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 120),
                          styleMask: [.titled], backing: .buffered, defer: false)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 1200, height: 120))
        window.contentView = container
        pill = NSHostingView(rootView: Pill(model: model))
        pill.sizingOptions = [.intrinsicContentSize]
        pill.safeAreaRegions = []
        pill.translatesAutoresizingMaskIntoConstraints = false
        neighbour = NSView()
        neighbour.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(pill)
        container.addSubview(neighbour)
        NSLayoutConstraint.activate([
            pill.topAnchor.constraint(equalTo: container.topAnchor),
            pill.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 92),
            neighbour.topAnchor.constraint(equalTo: container.topAnchor),
            neighbour.leadingAnchor.constraint(equalTo: pill.trailingAnchor, constant: 10),
            neighbour.widthAnchor.constraint(equalToConstant: 120),
            neighbour.heightAnchor.constraint(equalToConstant: 28),
        ])
        window.makeKeyAndOrderFront(nil)
        settle(0.5)
    }

    /// Where the name itself is, rather than the box around it.
    private func titleFrame() -> CGRect? {
        var found: CGRect?
        func walk(_ view: NSView) {
            if view is Marker.MarkerView, view.frame.width > 1, found == nil {
                found = view.convert(view.bounds, to: nil)
            }
            view.subviews.forEach(walk)
        }
        walk(pill)
        return found
    }

    /// The name and the row beside it, every frame or so until the animation is over.
    private func trackPill(for seconds: TimeInterval,
                           _ change: () -> Void) -> [(title: CGRect, neighbour: CGRect)] {
        change()
        var samples: [(title: CGRect, neighbour: CGRect)] = []
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.016))
            window.contentView?.layoutSubtreeIfNeeded()
            if let title = titleFrame() {
                samples.append((title, neighbour.convert(neighbour.bounds, to: nil)))
            }
        }
        return samples
    }

    private func reportPill(_ what: String, from start: CGRect, neighbour startNeighbour: CGRect,
                            samples: [(title: CGRect, neighbour: CGRect)]) {
        let step = max(1, samples.count / 30)
        let line = stride(from: 0, to: samples.count, by: step)
            .map { String(format: "%.0f/%.0f", samples[$0].title.minX, samples[$0].neighbour.minX) }
            .joined(separator: " ")
        print("DIAG pill \(what): \(samples.count) samples; name/row started "
              + String(format: "%.0f/%.0f", start.minX, startNeighbour.minX) + "; then \(line)")
    }

    /// Where each capsule is, in window coordinates, leading edge first.
    private func capsules() -> [CGRect] {
        var found: [CGRect] = []
        func walk(_ view: NSView) {
            if view is Marker.MarkerView, view.frame.width > 1 {
                found.append(view.convert(view.bounds, to: nil))
            }
            view.subviews.forEach(walk)
        }
        walk(host)
        return found.sorted { $0.minX < $1.minX }
    }

    private enum Which { case last, middle }

    /// The furthest any sample strayed from where the capsule started.
    private func drift(of which: Which, from before: CGRect, in track: [[CGRect]]) -> Double {
        track.compactMap { frames -> Double? in
            guard frames.count >= 2 else { return nil }
            switch which {
            case .last: return frames.last.map { abs($0.maxX - before.maxX) }
            case .middle: return abs(frames[frames.count - 2].minX - before.minX)
            }
        }.max() ?? 0
    }

    /// Run the change, then read the capsules every frame or so until the animation is over.
    private func sample(for seconds: TimeInterval, _ change: () -> Void) -> [[CGRect]] {
        change()
        var track: [[CGRect]] = []
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.016))
            window.contentView?.layoutSubtreeIfNeeded()
            track.append(capsules())
        }
        return track
    }

    private func settle(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        window.contentView?.layoutSubtreeIfNeeded()
    }

    /// The trajectory, so a result says what actually happened rather than only that it did.
    private func report(_ what: String, before: CGRect, track: [[CGRect]]) {
        let line = track.prefix(30).compactMap { $0.last.map { String(format: "%.0f", $0.maxX) } }
            .joined(separator: " ")
        print("DIAG \(what): trailing maxX started \(String(format: "%.0f", before.maxX)); then \(line)")
    }
}
