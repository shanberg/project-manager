import Foundation
import AppKit
import PmLib

func stderr(_ msg: String) {
    fputs(msg + "\n", stderr)
}

/// High-resolution elapsed time in seconds (for benchmarking).
private func now() -> Double {
    CFAbsoluteTimeGetCurrent()
}

func fail(_ err: Error) -> Never {
    if let pmErr = err as? PmError {
        stderr(pmErr.description)
    } else {
        stderr(err.localizedDescription)
    }
    exit(1)
}

/// True if the path exists but listing its contents fails with a permission error (e.g. macOS Full Disk Access).
private func isPermissionDenied(path: String) -> Bool {
    let url = URL(fileURLWithPath: path)
    do {
        _ = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        return false
    } catch {
        let ns = error as NSError
        // NSPOSIXErrorDomain, code 1 = EPERM (Operation not permitted)
        if ns.domain == NSPOSIXErrorDomain && ns.code == 1 { return true }
        if ns.domain == NSCocoaErrorDomain && ns.code == 257 { return true } // NSFileReadNoPermission
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
            if bench { stderr(String(format: "  loadConfig: %.2f ms", (now() - t0) * 1000)) }
            t0 = now()
            paths = try resolvePaths(config: config)
            if bench { stderr(String(format: "  resolvePaths: %.2f ms", (now() - t0) * 1000)) }
            t0 = now()
            try validatePathsExist(paths: paths)
            if bench { stderr(String(format: "  validatePathsExist: %.2f ms", (now() - t0) * 1000)) }
        } else {
            (config, paths) = try loadConfigAndPaths(skipPathValidation: true)
        }

        let domainCodes = Array(config.domains.keys)

        let t1 = now()
        let active = getProjectFolders(basePath: paths.activePath, domainCodes: domainCodes)
        if bench { stderr(String(format: "getProjectFolders(active): %.2f ms (%d projects)", (now() - t1) * 1000, active.count)) }

        let t2 = now()
        let archive = getProjectFolders(basePath: paths.archivePath, domainCodes: domainCodes)
        if bench { stderr(String(format: "getProjectFolders(archive): %.2f ms (%d projects)", (now() - t2) * 1000, archive.count)) }

        if bench { stderr(String(format: "total (in runList): %.2f ms", (now() - tStart) * 1000)) }

        if scope == "active" || scope == "all" {
            if scope == "all" { print("Active:") }
            for name in active {
                print(scope == "all" ? " \(name)" : name)
            }
            if scope == "all" && active.isEmpty { print("  (none)") }
            if active.isEmpty && (scope == "active" || scope == "all") {
                var isDir: ObjCBool = false
                if !FileManager.default.fileExists(atPath: paths.activePath, isDirectory: &isDir) || !isDir.boolValue {
                    stderr("Active path does not exist or is not a directory: \(paths.activePath)")
                } else if isPermissionDenied(path: paths.activePath) {
                    stderr("Permission denied: cannot read \(paths.activePath)")
                    stderr("Grant Full Disk Access to Terminal (or Cursor) in System Settings → Privacy & Security → Full Disk Access.")
                } else {
                    stderr("(no active projects in: \(paths.activePath))")
                    stderr("(project folders must match: <domain>-<number> <title>, e.g. W-1 My Project)")
                    stderr("(if Raycast shows projects, run List Projects there once to sync paths to this config)")
                }
            }
        }
        if scope == "archive" || scope == "all" {
            if scope == "all" { print("\nArchive:") }
            for name in archive {
                print(scope == "all" ? " \(name)" : name)
            }
            if scope == "archive" && archive.isEmpty { print("(none)") }
            if scope == "all" && archive.isEmpty { print("  (none)") }
            if archive.isEmpty && (scope == "archive" || scope == "all") {
                var isDir: ObjCBool = false
                if !FileManager.default.fileExists(atPath: paths.archivePath, isDirectory: &isDir) || !isDir.boolValue {
                    stderr("Archive path does not exist or is not a directory: \(paths.archivePath)")
                } else if isPermissionDenied(path: paths.archivePath) {
                    stderr("Permission denied: cannot read \(paths.archivePath)")
                    stderr("Grant Full Disk Access to Terminal (or Cursor) in System Settings → Privacy & Security → Full Disk Access.")
                } else {
                    stderr("(no archived projects in: \(paths.archivePath))")
                }
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
            stderr("Usage: pm new <domain> <title>")
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

func runArchive(args: [String]) {
    guard let name = args.first, !name.isEmpty else {
        stderr("Usage: pm archive <name>")
        exit(1)
    }
    do {
        let (config, paths) = try loadConfigAndPaths()
        let domainCodes = Array(config.domains.keys)
        let folders = getProjectFolders(basePath: paths.activePath, domainCodes: domainCodes)
        guard let matched = matchProject(folders: folders, query: name) else {
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            let prefixMatches = folders.filter { $0.hasPrefix(trimmed) }
            if prefixMatches.count > 1 {
                stderr("Ambiguous match. Multiple projects start with: \(name)")
                prefixMatches.forEach { stderr(" - \($0)") }
            } else {
                stderr("No project found matching: \(name)")
                if !folders.isEmpty { stderr("Active projects: \(folders.joined(separator: ", "))") }
            }
            exit(1)
        }
        let src = (paths.activePath as NSString).appendingPathComponent(matched)
        let dest = (paths.archivePath as NSString).appendingPathComponent(matched)
        try FileManager.default.moveItem(atPath: src, toPath: dest)
        print("Archived: \(matched)")
    } catch { fail(error) }
}

func runUnarchive(args: [String]) {
    guard let name = args.first, !name.isEmpty else {
        stderr("Usage: pm unarchive <name>")
        exit(1)
    }
    do {
        let (config, paths) = try loadConfigAndPaths()
        let domainCodes = Array(config.domains.keys)
        let folders = getProjectFolders(basePath: paths.archivePath, domainCodes: domainCodes)
        guard let matched = matchProject(folders: folders, query: name) else {
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            let prefixMatches = folders.filter { $0.hasPrefix(trimmed) }
            if prefixMatches.count > 1 {
                stderr("Ambiguous match. Multiple projects start with: \(name)")
                prefixMatches.forEach { stderr(" - \($0)") }
            } else {
                stderr("No archived project found matching: \(name)")
                if !folders.isEmpty { stderr("Archived projects: \(folders.joined(separator: ", "))") }
            }
            exit(1)
        }
        let src = (paths.archivePath as NSString).appendingPathComponent(matched)
        let dest = (paths.activePath as NSString).appendingPathComponent(matched)
        try FileManager.default.moveItem(atPath: src, toPath: dest)
        print("Unarchived: \(matched)")
    } catch { fail(error) }
}

func runConfigInit() {
    do {
        let existing = try loadConfig()
        if existing != nil {
            print("Config already exists at: \(getConfigPath())")
            print("Re-initialize? (y/N): ", terminator: "")
            guard let line = readLine(), line.lowercased() == "y" else { return }
        }
        print("Enter the path for active projects:")
        print("Active path: ", terminator: "")
        guard let activePath = readLine()?.trimmingCharacters(in: .whitespaces), !activePath.isEmpty else {
            stderr("No active path provided.")
            exit(1)
        }
        print("Enter the path for archived projects:")
        print("Archive path: ", terminator: "")
        guard let archivePath = readLine()?.trimmingCharacters(in: .whitespaces), !archivePath.isEmpty else {
            stderr("No archive path provided.")
            exit(1)
        }
        let config = createDefaultConfig(activePath: (activePath as NSString).expandingTildeInPath, archivePath: (archivePath as NSString).expandingTildeInPath)
        try saveConfig(config)
        try FileManager.default.createDirectory(atPath: config.activePath, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: config.archivePath, withIntermediateDirectories: true)
        print("Config saved to: \(getConfigPath())")
        print("Active: \(config.activePath)")
        print("Archive: \(config.archivePath)")
    } catch { fail(error) }
}

func runConfigGet(key: String?) {
    do {
        guard let config = try loadConfig() else { fail(PmError.configNotFound) }
        if let k = key {
            guard let value = getConfigValue(config: config, key: k) else { fail(PmError.unknownConfigKey(k)) }
            let obj: Any
            if let dict = value as? [String: String] { obj = dict }
            else if let arr = value as? [String] { obj = arr }
            else if let s = value as? String { obj = s }
            else { obj = value }
            let data = try JSONSerialization.data(withJSONObject: obj, options: .prettyPrinted)
            guard let str = String(data: data, encoding: .utf8) else { exit(1) }
            print(str)
        } else {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try enc.encode(config)
            guard let str = String(data: data, encoding: .utf8) else { exit(1) }
            print(str)
        }
    } catch { fail(error) }
}

func runConfigSet(key: String, valueStr: String) {
    do {
        guard var config = try loadConfig() else { fail(PmError.configNotFound) }
        if key == "activePath" || key == "archivePath" || key == "paraPath" {
            try setConfigValue(config: &config, key: key, value: (valueStr as NSString).expandingTildeInPath)
        } else if key == "notesTemplatePath" {
            try setConfigValue(config: &config, key: key, value: valueStr.isEmpty ? "" : (valueStr as NSString).expandingTildeInPath)
        } else if key == "domains" || key == "subfolders" {
            guard let data = valueStr.data(using: .utf8) else { exit(1) }
            let value = try JSONSerialization.jsonObject(with: data)
            try setConfigValue(config: &config, key: key, value: value)
        } else {
            fail(PmError.unknownConfigKey(key))
        }
        try saveConfig(config)
        print("Updated \(key)")
    } catch { fail(error) }
}

func runNotesPath(args: [String]) {
    guard let project = args.first else {
        stderr("Usage: pm notes path <project>")
        exit(1)
    }
    do {
        let projectPath = try resolveProjectPath(nameOrPrefix: project)
        let notesPath = resolveNotesPath(projectPath: projectPath) ?? getNotesPath(projectPath: projectPath)
        print(notesPath)
    } catch { fail(error) }
}

func runNotesCreate(args: [String]) {
    guard let project = args.first else {
        stderr("Usage: pm notes create <project>")
        exit(1)
    }
    do {
        let projectPath = try resolveProjectPath(nameOrPrefix: project)
        let notesPath = try createNotesFromTemplate(projectPath: projectPath)
        print("Created: \(notesPath)")
    } catch { fail(error) }
}

func runNotesCurrentDay() {
    print(formatSessionDate())
}

func runNotesShow(args: [String]) {
    guard let project = args.first else {
        stderr("Usage: pm notes show <project>")
        exit(1)
    }
    do {
        let projectPath = try resolveProjectPath(nameOrPrefix: project)
        guard let notesPath = resolveNotesPath(projectPath: projectPath) else {
            fail(PmError.notesNotFound(getNotesPath(projectPath: projectPath)))
        }
        let notes = try readNotesFile(notesPath: notesPath)
        let todos = parseTodos(notes: notes)
        let output = NotesShowOutput(notes: notes, todos: todos)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(output)
        guard let str = String(data: data, encoding: .utf8) else { exit(1) }
        print(str)
    } catch { fail(error) }
}

func runNotesWrite(args: [String]) {
    guard let project = args.first else {
        stderr("Usage: pm notes write <project>")
        exit(1)
    }
    do {
        let projectPath = try resolveProjectPath(nameOrPrefix: project)
        guard let notesPath = resolveNotesPath(projectPath: projectPath) else {
            fail(PmError.notesNotFound(getNotesPath(projectPath: projectPath)))
        }
        let stdinData = FileHandle.standardInput.readDataToEndOfFile()
        guard String(data: stdinData, encoding: .utf8) != nil else {
            stderr("Invalid UTF-8 on stdin")
            exit(1)
        }
        let notes = try JSONDecoder().decode(ProjectNotes.self, from: stdinData)
        try writeNotesFile(notesPath: notesPath, notes: notes)
    } catch { fail(error) }
}

func runNotesShowWindow(args: [String]) {
    guard let project = args.first else {
        stderr("Usage: pm notes show-window <project>")
        exit(1)
    }
    do {
        let projectPath = try resolveProjectPath(nameOrPrefix: project)
        guard let notesPath = resolveNotesPath(projectPath: projectPath) else {
            fail(PmError.notesNotFound(getNotesPath(projectPath: projectPath)))
        }
        let rawContent = try String(contentsOfFile: notesPath, encoding: .utf8)
        let windowTitle = (projectPath as NSString).lastPathComponent

        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.activate(ignoringOtherApps: true)

        class NotesWindowDelegate: NSObject, NSApplicationDelegate {
            let content: String
            let title: String
            var window: NSWindow?

            init(content: String, title: String) {
                self.content = content
                self.title = title
            }

            func applicationDidFinishLaunching(_ notification: Notification) {
                let visibleFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
                let width: CGFloat = 700
                let height: CGFloat = 500
                let x = visibleFrame.midX - width / 2
                let y = visibleFrame.midY - height / 2
                let window = NSWindow(
                    contentRect: NSRect(x: x, y: y, width: width, height: height),
                    styleMask: [.titled, .closable, .miniaturizable, .resizable],
                    backing: .buffered,
                    defer: false,
                    screen: nil
                )
                window.title = title
                window.isReleasedWhenClosed = false

                let scrollView = NSScrollView(frame: window.contentView!.bounds)
                scrollView.autoresizingMask = [.width, .height]
                scrollView.hasVerticalScroller = true
                scrollView.hasHorizontalScroller = false
                scrollView.autohidesScrollers = true
                scrollView.borderType = .noBorder
                scrollView.drawsBackground = true
                scrollView.backgroundColor = .textBackgroundColor

                let textView = NSTextView(frame: scrollView.bounds)
                textView.isEditable = false
                textView.isSelectable = true
                textView.drawsBackground = true
                textView.backgroundColor = .textBackgroundColor
                textView.font = NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
                textView.string = content
                textView.autoresizingMask = [.width]
                textView.textContainer?.containerSize = NSSize(width: scrollView.contentSize.width, height: .greatestFiniteMagnitude)
                textView.textContainer?.widthTracksTextView = true

                scrollView.documentView = textView
                window.contentView = scrollView

                self.window = window
                window.makeKeyAndOrderFront(nil)
            }

            func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
                true
            }
        }

        let delegate = NotesWindowDelegate(content: rawContent, title: windowTitle)
        app.delegate = delegate
        app.run()
    } catch { fail(error) }
}

func runNotesSessionAdd(args: [String], dateStr: String?) {
    guard let project = args.first else {
        stderr("Usage: pm notes session add <project> [label]")
        exit(1)
    }
    let label = args.count > 1 ? args[1] : ""
    do {
        let projectPath = try resolveProjectPath(nameOrPrefix: project)
        guard let notesPath = resolveNotesPath(projectPath: projectPath) else {
            fail(PmError.notesNotFound(getNotesPath(projectPath: projectPath)))
        }
        var notes = try readNotesFile(notesPath: notesPath)
        let date: Date?
        if let d = dateStr {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withFullDate]
            date = formatter.date(from: d) ?? Date()
        } else {
            date = nil
        }
        notes = addSession(notes: notes, label: label, date: date)
        try writeNotesFile(notesPath: notesPath, notes: notes)
        let sessionDate = formatSessionDate(date ?? Date())
        print("Added session: \(sessionDate) \(label)")
    } catch { fail(error) }
}

// MARK: - main

let argv = CommandLine.arguments
guard argv.count >= 2 else {
    stderr("Usage: pm <command> [options] [args]")
    exit(1)
}

let cmd = argv[1]
let rest = Array(argv.dropFirst(2))

switch cmd {
case "new":
    runNew(args: rest)
case "list":
    var scope = "active"
    if rest.contains("--all") || rest.contains("-a") { scope = "all" }
    else if rest.contains("--archive") { scope = "archive" }
    runList(scope: scope)
case "archive":
    runArchive(args: rest)
case "unarchive":
    runUnarchive(args: rest)
case "config":
    guard let sub = rest.first else {
        stderr("Usage: pm config <init|get|set> ...")
        exit(1)
    }
    switch sub {
    case "init":
        runConfigInit()
    case "get":
        runConfigGet(key: rest.count > 1 ? rest[1] : nil)
    case "set":
        guard rest.count >= 3 else {
            stderr("Usage: pm config set <key> <value>")
            exit(1)
        }
        runConfigSet(key: rest[1], valueStr: rest[2])
    default:
        stderr("Usage: pm config <init|get|set> ...")
        exit(1)
    }
case "notes":
    guard let sub = rest.first else {
        stderr("Usage: pm notes <path|create|show|show-window|write|current-day|session> ...")
        exit(1)
    }
    switch sub {
    case "path":
        runNotesPath(args: Array(rest.dropFirst()))
    case "create":
        runNotesCreate(args: Array(rest.dropFirst()))
    case "show":
        runNotesShow(args: Array(rest.dropFirst()))
    case "show-window":
        runNotesShowWindow(args: Array(rest.dropFirst()))
    case "write":
        runNotesWrite(args: Array(rest.dropFirst()))
    case "current-day":
        runNotesCurrentDay()
    case "session":
        guard rest.count >= 3, rest[1] == "add" else {
            stderr("Usage: pm notes session add <project> [label] [-d date]")
            exit(1)
        }
        var addArgs = Array(rest.dropFirst(2))
        var dateStr: String?
        if let idx = addArgs.firstIndex(of: "-d"), idx + 1 < addArgs.count {
            dateStr = addArgs[idx + 1]
            addArgs.remove(at: idx + 1)
            addArgs.remove(at: idx)
        } else if let idx = addArgs.firstIndex(of: "--date"), idx + 1 < addArgs.count {
            dateStr = addArgs[idx + 1]
            addArgs.remove(at: idx + 1)
            addArgs.remove(at: idx)
        }
        runNotesSessionAdd(args: addArgs, dateStr: dateStr)
    default:
        stderr("Usage: pm notes <path|create|show|show-window|write|current-day|session> ...")
        exit(1)
    }
default:
    stderr("Unknown command: \(cmd)")
    exit(1)
}
