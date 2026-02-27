import XCTest
@testable import PmLib

final class ProjectsTests: XCTestCase {
    /// getProjectFolders throws when the base path does not exist (cannot list directory).
    func testGetProjectFoldersThrowsWhenPathDoesNotExist() {
        let notExist = "/nonexistent/path/that/does/not/exist"
        XCTAssertThrowsError(try getProjectFolders(basePath: notExist, domainCodes: ["W"])) { err in
            guard case PmError.cannotListDirectory(let path, _) = err else {
                XCTFail("Expected cannotListDirectory, got \(err)")
                return
            }
            XCTAssertEqual(path, notExist)
        }
    }

    /// getProjectFolders returns matching folder names when path exists and contains project folders.
    func testGetProjectFoldersReturnsMatchingFolders() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        try FileManager.default.createDirectory(at: tmp.appendingPathComponent("W-1 Foo"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tmp.appendingPathComponent("W-2 Bar"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tmp.appendingPathComponent("not-a-project"), withIntermediateDirectories: true)

        let names = try getProjectFolders(basePath: tmp.path, domainCodes: ["W"])
        XCTAssertEqual(names.sorted(), ["W-1 Foo", "W-2 Bar"])
    }

    /// matchProject returns exact match, single prefix match, or nil for ambiguous/missing/empty.
    func testMatchProject() {
        let folders = ["W-1 Alpha", "W-2 Beta", "W-10 Gamma"]
        XCTAssertEqual(matchProject(folders: folders, query: "W-1 Alpha"), "W-1 Alpha")
        XCTAssertEqual(matchProject(folders: folders, query: "W-2"), "W-2 Beta")
        XCTAssertNil(matchProject(folders: folders, query: "W-1")) // ambiguous (W-1 Alpha and W-10 Gamma)
        XCTAssertNil(matchProject(folders: folders, query: "X-1"))
        XCTAssertNil(matchProject(folders: folders, query: ""))
    }

    /// matchProjectResult is the single source of truth; resolve logic uses it.
    func testMatchProjectResult() {
        let folders = ["W-1 Alpha", "W-2 Beta", "W-10 Gamma"]
        if case .matched(let name) = matchProjectResult(folders: folders, query: "W-1 Alpha") {
            XCTAssertEqual(name, "W-1 Alpha")
        } else { XCTFail("Expected .matched") }
        if case .matched(let name) = matchProjectResult(folders: folders, query: "W-2") {
            XCTAssertEqual(name, "W-2 Beta")
        } else { XCTFail("Expected .matched") }
        guard case .ambiguous = matchProjectResult(folders: folders, query: "W-1") else {
            XCTFail("Expected .ambiguous")
            return
        }
        guard case .notFound = matchProjectResult(folders: folders, query: "X-1") else {
            XCTFail("Expected .notFound")
            return
        }
        guard case .notFound = matchProjectResult(folders: folders, query: "  ") else {
            XCTFail("Expected .notFound for whitespace")
            return
        }
    }
}
