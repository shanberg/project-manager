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
}
