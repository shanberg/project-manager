import Foundation
import PmLib

/// The cards on a board that the tiled view in front of you isn't showing — what Add Card from Canvas
/// offers.
///
/// **A list, not pictures.** A card's own face is the most informative thing about it, and the board
/// already draws every one of them; the only thing a picker adds is a way to name one without leaving
/// the workspace. So this names them the way the board does when it is zoomed too far out to read —
/// the one line that stands for a card (`canvasCardSummary`), a file's name, a page's remembered title
/// — beside the icon the card itself would draw at that size. Nothing is rendered, and no page is
/// woken up to have its picture taken.
///
/// **The reading is `CanvasItems` now** (docs/items.md D2). This was the only thing that could turn a
/// board into a list of named things, and the list lenses needed exactly that — so the reading moved
/// to PmLib and what is left here is the picker: the command's name, and the app's answers to the
/// three questions a document can't answer for itself.
enum CanvasExistingCards {
    /// One name for the command in every place it is offered — the tile's menu, the board's, the `+`
    /// menu and the View menu — for the reason `CanvasAddCommand` gives.
    static let title = "Add Card from Canvas"

    typealias Card = CanvasItem
    typealias Section = CanvasItemSection

    /// What the app knows that the document doesn't: the disk, the page titles it has seen, and what a
    /// view card calls itself once its settings are read.
    ///
    /// **A folder is a file card** in the document (`CanvasFolderCard`), so the stored path can't say
    /// which it is; `isFolder` asks the disk, through the board's resolver.
    ///
    /// `liveTitle` is what a running card's page calls itself right now, which beats the remembered
    /// name for the one card it belongs to. See `CanvasBoardView.describeCard`.
    static func lookups(isFolder: @escaping (String) -> Bool = { _ in false },
                        liveTitle: String? = nil) -> CanvasItemLookups {
        CanvasItemLookups(isFolder: isFolder,
                          pageTitle: { liveTitle ?? CanvasPageTitles.of($0) },
                          viewTitle: { CanvasViewSpec.of($0)?.cardName })
    }

    /// The cards not in `shown`, grouped and ordered for a menu. Empty when every card is showing.
    static func sections(of document: CanvasDocument, showing shown: [String], first: String? = nil,
                         isFolder: @escaping (String) -> Bool = { _ in false }) -> [Section] {
        CanvasItems.sections(of: document, showing: shown, first: first,
                             lookups: lookups(isFolder: isFolder))
    }

    /// What one card is called in the list, and what stands beside it — which is also how a tile's tab
    /// and a dragged tile's proxy name it. Use `CanvasBoardView.describeCard`, which knows the folders.
    static func card(_ node: CanvasNode, isFolder: @escaping (String) -> Bool = { _ in false },
                     liveTitle: String? = nil) -> Card? {
        CanvasItem.of(node, lookups: lookups(isFolder: isFolder, liveTitle: liveTitle))
    }
}
