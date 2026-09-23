import XCTest
import PmLib

/// A card's file changing on disk reaches the card. See `CanvasFileWatch`.
@MainActor
final class CanvasFileWatchTests: XCTestCase {
    private var folder: URL!
    private let owner = NSObject()

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        CanvasFileWatch.shared.stop(owner)
        try? FileManager.default.removeItem(at: folder)
    }

    func testAChangeIsNoticedOnce() throws {
        let file = folder.appendingPathComponent("a.md")
        try "one".write(to: file, atomically: true, encoding: .utf8)
        var heard = 0
        CanvasFileWatch.shared.watch(owner, file) { heard += 1 }
        CanvasFileWatch.shared.check()
        XCTAssertEqual(heard, 0, "nothing changed yet")
        try "two, longer".write(to: file, atomically: true, encoding: .utf8)
        CanvasFileWatch.shared.check()
        CanvasFileWatch.shared.check()
        XCTAssertEqual(heard, 1)
    }

    /// Saved the way editors and sync clients save: a new file renamed over the old one.
    func testAReplacedFileIsNoticed() throws {
        let file = folder.appendingPathComponent("a.md")
        try "one".write(to: file, atomically: true, encoding: .utf8)
        var heard = 0
        CanvasFileWatch.shared.watch(owner, file) { heard += 1 }
        let other = folder.appendingPathComponent(".a.tmp")
        try "replaced".write(to: other, atomically: false, encoding: .utf8)
        _ = try FileManager.default.replaceItemAt(file, withItemAt: other)
        CanvasFileWatch.shared.check()
        XCTAssertEqual(heard, 1)
    }

    func testAnAcknowledgedWriteIsNotNews() throws {
        let file = folder.appendingPathComponent("a.md")
        try "one".write(to: file, atomically: true, encoding: .utf8)
        var heard = 0
        CanvasFileWatch.shared.watch(owner, file) { heard += 1 }
        try "mine, longer".write(to: file, atomically: true, encoding: .utf8)
        CanvasFileWatch.shared.acknowledge(owner)
        CanvasFileWatch.shared.check()
        XCTAssertEqual(heard, 0)
    }

    func testAFileGoingAwayIsNoticed() throws {
        let file = folder.appendingPathComponent("a.md")
        try "one".write(to: file, atomically: true, encoding: .utf8)
        var heard = 0
        CanvasFileWatch.shared.watch(owner, file) { heard += 1 }
        try FileManager.default.removeItem(at: file)
        CanvasFileWatch.shared.check()
        XCTAssertEqual(heard, 1)
    }

    func testStoppedIsSilent() throws {
        let file = folder.appendingPathComponent("a.md")
        try "one".write(to: file, atomically: true, encoding: .utf8)
        var heard = 0
        CanvasFileWatch.shared.watch(owner, file) { heard += 1 }
        CanvasFileWatch.shared.stop(owner)
        try "two, longer".write(to: file, atomically: true, encoding: .utf8)
        CanvasFileWatch.shared.check()
        XCTAssertEqual(heard, 0)
    }
}

/// Which files a delete offers to put in the Trash. See `CanvasDocCards.ownDocuments`.
final class CanvasOwnDocumentsTests: XCTestCase {
    private let docs = URL(fileURLWithPath: "/v/P-1 Thing/docs")
    private func card(_ id: String, _ path: String, subpath: String? = nil) -> CanvasNode {
        CanvasNode(id: id, content: .file(path: path, subpath: subpath),
                   frame: CanvasRect(x: 0, y: 0, width: 10, height: 10))
    }
    private func owned(_ ids: Set<String>, _ nodes: [CanvasNode]) -> [String] {
        CanvasDocCards.ownDocuments(deleting: ids, from: CanvasDocument(nodes: nodes), docs: docs,
                                    locate: { URL(fileURLWithPath: "/v/" + $0) })
            .map(\.lastPathComponent)
    }

    func testACardsOwnDocumentIsOffered() {
        XCTAssertEqual(owned(["a"], [card("a", "P-1 Thing/docs/Plan.md")]), ["Plan.md"])
    }

    func testADocumentAnotherCardStillShowsIsNot() {
        XCTAssertEqual(owned(["a"], [card("a", "P-1 Thing/docs/Plan.md"), card("b", "P-1 Thing/docs/Plan.md")]), [])
        // …unless that card is going too, and then it's offered once.
        XCTAssertEqual(owned(["a", "b"], [card("a", "P-1 Thing/docs/Plan.md"),
                                          card("b", "P-1 Thing/docs/Plan.md")]), ["Plan.md"])
    }

    func testPointersElsewhereAreNeverOffered() {
        XCTAssertEqual(owned(["a"], [card("a", "Elsewhere/Plan.md")]), [], "not in docs")
        XCTAssertEqual(owned(["a"], [card("a", "P-1 Thing/docs/Notes - Thing.md")]), [], "a project")
        XCTAssertEqual(owned(["a"], [card("a", "P-1 Thing/docs/photo.png")]), [], "not prose")
        XCTAssertEqual(owned(["a"], [card("a", "P-1 Thing/docs/Plan.md", subpath: "#Goals")]), [], "a slice of it")
        XCTAssertEqual(owned(["a"], [card("a", "P-1 Thing/docs/sub/Plan.md")]), [], "deeper than docs")
    }
}
