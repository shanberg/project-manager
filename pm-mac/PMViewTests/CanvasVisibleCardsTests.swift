import XCTest
import PmLib
@testable import PMViewTests

/// **Which cards the board builds a view for, and the one case where it went on building one for a card
/// that no longer existed.**
///
/// The decision has two jobs pulling against each other. Off a board of forty-three cards it has to
/// drop what is far away, because a card's view is a live thing — a web card is a renderer — and
/// forty-three of them is not a board anyone wants to scroll. Under a workspace it has to do the exact
/// opposite and keep everything it has, because a workspace shows six of those cards and dropping the
/// other thirty-seven would reload every page you had open the moment you looked away from them.
///
/// Backlog 19 is what happens where the two meet: delete one tile of a workspace and the keep-
/// everything rule kept answering for it. Nothing downstream could recover — `layoutNodeViews` skips a
/// view whose node it cannot find, so the orphan was never moved, hidden or faded again — which is why
/// the piece left on screen sat exactly where its tile had been, and why it went away the moment you
/// left the workspace and the layout became the document's.
final class CanvasVisibleCardsTests: XCTestCase {

    /// A screenful, near the origin. Everything below is placed either inside it or a long way outside.
    private let keep = CanvasRect(x: 0, y: 0, width: 1000, height: 800)

    private func card(_ id: String, x: Double, y: Double) -> CanvasNode {
        CanvasNode(id: id, content: .text(id), frame: CanvasRect(x: x, y: y, width: 200, height: 150))
    }

    /// Three cards on screen and one parked far off it — the board this file argues about.
    private func board() -> CanvasDocument {
        CanvasDocument(nodes: [card("a", x: 10, y: 10), card("b", x: 300, y: 10),
                               card("c", x: 600, y: 10), card("far", x: 9000, y: 9000)])
    }

    /// A workspace showing `ids`, each given a tile-shaped frame the document knows nothing about.
    private func tiled(_ ids: [String]) -> CanvasLayout {
        var layout = CanvasLayout(visible: Set(ids))
        for (index, id) in ids.enumerated() {
            layout.frames[id] = CanvasRect(x: Double(index) * 340, y: 0, width: 320, height: 700)
        }
        return layout
    }

    private func wanted(_ document: CanvasDocument, _ layout: CanvasLayout,
                        built: Set<String> = []) -> Set<String> {
        CanvasVisibleCards.wanted(in: document, layout: layout, keep: keep, built: built)
    }

    // MARK: The plain board

    func testACardTheKeepRegionReachesIsBuilt() {
        XCTAssertTrue(wanted(board(), .document).isSuperset(of: ["a", "b", "c"]))
    }

    func testACardFarOutsideTheKeepRegionIsNot() {
        XCTAssertFalse(wanted(board(), .document).contains("far"))
    }

    /// The board's own layout keeps nothing: a card scrolled well away from the keep region loses its
    /// view even though it has one. This is the rule the workspace case has to suspend — and it is also
    /// why backlog 19 healed itself on Escape.
    func testTheDocumentLayoutDropsAViewThatHasScrolledAway() {
        XCTAssertFalse(wanted(board(), .document, built: ["far"]).contains("far"))
    }

    func testAGroupNeverWantsAView() {
        let document = CanvasDocument(nodes: [
            CanvasNode(id: "frame", content: .group(label: "Reading", background: nil,
                                                   backgroundStyle: nil),
                       frame: CanvasRect(x: 0, y: 0, width: 800, height: 600)),
            card("a", x: 10, y: 10),
        ])
        XCTAssertEqual(wanted(document, .document), ["a"])
        // Including when a layout is carrying its id. The board's build loop asks this and nothing
        // else now — it used to re-check `isGroup` itself — so a frame reaching the answer would be a
        // frame handed a `CanvasNodeView`.
        XCTAssertEqual(wanted(document, tiled(["frame", "a"]), built: ["frame", "a"]), ["a"])
    }

    // MARK: A workspace

    /// The reason the keep-everything rule exists. `far` is nowhere near the screen and is not one of
    /// the tiles, and its view stays because throwing it away would mean loading that page again.
    func testAWorkspaceKeepsACardItIsNotShowing() {
        XCTAssertTrue(wanted(board(), tiled(["a", "b"]), built: ["a", "b", "far"]).contains("far"))
    }

    /// And a card that was never built stays unbuilt — a workspace hides the board, so the cards it
    /// leaves out are not worth making views for either.
    func testAWorkspaceDoesNotBuildACardItIsNotShowing() {
        XCTAssertFalse(wanted(board(), tiled(["a", "b"])).contains("far"))
    }

    // MARK: Backlog 19 — the tile that was deleted

    /// **The regression.** Three tiles, one of them deleted: the file has lost it and the workspace has
    /// reflowed around it, and the only thing still saying its name is the view it used to have.
    func testADeletedTileDoesNotKeepItsView() {
        var document = board()
        document.nodes.removeAll { $0.id == "c" }
        let after = wanted(document, tiled(["a", "b"]), built: ["a", "b", "c"])
        XCTAssertFalse(after.contains("c"),
                       "the deleted tile still wants a view, so nothing will ever take it off screen — "
                           + "it stays drawn at its old tile's frame over the tiles that reflowed")
        XCTAssertEqual(after, ["a", "b"])
    }

    /// Same deletion, but the layout has not caught up — `pruneTilingOfDeletedCards` and the build pass
    /// are two steps, and a layout still naming a card it no longer has must not resurrect it either.
    func testALayoutStillNamingADeletedCardDoesNotKeepItEither() {
        var document = board()
        document.nodes.removeAll { $0.id == "c" }
        XCTAssertFalse(wanted(document, tiled(["a", "b", "c"]), built: ["a", "b", "c"]).contains("c"))
    }

    /// Deleting the *last* tile leaves the workspace altogether, which puts the document's layout back —
    /// and that layout drops the orphan on its own. Worth pinning because it is why this only ever
    /// showed up on a workspace with more than one tile left in it.
    func testDeletingTheOnlyTileLeavesNothingBehindBecauseTheLayoutGoesBack() {
        var document = board()
        document.nodes.removeAll { $0.id == "c" }
        XCTAssertFalse(wanted(document, .document, built: ["c"]).contains("c"))
    }

    /// The other half of the same story: a deletion made while the board is not tiled was never able to
    /// do this, because nothing was keeping the view.
    func testADeletedCardOnAPlainBoardWasNeverKept() {
        var document = board()
        document.nodes.removeAll { $0.id == "a" }
        XCTAssertFalse(wanted(document, .document, built: ["a", "b", "c"]).contains("a"))
    }
}
