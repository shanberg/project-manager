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
}
