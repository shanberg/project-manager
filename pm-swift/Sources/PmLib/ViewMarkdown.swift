import Foundation

// MARK: - Every view reads as text
//
// A good share of what the views are for ends somewhere else — a standup, a client's weekly update, a
// handover — so each has a markdown rendering: the same answer laid out as a document (docs/views.md
// D10). One formatter per view, over the contract's answer, so Copy as Text on a card and `--markdown`
// on the CLI are the same words.
//
// **Plain markdown with `[[links]]`.** A project is named as PM writes one anywhere else, `[[folder]]`
// (`ProjectPartOf`, `waiting:`), so pasted into the vault it links. Task lines keep their boxes, so a
// finished one reads as finished. Dates are written out rather than said as "today", because text is
// read later than it's copied.

/// How long a project can go untouched before the Projects view calls it quiet.
public let projectQuietAfter: TimeInterval = 14 * 86_400

public enum ViewMarkdown {
    // MARK: Day

    /// A day's (or a week's) sittings: a heading per day, a heading per sitting at the time it began,
    /// its prose in full and its tasks, then what was finished in no sitting.
    public static func day(_ list: SittingList, calendar: Calendar = .current) -> String {
        var days = list.sittings.map(\.session)
        days += list.elsewhere.compactMap { DoneLog.date($0.at).map { isoDay($0, calendar: calendar) } }
        days = Array(Set(days)).sorted(by: >)
        guard !days.isEmpty else { return "Nothing written.\n" }

        var out: [String] = []
        for day in days {
            if !out.isEmpty { out.append("") }
            out.append("## \(longDay(day, calendar: calendar))")
            for sitting in list.sittings where sitting.session == day {
                out.append("")
                var title = [sitting.startTime ?? "Earlier", link(sitting.projectFolder)]
                if !sitting.name.isEmpty { title.append(sitting.name) }
                out.append("### " + title.joined(separator: " · "))
                if !sitting.prose.isEmpty {
                    out.append("")
                    // A sitting's own subheadings sit under its heading, not beside it.
                    out += sitting.prose.components(separatedBy: "\n").map { line in
                        line.range(of: #"^#{1,6}\s"#, options: .regularExpression) != nil ? "###" + line : line
                    }
                }
                let rows = dayRows(sitting, calendar: calendar)
                if !rows.isEmpty {
                    out.append("")
                    out += rows
                }
            }
            let elsewhere = list.elsewhere.filter {
                DoneLog.date($0.at).map { isoDay($0, calendar: calendar) } == day
            }
            if !elsewhere.isEmpty {
                out.append("")
                out.append("### Also finished")
                out.append("")
                out += elsewhere.map { "- [\($0.dropped ? "-" : "x")] \($0.text) · \(link($0.projectFolder))" }
            }
        }
        return out.joined(separator: "\n") + "\n"
    }

    /// A sitting's tasks, each line once: written, then picked up, then closed here but written elsewhere.
    private static func dayRows(_ sitting: SittingEntry, calendar: Calendar) -> [String] {
        var shown = Set<String>()
        var rows: [String] = []
        func add(_ task: SittingTask, depth: Int? = nil, note: String? = nil) {
            if let ref = task.ref {
                guard shown.insert("\(ref.session ?? ""):\(ref.sessionOrdinal ?? 0):\(ref.line)").inserted else { return }
            }
            rows.append(String(repeating: "  ", count: depth ?? task.depth) + "- [\(box(task.state))] \(task.text)"
                        + (note.map { " *(\($0))*" } ?? ""))
        }
        sitting.written.forEach { add($0) }
        for task in sitting.picked {
            add(task, note: task.depth == 0 ? task.from.map { "picked up from \(shortDay($0, calendar: calendar))" } : nil)
        }
        for task in sitting.finished + sitting.dropped {
            let from = task.ref?.session
            add(task, depth: 0, note: from == nil || from == sitting.session
                ? nil : "from \(shortDay(from!, calendar: calendar))")
        }
        return rows
    }

    // MARK: Leftovers

    /// The pile: each project, each sitting that left something open, its lede and its open tasks.
    /// `title` is what the cut-off is called ("before today").
    public static func leftovers(_ list: LeftoverList, before title: String = "before today",
                                 calendar: Calendar = .current) -> String {
        var out = ["## Left open \(title)"]
        guard !list.projects.isEmpty else { return out.joined() + "\n\nNothing.\n" }
        for project in list.projects {
            out.append("")
            out.append("### \(link(project.projectFolder))")
            for sitting in project.sittings {
                out.append("")
                var when = shortDay(sitting.session, calendar: calendar)
                if let time = sitting.startTime { when += " · \(time)" }
                out.append("**\(when)**" + (sitting.lede.isEmpty ? "" : " — \(oneLine(sitting.lede))"))
                out.append("")
                for task in sitting.tasks {
                    var line = String(repeating: "  ", count: task.depth) + "- [ ] \(task.text)"
                    if let due = task.due { line += " · due \(shortDay(String(due.prefix(10)), calendar: calendar))" }
                    if task.depth == 0, let picked = task.picked {
                        line += " *(picked up \(shortDay(picked.into, calendar: calendar)))*"
                    }
                    out.append(line)
                }
            }
        }
        return out.joined(separator: "\n") + "\n"
    }

    // MARK: Waiting

    /// What's being waited on, released first, and the tasks waiting on each.
    public static func waiting(_ buckets: [WaitingBucket], calendar: Calendar = .current) -> String {
        var out = ["## Waiting on"]
        guard !buckets.isEmpty else { return out.joined() + "\n\nNothing.\n" }
        for bucket in buckets {
            out.append("")
            let name = bucket.folder.map(link) ?? bucket.title
            out.append("### \(name)" + (bucket.state == "released" ? " — landed" : ""))
            out.append("")
            out += bucket.tasks.map { task(in: $0, calendar: calendar) }
        }
        return out.joined(separator: "\n") + "\n"
    }

    // MARK: Search

    public static func search(_ hits: [TaskSearchHit], query: String, calendar: Calendar = .current) -> String {
        var out = ["## Search: “\(query)”", ""]
        out += hits.isEmpty ? ["No matches."] : hits.map { task(in: $0, calendar: calendar) }
        return out.joined(separator: "\n") + "\n"
    }

    // MARK: Coming up

    /// What's due, by day: overdue first, then each day in turn.
    public static func due(_ hits: [TaskSearchHit], now: Date = Date(), calendar: Calendar = .current) -> String {
        var out = ["## Coming up"]
        guard !hits.isEmpty else { return out.joined() + "\n\nNothing due.\n" }
        let today = isoDay(now, calendar: calendar)
        var heading: String?
        for hit in hits {
            let day = String((hit.due ?? "").prefix(10))
            let this = day < today ? "Overdue" : longDay(day, calendar: calendar)
            if this != heading {
                out += ["", "### \(this)", ""]
                heading = this
            }
            var line = "- [ ] \(hit.text) · \(link(hit.projectFolder))"
            if day < today { line += " · was due \(shortDay(day, calendar: calendar))" }
            out.append(line)
        }
        return out.joined(separator: "\n") + "\n"
    }

    // MARK: Projects

    /// The portfolio: what's moving, newest first, then what's gone quiet.
    public static func projects(_ summaries: [ProjectSummary], now: Date = Date(),
                                calendar: Calendar = .current) -> String {
        var out = ["## Projects"]
        guard !summaries.isEmpty else { return out.joined() + "\n\nNone.\n" }
        let (moving, quiet) = split(summaries, now: now)
        for (title, group) in [("Moving", moving), ("Quiet", quiet)] where !group.isEmpty {
            out += ["", "### \(title)", ""]
            out += group.map { project in
                var parts = [link(project.folder)]
                if let last = project.lastActivity.flatMap(DoneLog.date) {
                    parts.append("last worked on \(shortDay(isoDay(last, calendar: calendar), calendar: calendar))")
                } else {
                    parts.append("no notes")
                }
                parts.append("\(project.open) open")
                if let due = project.nextDue {
                    parts.append("next due \(shortDay(String(due.prefix(10)), calendar: calendar))")
                }
                return "- " + parts.joined(separator: " · ")
            }
        }
        return out.joined(separator: "\n") + "\n"
    }

    // MARK: Time

    /// Where the time went: each project, longest first, with what came of it.
    ///
    /// Projects with no time against them come last, under their own heading rather than mixed in with
    /// a dash: pasted into a note, a list where half the rows have no number reads as a broken table.
    public static func time(_ report: TimeSpentReport) -> String {
        var out = ["## Where the time went"]
        let tracked = report.projects.filter { $0.seconds > 0 }
        guard !tracked.isEmpty else { return out.joined() + "\n\nNo time on record.\n" }
        out += ["", "**\(durationLabel(report.seconds))** in total.", ""]
        out += tracked.map { project in
            var line = "- \(link(project.projectFolder)) — **\(durationLabel(project.seconds))**"
            let came = changes(project)
            if !came.isEmpty { line += " · \(came)" }
            // The mark travels with the number wherever it goes: a total partly worked out rather than
            // recorded should say so in a pasted note too (docs/time-tracking.md D4).
            if project.inferred { line += " *(inferred)*" }
            return line
        }
        let untracked = report.projects.filter { $0.seconds == 0 && !changes($0).isEmpty }
        if !untracked.isEmpty {
            out += ["", "### No time on record", ""]
            out += untracked.map { "- \(link($0.projectFolder)) — \(changes($0))" }
        }
        return out.joined(separator: "\n") + "\n"
    }

    /// What came of a project's share of a period, as every surface says it.
    public static func changes(_ project: TimeSpentItem) -> String {
        var parts: [String] = []
        if project.sittings > 0 { parts.append("\(project.sittings) sitting\(project.sittings == 1 ? "" : "s")") }
        if project.done > 0 { parts.append("\(project.done) done") }
        if project.dropped > 0 { parts.append("\(project.dropped) dropped") }
        if project.picked > 0 { parts.append("\(project.picked) picked up") }
        return parts.joined(separator: " · ")
    }

    /// Projects touched within `projectQuietAfter`, and the rest, each in the order given.
    public static func split(_ summaries: [ProjectSummary], now: Date = Date())
        -> (moving: [ProjectSummary], quiet: [ProjectSummary]) {
        let isMoving: (ProjectSummary) -> Bool = { project in
            project.lastActivity.flatMap(DoneLog.date).map { now.timeIntervalSince($0) <= projectQuietAfter } ?? false
        }
        return (summaries.filter(isMoving), summaries.filter { !isMoving($0) })
    }

    // MARK: Pieces

    private static func task(in hit: TaskSearchHit, calendar: Calendar) -> String {
        var line = "- [ ] \(hit.text) · \(link(hit.projectFolder))"
        if let due = hit.due { line += " · due \(shortDay(String(due.prefix(10)), calendar: calendar))" }
        return line
    }

    static func link(_ folder: String) -> String { "[[\(folder)]]" }

    private static func box(_ state: String) -> String {
        switch state {
        case "done": return "x"
        case "dropped": return "-"
        default: return " "
        }
    }

    private static func oneLine(_ text: String) -> String {
        text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// "Fri, Sep 18, 2026".
    static func longDay(_ iso: String, calendar: Calendar) -> String {
        format(iso, "EEE, MMM d, yyyy", calendar: calendar)
    }

    /// "Sep 18".
    static func shortDay(_ iso: String, calendar: Calendar) -> String {
        format(iso, "MMM d", calendar: calendar)
    }

    private static func format(_ iso: String, _ pattern: String, calendar: Calendar) -> String {
        guard let day = try? DoneRange.localDay(iso, calendar: calendar) else { return iso }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = pattern
        return formatter.string(from: day)
    }
}
