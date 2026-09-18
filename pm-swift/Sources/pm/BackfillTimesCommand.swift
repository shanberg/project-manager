import Foundation
import PmLib

/// `pm backfill-times [--write] [<project>]` — give every sitting whose heading has no start time a
/// best guess, across every project (or one), through `session.backfillTimes`. See `SessionTimes`.
///
/// **A preview unless `--write` is given.** It is a migration over every notes file you have, so the
/// first run says what it would do and the second does it. Each project written is one journal entry,
/// so `pm api call journal.undo` takes any one of them back.
func runBackfillTimes(args: [String]) {
    var write = false
    var only: String?
    for argument in args {
        switch argument {
        case "--write": write = true
        case "--dry-run": write = false
        case let name where !name.hasPrefix("-") && only == nil: only = name
        default:
            stderr("Usage: pm backfill-times [--write] [<project>]")
            exit(1)
        }
    }

    let projects: [String]
    do {
        projects = try only.map { [try resolveProjectPath(nameOrPrefix: $0)] } ?? allProjectPaths()
    } catch {
        stderr(String(describing: error))
        exit(1)
    }

    // Read once, before the first write: see `SessionTimes.journalSnapshot`.
    SessionTimes.journalSnapshot = ApiJournal.entries(limit: 0)
    defer { SessionTimes.journalSnapshot = nil }

    var total = 0
    var fromRecord = 0
    var touched = 0
    var failed = 0
    for projectPath in projects {
        let folder = (projectPath as NSString).lastPathComponent
        // Never make a notes file to date: `resolveNotesHandle` creates one from the template when a
        // project has none, which is right for a write and wrong for a migration.
        guard ((try? resolveNotesPath(projectPath: projectPath)) ?? nil) != nil else { continue }
        // The action is addressed by name, and a name in two roots resolves to the first. Skip rather
        // than date the wrong one.
        guard (try? resolveProjectPath(nameOrPrefix: folder)) == projectPath else {
            print("\(projectTitle(fromFolderName: folder)): skipped — another project has the same name")
            continue
        }
        var input = ApiInput()
        input.project = folder
        do {
            let result = try performApi("session.backfillTimes", input,
                                        options: ApiOptions(dryRun: !write, source: "cli"))
            let guesses = try decodeGuesses(result.data)
            guard !guesses.isEmpty else { continue }
            touched += 1
            total += guesses.count
            fromRecord += guesses.filter { $0.basis != .placeholder }.count
            print(projectTitle(fromFolderName: folder))
            for guess in guesses { print("  " + describe(guess)) }
        } catch {
            failed += 1
            stderr("\(projectTitle(fromFolderName: folder)): \(ApiError.from(error).message)")
        }
    }

    if total == 0 {
        print(failed == 0 ? "Every session already has a time." : "Nothing dated.")
    } else {
        let sessions = total == 1 ? "1 session" : "\(total) sessions"
        let inProjects = touched == 1 ? "1 project" : "\(touched) projects"
        let split = "\(fromRecord) from the record, \(total - fromRecord) placeholder"
        print("")
        print(write ? "Gave \(sessions) in \(inProjects) a time (\(split))."
                    : "Would give \(sessions) in \(inProjects) a time (\(split)). Run with --write to write them.")
    }
    if failed > 0 { exit(1) }
}

/// Every project folder with a notes file PM can find — active, areas and archive, each once.
private func allProjectPaths() throws -> [String] {
    let (config, paths) = try loadConfigAndPaths(skipPathValidation: true)
    let codes = Array(config.domains.keys)
    var seen = Set<String>()
    var out: [String] = []
    for scope in ProjectScope.allCases {
        let base = scope.path(in: paths)
        for folder in (try? getFolders(basePath: base, scope: scope, domainCodes: codes)) ?? [] {
            let path = (base as NSString).appendingPathComponent(folder)
            if seen.insert(path).inserted { out.append(path) }
        }
    }
    return out
}

private func decodeGuesses(_ data: JSONValue?) throws -> [SessionTimes.Guess] {
    guard let data else { return [] }
    return try JSONDecoder().decode([SessionTimes.Guess].self, from: JSONEncoder().encode(data))
}

/// `Fri, Aug 22, 2026 · 9:00 AM · Kickoff   placeholder` — the heading it will have, and why.
private func describe(_ guess: SessionTimes.Guess) -> String {
    let heading = (try? sessionHeadingDate(iso: guess.session)) ?? guess.session
    let name = guess.name.isEmpty ? "" : " · \(guess.name)"
    let why: String
    switch guess.basis {
    case .placeholder: why = "placeholder"
    case .journal: why = "first write that day"
    case .done: why = "first completion that day"
    case .pick: why = "first pick-up that day"
    }
    return "\(heading) · \(guess.time)\(name)   \(why)"
}
