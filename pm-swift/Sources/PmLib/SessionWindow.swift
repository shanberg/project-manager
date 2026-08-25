import Foundation

// MARK: - When a write starts a new session
//
// A session used to be a day. Everything written into a project — a quick-captured task, a note, the
// panel's New Session — looked for a heading dated today, made one if there wasn't one, and joined
// it. That is right for a project you touch once a day and wrong for one you sit down to twice: a
// morning's work and an evening's work landed in the same block, with nothing between them to say
// they were two different sittings.
//
// So a session is now a *sitting*: the last one, unless the project has been left alone long enough
// that coming back to it is starting again. "Long enough" is `sessionIdleWindow` — hardcoded for now,
// and the obvious thing to lift into Settings when it earns a control.
//
// The measure is the notes file's modification date, which is the one answer every surface agrees on.
// The app, the CLI, Raycast, a model over MCP and a person typing in Obsidian all write that file and
// nothing else records all five. It also means the window is honest about hand edits: a paragraph
// typed into the notes in Obsidian is an edit to the project, and the next captured task joins the
// session it belongs to rather than opening a new one on top of it.

/// How long a project can sit untouched before the next thing written into it opens a new session
/// rather than joining the last one.
///
/// Ninety minutes: long enough to cover a meeting, a lunch, or a detour into another project and come
/// back to the same block of work; short enough that a morning and an afternoon are two sittings.
public let sessionIdleWindow: TimeInterval = 90 * 60

/// Whether a write landing at `now` is coming back to a project rather than continuing with it.
///
/// An unknown `lastEdited` is read as "no", not as "yes". Not being able to tell when the file was
/// last touched is a reason to leave the document's shape alone, and the cost of the two answers
/// isn't symmetric: joining the last session when a new one was due is a heading nobody got, while
/// splitting when nothing was due is a heading nobody wanted, in a file people read.
public func sessionHasGoneCold(lastEdited: Date?, now: Date = Date()) -> Bool {
    guard let lastEdited else { return false }
    return now.timeIntervalSince(lastEdited) > sessionIdleWindow
}

/// When a project's notes file was last written — the project's last edit, as the idle window
/// measures it. Nil when the file can't be stat'd, which `sessionHasGoneCold` reads as "don't split".
public func notesLastEdited(path: String) -> Date? {
    (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
}

/// The label an additional session started on a day that already has one carries: the clock time it
/// began.
///
/// A heading is identified by its date, so two on the same day are identical without this — two
/// "Tue, Aug 26, 2026" rules across the list with no way to tell which sitting is which. The time is
/// local, because it names the moment you sat down rather than a coordinate anything matches on (the
/// *date* is pinned to UTC by `formatSessionDate` precisely because that one is matched on).
///
/// Only the second and later sessions of a day get one. The first carries no label, exactly as before,
/// so a project worked on once a day never grows a decoration it has no use for.
public func sessionTimeLabel(_ date: Date = Date()) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "h:mm a"
    return formatter.string(from: date)
}

/// What `currentSessionPreservingFormat` found or made.
public struct CurrentSession: Equatable {
    /// The document, with a new session spliced in when one was needed.
    public var rawText: String
    /// The session to write into, indexed as `parseNotes` numbers them.
    public var sessionIndex: Int
    /// Whether this call is what created it, so a caller can say which of the two things it did.
    public var started: Bool

    public init(rawText: String, sessionIndex: Int, started: Bool) {
        self.rawText = rawText
        self.sessionIndex = sessionIndex
        self.started = started
    }
}

/// The session a write landing at `now` belongs in, adding one to the document first when it has to.
///
/// Three outcomes, in the order they're checked:
///
/// - **no session for today** — one is started, unlabelled. The first write of the day, unchanged
///   from what every surface did before the idle window existed.
/// - **today's session is still warm, or has nothing in it yet** — that one. An *empty* session is
///   reused however old it is: a heading with no note and no tasks is a sitting that hasn't started,
///   so writing into it is starting it, and stacking a second empty heading on the first would be the
///   rule arguing with the sweep that exists to remove them (`pruneEmptySessions`).
/// - **today's session has been left alone past the window** — a new one, labelled with the time so
///   the two dated headings can be told apart.
///
/// Returns nil when there's no `## Sessions` heading to splice into, which is the same "caller should
/// fall back" nil `sessionAddPreservingFormat` returns.
///
/// `label`, when given, is used verbatim for a session this call starts and overrides the automatic
/// time label — it's what `session.start` passes when the caller named the sitting.
public func currentSessionPreservingFormat(rawText: String, lastEdited: Date?, now: Date = Date(),
                                           label: String? = nil) throws -> CurrentSession? {
    let today = formatSessionDate(now)
    let notes = try parseNotes(markdown: rawText)
    let existing = notes.sessions.firstIndex { $0.date == today }

    if let existing {
        let isEmpty = notes.sessions[existing].body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if isEmpty || !sessionHasGoneCold(lastEdited: lastEdited, now: now) {
            return CurrentSession(rawText: rawText, sessionIndex: existing, started: false)
        }
    }

    // A second sitting on the same day needs telling apart from the first; the day's first doesn't.
    let newLabel = label ?? (existing == nil ? "" : sessionTimeLabel(now))
    guard let withSession = sessionAddPreservingFormat(rawText: rawText, label: newLabel, date: now),
          let index = try parseNotes(markdown: withSession).sessions.firstIndex(where: { $0.date == today })
    else { return nil }
    return CurrentSession(rawText: withSession, sessionIndex: index, started: true)
}
