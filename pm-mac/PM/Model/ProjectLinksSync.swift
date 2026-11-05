import AppKit
import PmLib

/// Keeps a project's links — web cards in the Links frame on its canvas — and the `## Links` in its notes
/// saying the same thing. The rules are `ProjectLinksFrame.sync`'s; this is only when and where it runs.
///
/// **Both ways round, from the two places either side changes.** A project's notes being read — which
/// happens after every write to them, from here, `pm`, Raycast or Obsidian — brings in what was typed
/// into `## Links`. A board's document changing brings in what was done to the frame. Each ends by
/// writing the other side, which is read or changed in turn, and finds nothing left to do.
///
/// **Through the board when it is open.** A canvas on screen has a store with its own saving and its own
/// watch on the file (`CanvasDocumentStore`); writing the file under it would be read back as somebody
/// else's edit, over whatever it hadn't saved yet. So an open canvas is changed through its store —
/// quietly, because a sync is not a step ⌘Z should stop at — and a closed one is read and written here.
@MainActor
enum ProjectLinksSync {
    /// Listen to every board, for changes to a Links frame. Once, at launch.
    static func install() {
        PMStore.onNotesRead = { notesPath, projectPath in sync(notesPath: notesPath, projectPath: projectPath) }
        CanvasDocumentStore.onDocumentChanged = { store in
            guard ProjectLinksFrame.isAheadOfNotes(store.document),
                  let notes = CanvasProjectNoteCard.notes(forCanvasAt: store.url) else { return }
            sync(notesPath: notes.path, projectPath: projectPath(forNotes: notes))
        }
    }

    /// Sync one project, after its notes were read.
    static func sync(notesPath: String, projectPath: String) {
        guard !running.contains(notesPath) else {
            rerun.insert(notesPath)
            return
        }
        running.insert(notesPath)
        DispatchQueue.global(qos: .utility).async {
            let found = Result { () -> (String, NotesIO, [LinkEntry], String?) in
                guard let config = try loadConfig() else { throw PmError.configNotFound }
                let io = makeNotesIO(notesPath: notesPath, config: config)
                let raw = try io.readContent(path: notesPath)
                let links = try parseNotes(markdown: raw).links
                var canvas = try resolveProjectCanvasPath(projectPath: projectPath)
                // A project with links and no board gets its board: the links have to live somewhere.
                if canvas == nil, ProjectLinksFrame.hasLinks(links) {
                    canvas = try createProjectCanvas(projectPath: projectPath, notesPath: notesPath)
                }
                return (raw, io, links, canvas)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard case .success(let (_, io, links, canvas)) = found, let canvas else {
                        if case .failure(let error) = found { Log.write("links sync: \(notesPath): \(error)") }
                        finished(notesPath, projectPath: projectPath)
                        return
                    }
                    let url = URL(fileURLWithPath: canvas)
                    // A closed board that is only in the cloud is left until it is on this Mac — opening
                    // it downloads it, and the next read of the notes syncs it. A sync runs for every
                    // project whose notes are read, so reading each canvas would pull every board down.
                    guard CanvasStoreRegistry.isOpen(url) || !CloudFile.isCloudOnly(url) else {
                        Log.write("links sync: \(canvas) is only in the cloud, left until it's downloaded")
                        finished(notesPath, projectPath: projectPath)
                        return
                    }
                    edit(canvasAt: url, named: nil, { ProjectLinksFrame.sync(notes: links, canvas: &$0) }) { synced in
                        defer { finished(notesPath, projectPath: projectPath) }
                        guard let synced, synced.notesChanged else { return }
                        writeNotes(synced.links, to: notesPath, io: io)
                    }
                }
            }
        }
    }

    // MARK: Pieces

    /// Projects mid-sync, and the ones asked for again while they were — so a burst of reads is one
    /// sync and then one more, rather than several racing each other to write the same two files.
    private static var running: Set<String> = []
    private static var rerun: Set<String> = []

    private static func finished(_ notesPath: String, projectPath: String) {
        running.remove(notesPath)
        if rerun.remove(notesPath) != nil { sync(notesPath: notesPath, projectPath: projectPath) }
    }


    /// Change a canvas from outside any board: through its store if a board has it open, so the change
    /// is the board's — shown at once, saved by it, and undoable under `named` when there is a name —
    /// and in the file otherwise.
    ///
    /// **A closed canvas is read and written off the main thread.** A read can take as long as the disk
    /// does to answer, and a synced folder whose provider has stalled never answers: read here, that was
    /// the app frozen at launch. `then` gets what `mutate` returned — nil if the file couldn't be read —
    /// back on the main thread.
    static func edit<Output>(canvasAt url: URL, named: String?,
                             _ mutate: @escaping (inout CanvasDocument) -> Output,
                             then: @escaping @MainActor (Output?) -> Void = { _ in }) {
        if CanvasStoreRegistry.isOpen(url), let store = try? CanvasStoreRegistry.store(for: url) {
            defer { CanvasStoreRegistry.release(store) }
            var result: Output?
            let change: (inout CanvasDocument) -> Void = { result = mutate(&$0) }
            if let named { store.change(named, change) } else { store.changeQuietly(change) }
            then(result)
            return
        }
        // The file's own queue (`CanvasFileQueue`): one edit at a time, and a board opening meanwhile
        // reads after this has written.
        CanvasFileQueue.queue(for: url).async {
            var result: Output?
            do {
                var document = try CanvasDocument.read(contentsOf: url)
                let before = document
                result = mutate(&document)
                if document != before { try document.write(to: url) }
            } catch {
                Log.write("canvas edit: \(url.path): \(error)")
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { then(result) } }
        }
    }

    /// Write the list into the notes — read again first, so only `## Links` is ours and anything
    /// written to the rest of the file since is kept.
    private static func writeNotes(_ links: [LinkEntry], to notesPath: String, io: NotesIO) {
        DispatchQueue.global(qos: .utility).async {
            do {
                let raw = try io.readContent(path: notesPath)
                guard let out = try ProjectLinksFrame.notes(raw, with: links, notesPath: notesPath) else { return }
                try io.writeContent(path: notesPath, content: out)
                Log.write("links sync: wrote \(links.count) link(s) to \(notesPath)")
            } catch {
                Log.write("links sync: \(notesPath): \(error)")
            }
        }
    }

    /// The project folder a notes file belongs to: its folder, or the one above a `docs/` folder.
    private static func projectPath(forNotes notes: URL) -> String {
        let folder = notes.deletingLastPathComponent()
        return (folder.lastPathComponent == "docs" ? folder.deletingLastPathComponent() : folder).path
    }
}
