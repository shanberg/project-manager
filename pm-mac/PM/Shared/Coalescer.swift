import Foundation

/// Runs one job once for a burst of requests, on the next turn of the main queue.
///
/// **Why a turn rather than a delay.** `ConfigWatcher` debounces on a timer because it is smoothing
/// out the filesystem, where a "burst" is a cloud client writing four times over half a second. This
/// is smoothing out an observable model, where a burst is twenty property assignments in a single
/// synchronous block — `PMStore.reload` sets `projectKey`, `projectName`, `notesPath`, `projectPath`,
/// `notes`, `icon`, `todos`, `lastEditedAt`, `focusedKey`, `errorMessage` and `hasLoaded` one after
/// another, and each one is announced. There is no interval to tune: the right moment is "once the
/// block that is writing has finished writing", and that is the next turn.
///
/// **The hop is not optional.** The announcement arrives *before* the new value is visible — under
/// `ObservableObject` because `objectWillChange` fired from `willSet`, and under `@Observable` because
/// `withObservationTracking`'s `onChange` does the same. A handler that reads the store synchronously
/// sees the value it is being told is about to change, so it has to defer by at least one turn whether
/// it coalesces or not. This gives that deferral and the coalescing together.
///
/// Its user is now `ObservationRelay`, which adds the re-arming that observation needs and Combine
/// did not.
///
/// **Retain cycles are the caller's to avoid.** The job is held for the life of the coalescer, so an
/// owner that holds a coalescer and passes a closure capturing `self` strongly has made a cycle.
/// Capture weakly.
@MainActor
final class Coalescer {
    private let job: @MainActor () -> Void
    private var isScheduled = false

    init(_ job: @escaping @MainActor () -> Void) {
        self.job = job
    }

    /// Ask for the job to run. The first call in a turn schedules it; the rest are free.
    func schedule() {
        guard !isScheduled else { return }
        isScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // Cleared *before* the job runs, so a job that itself causes another request gets a fresh
            // pass next turn rather than being swallowed. Clearing afterwards would drop the change a
            // reload-triggered-by-a-reload is trying to report.
            self.isScheduled = false
            self.job()
        }
    }

    /// Whether a run is already booked for this turn. For tests, and for a caller that wants to know
    /// it is about to be asked anyway.
    var isPending: Bool { isScheduled }
}
