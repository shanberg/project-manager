import XCTest
import PmLib
@testable import PMViewTests

/// Tidy Up: rows kept, columns aligned, a 20pt gutter, sizes untouched — and a second run is a no-op.
final class CanvasTidyTests: XCTestCase {

    private func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> CanvasRect {
        CanvasRect(x: x, y: y, width: w, height: h)
    }
    private func card(_ id: String, _ frame: CanvasRect) -> CanvasNode {
        CanvasNode(id: id, content: .text(id), frame: frame)
    }
    private func frame(_ id: String, _ frame: CanvasRect) -> CanvasNode {
        CanvasNode(id: id, content: .group(label: id, background: nil, backgroundStyle: nil), frame: frame)
    }
    private func applying(_ plan: [String: CanvasRect]?, to doc: CanvasDocument) -> CanvasDocument {
        var doc = doc
        for index in doc.nodes.indices { if let to = plan?[doc.nodes[index].id] { doc.nodes[index].frame = to } }
        return doc
    }

    /// Two rough rows of cards of different sizes.
    private func scatter() -> CanvasDocument {
        CanvasDocument(nodes: [
            card("a", rect(3, 7, 200, 100)),
            card("b", rect(260, 18, 300, 60)),
            card("c", rect(610, 0, 100, 140)),
            card("d", rect(12, 190, 240, 80)),
            card("e", rect(300, 175, 120, 120)),
        ])
    }

    func testRowsAreKeptAndColumnsLineUp() throws {
        let plan = try XCTUnwrap(CanvasTidy.plan(["a", "b", "c", "d", "e"], in: scatter()))
        // Anchored at the box's top-left on the 10pt lattice: (0, 0).
        XCTAssertEqual(plan["a"], rect(0, 0, 200, 100))
        // Column 0 is as wide as its widest card, d at 240.
        XCTAssertEqual(plan["b"], rect(260, 0, 300, 60))
        XCTAssertEqual(plan["c"], rect(580, 0, 100, 140))
        // Row 0 is as tall as c, its tallest.
        XCTAssertEqual(plan["d"], rect(0, 160, 240, 80))
        XCTAssertEqual(plan["e"], rect(260, 160, 120, 120), "under b, not packed against d")
    }

    func testASecondTidyChangesNothing() throws {
        let once = applying(CanvasTidy.plan(["a", "b", "c", "d", "e"], in: scatter()), to: scatter())
        XCTAssertEqual(CanvasTidy.plan(["a", "b", "c", "d", "e"], in: once), [:])
    }

    /// A tall card beside a short one is still one row once tidied, although their middles are far apart.
    func testATidiedRowOfUnevenCardsStaysARow() {
        let rows = CanvasTidy.rows([("tall", rect(0, 0, 100, 400)), ("note", rect(120, 0, 100, 60)),
                                    ("under", rect(0, 420, 100, 60))])
        XCTAssertEqual(rows.map { $0.map(\.id) }, [["tall", "note"], ["under"]])
    }

    func testOneCardIsNothingToTidy() {
        XCTAssertNil(CanvasTidy.plan(["a"], in: scatter()))
        XCTAssertNil(CanvasTidy.plan([], in: scatter()))
    }

    /// A frame alone tidies what it holds, inside it, and grows when the grid needs the room.
    func testAFrameTidiesWhatItHoldsAndGrowsToFit() throws {
        let doc = CanvasDocument(nodes: [
            frame("f", rect(100, 100, 300, 200)),
            card("x", rect(130, 150, 200, 100)),
            card("y", rect(250, 120, 140, 100)),
            card("outside", rect(900, 900, 50, 50)),
        ])
        let plan = try XCTUnwrap(CanvasTidy.plan(["f"], in: doc))
        XCTAssertEqual(plan["x"], rect(120, 120, 200, 100))
        XCTAssertEqual(plan["y"], rect(340, 120, 140, 100))
        XCTAssertEqual(plan["f"], rect(100, 100, 400, 200), "wider to hold y and a gutter; no taller")
        XCTAssertNil(plan["outside"])
    }

    /// In a larger selection a frame is one item, and what it holds moves with it.
    func testAFrameAmongCardsCarriesItsContents() throws {
        let doc = CanvasDocument(nodes: [
            frame("f", rect(15, 15, 200, 200)),
            card("inner", rect(35, 35, 50, 50)),
            card("z", rect(400, 0, 100, 100)),
        ])
        let plan = try XCTUnwrap(CanvasTidy.plan(["f", "inner", "z"], in: doc))
        XCTAssertEqual(plan["f"], rect(20, 0, 200, 200))
        XCTAssertEqual(plan["inner"], rect(40, 20, 50, 50), "carried, not laid out as a third item")
        XCTAssertEqual(plan["z"], rect(240, 0, 100, 100))
    }
}
