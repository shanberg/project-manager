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
        let archive = try getProjectFolders(basePath: paths.archivePath, domainCodes: domainCodes)
        if bench { stderr(String(format: "getProjectFolders(archive): %.2f ms (%d projects)", (now() - t2) * 1000, archive.count)) }

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
    guard args.count >= 2 else {
        stderr("Usage: pm new <domain> <title>")
        stderr("Example: pm new W 'Website Refresh'")
        exit(1)
    }
    let domainCode = args[0].uppercased()
    let title = args[1].trimmingCharacters(in: .whitespaces)
    do {
        let (config, paths) = try loadConfigAndPaths()
        if domainCode.isEmpty || title.isEmpty {
            stderr("Domain and title are required.")
            stderr("Domains: \(config.domains.keys.sorted().joined(separator: ", "))")
            exit(1)
        }
        guard config.domains[domainCode] != nil else {
            stderr("Unknown domain: \(domainCode)")
            stderr("Known domains: \(config.domains.keys.sorted().joined(separator: ", "))")
            exit(1)
        }
        let projectPath = try createProject(config: config, paths: paths, domainCode: domainCode, title: title)
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
        let domainCodes = Array(config.domains.keys)
        let (sourcePath, destPath, notFoundMsg, listLabel, doneVerb) = fromActive
            ? (paths.activePath, paths.archivePath, "No project found matching: \(name)", "Active projects", "Archived")
            : (paths.archivePath, paths.activePath, "No archived project found matching: \(name)", "Archived projects", "Unarchived")
        let folders = try getProjectFolders(basePath: sourcePath, domainCodes: domainCodes)
        guard let matched = matchProject(folders: folders, query: name) else {
            emitMatchErrorAndExit(folders: folders, query: name, notFoundMessage: notFoundMsg, listLabel: listLabel)
        }
        let src = (sourcePath as NSString).appendingPathComponent(matched)
        let dest = (destPath as NSString).appendingPathComponent(matched)
        try FileManager.default.moveItem(atPath: src, toPath: dest)
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
