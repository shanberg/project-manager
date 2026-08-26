import Foundation
import PmLib

private func now() -> Double {
    CFAbsoluteTimeGetCurrent()
}

private func printEmptyListHints(path: String, pathLabel: String, noProjectsMessage: String, extraStderrLines: [String] = []) {
    var isDir: ObjCBool = false
    if !FileManager.default.fileExists(atPath: path, isDirectory: &isDir) || !isDir.boolValue {
        stderr("\(pathLabel) does not exist or is not a directory: \(path)")
    } else if isPermissionDenied(path: path) {
        stderr("Permission denied: cannot read \(path)")
        stderr("Grant Full Disk Access to Terminal (or Cursor) in System Settings → Privacy & Security → Full Disk Access.")
    } else {
        stderr(noProjectsMessage)
        for line in extraStderrLines { stderr(line) }
    }
}

private func isPermissionDenied(path: String) -> Bool {
    let url = URL(fileURLWithPath: path)
    do {
        _ = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        return false
    } catch {
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain && ns.code == 1 { return true }
        if ns.domain == NSCocoaErrorDomain && ns.code == 257 { return true }
        return false
    }
}

func runList(scope: String) {
    let bench = ProcessInfo.processInfo.environment["PM_BENCHMARK"] != nil
    let tStart = now()

    do {
        let config: PmConfig
        let paths: ResolvedPaths

        if bench {
            var t0 = now()
            guard let c = try loadConfig() else { throw PmError.configNotFound }
            config = c
            stderr(String(format: "  loadConfig: %.2f ms", (now() - t0) * 1000))
            t0 = now()
            paths = try resolvePaths(config: config)
            stderr(String(format: "  resolvePaths: %.2f ms", (now() - t0) * 1000))
            t0 = now()
            try validatePathsExist(paths: paths)
            stderr(String(format: "  validatePathsExist: %.2f ms", (now() - t0) * 1000))
        } else {
            (config, paths) = try loadConfigAndPaths(skipPathValidation: true)
        }

        let domainCodes = Array(config.domains.keys)

        let t1 = now()
        let active = try getProjectFolders(basePath: paths.activePath, domainCodes: domainCodes)
        if bench { stderr(String(format: "getProjectFolders(active): %.2f ms (%d projects)", (now() - t1) * 1000, active.count)) }

        let t2 = now()
        let archive = try getFolders(basePath: paths.archivePath, scope: .archive, domainCodes: domainCodes)
        if bench { stderr(String(format: "getProjectFolders(archive): %.2f ms (%d projects)", (now() - t2) * 1000, archive.count)) }

        let t3 = now()
        let areas = try getAreaFolders(basePath: paths.areasPath)
        if bench { stderr(String(format: "getAreaFolders: %.2f ms (%d areas)", (now() - t3) * 1000, areas.count)) }

        if bench { stderr(String(format: "total (in runList): %.2f ms", (now() - tStart) * 1000)) }

        if scope == "active" || scope == "all" {
            if scope == "all" { print("Active:") }
            for name in active {
                print(scope == "all" ? " \(name)" : name)
            }
            if scope == "all" && active.isEmpty { print("  (none)") }
            if active.isEmpty && scope == "active" {
                printEmptyListHints(
                    path: paths.activePath,
                    pathLabel: "Active path",
                    noProjectsMessage: "(no active projects in: \(paths.activePath))",
                    extraStderrLines: [
                        "(project folders must match: <domain>-<number> <title>, e.g. W-1 My Project)",
                        "(if Raycast shows projects, run List Projects there once to sync paths to this config)"
                    ]
                )
            }
        }
        if scope == "areas" || scope == "all" {
            if scope == "all" { print("\nAreas:") }
            for name in areas {
                print(scope == "all" ? " \(name)" : name)
            }
            if scope == "all" && areas.isEmpty { print("  (none)") }
            if areas.isEmpty && scope == "areas" {
                printEmptyListHints(
                    path: paths.areasPath,
                    pathLabel: "Areas path",
                    noProjectsMessage: "(no areas in: \(paths.areasPath))",
                    extraStderrLines: ["(make one with: pm new --area 'Team 1:1s')"]
                )
            }
        }
        if scope == "archive" || scope == "all" {
            if scope == "all" { print("\nArchive:") }
            for name in archive {
                print(scope == "all" ? " \(name)" : name)
            }
            if scope == "archive" && archive.isEmpty { print("(none)") }
            if scope == "all" && archive.isEmpty { print("  (none)") }
            if archive.isEmpty && scope == "archive" {
                printEmptyListHints(
                    path: paths.archivePath,
                    pathLabel: "Archive path",
                    noProjectsMessage: "(no archived projects in: \(paths.archivePath))"
                )
            }
        }
    } catch { fail(error) }
}

func runNew(args: [String]) {
    // An area takes no domain, so `pm new --area <title>` has one argument where `pm new` has two.
    let makingArea = args.contains("--area")
    let rest = args.filter { $0 != "--area" }
    let needed = makingArea ? 1 : 2
    guard rest.count >= needed else {
        stderr(makingArea ? "Usage: pm new --area <title>" : "Usage: pm new <domain> <title>")
        stderr(makingArea ? "Example: pm new --area 'Team 1:1s'" : "Example: pm new W 'Website Refresh'")
        exit(1)
    }
    let domainCode = makingArea ? nil : rest[0].uppercased()
    let title = rest[makingArea ? 0 : 1].trimmingCharacters(in: .whitespaces)
    do {
        let (config, paths) = try loadConfigAndPaths()
        guard !title.isEmpty else {
            stderr(makingArea ? "A title is required." : "Domain and title are required.")
            if !makingArea { stderr("Domains: \(config.domains.keys.sorted().joined(separator: ", "))") }
            exit(1)
        }
        if let domainCode {
            guard config.domains[domainCode] != nil else {
                stderr("Unknown domain: \(domainCode)")
                stderr("Known domains: \(config.domains.keys.sorted().joined(separator: ", "))")
                exit(1)
            }
        }
        let projectPath = try createProject(config: config, paths: paths,
                                            kind: makingArea ? .area : .project,
                                            domainCode: domainCode, title: title)
        print("Created: \(projectPath)")
    } catch { fail(error) }
}

private func emitMatchErrorAndExit(folders: [String], query: String, notFoundMessage: String, listLabel: String) -> Never {
    let trimmed = query.trimmingCharacters(in: .whitespaces)
    let prefixMatches = folders.filter { $0.hasPrefix(trimmed) }
    if prefixMatches.count > 1 {
        stderr("Ambiguous match. Multiple projects start with: \(query)")
        prefixMatches.forEach { stderr(" - \($0)") }
    } else {
        stderr(notFoundMessage)
        if !folders.isEmpty { stderr("\(listLabel): \(folders.joined(separator: ", "))") }
    }
    exit(1)
}

private func runMoveProject(fromActive: Bool, name: String) {
    do {
        let (config, paths) = try loadConfigAndPaths()
        let codes = Array(config.domains.keys)
        // Putting something away can start from either of the two roots things are held in; bringing
        // one back always starts in the archive, which holds both kinds.
        let sources: [ProjectScope] = fromActive ? [.active, .areas] : [.archive]
        let (notFoundMsg, listLabel, doneVerb) = fromActive
            ? ("Nothing found matching: \(name)", "Active projects and areas", "Archived")
            : ("Nothing archived matching: \(name)", "Archived", "Unarchived")
        // Matching stays here rather than in the move itself: the CLI is the caller that gets a typed
        // query, and it can name the candidates when one is ambiguous.
        let candidates: [(scope: ProjectScope, folders: [String])] = try sources.map {
            ($0, try getFolders(basePath: $0.path(in: paths), scope: $0, domainCodes: codes))
        }
        let folders = candidates.flatMap(\.folders)
        guard let matched = matchProject(folders: folders, query: name),
              let source = candidates.first(where: { $0.folders.contains(matched) })?.scope else {
            emitMatchErrorAndExit(folders: folders, query: name, notFoundMessage: notFoundMsg, listLabel: listLabel)
        }
        // Everything archives into the one archive; what comes back out goes wherever its kind lives,
        // read off the folder's own name.
        let destination: ProjectScope = fromActive ? .archive : ProjectKind.of(folderName: matched).homeScope
        try moveProject(named: matched, from: source, to: destination, paths: paths)
        print("\(doneVerb): \(matched)")
    } catch { fail(error) }
}

func runArchive(args: [String]) {
    guard let name = args.first, !name.isEmpty else {
        stderr("Usage: pm archive <name>")
        exit(1)
    }
    runMoveProject(fromActive: true, name: name)
}

func runUnarchive(args: [String]) {
    guard let name = args.first, !name.isEmpty else {
        stderr("Usage: pm unarchive <name>")
        exit(1)
    }
    runMoveProject(fromActive: false, name: name)
}

/// `pm adopt` — with a name, take that folder on as an area; without one, list what could be.
///
/// The bare form isn't a usage error on purpose. "Which of my folders could become areas" is the
/// question somebody actually has when they type this, and answering it is more use than a usage line.
func runAdopt(args: [String]) {
    do {
        let (config, paths) = try loadConfigAndPaths()
        let name = args.first(where: { !$0.hasPrefix("-") })?.trimmingCharacters(in: .whitespaces)

        guard let name, !name.isEmpty else {
            let candidates = try getAdoptableFolders(basePath: paths.areasPath)
            guard !candidates.isEmpty else {
                print("Nothing to take on in \(paths.areasPath).")
                print("(a folder there with no notes in it is one PM could adopt)")
                return
            }
            print("Folders in \(paths.areasPath) that could become areas:")
            candidates.forEach { print(" \($0)") }
            print("")
            print("Take one on with: pm adopt \"\(candidates[0])\"")
            return
        }

        let notesPath = try adoptArea(config: config, paths: paths, folderName: name)
        print("Adopted: \(name)")
        print("Notes: \(notesPath)")
    } catch { fail(error) }
}
