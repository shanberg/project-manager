import XCTest
@testable import PmLib

/// Making an Area, and the template both kinds are built from.
final class AreaCreateTests: XCTestCase {

    private func makeVault() throws -> (PmConfig, ResolvedPaths, String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        for sub in ["active", "archive"] {
            try FileManager.default.createDirectory(atPath: (root as NSString).appendingPathComponent(sub),
                                                    withIntermediateDirectories: true)
        }
        let paths = ResolvedPaths(activePath: (root as NSString).appendingPathComponent("active"),
                                  archivePath: (root as NSString).appendingPathComponent("archive"),
                                  areasPath: (root as NSString).appendingPathComponent("areas"))
        let config = PmConfig(activePath: paths.activePath, archivePath: paths.archivePath,
                              domains: defaultDomains, subfolders: defaultSubfolders)
        return (config, paths, root)
    }

    // MARK: The template

    /// The generated project template must be byte-for-byte what the literal used to be. Generation
    /// exists so the section vocabulary is stated once, and it is only worth it if nobody's existing
    /// documents change shape because of it.
    func testProjectTemplateIsUnchanged() {
        let expected = """
        # {{title}}

        > [!summary] Summary
        > 


        > [!question] Problem
        > 


        > [!info] Goals
        > 1.  
        > 2.  
        > 3.  


        > [!info] Approach
        > 


        ## Links

        - 

        ## Learnings

        - 

        ## Sessions

        """
        XCTAssertEqual(notesTemplate(for: .project), expected)
    }

    func testAreaTemplateHasNoProblemOrApproach() throws {
        let template = notesTemplate(for: .area)
        XCTAssertTrue(template.contains("> [!summary] Summary"))
        XCTAssertTrue(template.contains("> [!info] Goals"))
        XCTAssertFalse(template.contains("Problem"))
        XCTAssertFalse(template.contains("Approach"))

        // And it's a document PM can read back, which is the only thing that makes it a template.
        let notes = try parseNotes(markdown: template.replacingOccurrences(of: "{{title}}", with: "Hiring"))
        XCTAssertEqual(notes.title, "Hiring")
        XCTAssertEqual(notes.goals.count, 3)
        XCTAssertTrue(notes.problem.isEmpty)
    }

    // MARK: Creating

    func testCreatingAnAreaMakesTheRootItNeeds() throws {
        let (config, paths, root) = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.areasPath),
                       "the fixture deliberately has no areas/ — a vault that never made one")

        let path = try createProject(config: config, paths: paths, kind: .area, title: "Team 1:1s")

        XCTAssertEqual(path, (paths.areasPath as NSString).appendingPathComponent("Team 1:1s"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent("docs")))
        XCTAssertTrue(FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent("resources")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent("deliverables")),
                       "an area doesn't ship")
        XCTAssertTrue(FileManager.default.fileExists(atPath: getNotesPath(projectPath: path)),
                      "the notes file has to land at the name projectTitle derives, not a truncated one")
        XCTAssertEqual(try getAreaFolders(basePath: paths.areasPath), ["Team 1:1s"])
    }

    /// An area draws no number, so nothing stops a second one taking the same folder — except this.
    func testASecondAreaOfTheSameNameIsRefused() throws {
        let (config, paths, root) = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        _ = try createProject(config: config, paths: paths, kind: .area, title: "Hiring")
        let notes = getNotesPath(projectPath: (paths.areasPath as NSString).appendingPathComponent("Hiring"))
        try "# Hiring\n\nsomething I wrote\n".write(toFile: notes, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try createProject(config: config, paths: paths, kind: .area, title: "Hiring")) { err in
            guard case PmError.areaAlreadyExists = err else { return XCTFail("expected areaAlreadyExists, got \(err)") }
        }
        XCTAssertTrue(try String(contentsOfFile: notes, encoding: .utf8).contains("something I wrote"),
                      "the refusal is the point — the second create would have written over this")
    }

    /// Areas take no numbers, so creating one must not move the sequence on.
    func testAreasDoNotConsumeProjectNumbers() throws {
        let (config, paths, root) = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        _ = try createProject(config: config, paths: paths, domainCode: "W", title: "First")
        _ = try createProject(config: config, paths: paths, kind: .area, title: "Hiring")
        let third = try createProject(config: config, paths: paths, domainCode: "W", title: "Second")
        XCTAssertTrue((third as NSString).lastPathComponent.hasPrefix("W-2 "),
                      "expected W-2, got \((third as NSString).lastPathComponent)")
    }

    func testADomainIsRequiredForProjectsAndRefusedForAreas() throws {
        let (config, paths, root) = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        XCTAssertThrowsError(try createProject(config: config, paths: paths, kind: .area,
                                               domainCode: "W", title: "Hiring")) { err in
            guard case PmError.domainNotApplicable = err else { return XCTFail("got \(err)") }
        }
        XCTAssertThrowsError(try createProject(config: config, paths: paths, title: "No domain")) { err in
            guard case PmError.domainNotApplicable = err else { return XCTFail("got \(err)") }
        }
    }

    func testDryRunCreatesNothing() throws {
        let (config, paths, root) = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let path = try createProject(config: config, paths: paths, kind: .area, title: "Hiring", dryRun: true)
        XCTAssertEqual((path as NSString).lastPathComponent, "Hiring")
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    // MARK: Renaming an area

    /// An area's name *is* its title, so a rename is just the folder moving — there's no prefix to keep.
    /// This used to throw `projectFolderMalformed`, while the app cheerfully offered the command.
    func testRenamingAnAreaMovesTheWholeName() throws {
        let (config, paths, root) = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        setenv("PM_CONFIG_HOME", root, 1)
        defer { unsetenv("PM_CONFIG_HOME") }
        try saveConfig(PmConfig(activePath: paths.activePath, archivePath: paths.archivePath,
                                areasPath: paths.areasPath, domains: config.domains,
                                subfolders: config.subfolders))

        _ = try createProject(config: config, paths: paths, kind: .area, title: "Team 1:1s")
        let newName = try renameProjectTitle(nameOrPrefix: "Team 1:1s", newTitle: "Team One-on-Ones")

        XCTAssertEqual(newName, "Team One-on-Ones", "an area's new folder name is just its new title")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: (paths.areasPath as NSString).appendingPathComponent("Team One-on-Ones")))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: (paths.areasPath as NSString).appendingPathComponent("Team 1:1s")))
    }

    /// A project still keeps its number: renaming is not renumbering.
    func testRenamingAProjectStillKeepsItsPrefix() throws {
        let (config, paths, root) = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        setenv("PM_CONFIG_HOME", root, 1)
        defer { unsetenv("PM_CONFIG_HOME") }
        try saveConfig(PmConfig(activePath: paths.activePath, archivePath: paths.archivePath,
                                areasPath: paths.areasPath, domains: config.domains,
                                subfolders: config.subfolders))

        _ = try createProject(config: config, paths: paths, domainCode: "W", title: "Website")
        XCTAssertEqual(try renameProjectTitle(nameOrPrefix: "W-1", newTitle: "Website Refresh"),
                       "W-1 Website Refresh")
    }

    // MARK: Taking on a folder you already keep

    /// Adopting writes the notes file and nothing else. The folder is already organized the way its
    /// owner organizes things; a command that tidied it in passing would be a worse deal than one that
    /// left it alone.
    func testAdoptingWritesNotesAndTouchesNothingElse() throws {
        let (config, paths, root) = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let folder = (paths.areasPath as NSString).appendingPathComponent("Work")
        try FileManager.default.createDirectory(atPath: (folder as NSString).appendingPathComponent("standups"),
                                                withIntermediateDirectories: true)
        let existing = (folder as NSString).appendingPathComponent("standups/2026.md")
        try "a file I already keep\n".write(toFile: existing, atomically: true, encoding: .utf8)

        let notesPath = try adoptArea(config: config, paths: paths, folderName: "Work")

        XCTAssertEqual(notesPath, getNotesPath(projectPath: folder))
        XCTAssertTrue(FileManager.default.fileExists(atPath: notesPath))
        XCTAssertEqual(try String(contentsOfFile: existing, encoding: .utf8), "a file I already keep\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: (folder as NSString).appendingPathComponent("resources")),
                       "adopting must not impose the scaffold on a folder that already has a shape")
        XCTAssertEqual(try getAreaFolders(basePath: paths.areasPath), ["Work"])
        XCTAssertEqual(try getAdoptableFolders(basePath: paths.areasPath), [])
    }

    /// The notes it writes are an area's, not a project's.
    func testAnAdoptedFolderGetsTheAreaHeader() throws {
        let (config, paths, root) = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(atPath: (paths.areasPath as NSString).appendingPathComponent("Team 1:1s"),
                                                withIntermediateDirectories: true)
        let notesPath = try adoptArea(config: config, paths: paths, folderName: "Team 1:1s")
        let notes = try String(contentsOfFile: notesPath, encoding: .utf8)
        XCTAssertTrue(notes.contains("# Team 1:1s"))
        XCTAssertTrue(notes.contains("> [!info] Goals"))
        XCTAssertFalse(notes.contains("Problem"))
    }

    /// `getAdoptableFolders` is the exact complement of `getAreaFolders` over the same set — every
    /// area-shaped folder is in one list or the other, never both, never neither.
    func testAdoptableAndAdoptedPartitionTheFolder() throws {
        let (config, paths, root) = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        for name in ["Work", "Kids", "Marriage"] {
            try FileManager.default.createDirectory(atPath: (paths.areasPath as NSString).appendingPathComponent(name),
                                                    withIntermediateDirectories: true)
        }
        _ = try adoptArea(config: config, paths: paths, folderName: "Kids")

        let adopted = try getAreaFolders(basePath: paths.areasPath)
        let adoptable = try getAdoptableFolders(basePath: paths.areasPath)
        XCTAssertEqual(adopted, ["Kids"])
        XCTAssertEqual(adoptable, ["Marriage", "Work"])
        XCTAssertTrue(Set(adopted).isDisjoint(with: adoptable))
        XCTAssertEqual(Set(adopted).union(adoptable), ["Work", "Kids", "Marriage"])
    }

    func testAdoptingRefusesWhatItShould() throws {
        let (config, paths, root) = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(atPath: (paths.areasPath as NSString).appendingPathComponent("Work"),
                                                withIntermediateDirectories: true)

        // Nothing there by that name.
        XCTAssertThrowsError(try adoptArea(config: config, paths: paths, folderName: "Nope"))
        // A numbered name is a project's, and this doesn't make projects.
        XCTAssertThrowsError(try adoptArea(config: config, paths: paths, folderName: "W-1 Website"))
        // Already an area — adopting twice would overwrite the notes it made the first time.
        _ = try adoptArea(config: config, paths: paths, folderName: "Work")
        try "written since\n".write(toFile: getNotesPath(projectPath: (paths.areasPath as NSString).appendingPathComponent("Work")),
                                    atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try adoptArea(config: config, paths: paths, folderName: "Work"))
        XCTAssertEqual(try String(contentsOfFile: getNotesPath(projectPath: (paths.areasPath as NSString).appendingPathComponent("Work")),
                                  encoding: .utf8), "written since\n",
                       "the refusal is the point — a second adopt would have overwritten this")
    }

    func testAdoptDryRunCreatesNothing() throws {
        let (config, paths, root) = try makeVault()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let folder = (paths.areasPath as NSString).appendingPathComponent("Work")
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)

        let notesPath = try adoptArea(config: config, paths: paths, folderName: "Work", dryRun: true)
        XCTAssertEqual(notesPath, getNotesPath(projectPath: folder))
        XCTAssertFalse(FileManager.default.fileExists(atPath: notesPath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: (folder as NSString).appendingPathComponent("docs")))
    }
}
