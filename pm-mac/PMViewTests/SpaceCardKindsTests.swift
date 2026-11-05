import XCTest

/// The sidebar address field's card kinds: matching, filling in, paths and recent folders
/// (docs/spaces.md § Adding cards from the sidebar).
final class SpaceCardKindsTests: XCTestCase {

    func testTwoLettersFillInAKindsName() {
        XCTAssertEqual(SpaceCardKinds.filled("ti"), "time")
        XCTAssertEqual(SpaceCardKinds.filled("Fo"), "Folder")  // your letters as typed
        XCTAssertEqual(SpaceCardKinds.filled("co"), "coming up")
        XCTAssertEqual(SpaceCardKinds.filled("te"), "text")
        XCTAssertNil(SpaceCardKinds.filled("t"), "one letter is the start of every address")
        XCTAssertNil(SpaceCardKinds.filled("time"), "nothing left to fill in")
        XCTAssertNil(SpaceCardKinds.filled("time zones"))
        XCTAssertNil(SpaceCardKinds.filled("github"))
    }

    func testTheWholeNameIsExactAndAnythingMoreIsNot() {
        XCTAssertEqual(SpaceCardKinds.exact("time")?.command, .timeView)
        XCTAssertEqual(SpaceCardKinds.exact(" Folder ")?.command, .folder)
        XCTAssertEqual(SpaceCardKinds.exact("text")?.command, .card)
        XCTAssertEqual(SpaceCardKinds.exact("coming up")?.command, .comingUpView)
        XCTAssertNil(SpaceCardKinds.exact("tim"))
        XCTAssertNil(SpaceCardKinds.exact("time zones"))
        XCTAssertNil(SpaceCardKinds.exact("web"), "the field already makes web cards")
        XCTAssertNil(SpaceCardKinds.exact("note"), "a project's notes are its Notes row")
    }

    func testMatchesAreEveryKindStartingSoInListOrder() {
        XCTAssertEqual(SpaceCardKinds.matches("pr").map(\.command), [.privateWeb, .projectsView])
        XCTAssertEqual(SpaceCardKinds.matches("f").map(\.command), [])
        XCTAssertEqual(SpaceCardKinds.matches("fr").map(\.command), [.frame])
        XCTAssertEqual(SpaceCardKinds.matches("~/").map(\.command), [], "a path is never a kind")
    }

    func testEveryViewIsOfferedOnce() {
        let views = SpaceCardKinds.all.map(\.command).filter { $0.viewSpec != nil }
        XCTAssertEqual(Set(views).count, views.count)
        XCTAssertEqual(Set(views), Set(CanvasAddCommand.allCases.filter { $0.viewSpec != nil }))
    }

    // MARK: Paths

    private func scratchHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("kinds-\(UUID().uuidString)")
        let fm = FileManager.default
        for folder in ["Documents", "Downloads", "Desktop", ".hidden", "Documents/Taxes"] {
            try fm.createDirectory(at: home.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        try Data().write(to: home.appendingPathComponent("Dossier.pdf"))
        try Data().write(to: home.appendingPathComponent("Documents/a.md"))
        addTeardownBlock { try? fm.removeItem(at: home) }
        return home
    }

    func testAPathListsFoldersFirstThenFilesStartingSo() throws {
        let home = try scratchHome()
        let names = { (text: String) in SpaceCardKinds.paths(text, home: home).map(\.url.lastPathComponent) }
        XCTAssertEqual(names("~/Do"), ["Documents", "Downloads", "Dossier.pdf"])
        XCTAssertEqual(names("~/do"), ["Documents", "Downloads", "Dossier.pdf"], "case doesn't matter")
        XCTAssertEqual(names("~/"), ["Desktop", "Documents", "Downloads", "Dossier.pdf"], "no hidden items")
        XCTAssertEqual(names("~/.h"), [".hidden"], "unless you typed the dot")
        XCTAssertEqual(names("~/Documents/"), ["Taxes", "a.md"])
        XCTAssertEqual(names(home.path + "/Doc"), ["Documents"])
        XCTAssertEqual(SpaceCardKinds.paths("~/Do", home: home).map(\.isFolder), [true, true, false])
        XCTAssertEqual(names("~/Nothing/"), [])
        XCTAssertEqual(names("time"), [])
    }

    func testAPathIsWrittenBackUnderHome() {
        let home = URL(fileURLWithPath: "/Users/someone")
        XCTAssertEqual(SpaceCardKinds.written(URL(fileURLWithPath: "/Users/someone/Downloads"), isFolder: true, home: home),
                       "~/Downloads/")
        XCTAssertEqual(SpaceCardKinds.written(URL(fileURLWithPath: "/Users/someone/a.md"), isFolder: false, home: home),
                       "~/a.md")
        XCTAssertEqual(SpaceCardKinds.written(URL(fileURLWithPath: "/tmp/x"), isFolder: true, home: home), "/tmp/x/")
    }

    // MARK: Recent folders

    func testRecentFoldersLeadWithTheProjectThenNewestThenDownloads() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "kinds-\(UUID().uuidString)"))
        let project = URL(fileURLWithPath: "/p/project"), downloads = URL(fileURLWithPath: "/u/Downloads")
        let list = { SpaceRecentFolders.list(projectFolder: project, defaults: defaults, downloads: downloads,
                                             exists: { _ in true }).map(\.path) }
        XCTAssertEqual(list(), ["/p/project", "/u/Downloads"])
        SpaceRecentFolders.note(URL(fileURLWithPath: "/a"), defaults: defaults)
        SpaceRecentFolders.note(URL(fileURLWithPath: "/b"), defaults: defaults)
        SpaceRecentFolders.note(URL(fileURLWithPath: "/a"), defaults: defaults)
        XCTAssertEqual(list(), ["/p/project", "/a", "/b", "/u/Downloads"], "newest first, once each")
        SpaceRecentFolders.note(project, defaults: defaults)
        XCTAssertEqual(list(), ["/p/project", "/a", "/b", "/u/Downloads"], "the project isn't listed twice")
        for name in ["c", "d", "e", "f"] { SpaceRecentFolders.note(URL(fileURLWithPath: "/" + name), defaults: defaults) }
        XCTAssertEqual(list().count, SpaceRecentFolders.shown)
        let gone = SpaceRecentFolders.list(projectFolder: nil, defaults: defaults, downloads: nil,
                                           exists: { $0.path != "/f" }).map(\.path)
        XCTAssertEqual(gone.first, "/e", "a folder that's gone isn't offered")
    }
}
