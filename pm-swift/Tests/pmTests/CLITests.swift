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
}
