import AppKit

/// The one place a sidebar row's drag over a board is decided: always the board's.
///
/// AppKit gives a drag to the deepest view under the pointer that is registered for anything on its
/// pasteboard, so every kind of card answered a row for itself. A web page passed rows on to the board;
/// a note's text view and a folder's list kept them; and a row let go in a tile's middle marked nothing
/// and did nothing, while its edges — the board's own, under the card's padding — worked (2026-11-09,
/// worst with one tile, where every middle is a card's). Teaching each card the rule would leave the
/// next kind of card to forget it.
///
/// So the board puts this over everything it holds for exactly as long as one of its own rows is in
/// flight (`SpaceRowDrag.current`), and it hands the board every call. A row means the same thing over
/// every card: what the tiling marks, or nothing. Other drags never see it — it is hidden, and a hidden
/// view is not a drag destination.
@MainActor
final class CanvasRowDropCatcher: NSView {
    weak var board: CanvasBoardView?

    override init(frame: NSRect) {
        super.init(frame: frame)
        isHidden = true
        // The board's own list, so anything the board would be offered this is offered too.
        registerForDraggedTypes(CanvasBoardView.droppedTypes)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // Never a click: it is only up while a drag is, and the mouse is the drag's then.
    override func mouseDown(with event: NSEvent) { board?.mouseDown(with: event) }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        board?.draggingEntered(sender) ?? []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        board?.draggingUpdated(sender) ?? []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { board?.draggingExited(sender) }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        board?.prepareForDragOperation(sender) ?? false
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        board?.performDragOperation(sender) ?? false
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) { board?.concludeDragOperation(sender) }
}
