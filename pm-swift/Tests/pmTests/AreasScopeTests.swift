import XCTest
@testable import PmLib

/// The three roots, the scan that finds Areas, and the question that replaced `ProjectScope.opposite`.
final class AreasScopeTests: XCTestCase {

    private func makeVault() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        for sub in ["active", "archive", "areas"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        return root
    }

    /// A folder with a notes file in it, the way `createProject` leaves one.
    private func makeFolder(_ name: String, in parent: URL, withNotes: Bool = true) throws {
        let folder = parent.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("docs"), withIntermediateDirectories: true)
        if withNotes {
            let title = projectTitle(fromFolderName: name)
            try "# \(title)\n".write(to: folder.appendingPathComponent("docs/Notes - \(title).md"),
                                     atomically: true, encoding: .utf8)
        }
    }

    // MARK: Which kind a folder is

    /// The kind is read off the name, which is what lets both kinds share one archive.
    func testKindIsDerivedFromTheFolderName() {
        XCTAssertEqual(ProjectKind.of(folderName: "W-12 Website Refresh"), .project)
        XCTAssertEqual(ProjectKind.of(folderName: "H-004 Maxwell Carmody"), .project)
        XCTAssertEqual(ProjectKind.of(folderName: "Team 1:1s"), .area)
        XCTAssertEqual(ProjectKind.of(folderName: "Hiring"), .area)
        XCTAssertEqual(ProjectKind.of(folderName: "On-call rotation"), .area)
    }

    /// The question `opposite` used to answer, and the reason it couldn't once there were three roots:
    /// both kinds archive into the same folder, and only the name says what comes back out where.
    func testArchivedFoldersStillKnowWhereTheyBelong() {
        XCTAssertEqual(ProjectKind.of(folderName: "W-12 Website Refresh").homeScope, .active)
        XCTAssertEqual(ProjectKind.of(folderName: "Team 1:1s").homeScope, .areas)
        XCTAssertFalse(ProjectScope.active.isArchived)
        XCTAssertFalse(ProjectScope.areas.isArchived)
        XCTAssertTrue(ProjectScope.archive.isArchived)
    }

    // MARK: Resolving the third root

    func testAreasPathFallsBesideActiveWhenNothingSaysOtherwise() throws {
        let config = PmConfig(activePath: "/PARA/active", archivePath: "/PARA/archive",
                              domains: defaultDomains, subfolders: defaultSubfolders)
        let paths = try resolvePaths(config: config, environment: [:])
        XCTAssertEqual(paths.areasPath, "/PARA/areas")
    }

    func testAreasPathPrefersParaPathOverTheGuess() throws {
        let config = PmConfig(paraPath: "/Vault", activePath: "/elsewhere/active", archivePath: "/elsewhere/archive",
                              domains: defaultDomains, subfolders: defaultSubfolders)
        let paths = try resolvePaths(config: config, environment: [:])
        XCTAssertEqual(paths.areasPath, "/Vault/areas")
    }

    func testExplicitAreasPathWinsOverEverything() throws {
        let config = PmConfig(paraPath: "/Vault", activePath: "/PARA/active", archivePath: "/PARA/archive",
                              areasPath: "/somewhere/else", domains: defaultDomains, subfolders: defaultSubfolders)
        let paths = try resolvePaths(config: config, environment: [:])
        XCTAssertEqual(paths.areasPath, "/somewhere/else")
    }

    /// Every config written before Areas existed has areasPath unset, and has to keep resolving.
    func testAConfigWithoutAreasStillResolves() throws {
        let config = PmConfig(activePath: "~/PARA/active", archivePath: "~/PARA/archive",
                              domains: defaultDomains, subfolders: defaultSubfolders)
        let paths = try resolvePaths(config: config, environment: [:])
        XCTAssertFalse(paths.areasPath.isEmpty)
        XCTAssertFalse(paths.areasPath.hasPrefix("~"), "the areas path should be expanded like the others")
    }

    // MARK: The scan

    func testAreaScanFindsFoldersWithNotes() throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let areas = root.appendingPathComponent("areas")
        try makeFolder("Team 1:1s", in: areas)
        try makeFolder("Hiring", in: areas)

        XCTAssertEqual(try getAreaFolders(basePath: areas.path), ["Hiring", "Team 1:1s"])
    }

    /// A folder someone put in areas/ for their own reasons isn't an Area. Notes are what make one.
    func testAreaScanIgnoresFoldersWithoutNotes() throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let areas = root.appendingPathComponent("areas")
        try makeFolder("Team 1:1s", in: areas)
        try makeFolder("Scanned receipts", in: areas, withNotes: false)

        XCTAssertEqual(try getAreaFolders(basePath: areas.path), ["Team 1:1s"])
    }

    /// The ordinary state of every vault that hasn't made an Area yet.
    func testAreaScanOfAMissingFolderIsEmptyNotAnError() throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = root.appendingPathComponent("no-such-folder").path
        XCTAssertEqual(try getAreaFolders(basePath: missing), [])
    }

    /// Areas don't take part in numbering, and the project scan is what enforces that: an unnumbered
    /// folder is not a project even when it's sitting in the archive next to real ones.
    func testProjectScanSkipsAreasInTheSharedArchive() throws {
        let root = try makeVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = root.appendingPathComponent("archive")
        try makeFolder("W-4 Old Thing", in: archive)
        try makeFolder("Team 1:1s", in: archive)

        XCTAssertEqual(try getProjectFolders(basePath: archive.path, domainCodes: Array(defaultDomains.keys)),
                       ["W-4 Old Thing"])
        XCTAssertEqual(try getAreaFolders(basePath: archive.path), ["Team 1:1s"],
                       "the area scan must leave archived projects alone — they share one archive")
    }

    // MARK: Scaffold

    func testAreasGetTheirOwnScaffold() {
        let config = PmConfig(activePath: "/a", archivePath: "/b", domains: defaultDomains, subfolders: defaultSubfolders)
        XCTAssertEqual(ProjectKind.project.subfolders(in: config), defaultSubfolders)
        XCTAssertEqual(ProjectKind.area.subfolders(in: config), ["docs", "resources"])
        XCTAssertFalse(ProjectKind.area.subfolders(in: config).contains("deliverables"))
    }

    func testConfiguredAreaSubfoldersWin() {
        var config = PmConfig(activePath: "/a", archivePath: "/b", domains: defaultDomains, subfolders: defaultSubfolders)
        config.areaSubfolders = ["notes"]
        XCTAssertEqual(ProjectKind.area.subfolders(in: config), ["notes"])
    }

    // MARK: How the derived folder is spelled

    /// A PARA vault laid out as `Projects` / `Archive` / `Areas` has already chosen the spelling, and a
    /// derived path shouldn't argue with it. On a case-insensitive volume the disagreement is invisible
    /// to `fileExists` and highly visible in every message and payload that prints the path; on a
    /// case-sensitive one PM would make a second directory beside the first.
    func testTheDerivedAreasFolderTakesTheSpellingOnDisk() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath: root) }
        for sub in ["Projects", "Archive", "Areas"] {
            try FileManager.default.createDirectory(atPath: (root as NSString).appendingPathComponent(sub),
                                                    withIntermediateDirectories: true)
        }
        let config = PmConfig(paraPath: root,
                              activePath: (root as NSString).appendingPathComponent("Projects"),
                              archivePath: (root as NSString).appendingPathComponent("Archive"),
                              domains: defaultDomains, subfolders: defaultSubfolders)
        let paths = try resolvePaths(config: config, environment: [:])
        XCTAssertEqual((paths.areasPath as NSString).lastPathComponent, "Areas")
    }

    /// Beside the active folder, the same way.
    func testTheGuessBesideActiveAlsoTakesTheSpellingOnDisk() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath: root) }
        for sub in ["active", "archive", "AREAS"] {
            try FileManager.default.createDirectory(atPath: (root as NSString).appendingPathComponent(sub),
                                                    withIntermediateDirectories: true)
        }
        let config = PmConfig(activePath: (root as NSString).appendingPathComponent("active"),
                              archivePath: (root as NSString).appendingPathComponent("archive"),
                              domains: defaultDomains, subfolders: defaultSubfolders)
        let paths = try resolvePaths(config: config, environment: [:])
        XCTAssertEqual((paths.areasPath as NSString).lastPathComponent, "AREAS")
    }

    /// With nothing there, `areas` is as good a spelling as any — PM is about to choose it.
    func testWithNoFolderThereTheDerivedNameIsLowercase() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(atPath: (root as NSString).appendingPathComponent("active"),
                                                withIntermediateDirectories: true)
        let config = PmConfig(activePath: (root as NSString).appendingPathComponent("active"),
                              archivePath: (root as NSString).appendingPathComponent("archive"),
                              domains: defaultDomains, subfolders: defaultSubfolders)
        let paths = try resolvePaths(config: config, environment: [:])
        XCTAssertEqual((paths.areasPath as NSString).lastPathComponent, "areas")
    }

    /// Only the *name* is taken from the canonical answer. The canonical form resolves symlinks too,
    /// and adopting the whole of it would re-root areasPath somewhere its siblings aren't.
    func testResolutionDoesNotRerootThePath() throws {
        let real = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        let link = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer {
            try? FileManager.default.removeItem(atPath: real)
            try? FileManager.default.removeItem(atPath: link)
        }
        try FileManager.default.createDirectory(atPath: (real as NSString).appendingPathComponent("Areas"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: (real as NSString).appendingPathComponent("active"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: real)

        let config = PmConfig(paraPath: link,
                              activePath: (link as NSString).appendingPathComponent("active"),
                              archivePath: (link as NSString).appendingPathComponent("archive"),
                              domains: defaultDomains, subfolders: defaultSubfolders)
        let paths = try resolvePaths(config: config, environment: [:])
        XCTAssertEqual(paths.areasPath, (link as NSString).appendingPathComponent("Areas"),
                       "the parent must stay as given — only the folder's own name comes from disk")
    }

    /// An explicitly configured path is used verbatim, like activePath and archivePath. Someone who
    /// wrote it down meant it.
    func testAnExplicitAreasPathIsNotSecondGuessed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(atPath: (root as NSString).appendingPathComponent("Areas"),
                                                withIntermediateDirectories: true)
        let config = PmConfig(activePath: "/a", archivePath: "/b",
                              areasPath: (root as NSString).appendingPathComponent("areas"),
                              domains: defaultDomains, subfolders: defaultSubfolders)
        let paths = try resolvePaths(config: config, environment: [:])
        XCTAssertEqual((paths.areasPath as NSString).lastPathComponent, "areas")
    }
}
