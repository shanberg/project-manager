import XCTest
import PmLib
@testable import PMViewTests

/// The project note the add menu offers to put back.
///
/// Two questions, and both are about paths rather than about drawing: which file this board's project
/// keeps, and whether a card already points at it. The second is the one that has to be right on a
/// board somebody is dragging across, because it is asked on every frame of that drag.
@MainActor
final class CanvasProjectNoteCardTests: XCTestCase {

    private var vault: URL!

    override func setUpWithError() throws {
        vault = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pm-note-card-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: vault)
    }

    /// A project folder with its notes file in place, and the path a canvas would sit at.
    @discardableResult
    private func project(_ folder: String, notes: Bool = true) throws -> URL {
        let root = vault.appendingPathComponent(folder)
        let docs = root.appendingPathComponent("docs")
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        if notes {
            let title = folder.contains(" ") ? String(folder.split(separator: " ").dropFirst().joined(separator: " ")) : folder
            try "# \(title)".write(to: docs.appendingPathComponent("Notes - \(title).md"),
                                   atomically: true, encoding: .utf8)
        }
        return root
    }

    private func resolver(canvas: URL) -> CanvasFileResolver {
        CanvasFileResolver(canvas: canvas, vaultRoot: vault)
    }

    // MARK: Which file

    func testTheCanonicalBoardFindsItsProjectsNotes() throws {
        let root = try project("W-001 Walkable")
        let canvas = root.appendingPathComponent("docs/Walkable.canvas")
        XCTAssertEqual(CanvasProjectNoteCard.notes(forCanvasAt: canvas)?.lastPathComponent,
                       "Notes - Walkable.md")
    }

    /// A board adopted from Obsidian sits at the top of the project folder rather than in `docs/`.
    /// It is still that project's board.
    func testABoardAtTheTopOfTheProjectFindsThemToo() throws {
        let root = try project("C-002 Strahd")
        let canvas = root.appendingPathComponent("The Curse of Strahd.canvas")
        XCTAssertEqual(CanvasProjectNoteCard.notes(forCanvasAt: canvas)?.lastPathComponent,
                       "Notes - Strahd.md")
    }

    /// A canvas that is just a canvas — somewhere in the vault, with no project a step above it. The
    /// menu has nothing to offer and must not invent a card pointing at a file that isn't there.
    func testACanvasThatIsntAProjectsGetsNoOffer() throws {
        let loose = vault.appendingPathComponent("Boards")
        try FileManager.default.createDirectory(at: loose, withIntermediateDirectories: true)
        XCTAssertNil(CanvasProjectNoteCard.notes(forCanvasAt: loose.appendingPathComponent("ideas.canvas")))
    }

    func testAProjectWithNoNotesFileYetGetsNoOffer() throws {
        let root = try project("W-003 Bare", notes: false)
        XCTAssertNil(CanvasProjectNoteCard.notes(forCanvasAt: root.appendingPathComponent("docs/Bare.canvas")))
    }

    // MARK: Whether it is already there

    private func board(_ paths: [String]) -> CanvasDocument {
        CanvasDocument(nodes: paths.map {
            CanvasNode(content: .file(path: $0, subpath: nil),
                       frame: CanvasRect(x: 0, y: 0, width: 400, height: 400))
        })
    }

    func testTheCardIsFoundByThePathItWouldBeStoredAs() throws {
        let root = try project("W-001 Walkable")
        let canvas = root.appendingPathComponent("docs/Walkable.canvas")
        let notes = try XCTUnwrap(CanvasProjectNoteCard.notes(forCanvasAt: canvas))
        let document = board(["W-001 Walkable/docs/Notes - Walkable.md"])
        XCTAssertTrue(CanvasProjectNoteCard.isOn(document, notes: notes,
                                                 resolver: resolver(canvas: canvas)))
    }

    func testAnotherFileOnTheBoardIsNotTheProjectNote() throws {
        let root = try project("W-001 Walkable")
        let canvas = root.appendingPathComponent("docs/Walkable.canvas")
        let notes = try XCTUnwrap(CanvasProjectNoteCard.notes(forCanvasAt: canvas))
        let document = board(["W-001 Walkable/docs/Brief.md", "Attachments/plan.png"])
        XCTAssertFalse(CanvasProjectNoteCard.isOn(document, notes: notes,
                                                  resolver: resolver(canvas: canvas)))
    }

    /// A card written by hand, or by another app, relative to somewhere else in the tree. The tail is
    /// what identifies it — the alternative is a resolver call, on the drag path, per card.
    func testACardWrittenRelativeToSomewhereElseStillCounts() throws {
        let root = try project("W-001 Walkable")
        let canvas = root.appendingPathComponent("docs/Walkable.canvas")
        let notes = try XCTUnwrap(CanvasProjectNoteCard.notes(forCanvasAt: canvas))
        let document = board(["docs/Notes - Walkable.md"])
        XCTAssertTrue(CanvasProjectNoteCard.isOn(document, notes: notes,
                                                 resolver: resolver(canvas: canvas)))
    }

    /// The card the board adds is the card `createProjectCanvas` writes: a vault-relative file path,
    /// 400 square, centred where it was asked for.
    func testTheCardItMakesIsTheOneANewBoardIsGiven() throws {
        let root = try project("W-001 Walkable")
        let canvas = root.appendingPathComponent("docs/Walkable.canvas")
        let notes = try XCTUnwrap(CanvasProjectNoteCard.notes(forCanvasAt: canvas))
        let node = CanvasProjectNoteCard.node(for: notes, at: CanvasPoint(x: 100, y: 60),
                                              resolver: resolver(canvas: canvas))
        guard case .file(let path, let subpath) = node.content else {
            return XCTFail("expected a file card")
        }
        XCTAssertEqual(path, "W-001 Walkable/docs/Notes - Walkable.md")
        XCTAssertNil(subpath)
        XCTAssertEqual(node.frame, CanvasRect(x: -100, y: -140, width: 400, height: 400))
    }
}
