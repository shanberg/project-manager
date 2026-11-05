import AppKit
import PmLib

/// One open canvas: the document, the undo stack, and the file underneath it.
///
/// The file is very likely open in Obsidian at the same time — that is the normal way to use this, not
/// an edge case — so two things follow. Writes are **atomic**, because a reader that catches a
/// half-written canvas doesn't get an error, it gets a board with the bottom half of its cards missing
/// and may well save that back. And the file is **watched**, because the other app will change it, and
/// a PM window holding a stale document would overwrite that change on its next autosave.
///
/// Saving is automatic and debounced: a canvas is dragged around, and a save per frame of a drag would
/// be absurd while a save only on ⌘S would mean a window you can lose work from.
///
/// **Read and written off main**, on the file's own queue (`CanvasFileQueue`). A board on a cloud drive
/// whose provider has stalled holds a read or a write in the kernel indefinitely, and on main that was the
/// app frozen. Saves land in the order asked; a re-read waits behind them. Opening a board reads it there
/// too — see `CanvasStoreRegistry.load`.
///
/// **One store per file, however many things are looking at it.** One board can be up in two windows at
/// once, and in two tabs of one window, and two stores on one file would be worse than either alone: each debounces its own writes and each watches the file for outside
/// changes, so a save by one is read by the other as somebody else's edit, reloaded over the top, and
/// whatever was in flight there is gone. `CanvasStoreRegistry` hands out the same store to every
/// holder, which makes both surfaces views of one document with one undo stack — the arrangement the
/// app already uses for projects. That is why the callbacks below are lists rather than single
/// closures, and why the undo manager is made here rather than handed in.
@MainActor
final class CanvasDocumentStore {
    private(set) var document: CanvasDocument
    let url: URL
    let resolver: CanvasFileResolver

    /// Everything looking at this document, and what to tell each of them.
    ///
    /// Keyed by the watcher so a surface that goes away takes its callbacks with it, and held weakly on
    /// nothing — the registry's retain count is what keeps a store alive, and a watcher is expected to
    /// say when it is done.
    private var watchers: [(owner: ObjectIdentifier, changed: () -> Void, reloaded: () -> Void)] = []

    /// Watch this document. `changed` fires after any change, whoever made it — an edit, an undo, or a
    /// reload because the file changed underneath us. `reloaded` fires only for that last case, which
    /// a window says out loud rather than swapping the board out silently.
    func addWatcher(_ owner: AnyObject, changed: @escaping () -> Void,
                    reloaded: @escaping () -> Void) {
        let id = ObjectIdentifier(owner)
        watchers.removeAll { $0.owner == id }
        watchers.append((id, changed, reloaded))
    }

    func removeWatcher(_ owner: AnyObject) {
        let id = ObjectIdentifier(owner)
        watchers.removeAll { $0.owner == id }
    }

    private func documentChanged() {
        for watcher in watchers { watcher.changed() }
        Self.onDocumentChanged?(self)
    }
    private func documentReloaded() {
        for watcher in watchers { watcher.reloaded() }
        Self.onDocumentChanged?(self)
    }

    /// Told of every change to every board's document, whoever made it. For the app's own bookkeeping
    /// across boards — a project's links (`ProjectLinksSync`) — and unset wherever there is no app.
    static var onDocumentChanged: ((CanvasDocumentStore) -> Void)?

    /// This document's undo stack, which every window showing it shares. A window hands it back from
    /// `windowWillReturnUndoManager` so ⌘Z reaches the board rather than whatever text field last had
    /// focus — and so undoing in one surface undoes in the other, which is the only coherent answer
    /// when both are the same document.
    ///
    /// With one exception, which is the Mac's own: a card you are standing in and typing into has its
    /// own stack while its editor is open, and ⌘Z there undoes your typing rather than the board. What
    /// reaches this stack is the whole session, as the one step its first keystroke registered — see
    /// `CanvasCardEditing.hasWritten`.
    let undoManager: UndoManager
    private var saveWork: DispatchWorkItem?
    /// The modification date of the last write we made or read. What tells our own save apart from
    /// Obsidian's — without it, every autosave would look like an outside change and trigger a reload.
    private var knownStamp: Date?
    private var watch: Timer?

    /// How long after the last change the file is written.
    private static let saveDelay: TimeInterval = 0.8
    /// How often the file is checked for an outside change while the window is open. A `stat`, so the
    /// cost is nothing; the interval is about how long you'd tolerate seeing a stale board.
    private static let watchInterval: TimeInterval = 2

    /// A store on a document already read — off main, by `CanvasStoreRegistry.load`.
    init(url: URL, read: CanvasFileQueue.Read) {
        self.url = url
        self.undoManager = UndoManager()
        self.document = read.document
        self.written = read.document
        self.resolver = CanvasFileResolver(canvas: url)
        self.knownStamp = read.stamp
    }

    /// Reads the file here and now, on the caller's thread. For tests and for the registry's fallback.
    convenience init(url: URL) throws {
        self.init(url: url, read: try CanvasFileQueue.readNow(url))
    }

    deinit { watch?.invalidate() }

    // MARK: Changing it

    /// Apply a change, with undo.
    ///
    /// The whole previous document is captured rather than a description of what changed. That is
    /// heavy-handed in principle and free in practice — a canvas is a few tens of kilobytes of value
    /// types — and it buys the thing that matters: there is exactly one way to undo, so a new kind of
    /// edit cannot arrive with a subtly wrong inverse. `actionName` is what the Edit menu says.
    ///
    /// **During a gesture this registers nothing.** See `beginInteraction`.
    ///
    /// `shows` is whether the change can be seen: false for a setting nothing on screen draws (Mute,
    /// Keep Running), whose undo and redo then say on the HUD what they did — see `onUnseenUndo`.
    func change(_ actionName: String, shows: Bool = true, _ mutate: (inout CanvasDocument) -> Void) {
        var next = document
        mutate(&next)
        guard next != document else { return }

        if interaction == nil {
            registerUndo(restoring: document, actionName: actionName, shows: shows)
        }
        document = next
        documentChanged()
        scheduleSave()
    }

    /// Change the document without touching the undo stack.
    ///
    /// Two callers, for the same reason: what they do is not a step ⌘Z should stop at.
    ///
    /// Housekeeping that undoes something the user never committed to — the empty card left behind by
    /// a double-click in the wrong place. Registering an undo for that would put a step on the stack
    /// whose only effect is to bring the empty card back, which is not a thing anyone means by ⌘Z.
    ///
    /// And **a keystroke in a card you are typing in**, after the first one. ⌘Z there means the
    /// editor's own stack, coalesced into typing bursts the way it is in every other Mac text view;
    /// the document's one step for the session is registered by the keystroke that opened it, through
    /// `change` above. See `CanvasCardEditing.hasWritten`.
    ///
    /// Both still save: the file should match the board.
    func changeQuietly(_ mutate: (inout CanvasDocument) -> Void) {
        var next = document
        mutate(&next)
        guard next != document else { return }
        document = next
        documentChanged()
        scheduleSave()
    }

    /// A gesture in progress: the document as it stood when the mouse went down, and what to call it.
    private var interaction: (baseline: CanvasDocument, name: String)?

    /// Begin a gesture — a drag, a resize — so that all of it is one undo step.
    ///
    /// This used to be `UndoManager`'s own grouping, with every mouse-moved event registering an undo
    /// inside the group. ⌘Z behaved correctly, so the flaw was invisible: what it actually did was put
    /// one complete copy of the document on the stack *per event*, so dragging a card across a large
    /// board allocated several hundred snapshots and kept them all until the stack rolled over.
    ///
    /// Now the document is captured once here, the moves in between register nothing, and one undo is
    /// registered at the end — from the baseline straight to the result, which is what ⌘Z meant all
    /// along.
    func beginInteraction(_ actionName: String) {
        // A gesture already open means the last one never got its mouse-up — the window lost focus
        // mid-drag, most likely. Close it rather than nesting, or its baseline is lost and ⌘Z after it
        // walks back to somewhere the board never was.
        if interaction != nil { endInteraction() }
        interaction = (document, actionName)
    }

    func endInteraction() {
        guard let (baseline, name) = interaction else { return }
        interaction = nil
        guard baseline != document else { return }
        registerUndo(restoring: baseline, actionName: name)
    }

    /// True while a drag or resize is in flight — the board draws itself more cheaply.
    var isInteracting: Bool { interaction != nil }

    private func registerUndo(restoring previous: CanvasDocument, actionName: String, shows: Bool = true) {
        undoManager.registerUndo(withTarget: self) { store in
            MainActor.assumeIsolated { store.replace(with: previous, actionName: actionName, shows: shows) }
        }
        undoManager.setActionName(actionName)
        undoManager.setActionUserInfoValue(CanvasUndoStep(document: previous, store: self), forKey: Self.undoStepKey)
    }

    /// Where a step on the undo stack says what it would put back — for ⌘Z to read before it acts.
    /// See `CanvasUndoStep`.
    static let undoStepKey = UndoManager.UserInfoKey("PMCanvasDocumentStep")

    /// Undo or redo of a change nothing on screen shows, as a line for the HUD: "Undo Mute Card".
    /// Without it ⌘Z on one looks like a beep that didn't happen.
    var onUnseenUndo: ((String) -> Void)?

    /// Undo and redo both land here, each registering the other.
    private func replace(with next: CanvasDocument, actionName: String, shows: Bool) {
        let undoing = undoManager.isUndoing
        let previous = document
        document = next
        registerUndo(restoring: previous, actionName: actionName, shows: shows)
        documentChanged()
        scheduleSave()
        if !shows { onUnseenUndo?("\(undoing ? "Undo" : "Redo") \(actionName)") }
    }

    // MARK: Writing it

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.save() } }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.saveDelay, execute: work)
    }

    /// What the file holds as far as this store knows: what it read, or what the last write asked for.
    /// Nil after a write failed, so the next save writes whatever the board holds.
    private var written: CanvasDocument?
    /// Writes asked for and not landed. While any are out the file is ours, and the watch leaves it be.
    private(set) var writesInFlight = 0
    /// A re-read is out — see `checkForOutsideChange`.
    private(set) var isRereading = false

    /// Whether the board holds anything not yet on its way to disk.
    var hasUnsavedChanges: Bool { document != written }

    /// Ask for the write now — on ⌘S, when the window closes, and at quit. Returns at once; the write
    /// lands later, on the file's queue. Nothing to write is nothing asked for.
    func save() {
        saveWork?.cancel()
        saveWork = nil
        guard hasUnsavedChanges else { return }
        let document = document, url = url, writer = CanvasFileQueue.writer
        written = document
        writesInFlight += 1
        CanvasFileQueue.queue(for: url).async {
            let result = Result { () throws -> Date? in
                try writer(document, url)
                return CanvasFileQueue.modified(url)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.landed(result) }
            }
        }
    }

    private func landed(_ result: Result<Date?, Error>) {
        writesInFlight -= 1
        switch result {
        case .success(let stamp):
            knownStamp = stamp
        case .failure(let error):
            written = nil
            Log.write("canvas save failed: \(url.lastPathComponent): \(error)")
            presentSaveFailure(error)
        }
    }

    /// A failed save is the one error here that must not be swallowed. Everything else this file does
    /// degrades quietly on purpose — a card that won't resolve draws as missing, a colour it doesn't
    /// know draws as none — but a canvas that has silently stopped saving looks exactly like one that
    /// is saving, right up until the window closes.
    private func presentSaveFailure(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Couldn't save \(url.lastPathComponent)."
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: Reading it again

    /// Watch for a change made by something else — Obsidian, a sync client, a text editor.
    func startWatching() {
        watch?.invalidate()
        watch = Timer.scheduledTimer(withTimeInterval: Self.watchInterval, repeats: true) { _ in
            MainActor.assumeIsolated { self.checkForOutsideChange() }
        }
    }

    func stopWatching() {
        watch?.invalidate()
        watch = nil
    }

    /// Re-read the file if it has changed under us.
    ///
    /// Unsaved local work is written first rather than discarded — but a pending save is *ours* and by
    /// definition older than whatever just landed, so flushing it would be the overwrite this is here
    /// to prevent. Instead the pending save is dropped and the file wins, because the alternative is
    /// silently clobbering an edit made in the other app. The window says so; undo still holds
    /// everything PM did.
    ///
    /// - The check is a `stat` on main, which answers for any file without reading it.
    /// - The read and parse are on the file's queue, behind any write of ours. One at a time: a read
    ///   that never returns stops the checks, not the app.
    /// - Not while a write of ours is out: the stamp is about to be ours.
    /// - A save asked for while the read was out wins over what it read — that edit is newer still.
    func checkForOutsideChange() {
        guard !isRereading, writesInFlight == 0,
              let stamp = CanvasFileQueue.modified(url), stamp != knownStamp else { return }
        isRereading = true
        let url = url, reader = CanvasFileQueue.reader
        CanvasFileQueue.queue(for: url).async {
            let reloaded = try? reader(url)
            let stamp = CanvasFileQueue.modified(url) ?? stamp
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.reread(reloaded, stamp: stamp) }
            }
        }
    }

    private func reread(_ reloaded: CanvasDocument?, stamp: Date) {
        isRereading = false
        guard writesInFlight == 0 else { return }
        // Unreadable — half-written by something that doesn't write atomically, most likely. Taken as
        // seen, so it isn't read again every two seconds; the write that finishes it is a new stamp.
        knownStamp = stamp
        guard let reloaded else { return }
        saveWork?.cancel()
        saveWork = nil
        written = reloaded
        guard reloaded != document else { return }
        document = reloaded
        resolver.refresh()
        documentChanged()
        documentReloaded()
    }
}

/// Where board files are read and written: a serial queue per file, so a store's saves land in order,
/// a re-read waits behind them, and `ProjectLinksSync`'s edits of a closed board take turns with a store
/// opening it.
enum CanvasFileQueue {
    /// A board's document as read, and the file's modification date then.
    struct Read: Sendable {
        let document: CanvasDocument
        let stamp: Date?
    }

    /// How a board is read and written. A test stands in a slow or stuck one.
    nonisolated(unsafe) static var reader: @Sendable (URL) throws -> CanvasDocument = {
        // read: the reader hook; run on CanvasFileQueue, or by `readNow` where a caller chose to.
        try CanvasDocument.read(contentsOf: $0)
    }
    nonisolated(unsafe) static var writer: @Sendable (CanvasDocument, URL) throws -> Void = {
        try $0.write(to: $1)
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var queues: [String: DispatchQueue] = [:]

    static func queue(for url: URL) -> DispatchQueue {
        let key = url.standardizedFileURL.path
        lock.lock()
        defer { lock.unlock() }
        if let queue = queues[key] { return queue }
        let queue = DispatchQueue(label: "Folio.board-file", qos: .userInitiated)
        queues[key] = queue
        return queue
    }

    /// Read on the caller's thread.
    static func readNow(_ url: URL) throws -> Read {
        let document = try reader(url)
        return Read(document: document, stamp: modified(url))
    }

    /// `stat`'s modification date, which never downloads or waits on the file's contents.
    static func modified(_ url: URL) -> Date? {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        let time = info.st_mtimespec
        return Date(timeIntervalSince1970: Double(time.tv_sec) + Double(time.tv_nsec) / 1_000_000_000)
    }

    /// At quit: wait up to `timeout` for every board write asked for so far. False if one hasn't
    /// landed — a provider that stalled — which is logged; quitting anyway beats hanging.
    @discardableResult
    static func finishAll(timeout: TimeInterval = 2) -> Bool {
        lock.lock()
        let all = Array(queues.values)
        lock.unlock()
        let group = DispatchGroup()
        for queue in all {
            group.enter()
            queue.async { group.leave() }
        }
        guard group.wait(timeout: .now() + timeout) == .success else {
            Log.write("quit with a board's write still out after \(timeout)s")
            return false
        }
        return true
    }
}

/// What a step of the board's undo would put back: the whole document, and the store it is for.
///
/// Read off the top of the stack before ⌘Z runs (`UndoManager.undoActionUserInfoValue`), so a step
/// whose undoing would take away a card that is out in a window of its own — closing the window — can
/// be asked for twice first. See `PageFirstMenu.undoClosesWindows`.
@MainActor
final class CanvasUndoStep {
    let document: CanvasDocument
    weak var store: CanvasDocumentStore?

    init(document: CanvasDocument, store: CanvasDocumentStore) {
        self.document = document
        self.store = store
    }
}
