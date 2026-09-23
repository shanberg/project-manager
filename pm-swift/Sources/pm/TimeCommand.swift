import Foundation
import PmLib

/// `pm time [today|yesterday|week] [--since YYYY-MM-DD] [--until YYYY-MM-DD] [--all]`
///
/// Where the time went, longest first. See docs/time-tracking.md D5.
///
/// Projects with no time against them are left out unless `--all` asks for them: they are worth
/// knowing about — work happened somewhere PM was never told you were — but they are not the answer to
/// the question, and a report that led with them would bury the one that is.
func runTime(args: [String]) {
    switch args.first {
    case "aways": return runTimeAways(args: Array(args.dropFirst()))
    case "count": return runTimeCount(args: Array(args.dropFirst()))
    default: break
    }
    var period: String?
    var since: String?
    var until: String?
    var showUntracked = false
    var index = 0
    while index < args.count {
        switch args[index] {
        case "today", "yesterday", "week": period = args[index]
        case "--since" where index + 1 < args.count: index += 1; since = args[index]
        case "--until" where index + 1 < args.count: index += 1; until = args[index]
        case "--all": showUntracked = true
        default:
            stderr("Usage: pm time [today|yesterday|week] [--since YYYY-MM-DD] [--until YYYY-MM-DD] [--all]")
            exit(1)
        }
        index += 1
    }
    do {
        let report = try timeSpent(in: try DoneRange.resolve(period: period, since: since, until: until))
        let listed = showUntracked ? report.projects : report.projects.filter { $0.seconds > 0 }
        guard !listed.isEmpty else {
            print("No time on record.")
            return
        }
        print(durationLabel(report.seconds))
        print("")
        // The name column is as wide as the widest name, so the durations line up without the table
        // ever being wider than it has to be.
        let width = listed.map(\.projectName.count).max() ?? 0
        for item in listed {
            let name = item.projectName.padding(toLength: max(width, item.projectName.count),
                                                withPad: " ", startingAt: 0)
            let time = item.seconds > 0 ? durationLabel(item.seconds) : "—"
            var line = "  \(name)  \(time.padding(toLength: max(6, time.count), withPad: " ", startingAt: 0))"
            let came = ViewMarkdown.changes(item)
            if !came.isEmpty { line += "  \(came)" }
            // A total that is partly guessed says so on its own line rather than in a legend at the
            // bottom, which nobody reads next to the number it qualifies (D4).
            if item.inferred { line += "  (inferred)" }
            if item.counted { line += "  (counted)" }
            print(line.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression))
        }
    } catch {
        stderr(String(describing: error))
        exit(1)
    }
}

/// `pm time aways [today|yesterday|week] [--since YYYY-MM-DD] [--until YYYY-MM-DD]`
///
/// The stretches nobody touched the machine that are still open questions (docs/away-time.md),
/// oldest first, each with what it interrupted. The times are the ones `pm time count` takes.
private func runTimeAways(args: [String]) {
    var input = ApiInput()
    var index = 0
    while index < args.count {
        switch args[index] {
        case "today", "yesterday", "week": input.period = args[index]
        case "--since" where index + 1 < args.count: index += 1; input.since = args[index]
        case "--until" where index + 1 < args.count: index += 1; input.until = args[index]
        default:
            stderr("Usage: pm time aways [today|yesterday|week] [--since YYYY-MM-DD] [--until YYYY-MM-DD]")
            exit(1)
        }
        index += 1
    }
    do {
        let range = try DoneRange.resolve(period: input.period, since: input.since, until: input.until)
        let aways = try attentionAways(in: range)
        guard !aways.isEmpty else {
            print("No aways.")
            return
        }
        let total = aways.reduce(0) { $0 + $1.seconds }
        print("\(aways.count) away\(aways.count == 1 ? "" : "s"), \(durationLabel(total))")
        print("")
        // Clock times alone for today, since that's what `pm time count` takes without `--day`; the
        // day as well for any other range, so an away is never mistaken for today's.
        let clock = DateFormatter()
        clock.dateFormat = Calendar.current.isDateInToday(range.start)
            && range.end.timeIntervalSince(range.start) <= 86_400 ? "HH:mm" : "EEE d HH:mm"
        let clockOnly = DateFormatter()
        clockOnly.dateFormat = "HH:mm"
        for away in aways {
            guard let from = away.fromDate, let to = away.toDate else { continue }
            let sameDay = Calendar.current.isDate(from, inSameDayAs: to)
            let when = "\(clock.string(from: from))–\(sameDay ? clockOnly.string(from: to) : clock.string(from: to))"
            let length = durationLabel(away.seconds).padding(toLength: 7, withPad: " ", startingAt: 0)
            var line = "  \(when)  \(length)  \(away.project)"
            if away.during == "call" { line += "  (on a call)" }
            print(line)
        }
    } catch {
        stderr(String(describing: error))
        exit(1)
    }
}

/// `pm time count <from> <to> (<project> | --not-work) [--day today|yesterday|YYYY-MM-DD] [--dry-run]`
///
/// Answer for a stretch: it was this project's, or it wasn't work. `from` and `to` are clock times on
/// `--day` (today by default) — `11:07`, `2:05pm` — or ISO 8601 with a zone.
private func runTimeCount(args: [String]) {
    let usage = "Usage: pm time count <from> <to> (<project> | --not-work) [--day today|yesterday|YYYY-MM-DD] [--dry-run]"
    var dryRun = false
    var notWork = false
    var day = Date()
    var words: [String] = []
    var index = 0
    while index < args.count {
        switch args[index] {
        case "--dry-run": dryRun = true
        case "--not-work": notWork = true
        case "--day" where index + 1 < args.count:
            index += 1
            guard let range = try? DoneRange.resolve(period: args[index] == "yesterday" ? "yesterday" : nil,
                                                     since: ["today", "yesterday"].contains(args[index]) ? nil : args[index],
                                                     until: nil) else {
                stderr("Couldn't read \(args[index]) as a day. Give today, yesterday or YYYY-MM-DD.")
                exit(1)
            }
            day = range.start
        default: words.append(args[index])
        }
        index += 1
    }
    guard words.count >= 2, notWork == (words.count == 2) else {
        stderr(usage)
        exit(1)
    }
    guard let from = parseMoment(words[0], now: day), let to = parseMoment(words[1], now: day) else {
        stderr("Couldn't read \(parseMoment(words[0], now: day) == nil ? words[0] : words[1]) as a time. "
               + "Give a clock time today, like 11:07 or 2:05pm, or ISO 8601 with a zone.")
        exit(1)
    }
    var input = ApiInput()
    input.from = DoneLog.timestamp(from)
    input.to = DoneLog.timestamp(to)
    if notWork {
        input.notWork = true
    } else {
        input.project = words.dropFirst(2).joined(separator: " ")
    }
    do {
        let result = try performApi("time.count", input, options: ApiOptions(dryRun: dryRun, source: "cli"))
        print(result.summary)
    } catch {
        stderr(ApiError.from(error).message)
        exit(1)
    }
}
