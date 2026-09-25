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
/// then what else. A web card's run is its page controls and a folder's is its view toggle; a project
/// card or an image will bring their own, into the same slot.
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
            if let folder = focus.folder {
                // Drawn as where a click goes, as maximize is — see `FolderControls`.
                let next: CanvasFolderView = folder.view == .list ? .icons : .list
                HeaderSymbolButton(symbol: next == .icons ? "square.grid.2x2" : "list.bullet",
                                   help: "View \(next.title)", action: model.toggleFolderView)
            }
            if let tile = focus.tile {
                // The air between the two runs, and only when there are two. `groupGap` says "same
                // scope, different job", which is exactly the relation between a page and the tile it
                // is in — a divider would say they were different scopes, and they are not.
                if hasKindRun { HeaderGap() }
                if tile.isMaximized {
                    HeaderRestoreButton(help: maximizeHelp(tile), action: model.maximizeTile)
                } else {
                    HeaderSymbolButton(symbol: "arrow.up.left.and.arrow.down.right",
                                       help: maximizeHelp(tile),
                                       action: model.maximizeTile)
                }
            }
            // The menu joins the tile's own verbs at the ordinary spacing — it *is* the rest of them,
            // and a gap would make the maximize button a group of one. With no tile run to join it
            // becomes the second group itself, and takes the air.
            // With nothing before it — one card selected, no page, no tile — it is the whole capsule.
            if focus.tile == nil, hasKindRun { HeaderGap() }
            overflow
        }
        // Not animated: Restore is wider than the glyph it replaces, and nothing here may animate a
        // change that alters the width — see `CanvasHeaderTrailingChrome`. Maximizing is the same kind
        // of step as moving from a web tile to a project tile: the capsule stays, its contents change,
        // and the row takes the new width in one frame.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(label))
    }

    /// Whether the capsule leads with controls for the kind of thing you are in — a page's, a folder's.
    private var hasKindRun: Bool { focus.page != nil || focus.folder != nil }

    private var label: String {
        guard let host = focus.page?.host, !host.isEmpty else { return "Tile controls" }
        return "Tile controls, " + host
    }

    /// A tooltip that a changing selection cannot make stale: it says which way the toggle goes, and
    /// the toggle's direction is the same fact its glyph is already showing.
    private func maximizeHelp(_ tile: CanvasHeaderModel.TileControls) -> String {
        switch (tile.isMaximized, tile.isCard) {
        case (true, true): return "Put the canvas back"
        case (false, true): return "Fill the window with this card"
        case (true, false): return "Put the workspace back"
        case (false, false): return "Fill the window with this tile"
        }
    }

    /// Everything else, in one menu — the card's contextual menu, built by the board.
    ///
    /// **One menu, two ways in.** It was a list of its own — the page's items, then four of the tile's —
    /// and that copy was the problem: every command a kind of card added to its right-click menu had to
    /// be added here as well, and the ones nobody remembered were missing from the only menu that is
    /// always on screen. It is now `CanvasBoardView.cardActionsMenu`, which is what right-clicking the
    /// tile gives, so a card's commands arrive here for nothing. See `HeaderMenuButton`.
    private var overflow: some View {
        HeaderMenuButton(symbol: "ellipsis",
                         help: CanvasCardActions.help(count: focus.cards, tile: focus.tile?.isCard == false),
                         openToken: model.cardActionsToken,
                         open: model.showCardActions)
    }
}

/// The way out of a maximized tile or card, while one fills the room: a word and a glyph in the accent,
/// on a tinted capsule, where every other header control is a grey glyph.
///
/// **Louder than its neighbours on purpose.** Maximized is a mode, and the one this app has that hides
/// most of what you had open — every other tile, or the whole board. A glyph-only button the same grey
/// as Back and Reload said nothing about being in it. Escape isn't a dependable way out either: an
/// engaged page takes the first press, and a web app that handles Escape itself takes them all. So the
/// header says the state in words, where the window's own controls are, and the tile underneath keeps
/// all of its room.
struct HeaderRestoreButton: View {
    var help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                    .font(.system(size: HeaderMetrics.iconSize - 2, weight: .semibold))
                Text("Restore")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 10)
            .frame(height: HeaderMetrics.itemHeight)
            .background {
                Capsule().fill(Color.accentColor.opacity(hovering ? 0.24 : 0.16))
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.animation(.easeOut(duration: 0.12)), value: hovering)
        .help(help)
        .accessibilityLabel(Text("Restore"))
        .accessibilityHint(Text(help))
    }
}
