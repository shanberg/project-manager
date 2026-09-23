import Foundation

/// Notices when a file a card is showing changes on disk — Obsidian saved it, a sync landed, a script
/// rewrote it — so the card can show what the file says now rather than what it said when drawn.
///
/// **Polled, like the canvas itself** (`CanvasDocumentStore.startWatching`). A vnode watch on the file
/// is lost the first time something saves by writing a new file and renaming it over the old one, which
/// is how most editors and every sync client save; a modification date survives that. One timer for
/// every card rather than one each, and only for the cards that are drawing a file — a board of forty
/// is forty `stat`s every couple of seconds.
@MainActor
final class CanvasFileWatch {
    static let shared = CanvasFileWatch()

    /// What a file looked like the last time anybody checked: when it was changed and how long it is.
    /// Size as well as date, because a save within the same second as the last one keeps the date.
    struct Stamp: Equatable {
        let modified: Date
        let size: Int

        init?(_ url: URL) {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let modified = attributes[.modificationDate] as? Date else { return nil }
            self.modified = modified
            size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        }
    }

    private struct Watch {
        let url: URL
        var stamp: Stamp?
        let changed: () -> Void
    }

    private var watches: [ObjectIdentifier: Watch] = [:]
    private var timer: Timer?
    static let interval: TimeInterval = 1.5

    /// Tell `owner` when `url` changes, replacing whatever it was watching. What the file is now is the
    /// baseline: the owner has just read it.
    func watch(_ owner: AnyObject, _ url: URL, changed: @escaping () -> Void) {
        let key = ObjectIdentifier(owner)
        watches[key] = Watch(url: url, stamp: Stamp(url), changed: changed)
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { _ in
            MainActor.assumeIsolated { CanvasFileWatch.shared.check() }
        }
    }

    func stop(_ owner: AnyObject) {
        watches[ObjectIdentifier(owner)] = nil
        if watches.isEmpty {
            timer?.invalidate()
            timer = nil
        }
    }

    /// Accept what the file is now as seen — for an owner that has just written it itself, so its own
    /// save doesn't come back to it as somebody else's.
    func acknowledge(_ owner: AnyObject) {
        let key = ObjectIdentifier(owner)
        guard let watch = watches[key] else { return }
        watches[key]?.stamp = Stamp(watch.url)
    }

    /// Look at every watched file once. Called by the timer; a test calls it directly.
    func check() {
        var fired: [() -> Void] = []
        for (key, watch) in watches {
            let now = Stamp(watch.url)
            guard now != watch.stamp else { continue }
            watches[key]?.stamp = now
            fired.append(watch.changed)
        }
        // After the pass: a card answering a change may stop or restart its own watch.
        fired.forEach { $0() }
    }
}
