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
    }

    public var id: String
    /// When it happened, ISO 8601 in UTC.
    public var at: String
    public var event: Kind
    /// The project's folder name — what a report groups and prints by.
    public var project: String
    /// Its `<basePath>:<folder>` key, the spelling `focused.json` uses. Kept beside the folder name so
    /// two projects of the same name in different scopes are two projects here too.
    public var key: String
    /// `began`: the focused task when it did, as colour. Never totalled — see D1.
    public var task: String?
    /// Why the edge happened. `began`: `switched` (the default, not written), `resumed` after a pause.
    /// `ended`: `switched`, `paused`, `slept`, `quit`.
    public var why: String?
    /// Which surface did it — "app", "cli", "raycast", a model.
    public var source: String?

    public init(id: String = AttentionLog.newID(), at: String, event: Kind, project: String,
                key: String, task: String? = nil, why: String? = nil, source: String? = nil) {
        self.id = id
        self.at = at
        self.event = event
        self.project = project
        self.key = key
        self.task = task
        self.why = why
        self.source = source
    }
}

/// A stretch of attention on one project, as a read works it out.
public struct AttentionSpan: Codable, Equatable, Sendable {
    /// Where the span's end came from.
    public enum Basis: String, Codable, Sendable {
        /// An `ended` is on record. The span is what it says.
        case measured
        /// No `ended`. Closed by the evidence in the other logs, or by the cap — `endOfUnclosed`.
        case inferred
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
    /// The longest pause that still counts as working — the *only* thing this threshold decides, since
    /// an `ended` is back-dated to the last sign of life either way (D3). Ten minutes is long enough to
    /// read a document, watch something or think at the screen, and short enough that a coffee isn't
    /// work.
    ///
    /// Hardcoded, with the same note `sessionIdleWindow` carries: the obvious thing to lift into
    /// Settings when it earns a control.
    public static let attentionPause: TimeInterval = 10 * 60

    /// What an unwitnessed span is worth. A `began` with no `ended` and nothing in any other log to
    /// show for it gets an hour of the benefit of the doubt and no more.
    public static let attentionCap: TimeInterval = 60 * 60

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
    public static func spans(from events: [AttentionEvent], evidence: [String: [Date]] = [:],
                             now: Date = Date()) -> [AttentionSpan] {
        let edges = events
            .compactMap { event in DoneLog.date(event.at).map { Edge(at: $0, event: event) } }
            .sorted { $0.at < $1.at }
        var out: [AttentionSpan] = []
        // The span still open, if any: where it began, and on what.
        var open: (start: Date, event: AttentionEvent)?

        func closeSpan(_ span: (start: Date, event: AttentionEvent), by edge: Edge?) {
            // Never past the next edge: that's where attention demonstrably went somewhere else.
            let limit = min(edge?.at ?? now, now)
            guard limit > span.start else { open = nil; return }
            let end: Date
            let basis: AttentionSpan.Basis
            if let edge, edge.event.event == .ended, edge.event.key == span.event.key {
                end = limit
                basis = .measured
            } else {
                end = endOfUnclosed(span.start, limit: limit,
                                    evidence: evidence[span.event.project] ?? [])
                basis = .inferred
            }
            guard end > span.start else { open = nil; return }
            out.append(AttentionSpan(project: span.event.project, key: span.event.key,
                                     task: span.event.task, start: span.start, end: end, basis: basis))
            open = nil
        }

        for edge in edges {
            switch edge.event.event {
            case .began:
                // A `began` implicitly ends whatever attention was on: one project at a time.
                if let span = open { closeSpan(span, by: edge) }
                open = (edge.at, edge.event)
            case .ended:
                guard let span = open else { continue }
                // An `ended` for a project that isn't the open one is a stale edge — Folio closing a
                // span a later `began` from another surface already superseded. It still bounds this
                // one, but it doesn't measure it.
                closeSpan(span, by: edge)
            }
        }
        if let span = open { closeSpan(span, by: nil) }
        return out
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
