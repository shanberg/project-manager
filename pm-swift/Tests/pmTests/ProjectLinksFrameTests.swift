import XCTest
@testable import PmLib

/// A project's links are web cards in a frame on its canvas, and `## Links` is a mirror of that frame.
/// What has to hold: nothing typed into the notes by hand is lost, nothing done on the board is
/// undone by the notes, and a project with no links gets no frame.
final class ProjectLinksFrameTests: XCTestCase {
    private func urls(_ document: CanvasDocument) -> [String?] { ProjectLinksFrame.links(of: document).map(\.url) }

    func testMigratingTakesEveryLinkInTheNotesInOrderWithItsName() {
        var canvas = CanvasDocument()
        let notes = [LinkEntry(label: "Design file", url: "https://figma.com/a"),
                     LinkEntry(url: "https://example.com/b")]
        let synced = ProjectLinksFrame.sync(notes: notes, canvas: &canvas)
        XCTAssertTrue(synced.canvasChanged)
        XCTAssertFalse(synced.notesChanged, "the notes already say this")
        XCTAssertEqual(urls(canvas), ["https://figma.com/a", "https://example.com/b"])
        XCTAssertEqual(ProjectLinksFrame.links(of: canvas).map(\.label), ["Design file", nil])
        XCTAssertEqual(canvasFrameLabel(ProjectLinksFrame.frame(of: canvas)!), "Links")
        XCTAssertEqual(synced.links, notes)

        let again = ProjectLinksFrame.sync(notes: synced.links, canvas: &canvas)
        XCTAssertFalse(again.canvasChanged, "a second sync is a no-op")
        XCTAssertFalse(again.notesChanged)
    }

    func testAProjectWithNoLinksGetsNoFrame() {
        var canvas = CanvasDocument()
        let synced = ProjectLinksFrame.sync(notes: [LinkEntry()], canvas: &canvas)
        XCTAssertFalse(synced.canvasChanged)
        XCTAssertNil(ProjectLinksFrame.frame(of: canvas))
    }

    func testALineAddedByHandBecomesACardAndOneRemovedTakesItsCard() {
        var canvas = CanvasDocument()
        let first = ProjectLinksFrame.sync(notes: [LinkEntry(url: "https://a.com")], canvas: &canvas).links
        let added = ProjectLinksFrame.sync(notes: first + [LinkEntry(label: "B", url: "https://b.com")], canvas: &canvas)
        XCTAssertEqual(urls(canvas), ["https://a.com", "https://b.com"])
        XCTAssertFalse(added.notesChanged)

        let removed = ProjectLinksFrame.sync(notes: [LinkEntry(label: "B", url: "https://b.com")], canvas: &canvas)
        XCTAssertEqual(urls(canvas), ["https://b.com"], "a.com's card went with its line")
        XCTAssertFalse(removed.notesChanged)
    }

    func testACardAddedOrRemovedOnTheBoardIsWrittenToTheNotes() {
        var canvas = CanvasDocument()
        var notes = ProjectLinksFrame.sync(notes: [LinkEntry(url: "https://a.com")], canvas: &canvas).links
        let home = ProjectLinksFrame.frame(of: canvas)!.id
        CanvasItemPlacement.add(.link(url: "https://new.com"), to: &canvas, frame: home)
        let synced = ProjectLinksFrame.sync(notes: notes, canvas: &canvas)
        XCTAssertTrue(synced.notesChanged)
        XCTAssertEqual(synced.links.map(\.url), ["https://a.com", "https://new.com"], "kept, not taken as removed by hand")
        notes = synced.links

        let a = ProjectLinksFrame.links(of: canvas).first { $0.url == "https://a.com" }!.id
        canvas.nodes.removeAll { $0.id == a }
        let after = ProjectLinksFrame.sync(notes: notes, canvas: &canvas)
        XCTAssertEqual(after.links.map(\.url), ["https://new.com"], "not put back as added by hand")
    }

    func testRenamingByHandRenamesTheCardAndRenamingTheCardRenamesTheLine() {
        var canvas = CanvasDocument()
        let notes = ProjectLinksFrame.sync(notes: [LinkEntry(label: "Old", url: "https://a.com")], canvas: &canvas).links
        _ = ProjectLinksFrame.sync(notes: [LinkEntry(label: "New", url: "https://a.com")], canvas: &canvas)
        XCTAssertEqual(ProjectLinksFrame.links(of: canvas).first?.label, "New")

        let id = ProjectLinksFrame.links(of: canvas).first!.id
        let index = canvas.nodes.firstIndex { $0.id == id }!
        canvas.nodes[index].extra[ProjectLinksFrame.labelKey] = .string("From the board")
        let synced = ProjectLinksFrame.sync(notes: [LinkEntry(label: "New", url: "https://a.com")], canvas: &canvas)
        XCTAssertEqual(synced.links.first?.label, "From the board")
        XCTAssertTrue(synced.notesChanged)
        _ = notes
    }

    func testAnAddressUsedAsItsOwnNameIsNoName() {
        var canvas = CanvasDocument()
        let synced = ProjectLinksFrame.sync(notes: [LinkEntry(label: "https://a.com", url: "https://a.com")], canvas: &canvas)
        XCTAssertNil(ProjectLinksFrame.links(of: canvas).first?.label)
        XCTAssertTrue(synced.notesChanged, "the notes are told the plain form")
        XCTAssertEqual(synced.links, [LinkEntry(url: "https://a.com")])
    }

    func testAGroupIsAFrameInsideTheLinksFrame() {
        var canvas = CanvasDocument()
        let notes = [LinkEntry(label: "Docs", children: [LinkEntry(url: "https://d1.com"), LinkEntry(url: "https://d2.com")]),
                     LinkEntry(url: "https://top.com")]
        let synced = ProjectLinksFrame.sync(notes: notes, canvas: &canvas)
        let links = ProjectLinksFrame.links(of: canvas)
        XCTAssertEqual(Set(links.compactMap(\.label)), ["Docs"])
        XCTAssertEqual(links.first { $0.label == "Docs" }?.children.map(\.url), ["https://d1.com", "https://d2.com"])
        XCTAssertEqual(Set(synced.links.compactMap(\.url)), ["https://top.com"])
    }

    func testCardsOutsideTheFrameAndNotesInsideItAreNotLinks() {
        var canvas = CanvasDocument()
        _ = ProjectLinksFrame.sync(notes: [LinkEntry(url: "https://a.com")], canvas: &canvas)
        let home = ProjectLinksFrame.frame(of: canvas)!.id
        CanvasItemPlacement.add(.text("a note about the links"), to: &canvas, frame: home)
        canvas.nodes.append(CanvasNode(content: .link(url: "https://elsewhere.com"),
                                       frame: CanvasRect(x: -5000, y: -5000, width: 400, height: 300)))
        XCTAssertEqual(urls(canvas), ["https://a.com"])
    }

    func testTheMirrorSurvivesTheFile() throws {
        var canvas = CanvasDocument()
        _ = ProjectLinksFrame.sync(notes: [LinkEntry(label: "A", url: "https://a.com")], canvas: &canvas)
        var reread = try CanvasDocument.parse(Data(canvas.serialized().utf8))
        let synced = ProjectLinksFrame.sync(notes: [], canvas: &reread)
        XCTAssertEqual(urls(reread), [], "an emptied Links section removes the card: the mirror was read back")
        XCTAssertEqual(synced.links, [LinkEntry()])
    }
}

extension ProjectLinksFrameTests {
    func testReorderingTheNotesMovesTheCardsAndNotTheOtherWayRound() {
        var canvas = CanvasDocument()
        let notes = ProjectLinksFrame.sync(notes: ["a", "b", "c"].map { LinkEntry(url: "https://\($0).com") }, canvas: &canvas).links
        let before = Set(ProjectLinksFrame.links(of: canvas).compactMap { canvas.node(id: $0.id).map { "\($0.frame.x),\($0.frame.y)" } })
        let reordered = [notes[2], notes[0], notes[1]]
        let synced = ProjectLinksFrame.sync(notes: reordered, canvas: &canvas)
        XCTAssertEqual(ProjectLinksFrame.links(of: canvas).map(\.url), ["https://c.com", "https://a.com", "https://b.com"])
        XCTAssertFalse(synced.notesChanged, "the notes' order stands")
        let after = Set(ProjectLinksFrame.links(of: canvas).compactMap { canvas.node(id: $0.id).map { "\($0.frame.x),\($0.frame.y)" } })
        XCTAssertEqual(before, after, "the same places, dealt out in the new order")
    }
}

extension ProjectLinksFrameTests {
    func testANameWithColonsInItIsPutBackTogether() {
        var canvas = CanvasDocument()
        // What `- Lain [Sub] : Internet Archive: https://archive.org/x` parses to.
        let parsed = LinkEntry(label: "Lain [Sub] ", url: "Internet Archive: https://archive.org/x")
        let synced = ProjectLinksFrame.sync(notes: [parsed], canvas: &canvas)
        XCTAssertEqual(ProjectLinksFrame.links(of: canvas).map(\.url), ["https://archive.org/x"])
        XCTAssertEqual(ProjectLinksFrame.links(of: canvas).first?.label, "Lain [Sub] : Internet Archive")
        let again = ProjectLinksFrame.sync(notes: [parsed], canvas: &canvas)
        XCTAssertFalse(again.canvasChanged, "the same broken parse next time is the same link, not a new one")
        _ = synced
    }

    func testARowThatIsNotALinkStaysInTheNotesAndOffTheBoard() {
        var canvas = CanvasDocument()
        let prose = LinkEntry(label: "Ask Sam for the login", children: [])
        let relative = LinkEntry(label: "Spec", url: "docs/spec.md")
        let synced = ProjectLinksFrame.sync(notes: [LinkEntry(url: "https://a.com"), prose, relative], canvas: &canvas)
        XCTAssertEqual(ProjectLinksFrame.links(of: canvas).map(\.url), ["https://a.com"])
        XCTAssertEqual(synced.links.count, 3, "both kept")
        XCTAssertFalse(synced.notesChanged)
    }
}
