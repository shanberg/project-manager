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

    /// Boards read off main and not yet taken: what `load` read, waiting for the store it becomes.
    private static var read: [URL: (result: Result<CanvasFileQueue.Read, Error>, stamp: Date?)] = [:]
    /// Loads out, and who is waiting on each.
    private static var loading: [URL: [@MainActor () -> Void]] = [:]

    /// The store for this file, made if nobody has it open. Every call must be paired with `release`.
    ///
    /// From what `load` read when it has; otherwise the file is read here, on main — so a caller that
    /// can wait calls `load` first, or asks `storeIfReady`.
    static func store(for url: URL) throws -> CanvasDocumentStore {
        let key = url.standardizedFileURL
        if let ready = try take(key) { return ready }
        return hold(CanvasDocumentStore(url: key, read: try CanvasFileQueue.readNow(key)), key)
    }

    /// The store, when it can be had without reading the file: open already, or read by `load`. Paired
    /// with `release` like `store(for:)`. Nil otherwise — and for a file that wouldn't read, which
    /// `store(for:)` reports.
    static func storeIfReady(for url: URL) -> CanvasDocumentStore? {
        try? take(url.standardizedFileURL)
    }

    /// Whether `store(for:)` would answer without reading the file: open, or read and still current.
    static func isReady(_ url: URL) -> Bool {
        let key = url.standardizedFileURL
        if open[key] != nil { return true }
        guard let entry = read[key] else { return false }
        return entry.stamp == CanvasFileQueue.modified(key)
    }

    /// Read the file off main, on its own queue, so the next `store(for:)` or `storeIfReady` needn't.
    /// `then` runs on main once it can — at once for a board that's ready. A file that won't read is
    /// ready too: `store(for:)` throws what it threw.
    static func load(_ url: URL, then: @escaping @MainActor () -> Void) {
        let key = url.standardizedFileURL
        if isReady(key) { return then() }
        if loading[key] != nil {
            loading[key]?.append(then)
            return
        }
        loading[key] = [then]
        let reader = CanvasFileQueue.reader
        CanvasFileQueue.queue(for: key).async {
            let result = Result { () throws -> CanvasFileQueue.Read in
                CanvasFileQueue.Read(document: try reader(key), stamp: CanvasFileQueue.modified(key))
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if open[key] == nil {
                        read[key] = (result, (try? result.get())?.stamp ?? CanvasFileQueue.modified(key))
                    }
                    for job in loading.removeValue(forKey: key) ?? [] { job() }
                }
            }
        }
    }

    /// Load each board, then run `work` with their stores, then let them go. For an edit to a board that
    /// may not be open — a card moved between spaces — so it doesn't read the file on main.
    static func withStores(_ urls: [URL], _ work: @escaping @MainActor ([CanvasDocumentStore]) -> Void) {
        guard let first = urls.first else { return }
        load(first) {
            let rest = Array(urls.dropFirst())
            guard rest.isEmpty else {
                // Held meanwhile, so the first isn't let go — and read again — while the rest load.
                let held = storeIfReady(for: first)
                return withStores(rest) { stores in
                    work((held.map { [$0] } ?? []) + stores)
                    if let held { release(held) }
                }
            }
            guard let store = storeIfReady(for: first) else { return }
            work([store])
            release(store)
        }
    }

    /// The open store held once more, or one made from what `load` read. Nil when neither.
    private static func take(_ key: URL) throws -> CanvasDocumentStore? {
        if var entry = open[key] {
            entry.holders += 1
            open[key] = entry
            return entry.store
        }
        guard let entry = read.removeValue(forKey: key) else { return nil }
        // Changed since it was read: no good to anyone. The caller reads again.
        guard entry.stamp == CanvasFileQueue.modified(key) else { return nil }
        return hold(CanvasDocumentStore(url: key, read: try entry.result.get()), key)
    }

    private static func hold(_ store: CanvasDocumentStore, _ key: URL) -> CanvasDocumentStore {
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

    /// At quit: ask every open board for its write. They land on their queues; see
    /// `CanvasFileQueue.finishAll`.
    static func saveAll() {
        for entry in open.values { entry.store.save() }
    }

    /// Whether this file is already open somewhere, for a caller deciding whether it is about to make a
    /// second view of a document or the first.
    static func isOpen(_ url: URL) -> Bool { open[url.standardizedFileURL] != nil }
}
