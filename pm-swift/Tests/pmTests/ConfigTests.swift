import XCTest
@testable import PmLib

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
}
