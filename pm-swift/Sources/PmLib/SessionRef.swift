import Foundation

// MARK: - Session references
//
// The companion to `TaskRef`, for the same hazard read from the other end.
//
// `TaskRef` exists because a task's `sessionIndex:lineIndex` moves when a session is spliced in above
// it. The sessions themselves move for exactly the same reason and were addressed by a bare `Int`
// anyway — so every operation that named one (rename it, delete it, write its note, add a task to it)
// was trusting a number that the next write could quietly redefine. That is not theoretical: a note
// written from the quick bar starts a session, every index below shifts by one, and an editor opened a
// moment earlier is now pointed at a different sitting. It destroyed a note that way.
//
// A `SessionRef` carries the same two defences `TaskRef` does. It names its session by **date** rather
// than index, so the splice doesn't move it at all; and it carries a **digest** of the session's label,
// so a position that has come to mean something else is caught instead of written to.

/// Short content hash of a session's label — the session equivalent of `taskDigest`.
///
/// The label is what distinguishes one sitting from another on the same day (`"2:14 PM"`, `"Kickoff"`),
/// so it is the thing worth asserting. An unlabelled session digests to a constant, which discriminates
/// nothing and is meant to: with one session that day the date has already identified it, and with
/// several unlabelled ones there is genuinely nothing to tell them apart by, so a reference that has
/// lost its position is refused rather than guessed at.
public func sessionDigest(_ label: String) -> String { contentDigest(label) }

/// How a caller names a session it read earlier.
///
/// `date` takes precedence over `index`; `index` is the positional form for callers with no date to
/// hand — the CLI's positional arguments, and anything in-process that re-reads after every write.
/// `digest` is optional in the same spirit as `TaskRef`'s: omitting it says "I am not asserting
/// anything about this session", which is what a person typing `pm notes session rename W-1 0` is
/// doing. Anything that reads early and acts late should always send one.
public struct SessionRef: Equatable {
    /// ISO `YYYY-MM-DD`. Takes precedence over `index` when both are set.
    public var date: String?
    /// Which session of that date, when a project has more than one. Almost always 0.
    public var ordinal: Int
    /// Positional form, used when `date` is nil.
    public var index: Int?
    /// `sessionDigest` of the label the caller believes this session has.
    public var digest: String?

    public init(date: String? = nil, ordinal: Int = 0, index: Int? = nil, digest: String? = nil) {
        self.date = date
        self.ordinal = ordinal
        self.index = index
        self.digest = digest
    }

    /// The positional form every existing caller uses.
    public init(index: Int, digest: String? = nil) {
        self.init(date: nil, ordinal: 0, index: index, digest: digest)
    }

    /// The strongest reference that can be made to a session already read: its date, its ordinal among
    /// that date's sittings, and a digest of its label. This is what a UI should capture the moment it
    /// opens an editor on a session, and hand back when it commits.
    ///
    /// Falls back to the positional form for a heading this parser didn't write — a hand-edited date
    /// still names a session, it just can't be named back by date.
    public init(session: Session, at index: Int, in notes: ProjectNotes) {
        let digest = sessionDigest(session.label)
        guard let iso = sessionISODate(heading: session.date) else {
            self.init(index: index, digest: digest)
            return
        }
        let ordinal = notes.sessions[..<min(index, notes.sessions.count)]
            .filter { $0.date == session.date }.count
        self.init(date: iso, ordinal: ordinal, index: index, digest: digest)
    }
}

/// Where a reference landed, and whether it had to move to get there.
public struct ResolvedSessionRef: Equatable {
    public let index: Int
    /// True when the session was found somewhere other than the position the caller named — the
    /// sitting is the one they meant, but the document shifted under them.
    public let relocated: Bool

    public init(index: Int, relocated: Bool = false) {
        self.index = index
        self.relocated = relocated
    }
}

/// Turn a reference into the session index to act on, or refuse.
///
/// The same three outcomes `resolveTaskRef` has, for the same reasons:
///
/// - **hit** — the session at the named position carries the digest (or no digest was asserted).
/// - **relocated** — it doesn't, but exactly one session of the same date carries it. The sitting is
///   the one the caller meant and the document moved under them, so we act on it and say so.
/// - **stale** — anything else. Two matches is as refusable as none: once the position check has
///   failed, healing would be a guess, and a guess here writes a note into the wrong day.
public func resolveSessionRef(_ ref: SessionRef, notes: ProjectNotes) throws -> ResolvedSessionRef {
    let sessions = notes.sessions

    // Where the caller says it is.
    let named: Int
    let sameDate: [Int]
    if let iso = ref.date {
        let heading = try sessionHeadingDate(iso: iso)
        sameDate = sessions.indices.filter { sessions[$0].date == heading }
        guard ref.ordinal >= 0, ref.ordinal < sameDate.count else {
            throw PmError.staleReference(
                detail: sameDate.isEmpty
                    ? "this project has no session dated \(iso)"
                    : "this project has \(sameDate.count) session(s) dated \(iso), not \(ref.ordinal + 1)")
        }
        named = sameDate[ref.ordinal]
    } else {
        guard let index = ref.index else {
            throw PmError.staleReference(detail: "reference names neither a session date nor an index")
        }
        guard index >= 0, index < sessions.count else {
            throw PmError.staleReference(detail: "this project has no session \(index)")
        }
        named = index
        sameDate = sessions.indices.filter { sessions[$0].date == sessions[index].date }
    }

    guard let digest = ref.digest else { return ResolvedSessionRef(index: named) }
    if sessionDigest(sessions[named].label) == digest { return ResolvedSessionRef(index: named) }

    // Searched among that day's sittings rather than the whole document: a label is only meaningful
    // beside its date, and "Kickoff" recurring in a later month is a different sitting, not this one.
    let elsewhere = sameDate.filter { sessionDigest(sessions[$0].label) == digest }
    guard elsewhere.count == 1, let moved = elsewhere.first else {
        let found = sessions[named].label.isEmpty ? "an unlabelled session" : "“\(sessions[named].label)”"
        throw PmError.staleReference(
            detail: elsewhere.isEmpty
                ? "the session you read is no longer in this project (that position now holds \(found))"
                : "\(elsewhere.count) sessions that day share that label, so which one you meant can't be recovered")
    }
    return ResolvedSessionRef(index: moved, relocated: true)
}
