import Combine
import XCTest

/// One pass per burst, rather than one pass per property.
///
/// `AppDelegate.storeDidChange` is not cheap — it syncs notifications, refreshes the quick bar's
/// focused-task name, refreshes every window title and re-points the notes watches. It used to run
/// once per `@Published` assignment, and `PMStore.reload` makes fourteen of those in a row, so a
/// single reload paid for all of it fourteen times. With several windows open and the watcher firing,
/// one save in Obsidian was some forty passes. See `Coalescer`.
@MainActor
final class CoalescerTests: XCTestCase {

    /// A model shaped like the real one: several properties written together in one block.
    private final class Model: ObservableObject {
        @Published var a = 0
        @Published var b = 0
        @Published var c = 0

        /// What `PMStore.reload` does — a run of assignments with no suspension between them.
        func reload() {
            a = 1
            b = 2
            c = 3
        }
    }

    private var bag = Set<AnyCancellable>()

    /// Let the main queue turn over, so anything scheduled for "next turn" has run.
    private func settle() {
        let done = expectation(description: "next turn")
        DispatchQueue.main.async { done.fulfill() }
        wait(for: [done], timeout: 1)
    }

    // MARK: The defect, pinned

    /// **Why this exists at all.** Combine fires `objectWillChange` once per assignment, and a
    /// main-queue hop delivers each of those separately — it defers the work but does not merge it. So
    /// the old subscription shape ran its job once per property, and this is that shape, asserted, so
    /// that reverting to it fails here rather than in a profile six months from now.
    func testAHopDefersTheWorkButDoesNotMergeIt() {
        let model = Model()
        var passes = 0
        model.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { passes += 1 }
            .store(in: &bag)

        model.reload()
        settle()

        XCTAssertEqual(passes, 3, "three assignments, three passes — the hop merges nothing")
    }

    // MARK: What the coalescer does instead

    /// The same burst, one pass.
    func testABurstOfRequestsRunsTheJobOnce() {
        var passes = 0
        let coalescer = Coalescer { passes += 1 }
        let model = Model()
        model.objectWillChange.sink { coalescer.schedule() }.store(in: &bag)

        model.reload()
        XCTAssertEqual(passes, 0, "nothing runs inside the block that is still writing")

        settle()
        XCTAssertEqual(passes, 1, "three assignments, one pass")
    }

    /// **The hop is load-bearing, not decoration.** `objectWillChange` fires from `willSet`, so a job
    /// that ran synchronously would read the value it is being told is about to change. The whole
    /// point of deferring is that by the time the job looks, the writes have landed — all of them,
    /// including the ones that came after the notification that woke it.
    func testTheJobSeesEveryValueTheBurstWrote() {
        let model = Model()
        var seen: (Int, Int, Int)?
        let coalescer = Coalescer { seen = (model.a, model.b, model.c) }
        model.objectWillChange.sink { coalescer.schedule() }.store(in: &bag)

        model.reload()
        settle()

        XCTAssertEqual(seen?.0, 1)
        XCTAssertEqual(seen?.1, 2)
        XCTAssertEqual(seen?.2, 3, "the last write of the burst is visible, not just the first")
    }

    /// A later burst is a later pass. Coalescing collapses a turn, not the future.
    func testASecondBurstRunsTheJobAgain() {
        var passes = 0
        let coalescer = Coalescer { passes += 1 }
        let model = Model()
        model.objectWillChange.sink { coalescer.schedule() }.store(in: &bag)

        model.reload()
        settle()
        XCTAssertEqual(passes, 1)

        model.reload()
        settle()
        XCTAssertEqual(passes, 2)
    }

    /// **A job that causes another request is not swallowed.** `storeDidChange` can end up provoking
    /// the next change itself — re-pointing the notes watches is a write of its own — and the flag is
    /// cleared before the job runs precisely so that request books a fresh pass instead of landing
    /// inside the one already running and being dropped.
    func testAJobThatRequestsAgainGetsAnotherPass() {
        var passes = 0
        var coalescer: Coalescer?
        coalescer = Coalescer {
            passes += 1
            if passes == 1 { coalescer?.schedule() }
        }
        coalescer?.schedule()

        settle()
        XCTAssertEqual(passes, 1)

        settle()
        XCTAssertEqual(passes, 2, "the request made from inside the job booked its own pass")
    }

    /// Nothing asked for, nothing run.
    func testAnIdleCoalescerNeverRuns() {
        var passes = 0
        let coalescer = Coalescer { passes += 1 }
        XCTAssertFalse(coalescer.isPending)

        settle()

        XCTAssertEqual(passes, 0)
    }

    /// `isPending` says whether this turn is already booked — true between the first request and the
    /// run, false either side of it.
    func testPendingIsTrueOnlyBetweenTheRequestAndTheRun() {
        let coalescer = Coalescer {}
        XCTAssertFalse(coalescer.isPending)

        coalescer.schedule()
        XCTAssertTrue(coalescer.isPending)
        coalescer.schedule()
        XCTAssertTrue(coalescer.isPending, "a second request in the same turn changes nothing")

        settle()
        XCTAssertFalse(coalescer.isPending)
    }
}
