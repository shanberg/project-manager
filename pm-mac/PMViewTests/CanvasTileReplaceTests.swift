import XCTest
import PmLib
@testable import PMViewTests

/// Replace With (backlog 8): a different card in the same slot, and the slot kept as it was.
@MainActor
final class CanvasTileReplaceTests: XCTestCase {

    private let area = CanvasRect(x: 0, y: 0, width: 1400, height: 800)

    /// Two columns: a pinned tile of two tabs, "b" showing, and "c" alone.
    private func session() -> CanvasTileSession {
        CanvasTileSession(columns: [
            CanvasTiling.Column(width: .pinned(420), [CanvasTiling.Tile(["a", "b"], showing: 1, tabsOnSide: true)]),
            CanvasTiling.Column([CanvasTiling.Tile(["c"])]),
        ], area: area, restoreVisible: area)
    }

    func testTheCardTakesTheSlotAndTheSlotKeepsItsShape() {
        var s = session()
        XCTAssertTrue(s.replace("b", with: "z"))
        XCTAssertEqual(s.columns[0].tiles[0].cards, ["a", "z"])
        XCTAssertEqual(s.columns[0].tiles[0].showing, 1, "the new card is the one showing, where b was")
        XCTAssertTrue(s.columns[0].tiles[0].tabsOnSide)
        XCTAssertEqual(s.columns[0].width, .pinned(420))
        XCTAssertFalse(s.cards.contains("b"))
    }

    func testAMaximizedTileStaysMaximizedAsTheNewCard() {
        var s = session()
        s.maximized = "c"
        s.replace("c", with: "z")
        XCTAssertEqual(s.maximized, "z")
    }

    func testACardAlreadyUpIsRefused() {
        var s = session()
        XCTAssertFalse(s.replace("c", with: "a"), "that is a swap, which has its own command")
        XCTAssertFalse(s.replace("c", with: "c"))
        XCTAssertFalse(s.replace("gone", with: "z"))
        XCTAssertEqual(s, session())
    }

    /// The project's note leads the list, out of whatever frame it sits in.
    func testTheListCanLeadWithOneCard() {
        let doc = CanvasDocument(nodes: [
            CanvasNode(id: "loose", content: .text("Loose"), frame: CanvasRect(x: 0, y: 0, width: 200, height: 150)),
            CanvasNode(id: "f", content: .group(label: "Frame", background: nil, backgroundStyle: nil),
                       frame: CanvasRect(x: 1000, y: 0, width: 600, height: 400)),
            CanvasNode(id: "note", content: .file(path: "Projects/X/notes.md", subpath: nil),
                       frame: CanvasRect(x: 1100, y: 100, width: 200, height: 150)),
        ])
        let sections = CanvasExistingCards.sections(of: doc, showing: [], first: "note")
        XCTAssertEqual(sections.map { $0.items.map(\.id) }, [["note", "loose"]])
        XCTAssertEqual(sections.map(\.frame), [nil], "the frame it left is empty, so it has no header")
    }
}
