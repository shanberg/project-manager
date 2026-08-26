import XCTest
import Foundation
import PmLib

/// End-to-end tests that run the built `pm` binary with a temp config.
/// The test target depends on the `pm` executable; `swift test` builds it first. Binary path: packageRoot/.build/debug/pm.
/// If you only use `swift build -c release`, run `swift build` or `swift test` once so the debug binary exists for tests.
/// Tests that create a project with `pm new` then parse `pm list` output to get a folder name depend on the current list format (one project per line, folder name in the line); changing list output may require updating those tests.
final class CLITests: XCTestCase {

    /// Package root (pm-swift) and path to the debug pm binary. Centralized so changing build layout only requires one edit.
    private static var packageRoot: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .path
    }
    private static var pmBinaryPath: String {
        (packageRoot as NSString).appendingPathComponent(".build/debug/pm")
    }

    private var env: [String: String] = [:]
    private var configDir: String = ""
    private var activePath: String = ""
    private var archivePath: String = ""

    override func setUp() {
        super.setUp()
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: Self.pmBinaryPath) else {
            return
        }
        let tmp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        try? fm.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        configDir = (tmp as NSString).appendingPathComponent("config")
        activePath = (tmp as NSString).appendingPathComponent("active")
        archivePath = (tmp as NSString).appendingPathComponent("archive")
        try? fm.createDirectory(atPath: configDir, withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: activePath, withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: archivePath, withIntermediateDirectories: true)
        let configObj: [String: Any] = [
            "activePath": activePath,
            "archivePath": archivePath,
            "domains": ["W": "Work", "P": "Personal"],
            "subfolders": ["deliverables", "docs", "resources", "previews", "working files"],
        ]
        let configData = try? JSONSerialization.data(withJSONObject: configObj)
        let configPath = (configDir as NSString).appendingPathComponent("config.json")
        try? configData?.write(to: URL(fileURLWithPath: configPath))
        env = [
            "PM_CONFIG_HOME": configDir,
            "PM_ACTIVE_PATH": activePath,
            "PM_ARCHIVE_PATH": archivePath,
        ]
    }

    override func tearDown() {
        if !configDir.isEmpty {
            let tmp = (configDir as NSString).deletingLastPathComponent
            try? FileManager.default.removeItem(atPath: tmp)
        }
        super.tearDown()
    }

    private func runPm(_ args: [String], stdin: String? = nil) -> (stdout: String, stderr: String, exitCode: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.pmBinaryPath)
        process.arguments = args
        process.environment = ProcessInfo.processInfo.environment.merging(env) { _, e in e }
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        if let input = stdin {
            let inPipe = Pipe()
            process.standardInput = inPipe
            try? inPipe.fileHandleForWriting.write(contentsOf: Data(input.utf8))
            try? inPipe.fileHandleForWriting.close()
        }
        try? process.run()
        process.waitUntilExit()
        let outData = (try? outPipe.fileHandleForReading.readToEnd()) ?? Data()
        let errData = (try? errPipe.fileHandleForReading.readToEnd()) ?? Data()
        return (
            String(data: outData, encoding: .utf8) ?? "",
            String(data: errData, encoding: .utf8) ?? "",
            process.terminationStatus
        )
    }

    private func skipIfNoBinary() throws {
        if !FileManager.default.isExecutableFile(atPath: Self.pmBinaryPath) {
            throw XCTSkip("pm binary not found at \(Self.pmBinaryPath); run 'swift test' to build")
        }
        if configDir.isEmpty {
            throw XCTSkip("setUp did not create temp config")
        }
    }

    func testVersionFlag() throws {
        try skipIfNoBinary()
        let (stdout, _, code) = runPm(["--version"])
        XCTAssertEqual(code, 0)
        XCTAssertFalse(stdout.trimmingCharacters(in: .whitespaces).isEmpty, "version should be non-empty")
        XCTAssertTrue(stdout.contains("."), "version should look like x.y.z")
        let (stdoutV, _, codeV) = runPm(["-V"])
        XCTAssertEqual(codeV, 0)
        XCTAssertEqual(stdout.trimmingCharacters(in: .whitespaces), stdoutV.trimmingCharacters(in: .whitespaces))
    }

    func testConfigGet() throws {
        try skipIfNoBinary()
        let (stdout, _, code) = runPm(["config", "get"])
        XCTAssertEqual(code, 0, "pm config get should exit 0")
        guard let data = stdout.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("stdout should be valid JSON: \(stdout)")
            return
        }
        XCTAssertTrue(obj["activePath"] != nil, "config JSON should have activePath key")
        XCTAssertTrue(obj["archivePath"] != nil, "config JSON should have archivePath key")
    }

    /// Optional keys (paraPath, notesTemplatePath) when unset must serialize as JSON null, not omit or use type reflection.
    func testConfigGetOptionalKeyOutputsNull() throws {
        try skipIfNoBinary()
        let (stdout, _, code) = runPm(["config", "get", "paraPath"])
        XCTAssertEqual(code, 0)
        XCTAssertEqual(stdout.trimmingCharacters(in: .whitespacesAndNewlines), "null", "unset paraPath should output JSON null")
    }

    /// Single-key config get for string keys (e.g. activePath) outputs the raw value, not JSON-encoded (so scripting works).
    func testConfigGetSingleKeyOutputsRawString() throws {
        try skipIfNoBinary()
        let (stdout, _, code) = runPm(["config", "get", "activePath"])
        XCTAssertEqual(code, 0, "pm config get activePath should exit 0")
        let value = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(value, activePath, "single-key get should output raw path without JSON quotes; got: \(value)")
        XCTAssertFalse(value.hasPrefix("\""), "output must not be JSON-encoded string")
    }

    func testNotesCurrentDay() throws {
        try skipIfNoBinary()
        let (stdout, _, code) = runPm(["notes", "current-day"])
        XCTAssertEqual(code, 0)
        XCTAssertTrue(stdout.contains(","), "expected date format like 'Thu, Feb 26, 2025'")
        XCTAssertTrue(stdout.range(of: #"\d{4}"#, options: .regularExpression) != nil, "should contain 4-digit year")
    }

    func testConfigSetInvalidJSONFailsWithMessage() throws {
        try skipIfNoBinary()
        let (_, stderr, code) = runPm(["config", "set", "domains", "not json"])
        XCTAssertNotEqual(code, 0)
        XCTAssertTrue(stderr.contains("valid JSON"), "stderr should mention valid JSON: \(stderr)")
    }

    /// Values with spaces are supported when passed as a single argument (e.g. quoted in shell).
    func testConfigSetValueWithSpaces() throws {
        try skipIfNoBinary()
        let pathWithSpaces = "/path/with spaces"
        let (_, stderrSet, codeSet) = runPm(["config", "set", "activePath", pathWithSpaces])
        XCTAssertEqual(codeSet, 0, "config set should accept value with spaces (stderr: \(stderrSet))")
        let (stdoutGet, _, codeGet) = runPm(["config", "get"])
        XCTAssertEqual(codeGet, 0, "config get should succeed after set")
        guard let data = stdoutGet.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = obj["activePath"] as? String else {
            XCTFail("config get should output JSON with activePath key")
            return
        }
        XCTAssertEqual(value, pathWithSpaces, "stored value should equal path with spaces")
        _ = runPm(["config", "set", "activePath", activePath])
    }

    func testNewAndList() throws {
        try skipIfNoBinary()
        let (_, _, codeNew) = runPm(["new", "W", "CLI Test Project"])
        XCTAssertEqual(codeNew, 0, "pm new should succeed")
        let (stdout, _, codeList) = runPm(["list"])
        XCTAssertEqual(codeList, 0)
        let hasFullProject = stdout.contains("CLI Test Project") && stdout.contains("W-1")
        XCTAssertTrue(hasFullProject, "list should show full project (W-1 CLI Test Project): \(stdout)")
    }

    func testNewRejectsTitleWithSlash() throws {
        try skipIfNoBinary()
        let (_, stderr, code) = runPm(["new", "W", "Foo/Bar"])
        XCTAssertNotEqual(code, 0)
        XCTAssertTrue(stderr.contains("path separators") || stderr.contains("/"), "stderr should explain invalid title")
    }

    /// notes path exits 0 when notes file exists, non-zero when it does not (for scripting).
    func testNotesPathExitCode() throws {
        try skipIfNoBinary()
        let (_, _, codeNew) = runPm(["new", "W", "Path Test Project"])
        XCTAssertEqual(codeNew, 0)
        let (stdoutList, _, _) = runPm(["list"])
        // List format: one project per line; line content is the folder name (e.g. "W-1 Path Test Project").
        let line = stdoutList.split(separator: "\n").first { $0.contains("Path Test Project") }.map(String.init)
        guard let folderName = line?.trimmingCharacters(in: .whitespaces) else {
            XCTFail("could not find project in list")
            return
        }
        let (_, _, codePathExists) = runPm(["notes", "path", folderName])
        XCTAssertEqual(codePathExists, 0, "notes path should exit 0 when notes file exists")
        let notesPath = (activePath as NSString).appendingPathComponent(folderName)
        let docsPath = (notesPath as NSString).appendingPathComponent("docs")
        let notesFile = (docsPath as NSString).appendingPathComponent("Notes - Path Test Project.md")
        do {
            try FileManager.default.removeItem(atPath: notesFile)
        } catch {
            XCTFail("Failed to remove notes file for test: \(error)")
            return
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: notesFile), "notes file should be gone before testing missing path")
        let (_, stderrNoNotes, codePathMissing) = runPm(["notes", "path", folderName])
        XCTAssertNotEqual(codePathMissing, 0, "notes path should exit non-zero when notes file does not exist: \(stderrNoNotes)")
    }

    /// archive moves project from active to archive; list and list --archive reflect the move; unarchive moves it back.
    func testArchiveAndUnarchiveMoveProject() throws {
        try skipIfNoBinary()
        let (_, _, codeNew) = runPm(["new", "W", "Archive Test Project"])
        XCTAssertEqual(codeNew, 0)
        let (stdoutActive1, _, codeList1) = runPm(["list"])
        XCTAssertEqual(codeList1, 0)
        // List format: one project per line; full line is the folder name.
        let folderLine = stdoutActive1.split(separator: "\n").first { $0.contains("Archive Test Project") }
        guard let line = folderLine else {
            XCTFail("list should show new project: \(stdoutActive1)")
            return
        }
        let folderName = String(line.trimmingCharacters(in: .whitespaces))

        let (stdoutArchive, _, codeArchive) = runPm(["archive", "W-1"])
        XCTAssertEqual(codeArchive, 0, "pm archive should succeed")
        XCTAssertTrue(stdoutArchive.contains("Archived") && stdoutArchive.contains(folderName))

        XCTAssertFalse(FileManager.default.fileExists(atPath: (activePath as NSString).appendingPathComponent(folderName)), "folder should be gone from active")
        XCTAssertTrue(FileManager.default.fileExists(atPath: (archivePath as NSString).appendingPathComponent(folderName)), "folder should exist in archive")

        let (stdoutActive2, _, _) = runPm(["list"])
        XCTAssertFalse(stdoutActive2.contains("Archive Test Project"), "list (active) should not show archived project")
        let (stdoutArchiveList, _, codeArchiveList) = runPm(["list", "--archive"])
        XCTAssertEqual(codeArchiveList, 0)
        XCTAssertTrue(stdoutArchiveList.contains("Archive Test Project"), "list --archive should show archived project: \(stdoutArchiveList)")

        let (stdoutUnarchive, _, codeUnarchive) = runPm(["unarchive", "W-1"])
        XCTAssertEqual(codeUnarchive, 0)
        XCTAssertTrue(stdoutUnarchive.contains("Unarchived"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: (activePath as NSString).appendingPathComponent(folderName)), "folder should be back in active after unarchive")
        XCTAssertFalse(FileManager.default.fileExists(atPath: (archivePath as NSString).appendingPathComponent(folderName)), "folder should be gone from archive")
        let (stdoutActive3, _, _) = runPm(["list"])
        XCTAssertTrue(stdoutActive3.contains("Archive Test Project"), "list should show project again after unarchive")
    }

    /// rename changes folder title; stdout is the new folder basename.
    func testPmRenamePrintsNewBasename() throws {
        try skipIfNoBinary()
        let (_, _, codeNew) = runPm(["new", "W", "Rename CLI Test"])
        XCTAssertEqual(codeNew, 0)
        let (stdout, stderr, code) = runPm(["rename", "W-1", "Renamed Title"])
        XCTAssertEqual(code, 0, "pm rename should succeed: \(stderr)")
        let line = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(line, "W-1 Renamed Title")
        let newPath = (activePath as NSString).appendingPathComponent("W-1 Renamed Title")
        XCTAssertTrue(FileManager.default.fileExists(atPath: newPath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: (activePath as NSString).appendingPathComponent("W-1 Rename CLI Test")))
    }

    /// config init rejects when active and archive paths are the same.
    func testConfigInitRejectsSamePath() throws {
        try skipIfNoBinary()
        let samePath = "/tmp/same-path"
        let stdinInput = "y\n\(samePath)\n\(samePath)\n"
        let (_, stderr, code) = runPm(["config", "init"], stdin: stdinInput)
        XCTAssertNotEqual(code, 0, "config init with same path should fail")
        XCTAssertTrue(stderr.contains("must be different"), "stderr should explain: \(stderr)")
    }

    /// notes write accepts ProjectNotes JSON on stdin and overwrites the project notes file; notes show returns the written content.
    func testNotesWrite() throws {
        try skipIfNoBinary()
        let (_, _, codeNew) = runPm(["new", "W", "Notes Write Test"])
        XCTAssertEqual(codeNew, 0, "pm new should succeed")
        let notes = ProjectNotes(
            title: "Notes Write Test",
            summary: "Summary from notes write",
            problem: "",
            goals: ["", "", ""],
            approach: "",
            links: [LinkEntry(label: nil, url: nil, children: nil)],
            learnings: [""],
            sessions: [
                Session(date: "Fri, Feb 27, 2025", label: "CLITest", body: "- [ ] Task written via pm notes write")
            ]
        )
        let encoder = JSONEncoder()
        let data = try encoder.encode(notes)
        let jsonString = String(data: data, encoding: .utf8)!
        let (_, _, codeWrite) = runPm(["notes", "write", "W-1"], stdin: jsonString)
        XCTAssertEqual(codeWrite, 0, "pm notes write should exit 0")
        let (stdoutShow, _, codeShow) = runPm(["notes", "show", "W-1"])
        XCTAssertEqual(codeShow, 0, "pm notes show should exit 0 after write")
        XCTAssertTrue(stdoutShow.contains("Summary from notes write"), "show output should contain written summary")
        XCTAssertTrue(stdoutShow.contains("Task written via pm notes write"), "show output should contain written todo text")
        XCTAssertTrue(stdoutShow.contains("CLITest"), "show output should contain session label")
    }

    /// notes todo add (quick add) takes focus; notes show reflects it; notes todo complete clears/advances
    /// focus. Exercises the shared NotesService load/mutate/write path end-to-end.
    func testNotesTodoAddShowComplete() throws {
        try skipIfNoBinary()
        let (_, _, codeNew) = runPm(["new", "W", "Todo Service Test"])
        XCTAssertEqual(codeNew, 0, "pm new should succeed")
        // pm new scaffolds the notes file from the template, so todo mutations can run immediately.
        let (_, addErr, codeAdd) = runPm(["notes", "todo", "add", "W-1", "First service task"])
        XCTAssertEqual(codeAdd, 0, "pm notes todo add should exit 0: \(addErr)")

        let (showOut, _, codeShow) = runPm(["notes", "show", "W-1"])
        XCTAssertEqual(codeShow, 0, "pm notes show should exit 0")
        XCTAssertTrue(showOut.contains("First service task"), "show should contain the added task")
        XCTAssertTrue(showOut.contains("\"focusedKey\""), "quick-added task should take focus")

        // Complete it; with no other tasks, focus clears (focusedKey becomes null).
        let (showData, _, _) = runPm(["notes", "show", "W-1"])
        struct ShowKey: Decodable { let focusedKey: String? }
        let key = (try? JSONDecoder().decode(ShowKey.self, from: Data(showData.utf8)))?.focusedKey
        let parts = (key ?? "0:0").split(separator: ":")
        let (_, compErr, codeComp) = runPm(["notes", "todo", "complete", "W-1", String(parts[0]), String(parts[1])])
        XCTAssertEqual(codeComp, 0, "pm notes todo complete should exit 0: \(compErr)")

        let (showOut2, _, _) = runPm(["notes", "show", "W-1"])
        XCTAssertTrue(showOut2.contains("\"checked\":true") || showOut2.contains("\"checked\" : true"),
                      "completed task should be checked in show output")
    }

    /// notes session add creates a session with optional label and --date; notes show includes the new session.
    func testNotesSessionAdd() throws {
        try skipIfNoBinary()
        let (_, _, codeNew) = runPm(["new", "W", "Session Add Test"])
        XCTAssertEqual(codeNew, 0)
        let (stdoutList, _, _) = runPm(["list"])
        // List format: one project per line; full line is the folder name.
        let folderName = stdoutList.split(separator: "\n").first { $0.contains("Session Add Test") }.map { String($0.trimmingCharacters(in: .whitespaces)) }
        guard let name = folderName else { XCTFail("project not in list"); return }

        let (stdoutAdd, _, codeAdd) = runPm(["notes", "session", "add", name, "Sprint 1", "--date", "2025-01-15"])
        XCTAssertEqual(codeAdd, 0, "notes session add should succeed: \(stdoutAdd)")
        XCTAssertTrue(stdoutAdd.contains("2025") && stdoutAdd.contains("Sprint 1"), "output should show date and label")

        let (stdoutShow, _, codeShow) = runPm(["notes", "show", name])
        XCTAssertEqual(codeShow, 0)
        XCTAssertTrue(stdoutShow.contains("Jan 15, 2025"), "notes show should include session date from --date 2025-01-15")
        XCTAssertTrue(stdoutShow.contains("Sprint 1"), "notes show should include session label")
    }

    // MARK: Areas

    /// The end-to-end shape of an Area: made without a domain, in its own root, listed on its own, and
    /// carrying the header its kind calls for rather than a project's.
    func testNewAreaCreatesAnUnnumberedFolderWithTheAreaHeader() throws {
        try skipIfNoBinary()
        let made = runPm(["new", "--area", "Team 1:1s"])
        XCTAssertEqual(made.exitCode, 0, made.stderr)

        let areasPath = ((activePath as NSString).deletingLastPathComponent as NSString)
            .appendingPathComponent("areas")
        let folder = (areasPath as NSString).appendingPathComponent("Team 1:1s")
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder), "expected an area at \(folder)")

        // The notes file lands at the full title, which is the projectTitle fix doing its job.
        let notesPath = (folder as NSString).appendingPathComponent("docs/Notes - Team 1:1s.md")
        let notes = try String(contentsOfFile: notesPath, encoding: .utf8)
        XCTAssertTrue(notes.contains("# Team 1:1s"))
        XCTAssertTrue(notes.contains("> [!info] Goals"))
        XCTAssertFalse(notes.contains("Problem"), "an area's template has no Problem")
        XCTAssertFalse(notes.contains("Approach"), "an area's template has no Approach")

        let listed = runPm(["list", "--areas"])
        XCTAssertTrue(listed.stdout.contains("Team 1:1s"), listed.stdout + listed.stderr)

        // And it stays out of the project list, where a number would have put it.
        let projects = runPm(["list"])
        XCTAssertFalse(projects.stdout.contains("Team 1:1s"), projects.stdout)
    }

    func testNewAreaTakesNoDomain() throws {
        try skipIfNoBinary()
        _ = runPm(["new", "W", "First"])
        _ = runPm(["new", "--area", "Hiring"])
        let second = runPm(["new", "W", "Second"])
        XCTAssertTrue(second.stdout.contains("W-2 Second"),
                      "an area must not take a number: \(second.stdout)")
    }

    /// Both kinds share one archive, and an Area still knows to come back to areas/ rather than active/.
    func testArchivingAnAreaAndBringingItBack() throws {
        try skipIfNoBinary()
        _ = runPm(["new", "--area", "Team 1:1s"])
        let areasPath = ((activePath as NSString).deletingLastPathComponent as NSString)
            .appendingPathComponent("areas")

        let archived = runPm(["api", "call", "project.archive", #"{"project":"Team 1:1s"}"#])
        XCTAssertEqual(archived.exitCode, 0, archived.stderr)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: (archivePath as NSString).appendingPathComponent("Team 1:1s")))

        let restored = runPm(["api", "call", "project.unarchive", #"{"project":"Team 1:1s"}"#])
        XCTAssertEqual(restored.exitCode, 0, restored.stderr)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: (areasPath as NSString).appendingPathComponent("Team 1:1s")),
            "an unarchived area belongs in areas/, not active/")
    }

    /// Capture works on an Area with nothing added for it — one resolver serves both kinds.
    func testTasksAndNotesGoIntoAnAreaLikeAnyOtherProject() throws {
        try skipIfNoBinary()
        _ = runPm(["new", "--area", "Team 1:1s"])
        let added = runPm(["api", "call", "task.add",
                           #"{"project":"Team 1:1s","text":"send Dana the levelling doc"}"#])
        XCTAssertEqual(added.exitCode, 0, added.stderr)

        let read = runPm(["api", "call", "notes.get", #"{"project":"Team 1:1s"}"#])
        XCTAssertTrue(read.stdout.contains("send Dana the levelling doc"), read.stdout)
    }

    /// A section the kind leaves out is refused where the caller can be told, rather than written and
    /// then dropped by the next thing that rewrites the document.
    func testSettingAProblemOnAnAreaIsRefused() throws {
        try skipIfNoBinary()
        _ = runPm(["new", "--area", "Team 1:1s"])
        let refused = runPm(["api", "call", "notes.setDetail",
                             #"{"project":"Team 1:1s","key":"problem","value":"nope"}"#])
        XCTAssertNotEqual(refused.exitCode, 0)
        XCTAssertTrue((refused.stdout + refused.stderr).contains("no Problem section"),
                      refused.stdout + refused.stderr)

        let allowed = runPm(["api", "call", "notes.setDetail",
                             #"{"project":"Team 1:1s","key":"summary","value":"Weekly."}"#])
        XCTAssertEqual(allowed.exitCode, 0, allowed.stderr)
    }

    /// Cross-project task search has to see Areas. It used to scan only the two numbered roots, so an
    /// area's tasks were findable in the Mac app (its own index) and nowhere else — the worst version
    /// of a gap, since the same query gave two different answers depending on where you asked.
    func testTaskSearchFindsTasksInAreas() throws {
        try skipIfNoBinary()
        _ = runPm(["new", "W", "Website"])
        _ = runPm(["new", "--area", "Team 1:1s"])
        _ = runPm(["api", "call", "task.add", #"{"project":"W-1","text":"levelling the nav"}"#])
        _ = runPm(["api", "call", "task.add", #"{"project":"Team 1:1s","text":"levelling doc for Dana"}"#])

        let found = runPm(["api", "call", "task.search", #"{"query":"levelling"}"#])
        XCTAssertEqual(found.exitCode, 0, found.stderr)
        XCTAssertTrue(found.stdout.contains("Team 1:1s"), "the area's task is missing: \(found.stdout)")
        XCTAssertTrue(found.stdout.contains("W-1 Website"), "the project's task is missing: \(found.stdout)")
    }

    /// `pm archive` matched only numbered folders, so an area couldn't be put away from the CLI even
    /// though the API could do it.
    func testArchivingAnAreaFromTheCli() throws {
        try skipIfNoBinary()
        _ = runPm(["new", "--area", "Team 1:1s"])
        let areasPath = ((activePath as NSString).deletingLastPathComponent as NSString)
            .appendingPathComponent("areas")

        let archived = runPm(["archive", "Team 1:1s"])
        XCTAssertEqual(archived.exitCode, 0, archived.stderr)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: (archivePath as NSString).appendingPathComponent("Team 1:1s")))

        let restored = runPm(["unarchive", "Team 1:1s"])
        XCTAssertEqual(restored.exitCode, 0, restored.stderr)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: (areasPath as NSString).appendingPathComponent("Team 1:1s")),
            "an unarchived area belongs in areas/, not active/")
    }

    /// `pm rename` on an area moves the whole name, since an area has no prefix to preserve.
    func testRenamingAnAreaFromTheCli() throws {
        try skipIfNoBinary()
        _ = runPm(["new", "--area", "Team 1:1s"])
        let renamed = runPm(["rename", "Team 1:1s", "Team One-on-Ones"])
        XCTAssertEqual(renamed.exitCode, 0, renamed.stderr)
        XCTAssertTrue(renamed.stdout.contains("Team One-on-Ones"), renamed.stdout)

        let listed = runPm(["list", "--areas"])
        XCTAssertTrue(listed.stdout.contains("Team One-on-Ones"), listed.stdout)
        XCTAssertFalse(listed.stdout.contains("Team 1:1s"), listed.stdout)
    }

    /// The whole-document write path refuses to introduce an omitted section, and says so with a
    /// non-zero exit rather than reporting success.
    func testWholeDocumentWriteCannotAddAProblemToAnArea() throws {
        try skipIfNoBinary()
        _ = runPm(["new", "--area", "Team 1:1s"])
        let read = runPm(["api", "call", "notes.get", #"{"project":"Team 1:1s"}"#])
        let notes = try XCTUnwrap(
            (try JSONSerialization.jsonObject(with: Data(read.stdout.utf8)) as? [String: Any])?["data"]
                as? [String: Any])
        var doc = try XCTUnwrap(notes["notes"] as? [String: Any])
        doc["problem"] = "snuck in"
        let payload = String(decoding: try JSONSerialization.data(withJSONObject: doc), as: UTF8.self)

        let written = runPm(["notes", "write", "Team 1:1s"], stdin: payload)
        XCTAssertNotEqual(written.exitCode, 0, "a refused write must not report success")
        XCTAssertTrue((written.stdout + written.stderr).contains("no Problem section"),
                      written.stdout + written.stderr)
    }
}
