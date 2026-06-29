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
