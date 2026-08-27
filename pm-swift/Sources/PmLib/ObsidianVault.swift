import Foundation

// Finding the file an embed names.
//
// A note written by PM says `attachments/shot.png` and means the folder beside itself. A note written
// by Obsidian says `![[shot.png]]` and means "the file called that, wherever in this vault it lives" —
// Obsidian keeps an index of the whole vault and resolves it by name. The two conventions meet in one
// file, because the same note is edited by both, so reading one has to cope with the other.
//
// Rebuilding Obsidian's index isn't the answer — it would mean walking the vault on every redraw. What
// this does instead is ask the vault where it puts attachments (it says so, in `.obsidian/app.json`)
// and look in the handful of places that answer implies, nearest the note first.

/// The vault a note lives in: the nearest folder above it holding an `.obsidian` directory.
///
/// That directory *is* the definition of a vault — it's what Obsidian creates when you open a folder
/// as one — so this asks the question exactly rather than guessing from the shape of the path. Nil for
/// a note outside any vault, which is a perfectly ordinary way to use PM and simply means embeds
/// resolve relative to the note and nowhere else.
public func obsidianVaultRoot(for note: URL, maxDepth: Int = 12) -> URL? {
    var folder = note.deletingLastPathComponent().standardizedFileURL
    for _ in 0..<maxDepth {
        if FileManager.default.fileExists(atPath: folder.appendingPathComponent(".obsidian").path) {
            return folder
        }
        let parent = folder.deletingLastPathComponent().standardizedFileURL
        if parent.path == folder.path { break }   // reached the filesystem root
        folder = parent
    }
    return nil
}

/// Where a vault has been told to put new attachments, as written in `.obsidian/app.json`.
///
/// Obsidian's own values, which is why this is a raw string rather than an enum of guesses: `""` or
/// missing means the vault root, `"./"` means beside the note, `"./sub"` means a subfolder beside the
/// note, and anything else is a folder path from the vault root. Read straight from the vault so a
/// user who keeps attachments in `z_assets` is served as well as one who uses the default.
///
/// Answered from a cache, because the caller is a view: an embed is resolved while a session row lays
/// itself out, and reading and parsing a JSON file every time one redraws is not something a redraw
/// should do. Keyed by the settings file's modification date, so changing the setting in Obsidian is
/// picked up on the next redraw rather than needing PM restarted.
public func obsidianAttachmentFolder(vaultRoot: URL) -> String? {
    let settings = vaultRoot.appendingPathComponent(".obsidian/app.json")
    let stamp = (try? FileManager.default.attributesOfItem(atPath: settings.path))
        .flatMap { ($0[.modificationDate] as? Date)?.timeIntervalSince1970 } ?? 0
    if let hit = attachmentFolderCache.value(for: settings.path, stamp: stamp) { return hit.folder }


    var folder: String?
    if let data = try? Data(contentsOf: settings),
       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let path = json["attachmentFolderPath"] as? String {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        folder = trimmed.isEmpty ? nil : trimmed
    }
    attachmentFolderCache.store(folder, for: settings.path, stamp: stamp)
    return folder
}

/// The parsed `attachmentFolderPath` per vault, valid for as long as the file it came from is
/// untouched. Small and long-lived: one entry per vault a session ever reads from.
private final class AttachmentFolderCache {
    private let lock = NSLock()
    private var entries: [String: (stamp: TimeInterval, folder: String?)] = [:]

    /// One cached answer. A type rather than a bare `String?` so that "cached, and this vault names no
    /// folder" stays distinguishable from "not cached" — the two mean opposite things to the caller.
    struct Answer { let folder: String? }

    func value(for path: String, stamp: TimeInterval) -> Answer? {
        lock.lock(); defer { lock.unlock() }
        guard let hit = entries[path], hit.stamp == stamp else { return nil }
        return Answer(folder: hit.folder)
    }

    func store(_ folder: String?, for path: String, stamp: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        entries[path] = (stamp, folder)
    }
}

private let attachmentFolderCache = AttachmentFolderCache()

/// The folders an embed's target might be in, nearest the note first.
///
/// Order is the whole design. The note's own folder comes first because that's where PM puts what it
/// writes and where a link relative to the note points; the vault's configured attachment folder next,
/// because that's where Obsidian puts what *it* writes; then the vault root and the conventional
/// `attachments/` on either side of it, which is where a vault that never configured anything ends up.
/// First hit wins, so a picture beside the note is never shadowed by a same-named one at the root.
func embedSearchFolders(noteAt note: URL) -> [URL] {
    let noteFolder = note.deletingLastPathComponent().standardizedFileURL
    var folders: [URL] = [noteFolder, noteFolder.appendingPathComponent(markdownAttachmentsFolder)]
    guard let vault = obsidianVaultRoot(for: note) else { return folders }

    if let configured = obsidianAttachmentFolder(vaultRoot: vault) {
        // "./" and "./sub" are relative to the note; anything else is relative to the vault root.
        if configured == "./" {
            folders.append(noteFolder)
        } else if configured.hasPrefix("./") {
            folders.append(noteFolder.appendingPathComponent(String(configured.dropFirst(2))))
        } else {
            folders.append(vault.appendingPathComponent(configured))
        }
    }
    folders.append(vault)
    folders.append(vault.appendingPathComponent(markdownAttachmentsFolder))
    return folders
}

/// Resolve what an embed or a link points at to a file on disk, or nil when nothing is there.
///
/// Handles both ways a note names a file. A path — `attachments/shot.png`, `../docs/spec.pdf` — is
/// tried against each search folder in turn, which is what makes a vault-root-relative path written by
/// Obsidian resolve from a note several folders down. A bare name — `shot.png`, all a wikilink embed
/// ever carries — is looked for in those same folders by name.
///
/// Nil is a real answer and callers depend on it: a destination that points at nothing isn't a link,
/// so the read view leaves it as text and the editor lets a ⌘-click place the caret instead.
public func resolveNoteReference(_ destination: String, noteAt note: URL?) -> URL? {
    let raw = destination.trimmingCharacters(in: .whitespaces)
    guard !raw.isEmpty else { return nil }
    let path = NSString(string: raw.removingPercentEncoding ?? raw).expandingTildeInPath

    let fm = FileManager.default
    if path.hasPrefix("/") {
        return fm.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
    }
    guard let note else { return nil }
    for folder in embedSearchFolders(noteAt: note) {
        let candidate = URL(fileURLWithPath: path, relativeTo: folder).standardizedFileURL
        if fm.fileExists(atPath: candidate.path) { return candidate }
    }
    return nil
}
