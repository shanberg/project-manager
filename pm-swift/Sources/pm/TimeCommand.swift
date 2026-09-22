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
            print(line.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression))
        }
    } catch {
        stderr(String(describing: error))
        exit(1)
    }
}
