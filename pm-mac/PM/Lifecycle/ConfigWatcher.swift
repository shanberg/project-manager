import Foundation

/// Watches the pm config directory and the focused project's notes file for changes and fires a
/// debounced callback. Replaces the Tauri panel's Rust `notify-debouncer-mini` watcher.
///
/// Two mechanisms run together:
///   * A `DispatchSource` vnode watch on the config dir and the notes file — the fast path for
///     in-place writes (CLI, Obsidian, Raycast writing `focused.json`).
///   * A periodic mtime **poll** as a reliable fallback. Vnode watches go stale after an atomic save
///     (write-temp-then-rename replaces the inode the descriptor points at) and frequently deliver
///     nothing at all on cloud-synced folders (iCloud/Google Drive). The poll only stats metadata —
///     no content reads — so it's cheap, and it reloads only when an mtime actually changes.
final class ConfigWatcher {
    private let onChange: () -> Void
    private let debounce: TimeInterval
    private let pollInterval: TimeInterval
    private let queue = DispatchQueue(label: "com.stuarthanberg.pm.watcher")

    private var dirSource: DispatchSourceFileSystemObject?
    private var dirFD: Int32 = -1
    /// One vnode watch per notes file — the app shows a project per window, so there are as many notes
    /// files in play as there are open windows (plus the focused one the menubar tracks).
    private var notesWatches: [String: (source: DispatchSourceFileSystemObject, fd: Int32)] = [:]
    private var pendingWork: DispatchWorkItem?

    private var pollTimer: DispatchSourceTimer?
    /// Notes paths currently being watched/polled (empty when nothing is open).
    private var currentNotesPaths: [String] = []
    /// The PARA root directories. Polled for their own mtime, which changes when a folder is created,
    /// renamed, archived or deleted inside them — none of which touches a file this otherwise watches.
    private var currentRootPaths: [String] = []
    /// Last-seen combined mtime signature of the watched files; a change triggers `onChange`.
    private var lastSignature: String = ""

    init(debounce: TimeInterval = 0.3, pollInterval: TimeInterval = 2.0, onChange: @escaping () -> Void) {
        self.onChange = onChange
        self.debounce = debounce
        self.pollInterval = pollInterval
    }

    /// Start watching the config dir and begin polling. Call `watchNotes(paths:)` when the set of open
    /// projects changes.
    func start() {
        watchDir(PMFiles.configDir.path)
        startPolling()
    }

    func stop() {
        dirSource?.cancel(); dirSource = nil
        for (_, watch) in notesWatches { watch.source.cancel() }
        notesWatches.removeAll()
        pollTimer?.cancel(); pollTimer = nil
    }

    /// (Re)point the notes-file watches at the projects currently on screen. Watches already covering a
    /// path are left alone, so opening a second window doesn't disturb the first window's watch.
    func watchNotes(paths: [String]) {
        let wanted = Set(paths)
        for (path, watch) in notesWatches where !wanted.contains(path) {
            watch.source.cancel()
            notesWatches[path] = nil
        }
        for path in wanted where notesWatches[path] == nil {
            addNotesWatch(path)
        }
        let snapshot = Array(wanted)
        queue.async { [weak self] in self?.currentNotesPaths = snapshot }
    }

    /// Open one notes-file vnode watch. Called from `watchNotes` and from `rearmNotesWatch`, both on the
    /// main queue — which is the only queue that touches `notesWatches`.
    private func addNotesWatch(_ path: String) {
        guard FileManager.default.fileExists(atPath: path) else { return }
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete, .extend], queue: queue)
        source.setEventHandler { [weak self, weak source] in
            guard let self else { return }
            self.fire()
            // A vnode watch survives a write in place but not a *replacement*. Obsidian, the CLI and
            // most editors save atomically — write a temp file, rename it over the target — which leaves
            // this descriptor pointing at an inode nothing will ever write to again. The source stays
            // alive and simply goes silent, so from the first atomic save onward the 2s poll was the
            // only thing still noticing that file. Re-open on the path to put the fast path back.
            if let flags = source?.data, flags.contains(.rename) || flags.contains(.delete) {
                self.rearmNotesWatch(path)
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        notesWatches[path] = (source, fd)
    }

    /// Replace a watch whose file has been swapped out from under it.
    private func rearmNotesWatch(_ path: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let existing = self.notesWatches[path] else { return }
            existing.source.cancel()
            self.notesWatches[path] = nil
            // The replacement isn't necessarily in place the instant the rename event lands, so give it
            // a beat. If it never arrives, the path simply stays unwatched and the poll covers it —
            // which is the same position we were in before, not a worse one.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self, self.notesWatches[path] == nil else { return }
                self.addNotesWatch(path)
            }
        }
    }

    /// (Re)point the poll at the PARA roots.
    ///
    /// A directory's mtime moves when its contents are added to, removed from, or renamed — so three
    /// extra `stat`s per poll are the whole cost of noticing a project archived, created or renamed by
    /// the CLI, by Raycast, or in Finder. Without them PM finds out at the next reload it happens to
    /// do for another reason, which for an idle app is not soon: the unblock announcement in
    /// particular is about a project *other* than the one you're in, so nothing else was going to ask.
    func watchRoots(paths: [String]) {
        let snapshot = paths.sorted()
        queue.async { [weak self] in
            guard let self, snapshot != self.currentRootPaths else { return }
            self.currentRootPaths = snapshot
            // Adopt the new signature without firing: gaining a watch isn't a change to what it
            // watches, and reloading here would make every launch reload twice.
            self.lastSignature = self.currentSignature()
        }
    }

    /// Check the watched files right now, outside the poll's cadence.
    ///
    /// Called when the app comes forward. The poll interval is a background-cost tradeoff, but the
    /// moment you switch back to PM from the editor you were just typing in is exactly when a stale
    /// view is most obvious — and it's also a moment when doing the work is free, because you are
    /// looking at the app rather than at whatever the poll was trying not to slow down.
    func pokeNow() {
        queue.async { [weak self] in self?.poll() }
    }

    private func watchDir(_ path: String) {
        dirFD = open(path, O_EVTONLY)
        guard dirFD >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: dirFD, eventMask: [.write, .rename, .delete, .extend], queue: queue)
        source.setEventHandler { [weak self] in self?.fire() }
        source.setCancelHandler { [weak self] in
            if let fd = self?.dirFD, fd >= 0 { close(fd); self?.dirFD = -1 }
        }
        source.resume()
        dirSource = source
    }

    // MARK: Polling fallback

    private func startPolling() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + pollInterval, repeating: pollInterval)
        timer.setEventHandler { [weak self] in self?.poll() }
        timer.resume()
        pollTimer = timer
        // Seed the signature so the first poll doesn't fire a spurious reload.
        lastSignature = currentSignature()
    }

    /// Reload only when a watched file's mtime changed since the last check.
    private func poll() {
        let signature = currentSignature()
        guard signature != lastSignature else { return }
        lastSignature = signature
        DispatchQueue.main.async { [weak self] in self?.onChange() }
    }

    /// Combined modification-time signature of the notes file and the config JSON that external tools
    /// (Raycast) write. Missing files contribute nothing. Metadata only — no content is read.
    private func currentSignature() -> String {
        var parts: [String] = []
        let fm = FileManager.default
        var paths = [
            PMFiles.configDir.appendingPathComponent("focused.json").path,
            PMFiles.configDir.appendingPathComponent("panel-settings.json").path,
        ]
        paths.append(contentsOf: currentNotesPaths.sorted())
        paths.append(contentsOf: currentRootPaths)
        for path in paths {
            if let date = (try? fm.attributesOfItem(atPath: path)[.modificationDate]) as? Date {
                parts.append("\(path):\(date.timeIntervalSince1970)")
            }
        }
        return parts.joined(separator: "|")
    }

    private func fire() {
        pendingWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // The dir vnode fires for *any* change in the config dir — including our own writes to
            // pm-mac.log, task-timing.json, and recent-projects.json, none of which are inputs we need
            // to reload for. Gate on the same mtime signature the poll uses so only the files external
            // tools write (focused.json / panel-settings.json / the notes file) actually trigger a
            // reload; otherwise our own bookkeeping writes cause a spurious reload storm.
            let signature = self.currentSignature()
            guard signature != self.lastSignature else { return }
            self.lastSignature = signature
            DispatchQueue.main.async { self.onChange() }
        }
        pendingWork = work
        queue.asyncAfter(deadline: .now() + debounce, execute: work)
    }
}
