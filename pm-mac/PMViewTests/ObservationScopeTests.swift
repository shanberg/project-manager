import AppKit
import Combine
import SwiftUI
import XCTest

/// What the `@Observable` migration actually bought, measured where it is spent: SwiftUI bodies.
///
/// The claim in `docs/structural-work.md` was that per-property dependency tracking stops a change to
/// one property invalidating every view of the model. That is a claim about rendering, so asserting
/// it against `withObservationTracking` — as `ObservationRelayTests` does — is not quite the same
/// thing: it shows the *mechanism* works, not that SwiftUI uses it the way the app needs. This puts
/// two real views on a real window and counts their bodies.
///
/// Both halves are here on purpose. A test that only showed the new behaviour would not say how much
/// it was worth, and the `ObservableObject` half is the number it is worth measuring against.
@MainActor
final class ObservationScopeTests: XCTestCase {

    private var window: NSWindow!

    override func tearDown() {
        window?.orderOut(nil)
        super.tearDown()
    }

    // MARK: Two models of the same shape

    @Observable
    final class Tracked {
        var title = "one"
        var rows: [String] = []
    }

    final class WholeObject: ObservableObject {
        @Published var title = "one"
        @Published var rows: [String] = []
    }

    /// Reference counters the views write to. A class rather than `@State`, so a body evaluation is
    /// recorded even though re-rendering is exactly what is being counted.
    final class Tally: @unchecked Sendable {
        var titleBodies = 0
        var rowBodies = 0
    }

    // MARK: The views

    /// Reads `title` and nothing else.
    private struct TrackedTitle: View {
        let model: Tracked
        let tally: Tally
        var body: some View {
            tally.titleBodies += 1
            return Text(model.title)
        }
    }

    /// Reads `rows` and nothing else.
    private struct TrackedRows: View {
        let model: Tracked
        let tally: Tally
        var body: some View {
            tally.rowBodies += 1
            return Text("\(model.rows.count)")
        }
    }

    private struct WholeObjectTitle: View {
        @ObservedObject var model: WholeObject
        let tally: Tally
        var body: some View {
            tally.titleBodies += 1
            return Text(model.title)
        }
    }

    private struct WholeObjectRows: View {
        @ObservedObject var model: WholeObject
        let tally: Tally
        var body: some View {
            tally.rowBodies += 1
            return Text("\(model.rows.count)")
        }
    }

    // MARK: The measurement

    /// **The win, measured.** A view that reads `title` is not re-rendered when `rows` changes.
    ///
    /// This is the app's commonest shape: `PMStore.reload` writes twenty properties, and the window
    /// title, the details pane and the task list each read a couple of them.
    func testAViewIsNotRerenderedByAPropertyItDoesNotRead() {
        let model = Tracked()
        let tally = Tally()
        host(AnyView(VStack {
            TrackedTitle(model: model, tally: tally)
            TrackedRows(model: model, tally: tally)
        }))

        let titleBefore = tally.titleBodies
        let rowBefore = tally.rowBodies
        XCTAssertGreaterThan(titleBefore, 0, "the views never drew, so nothing below means anything")

        model.rows = ["a", "b", "c"]
        settle()

        XCTAssertGreaterThan(tally.rowBodies, rowBefore, "the view that reads rows must redraw")
        XCTAssertEqual(tally.titleBodies, titleBefore,
                       "the view that reads only title must not redraw for a change to rows")
    }

    /// The same two views under `ObservableObject`, which is what every model in the app was before
    /// this migration: both redraw, because the dependency is the object rather than the property.
    ///
    /// Kept so the number above has something to be a number *against*, and so that a model reverted
    /// to `@Published` fails here rather than quietly costing a redraw per unrelated change.
    func testObservableObjectRerendersEveryViewOfTheModel() {
        let model = WholeObject()
        let tally = Tally()
        host(AnyView(VStack {
            WholeObjectTitle(model: model, tally: tally)
            WholeObjectRows(model: model, tally: tally)
        }))

        let titleBefore = tally.titleBodies
        let rowBefore = tally.rowBodies
        XCTAssertGreaterThan(titleBefore, 0)

        model.rows = ["a", "b", "c"]
        settle()

        XCTAssertGreaterThan(tally.rowBodies, rowBefore)
        XCTAssertGreaterThan(tally.titleBodies, titleBefore,
                             "whole-object invalidation: the title view redraws for a change it "
                             + "cannot see")
    }

    // MARK: Putting it on screen

    private func host(_ content: AnyView) {
        TestApp.start()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                          styleMask: [.titled], backing: .buffered, defer: false)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        window.contentView = container
        let host = NSHostingView(rootView: content)
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
        window.makeKeyAndOrderFront(nil)
        settle()
    }

    private func settle(_ seconds: TimeInterval = 0.4) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        window.contentView?.layoutSubtreeIfNeeded()
    }
}
