import PmLib
import XCTest

/// Archived Cards (docs/spaces.md § Browsing, Archived cards): recorded, written, read back, restored.
@MainActor
final class SpaceArchiveTests: XCTestCase {
    private var url: URL!

    override func setUpWithError() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpaceArchiveTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("archive.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    func testARecordedCardComesBackWholeFromTheFile() throws {
        var note = CanvasNode(content: .text("# Plan\n- one"), frame: CanvasRect(x: 900, y: 300, width: 360, height: 480),
                              color: "4", extra: ["pmSomethingNew": .string("kept")])
        SpaceCardMarks.setPinned(true, on: &note)
        let web = CanvasNode(content: .link(url: "https://example.com/a"), frame: CanvasRect(x: 0, y: 0, width: 400, height: 400))

        let archive = SpaceArchive(fileURL: url)
        archive.record([note, web], titles: [web.id: "Example"], spaceID: "s1", reason: .cleared)
        archive.finish()

        let read = SpaceArchive.read(url)
        XCTAssertEqual(read.count, 2)
        let webEntry = try XCTUnwrap(read.first { $0.address != nil })
        XCTAssertEqual(webEntry.title, "Example")
        XCTAssertEqual(webEntry.host, "example.com")
        XCTAssertEqual(webEntry.reason, .cleared)
        XCTAssertEqual(webEntry.spaceID, "s1")
        let noteEntry = try XCTUnwrap(read.first { $0.address == nil })
        XCTAssertEqual(noteEntry.card, note, "the whole node, keys Folio doesn't know included")

        // Restored: on the board, unpinned, at the top of Today, content intact.
        var other = CanvasNode(content: .link(url: "https://other.com"), frame: CanvasRect(x: 0, y: 0, width: 400, height: 400))
        other.extra[SpaceCardMarks.orderKey] = .number(0)
        var document = CanvasDocument(nodes: [other])
        let id = SpaceArchive.place(try XCTUnwrap(noteEntry.card), into: &document)
        let placed = try XCTUnwrap(document.node(id: id))
        XCTAssertEqual(placed.content, note.content)
        XCTAssertEqual(placed.extra["pmSomethingNew"], .string("kept"))
        XCTAssertFalse(SpaceCardMarks.isPinned(placed))
        XCTAssertLessThan(try XCTUnwrap(SpaceCardMarks.order(placed)), 0)
        XCTAssertGreaterThan(placed.frame.x, other.frame.maxX)
        XCTAssertEqual(SpaceCardMarks.sorted(document.nodes, by: SpaceCardMarks.order).first?.id, id)

        // Already back on the board: left alone.
        XCTAssertEqual(SpaceArchive.place(note, into: &document), id)
        XCTAssertEqual(document.nodes.count, 2)
    }

    func testRemovingAndClearingAreWritten() {
        let archive = SpaceArchive(fileURL: url)
        func card(_ n: Int) -> CanvasNode {
            CanvasNode(content: .link(url: "https://example.com/\(n)"), frame: CanvasRect(x: 0, y: 0, width: 400, height: 400))
        }
        archive.record([card(1), card(2)], titles: [:], spaceID: "s1", reason: .auto)
        archive.record([card(3)], titles: [:], spaceID: "s2", reason: .closed)
        let first = archive.entries(in: "s1")[0].id
        archive.remove([first])
        archive.finish()
        XCTAssertEqual(SpaceArchive.read(url).count, 2)
        XCTAssertFalse(SpaceArchive.read(url).contains { $0.id == first })

        archive.clear(spaceID: "s1")
        archive.finish()
        XCTAssertEqual(SpaceArchive.read(url).map(\.spaceID), ["s2"])
    }

    func testOldAndOverflowingEntriesGo() throws {
        let now = Date()
        let node = try XCTUnwrap(SpaceArchive.json(of: CanvasNode(content: .text("x"), frame: CanvasRect(x: 0, y: 0, width: 1, height: 1))))
        func entry(_ space: String, _ age: TimeInterval) -> SpaceArchive.Entry {
            .init(id: UUID().uuidString, spaceID: space, node: node, title: "x", archivedAt: now.addingTimeInterval(-age),
                  reason: .auto)
        }
        let many = (0..<(SpaceArchive.capacity + 5)).map { entry("a", Double($0)) }
        let kept = SpaceArchive.pruned(many + [entry("b", 1), entry("b", 91 * 86_400)], now: now)
        XCTAssertEqual(kept.filter { $0.spaceID == "a" }.count, SpaceArchive.capacity)
        XCTAssertEqual(kept.filter { $0.spaceID == "b" }.count, 1)
    }
}
