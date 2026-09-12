import AppKit
import SwiftUI

/// Where you are standing, and everything you can tell it: the controls for whatever kind of thing the
/// focused tile holds, then the verbs the tile itself answers to, then one menu for the rest.
///
/// **Because a tile has no chrome and that is deliberate.** The handlebar is out in the gap and does
/// one thing, a drag; nothing is drawn on the card, because a tiled view is for reading the cards and
/// chrome laid over the thing being read is chrome in the way (see `CanvasBoardView.tileHandle`). That
/// left every verb a tile has reachable only by right-clicking it — which is a thing you have to
/// already know is there. The window frame is the one place these can be visible without being on top
/// of the page.
///
/// **One capsule, and it was two.** The page's controls had a capsule beside this one, and the split was
/// drawn at the wrong joint. In a tiled view the focused tile *is* the engaged card — `tileClicked`
/// selects and engages together — so on a web tile the two were up at once, describing one object at two
/// scales, each ending in an `…` of its own: two overflow buttons a few points apart, which is a menu
/// nobody can aim at. A tile and the thing inside it are not two scopes you move between. They are one
/// place, and the header now says so once.
///
/// **The per-kind run leads, the tile's verbs follow, the menu ends it.** Scopes widening left to right
/// is the rule the whole row follows — the page inside the card, the tile the card is in, then the board
/// in the capsule beside this one — and it is also the reading order: what is this, then where is it,
/// then what else. Today only a web tile has a per-kind run; a project tile or an image will bring
/// their own, into the same slot.
///
/// **Fixed slots outside the menu**, and the fixedness is the design rather than an accident of what
/// fitted. A tile's verbs are conditional — a grid has no master to promote into, a grid of both rows
/// and columns has no run to pin along — and a row of buttons that appeared and disappeared with those
/// conditions would change width every time you clicked a different tile, shoving the address field
/// along under a pointer already on its way to it. A menu is allowed to change its items; a toolbar is
/// not. So the conditional ones live in the menu, and the ones that are always true get buttons.
///
/// **Either half can be missing.** A page with no focused tile is an engaged card on an untiled board;
/// a focused tile with no page is every tile that isn't a web card. The capsule is absent only when
/// both are — see `CanvasHeaderModel.focus`.
struct CanvasTileCapsule: View {
    var model: CanvasHeaderModel
    let focus: CanvasHeaderModel.Focus
    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        // **Named, and this is the capsule the name was needed for.** Its contents change with the kind
        // of tile you are in — a web tile brings a whole run of page controls that a project tile
        // doesn't — so it is the one piece of glass in the header that regularly arrives at a new
        // width while remaining the same piece of glass. See `headerBacking`.
        HeaderCapsule(chrome: HeaderChrome(active: controlActiveState), glass: "focus") {
            if let page = focus.page {
                CanvasPageControls(model: model, page: page)
            }
            if let tile = focus.tile {
                // The air between the two runs, and only when there are two. `groupGap` says "same
                // scope, different job", which is exactly the relation between a page and the tile it
                // is in — a divider would say they were different scopes, and they are not.
                if focus.page != nil { HeaderGap() }
                HeaderSymbolButton(symbol: tile.isMaximized ? "arrow.down.right.and.arrow.up.left"
                                                            : "arrow.up.left.and.arrow.down.right",
                                   help: maximizeHelp(tile),
                                   action: model.maximizeTile)
            }
            // The menu joins the tile's own verbs at the ordinary spacing — it *is* the rest of them,
            // and a gap would make the maximize button a group of one. With no tile run to join it
            // becomes the second group itself, and takes the air.
            if focus.tile == nil { HeaderGap() }
            overflow
        }
        // Safe to animate because neither changes the capsule's width: a glyph swapped inside a hit
        // area that is the same size either way. Nothing here may animate a change that alters the
        // width — see `CanvasHeaderTrailingChrome`. Which is also why stepping from a web tile to a
        // project tile is not animated at all: the capsule stays, its contents change, and the row
        // takes the new width in one frame.
        .animation(Motion.animation(.easeOut(duration: 0.18)), value: focus.tile?.isMaximized)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(label))
    }

    private var label: String {
        guard let host = focus.page?.host, !host.isEmpty else { return "Tile controls" }
        return "Tile controls, " + host
    }

    /// A tooltip that a changing selection cannot make stale: it says which way the toggle goes, and
    /// the toggle's direction is the same fact its glyph is already showing.
    private func maximizeHelp(_ tile: CanvasHeaderModel.TileControls) -> String {
        tile.isMaximized ? "Put the workspace back" : "Fill the window with this tile"
    }

    /// Everything else, in one menu — which is the point of merging the capsules.
    ///
    /// **Innermost first.** The page's items are about the thing you are reading; the tile's are about
    /// the frame around it; Remove takes the frame away and goes last, as Delete does everywhere. A
    /// separator between the two groups rather than a heading, because the titles already say which is
    /// which — "Copy Address" and "Remove from Tiled View" are not going to be confused for each other.
    ///
    /// Rename and Arrange are **not** here: both are about the workspace rather than about this tile,
    /// and both already have a home — the chip's own menu and the board's view options. A tile menu
    /// carrying them would be the third place to look for one command.
    private var overflow: some View {
        Menu {
            if let page = focus.page {
                CanvasPageMenuItems(model: model, page: page)
            }
            if let tile = focus.tile {
                if focus.page != nil { Divider() }
                if tile.canPromote {
                    Button("Make This the Master Tile", action: model.promoteTile)
                }
                if let pin = tile.pinTitle {
                    Button(pin, action: model.pinTile)
                }
                Divider()
                // Last, as Delete is everywhere: it is the one that takes something away. "Remove"
                // rather than "Close" because it destroys nothing — a tile is a view of a card, and the
                // card stays exactly where the board says it is. See `CanvasBoardView.removeFromTiling`.
                Button("Remove from Tiled View", action: model.removeTile)
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: HeaderMetrics.hitWidth, height: HeaderMetrics.itemHeight)
        .headerHoverHighlight()
        .help(focus.tile == nil ? "What this card can be told" : "What this tile can be told")
    }
}
