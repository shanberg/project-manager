import XCTest
@testable import PmLib

final class ResolveProjectPathTests: XCTestCase {
    private var activePath: String = ""
    private var archivePath: String = ""

    override func setUp() {
        super.setUp()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        activePath = (tmp as NSString).appendingPathComponent("active")
        archivePath = (tmp as NSString).appendingPathComponent("archive")
        try? FileManager.default.createDirectory(atPath: activePath, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: archivePath, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if !activePath.isEmpty {
            let tmp = (activePath as NSString).deletingLastPathComponent
            try? FileManager.default.removeItem(atPath: tmp)
        }
        super.tearDown()
    }

    private func config(active: String? = nil, archive: String? = nil) throws -> (PmConfig, ResolvedPaths) {
        let c = PmConfig(
            activePath: active ?? activePath,
            archivePath: archive ?? archivePath,
            domains: ["W": "Work", "P": "Personal"],
            subfolders: defaultSubfolders
        )
        let paths = try resolvePaths(config: c, environment: [:])
        return (c, paths)
    }

    /// Returns full path when project exists in active.
    func testResolveProjectPathReturnsActivePath() throws {
        let projectDir = (activePath as NSString).appendingPathComponent("W-1 Alpha Project")
        try FileManager.default.createDirectory(atPath: projectDir, withIntermediateDirectories: true)
        let (config, paths) = try config()

        let path = try resolveProjectPath(config: config, paths: paths, nameOrPrefix: "W-1 Alpha Project")
        XCTAssertEqual(path, projectDir)
        XCTAssertEqual(try resolveProjectPath(config: config, paths: paths, nameOrPrefix: "W-1"), projectDir)
    }

    /// Returns full path when project exists in archive.
    func testResolveProjectPathReturnsArchivePath() throws {
        let projectDir = (archivePath as NSString).appendingPathComponent("W-2 Archived")
        try FileManager.default.createDirectory(atPath: projectDir, withIntermediateDirectories: true)
        let (config, paths) = try config()

        let path = try resolveProjectPath(config: config, paths: paths, nameOrPrefix: "W-2 Archived")
        XCTAssertEqual(path, projectDir)
        XCTAssertEqual(try resolveProjectPath(config: config, paths: paths, nameOrPrefix: "W-2"), projectDir)
    }

    /// Throws emptyProjectQuery when nameOrPrefix is empty or only whitespace. Empty query throws before loadConfigAndPaths(); no config required.
    func testResolveProjectPathThrowsWhenEmpty() {
        XCTAssertThrowsError(try resolveProjectPath(nameOrPrefix: "")) { err in
            guard case PmError.emptyProjectQuery = err else {
                XCTFail("Expected emptyProjectQuery, got \(err)")
                return
            }
        }
        XCTAssertThrowsError(try resolveProjectPath(nameOrPrefix: "   ")) { err in
            guard case PmError.emptyProjectQuery = err else {
                XCTFail("Expected emptyProjectQuery, got \(err)")
                return
            }
        }
    }

    /// Throws projectNotFound when no folder matches.
    func testResolveProjectPathThrowsWhenNotFound() throws {
        let (config, paths) = try config()
        XCTAssertThrowsError(try resolveProjectPath(config: config, paths: paths, nameOrPrefix: "W-99")) { err in
            guard case PmError.projectNotFound("W-99") = err else {
                XCTFail("Expected projectNotFound, got \(err)")
                return
            }
        }
    }

    /// Throws ambiguousProject when multiple folders match the prefix.
    func testResolveProjectPathThrowsWhenAmbiguous() throws {
        try FileManager.default.createDirectory(atPath: (activePath as NSString).appendingPathComponent("W-1 Foo"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: (activePath as NSString).appendingPathComponent("W-10 Bar"), withIntermediateDirectories: true)
        let (config, paths) = try config()

        XCTAssertThrowsError(try resolveProjectPath(config: config, paths: paths, nameOrPrefix: "W-1")) { err in
            guard case PmError.ambiguousProject("W-1") = err else {
                XCTFail("Expected ambiguousProject, got \(err)")
                return
            }
        }
    }

    /// When the same folder name exists in both active and archive, resolve returns the active path.
    func testResolveProjectPathDuplicateFolderReturnsActive() throws {
        let folderName = "W-1 Duplicate"
        try FileManager.default.createDirectory(atPath: (activePath as NSString).appendingPathComponent(folderName), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: (archivePath as NSString).appendingPathComponent(folderName), withIntermediateDirectories: true)
        let (config, paths) = try config()

        let path = try resolveProjectPath(config: config, paths: paths, nameOrPrefix: folderName)
        XCTAssertEqual(path, (activePath as NSString).appendingPathComponent(folderName), "Duplicate folder name should resolve to active, not archive")
    }
}
