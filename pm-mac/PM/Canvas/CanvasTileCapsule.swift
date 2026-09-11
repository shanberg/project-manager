import AppKit
import SwiftUI

/// The focused tile, and everything you can tell it — a capsule of its own between the page's and the
/// board's.
///
/// **Because a tile has no chrome and that is deliberate.** The handlebar is out in the gap and does
/// one thing, a drag; nothing is drawn on the card, because a tiled view is for reading the cards and
/// chrome laid over the thing being read is chrome in the way (see `CanvasBoardView.tileHandle`). That
/// left every verb a tile has reachable only by right-clicking it — which is a thing you have to
/// already know is there. The window frame is the one place these can be visible without being on top
/// of the page.
///
/// **Two fixed slots**, and the fixedness is the design rather than an accident of what fitted. The
/// verbs are conditional — a grid has no master to promote into, a grid of both rows and columns has no
/// run to pin along — and a row of buttons that appear and disappear with those conditions would change
/// width every time you clicked a different tile, shoving the address field along under a pointer
/// already on its way to it. That is the failure `CanvasPageCapsule` was split out to fix. A menu is
/// allowed to change its items; a toolbar is not. So the conditional ones live in the overflow, and the
/// one that is always true — maximize — gets the button.
///
/// **It appears only where all of that is true**: a tiled view, more than one tile, and exactly one of
/// them focused. A workspace of one tile is the project-note view, which has nothing to promote,
/// nothing to pin and nothing to maximize; several tiles picked at once is a bulk selection, and bulk
/// acts belong to the contextual menu on the things themselves.
struct CanvasTileCapsule: View {
    @ObservedObject var model: CanvasHeaderModel
    let tile: CanvasHeaderModel.TileControls
    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        HeaderCapsule(chrome: HeaderChrome(active: controlActiveState)) {
            HeaderSymbolButton(symbol: tile.isMaximized ? "arrow.down.right.and.arrow.up.left"
                                                        : "arrow.up.left.and.arrow.down.right",
                               help: maximizeHelp,
                               action: model.maximizeTile)
            overflow
        }
        // Safe to animate because it doesn't change the capsule's width: a glyph swapped inside a hit
        // area that is the same size either way. Nothing here may animate a change that alters the
        // width — see `CanvasHeaderTrailingChrome`. Which the two fixed slots above were already the
        // design for, and is now also the reason.
        .animation(Motion.animation(.easeOut(duration: 0.18)), value: tile.isMaximized)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Tile controls"))
    }

    /// A tooltip that a changing selection cannot make stale: it says which way the toggle goes, and
    /// the toggle's direction is the same fact its glyph is already showing.
    private var maximizeHelp: String {
        tile.isMaximized ? "Put the workspace back" : "Fill the window with this tile"
    }

    /// The verbs that are not always there.
    ///
    /// Rename and Arrange are **not** here: both are about the workspace rather than about this tile,
    /// and both already have a home — the chip's own menu and the board's view options. A tile menu
    /// carrying them would be the third place to look for one command.
    private var overflow: some View {
        Menu {
            if tile.canPromote {
                Button("Make This the Master Tile", action: model.promoteTile)
            }
            if let pin = tile.pinTitle {
                Button(pin, action: model.pinTile)
            }
            Divider()
            // Last, as Delete is everywhere: it is the one that takes something away. "Remove" rather
            // than "Close" because it destroys nothing — a tile is a view of a card, and the card stays
            // exactly where the board says it is. See `CanvasBoardView.removeFromTiling`.
            Button("Remove from Tiled View", action: model.removeTile)
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: HeaderMetrics.hitWidth, height: HeaderMetrics.itemHeight)
        .headerHoverHighlight()
        .help("What this tile can be told")
    }
}
