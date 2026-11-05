import XCTest
@testable import PMViewTests

/// Rebuilding a board of web cards when the block lists arrive: one at a time, cards you can see first.
@MainActor
final class CanvasStaggeredRunTests: XCTestCase {
    private func item(_ name: String, first: Bool, into log: Ref) -> CanvasStaggeredRun.Item {
        .init(first: { first }, work: { log.value.append(name) })
    }

    final class Ref { var value: [String] = [] }

    func testCardsYouCanSeeRebuildFirstAndTheRestKeepTheirOrder() async {
        let log = Ref()
        await CanvasStaggeredRun.run([
            item("hidden-a", first: false, into: log),
            item("seen-a", first: true, into: log),
            item("hidden-b", first: false, into: log),
            item("seen-b", first: true, into: log),
        ], wait: {})
        XCTAssertEqual(log.value, ["seen-a", "seen-b", "hidden-a", "hidden-b"])
    }

    /// The freeze in folio-hang-3: every rebuild in one main-thread pass. Work queued on main after
    /// the run starts has to get in between two rebuilds.
    func testTheMainThreadGetsATurnBetweenRebuilds() async {
        let log = Ref()
        let run = Task { @MainActor in
            await CanvasStaggeredRun.run([
                item("one", first: false, into: log),
                item("two", first: false, into: log),
            ])
        }
        DispatchQueue.main.async { log.value.append("event") }
        await run.value
        XCTAssertEqual(log.value, ["one", "event", "two"])
    }

    func testOnePauseBetweenEachPairAndNoneAtTheEnds() async {
        var pauses = 0
        await CanvasStaggeredRun.run((0..<3).map { _ in .init(first: { false }, work: {}) },
                                     wait: { pauses += 1 })
        XCTAssertEqual(pauses, 2)
        await CanvasStaggeredRun.run([], wait: { pauses += 1 })
        XCTAssertEqual(pauses, 2)
    }
}
