import Combine
import Observation
import XCTest

/// A non-SwiftUI observer following an `@Observable` model, and the two ways the naive port of a
/// Combine `.sink` gets it wrong.
///
/// `withObservationTracking` arms one notification and then stops watching, so a subscription written
/// as a direct translation of `.sink` delivers the first change and silently dies. And `onChange`
/// fires before the value lands, so a handler that reads the model from inside it sees the old one.
/// Both are asserted here as the *unrelayed* behaviour, so that a "simplification" back to a bare
/// `withObservationTracking` call fails a test rather than producing a menubar that goes stale after
/// one edit. See `ObservationRelay`.
/// Shaped like `PMStore`: several properties written together in one block, and one that a given
/// observer does not care about.
///
/// At file scope rather than nested in the test case, because `@Observable` expands to an extension
/// and Swift has nowhere to put an extension of a private nested type.
@Observable
final class RelayProbeModel {
    var a = 0
    var b = 0
    var c = 0
    /// The property this test's relays deliberately do not read.
    var unrelated = 0

    /// What `PMStore.reload` does — a run of assignments with no suspension between them.
    func reload() {
        a = 1
        b = 2
        c = 3
    }
}

/// Somewhere for the two bare-`withObservationTracking` tests to record from. `onChange` is a
/// `@Sendable` closure, so a captured local `var` is a concurrency warning even though it fires
/// synchronously on the thread that did the mutating; a reference the closure shares is the honest
/// spelling of what is happening.
final class RelayProbeRecord: @unchecked Sendable {
    var notices = 0
    var seen: Int?
}

/// The `ObservableObject` shape of the same model, kept for the comparison below.
final class RelayProbeLegacyModel: ObservableObject {
    @Published var a = 0
    @Published var unrelated = 0
}

@MainActor
final class ObservationRelayTests: XCTestCase {

    private var bag = Set<AnyCancellable>()

    /// Let the main queue turn over `times` times, so anything scheduled for "next turn" has run.
    /// A relay takes two: one for `onChange`'s hop out of the mutation, one for the coalesced pass.
    private func settle(_ times: Int = 2) {
        for _ in 0..<times {
            let done = expectation(description: "next turn")
            DispatchQueue.main.async { done.fulfill() }
            wait(for: [done], timeout: 1)
        }
    }

    // MARK: The two defects, pinned

    /// **Tracking is one-shot.** This is the bug that makes the naive port dangerous rather than
    /// merely wrong: the first change arrives, so the wiring looks correct, and every change after it
    /// is dropped.
    func testBareTrackingDeliversOneChangeAndThenStopsWatching() {
        let model = RelayProbeModel()
        let record = RelayProbeRecord()
        withObservationTracking { _ = model.a } onChange: { record.notices += 1 }

        model.a = 1
        model.a = 2
        model.a = 3

        XCTAssertEqual(record.notices, 1, "armed once, fired once, and stopped watching — not a subscription")
    }

    /// **`onChange` fires before the value lands**, exactly as `objectWillChange` did from `willSet`.
    func testBareTrackingSeesTheValueItIsBeingToldIsAboutToChange() {
        let model = RelayProbeModel()
        let record = RelayProbeRecord()
        withObservationTracking { _ = model.a } onChange: { record.seen = model.a }

        model.a = 7

        XCTAssertEqual(record.seen, 0, "read synchronously, the handler sees the old value")
    }

    // MARK: What the relay does instead

    func testTheRelayRunsTheJobOnceForABurst() {
        let model = RelayProbeModel()
        var passes = 0
        let relay = ObservationRelay(tracking: { _ = model.a; _ = model.b; _ = model.c },
                                     then: { passes += 1 })

        model.reload()
        XCTAssertEqual(passes, 0, "nothing runs inside the block that is still writing")

        settle()
        XCTAssertEqual(passes, 1, "three assignments, one pass")
        withExtendedLifetime(relay) {}
    }

    /// The failure `testBareTrackingDeliversOneChangeAndThenStopsWatching` describes, fixed.
    func testTheRelayKeepsWatchingAfterItHasFired() {
        let model = RelayProbeModel()
        var passes = 0
        let relay = ObservationRelay(tracking: { _ = model.a }, then: { passes += 1 })

        model.a = 1
        settle()
        XCTAssertEqual(passes, 1)

        model.a = 2
        settle()
        XCTAssertEqual(passes, 2, "a relay that stopped after the first change would sit at 1")

        model.a = 3
        settle()
        XCTAssertEqual(passes, 3)
        withExtendedLifetime(relay) {}
    }

    func testTheJobSeesTheValuesTheBurstWrote() {
        let model = RelayProbeModel()
        var seen: [Int] = []
        let relay = ObservationRelay(tracking: { _ = model.a; _ = model.b; _ = model.c },
                                     then: { seen = [model.a, model.b, model.c] })

        model.reload()
        settle()

        XCTAssertEqual(seen, [1, 2, 3], "the deferral exists so the job reads landed values")
        withExtendedLifetime(relay) {}
    }

    // MARK: The reason for the migration

    /// **The whole point of `@Observable`.** A relay that does not read `unrelated` is not woken when
    /// `unrelated` changes.
    func testAChangeToAPropertyTheRelayDoesNotReadWakesNothing() {
        let model = RelayProbeModel()
        var passes = 0
        let relay = ObservationRelay(tracking: { _ = model.a }, then: { passes += 1 })

        model.unrelated = 99
        settle()

        XCTAssertEqual(passes, 0, "per-property tracking: an unread property is not a dependency")

        // And the relay is still live — the silence above is selectivity, not a dead subscription.
        model.a = 1
        settle()
        XCTAssertEqual(passes, 1)
        withExtendedLifetime(relay) {}
    }

    /// The same scenario under `ObservableObject`, which is what the app did before: every observer
    /// woken by every property, whether it reads it or not. This is the cost the migration removes,
    /// asserted, so that reverting a model to `@Published` fails here.
    func testObservableObjectWakesEveryObserverForEveryProperty() {
        let legacy = RelayProbeLegacyModel()
        var passes = 0
        legacy.objectWillChange.sink { passes += 1 }.store(in: &bag)

        legacy.unrelated = 99

        XCTAssertEqual(passes, 1, "whole-object invalidation: nothing can opt out of a property")
    }

    /// A relay whose job writes to the model it watches gets a fresh pass rather than being swallowed,
    /// because arming happens before the job runs. `PMStore`'s observers do exactly this — a reload
    /// triggered by a reload.
    func testAJobThatChangesTheModelIsHeardAgain() {
        let model = RelayProbeModel()
        var passes = 0
        var relay: ObservationRelay?
        relay = ObservationRelay(tracking: { _ = model.a }) {
            passes += 1
            if passes == 1 { model.a += 1 }
        }

        model.a = 1
        settle()
        XCTAssertEqual(passes, 1)

        settle()
        XCTAssertEqual(passes, 2, "the job's own write is a change, and arming precedes the job")
        withExtendedLifetime(relay) {}
    }
}
