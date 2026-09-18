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

/// The time a sitting's heading carries: the clock time it began, as `9:10 AM`.
///
/// Every sitting PM starts carries one (docs/views.md D4). It began as the way to tell two sittings of
/// one day apart, and only the second and later got it; a day read across projects needs to be put in
/// order, and a heading with no time can't be. The time is local, because it names the moment you sat
/// down rather than a coordinate anything matches on (the *date* is pinned to UTC by
/// `formatSessionDate` precisely because that one is matched on).
public func sessionTimeLabel(_ date: Date = Date()) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "h:mm a"
    return formatter.string(from: date)
}

/// What follows the date in a sitting's heading, taken apart: the time it began, and the name someone
/// gave it.
///
/// ```
/// ### Thu, Sep 18, 2026 9:10 AM
/// ### Thu, Sep 18, 2026 9:10 AM · Week in review
/// ### Thu, Sep 18, 2026 Week in review        (named before sittings kept their time)
/// ### Thu, Sep 18, 2026                        (started before sittings kept their time)
/// ```
///
/// **One field on disk, two in meaning.** The heading pattern captures everything after the date as
/// the label, and `Session.label` stays exactly that, so a `SessionRef`'s digest and every heading
/// already written are untouched. Before this, the time *was* the label, and naming a sitting threw it
/// away. Keeping them apart is what lets a rename keep the time.
///
/// A time is `h:mm` and AM or PM, what `sessionTimeLabel` writes; anything else is a name, so "10:30
/// sync" is a sitting named that, not one that began at half past ten.
public struct SessionLabel: Equatable, Sendable {
    public var time: String?
    public var name: String

    public init(time: String?, name: String) {
        self.time = time
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public init(parsing label: String) {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        guard let m = Self.pattern.firstMatch(in: trimmed, range: range),
              let t = Range(m.range(at: 1), in: trimmed) else {
            self.init(time: nil, name: trimmed)
            return
        }
        let name = Range(m.range(at: 2), in: trimmed).map { String(trimmed[$0]) } ?? ""
        self.init(time: String(trimmed[t]).uppercased(), name: name)
    }

    /// As the heading writes it.
    public var text: String {
        switch (time, name.isEmpty) {
        case (nil, _): return name
        case (let time?, true): return time
        case (let time?, false): return "\(time) · \(name)"
        }
    }

    /// A leading time, then optionally a name after ` · ` (or, hand-written, after plain spaces).
    private static let pattern = try! NSRegularExpression(
        pattern: #"^(\d{1,2}:\d{2}\s?[AaPp][Mm])(?:(?:\s*·\s*|\s+)(.*))?$"#)
}

extension Session {
    /// The time this sitting began, as its heading says — nil for one started before sittings kept it.
    public var startTime: String? { SessionLabel(parsing: label).time }
    /// The name someone gave this sitting, or empty.
    public var name: String { SessionLabel(parsing: label).name }
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
/// - **no session for today** — one is started, headed with the time it began (`SessionLabel`).
/// - **today's session is still warm, or has nothing in it yet** — that one. An *empty* session is
///   reused however old it is: a heading with no note and no tasks is a sitting that hasn't started,
///   so writing into it is starting it, and stacking a second empty heading on the first would be the
///   rule arguing with the sweep that exists to remove them (`pruneEmptySessions`).
/// - **today's session has been left alone past the window** — a new one, headed with its time too.
///
/// An empty heading that is joined keeps the time it was made with. That's when someone asked for a
/// sitting, and re-stamping it would break a `SessionRef` an open editor already holds for it.
///
/// Returns nil when there's no `## Sessions` heading to splice into, which is the same "caller should
/// fall back" nil `sessionAddPreservingFormat` returns.
///
/// `label`, when given, is the name of a session this call starts, written after its time — it's what
/// `session.start` passes when the caller named the sitting.
///
/// `forcingNew` skips the window: a warm session is left alone and a new one is started beside it.
/// Still not over an *empty* one, which is already new — only `session.start` asks for it, when
/// someone said "new session" on purpose (⌥ New Session; docs/tile-sessions.md D1).
public func currentSessionPreservingFormat(rawText: String, lastEdited: Date?, now: Date = Date(),
                                           label: String? = nil,
                                           forcingNew: Bool = false) throws -> CurrentSession? {
    let today = formatSessionDate(now)
    let notes = try parseNotes(markdown: rawText)
    let existing = notes.sessions.firstIndex { $0.date == today }

    if let existing {
        let isEmpty = notes.sessions[existing].body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if isEmpty || (!forcingNew && !sessionHasGoneCold(lastEdited: lastEdited, now: now)) {
            return CurrentSession(rawText: rawText, sessionIndex: existing, started: false)
        }
    }

    let newLabel = SessionLabel(time: sessionTimeLabel(now), name: label ?? "").text
    guard let withSession = sessionAddPreservingFormat(rawText: rawText, label: newLabel, date: now),
          let index = try parseNotes(markdown: withSession).sessions.firstIndex(where: { $0.date == today })
    else { return nil }
    return CurrentSession(rawText: withSession, sessionIndex: index, started: true)
}
