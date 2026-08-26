import XCTest
import PmLib

final class ProjectMoveTests: XCTestCase {
    /// A temp active/archive pair with one project folder in `active`.
    private func makeFixture(project: String = "W-1 Website Refresh")
        throws -> (paths: ResolvedPaths, root: String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        let activePath = (root as NSString).appendingPathComponent("active")
        let archivePath = (root as NSString).appendingPathComponent("archive")
        let fm = FileManager.default
        try fm.createDirectory(atPath: (activePath as NSString).appendingPathComponent(project),
                               withIntermediateDirectories: true)
        try fm.createDirectory(atPath: archivePath, withIntermediateDirectories: true)
        return (ResolvedPaths(activePath: activePath, archivePath: archivePath), root)
    }

    func testArchiveMovesTheFolder() throws {
        let (paths, root) = try makeFixture()
        defer { try? FileManager.default.removeItem(atPath: root) }

        let destination = try moveProject(named: "W-1 Website Refresh", from: .active, to: .archive,
                                          paths: paths)

        XCTAssertEqual(destination,
                       (paths.archivePath as NSString).appendingPathComponent("W-1 Website Refresh"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: (paths.activePath as NSString).appendingPathComponent("W-1 Website Refresh")))
    }

    func testUnarchiveIsTheSameMoveReversed() throws {
        let (paths, root) = try makeFixture()
        defer { try? FileManager.default.removeItem(atPath: root) }

        try moveProject(named: "W-1 Website Refresh", from: .active, to: .archive, paths: paths)
        try moveProject(named: "W-1 Website Refresh", from: .archive, to: .active, paths: paths)

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: (paths.activePath as NSString).appendingPathComponent("W-1 Website Refresh")))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: (paths.archivePath as NSString).appendingPathComponent("W-1 Website Refresh")))
    }

    func testProjectContentsSurviveTheMove() throws {
        let (paths, root) = try makeFixture()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let notes = (paths.activePath as NSString)
            .appendingPathComponent("W-1 Website Refresh/docs/Notes - Website Refresh.md")
        try FileManager.default.createDirectory(
            atPath: (notes as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try "# Website Refresh".write(toFile: notes, atomically: true, encoding: .utf8)

        let destination = try moveProject(named: "W-1 Website Refresh", from: .active, to: .archive,
                                          paths: paths)

        let moved = (destination as NSString).appendingPathComponent("docs/Notes - Website Refresh.md")
        XCTAssertEqual(try String(contentsOfFile: moved, encoding: .utf8), "# Website Refresh")
    }

    func testMissingProjectThrowsProjectNotFound() throws {
        let (paths, root) = try makeFixture()
        defer { try? FileManager.default.removeItem(atPath: root) }

        XCTAssertThrowsError(try moveProject(named: "W-9 Nope", from: .active, to: .archive,
                                             paths: paths)) { error in
            guard case PmError.projectNotFound(let name) = error else {
                return XCTFail("Expected projectNotFound, got \(error)")
            }
            XCTAssertEqual(name, "W-9 Nope")
        }
    }

    /// A name present in both folders must not be moved onto the other copy — that would be a silent
    /// merge of two projects, or a POSIX error that says nothing about projects.
    func testNameAlreadyInDestinationThrows() throws {
        let (paths, root) = try makeFixture()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(
            atPath: (paths.archivePath as NSString).appendingPathComponent("W-1 Website Refresh"),
            withIntermediateDirectories: true)

        XCTAssertThrowsError(try moveProject(named: "W-1 Website Refresh", from: .active, to: .archive,
                                             paths: paths)) { error in
            guard case PmError.moveTargetExists = error else {
                return XCTFail("Expected moveTargetExists, got \(error)")
            }
        }
        // The original must still be where it was.
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: (paths.activePath as NSString).appendingPathComponent("W-1 Website Refresh")))
    }

    /// `opposite` is gone — it only worked while there were two roots. Where a folder comes back to is
    /// now a question about the folder, answered in AreasScopeTests.
    func testScopePaths() throws {
        let (paths, root) = try makeFixture()
        defer { try? FileManager.default.removeItem(atPath: root) }
        XCTAssertEqual(ProjectScope.active.path(in: paths), paths.activePath)
        XCTAssertEqual(ProjectScope.archive.path(in: paths), paths.archivePath)
        XCTAssertEqual(ProjectScope.areas.path(in: paths), paths.areasPath)
    }
}
