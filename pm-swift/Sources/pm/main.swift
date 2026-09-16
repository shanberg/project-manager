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
        else if args.contains("--areas") { scope = "areas" }
        runList(scope: scope)
    case "adopt":
        runAdopt(args: args)
    case "archive":
        runArchive(args: args)
    case "unarchive":
        runUnarchive(args: args)
    case "rename":
        runRename(args: args)
    case "part-of":
        runPartOf(args: args)
    case "config":
        runConfig(args: args)
    case "notes":
        runNotes(args: args)
    case "done":
        runDone(args: args)
    case "api":
        runApi(args: args)
    case "mcp":
        runMcp(args: args)
    case "due-table":
        // Undocumented and deliberately not a contract action: this exists so the Raycast extension's
        // copy of the due-label rules can be checked against PmLib's, and nothing in the product calls
        // it. See `RelativeDue.conformanceTable`.
        runDueTable()
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
