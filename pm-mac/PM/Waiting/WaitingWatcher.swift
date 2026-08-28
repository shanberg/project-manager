import Foundation
import Combine
import PmLib

/// The unblock moment: says once, out loud, when something you were waiting on lands.
///
/// ## What the event actually is
///
/// Archiving a project releases every task waiting on it, at once, in files that project never
/// touches — nothing writes into another project's notes, which is the whole storage model. So the
/// change arrives as several rows in several windows quietly turning green, most of them not on
/// screen. That is the one state change in this feature that a person needs told rather than shown.
///
/// ## What it watches
///
/// Not a timer, and not the task scan. The event *is* a folder arriving in the archive root, and
/// `ProjectIndex.waitRoots` already lists those folders, is ungated, and reloads with everything else.
/// So this watches the archive membership — three directory listings the app was doing anyway — and
/// only when a folder is genuinely new there does it pay for one `waitingBuckets` scan to find out
/// whether anything cared. Archive nothing and this costs nothing.
///
/// ## Why the baseline is persisted, and where
///
/// "Once" has to survive a quit, or archiving a project on Friday and opening PM on Monday says
/// nothing. So the archive membership as last seen is written down, and the first launch after this
/// shipped seeds it silently: a fresh install would otherwise announce every project ever archived,
/// which is the exact failure mode "announce once" exists to prevent. The set is *replaced* rather
/// than added to, so a project unarchived and archived again announces again — which is right,
/// because it is the same news a second time.
///
/// It lives in the config dir beside `recent-projects.json`, not in defaults, because the thing it
/// describes belongs to a vault and defaults belong to the app. `PM_CONFIG_HOME` points PM at another
/// vault with its own archive; one baseline shared between them would read every project in the
/// second vault's archive as newly landed and announce all of them at once. Which is precisely what
/// happened the first time this was tested against the dev vault.
@MainActor
final class WaitingWatcher {
    static let shared = WaitingWatcher()

    /// What was in the archive as of the last time anyone looked. A missing file — not an empty list —
    /// is a first run, which is how seeding tells itself apart from "the archive is empty".
    private static var seenURL: URL { PMFiles.configDir.appendingPathComponent("seen-archived.json") }

    /// What counts as "the same archived thing" across two looks: the code it carries, else its name.
    ///
    /// By code because the rest of this feature already decided the code is the identity and the title
    /// is commentary — see `matchWaitTarget`. Keying on the folder name instead would make *renaming
    /// an archived project* look like a fresh archiving and announce it again, which is stale news
    /// delivered as new. An area carries no code and falls back to its name, so renaming an archived
    /// area still re-announces; that is a rarer case with nothing stable to hold on to.
    private static func identity(of folder: String) -> String {
        projectCode(fromName: folder) ?? folder.lowercased()
    }

    private static func loadSeen() -> [String]? {
        guard let data = try? Data(contentsOf: seenURL) else { return nil }
        return try? JSONDecoder().decode([String].self, from: data)
    }

    private static func saveSeen(_ identities: Set<String>) {
        guard let data = try? JSONEncoder().encode(identities.sorted()) else { return }
        try? FileManager.default.createDirectory(at: PMFiles.configDir, withIntermediateDirectories: true)
        try? data.write(to: seenURL, options: .atomic)
    }

    /// Delivers the announcement. Held weakly-ish through the app delegate rather than owned, because
    /// the notification centre delegate has to be the one object registered with it.
    var announce: ((_ title: String, _ count: Int) -> Void)?

    private var cancellables: Set<AnyCancellable> = []
    private let queue = DispatchQueue(label: "com.stuarthanberg.pm.unblock")
    private var scanning = false

    private init() {}

    func start() {
        ProjectIndex.shared.$waitRoots
            .sink { [weak self] roots in
                Task { @MainActor in self?.archiveChanged(roots) }
            }
            .store(in: &cancellables)
    }

    private func archiveChanged(_ roots: [ProjectIndex.WaitRoot]) {
        // The very first published value is the empty list the index starts with, not an answer.
        guard !roots.isEmpty else { return }
        let archived = Set(roots.filter(\.scope.isArchived).flatMap(\.folders).map(Self.identity))

        guard let seen = Self.loadSeen() else {
            Self.saveSeen(archived)
            Log.write("unblock watcher seeded with \(archived.count) archived project(s)")
            return
        }
        let newly = archived.subtracting(seen)
        Self.saveSeen(archived)
        guard !newly.isEmpty, NotificationSettings.unblockAlerts, !scanning else { return }

        // One scan, only now, only because something was archived.
        scanning = true
        queue.async { [weak self] in
            let buckets = (try? waitingBuckets()) ?? []
            let landed = buckets.filter { bucket in
                bucket.state == "released"
                    && bucket.folder.map { newly.contains(Self.identity(of: $0)) } == true
            }
            Task { @MainActor in
                guard let self else { return }
                self.scanning = false
                for bucket in landed {
                    Log.write("unblocked: \(bucket.folder ?? bucket.target) — \(bucket.tasks.count) task(s)")
                    self.announce?(bucket.title, bucket.tasks.count)
                }
            }
        }
    }
}
