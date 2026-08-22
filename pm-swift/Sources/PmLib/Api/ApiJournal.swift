import Foundation

// MARK: - The mutation journal
//
// Every write the contract makes, appended to `~/.config/pm/journal.ndjson` with the content it
// replaced. Two things need it.
//
// The first is review. A model, the CLI and Raycast all write to files a person also edits by hand,
// and until now the only record of what they did was the sentence each returned at the time. An
// entry says when, which adapter, which action, and what changed.
//
// The second is undo across surfaces. The panel's undo stack is in memory and app-only: nothing can
// reverse a write made by Raycast, by `pm`, or by a model — including the app, after a relaunch. The
// journal makes any write reversible by anything, and safely, because an entry records the revision
// it produced. Reversing checks that the file is still exactly as that write left it and refuses if
// it isn't, so an undo can never quietly discard an edit made since.

/// One write, as the journal records it.
public struct JournalEntry: Codable, Equatable {
    /// Sortable and unique enough to name in an undo: the timestamp plus the revision it produced.
    public var id: String
    public var at: String
    /// Which adapter made the write — "cli", "mcp", "app", "raycast".
    public var source: String
    public var action: String
    public var project: String?
    public var notesPath: String?
    public var summary: String
    /// Content hash before and after. The pair is what makes reversing safe rather than hopeful.
    public var revisionBefore: String?
    public var revisionAfter: String?
    public var changed: [ApiChange]
    /// False for writes with no document behind them — creating a project, setting a config key.
    public var undoable: Bool
    /// The id of the entry this one reversed, when it is a reversal.
    ///
    /// A reversal is a write like any other and is recorded like one, which is what makes it
    /// reversible in turn. But it must not be what the *next* undo picks, or undo would oscillate
    /// between two states instead of walking back through the history.
    public var reverses: String?

    public init(id: String, at: String, source: String, action: String, project: String?,
                notesPath: String?, summary: String, revisionBefore: String?, revisionAfter: String?,
                changed: [ApiChange], undoable: Bool, reverses: String? = nil) {
        self.id = id
        self.at = at
        self.source = source
        self.action = action
        self.project = project
        self.notesPath = notesPath
        self.summary = summary
        self.revisionBefore = revisionBefore
        self.revisionAfter = revisionAfter
        self.changed = changed
        self.undoable = undoable
        self.reverses = reverses
    }
}

public enum ApiJournal {
    /// Entries kept, and the point at which a write prunes back to it. Pruning on a threshold rather
    /// than every write keeps the common case a single append.
    static let keepEntries = 200
    static let pruneAbove = 300

    static var journalPath: String {
        (getConfigDir() as NSString).appendingPathComponent("journal.ndjson")
    }

    static var snapshotDirectory: String {
        (getConfigDir() as NSString).appendingPathComponent("journal")
    }

    /// Snapshots are named by the hash of what's in them, so the same content is stored once however
    /// many entries point at it — and an entry's `revisionBefore` is already the name of its file.
    static func snapshotPath(_ revision: String) -> String {
        (snapshotDirectory as NSString).appendingPathComponent("\(revision).md")
    }

    static func snapshot(_ revision: String?) -> String? {
        guard let revision else { return nil }
        return try? String(contentsOfFile: snapshotPath(revision), encoding: .utf8)
    }

    private static func store(_ content: String) -> String {
        let revision = revision(of: content)
        let path = snapshotPath(revision)
        if !FileManager.default.fileExists(atPath: path) {
            try? FileManager.default.createDirectory(atPath: snapshotDirectory,
                                                     withIntermediateDirectories: true)
            try? content.write(toFile: path, atomically: true, encoding: .utf8)
        }
        return revision
    }

    private static var timestamp: String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date())
    }

    /// Record a document write, keeping the content it replaced.
    ///
    /// Failing to journal must never fail the write: the file on disk is the truth, and a full disk
    /// or a read-only config directory is a reason to lose the record, not the work.
    @discardableResult
    static func record(action: String, project: String?, notesPath: String?, summary: String,
                       before: String, after: String, changed: [ApiChange], source: String,
                       reverses: String? = nil) -> JournalEntry? {
        let entry = JournalEntry(
            id: "", at: timestamp, source: source, action: action, project: project,
            notesPath: notesPath, summary: summary,
            revisionBefore: store(before), revisionAfter: store(after),
            changed: changed, undoable: true, reverses: reverses)
        return append(entry)
    }

    /// Record a write with no document behind it — a project created, a config key set. Reviewable,
    /// not reversible, and the entry says so rather than leaving a caller to find out.
    @discardableResult
    static func recordMetadata(action: String, project: String?, summary: String,
                               source: String) -> JournalEntry? {
        append(JournalEntry(id: "", at: timestamp, source: source, action: action, project: project,
                            notesPath: nil, summary: summary, revisionBefore: nil, revisionAfter: nil,
                            changed: [], undoable: false))
    }

    private static func append(_ entry: JournalEntry) -> JournalEntry? {
        var stamped = entry
        stamped.id = "\(entry.at)/\(entry.revisionAfter ?? revision(of: entry.at + entry.action))"
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(stamped),
              var line = String(data: data, encoding: .utf8) else { return nil }
        line += "\n"

        let path = journalPath
        let fm = FileManager.default
        if !fm.fileExists(atPath: path) {
            try? fm.createDirectory(atPath: getConfigDir(), withIntermediateDirectories: true)
            fm.createFile(atPath: path, contents: nil)
        }
        // One append of one line. Not a lock — two processes writing at the same instant could still
        // interleave — but a single short write to a file opened for appending is atomic enough that
        // a line has never been seen split in practice.
        guard let handle = FileHandle(forWritingAtPath: path) else { return nil }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(line.utf8))
        prune()
        return stamped
    }

    /// Entries, newest first.
    public static func entries(limit: Int = 50, project: String? = nil) -> [JournalEntry] {
        read()
            .filter { project == nil || $0.project == project }
            .suffix(limit == 0 ? Int.max : limit)
            .reversed()
    }

    static func entry(id: String) -> JournalEntry? {
        read().last { $0.id == id }
    }

    /// The entry a plain "undo" should reverse: the newest write that is still standing.
    ///
    /// Reversals are skipped, and so is anything already reversed. Undoing twice then walks back
    /// through the history — which works because reversing a write leaves the file at exactly the
    /// revision the write before it produced, so the next entry back is once again reversible.
    static func nextToReverse(project: String?) -> JournalEntry? {
        let all = read().filter { project == nil || $0.project == project }
        let alreadyReversed = Set(all.compactMap(\.reverses))
        return all.last { $0.undoable && $0.reverses == nil && !alreadyReversed.contains($0.id) }
    }

    private static func read() -> [JournalEntry] {
        guard let text = try? String(contentsOfFile: journalPath, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        return text.split(separator: "\n").compactMap {
            try? decoder.decode(JournalEntry.self, from: Data($0.utf8))
        }
    }

    /// Trim the journal and drop snapshots nothing points at any more.
    private static func prune() {
        let all = read()
        guard all.count > pruneAbove else { return }
        let kept = Array(all.suffix(keepEntries))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let lines = kept.compactMap { entry -> String? in
            guard let data = try? encoder.encode(entry) else { return nil }
            return String(data: data, encoding: .utf8)
        }
        try? (lines.joined(separator: "\n") + "\n").write(toFile: journalPath, atomically: true,
                                                          encoding: .utf8)
        let referenced = Set(kept.flatMap { [$0.revisionBefore, $0.revisionAfter].compactMap { $0 } })
        let fm = FileManager.default
        for file in (try? fm.contentsOfDirectory(atPath: snapshotDirectory)) ?? [] {
            let revision = (file as NSString).deletingPathExtension
            if !referenced.contains(revision) {
                try? fm.removeItem(atPath: snapshotPath(revision))
            }
        }
    }
}
