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
}
