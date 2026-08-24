import CryptoKit
import Foundation

// MARK: - Task references
//
// A task's position — `sessionIndex:lineIndex` — is how every mutation addresses it, and it is only
// trustworthy while the reader and the writer are the same process one runloop apart. That describes
// the panel, which reloads after each edit. It does not describe a Raycast list rendered minutes ago,
// or anything that reads, thinks, and acts later.
//
// Two things move a position out from under such a caller. Sessions are newest-first and a new one is
// spliced in at the top (`sessionAddPreservingFormat`), so *starting* a session — which quick add does
// by itself, first thing each day — shifts every task from (n, l) to (n+1, l). And inserting or
// deleting a task shifts everything below it within its session.
//
// A `TaskRef` is a position plus two defences. It names its session by **date** rather than index, so
// the common shift doesn't move it at all; and it carries a **digest** of the task's text, so a
// position that has come to mean something else is caught instead of acted on. See
// docs/task-identity.md.

/// Short content hash of a task's text: the first 8 hex characters of SHA-256, NFC-normalized.
///
/// The input is `Todo.text` — the line's content with the inline `due:` and the trailing ` @` focus
/// marker already stripped by `TaskContent.split`. Hashing the *raw line* instead would be useless,
/// because focus moves on nearly every completion and would invalidate every reference in the
/// document each time. Hashing the text means a reference survives completion, focus arriving or
/// leaving, a due date being set or cleared, and being wrapped or moved — none of which change what
/// the task is — and breaks on a rename, which does.
///
/// Eight hex characters is ample: the digest is checked against one known position rather than used
/// as a lookup key, so a collision has to land on that exact line to matter.
public func taskDigest(_ text: String) -> String {
    let normalized = text.trimmingCharacters(in: .whitespaces).precomposedStringWithCanonicalMapping
    return SHA256.hash(data: Data(normalized.utf8)).prefix(4)
        .map { String(format: "%02x", $0) }.joined()
}

/// How a caller names a task it read earlier.
///
/// A session is named by ISO date (`2026-08-22`) where possible, and by index only for callers that
/// have no date to hand — the CLI's positional arguments, and the panel, which is in-process and
/// re-reads after every write. `digest` is optional in the same spirit: omitting it means "I am not
/// asserting anything about this task", which is what a human typing `pm notes todo complete W-1 0 3`
/// is doing. Callers that read early and act late should always send one.
public struct TaskRef: Equatable {
    /// ISO `YYYY-MM-DD`. Takes precedence over `sessionIndex` when both are set.
    public var sessionDate: String?
    /// Which session of that date, when a project has more than one. Almost always 0.
    ///
    /// Duplicates are reachable: the panel checks for today's session before making one, but
    /// `pm notes session add` doesn't, so running it twice in a day leaves two identical headings —
    /// as does editing the file by hand.
    public var sessionOrdinal: Int
    /// Positional form, used when `sessionDate` is nil.
    public var sessionIndex: Int?
    /// The task's ordinal among the task lines of its session.
    public var lineIndex: Int
    /// `taskDigest` of the text the caller believes this task has.
    public var digest: String?

    public init(sessionDate: String? = nil, sessionOrdinal: Int = 0, sessionIndex: Int? = nil,
                lineIndex: Int, digest: String? = nil) {
        self.sessionDate = sessionDate
        self.sessionOrdinal = sessionOrdinal
        self.sessionIndex = sessionIndex
        self.lineIndex = lineIndex
        self.digest = digest
    }

    /// The positional form every existing caller uses.
    public init(sessionIndex: Int, lineIndex: Int, digest: String? = nil) {
        self.init(sessionDate: nil, sessionOrdinal: 0, sessionIndex: sessionIndex,
                  lineIndex: lineIndex, digest: digest)
    }
}

/// Where a reference landed, and whether it had to move to get there.
public struct ResolvedTaskRef: Equatable {
    public let sessionIndex: Int
    public let lineIndex: Int
    /// True when the digest was found somewhere other than the position the caller named — the task
    /// is the one they meant, but the document shifted under them.
    public let relocated: Bool

    public init(sessionIndex: Int, lineIndex: Int, relocated: Bool = false) {
        self.sessionIndex = sessionIndex
        self.lineIndex = lineIndex
        self.relocated = relocated
    }
}

// MARK: - Session dates

/// The heading form a session date is stored in, e.g. `"Fri, Aug 22, 2026"`, from an ISO date.
///
/// The stored form is a display format — `formatSessionDate` writes it with the locale pinned to
/// `en_US` and the timezone to UTC, so it is deterministic — but a reference shouldn't be passing a
/// display format around when `due:` is already ISO. This is the conversion at the edge.
public func sessionHeadingDate(iso: String) throws -> String {
    formatSessionDate(try parseSessionDateArgument(iso))
}

/// The ISO date of a session heading string, or nil if it isn't one this parser writes.
public func sessionISODate(heading: String) -> String? {
    let reader = DateFormatter()
    reader.locale = Locale(identifier: "en_US")
    reader.timeZone = TimeZone(identifier: "UTC")
    reader.dateFormat = "EEE, MMM d, yyyy"
    guard let date = reader.date(from: heading) else { return nil }
    let writer = DateFormatter()
    writer.locale = Locale(identifier: "en_US_POSIX")
    writer.timeZone = TimeZone(identifier: "UTC")
    writer.dateFormat = "yyyy-MM-dd"
    return writer.string(from: date)
}

// MARK: - Resolution

/// Turn a reference into the position to act on, or refuse.
///
/// Three outcomes, in order:
///
/// - **hit** — the task at the named position carries the digest (or no digest was asserted).
/// - **relocated** — it doesn't, but the digest appears exactly once elsewhere in the document. The
///   task is the one the caller meant and the document moved under them, so we act on it and say so.
///   Searching the whole document rather than the session is deliberate: the shift this exists to
///   absorb moves a task *between* session indices.
/// - **stale** — anything else. Two matches is as refusable as none: duplicate task text is ordinary
///   ("Follow up" twice in a project), and once the position check has failed, healing would be a
///   guess. Refusing returns the caller to a re-read, which is cheap; completing the wrong task isn't.
public func resolveTaskRef(_ ref: TaskRef, notes: ProjectNotes) throws -> ResolvedTaskRef {
    let sessionIndex = try sessionIndex(for: ref, notes: notes)
    let todos = try parseTodos(notes: notes)

    let atPosition = todos.first { $0.sessionIndex == sessionIndex && $0.lineIndex == ref.lineIndex }

    guard let digest = ref.digest else {
        // Nothing asserted, so nothing to check beyond the position existing at all. Catching this
        // here turns what the raw edits report as "notes file not found" into something true.
        guard atPosition != nil else {
            throw PmError.staleReference(
                detail: "no task at session \(sessionIndex), line \(ref.lineIndex)")
        }
        return ResolvedTaskRef(sessionIndex: sessionIndex, lineIndex: ref.lineIndex)
    }

    if let atPosition, taskDigest(atPosition.text) == digest {
        return ResolvedTaskRef(sessionIndex: sessionIndex, lineIndex: ref.lineIndex)
    }

    let elsewhere = todos.filter { taskDigest($0.text) == digest }
    guard elsewhere.count == 1, let moved = elsewhere.first else {
        let found = atPosition.map { "“\($0.text)”" } ?? "nothing"
        let detail = elsewhere.isEmpty
            ? "the task you read is no longer in this project (that position now holds \(found))"
            : "\(elsewhere.count) tasks share that text, so which one you meant can't be recovered"
        throw PmError.staleReference(detail: detail)
    }
    return ResolvedTaskRef(sessionIndex: moved.sessionIndex, lineIndex: moved.lineIndex, relocated: true)
}

/// Resolve a reference against markdown already in hand — the form every mutation uses, so the read
/// it resolves against is the same read it is about to mutate.
public func resolveTaskRef(_ ref: TaskRef, rawText: String) throws -> ResolvedTaskRef {
    try resolveTaskRef(ref, notes: normalizeFocusMarker(notes: try parseNotes(markdown: rawText)))
}

/// Which session a reference names: by date and ordinal when it has one, by index otherwise.
private func sessionIndex(for ref: TaskRef, notes: ProjectNotes) throws -> Int {
    guard let iso = ref.sessionDate else {
        guard let index = ref.sessionIndex else {
            throw PmError.staleReference(detail: "reference names neither a session date nor an index")
        }
        guard index >= 0, index < notes.sessions.count else {
            throw PmError.staleReference(detail: "this project has no session \(index)")
        }
        return index
    }
    let heading = try sessionHeadingDate(iso: iso)
    let matching = notes.sessions.enumerated().filter { $0.element.date == heading }.map(\.offset)
    guard ref.sessionOrdinal >= 0, ref.sessionOrdinal < matching.count else {
        throw PmError.staleReference(
            detail: matching.isEmpty
                ? "this project has no session dated \(iso)"
                : "this project has \(matching.count) session(s) dated \(iso), not \(ref.sessionOrdinal + 1)")
    }
    return matching[ref.sessionOrdinal]
}
