import AppKit
import PmLib

/// Today's session note, open for editing. One of these behind every surface that writes into a
/// session. What it holds is the session's whole body — the tasks written down in it as much as the
/// prose around them — so scrolling up amends the sitting rather than a preamble to it.
///
/// It exists because there used to be two contracts for the same file. The full-screen surface edited
/// today's whole note live — no save, no revert, every keystroke written through — while the quick
/// bar's note mode composed one paragraph and appended it on ⌘↩. Both were markdown editors on the
/// same prose, one keystroke apart (⌃⌘F took you from the second to the first), and they disagreed
/// about what Escape meant, what ⌘↩ meant, and whether what you could see was all of the note or the
/// end of it. Which of the two survived was a question the code left open in a comment.
///
/// This is the answer: **live, everywhere**. A note surface opens holding what's already there with
/// the caret at the end, so typing continues it and scrolling up amends it. There is nothing to save
/// and nothing to lose, which is what makes ⌃⌘F a change of size rather than a change of rules.
///
/// What this is *not* is a way to append one line without opening anything — that's the quick bar's
/// capture row, and it stays a capture rather than becoming a third editor. Filing a line and editing
/// the note are different gestures; two editors with opposite save semantics were the problem.
@MainActor
final class LiveSessionNote {
    /// The prose as it should now appear on screen — a fresh read, or a session that has just been
    /// started. Only ever called when the surface's own text needs replacing.
    var onProse: (String) -> Void = { _ in }
    /// Today's session label, for a surface that names what's being written into.
    var onSessionLabel: (String) -> Void = { _ in }
    /// The notes file, so a pasted picture can land beside the note rather than as plain text.
    var onNoteURL: (URL?) -> Void = { _ in }
    var onProjectName: (String?) -> Void = { _ in }

    private(set) var isOpen = false
    private(set) var store: PMStore?
    private var projectKey: String?
    /// Which session is being edited, asserted by digest so a write can be refused if the session it
    /// names has changed identity underneath. Nil until today's session exists.
    private var ref: SessionRef?
    /// The prose as it stood at the last agreed point — what was read on opening, and then whatever
    /// was last written. Two things use it: deciding whether there is anything to write, and telling a
    /// note that changed underneath us from one that didn't.
    private var seed = ""
    private var pendingWrite: DispatchWorkItem?
    /// Prose handed over from somewhere else, to be added once the note has been read. Consumed on the
    /// first seed, since a reload can seed twice.
    private var pendingAppend: String?

    /// Open the note for `projectKey`. Returns false when there's nothing to open it against.
    @discardableResult
    func open(projectKey key: String, appending carried: String? = nil) -> Bool {
        guard !isOpen else { return true }
        pendingAppend = carried?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? carried : nil
        let store = StoreRegistry.shared.acquire(key)
        self.store = store
        self.projectKey = key
        isOpen = true

        // Read before the surface is shown. The store may not be loaded yet — the surface then opens
        // empty and `seedFromStore` fills it in when the read lands, which is the one moment
        // `applyExternalChange` exists for.
        seedFromStore()
        if store.projectName == nil {
            store.reload { [weak self] in self?.seedFromStore() }
        }
        return true
    }

    /// Every keystroke arrives here; only the last one in a burst reaches the disk.
    ///
    /// Debounced rather than written per character because a write is a whole-file rewrite, and
    /// debounced *briefly* because the interval is exactly the window in which someone else's edit and
    /// this one can collide. Under a second is short enough that the surface still deserves to be
    /// called live, and long enough that a sentence is one write rather than forty.
    func changed(_ text: String) {
        guard isOpen else { return }
        pendingWrite?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flush(text) }
        pendingWrite = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.writeDelay, execute: work)
    }

    private static let writeDelay: TimeInterval = 0.6

    /// Close the note, writing whatever is in the editor now rather than on the debounce that was
    /// still counting. `then` runs once that write has landed and the store has re-read — which is
    /// what lets one surface hand over to another without the second reading a stale document.
    func close(_ finalText: String, then: (@MainActor () -> Void)? = nil) {
        guard isOpen else { then?(); return }
        isOpen = false
        pendingWrite?.cancel()
        pendingWrite = nil
        flush(finalText, then: { [weak self] in
            guard let self else { then?(); return }
            StoreRegistry.shared.release(self.projectKey)
            self.store = nil
            self.projectKey = nil
            self.ref = nil
            self.seed = ""
            self.pendingAppend = nil
            then?()
        })
    }

    /// A note changed on disk while this was open — the config watcher's signal. Only replaces what's
    /// on screen when the surface itself has no unwritten changes, since the merge on the next flush
    /// is the better answer while it does.
    func applyExternalChangeIfIdle(currentText: String) {
        guard isOpen, pendingWrite == nil, let store else { return }
        let disk = Self.currentProse(in: store)
        guard disk != seed, currentText == seed else { return }
        seed = disk
        onProse(disk)
    }

    // MARK: Reading

    /// Fill the surface from the store: today's note, the project it belongs to, and the file it lives
    /// in.
    private func seedFromStore() {
        guard let store, isOpen else { return }
        onProjectName(store.projectName.map { ProjectCodes.display($0) })
        onNoteURL(store.notesPath.map { URL(fileURLWithPath: $0) })
        guard let index = store.todaySessionIndex, let sessions = store.notes?.sessions,
              index < sessions.count else {
            // No session for today yet. One will be started by the first thing written — see `flush`.
            onSessionLabel("Today")
            ref = nil
            if let carried = pendingAppend {
                pendingAppend = nil
                seed = ""
                onProse(carried)
                changed(carried)
            }
            return
        }
        let session = sessions[index]
        onSessionLabel(session.label.isEmpty ? "Today" : session.label)
        ref = store.sessionRef(at: index)
        let prose = sessionNoteBody(body: session.body)
        seed = prose
        guard let carried = pendingAppend else {
            onProse(prose)
            return
        }
        pendingAppend = nil
        // A blank line between, which is how the file separates paragraphs and how the note would have
        // read if the line had been appended rather than carried in.
        let joined = prose.isEmpty ? carried : prose + "\n\n" + carried
        onProse(joined)
        // Written through at once rather than waiting for a keystroke: the paragraph came from
        // somewhere that was about to save it, and changing surface must not be a way of losing it.
        changed(joined)
    }

    // MARK: Writing

    /// Put the prose on disk. What to write when someone else has been at the same note is
    /// `SessionNoteMerge`'s judgement, not this method's.
    private func flush(_ text: String, then: (@MainActor () -> Void)? = nil) {
        pendingWrite = nil
        guard let store, store.projectName != nil else { then?(); return }

        // No session for today yet: the first thing written starts one, which is what
        // `appendSessionNote` is for. Everything after that is an edit of the session it just made.
        guard let ref else {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { then?(); return }
            store.appendSessionNote(text) { [weak self] in
                guard let self, let store = self.store else { then?(); return }
                self.seed = text
                if let index = store.todaySessionIndex {
                    self.ref = store.sessionRef(at: index)
                    if let sessions = store.notes?.sessions, index < sessions.count {
                        self.onSessionLabel(sessions[index].label.isEmpty
                                            ? "Today" : sessions[index].label)
                    }
                }
                Log.write("session note started today's session")
                then?()
            }
            return
        }

        switch SessionNoteMerge.resolve(edited: text, onDisk: Self.currentProse(in: store), seed: seed) {
        case .unchanged:
            seed = text
            then?()
        case .replace(let prose):
            seed = prose
            store.setSessionNote(ref, body: prose, then: then)
        case .merged(let prose):
            seed = prose
            Log.write("session note merged an edit made elsewhere while it was open")
            store.setSessionNote(ref, body: prose, then: then)
        case .overwrote(let prose):
            seed = prose
            Log.write("session note overwrote an edit made elsewhere while it was open")
            store.setSessionNote(ref, body: prose, then: then)
        }
    }

    /// Today's prose as the store currently has it.
    private static func currentProse(in store: PMStore) -> String {
        guard let index = store.todaySessionIndex, let sessions = store.notes?.sessions,
              index < sessions.count else { return "" }
        return sessionNoteBody(body: sessions[index].body)
    }
}
