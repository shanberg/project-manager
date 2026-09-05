import XCTest
@testable import PmLib

/// The project's canvas: where it goes, which board on disk counts as it, and what a new one holds.
///
/// The fixture is modelled on the real vault rather than on the convention, because the convention is
/// the newcomer here. Boards already exist in these folders — at the top of the project, two side by
/// side in `docs/` — and were named before PM had an opinion about them. Getting those cases right is
/// most of the point.
final class ProjectCanvasTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pm-project-canvas-\(UUID().uuidString)")
        try put(".obsidian/app.json", "{}")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func put(_ path: String, _ text: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func project(_ name: String) -> String {
        root.appendingPathComponent("Projects/\(name)").path
    }

    private func relative(_ path: String?) -> String? {
        path.map { String($0.dropFirst(root.path.count + 1)) }
    }

    // MARK: Where it goes

    /// Beside the notes, under the project's title with the domain prefix dropped — the same reading
    /// of the folder name `getNotesPath` uses.
    func testTheCanonicalPathIsTheTitleInDocs() {
        XCTAssertEqual(relative(getProjectCanvasPath(projectPath: project("W-003 Detective Depictions"))),
                       "Projects/W-003 Detective Depictions/docs/Detective Depictions.canvas")
    }

    /// An Area has no prefix to drop: its folder name is its title.
    func testAnAreaUsesItsWholeName() {
        let area = root.appendingPathComponent("Areas/Church").path
        XCTAssertEqual(relative(getProjectCanvasPath(projectPath: area)),
                       "Areas/Church/docs/Church.canvas")
    }

    // MARK: Which board counts

    func testAProjectWithNoBoardHasNoCanvasYet() throws {
        try put("Projects/W-001 Site/docs/Notes - Site.md", "site")
        XCTAssertNil(try resolveProjectCanvasPath(projectPath: project("W-001 Site")))
    }

    /// A folder that doesn't exist at all reads as "no canvas", not as an error — a project can be
    /// asked about before anything has been written into it.
    func testAMissingProjectFolderIsNotAnError() throws {
        XCTAssertNil(try resolveProjectCanvasPath(projectPath: project("W-404 Nothing")))
    }

    func testTheCanonicalBoardWins() throws {
        try put("Projects/S-003 ISD Walkable/docs/ISD Walkable.canvas", "{}")
        try put("Projects/S-003 ISD Walkable/docs/Sketches.canvas", "{}")
        XCTAssertEqual(relative(try resolveProjectCanvasPath(projectPath: project("S-003 ISD Walkable"))),
                       "Projects/S-003 ISD Walkable/docs/ISD Walkable.canvas")
    }

    /// A single board in `docs/` is the project's, whatever it's called. This is the notes file's own
    /// fallback, and it's what keeps a canvas findable across a rename that didn't move it.
    func testALoneBoardInDocsIsAdopted() throws {
        try put("Projects/M-002 Fruhstuk/docs/Breakfast Plan.canvas", "{}")
        XCTAssertEqual(relative(try resolveProjectCanvasPath(projectPath: project("M-002 Fruhstuk"))),
                       "Projects/M-002 Fruhstuk/docs/Breakfast Plan.canvas")
    }

    /// The case this exists for: a board made in Obsidian, at the top of the project, named for the
    /// thing rather than for the folder. `The Curse of Strahd.canvas` is unmistakably that project's
    /// canvas, and offering to make an empty one beside it would be absurd.
    func testALoneBoardAtTheTopOfTheProjectIsAdopted() throws {
        try put("Projects/C-002 Dnd - Strahd 2024/The Curse of Strahd.canvas", "{}")
        XCTAssertEqual(relative(try resolveProjectCanvasPath(projectPath: project("C-002 Dnd - Strahd 2024"))),
                       "Projects/C-002 Dnd - Strahd 2024/The Curse of Strahd.canvas")
    }

    /// `docs/` is asked first, so a project with a board in both places doesn't have the top-level one
    /// promoted over the one filed properly.
    func testDocsBeatsTheTopOfTheFolder() throws {
        try put("Projects/W-001 Site/Scratch.canvas", "{}")
        try put("Projects/W-001 Site/docs/Site.canvas", "{}")
        XCTAssertEqual(relative(try resolveProjectCanvasPath(projectPath: project("W-001 Site"))),
                       "Projects/W-001 Site/docs/Site.canvas")
    }

    /// Two boards and no canonical one is nil, not a coin toss. `estimates` and `insurance` are two
    /// different subjects; crowning either would put a button in the header that opens the wrong board
    /// every time, and the user would have no way to tell it was guessing.
    func testTwoBoardsAndNoCanonicalOneIsNil() throws {
        try put("Projects/H-005 42 Aberdeen/docs/estimates.canvas", "{}")
        try put("Projects/H-005 42 Aberdeen/docs/insurance.canvas", "{}")
        XCTAssertNil(try resolveProjectCanvasPath(projectPath: project("H-005 42 Aberdeen")))
    }

    /// A card's own attachments live deeper in the folder and are not the project's canvas.
    func testASubfolderBoardIsNotAdopted() throws {
        try put("Projects/W-003 Detective Depictions/content/The Batman/The Batman.canvas", "{}")
        XCTAssertNil(try resolveProjectCanvasPath(projectPath: project("W-003 Detective Depictions")))
    }

    // MARK: Making one

    /// A new canvas opens as a view of the project, not a blank page: one card showing the notes, with
    /// the path written from the vault root the way Obsidian writes it.
    func testANewCanvasHoldsTheNotes() throws {
        let path = project("W-001 Site")
        try put("Projects/W-001 Site/docs/Notes - Site.md", "site")
        let made = try createProjectCanvas(projectPath: path,
                                           notesPath: try resolveNotesPath(projectPath: path))
        XCTAssertEqual(relative(made), "Projects/W-001 Site/docs/Site.canvas")

        let document = try CanvasDocument.read(contentsOf: URL(fileURLWithPath: made))
        XCTAssertEqual(document.nodes.count, 1)
        XCTAssertEqual(document.nodes.first?.content,
                       .file(path: "Projects/W-001 Site/docs/Notes - Site.md", subpath: nil))
        XCTAssertTrue(document.edges.isEmpty)
    }

    /// A project with no notes yet gets a genuinely empty board rather than a card pointing at nothing.
    func testANewCanvasWithoutNotesIsEmpty() throws {
        let made = try createProjectCanvas(projectPath: project("W-001 Site"), notesPath: nil)
        XCTAssertTrue(try CanvasDocument.read(contentsOf: URL(fileURLWithPath: made)).nodes.isEmpty)
    }

    /// It refuses rather than writing over a board. The caller resolves first and only creates when
    /// that came back nil, so reaching here means something else made the file in between.
    func testMakingOneTwiceRefuses() throws {
        _ = try createProjectCanvas(projectPath: project("W-001 Site"))
        XCTAssertThrowsError(try createProjectCanvas(projectPath: project("W-001 Site"))) { error in
            guard case PmError.canvasAlreadyExists = error else {
                return XCTFail("expected canvasAlreadyExists, got \(error)")
            }
        }
    }
}
