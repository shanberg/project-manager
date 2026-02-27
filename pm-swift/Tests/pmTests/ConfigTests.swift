import XCTest
@testable import PmLib

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Config tests that use setenv(PM_CONFIG_HOME) mutate process environment.
/// Do not run this test target in parallel with other processes that call loadConfig() or getConfigDir();
/// Swift Test runs tests serially by default, so single-threaded execution is the default.
final class ConfigTests: XCTestCase {
    /// Use empty env so we only test config-based resolution (not PM_ACTIVE_PATH/PM_ARCHIVE_PATH).
    private var emptyEnv: [String: String] { [:] }

    /// Paths from config when activePath/archivePath are set.
    func testResolvePathsFromConfig() throws {
        let config = PmConfig(
            activePath: "/tmp/active",
            archivePath: "/tmp/archive",
            domains: defaultDomains,
            subfolders: defaultSubfolders
        )
        let paths = try resolvePaths(config: config, environment: emptyEnv)
        XCTAssertEqual(paths.activePath, "/tmp/active")
        XCTAssertEqual(paths.archivePath, "/tmp/archive")
    }

    /// Paths derived from paraPath when active/archive are empty.
    func testResolvePathsFromParaPath() throws {
        let config = PmConfig(
            paraPath: "/tmp/para",
            activePath: "",
            archivePath: "",
            domains: defaultDomains,
            subfolders: defaultSubfolders
        )
        let paths = try resolvePaths(config: config, environment: emptyEnv)
        XCTAssertEqual(paths.activePath, "/tmp/para/active")
        XCTAssertEqual(paths.archivePath, "/tmp/para/archive")
    }

    /// Throws when no path source is available (no env, no config paths, no paraPath).
    func testResolvePathsThrowsWhenMissingPaths() {
        let config = PmConfig(
            activePath: "",
            archivePath: "",
            domains: defaultDomains,
            subfolders: defaultSubfolders
        )
        XCTAssertThrowsError(try resolvePaths(config: config, environment: emptyEnv)) { err in
            guard case PmError.configMissingPaths = err else {
                XCTFail("Expected configMissingPaths, got \(err)")
                return
            }
        }
    }

    /// Env (PM_ACTIVE_PATH / PM_ARCHIVE_PATH) overrides config when both are present.
    func testResolvePathsEnvOverridesConfig() throws {
        let config = PmConfig(
            activePath: "/tmp/active",
            archivePath: "/tmp/archive",
            domains: defaultDomains,
            subfolders: defaultSubfolders
        )
        let env = ["PM_ACTIVE_PATH": "/env/active", "PM_ARCHIVE_PATH": "/env/archive"]
        let paths = try resolvePaths(config: config, environment: env)
        XCTAssertEqual(paths.activePath, "/env/active")
        XCTAssertEqual(paths.archivePath, "/env/archive")
    }

    /// When only one env var is set, env is not used; config paths are used.
    func testResolvePathsPartialEnvFallsBackToConfig() throws {
        let config = PmConfig(
            activePath: "/tmp/active",
            archivePath: "/tmp/archive",
            domains: defaultDomains,
            subfolders: defaultSubfolders
        )
        let envOnlyActive = ["PM_ACTIVE_PATH": "/env/active"]
        let paths = try resolvePaths(config: config, environment: envOnlyActive)
        XCTAssertEqual(paths.activePath, "/tmp/active")
        XCTAssertEqual(paths.archivePath, "/tmp/archive")
    }

    /// Optional path keys (paraPath, notesTemplatePath): empty string is stored as nil so "unset" is consistent (CLI string API).
    func testSetConfigValueParaPathEmptyStringStoresNil() throws {
        var config = PmConfig(
            paraPath: "/some/para",
            activePath: "/a",
            archivePath: "/b",
            domains: defaultDomains,
            subfolders: defaultSubfolders
        )
        try setConfigValue(config: &config, key: "paraPath", value: "")
        XCTAssertNil(config.paraPath)
    }

    /// Typed API: paraPath with .string(nil) or .string("") stores nil (library contract).
    func testSetConfigValueParaPathTypedAPIStoresNil() throws {
        var config = PmConfig(
            paraPath: "/some/para",
            activePath: "/a",
            archivePath: "/b",
            domains: defaultDomains,
            subfolders: defaultSubfolders
        )
        try setConfigValue(config: &config, key: .paraPath, value: .string(nil))
        XCTAssertNil(config.paraPath)
        config.paraPath = "/restored"
        try setConfigValue(config: &config, key: .paraPath, value: .string(""))
        XCTAssertNil(config.paraPath)
    }

    /// setConfigValue throws invalidConfigValue when value has wrong type (no crash from as!).
    func testSetConfigValueInvalidTypeThrows() {
        var config = PmConfig(
            activePath: "/a",
            archivePath: "/b",
            domains: defaultDomains,
            subfolders: defaultSubfolders
        )
        XCTAssertThrowsError(try setConfigValue(config: &config, key: "activePath", value: 123)) { err in
            guard case PmError.invalidConfigValue("activePath", "String") = err else {
                XCTFail("Expected invalidConfigValue for activePath, got \(err)")
                return
            }
        }
        XCTAssertThrowsError(try setConfigValue(config: &config, key: "domains", value: "not an object")) { err in
            guard case PmError.invalidConfigValue(let k, let exp) = err, k == "domains", exp.contains("object") else {
                XCTFail("Expected invalidConfigValue for domains, got \(err)")
                return
            }
        }
    }

    /// loadConfig returns nil when config file does not exist (no throw).
    /// Uses setenv(PM_CONFIG_HOME); do not run in parallel with other code that reads PM_CONFIG_HOME.
    func testLoadConfigReturnsNilWhenFileMissing() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let configDir = tmp.path
        let saved = ProcessInfo.processInfo.environment["PM_CONFIG_HOME"]
        setenv("PM_CONFIG_HOME", configDir, 1)
        defer {
            if let s = saved {
                setenv("PM_CONFIG_HOME", s, 1)
            } else {
                unsetenv("PM_CONFIG_HOME")
            }
        }
        let result = try loadConfig()
        XCTAssertNil(result)
    }

    /// loadConfig throws when config file exists but is invalid JSON.
    /// Uses setenv(PM_CONFIG_HOME); do not run in parallel with other code that reads PM_CONFIG_HOME.
    func testLoadConfigThrowsWhenInvalidJSON() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let configPath = tmp.appendingPathComponent("config.json")
        try "not valid json".write(to: configPath, atomically: true, encoding: .utf8)
        let saved = ProcessInfo.processInfo.environment["PM_CONFIG_HOME"]
        setenv("PM_CONFIG_HOME", tmp.path, 1)
        defer {
            if let s = saved {
                setenv("PM_CONFIG_HOME", s, 1)
            } else {
                unsetenv("PM_CONFIG_HOME")
            }
        }
        XCTAssertThrowsError(try loadConfig()) { err in
            XCTAssert(err is DecodingError, "Expected DecodingError, got \(type(of: err))")
        }
    }

    /// validatePathsExist throws activePathNotFound when active path does not exist.
    func testValidatePathsExistThrowsWhenActiveMissing() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let paths = ResolvedPaths(activePath: "/nonexistent/active", archivePath: tmp.path)
        XCTAssertThrowsError(try validatePathsExist(paths: paths)) { err in
            guard case PmError.activePathNotFound(let path) = err else {
                XCTFail("Expected activePathNotFound, got \(err)")
                return
            }
            XCTAssertEqual(path, "/nonexistent/active")
        }
    }

    /// validatePathsExist throws archivePathNotFound when archive path does not exist.
    func testValidatePathsExistThrowsWhenArchiveMissing() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let paths = ResolvedPaths(activePath: tmp.path, archivePath: "/nonexistent/archive")
        XCTAssertThrowsError(try validatePathsExist(paths: paths)) { err in
            guard case PmError.archivePathNotFound(let path) = err else {
                XCTFail("Expected archivePathNotFound, got \(err)")
                return
            }
            XCTAssertEqual(path, "/nonexistent/archive")
        }
    }

    /// validatePathsExist throws when active path exists but is a file, not a directory.
    func testValidatePathsExistThrowsWhenActiveIsFile() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let fileAsActive = tmp.appendingPathComponent("active").path
        try Data().write(to: URL(fileURLWithPath: fileAsActive))
        let archiveDir = tmp.appendingPathComponent("archive").path
        try FileManager.default.createDirectory(atPath: archiveDir, withIntermediateDirectories: true)
        let paths = ResolvedPaths(activePath: fileAsActive, archivePath: archiveDir)
        XCTAssertThrowsError(try validatePathsExist(paths: paths)) { err in
            guard case PmError.activePathNotFound(let path) = err else {
                XCTFail("Expected activePathNotFound, got \(err)")
                return
            }
            XCTAssertEqual(path, fileAsActive)
        }
    }

    /// validatePathsExist throws when archive path exists but is a file, not a directory.
    func testValidatePathsExistThrowsWhenArchiveIsFile() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let activeDir = tmp.appendingPathComponent("active").path
        try FileManager.default.createDirectory(atPath: activeDir, withIntermediateDirectories: true)
        let fileAsArchive = tmp.appendingPathComponent("archive").path
        try Data().write(to: URL(fileURLWithPath: fileAsArchive))
        let paths = ResolvedPaths(activePath: activeDir, archivePath: fileAsArchive)
        XCTAssertThrowsError(try validatePathsExist(paths: paths)) { err in
            guard case PmError.archivePathNotFound(let path) = err else {
                XCTFail("Expected archivePathNotFound, got \(err)")
                return
            }
            XCTAssertEqual(path, fileAsArchive)
        }
    }

    /// getConfigValue returns .unknownKey for invalid key string (CLI uses this for unknown keys).
    func testGetConfigValueUnknownKeyReturnsUnknownKey() {
        let config = PmConfig(
            activePath: "/a",
            archivePath: "/b",
            domains: defaultDomains,
            subfolders: defaultSubfolders
        )
        guard case .unknownKey = getConfigValue(config: config, key: "bogus") else {
            XCTFail("Expected unknownKey for invalid key")
            return
        }
    }
}
