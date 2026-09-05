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
@MainActor
final class CanvasDocumentStore {
    private(set) var document: CanvasDocument
    let url: URL
    let resolver: CanvasFileResolver

    /// Called after any change to `document`, whoever made it — an edit, an undo, or a reload because
    /// the file changed underneath us.
    var onChange: (() -> Void)?
    /// Called when the file was changed by something else and has been re-read. The window says so
    /// rather than swapping the board out silently.
    var onReloadedFromDisk: (() -> Void)?

    private let undoManager: UndoManager
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

    init(url: URL, undoManager: UndoManager) throws {
        self.url = url
        self.undoManager = undoManager
        self.document = try CanvasDocument.read(contentsOf: url)
        self.resolver = CanvasFileResolver(canvas: url)
        self.knownStamp = Self.modified(url)
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
    func change(_ actionName: String, _ mutate: (inout CanvasDocument) -> Void) {
        var next = document
        mutate(&next)
        guard next != document else { return }

        if interaction == nil {
            registerUndo(restoring: document, actionName: actionName)
        }
        document = next
        onChange?()
        scheduleSave()
    }

    /// Change the document without touching the undo stack.
    ///
    /// For housekeeping that undoes something the user never committed to — the empty card left behind
    /// by a double-click in the wrong place. Registering an undo for that would put a step on the
    /// stack whose only effect is to bring the empty card back, which is not a thing anyone means by
    /// ⌘Z. It still saves: the file should match the board.
    func changeQuietly(_ mutate: (inout CanvasDocument) -> Void) {
        var next = document
        mutate(&next)
        guard next != document else { return }
        document = next
        onChange?()
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

    private func registerUndo(restoring previous: CanvasDocument, actionName: String) {
        undoManager.registerUndo(withTarget: self) { store in
            MainActor.assumeIsolated { store.replace(with: previous, actionName: actionName) }
        }
        undoManager.setActionName(actionName)
    }

    /// Undo and redo both land here, each registering the other.
    private func replace(with next: CanvasDocument, actionName: String) {
        let previous = document
        document = next
        registerUndo(restoring: previous, actionName: actionName)
        onChange?()
        scheduleSave()
    }

    // MARK: Writing it

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.save() } }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.saveDelay, execute: work)
    }

    /// Write now — on ⌘S, and when the window closes.
    func save() {
        saveWork?.cancel()
        saveWork = nil
        do {
            try document.write(to: url)
            knownStamp = Self.modified(url)
        } catch {
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
    func checkForOutsideChange() {
        guard let stamp = Self.modified(url), stamp != knownStamp else { return }
        guard let reloaded = try? CanvasDocument.read(contentsOf: url) else { return }
        saveWork?.cancel()
        saveWork = nil
        knownStamp = stamp
        guard reloaded != document else { return }
        document = reloaded
        resolver.refresh()
        onChange?()
        onReloadedFromDisk?()
    }

    private static func modified(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}
