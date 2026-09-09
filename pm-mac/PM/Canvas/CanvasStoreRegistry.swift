import AppKit
import PmLib

/// One `CanvasDocumentStore` per file, however many surfaces are showing it.
///
/// One board can be up in two windows at once, and in two tabs of one window.
/// Two stores on one file would be worse than either alone: each debounces its own saves and each polls
/// the file for outside changes, so a save by one arrives at the other as somebody else's edit, gets
/// reloaded over the top, and takes any in-flight work there with it. Sharing the store makes both
/// surfaces views of one document, with one undo stack and one answer about what is on disk.
///
/// This is the same shape as `StoreRegistry`, which does it for projects, and for the same reason —
/// so the pattern is the app's rather than this feature's.
///
/// **Retained by count, not by weak reference.** A weak table would drop a store the instant the last
/// view of it was torn down, which happens in the middle of switching a project window between the task
/// list and the board: the pane goes away, the store dies with any pending save, and the new pane reads
/// the file back from before it. Holders check in and check out, and the store's watch and its final
/// save run when the last one leaves.
@MainActor
enum CanvasStoreRegistry {
    private static var open: [URL: (store: CanvasDocumentStore, holders: Int)] = [:]

    /// The store for this file, made if nobody has it open. Every call must be paired with `release`.
    static func store(for url: URL) throws -> CanvasDocumentStore {
        let key = url.standardizedFileURL
        if var entry = open[key] {
            entry.holders += 1
            open[key] = entry
            return entry.store
        }
        let store = try CanvasDocumentStore(url: key)
        store.startWatching()
        open[key] = (store, 1)
        return store
    }

    /// Give up a hold. The last one out saves and stops watching.
    static func release(_ store: CanvasDocumentStore) {
        let key = store.url.standardizedFileURL
        guard var entry = open[key], entry.store === store else { return }
        entry.holders -= 1
        guard entry.holders <= 0 else {
            open[key] = entry
            return
        }
        open.removeValue(forKey: key)
        store.stopWatching()
        store.save()
    }

    /// Whether this file is already open somewhere, for a caller deciding whether it is about to make a
    /// second view of a document or the first.
    static func isOpen(_ url: URL) -> Bool { open[url.standardizedFileURL] != nil }
}
