import Foundation
import PmLib

/// Which of a board's cards want a view, and which have stopped wanting one.
///
/// Lifted out of `CanvasBoardView.buildNodeViews` because none of it is about a view: it is a question
/// about a document, a layout and a rectangle, and the build pass around it only ever makes what this
/// names and throws away the rest. Worth having alone because both of its wrong answers are expensive
/// and neither looks like this decision when you meet it — a card dropped that should have been kept is
/// a web page reloaded on the way back, and a card kept that should have been dropped is a tile still
/// drawn over the workspace that reflowed around it (canvas-backlog.md 19). See
/// `CanvasVisibleCardsTests`.
enum CanvasVisibleCards {

    /// The cards that should have a view.
    ///
    /// `keep` is the region a card has to reach to be worth building — the visible rectangle grown by a
    /// screenful, plus wherever a flight or a peek is headed. `built` is the cards that have a view
    /// already.
    ///
    /// **Under a layout that is not the document, every card already built is kept**, wherever the file
    /// says it is. A workspace of six cards on a board of forty-three shows six, and tearing the other
    /// thirty-seven down would mean reloading every page you had open as the price of having glanced at
    /// six of them. They are hidden instead, which is `CanvasLayout.hides`.
    static func wanted(in document: CanvasDocument, layout: CanvasLayout,
                       keep: CanvasRect, built: Set<String>) -> Set<String> {
        var wanted: Set<String> = []
        if !layout.isDocument {
            wanted.formUnion(layout.visible ?? [])
            wanted.formUnion(built)
        }
        var cards: Set<String> = []
        for node in document.nodes where !node.isGroup {
            cards.insert(node.id)
            if layout.frame(of: node).intersects(keep) { wanted.insert(node.id) }
        }
        // **A card that has gone takes its view with it, whatever else would have kept it.** Deleting
        // one tile of a workspace leaves the rest of it tiled, so the keep-everything rule above went
        // on answering for a card the file no longer had — and `layoutNodeViews` skips a view whose
        // node it cannot find, so after that nothing moved it, hid it or faded it again. It sat at the
        // frame its tile used to have, over the tiles that had reflowed around it, until the workspace
        // was left and the layout became the document's again. That is canvas-backlog.md 19, and it is
        // why the piece left behind went away as soon as you pressed Escape.
        //
        // Groups fall out here too, and always did: a frame is drawn by the board itself and has never
        // had a view to keep.
        return wanted.intersection(cards)
    }
}
