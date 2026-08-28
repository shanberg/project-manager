import Foundation
import Combine
import PmLib

/// Everything you're waiting on, across every project, grouped by what it's waiting on.
///
/// **Its own scan, not the warmed index.** `ProjectIndex.openTasks` already holds every open task and
/// would have answered this for free — but it is gated on a sidebar being open, capped at a hundred
/// projects, and carries no digest, so a row built from it could be listed but not acted on. This is a
/// window somebody opens on purpose to deal with a list, so it pays for one honest scan and gets rows
/// that can be written to. `waitingBuckets` is the same walk the CLI and a model make for the same
/// question, which is the point: one answer, three surfaces.
@MainActor
final class WaitingModel: ObservableObject {
    @Published private(set) var buckets: [WaitingBucket] = []
    @Published private(set) var isLoading = false
    /// Set when a scan or a write failed, so the window says so rather than showing an empty list.
    @Published private(set) var failure: String?
    /// Whether archived projects' own tasks are listed too. Off by default: an archived project's
    /// unfinished tasks were put down, not blocked.
    @Published var includesArchived = false { didSet { reload() } }

    private var cancellables: Set<AnyCancellable> = []
    private let queue = DispatchQueue(label: "com.stuarthanberg.pm.waiting")
    /// Rising counter so a slow scan can't overwrite a newer one that already landed.
    private var generation = 0

    init() {
        // The folder scan is what turns a wait from pending to released, and it is ungated — so the
        // list follows an archive made in another window without this window doing any polling.
        ProjectIndex.shared.$waitRoots
            .dropFirst()
            .sink { [weak self] _ in Task { @MainActor in self?.reload() } }
            .store(in: &cancellables)
    }

    var isEmpty: Bool { buckets.isEmpty && !isLoading && failure == nil }

    /// How many tasks are listed, for the window's subtitle.
    var taskCount: Int { buckets.reduce(0) { $0 + $1.tasks.count } }

    var releasedCount: Int { buckets.filter { $0.state == "released" }.count }

    func reload() {
        generation += 1
        let mine = generation
        let archived = includesArchived
        isLoading = true
        queue.async { [weak self] in
            let result = Result { try waitingBuckets(includeArchived: archived) }
            Task { @MainActor in
                guard let self, mine == self.generation else { return }
                self.isLoading = false
                switch result {
                case .success(let buckets):
                    self.buckets = buckets
                    self.failure = nil
                    Log.write("waiting scan: \(buckets.count) target(s), \(self.taskCount) task(s), "
                              + "\(self.releasedCount) released")
                case .failure(let error):
                    self.failure = PMContract.message(for: error)
                    Log.write("waiting scan FAILED: \(error)")
                }
            }
        }
    }

    // MARK: Acting on a wait

    /// Stop waiting — on one task, or on every task in a group.
    ///
    /// The action the released band exists for. A project landing doesn't edit the tasks that were
    /// waiting on it (nothing writes into another project's file, which is the whole storage model),
    /// so the tokens stay until somebody clears them. Doing that one row at a time, in the project
    /// each row lives in, is exactly the errand this window was built to spare you.
    ///
    /// **Only the tasks that declare a wait are written to.** A group lists everything the target is
    /// holding up, and most of those are usually children of one waiting parent — they carry no
    /// `waiting:` of their own, and a `clearWaiting` aimed at one edits a line that doesn't have the
    /// token and reports nothing changed. Clearing the parent frees them all, which is the whole point
    /// of inheritance, so the right write is the smaller one.
    ///
    /// Grouped by project because one write per project is what `task.setWaiting` takes a `tasks` list
    /// for, and because a stale digest then fails that project's write alone rather than the batch.
    func stopWaiting(_ tasks: [TaskSearchHit]) {
        let declared = tasks.filter { $0.waiting != nil }
        guard !declared.isEmpty else {
            // Every one of them inherits, and the line that declares the wait isn't in the list —
            // an ancestor that's already ticked off, most likely. Saying so beats a button that
            // reports success and leaves the rows exactly where they were.
            failure = "These inherit their wait from a task that isn't listed here. "
                + "Clear it on that task instead."
            return
        }
        let byProject = Dictionary(grouping: declared, by: \.projectFolder)
        queue.async { [weak self] in
            var failures: [String] = []
            for (project, hits) in byProject {
                var input = ApiInput()
                input.project = project
                input.tasks = hits.map {
                    TaskRefInput(session: $0.session ?? "", line: $0.line, digest: $0.digest)
                }
                input.clearWaiting = true
                do { _ = try PMContract.perform("task.setWaiting", input) }
                catch { failures.append(PMContract.message(for: error)) }
            }
            let reported = failures.first
            Task { @MainActor in
                guard let self else { return }
                self.failure = reported
                self.reload()
            }
        }
    }

    /// Open the window for the project a row lives in.
    func open(_ hit: TaskSearchHit) {
        WindowManager.shared.open(projectKey: hit.projectKey)
    }

    /// Open the window for the project a group names, when it names one PM can find.
    func open(_ bucket: WaitingBucket) {
        guard let folder = bucket.folder,
              let key = ProjectIndex.shared.projectKey(forFolder: folder) else { return }
        WindowManager.shared.open(projectKey: key)
    }
}
