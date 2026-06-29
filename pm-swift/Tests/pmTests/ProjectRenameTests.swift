import XCTest
import PmLib

final class ProjectRenameTests: XCTestCase {
    func testParseProjectPrefixAndTitleW() throws {
        let p = try parseProjectPrefixAndTitle(folderName: "W-1 My Project", domainCodes: ["W", "P"])
        XCTAssertEqual(p.prefix, "W-1")
        XCTAssertEqual(p.title, "My Project")
    }

    func testParseProjectPrefixAndTitleMultiDigit() throws {
        let p = try parseProjectPrefixAndTitle(folderName: "W-12 Beta", domainCodes: ["W"])
        XCTAssertEqual(p.prefix, "W-12")
        XCTAssertEqual(p.title, "Beta")
    }

    func testParseProjectPrefixPrefersLongerDomain() throws {
        let p = try parseProjectPrefixAndTitle(folderName: "DE-3 X", domainCodes: ["D", "DE"])
        XCTAssertEqual(p.prefix, "DE-3")
        XCTAssertEqual(p.title, "X")
    }

    func testParseProjectPrefixMalformedThrows() {
        XCTAssertThrowsError(try parseProjectPrefixAndTitle(folderName: "W-1", domainCodes: ["W"])) { err in
            guard case PmError.projectFolderMalformed(let name) = err else {
                XCTFail("Expected projectFolderMalformed, got \(err)")
                return
            }
            XCTAssertEqual(name, "W-1")
        }
    }

    /// Uses setenv(PM_CONFIG_HOME); do not run in parallel with other code that reads PM_CONFIG_HOME.
    func testRenameProjectTitleMovesFolderAndUpdatesNotes() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        let configDir = (tmp as NSString).appendingPathComponent("pmcfg")
        let activePath = (tmp as NSString).appendingPathComponent("active")
        let archivePath = (tmp as NSString).appendingPathComponent("archive")
        try FileManager.default.createDirectory(atPath: configDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: activePath, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: archivePath, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let configObj: [String: Any] = [
            "activePath": activePath,
            "archivePath": archivePath,
            "domains": ["W": "Work", "P": "Personal"],
            "subfolders": ["docs"],
        ]
        let configData = try JSONSerialization.data(withJSONObject: configObj)
        let configPath = (configDir as NSString).appendingPathComponent("config.json")
        try configData.write(to: URL(fileURLWithPath: configPath))

        let projectDir = (activePath as NSString).appendingPathComponent("W-1 Old Name")
        try FileManager.default.createDirectory(atPath: projectDir, withIntermediateDirectories: true)
        let docsPath = (projectDir as NSString).appendingPathComponent("docs")
        try FileManager.default.createDirectory(atPath: docsPath, withIntermediateDirectories: true)
        let notesPath = (docsPath as NSString).appendingPathComponent("Notes - Old Name.md")
        let templateContent = try getNotesTemplateContent(templatePath: nil, title: "Old Name")
        try templateContent.write(toFile: notesPath, atomically: true, encoding: .utf8)

        let saved = ProcessInfo.processInfo.environment["PM_CONFIG_HOME"]
        setenv("PM_CONFIG_HOME", configDir, 1)
        defer {
            if let s = saved {
                setenv("PM_CONFIG_HOME", s, 1)
            } else {
                unsetenv("PM_CONFIG_HOME")
            }
        }

        let out = try renameProjectTitle(nameOrPrefix: "W-1", newTitle: "New Name")
        XCTAssertEqual(out, "W-1 New Name")

        let newDir = (activePath as NSString).appendingPathComponent("W-1 New Name")
        XCTAssertTrue(FileManager.default.fileExists(atPath: newDir))
        XCTAssertFalse(FileManager.default.fileExists(atPath: projectDir))

        let newNotes = (newDir as NSString).appendingPathComponent("docs/Notes - New Name.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: newNotes))
        let body = try String(contentsOfFile: newNotes, encoding: .utf8)
        XCTAssertTrue(body.hasPrefix("# New Name\n"), "H1 should match new title: \(body.prefix(40))")
    }

    /// Rename must update the title line only, preserving frontmatter, callouts, and spacing in the notes file.
    /// Uses setenv(PM_CONFIG_HOME); do not run in parallel with other code that reads PM_CONFIG_HOME.
    func testRenamePreservesNotesFormatting() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        let configDir = (tmp as NSString).appendingPathComponent("pmcfg")
        let activePath = (tmp as NSString).appendingPathComponent("active")
        let archivePath = (tmp as NSString).appendingPathComponent("archive")
        try FileManager.default.createDirectory(atPath: configDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: activePath, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: archivePath, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let configObj: [String: Any] = [
            "activePath": activePath,
            "archivePath": archivePath,
            "domains": ["W": "Work"],
            "subfolders": ["docs"],
        ]
        try JSONSerialization.data(withJSONObject: configObj).write(to: URL(fileURLWithPath: (configDir as NSString).appendingPathComponent("config.json")))

        let projectDir = (activePath as NSString).appendingPathComponent("W-1 Old Name")
        let docsPath = (projectDir as NSString).appendingPathComponent("docs")
        try FileManager.default.createDirectory(atPath: docsPath, withIntermediateDirectories: true)
        let messy = """
        ---
        tags: [keep-me]
        ---
        # Old Name

        > [!summary] Summary
        > A summary.
        >
        > Second paragraph.

        > [!info] Goals
        > 1.   Weird spacing
        > 2.  Two
        > 3.  Three

        ## Links

        - https://example.com

        ## Learnings

        - Something

        ## Sessions

        ### Wed, Feb 25, 2025

        - [ ] A task
        """
        let notesPath = (docsPath as NSString).appendingPathComponent("Notes - Old Name.md")
        try messy.write(toFile: notesPath, atomically: true, encoding: .utf8)

        let saved = ProcessInfo.processInfo.environment["PM_CONFIG_HOME"]
        setenv("PM_CONFIG_HOME", configDir, 1)
        defer {
            if let s = saved { setenv("PM_CONFIG_HOME", s, 1) } else { unsetenv("PM_CONFIG_HOME") }
        }

        _ = try renameProjectTitle(nameOrPrefix: "W-1", newTitle: "New Name")

        let newNotes = (activePath as NSString).appendingPathComponent("W-1 New Name/docs/Notes - New Name.md")
        let body = try String(contentsOfFile: newNotes, encoding: .utf8)

        // Title updated, everything else byte-preserved.
        XCTAssertEqual(body, messy.replacingOccurrences(of: "# Old Name", with: "# New Name"),
                       "Only the H1 title line should change; all other formatting preserved")
    }

    func testRenameProjectTitleNoOpWhenSameTitle() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        let configDir = (tmp as NSString).appendingPathComponent("pmcfg")
        let activePath = (tmp as NSString).appendingPathComponent("active")
        let archivePath = (tmp as NSString).appendingPathComponent("archive")
        try FileManager.default.createDirectory(atPath: configDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: activePath, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: archivePath, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let configObj: [String: Any] = [
            "activePath": activePath,
            "archivePath": archivePath,
            "domains": ["W": "Work"],
            "subfolders": ["docs"],
        ]
        try JSONSerialization.data(withJSONObject: configObj).write(to: URL(fileURLWithPath: (configDir as NSString).appendingPathComponent("config.json")))

        let projectDir = (activePath as NSString).appendingPathComponent("W-1 Same")
        try FileManager.default.createDirectory(atPath: projectDir, withIntermediateDirectories: true)

        let saved = ProcessInfo.processInfo.environment["PM_CONFIG_HOME"]
        setenv("PM_CONFIG_HOME", configDir, 1)
        defer {
            if let s = saved {
                setenv("PM_CONFIG_HOME", s, 1)
            } else {
                unsetenv("PM_CONFIG_HOME")
            }
        }

        let out = try renameProjectTitle(nameOrPrefix: "W-1", newTitle: "Same")
        XCTAssertEqual(out, "W-1 Same")
    }
}
