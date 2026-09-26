import Foundation

/// A new card is a markdown document in the board's `docs` folder, not text stored in the canvas.
///
/// **Why a file.** Text in a `.canvas` is readable only through the canvas: search, Obsidian's graph,
/// backlinks, a `[[link]]` from a note, `pm` on the command line — none of them can see it, and a card
/// that outgrows the board has nowhere to go. A card that is a file is a note that happens to be on a
/// board. Obsidian's own "Convert to file" is the same move, made at the start instead of too late.
///
/// **Named by what you wrote.** A card is made before anything is typed in it, so its file starts as
/// `Untitled.md` and is marked (`pmUntitled`) as a name nobody chose. Stepping out with words in it
/// renames the file after its first line, once; after that the name is the file's, and changing the
/// first line doesn't move it — a rename is what breaks the links other notes made to it.
///
/// **Empty is nothing.** A card opened empty and left empty was a double-click that landed somewhere
/// you didn't mean, and taking it away takes its file too — but only a file this made, only while
/// it's still empty.
public enum CanvasDocCards {
    /// Marks a card whose file still has the name it was given before it had words.
    public static let untitledKey = "pmUntitled"

    public static let placeholder = "Untitled"

    /// Where a board's new documents go: its own folder when that is a `docs` folder — which is where
    /// every project keeps its canvas (`getProjectCanvasPath`) — and a `docs` beside it otherwise.
    public static func folder(forCanvasAt canvas: URL) -> URL {
        let folder = canvas.deletingLastPathComponent()
        return folder.lastPathComponent == "docs" ? folder : folder.appendingPathComponent("docs")
    }

    /// Make an empty `Untitled.md` in `folder` — `Untitled 2.md` and so on when that is taken — and
    /// return where it went. Never overwrites.
    public static func makeUntitled(in folder: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = available(placeholder, in: folder)
        // `.withoutOverwriting`: a file appearing between the check and the write — another window
        // making a card at the same moment — is an error rather than a note emptied.
        try Data().write(to: url, options: .withoutOverwriting)
        return url
    }

    /// Write `text` as a new document in `folder`, named after its first line — `Untitled` when that
    /// gives no name — and return where it went. Never overwrites: a taken name gets a number.
    /// How a card that was text becomes a file, and how text arriving from outside the board — `pm card
    /// add`, a paste — becomes a card.
    public static func write(_ text: String, in folder: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = available(title(from: text) ?? placeholder, in: folder)
        try Data(text.utf8).write(to: url, options: .withoutOverwriting)
        return url
    }

    /// The first free `<name>.md`, `<name> 2.md`, … in `folder`.
    public static func available(_ name: String, in folder: URL, except current: URL? = nil) -> URL {
        var candidate = folder.appendingPathComponent(name + ".md")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path),
              candidate.standardizedFileURL != current?.standardizedFileURL {
            candidate = folder.appendingPathComponent("\(name) \(n).md")
            n += 1
        }
        return candidate
    }

    /// What a document is called, from what it says: its first line with words on it, without the
    /// markdown that dresses it and without the characters a filename or an Obsidian link can't hold.
    /// Nil when nothing usable is left.
    public static func title(from text: String) -> String? {
        guard let line = text.split(whereSeparator: \.isNewline)
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { !$0.isEmpty }) else { return nil }
        var title = line
        // A heading's hashes, a list item's or a quote's marker, a task's box.
        if let marker = title.range(of: #"^(#{1,6}\s+|[-*+]\s+(\[[ xX]\]\s+)?|>\s*|\d+[.)]\s+)"#,
                                    options: .regularExpression) {
            title.removeSubrange(marker)
        }
        // `[label](url)` reads as its label, `[[Target|alias]]` as whichever it shows.
        title = title.replacingOccurrences(of: #"\[\[([^\]|]*\|)?([^\]]*)\]\]"#, with: "$2",
                                           options: .regularExpression)
        title = title.replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1",
                                           options: .regularExpression)
        // Emphasis and code markers carry no words.
        title = title.replacingOccurrences(of: #"[*_`~=]+"#, with: "", options: .regularExpression)
        // Obsidian refuses `* " \ / < > : | ?` in a name and a link can't carry `# ^ [ ]`.
        title = title.replacingOccurrences(of: #"[*"\\/<>:|?#^\[\]]"#, with: " ", options: .regularExpression)
        title = title.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".")))
        guard !title.isEmpty else { return nil }
        // Long enough to say what it is, short enough to be a name. Cut at a word.
        if title.count > 60 {
            let cut = title.prefix(60)
            title = cut.lastIndex(of: " ").map { String(cut[..<$0]) } ?? String(cut)
        }
        return title
    }

    /// The documents a delete would leave behind with nothing showing them: the files in `docs` that the
    /// cards going are showing whole, and that no card staying on the board shows. What the delete
    /// question offers to put in the Trash.
    ///
    /// Only `docs`, only prose, never a project's notes: a card pointing at a note somewhere else in the
    /// vault is a pointer to something that belongs to where it is, and deleting the pointer is all the
    /// delete key has ever meant for it. Another *board* may still show one of these — nothing here can
    /// know that — which is why the answer is the Trash, and why Undo brings it back.
    public static func ownDocuments(deleting ids: Set<String>, from document: CanvasDocument, docs: URL,
                             locate: (String) -> URL?) -> [URL] {
        func shown(by node: CanvasNode) -> URL? {
            guard case .file(let path, nil) = node.content else { return nil }
            return locate(path)?.standardizedFileURL
        }
        // Paths, not URLs: a URL to a folder may or may not carry a trailing slash, and two that differ
        // only in that are unequal.
        let staying = Set(document.nodes.filter { !ids.contains($0.id) }.compactMap(shown).map(\.path))
        let folder = docs.standardizedFileURL.path
        var seen: Set<String> = []
        return document.nodes.filter { ids.contains($0.id) }.compactMap(shown).filter { url in
            ["md", "markdown", "txt"].contains(url.pathExtension.lowercased())
                && url.deletingLastPathComponent().path == folder
                && projectFolder(ofNotesPath: url.path) == nil
                && !staying.contains(url.path)
                && seen.insert(url.path).inserted
        }
    }
}
