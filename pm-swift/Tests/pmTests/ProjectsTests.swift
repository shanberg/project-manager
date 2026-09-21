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

    /// A query that is no code reads as a name: exact title first, then a title prefix, either
    /// case. A name two projects share is ambiguous, and the code still picks one out.
    func testMatchProjectResultByName() {
        let folders = ["S-004 Project Manager Tool", "W-1 Alpha", "W-2 Alpha", "W-3 Beta Site"]
        guard case .matched("S-004 Project Manager Tool") = matchProjectResult(folders: folders, query: "Project Manager Tool") else {
            return XCTFail("Expected the exact title to match")
        }
        guard case .matched("S-004 Project Manager Tool") = matchProjectResult(folders: folders, query: "project manager") else {
            return XCTFail("Expected a title prefix to match, in any case")
        }
        guard case .ambiguous = matchProjectResult(folders: folders, query: "Alpha") else {
            return XCTFail("Expected a shared name to be ambiguous")
        }
        guard case .matched("W-2 Alpha") = matchProjectResult(folders: folders, query: "W-2") else {
            return XCTFail("Expected the code to disambiguate")
        }
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

    /// A refusal names what would have worked: projects sharing a word with the query, with their codes,
    /// else the first few — so a session label taken for a project name gets an answer, not a dead end.
    func testClosestProjectNamesSuggestsRelatedThenAny() {
        let folders = ["W-1 Design Editor", "W-2 Design Tokens", "W-3 Invoices"]
        XCTAssertEqual(closestProjectNames(to: "General Work Design", in: folders),
                       ["Design Editor (W-1)", "Design Tokens (W-2)"])
        XCTAssertEqual(closestProjectNames(to: "General Work", in: folders, limit: 2),
                       ["Design Editor (W-1)", "Design Tokens (W-2)"])
        XCTAssertTrue(PmError.projectNotFoundAmong("x", candidates: ["Design Editor (W-1)"]).description
            .contains("Design Editor (W-1)"))
    }
}
