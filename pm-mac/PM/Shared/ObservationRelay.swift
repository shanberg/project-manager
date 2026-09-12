import Foundation
import Observation

/// Keeps a non-SwiftUI observer — an `NSViewController`, an app delegate — following an `@Observable`
/// model, the way a Combine subscription used to.
///
/// **Why this is needed at all.** `ObservableObject` published a stream: you subscribed once and were
/// told about every change until you cancelled. `@Observable` does not. `withObservationTracking`
/// arms *one* notification, and after it fires the model is no longer being watched — so the naive
/// port of a `.sink` is a subscription that delivers the first change and then silently stops. That
/// failure is invisible in a quick test (the first change works) and shows up as a menubar that goes
/// stale after one edit, which is why this is a type with tests rather than four lines at each call
/// site.
///
/// **The turn's delay is still load-bearing, for the same reason it was under Combine.**
/// `onChange` fires *before* the new value lands, exactly like `objectWillChange` firing from
/// `willSet` — a handler that reads the model synchronously sees the value it is being told is about
/// to change. So the work goes through a `Coalescer`, which supplies that deferral and merges a burst
/// into one pass at the same time. Re-arming happens in that deferred pass rather than inside
/// `onChange`, because `onChange` runs while the registrar is mid-mutation.
///
/// **What is watched is what `tracking` reads.** That is the whole point of the move: a relay that
/// reads two properties is not woken by the other twelve. A relay that deliberately depends on all of
/// them should say so by reading all of them, and should have a test that notices when a
/// fifteenth is added — see `PMStore.trackedByAppDelegate`.
@MainActor
final class ObservationRelay {
    private let tracking: @MainActor () -> Void
    private let job: @MainActor () -> Void

    /// Re-arm and run the job, once, on the next turn of the main queue. Armed before the job runs so
    /// that a change the job itself causes is still seen.
    private lazy var pass = Coalescer { [weak self] in
        guard let self else { return }
        self.arm()
        self.job()
    }

    /// - Parameters:
    ///   - tracking: Reads the properties this observer depends on. Called on every re-arm, so it must
    ///     be cheap and free of side effects — it runs once per burst, not once per change.
    ///   - job: The work. Runs on the main queue a turn after the change, with the new values visible.
    init(tracking: @escaping @MainActor () -> Void, then job: @escaping @MainActor () -> Void) {
        self.tracking = tracking
        self.job = job
        arm()
    }

    /// Whether a pass is booked for this turn. For tests, and for a caller that wants to know it is
    /// about to be asked anyway.
    var isPending: Bool { pass.isPending }

    private func arm() {
        withObservationTracking {
            tracking()
        } onChange: { [weak self] in
            // Fires synchronously from the mutation, and is not main-actor-isolated, so it hops rather
            // than touching the coalescer here.
            Task { @MainActor in self?.pass.schedule() }
        }
    }

    // MARK: Waiting for a value

    /// Suspends until `condition` holds, re-checking whenever an observable property it read changes.
    ///
    /// The `ObservableObject` spelling of this was `for await x in store.$hasLoaded.values where x`,
    /// and there is no `$hasLoaded` any more. The subtlety worth writing down is why the loop re-checks
    /// rather than trusting the notification: `onChange` fires *before* the new value lands, so the
    /// condition is still false at the instant it arrives. Resuming a continuation enqueues rather than
    /// running inline, so the check after it sees the landed value — but the loop is what makes that a
    /// fact about the code rather than a fact about the scheduler, and what handles a change that moves
    /// the property without satisfying the condition.
    ///
    /// Arming happens inside the continuation body, which runs synchronously before the suspension, so
    /// there is no window in which the condition could become true unobserved and leave this waiting
    /// for a change that has already happened.
    static func wait(until condition: @MainActor () -> Bool) async {
        while !condition() {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                withObservationTracking {
                    _ = condition()
                } onChange: {
                    continuation.resume()
                }
            }
        }
    }
}
