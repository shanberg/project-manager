import XCTest
@testable import PmLib

final class NotesHelpersTests: XCTestCase {
    /// Contract: Swift formatSessionDate must match Raycast's formatSessionDate (en-US short).
    /// We build a date at noon UTC and assert the formatted string; in UTC and common zones (PST, etc.) this yields "Tue, Feb 25, 2025".
    /// So the test is deterministic across CI and local runs in those timezones.
    func testFormatSessionDateContract() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"), "UTC time zone should always be valid")
        let date = try XCTUnwrap(cal.date(from: DateComponents(year: 2025, month: 2, day: 25, hour: 12, minute: 0)), "Date components should yield a valid date")
        let formatted = formatSessionDate(date)
        XCTAssertEqual(formatted, "Tue, Feb 25, 2025", "Session date format must match Raycast (en-US short); change only with extension update")
    }

    // MARK: projectTitle

    /// A numbered project folder keeps behaving exactly as it did: the code prefix comes off.
    func testProjectTitleStripsNumberedPrefix() {
        XCTAssertEqual(projectTitle(fromFolderName: "W-12 Website Refresh"), "Website Refresh")
        XCTAssertEqual(projectTitle(fromFolderName: "H-004 Maxwell Carmody"), "Maxwell Carmody")
        XCTAssertEqual(projectTitle(fromFolderName: "W-1 Website"), "Website")
    }

    /// The Areas case. An unprefixed folder is its own title — splitting on the first space turned
    /// "Team 1:1s" into "1:1s", which sent getNotesPath at "docs/Notes - 1:1s.md".
    func testProjectTitleKeepsUnprefixedNameWhole() {
        XCTAssertEqual(projectTitle(fromFolderName: "Team 1:1s"), "Team 1:1s")
        XCTAssertEqual(projectTitle(fromFolderName: "Home maintenance"), "Home maintenance")
        XCTAssertEqual(projectTitle(fromFolderName: "Hiring"), "Hiring")
    }

    /// Near misses on the prefix grammar are names, not prefixes: no number, no separating space,
    /// or a hyphenated word rather than a code.
    func testProjectTitleIgnoresNonPrefixes() {
        XCTAssertEqual(projectTitle(fromFolderName: "W- Website Refresh"), "W- Website Refresh")
        XCTAssertEqual(projectTitle(fromFolderName: "W-12"), "W-12")
        XCTAssertEqual(projectTitle(fromFolderName: "On-call rotation"), "On-call rotation")
    }

    /// The whole point of the fix, at the level it actually broke: where the notes file goes.
    func testNotesPathForUnprefixedFolder() {
        XCTAssertEqual(getNotesPath(projectPath: "/PARA/areas/Team 1:1s"),
                       "/PARA/areas/Team 1:1s/docs/Notes - Team 1:1s.md")
        XCTAssertEqual(getNotesPath(projectPath: "/PARA/active/W-12 Website Refresh"),
                       "/PARA/active/W-12 Website Refresh/docs/Notes - Website Refresh.md")
    }

    func testParseSessionDateArgumentValid() throws {
        let date = try parseSessionDateArgument("2025-02-25")
        let formatted = formatSessionDate(date)
        XCTAssertTrue(formatted.contains("2025"), "formatted date should contain year: \(formatted)")
        XCTAssertTrue(formatted.contains("Feb"), "formatted date should contain month: \(formatted)")
    }

    func testParseSessionDateArgumentInvalidThrows() {
        XCTAssertThrowsError(try parseSessionDateArgument("not-a-date")) { err in
            guard case PmError.invalidSessionDate(let value) = err else {
                XCTFail("Expected invalidSessionDate, got \(err)")
                return
            }
            XCTAssertEqual(value, "not-a-date")
        }
    }

    /// getNotesTemplateContent throws notesTemplateNotFound when template path is set but file does not exist.
    func testGetNotesTemplateContentThrowsWhenFileMissing() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let missingPath = tmp.appendingPathComponent("nonexistent-template.md").path
        XCTAssertThrowsError(try getNotesTemplateContent(templatePath: missingPath, title: "Test")) { err in
            guard case PmError.notesTemplateNotFound(let path) = err else {
                XCTFail("Expected notesTemplateNotFound, got \(err)")
                return
            }
            XCTAssertEqual(path, missingPath)
        }
    }

    /// When docs/ does not exist, resolveNotesPath returns nil (no throw; treated as "no notes").
    func testResolveNotesPathReturnsNilWhenDocsMissing() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let projectPath = tmp.appendingPathComponent("W-1 Some Project").path
        try FileManager.default.createDirectory(atPath: projectPath, withIntermediateDirectories: true)
        let result = try resolveNotesPath(projectPath: projectPath)
        XCTAssertNil(result)
    }

    /// projectTitle extracts title after first space; falls back to full name when no space.
    func testProjectTitleFromFolderName() {
        XCTAssertEqual(projectTitle(fromFolderName: "W-1 My Project"), "My Project")
        XCTAssertEqual(projectTitle(fromFolderName: "P-01 Personal"), "Personal")
        XCTAssertEqual(projectTitle(fromFolderName: "W-1"), "W-1")
    }

    /// When canonical notes file exists, resolveNotesPath returns it.
    func testResolveNotesPathReturnsCanonicalWhenExists() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let projectPath = tmp.appendingPathComponent("W-1 Some Project").path
        let docsPath = (projectPath as NSString).appendingPathComponent("docs")
        let notesPath = (docsPath as NSString).appendingPathComponent("Notes - Some Project.md")
        try FileManager.default.createDirectory(atPath: docsPath, withIntermediateDirectories: true)
        try Data().write(to: URL(fileURLWithPath: notesPath))
        let result = try resolveNotesPath(projectPath: projectPath)
        XCTAssertEqual(result, notesPath)
    }

    /// When multiple Notes - *.md exist and canonical is one of them, resolveNotesPath returns canonical.
    func testResolveNotesPathMultipleFilesReturnsCanonicalWhenPresent() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let projectPath = tmp.appendingPathComponent("W-1 Some Project").path
        let docsPath = (projectPath as NSString).appendingPathComponent("docs")
        let canonicalPath = (docsPath as NSString).appendingPathComponent("Notes - Some Project.md")
        let otherPath = (docsPath as NSString).appendingPathComponent("Notes - Other Title.md")
        try FileManager.default.createDirectory(atPath: docsPath, withIntermediateDirectories: true)
        try Data().write(to: URL(fileURLWithPath: canonicalPath))
        try Data().write(to: URL(fileURLWithPath: otherPath))
        let result = try resolveNotesPath(projectPath: projectPath)
        XCTAssertEqual(result, canonicalPath, "When multiple notes files exist, canonical (Notes - <title>.md) should be preferred")
    }

    /// When multiple Notes - *.md exist but canonical is not among them, resolveNotesPath returns one of them.
    /// Which file is returned is implementation-defined (order of contentsOfDirectory); we only assert one is returned.
    func testResolveNotesPathMultipleFilesReturnsOneWhenCanonicalMissing() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        // Folder name "W-1 Some Project" => canonical would be "Notes - Some Project.md"; we create different files.
        let projectPath = tmp.appendingPathComponent("W-1 Some Project").path
        let docsPath = (projectPath as NSString).appendingPathComponent("docs")
        let notesA = (docsPath as NSString).appendingPathComponent("Notes - Alpha.md")
        let notesB = (docsPath as NSString).appendingPathComponent("Notes - Beta.md")
        try FileManager.default.createDirectory(atPath: docsPath, withIntermediateDirectories: true)
        try Data().write(to: URL(fileURLWithPath: notesA))
        try Data().write(to: URL(fileURLWithPath: notesB))
        let result = try resolveNotesPath(projectPath: projectPath)
        XCTAssertNotNil(result)
        XCTAssertTrue(result == notesA || result == notesB, "Should return one of the notes files when canonical is missing")
    }
}
