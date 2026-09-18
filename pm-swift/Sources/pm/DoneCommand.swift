import Foundation
import PmLib

/// `pm done [today|week] [--since YYYY-MM-DD] [--until YYYY-MM-DD] [--dropped]` — what got done,
/// grouped by project, for reading at a standup or a weekly review. `--dropped` lists what was let go of
/// in the same span too, marked ✗ so it can't be read as done. `pm api call task.done` is the same answer as
/// JSON; this is the one a person reads.
func runDone(args: [String]) {
    var period: String?
    var since: String?
    var until: String?
    var includeDropped = false
    var index = 0
    while index < args.count {
        switch args[index] {
        case "today", "week": period = args[index]
        case "--since" where index + 1 < args.count: index += 1; since = args[index]
        case "--until" where index + 1 < args.count: index += 1; until = args[index]
        case "--dropped": includeDropped = true
        default:
            stderr("Usage: pm done [today|week] [--since YYYY-MM-DD] [--until YYYY-MM-DD] [--dropped]")
            exit(1)
        }
        index += 1
    }
    do {
        let items = try doneTasks(in: try DoneRange.resolve(period: period, since: since, until: until),
                                  includeDropped: includeDropped)
        if items.isEmpty {
            print("Nothing done.")
            return
        }
        // Projects in the order their latest work was done, tasks oldest first within each — a project
        // reads as the story of that stretch of work.
        var order: [String] = []
        var byProject: [String: [DoneItem]] = [:]
        for item in items {
            if byProject[item.projectFolder] == nil { order.append(item.projectFolder) }
            byProject[item.projectFolder, default: []].append(item)
        }
        for (position, folder) in order.enumerated() {
            let tasks = byProject[folder] ?? []
            if position > 0 { print("") }
            print(tasks.first?.projectName ?? folder)
            for task in tasks.reversed() { print("  \(task.dropped ? "✗" : "✓") \(task.text)") }
        }
    } catch {
        stderr(String(describing: error))
        exit(1)
    }
}
