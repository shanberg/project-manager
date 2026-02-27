import XCTest
import Foundation

/// End-to-end tests that run the built `pm` binary with a temp config.
/// Require: pm binary at packageRoot/.build/debug/pm (built by `swift test`).
final class CLITests: XCTestCase {

    private var env: [String: String] = [:]
    private var configDir: String = ""
    private var activePath: String = ""
    private var archivePath: String = ""

    override func setUp() {
        super.setUp()
        let fm = FileManager.default
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .path
        let pmPath = (packageRoot as NSString).appendingPathComponent(".build/debug/pm")
        guard fm.isExecutableFile(atPath: pmPath) else {
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
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .path
        let pmPath = (packageRoot as NSString).appendingPathComponent(".build/debug/pm")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: pmPath)
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
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .path
        let pmPath = (packageRoot as NSString).appendingPathComponent(".build/debug/pm")
        if !FileManager.default.isExecutableFile(atPath: pmPath) {
            throw XCTSkip("pm binary not found at \(pmPath); run 'swift test' to build")
        }
        if configDir.isEmpty {
            throw XCTSkip("setUp did not create temp config")
        }
    }

    func testConfigGet() throws {
        try skipIfNoBinary()
        let (stdout, _, code) = runPm(["config", "get"])
        XCTAssertEqual(code, 0, "pm config get should exit 0")
        XCTAssertTrue(stdout.contains("activePath"), "stdout should contain activePath")
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

    func testNewAndList() throws {
        try skipIfNoBinary()
        let (_, _, codeNew) = runPm(["new", "W", "CLI Test Project"])
        XCTAssertEqual(codeNew, 0, "pm new should succeed")
        let (stdout, _, codeList) = runPm(["list"])
        XCTAssertEqual(codeList, 0)
        XCTAssertTrue(stdout.contains("CLI Test Project") || stdout.contains("W-1"), "list should show new project")
    }

    func testNewRejectsTitleWithSlash() throws {
        try skipIfNoBinary()
        let (_, stderr, code) = runPm(["new", "W", "Foo/Bar"])
        XCTAssertNotEqual(code, 0)
        XCTAssertTrue(stderr.contains("path separators") || stderr.contains("/"), "stderr should explain invalid title")
    }
}
