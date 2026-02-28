import XCTest
@testable import PmLib

final class ScaffoldTests: XCTestCase {
    /// createProject creates folder structure, subfolders, and notes file with correct title.
    func testCreateProjectCreatesStructureAndNotes() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let activePath = tmp.appendingPathComponent("active").path
        let archivePath = tmp.appendingPathComponent("archive").path
        try FileManager.default.createDirectory(atPath: activePath, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: archivePath, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let config = PmConfig(
            activePath: activePath,
            archivePath: archivePath,
            domains: defaultDomains,
            subfolders: defaultSubfolders
        )
        let paths = ResolvedPaths(activePath: activePath, archivePath: archivePath)

        let projectPath = try createProject(config: config, paths: paths, domainCode: "W", title: "Test Project")

        XCTAssertTrue(FileManager.default.fileExists(atPath: projectPath))
        XCTAssertEqual((projectPath as NSString).lastPathComponent, "W-1 Test Project", "Project folder name must be W-1 Test Project")
        for sub in defaultSubfolders {
            let subPath = (projectPath as NSString).appendingPathComponent(sub)
            var isDir: ObjCBool = false
            XCTAssertTrue(FileManager.default.fileExists(atPath: subPath, isDirectory: &isDir) && isDir.boolValue, "Subfolder \(sub) should exist")
        }
        let notesPath = getNotesPath(projectPath: projectPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: notesPath))
        let notesContent = try String(contentsOfFile: notesPath, encoding: .utf8)
        XCTAssertTrue(notesContent.contains("# Test Project"), "Notes should contain title")
    }

    /// createProject throws invalidProjectTitle when title contains path separators.
    func testCreateProjectThrowsWhenTitleContainsSlash() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let activePath = tmp.appendingPathComponent("active").path
        let archivePath = tmp.appendingPathComponent("archive").path
        try FileManager.default.createDirectory(atPath: activePath, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: archivePath, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let config = PmConfig(
            activePath: activePath,
            archivePath: archivePath,
            domains: defaultDomains,
            subfolders: defaultSubfolders
        )
        let paths = ResolvedPaths(activePath: activePath, archivePath: archivePath)

        XCTAssertThrowsError(try createProject(config: config, paths: paths, domainCode: "W", title: "Foo/Bar")) { err in
            guard case PmError.invalidProjectTitle(let t) = err else {
                XCTFail("Expected invalidProjectTitle, got \(err)")
                return
            }
            XCTAssertEqual(t, "Foo/Bar")
        }
    }

    func testCreateProjectThrowsWhenTitleContainsBackslash() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let activePath = tmp.appendingPathComponent("active").path
        let archivePath = tmp.appendingPathComponent("archive").path
        try FileManager.default.createDirectory(atPath: activePath, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: archivePath, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let config = PmConfig(
            activePath: activePath,
            archivePath: archivePath,
            domains: defaultDomains,
            subfolders: defaultSubfolders
        )
        let paths = ResolvedPaths(activePath: activePath, archivePath: archivePath)

        XCTAssertThrowsError(try createProject(config: config, paths: paths, domainCode: "W", title: "Foo\\Bar")) { err in
            guard case PmError.invalidProjectTitle(let t) = err else {
                XCTFail("Expected invalidProjectTitle, got \(err)")
                return
            }
            XCTAssertEqual(t, "Foo\\Bar")
        }
    }

    /// createProject throws notesTemplateNotFound when notesTemplatePath is set but the template file does not exist.
    func testCreateProjectThrowsWhenTemplatePathMissing() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let activePath = tmp.appendingPathComponent("active").path
        let archivePath = tmp.appendingPathComponent("archive").path
        let missingTemplate = tmp.appendingPathComponent("missing-template.md").path
        try FileManager.default.createDirectory(atPath: activePath, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: archivePath, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        var config = PmConfig(
            activePath: activePath,
            archivePath: archivePath,
            domains: defaultDomains,
            subfolders: defaultSubfolders
        )
        config.notesTemplatePath = missingTemplate
        let paths = ResolvedPaths(activePath: activePath, archivePath: archivePath)

        XCTAssertThrowsError(try createProject(config: config, paths: paths, domainCode: "W", title: "Test")) { err in
            guard case PmError.notesTemplateNotFound(let path) = err else {
                XCTFail("Expected notesTemplateNotFound, got \(err)")
                return
            }
            XCTAssertEqual(path, missingTemplate)
        }
    }
}
