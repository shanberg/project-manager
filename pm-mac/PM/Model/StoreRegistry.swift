import Foundation

/// Vends the app's `PMStore`s, one per project, shared by everything showing that project.
///
/// With a window per project there is no longer a single store. Two things make sharing (rather than a
/// store per window) the right call: a project open in two windows must show one undo stack and one set
/// of edits — two stores would drift — and each store re-reads the notes file on every watcher tick, so
/// duplicates cost real IO on a protected folder.
///
/// Holders acquire a store and release it when they're done; the store is dropped when the last holder
/// lets go. The menubar is a holder like any other — it acquires the store for whatever project
/// `focused.json` names and re-acquires when that changes — so when a window is showing the focused
/// project, the menubar and that window are looking at the *same* store.
@MainActor
final class StoreRegistry {
    static let shared = StoreRegistry()

    private var stores: [String: PMStore] = [:]
    private var retainCounts: [String: Int] = [:]

    /// Stands in when there is no focused project at all, so callers always have a store to show (it
    /// renders the empty state). Not refcounted — it holds nothing.
    let emptyStore = PMStore()

    /// The store for a project, created on first acquire. Balance every call with `release`.
    func acquire(_ projectKey: String) -> PMStore {
        retainCounts[projectKey, default: 0] += 1
        if let existing = stores[projectKey] { return existing }
        let store = PMStore(boundKey: projectKey)
        stores[projectKey] = store
        store.reload()
        return store
    }

    /// Acquire the store for `projectKey`, or the empty store when it's nil.
    func acquire(_ projectKey: String?) -> PMStore {
        projectKey.map { acquire($0) } ?? emptyStore
    }

    func release(_ projectKey: String?) {
        guard let projectKey, let count = retainCounts[projectKey] else { return }
        if count <= 1 {
            retainCounts[projectKey] = nil
            stores[projectKey] = nil
        } else {
            retainCounts[projectKey] = count - 1
        }
    }

    /// Every store currently alive. Used by the config watcher to reload them all when something
    /// changes on disk.
    var liveStores: [PMStore] { Array(stores.values) }

    /// The notes files every live store is showing, for the watcher to keep an eye on.
    var watchedNotesPaths: [String] { liveStores.compactMap(\.notesPath) }
}
