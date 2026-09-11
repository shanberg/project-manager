import Foundation
import PmLib

/// Where cards are drawn, which is not always where the document says they are.
///
/// The board had exactly one layout and it *was* the document: `layoutNodeViews` read `node.frame` and
/// that was the end of it. Splitting the two is the whole of what lets a canvas behave like a window
/// manager — a tiled arrangement is a second layout the board can display without the file knowing, and
/// everything else (hit testing, focus, the page budget) keeps working because it asks the layout
/// instead of asking the document.
///
/// **The document is never rewritten by a layout.** Positions on a canvas mean something — this card is
/// near that one because they are related — and the file is shared with Obsidian, so tidying your view
/// would tidy everyone's board. A tiled view is a way of looking, and Escape puts it back. Rewriting the
/// board to match is a separate, deliberate, undoable command.
struct CanvasLayout: Equatable {
    /// Frames the layout overrides, in canvas coordinates. Empty is the document's own layout.
    var frames: [String: CanvasRect] = [:]
    /// The cards this layout is showing, or nil for all of them. A tiled view of six cards on a board of
    /// forty-three is showing six.
    var visible: Set<String>?

    /// The plain one: the board as the file describes it.
    static let document = CanvasLayout()

    var isDocument: Bool { frames.isEmpty && visible == nil }

    func frame(of node: CanvasNode) -> CanvasRect { frames[node.id] ?? node.frame }
    func frame(of id: String, in document: CanvasDocument) -> CanvasRect? {
        frames[id] ?? document.node(id: id)?.frame
    }
    func shows(_ id: String) -> Bool { visible?.contains(id) ?? true }

    /// Whether a card's view is taken off screen altogether, given whether it is one of the cards a
    /// crossing into or out of a workspace is fading, and how far that fade has got.
    ///
    /// **A card this layout does not show is hidden unless it is on its way.** The cards a crossing
    /// fades stay drawn until they reach nothing, so you see them go. Every other card the layout
    /// leaves out is hidden outright — which this used to leave to the alpha alone, and a card only has
    /// a fading alpha if it was on the board when the crossing began. One made afterwards — dropped,
    /// pasted, or added through another tab's view of the same board — sat at full strength, where the
    /// board says it is, over the tiles of a workspace it was never part of.
    func hides(_ id: String, fading: Bool, alpha: Double) -> Bool {
        guard !shows(id) else { return false }
        return !fading || alpha <= 0.001
    }

    /// The cards a change from `old` to `next` fades — out on the way into a workspace, back in on the
    /// way out — among the board's `cards`. See `CanvasBoardView.setLayout`.
    ///
    /// **Only the way out borrows the old layout's answer.** Leaving to the document, every card is in
    /// the layout the instant it is set, so the ones arriving back can only be read off the layout being
    /// left. A tiling that happens to show every card is not that — a maximized tile put back, or a
    /// switch into a workspace holding the whole board — and borrowing there marked the tiles it shows
    /// as fading. A fading card is drawn at `1 - tiledness`, which in a workspace is zero, so they sat
    /// in their slots invisible until a resize re-laid the board and asked again.
    static func fading(from old: CanvasLayout, to next: CanvasLayout,
                       among cards: Set<String>) -> Set<String> {
        if let visible = next.visible { return cards.subtracting(visible) }
        return old.visible.map { cards.subtracting($0) } ?? []
    }
}
