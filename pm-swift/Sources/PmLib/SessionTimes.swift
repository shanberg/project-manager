import Foundation

// MARK: - Giving old sittings a time
//
// Every sitting PM starts now carries the clock time it began (`sessionTimeLabel`, docs/views.md D4).
// The ones before that don't: `### Fri, Aug 22, 2026 Kickoff` is a day and a name, and a day read
// across projects can't put it in order. This gives each of them a time, once, as a migration.
//
// ## Guessed from the record, where there is one
//
// PM keeps three records with a clock in them, and each ties a moment to a sitting:
//
// - the **journal** — every write through the contract, with the sitting each change touched;
// - the **done log** — every completion, with the sitting the task sat under;
// - the **pick log** — every task picked up, with the sitting it went into.
//
// The earliest of those on the sitting's own day is the latest it can have begun, so that is the
// guess, rounded down to five minutes because a sitting begins at "about ten past", not at 10:13.
// Later days don't count: a task from the 2nd ticked on the 5th says nothing about when the 2nd began.
//
// ## Where there isn't, a placeholder
//
// 9:00 AM — a round number that reads as the default it is. A time is what orders a day, so an old
// sitting with nothing on record still gets one rather than sorting as "Earlier" forever.
//
// ## Never out of order
//
// A day can hold several sittings, some already timed. A guess is kept strictly between the timed
// sittings either side of it: evidence before the sitting below belongs to that one, and evidence
// after the sitting above belongs to that one. A placeholder that would fall outside is moved inside.
// The sittings of a day are taken oldest first, so each guess is the floor of the next.
//
// Ordinals on the records are not trusted to say *which* of a day's sittings they meant: an ordinal
// counts newest first among the sittings that existed when it was written, so a sitting started later
// that day renumbers every one before it. The bounds do that job instead.

public enum SessionTimes {
    /// One moment a record ties to a sitting's day.
    public struct Evidence: Equatable, Sendable {
        public var at: Date
        /// The sitting's ISO date, as the record names it.
        public var session: String
        public var source: Basis

        public init(at: Date, session: String, source: Basis) {
            self.at = at
            self.session = session
            self.source = source
        }
    }

    /// Where a time came from.
    public enum Basis: String, Codable, Sendable {
        case journal, done, pick, placeholder
    }

    /// A sitting given a time.
    public struct Guess: Codable, Equatable, Sendable {
        /// Its ISO date.
        public var session: String
        /// Where it is in the document, when it was read.
        public var sessionIndex: Int
        /// The name it already had, kept.
        public var name: String
        /// As the heading will say it: `9:10 AM`.
        public var time: String
        public var basis: Basis
        /// The record it came from, ISO 8601 — nil for a placeholder.
        public var evidenceAt: String?
    }

    /// The placeholder's hour.
    public static let placeholderHour = 9
    static let roundingMinutes = 5

    /// The journal as it stood before a batch began writing. A batch over every project writes one
    /// journal entry per project it changes, and the journal prunes its oldest entries past a
    /// threshold — which are exactly the evidence later projects in the batch would read. Set by the
    /// batch before its first write, cleared after its last.
    public static var journalSnapshot: [JournalEntry]?

    // MARK: Reading the record

    /// Every moment the three records tie to a sitting of the project at `projectPath`.
    ///
    /// The journal is matched on the project's folder name rather than its whole path, so a project
    /// that has since been archived keeps the entries written while it was active. One renamed since
    /// loses them, which is the safe direction: a placeholder rather than another project's time.
    public static func evidence(projectPath: String, journal: [JournalEntry]? = nil) -> [Evidence] {
        var out: [Evidence] = []
        let folder = (projectPath as NSString).lastPathComponent
        for entry in journal ?? journalSnapshot ?? ApiJournal.entries(limit: 0) {
            guard let project = entry.project, (project as NSString).lastPathComponent == folder,
                  let at = DoneLog.date(entry.at) else { continue }
            for session in Set(entry.changed.compactMap(\.ref?.session)) where isISODay(session) {
                out.append(Evidence(at: at, session: session, source: .journal))
            }
        }
        for event in DoneLog.events(projectPath: projectPath) {
            guard let session = event.session, let at = DoneLog.date(event.at) else { continue }
            out.append(Evidence(at: at, session: session, source: .done))
        }
        for event in PickLog.events(projectPath: projectPath) where event.event == .picked {
            guard let into = event.into, let at = DoneLog.date(event.at) else { continue }
            out.append(Evidence(at: at, session: into.session, source: .pick))
        }
        return out
    }

    // MARK: Guessing

    /// The document with every untimed sitting given a time, and what each was given. Nil when every
    /// sitting already has one, or the document has no sittings to give one to.
    public static func backfill(rawText: String, evidence: [Evidence],
                                calendar: Calendar = .current) throws -> (rawText: String, guesses: [Guess])? {
        let sessions = try parseNotes(markdown: rawText).sessions
        var byDay: [String: [Int]] = [:]
        for (index, session) in sessions.enumerated() {
            guard let iso = sessionISODate(heading: session.date) else { continue }
            byDay[iso, default: []].append(index)
        }

        var guesses: [Guess] = []
        for (iso, indices) in byDay {
            guard let day = localDay(iso, calendar: calendar),
                  let end = calendar.date(byAdding: .day, value: 1, to: day) else { continue }
            let onTheDay = evidence.filter {
                $0.session == iso && calendar.isDate($0.at, inSameDayAs: day)
            }.sorted { $0.at < $1.at }
            // Oldest first: the document keeps a day's sittings newest first.
            let oldestFirst = Array(indices.reversed())
            var floor: Date?
            // The last record a guess was made from. Kept apart from `floor`, which is the guess
            // *rounded down*: a record at 9:42 dates a sitting 9:40, and the next sitting must not
            // take the same record because it is later than 9:40.
            var spent: Date?
            for (position, index) in oldestFirst.enumerated() {
                let session = sessions[index]
                if let time = session.startTime, let started = clockTime(time, on: day, calendar: calendar) {
                    floor = started
                    spent = nil
                    continue
                }
                // The next sitting that day that already says when it began.
                let ceiling = oldestFirst[(position + 1)...].lazy
                    .compactMap { sessions[$0].startTime.flatMap { clockTime($0, on: day, calendar: calendar) } }
                    .first ?? end
                let after = [floor, spent].compactMap { $0 }.max()
                let found = onTheDay.first { evidence in
                    evidence.at < ceiling && after.map { evidence.at > $0 } ?? true
                }
                let started: Date
                let basis: Basis
                if let found {
                    started = rounded(found.at, above: floor, calendar: calendar)
                    basis = found.source
                } else {
                    started = placeholder(on: day, above: floor, below: ceiling, calendar: calendar)
                    basis = .placeholder
                }
                floor = started
                spent = found?.at
                guesses.append(Guess(session: iso, sessionIndex: index, name: session.name,
                                     time: clockLabel(started, calendar: calendar),
                                     basis: basis, evidenceAt: found.map { DoneLog.timestamp($0.at) }))
            }
        }
        guard !guesses.isEmpty else { return nil }

        // Only the heading lines change, so every index read above still names its sitting.
        var out = rawText
        for guess in guesses {
            let label = SessionLabel(time: guess.time, name: guess.name).text
            guard let renamed = renameSessionPreservingFormat(rawText: out, sessionIndex: guess.sessionIndex,
                                                              label: label) else { continue }
            out = renamed
        }
        return (out, guesses.sorted { $0.sessionIndex < $1.sessionIndex })
    }

    /// Down to the five minutes — but never onto or below the sitting before it, which would put the
    /// two out of order or level. Then to the minute, which a record can always keep above its floor.
    static func rounded(_ at: Date, above floor: Date?, calendar: Calendar) -> Date {
        let parts = calendar.dateComponents([.hour, .minute], from: at)
        let minute = (parts.minute ?? 0) / roundingMinutes * roundingMinutes
        let five = calendar.date(bySettingHour: parts.hour ?? 0, minute: minute, second: 0, of: at) ?? at
        if floor.map({ five > $0 }) ?? true { return five }
        return calendar.date(bySettingHour: parts.hour ?? 0, minute: parts.minute ?? 0, second: 0, of: at) ?? at
    }

    /// 9:00 AM, unless that falls outside the sittings either side — then half an hour inside
    /// whichever edge it crossed, and failing that halfway between them.
    static func placeholder(on day: Date, above floor: Date?, below ceiling: Date,
                            calendar: Calendar) -> Date {
        let nine = calendar.date(bySettingHour: placeholderHour, minute: 0, second: 0, of: day) ?? day
        func inside(_ date: Date) -> Bool { date < ceiling && floor.map { date > $0 } ?? true }
        if inside(nine) { return nine }
        let candidates = [floor.map { $0.addingTimeInterval(30 * 60) }, ceiling.addingTimeInterval(-30 * 60)]
            .compactMap { $0 }
            .map { rounded($0, above: floor, calendar: calendar) }
        if let fits = candidates.first(where: inside) { return fits }
        let low = floor ?? calendar.startOfDay(for: day)
        return rounded(low.addingTimeInterval(ceiling.timeIntervalSince(low) / 2), above: floor,
                       calendar: calendar)
    }

    /// `sessionTimeLabel`, in `calendar`'s zone rather than the machine's.
    static func clockLabel(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: date)
    }

    /// The ISO day as midnight in `calendar`'s zone — the day the heading names, where it was written.
    static func localDay(_ iso: String, calendar: Calendar) -> Date? {
        let parts = iso.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    static func isISODay(_ string: String) -> Bool {
        string.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
    }
}
