import Foundation

/// One sitting of writing in a file card: what the file said when you started, what it says now, and
/// the write that puts the second on disk.
///
/// - **Written shortly after you stop, and always on the way out.** Every keystroke to disk would be a
///   file event per character for Obsidian, iCloud and anything else watching the vault; a write only
///   on stepping out would lose a sitting to a crash. Half a second after the last change is neither.
/// - **Written off main.** A file on a cloud drive whose provider has stalled holds a write in the
///   kernel indefinitely. Writes go to a serial queue per file, so they land in the order asked.
/// - `synced` is what the file holds once the writes asked for have landed. A write that fails puts
///   it back to what last landed, so the typing still counts as unsaved and the next change retries.
/// - Quit waits a bounded time for writes still out (`finishAll`); one still stuck is logged.
@MainActor
final class CanvasDocSession {
    let url: URL
    /// What the file held when you stepped in — the half of "was this ever a card?" that
    /// `CanvasDocCards` needs besides what it holds now.
    let opening: String
    private(set) var text: String
    /// What the file holds as far as this session knows — what it read, or the last write asked for.
    /// The difference between this and `text` is typing not yet on its way to disk.
    private(set) var synced: String
    /// What the last write that landed put on disk.
    private var landed: String
    /// Writes asked for and not landed.
    private(set) var writesInFlight = 0
    var isWriting: Bool { writesInFlight > 0 }
    private var pending: DispatchWorkItem?
    /// Called after each write lands, so the card's watch can take the write as its own. See
    /// `CanvasFileWatch.acknowledge`.
    var onWrite: (() -> Void)?

    /// How a write is made. A test stands in a slow or stuck one.
    nonisolated(unsafe) static var writer: @Sendable (String, URL) throws -> Void = { text, url in
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// How long after the last change a write is asked for.
    static var delay: TimeInterval = 0.5

    /// `text` is the file as just read — off main, by the card. See `CanvasFileNodeView.opening`.
    init(url: URL, text read: String) {
        self.url = url
        opening = read
        text = read
        synced = read
        landed = read
        Self.live.add(self)
    }

    var hasUnsavedEdits: Bool { text != synced }

    /// Take the file's version as this session's — something else changed it, and nothing here was
    /// waiting to be written.
    func adopt(_ disk: String) {
        pending?.cancel()
        pending = nil
        text = disk
        synced = disk
        landed = disk
    }

    func changed(_ edited: String) {
        text = edited
        pending?.cancel()
        // The editor reporting back text that is already the file — an adopted change arriving through
        // the binding — is nothing to write.
        guard edited != synced else { pending = nil; return }
        let write = DispatchWorkItem { [weak self] in self?.flush() }
        pending = write
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.delay, execute: write)
    }

    /// Ask for the write now, if anything is waiting. Returns at once; the write lands later.
    func flush() {
        guard let write = pending else { return }
        write.cancel()
        pending = nil
        let text = text, url = url, writer = Self.writer
        synced = text
        writesInFlight += 1
        Self.queue(for: url).async {
            let failure: Error?
            do { try writer(text, url); failure = nil } catch { failure = error }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.landed(text, failure) }
            }
        }
    }

    private func landed(_ written: String, _ failure: Error?) {
        writesInFlight -= 1
        if let failure {
            Log.write("writing a card's file failed: \(failure)")
            if writesInFlight == 0 { synced = landed }
            return
        }
        landed = written
        onWrite?()
    }

    /// Run `work` on this file's write queue once every write asked for so far has landed — a rename
    /// or a removal that must not overtake them — then `then` on main with what it threw.
    func afterWrites(_ work: @escaping @Sendable () throws -> Void,
                     then: @escaping @MainActor (Error?) -> Void = { _ in }) {
        Self.queue(for: url).async {
            let failure: Error?
            do { try work(); failure = nil } catch { failure = error }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { then(failure) }
            }
        }
    }

    // MARK: Every session

    private static let live = NSHashTable<CanvasDocSession>.weakObjects()
    private static var queues: [String: DispatchQueue] = [:]

    private static func queue(for url: URL) -> DispatchQueue {
        let key = url.standardizedFileURL.path
        if let queue = queues[key] { return queue }
        let queue = DispatchQueue(label: "Folio.doc-writes", qos: .userInitiated)
        queues[key] = queue
        return queue
    }

    /// At quit: ask for every waiting write, then wait up to `timeout` for all of them to land. False
    /// if one hasn't — a provider that stalled — which is logged; quitting anyway beats hanging.
    @discardableResult
    static func finishAll(timeout: TimeInterval = 2) -> Bool {
        live.allObjects.forEach { $0.flush() }
        let group = DispatchGroup()
        for queue in queues.values {
            group.enter()
            queue.async { group.leave() }
        }
        guard group.wait(timeout: .now() + timeout) == .success else {
            Log.write("quit with a card's write still out after \(timeout)s")
            return false
        }
        return true
    }
}
