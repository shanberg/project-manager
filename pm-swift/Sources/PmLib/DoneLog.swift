import Foundation

// MARK: - What got done
//
// A notes file is state: it says a task is done, not when it became done. The session heading above a
// task is when it was *written*, so reading completion dates off the document reports a task captured
// three weeks ago and finished today as three weeks old. This is the other half — an append-only log
// of events, one per project folder, that answers "what happened" without adding a byte to the notes.
// See docs/done-report.md.
//
// ## Observed, not hooked
//
// Nothing here is called by "the code that completes a task", because there isn't one. The contract
// completes tasks, the Siri intents complete them without the contract, and Obsidian or a text editor
// completes them without PM at all. So the log is written by *looking*: compare what's checked now
// against what was checked the last time this project was seen, and append whatever changed. Every
// write that goes through a `NotesIO` looks straight afterwards, so PM's own completions are stamped
// the moment they land; a sweep before every report catches up on everything else, stamped when it
// was noticed.
//
// ## By text, counted
//
// A task is matched by its digest, and the baseline is a count per digest — how many open, how many
// checked — not a list of positions. Sessions start above tasks, tasks move, and none of that is
// completion; a count doesn't see it. A completion is one task of that text going from open to
// checked: the checked count rose *and* the open count fell. A task written already checked, a checked
// task renamed, or one pasted in from elsewhere raises only the first, and is not something you did
// today.

/// One thing that happened to a task.
public struct DoneEvent: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case completed, reopened
        /// Closed without being done. Logged so the record is whole, and left out of what got done.
        case dropped
    }

    /// When it was noticed, ISO 8601 in UTC. For a write PM made, that is when it happened.
    public var at: String
    public var event: Kind
    /// A copy of the task's text, because the line may be gone by the time anybody reports on it —
    /// tidying finished work out of the notes doesn't un-finish it.
    public var text: String
    public var digest: String
    /// The ISO date of the session the task sat under: when it was written, as opposed to `at`.
    public var session: String?

    public init(at: String, event: Kind, text: String, digest: String, session: String? = nil) {
        self.at = at
        self.event = event
        self.text = text
        self.digest = digest
        self.session = session
    }
}

/// A finished task as a report lists it.
public struct DoneItem: Codable, Equatable, Sendable {
    public let projectFolder: String
    public let projectName: String
    public let isArchived: Bool
    /// When it was done, ISO 8601 in UTC.
    public let at: String
    public let text: String
    public let session: String?
    /// Dropped rather than done. Only ever true in a report that asked for dropped tasks.
    public let dropped: Bool
}

public enum DoneLog {
    /// Dot-prefixed so Obsidian's file tree and Finder leave them alone. Both live in the project
    /// folder, so they move with it through a rename and through archiving, and sync with the vault.
    ///
    /// The baseline is in the folder too, not in the config dir, for a reason that only shows with two
    /// Macs: a baseline that didn't sync would have the second machine find every completion the first
    /// one made and log it again.
    static let logName = ".pm-done.ndjson"
    static let baselineName = ".pm-seen.json"

    public static func logPath(projectPath: String) -> String {
        (projectPath as NSString).appendingPathComponent(logName)
    }

    static func baselinePath(projectPath: String) -> String {
        (projectPath as NSString).appendingPathComponent(baselineName)
    }

    /// How many tasks of each text are open, done and dropped — `[open, done, dropped]`, keyed by
    /// digest. A baseline written before dropping existed has `[open, done]`; `triple` reads the
    /// missing count as zero, which is what it was.
    typealias Counts = [String: [Int]]

    static func triple(_ counts: [Int]?) -> [Int] {
        let c = counts ?? []
        return [0, 1, 2].map { $0 < c.count ? c[$0] : 0 }
    }

    private struct Baseline: Codable {
        var tasks: Counts
    }

    // MARK: Looking

    /// Look at a project's notes and log whatever was completed or reopened since the last look.
    ///
    /// The first look at a project records what's there and logs nothing: tasks already checked when
    /// PM first saw them were done at some time nobody can know, and inventing one would put a year's
    /// work into the first report.
    ///
    /// Never throws. The notes file is the truth and the log is a record of it, so a log that can't be
    /// written is a reason to lose the record, not to fail the write that prompted the look.
    public static func observe(projectPath: String, rawText: String, now: Date = Date()) {
        guard let notes = try? parseNotes(markdown: rawText),
              let todos = try? parseTodos(notes: notes) else { return }
        let current = counts(of: todos)

        let fm = FileManager.default
        guard fm.fileExists(atPath: projectPath) else { return }
        let log = logPath(projectPath: projectPath)
        if !fm.fileExists(atPath: log) { fm.createFile(atPath: log, contents: nil) }
        // Held across read-baseline, append, write-baseline. The app and a `pm` call can write the same
        // project at the same moment, and two looks that both read the old baseline would both log the
        // completion. Locked on the log rather than the baseline because the baseline is replaced
        // atomically — a new inode — and a lock on a file that's been replaced locks nothing.
        let fd = open(log, O_WRONLY | O_APPEND)
        guard fd >= 0 else { return }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { return }
        defer { flock(fd, LOCK_UN) }

        let baselineURL = URL(fileURLWithPath: baselinePath(projectPath: projectPath))
        guard let data = try? Data(contentsOf: baselineURL),
              let previous = try? JSONDecoder().decode(Baseline.self, from: data) else {
            save(Baseline(tasks: current), to: baselineURL)
            return
        }
        guard previous.tasks != current else { return }

        let events = changes(from: previous.tasks, to: current, todos: todos, at: timestamp(now))
        if !events.isEmpty {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            var lines = ""
            for event in events {
                guard let data = try? encoder.encode(event),
                      let line = String(data: data, encoding: .utf8) else { continue }
                lines += line + "\n"
            }
            // Before the baseline, never after: if this is interrupted between the two, the next look
            // finds the same change and logs it again, which is a duplicate. The other order loses it.
            let bytes = Array(lines.utf8)
            guard write(fd, bytes, bytes.count) == bytes.count else { return }
        }
        save(Baseline(tasks: current), to: baselineURL)
    }

    /// `observe`, for a write that only has the path of the file it wrote. Anything that isn't one of
    /// PM's notes files — by the same name test the canvas uses — is left alone.
    static func observeWrite(notesPath: String, content: String) {
        guard let projectPath = projectFolder(ofNotesPath: notesPath) else { return }
        observe(projectPath: projectPath, rawText: content)
    }

    private static func save(_ baseline: Baseline, to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(baseline) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func counts(of todos: [Todo]) -> Counts {
        var out: Counts = [:]
        for todo in todos {
            let digest = todo.digest ?? taskDigest(todo.text)
            var counts = out[digest] ?? [0, 0, 0]
            switch todo.state {
            case .open: counts[0] += 1
            case .done: counts[1] += 1
            case .dropped: counts[2] += 1
            }
            out[digest] = counts
        }
        return out
    }

    /// The events that take one set of counts to the other. Pure, so the rules are testable without a
    /// file in sight.
    ///
    /// A move between two states is only counted when one count fell and the other rose by the same
    /// task's worth, the rule a completion has always had. Moving straight from done to dropped (or back)
    /// is logged as the two things it is, a reopening and then the other closing, so `standing` never
    /// needs to know about more than "a reopening cancels the latest closing".
    static func changes(from old: Counts, to new: Counts, todos: [Todo], at: String) -> [DoneEvent] {
        var events: [DoneEvent] = []
        // Sorted, so one look logs its events in the same order every time.
        for digest in Set(old.keys).union(new.keys).sorted() {
            let was = triple(old[digest]), now = triple(new[digest])
            func fell(_ i: Int) -> Int { max(was[i] - now[i], 0) }
            func rose(_ i: Int) -> Int { max(now[i] - was[i], 0) }

            let openToDone = min(fell(0), rose(1))
            let openToDropped = min(fell(0) - openToDone, rose(2))
            let doneToOpen = min(fell(1), rose(0))
            let droppedToOpen = min(fell(2), rose(0) - doneToOpen)
            let doneToDropped = min(fell(1) - doneToOpen, rose(2) - openToDropped)
            let droppedToDone = min(fell(2) - droppedToOpen, rose(1) - openToDone)

            let reopened = doneToOpen + droppedToOpen + doneToDropped + droppedToDone
            let completed = openToDone + droppedToDone
            let dropped = openToDropped + doneToDropped
            guard reopened + completed + dropped > 0 else { continue }
            // Every task with this digest has this text; the session is the one the changed task is in,
            // as near as a count can say — the first one now in the state the event names.
            let matching = todos.filter { ($0.digest ?? taskDigest($0.text)) == digest }
            func example(_ state: TaskState) -> Todo? { matching.first { $0.state == state } ?? matching.first }
            func log(_ n: Int, _ kind: DoneEvent.Kind, _ state: TaskState) {
                guard n > 0, let todo = example(state) else { return }
                for _ in 0..<n {
                    events.append(DoneEvent(at: at, event: kind, text: todo.text, digest: digest,
                                            session: todo.sessionISODate))
                }
            }
            // Reopenings first: a done task dropped is a reopening *then* a drop, and in the other order
            // the reopening would cancel the drop it came with.
            log(reopened, .reopened, .open)
            log(completed, .completed, .done)
            log(dropped, .dropped, .dropped)
        }
        return events
    }

    // MARK: Reading

    public static func events(projectPath: String) -> [DoneEvent] {
        guard let text = try? String(contentsOfFile: logPath(projectPath: projectPath), encoding: .utf8)
        else { return [] }
        let decoder = JSONDecoder()
        return text.split(separator: "\n").compactMap { try? decoder.decode(DoneEvent.self, from: Data($0.utf8)) }
    }

    /// The closings that still stand, completions and drops: each reopening cancels the latest closing
    /// of the same task before it. Done on the 1st and reopened on the 3rd was not done that week; done
    /// again on the 5th was done on the 5th.
    static func standing(_ events: [DoneEvent]) -> [DoneEvent] {
        var kept: [DoneEvent?] = []
        var open: [String: [Int]] = [:]
        for event in events {
            switch event.event {
            case .completed, .dropped:
                open[event.digest, default: []].append(kept.count)
                kept.append(event)
            case .reopened:
                if let index = open[event.digest]?.popLast() { kept[index] = nil }
            }
        }
        return kept.compactMap { $0 }
    }

    public static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    public static func date(_ timestamp: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: timestamp)
    }
}

// MARK: - The report

/// A span of local days, start inclusive, end exclusive.
public struct DoneRange: Equatable {
    public let start: Date
    public let end: Date

    /// `today` is the day `now` falls in, `yesterday` the one before it; `week` is the calendar week and
    /// `month` the calendar month, both by the reader's own calendar. `since` and `until` are local
    /// dates, both inclusive, and override the period's ends.
    public static func resolve(period: String?, since: String?, until: String?, now: Date = Date(),
                               calendar: Calendar = .current) throws -> DoneRange {
        let today = calendar.startOfDay(for: now)
        var start = today
        var end = calendar.date(byAdding: .day, value: 1, to: today) ?? today
        if period == "week", let week = calendar.dateInterval(of: .weekOfYear, for: now) {
            start = week.start
            end = week.end
        }
        if period == "month", let month = calendar.dateInterval(of: .month, for: now) {
            start = month.start
            end = month.end
        }
        if period == "yesterday", let before = calendar.date(byAdding: .day, value: -1, to: today) {
            start = before
            end = today
        }
        if let since { start = try localDay(since, calendar: calendar) }
        if let until {
            let day = try localDay(until, calendar: calendar)
            end = calendar.date(byAdding: .day, value: 1, to: day) ?? day
        }
        return DoneRange(start: start, end: end)
    }

    /// Midnight at the start of a `YYYY-MM-DD` in the reader's timezone. Not `parseSessionDateArgument`,
    /// which pins noon UTC so a heading formats the same everywhere — a report's "Tuesday" is the
    /// reader's Tuesday.
    public static func localDay(_ string: String, calendar: Calendar) throws -> Date {
        let parts = string.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3,
              let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
        else { throw PmError.invalidSessionDate(value: string) }
        return calendar.startOfDay(for: date)
    }

    public func contains(_ date: Date) -> Bool { date >= start && date < end }
}

/// Everything completed in a range, across every project, newest first.
///
/// Looks at every project before reading its log, so a task ticked in Obsidian an hour ago is in the
/// answer rather than waiting for PM to happen to write that project. Archived projects are included by
/// default: finishing something and archiving it the same week is the most done a thing can be.
///
/// Dropped tasks are left out unless `includeDropped` asks for them: the report is what got done.
public func doneTasks(in range: DoneRange, includeArchived: Bool = true,
                      includeActive: Bool = true, includeDropped: Bool = false) throws -> [DoneItem] {
    let (config, paths) = try loadConfigAndPaths(skipPathValidation: true)
    let codes = Array(config.domains.keys)
    var scopes: [ProjectScope] = []
    if includeActive { scopes.append(contentsOf: [.active, .areas]) }
    if includeArchived { scopes.append(.archive) }

    var items: [(date: Date, item: DoneItem)] = []
    // Areas may share the active root when `areasPath` is unset; a folder is one project however many
    // scopes list it.
    var seen = Set<String>()
    for scope in scopes {
        let base = scope.path(in: paths)
        for folder in (try? getFolders(basePath: base, scope: scope, domainCodes: codes)) ?? [] {
            let projectPath = (base as NSString).appendingPathComponent(folder)
            guard seen.insert(projectPath).inserted else { continue }
            if let notesPath = (try? resolveNotesPath(projectPath: projectPath)) ?? nil,
               let rawText = try? String(contentsOfFile: notesPath, encoding: .utf8) {
                DoneLog.observe(projectPath: projectPath, rawText: rawText)
            }
            for event in DoneLog.standing(DoneLog.events(projectPath: projectPath)) {
                let dropped = event.event == .dropped
                guard includeDropped || !dropped,
                      let date = DoneLog.date(event.at), range.contains(date) else { continue }
                items.append((date, DoneItem(projectFolder: folder,
                                             projectName: projectTitle(fromFolderName: folder),
                                             isArchived: scope.isArchived, at: event.at,
                                             text: event.text, session: event.session,
                                             dropped: dropped)))
            }
        }
    }
    return items.sorted { $0.date > $1.date }.map(\.item)
}
