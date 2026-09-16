import Foundation
import PmLib

func runRename(args: [String]) {
    guard args.count >= 2 else {
        stderr("Usage: pm rename <project> <newTitle>")
        stderr("Example: pm rename W-1 'Website Refresh'")
        stderr("On success, prints the new folder basename (one line, stdout).")
        exit(1)
    }
    let projectQuery = args[0]
    let newTitle = args[1]
    do {
        let basename = try renameProjectTitle(nameOrPrefix: projectQuery, newTitle: newTitle)
        print(basename)
    } catch {
        fail(error)
    }
}

/// `pm part-of <project> <master>` puts a project under a master; `--clear` takes it out; with only a
/// project, prints its master and its members. Through the contract, so the one-level rule and the
/// journal are the same ones every other surface gets. See docs/combining-projects.md.
func runPartOf(args: [String]) {
    guard let project = args.first else {
        stderr("Usage: pm part-of <project> [<master> | --clear]")
        stderr("Example: pm part-of W-3 W-1")
        exit(1)
    }
    let rest = Array(args.dropFirst())
    var input = ApiInput()
    input.project = project
    let action: String
    if rest.isEmpty {
        action = "project.get"
    } else {
        action = "project.setPartOf"
        if rest.contains("--clear") { input.clearPartOf = true } else { input.partOf = rest[0] }
    }
    let result: ApiResult
    do {
        result = try performApi(action, input)
    } catch let error as ApiError {
        stderr(error.message)
        exit(1)
    } catch {
        fail(error)
    }
    guard action == "project.get", case .object(let data)? = result.data else {
        print(result.summary)
        return
    }
    if case .string(let master)? = data["partOf"] { print("Part of \(master)") }
    if case .array(let members)? = data["members"], !members.isEmpty {
        print("Projects:")
        for case .string(let member) in members { print("  \(member)") }
    }
    if data["partOf"] == JSONValue.null, case .array(let members)? = data["members"], members.isEmpty {
        print("Not part of anything, and nothing is part of it.")
    }
}
