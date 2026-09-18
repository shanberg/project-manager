import Foundation
import PmLib

/// `pm day [today|yesterday|week|YYYY-MM-DD] [--since YYYY-MM-DD] [--until YYYY-MM-DD] [--project NAME]…`
/// — the sittings of a day across projects, in the order the day went, with their prose kept in. `pm done`
/// is the checklist; this is the journal. `pm api call session.list` is the same answer as JSON.
func runDay(args: [String]) {
    let usage = "Usage: pm day [today|yesterday|week|YYYY-MM-DD] [--since YYYY-MM-DD] [--until YYYY-MM-DD] [--project NAME]…"
    var period: String?
    var since: String?
    var until: String?
    var projects: [String] = []
    var index = 0
    while index < args.count {
        let arg = args[index]
        switch arg {
        case "today", "yesterday", "week": period = arg
        case "--since" where index + 1 < args.count: index += 1; since = args[index]
        case "--until" where index + 1 < args.count: index += 1; until = args[index]
        case "--project" where index + 1 < args.count: index += 1; projects.append(args[index])
        case _ where arg.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil:
            since = arg
            until = arg
        default:
            stderr(usage)
            exit(1)
        }
        index += 1
    }
    do {
        let range = try DoneRange.resolve(period: period, since: since, until: until)
        let list = try sessionList(in: range, projects: projects.isEmpty ? nil : projects)
        print(dayText(list, range: range), terminator: "")
    } catch {
        stderr(String(describing: error))
        exit(1)
    }
}

/// The answer as a person reads it: a caption per day, then each sitting at the time it began, its prose
/// in full and its tasks, then what was finished in no sitting.
func dayText(_ list: SittingList, range: DoneRange, now: Date = Date(),
             calendar: Calendar = .current) -> String {
    let dayFormat = DateFormatter()
    dayFormat.dateFormat = "EEE, MMM d"
    let clock = DateFormatter()
    clock.locale = Locale(identifier: "en_US_POSIX")
    clock.dateFormat = "h:mm a"
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime]

    func localDay(_ isoDate: String) -> Date? {
        let parts = isoDate.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
    func shortDay(_ isoDate: String?) -> String {
        guard let isoDate, let day = localDay(isoDate) else { return "" }
        let short = DateFormatter()
        short.dateFormat = "MMM d"
        return short.string(from: day)
    }
    func caption(_ day: Date) -> String {
        let name = dayFormat.string(from: day)
        if calendar.isDate(day, inSameDayAs: now) { return "Today · \(name)" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(day, inSameDayAs: yesterday) { return "Yesterday · \(name)" }
        return name
    }
    func mark(_ state: String) -> String {
        switch state {
        case "done": return "✓"
        case "dropped": return "✗"
        default: return "○"
        }
    }

    // Days newest first: the sittings' own, and the days of anything finished elsewhere.
    var days: [Date] = list.sittings.compactMap { localDay($0.session) }
    days += list.elsewhere.compactMap { iso.date(from: $0.at).map { calendar.startOfDay(for: $0) } }
    days = Array(Set(days)).sorted(by: >)
    guard !days.isEmpty else { return "Nothing written \(range.end.timeIntervalSince(range.start) > 86_400 * 1.5 ? "in that span" : "that day").\n" }

    let gutter = String(repeating: " ", count: 10)
    var out: [String] = []
    for day in days {
        let sittings = list.sittings.filter { localDay($0.session).map { calendar.isDate($0, inSameDayAs: day) } == true }
        let elsewhere = list.elsewhere.filter {
            iso.date(from: $0.at).map { calendar.isDate($0, inSameDayAs: day) } == true
        }
        let done = sittings.reduce(0) { $0 + $1.finished.count } + elsewhere.filter { !$0.dropped }.count
        let dropped = sittings.reduce(0) { $0 + $1.dropped.count } + elsewhere.filter(\.dropped).count
        var counts = ["\(sittings.count) sitting\(sittings.count == 1 ? "" : "s")"]
        if done > 0 { counts.append("\(done) done") }
        if dropped > 0 { counts.append("\(dropped) dropped") }
        if !out.isEmpty { out.append("") }
        out.append("\(caption(day)) — \(counts.joined(separator: " · "))")

        for sitting in sittings {
            out.append("")
            let time = sitting.startTime ?? "Earlier"
            var title = sitting.projectName
            if !sitting.name.isEmpty { title += " · \(sitting.name)" }
            if sitting.isCurrent { title += "  (now)" }
            out.append(time.padding(toLength: gutter.count, withPad: " ", startingAt: 0) + title)
            if !sitting.prose.isEmpty {
                out += sitting.prose.components(separatedBy: "\n").map { $0.isEmpty ? "" : gutter + $0 }
            }

            // Written, then picked up, then anything finished or dropped here that was written elsewhere
            // and isn't already among them. Each line once.
            var shown = Set<String>()
            func key(_ task: SittingTask) -> String? {
                task.ref.map { "\($0.session ?? ""):\($0.sessionOrdinal ?? 0):\($0.line)" }
            }
            var rows: [String] = []
            func add(_ task: SittingTask, depth: Int? = nil, note: String? = nil) {
                if let key = key(task) { guard shown.insert(key).inserted else { return } }
                let indent = String(repeating: "  ", count: depth ?? task.depth)
                rows.append(gutter + indent + "\(mark(task.state)) \(task.text)" + (note.map { "  — \($0)" } ?? ""))
            }
            sitting.written.forEach { add($0) }
            for task in sitting.picked {
                add(task, note: task.depth == 0 ? "picked up from \(shortDay(task.from))" : nil)
            }
            for task in sitting.finished + sitting.dropped {
                let from = task.ref?.session.map(shortDay)
                add(task, depth: 0, note: from.map { "from \($0)" })
            }
            if !rows.isEmpty {
                if !sitting.prose.isEmpty { out.append("") }
                out += rows
            }
        }

        if !elsewhere.isEmpty {
            out.append("")
            out.append("Also finished")
            for item in elsewhere {
                let at = iso.date(from: item.at).map(clock.string(from:)) ?? ""
                out.append("  \(item.dropped ? "✗" : "✓") \(item.text) · \(item.projectName)  \(at)")
            }
        }
    }
    return out.joined(separator: "\n") + "\n"
}
