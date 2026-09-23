import Foundation

// MARK: - Where the attention went
//
// The three records PM already keeps with a clock in them — the journal, the done log, the pick log —
// each record a *moment*: this was finished at 14:26, this was picked up at 15:02. That is enough to
// put a day in order, which is what `SessionTimes` wanted of them. It is not enough to say how long
// anything took, because time spent is the question of what you were doing *between* two moments.
//
// This is the record of that. One project or area has your attention at a time — `focused.json`, a
// single global slot every surface reads — and this is that slot with a log behind it.
// See docs/time-tracking.md.
//
// ## Global, where the done and pick logs are per project
//
// A deliberate departure from done-report.md's reasoning, and a forced one: a span ends because your
// attention went *somewhere else*, and the only file that can know that is one both projects write to.
// A per-project log would record a hundred openings and never once say which of them was still going.
//
// The price, accepted: it doesn't travel with a project through archiving, and it isn't synced or
// backed up with the vault. Both are the right way round. A span is a fact about a Tuesday rather than
// about a project's history, and two Macs keeping one timeline between them would be two Macs each
// claiming the same hour.
//
// ## No duration is ever written
//
// A span is arithmetic between two edges, done on read, the way `SittingList` stores nothing new and
// joins the logs PM already keeps. What's on disk is only ever "attention arrived" and "attention
// left", each with the moment it happened.

/// One edge of a span, as the log records it.
public struct AttentionEvent: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// Attention arrived at a project. Implicitly ends whatever it was on before.
        case began
        /// Attention left it. Always back-dated to the last sign of life (D3), never stamped at the
        /// moment the pause was noticed.
        case ended
        /// An answer about `from`..`to`: it was this project's, or (no project) it wasn't work.
        /// Overrides whatever the edges say about that range. See docs/away-time.md.
        case counted
        /// Takes back the `counted` named by `ref` — what undo appends, since the log is never rewritten.
        case withdrawn
    }

    public var id: String
    /// When it happened, ISO 8601 in UTC. For `counted`, when the answer was given — which is what
    /// decides between two answers about the same range — not the range it's about.
    public var at: String
    public var event: Kind
    /// The project's folder name — what a report groups and prints by. Nil only on a `counted` that
    /// says "not work", and on a `withdrawn`.
    public var project: String?
    /// Its `<basePath>:<folder>` key, the spelling `focused.json` uses. Kept beside the folder name so
    /// two projects of the same name in different scopes are two projects here too.
    public var key: String?
    /// `began`: the focused task when it did, as colour. Never totalled — see D1.
    public var task: String?
    /// Why the edge happened. `began`: `switched` (the default, not written), `resumed` after a pause.
    /// `ended`: `switched`, `paused`, `slept`, `quit`.
    public var why: String?
    /// Which surface did it — "app", "cli", "raycast", a model.
    public var source: String?
    /// `counted`: the range the answer covers, ISO 8601 in UTC, end exclusive.
    public var from: String?
    public var to: String?
    /// `withdrawn`: the `id` of the `counted` it takes back.
    public var ref: String?
    /// `began` after a pause: what the machine showed while nobody was typing — `call` when the
    /// microphone was in use. A hint for the question about the away, never an answer to it.
    public var during: String?

    public init(id: String = AttentionLog.newID(), at: String, event: Kind, project: String?,
                key: String?, task: String? = nil, why: String? = nil, source: String? = nil,
                from: String? = nil, to: String? = nil, ref: String? = nil, during: String? = nil) {
        self.id = id
        self.at = at
        self.event = event
        self.project = project
        self.key = key
        self.task = task
        self.why = why
        self.source = source
        self.from = from
        self.to = to
        self.ref = ref
        self.during = during
    }
}

/// A stretch nobody touched the machine, between a pause and the next time attention landed
/// anywhere — the question docs/away-time.md asks. Derived on read, never stored.
public struct AttentionAway: Codable, Equatable, Sendable {
    /// The project the pause interrupted: what "Count for …" offers first.
    public var project: String
    public var key: String
    /// ISO 8601 in UTC, both. `from` is the last input before the pause, `to` the first `began` after.
    public var from: String
    public var to: String
    public var seconds: Double
    /// What ended the span before it: `paused` or `slept`.
    public var why: String
    /// What the machine showed meanwhile, from the `began` that ended it — `call`, or nil.
    public var during: String?

    public init(project: String, key: String, from: Date, to: Date, why: String, during: String?) {
        self.project = project
        self.key = key
        self.from = DoneLog.timestamp(from)
        self.to = DoneLog.timestamp(to)
        self.seconds = max(0, to.timeIntervalSince(from))
        self.why = why
        self.during = during
    }

    public var fromDate: Date? { DoneLog.date(from) }
    public var toDate: Date? { DoneLog.date(to) }
}

/// A stretch of attention on one project, as a read works it out.
public struct AttentionSpan: Codable, Equatable, Sendable {
    /// Where the span's end came from.
    public enum Basis: String, Codable, Sendable {
        /// An `ended` is on record. The span is what it says.
        case measured
        /// No `ended`. Closed by the evidence in the other logs, or by the cap — `endOfUnclosed`.
        case inferred
        /// Neither edge was seen: you said this range was this project's (docs/away-time.md).
        case counted
    }

    public var project: String
    public var key: String
    public var task: String?
    /// ISO 8601 in UTC, both.
    public var start: String
    public var end: String
    public var basis: Basis
    /// How long it ran, in seconds. Written into the report rather than recomputed by every reader,
    /// because the midnight split (D4) means `end - start` is not always the answer.
    public var seconds: Double

    public init(project: String, key: String, task: String?, start: Date, end: Date, basis: Basis) {
        self.project = project
        self.key = key
        self.task = task
        self.start = DoneLog.timestamp(start)
        self.end = DoneLog.timestamp(end)
        self.basis = basis
        self.seconds = max(0, end.timeIntervalSince(start))
    }

    public var startDate: Date? { DoneLog.date(start) }
    public var endDate: Date? { DoneLog.date(end) }
}

public enum AttentionLog {
    /// How long with no input before Folio writes a pause, back-dated to the last sign of life (D3).
    /// Whether that quiet counts is decided on read, not here: back on the same project within
    /// `longestQuiet`, it was focus all along (docs/away-time.md).
    ///
    /// Hardcoded, with the same note `sessionIdleWindow` carries: the obvious thing to lift into
    /// Settings when it earns a control.
    public static let attentionPause: TimeInterval = 10 * 60

    /// What an unwitnessed span is worth. A `began` with no `ended` and nothing in any other log to
    /// show for it gets an hour of the benefit of the doubt and no more.
    public static let attentionCap: TimeInterval = 60 * 60

    /// The longest gap that's still a question. Past it, a gap is a night or a day off, and asking
    /// whether it was work would be noise (docs/away-time.md). The shortest is `attentionPause`, for a
    /// lock or a lid as much as for a pause: under it is a break, and it isn't asked about either.
    public static let longestAway: TimeInterval = 4 * 60 * 60

    /// The longest return that doesn't break a gap in two. Something that touches the machine once —
    /// a keep-awake jiggle, a nudged mouse — resumes a span for a moment, and ten minutes later the
    /// pause is back-dated to that one touch. The log from 2026-09-22 has five of these in a row, one
    /// every fifteen minutes: one eighty-minute absence, which must neither pass for five short quiet
    /// stretches (`longestQuiet`) nor be asked about five times.
    ///
    /// Short, because a real return can be short — typing a prompt, scrolling an agent's output. It
    /// can be, because Folio stamps a resumption within seconds of the first input (`AttentionKeeper`).
    public static let awayBlip: TimeInterval = 30

    /// The longest quiet stretch that's still focus (docs/away-time.md): no input, but nothing that
    /// says you left — no lock, no lid, no sleep, no app you've said isn't work — and you came back to
    /// the same project. Reading an agent's work, thinking about it. The display going dark on its own
    /// timer doesn't count as leaving.
    ///
    /// Past it, the whole stretch is an away, to be counted or not; an unlocked lunch and a long
    /// agent run look the same from here, and only you know which it was.
    public static let longestQuiet: TimeInterval = 15 * 60

    /// Beside the journal in the config dir, not in a project folder — see the note at the top.
    public static var logPath: String {
        (getConfigDir() as NSString).appendingPathComponent("attention.ndjson")
    }

    public static func newID() -> String { UUID().uuidString.lowercased() }

    // MARK: Writing

    /// Append events, under the `flock` discipline the other two logs use: Folio's timekeeper and a
    /// `pm` call can write at the same moment, and two appends interleaving mid-line would corrupt both.
    ///
    /// Never throws. Failing to record where the time went must not fail the thing that moved it — the
    /// same rule the journal keeps, for the same reason: a full disk is a reason to lose the record,
    /// not the work. A dropped `ended` costs an inferred span rather than a wrong one.
    public static func append(_ events: [AttentionEvent]) {
        guard !events.isEmpty else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var lines = ""
        for event in events {
            guard let data = try? encoder.encode(event) else { continue }
            lines += String(decoding: data, as: UTF8.self) + "\n"
        }
        guard !lines.isEmpty else { return }
        try? FileManager.default.createDirectory(atPath: getConfigDir(), withIntermediateDirectories: true)
        let fd = open(logPath, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { return }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { return }
        defer { flock(fd, LOCK_UN) }
        let bytes = Array(lines.utf8)
        _ = write(fd, bytes, bytes.count)
    }

    /// Record that attention arrived at a project. What `project.focus` and Folio's timekeeper both call.
    public static func began(project: String, key: String, task: String? = nil, why: String? = nil,
                             source: String? = nil, at: Date = Date()) {
        append([AttentionEvent(at: DoneLog.timestamp(at), event: .began, project: project, key: key,
                               task: task, why: why, source: source)])
    }

    /// Record that attention left it, at the moment it actually left (D3) rather than now.
    public static func ended(project: String, key: String, why: String? = nil, source: String? = nil,
                             at: Date = Date()) {
        append([AttentionEvent(at: DoneLog.timestamp(at), event: .ended, project: project, key: key,
                               why: why, source: source)])
    }

    /// Record an answer about `from`..`to`: it was `project`'s, or, with no project, it wasn't work.
    /// Returns the event so undo can name it in a `withdraw`.
    @discardableResult
    public static func counted(from: Date, to: Date, project: String? = nil, key: String? = nil,
                               source: String? = nil, at: Date = Date()) -> AttentionEvent {
        let event = AttentionEvent(at: DoneLog.timestamp(at), event: .counted, project: project,
                                   key: key, source: source, from: DoneLog.timestamp(from),
                                   to: DoneLog.timestamp(to))
        append([event])
        return event
    }

    /// Take back a `counted`, by its id. The range reads as if the answer had never been given.
    public static func withdraw(_ id: String, source: String? = nil, at: Date = Date()) {
        append([AttentionEvent(at: DoneLog.timestamp(at), event: .withdrawn, project: nil, key: nil,
                               source: source, ref: id)])
    }

    // MARK: Reading

    /// The last edge written, without reading the whole log.
    ///
    /// What Folio's timekeeper checks before writing a `began` of its own: a focus that came through
    /// `project.focus` has already recorded one, and two in a row would put a stray few-second span
    /// against the project. Reads the file's tail, so it costs the same on a log of any age.
    public static func lastEvent() -> AttentionEvent? {
        guard let handle = FileHandle(forReadingAtPath: logPath) else { return nil }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return nil }
        let window: UInt64 = 8 * 1024
        try? handle.seek(toOffset: end > window ? end - window : 0)
        guard let data = try? handle.readToEnd(),
              let last = String(decoding: data, as: UTF8.self)
                  .split(separator: "\n", omittingEmptySubsequences: true).last
        else { return nil }
        return try? JSONDecoder().decode(AttentionEvent.self, from: Data(last.utf8))
    }

    public static func events() -> [AttentionEvent] {
        guard let text = try? String(contentsOfFile: logPath, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        return text.split(separator: "\n")
            .compactMap { try? decoder.decode(AttentionEvent.self, from: Data($0.utf8)) }
    }

    // MARK: The derivation
    //
    // Pure, and the whole of what's worth testing: everything above it is file handling and everything
    // below it is presentation.

    /// One edge, parsed and in order.
    struct Edge {
        let at: Date
        let event: AttentionEvent
    }

    /// The spans the log describes, oldest first.
    ///
    /// `evidence` is the moments the other three logs tie to each project, by folder name — what
    /// `SessionTimes.evidence` already gathers. It closes the spans no `ended` closed (D4).
    ///
    /// `now` bounds the span still running. A report for a past day passes the end of that day, so
    /// yesterday's last span doesn't grow every time it's read.
    ///
    /// `only` keeps the spans of those project folders and drops the rest — *after* the whole log has
    /// been read, never before: another project's `began` is what ends this one's span, and a
    /// `counted` for another project is what takes time away from it.
    public static func spans(from events: [AttentionEvent], evidence: [String: [Date]] = [:],
                             now: Date = Date(), only: Set<String>? = nil) -> [AttentionSpan] {
        let edges = events
            .compactMap { event in DoneLog.date(event.at).map { Edge(at: $0, event: event) } }
            .sorted { $0.at < $1.at }
        var out: [AttentionSpan] = []
        // The span still open, if any: where it began, and on what.
        var open: (start: Date, project: String, key: String, task: String?)?

        func closeSpan(_ span: (start: Date, project: String, key: String, task: String?),
                       by edge: Edge?) {
            // Never past the next edge: that's where attention demonstrably went somewhere else.
            let limit = min(edge?.at ?? now, now)
            guard limit > span.start else { open = nil; return }
            let end: Date
            let basis: AttentionSpan.Basis
            if let edge, edge.event.event == .ended, edge.event.key == span.key {
                end = limit
                basis = .measured
            } else {
                end = endOfUnclosed(span.start, limit: limit, evidence: evidence[span.project] ?? [])
                basis = .inferred
            }
            guard end > span.start else { open = nil; return }
            out.append(AttentionSpan(project: span.project, key: span.key, task: span.task,
                                     start: span.start, end: end, basis: basis))
            open = nil
        }

        for edge in edges {
            switch edge.event.event {
            case .began:
                guard let project = edge.event.project, let key = edge.event.key else { continue }
                // A `began` implicitly ends whatever attention was on: one project at a time.
                if let span = open { closeSpan(span, by: edge) }
                open = (edge.at, project, key, edge.event.task)
            case .ended:
                guard let span = open else { continue }
                // An `ended` for a project that isn't the open one is a stale edge — Folio closing a
                // span a later `began` from another surface already superseded. It still bounds this
                // one, but it doesn't measure it.
                closeSpan(span, by: edge)
            case .counted, .withdrawn:
                // Answers, not movements of attention: they neither open nor close a span, and are
                // laid over the finished spans below.
                continue
            }
        }
        if let span = open { closeSpan(span, by: nil) }
        // Quiet first, answers over it: an answer about a range beats what the log implies about it.
        let quiet = resolvingGaps(out, gaps: gaps(edges), now: now)
        let counted = applyingCounts(to: quiet, from: edges, now: now)
        guard let only else { return counted }
        return counted.filter { only.contains($0.project) }
    }

    /// The spans with every standing `counted` laid over them (docs/away-time.md).
    ///
    /// Applied in the order the answers were *given*, so a later answer about a range beats an earlier
    /// one — including an earlier `counted` span, which the later one cuts like any other. A `counted`
    /// that a `withdrawn` names is skipped entirely, which puts back exactly what it covered.
    static func applyingCounts(to spans: [AttentionSpan], from edges: [Edge], now: Date)
        -> [AttentionSpan] {
        let withdrawn = Set(edges.compactMap { $0.event.event == .withdrawn ? $0.event.ref : nil })
        var spans = spans
        for edge in edges where edge.event.event == .counted && !withdrawn.contains(edge.event.id) {
            // Nothing is known past `now`, so no answer can claim it.
            guard let from = edge.event.from.flatMap(DoneLog.date),
                  let to = edge.event.to.flatMap(DoneLog.date).map({ min($0, now) }),
                  to > from else { continue }
            spans = spans.flatMap { removing(from, to, from: $0) }
            if let project = edge.event.project, let key = edge.event.key {
                spans.append(AttentionSpan(project: project, key: key, task: nil,
                                           start: from, end: to, basis: .counted))
            }
        }
        return spans.sorted { ($0.startDate ?? .distantPast) < ($1.startDate ?? .distantPast) }
    }

    // MARK: Gaps

    /// A stretch with nobody at the keys: from a pause, a lock or a sleep to the next `began` on any
    /// project, with touch-short returns inside it joined up (`awayBlip`). What both quiet focus and
    /// aways are cut from (docs/away-time.md).
    struct Gap {
        var from: Date
        var to: Date
        /// The project it interrupted.
        var project: String
        var key: String
        /// What opened it: `paused`, `slept`, `locked`.
        var why: String
        var during: String?
        /// A lock, a lid or a sleep anywhere in it: you left the machine.
        var left: Bool
        /// An app you've said isn't work came to the front during it.
        var elsewhere: Bool
        /// Where attention landed when it ended.
        var returnKey: String?

        var seconds: TimeInterval { to.timeIntervalSince(from) }

        /// Still focus: nothing says you left, you came back to the same project, and not after so
        /// long that it could as easily have been lunch (`longestQuiet`).
        var isQuiet: Bool { !left && !elsewhere && returnKey == key && seconds <= longestQuiet }
    }

    /// The reasons an `ended` gives that mean you left the machine rather than stopped touching it.
    /// `slept` in logs written before 2026-09-23 also covers the display sleeping on its own timer;
    /// those gaps are read as leaving, which is the direction that never overcounts.
    static let leaves: Set<String> = ["slept", "locked"]

    /// Every gap in the log, oldest first, of any length. Nothing is filtered here: a short gap can be
    /// part of a long one once blips are joined, and what each reader wants of them differs.
    static func gaps(_ edges: [Edge]) -> [Gap] {
        var gaps: [Gap] = []
        // The gap still waiting for attention to land somewhere again.
        var pending: Gap?
        for edge in edges {
            let event = edge.event
            switch event.event {
            case .ended:
                if var gap = pending {
                    // Already quiet: a later `ended` doesn't move when the hands left, but it says what
                    // happened while they were gone.
                    if leaves.contains(event.why ?? "") { gap.left = true }
                    if event.why == "elsewhere" { gap.elsewhere = true }
                    pending = gap
                    continue
                }
                guard let why = event.why, why == "paused" || leaves.contains(why),
                      let project = event.project, let key = event.key else { continue }
                pending = Gap(from: edge.at, to: edge.at, project: project, key: key, why: why,
                              during: nil, left: leaves.contains(why), elsewhere: false, returnKey: nil)
            case .began:
                guard var gap = pending else { continue }
                pending = nil
                gap.to = edge.at
                gap.during = event.during
                gap.returnKey = event.key
                if var last = gaps.last, gap.from.timeIntervalSince(last.to) < awayBlip {
                    // The first part says what was interrupted and why; what any part saw holds for
                    // the whole, and the last part says where attention landed.
                    last.to = gap.to
                    last.during = last.during ?? gap.during
                    last.left = last.left || gap.left
                    last.elsewhere = last.elsewhere || gap.elsewhere
                    last.returnKey = gap.returnKey
                    gaps[gaps.count - 1] = last
                } else {
                    gaps.append(gap)
                }
            case .counted, .withdrawn:
                continue
            }
        }
        return gaps
    }

    /// The spans with every gap made whole. A quiet gap is given back to the project it interrupted,
    /// joined to the spans either side of it — measured, not counted: nobody answered anything, and
    /// the log says exactly where the quiet began and ended. Any other gap is emptied of the
    /// touch-short spans its joining swallowed: it's one away, not an away with seconds of work in it.
    static func resolvingGaps(_ spans: [AttentionSpan], gaps: [Gap], now: Date) -> [AttentionSpan] {
        var spans = spans
        for gap in gaps {
            let to = min(gap.to, now)
            guard to > gap.from else { continue }
            spans = spans.flatMap { removing(gap.from, to, from: $0) }
            if gap.isQuiet {
                spans.append(AttentionSpan(project: gap.project, key: gap.key, task: nil,
                                           start: gap.from, end: to, basis: .measured))
            }
        }
        return coalescing(spans)
    }

    /// Adjacent spans of one project on one basis, as one span. Keeps the first one's task.
    static func coalescing(_ spans: [AttentionSpan]) -> [AttentionSpan] {
        var out: [AttentionSpan] = []
        for span in spans.sorted(by: { ($0.startDate ?? .distantPast) < ($1.startDate ?? .distantPast) }) {
            if let last = out.last, last.key == span.key, last.basis == span.basis, last.end == span.start,
               let start = last.startDate, let end = span.endDate {
                out[out.count - 1] = AttentionSpan(project: last.project, key: last.key,
                                                   task: last.task ?? span.task, start: start, end: end,
                                                   basis: last.basis)
            } else {
                out.append(span)
            }
        }
        return out
    }

    // MARK: Aways

    /// The gaps still worth asking about, oldest first (docs/away-time.md). Every gap is one, except:
    ///
    /// - quiet — it's focus already, and there's nothing to ask (`Gap.isQuiet`);
    /// - one with an app you've said isn't work in it — you answered by opening it;
    /// - under `attentionPause` or over `longestAway` — a break, or a night;
    /// - one a standing `counted` overlaps, whatever it said — "not work" is an answer too.
    ///
    /// A gap still going isn't one yet: nobody's back to be asked.
    ///
    /// `range`, when given, keeps the aways that *began* in it, as a span belongs to the day it began.
    public static func aways(from events: [AttentionEvent], in range: DoneRange? = nil)
        -> [AttentionAway] {
        let edges = events
            .compactMap { event in DoneLog.date(event.at).map { Edge(at: $0, event: event) } }
            .sorted { $0.at < $1.at }
        let withdrawn = Set(edges.compactMap { $0.event.event == .withdrawn ? $0.event.ref : nil })
        let answers: [(from: Date, to: Date)] = edges.compactMap { edge in
            guard edge.event.event == .counted, !withdrawn.contains(edge.event.id),
                  let from = edge.event.from.flatMap(DoneLog.date),
                  let to = edge.event.to.flatMap(DoneLog.date) else { return nil }
            return (from, to)
        }

        return gaps(edges).compactMap { gap in
            guard !gap.isQuiet, !gap.elsewhere,
                  gap.seconds >= attentionPause, gap.seconds <= longestAway else { return nil }
            if let range, !(gap.from >= range.start && gap.from < range.end) { return nil }
            guard !answers.contains(where: { $0.from < gap.to && $0.to > gap.from }) else { return nil }
            return AttentionAway(project: gap.project, key: gap.key, from: gap.from, to: gap.to,
                                 why: gap.why, during: gap.during)
        }
    }

    /// What's left of `span` once `from`..`to` is taken out of it: itself, one piece or two.
    static func removing(_ from: Date, _ to: Date, from span: AttentionSpan) -> [AttentionSpan] {
        guard let start = span.startDate, let end = span.endDate, from < end, to > start else {
            return [span]
        }
        var pieces: [AttentionSpan] = []
        if start < from {
            pieces.append(AttentionSpan(project: span.project, key: span.key, task: span.task,
                                        start: start, end: from, basis: span.basis))
        }
        if to < end {
            pieces.append(AttentionSpan(project: span.project, key: span.key, task: span.task,
                                        start: to, end: end, basis: span.basis))
        }
        return pieces
    }

    /// Where an unclosed span ends (D4).
    ///
    /// **Proof beats the cap.** A write at 11:40 says you were still on it at 11:40, so a long stretch
    /// of evidence is credited in full. It is only the case with *nothing* on record that the cap
    /// decides, and there it is the whole of what's known: an hour of the benefit of the doubt.
    static func endOfUnclosed(_ start: Date, limit: Date, evidence: [Date]) -> Date {
        let inside = evidence.filter { $0 > start && $0 <= limit }
        if let latest = inside.max() { return latest }
        return min(limit, start.addingTimeInterval(attentionCap))
    }

    /// The spans that fall in `range`, each cut back to it.
    ///
    /// A span is clipped rather than dropped: a stretch of work that began at 23:50 on Monday is ten
    /// minutes of Monday, and a report for Tuesday shouldn't be given them. (`splittingAtMidnight` has
    /// usually done this already; a range of several days is where the clip earns its place.)
    public static func clipped(_ spans: [AttentionSpan], to range: DoneRange) -> [AttentionSpan] {
        spans.compactMap { span in
            guard let start = span.startDate, let end = span.endDate else { return nil }
            let from = max(start, range.start)
            let to = min(end, range.end)
            guard to > from else { return nil }
            guard from != start || to != end else { return span }
            return AttentionSpan(project: span.project, key: span.key, task: span.task,
                                 start: from, end: to, basis: span.basis)
        }
    }

    /// The spans, cut at midnight so a day's total is a day's (D4). A span that runs from 23:40 to
    /// 00:30 is forty minutes of one day and thirty of the next, and neither day should be told the
    /// other's story.
    public static func splittingAtMidnight(_ spans: [AttentionSpan],
                                           calendar: Calendar = .current) -> [AttentionSpan] {
        var out: [AttentionSpan] = []
        for span in spans {
            guard var start = span.startDate, let end = span.endDate else { continue }
            while start < end {
                let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: start))
                let piece = min(midnight ?? end, end)
                out.append(AttentionSpan(project: span.project, key: span.key, task: span.task,
                                         start: start, end: piece, basis: span.basis))
                start = piece
            }
        }
        return out
    }
}
