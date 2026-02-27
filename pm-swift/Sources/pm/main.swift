import Foundation
import PmLib

// MARK: - dispatch

private func dispatch(cmd: String, args: [String]) {
    switch cmd {
    case "new":
        runNew(args: args)
    case "list":
        var scope = "active"
        if args.contains("--all") { scope = "all" }
        else if args.contains("--archive") || args.contains("-a") { scope = "archive" }
        runList(scope: scope)
    case "archive":
        runArchive(args: args)
    case "unarchive":
        runUnarchive(args: args)
    case "config":
        runConfig(args: args)
    case "notes":
        runNotes(args: args)
    default:
        stderr("Unknown command: \(cmd)")
        exit(1)
    }
}

// MARK: - main

let argv = CommandLine.arguments
guard argv.count >= 2 else {
    stderr("Usage: pm <command> [options] [args]")
    exit(1)
}
let cmd = argv[1]
if cmd == "--version" || cmd == "-V" {
    print(pmVersion)
    exit(0)
}
dispatch(cmd: cmd, args: Array(argv.dropFirst(2)))
