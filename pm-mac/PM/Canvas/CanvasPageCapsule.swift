import AppKit
import SwiftUI

/// The window's trailing chrome: the board's controls, and — while you are standing in something on it
/// — that thing's, in a capsule beside them.
///
/// **Two capsules, and it was three.** The third was the page's, separate from the tile's, and the split
/// was drawn at the wrong joint: a tile and the thing inside it are not two scopes you move between,
/// they are one place described twice. On a web tile both were up at once, about the same object, each
/// ending in an `…` of its own — two overflow buttons a few points apart, which is a menu nobody can
/// aim at. So the tile capsule carries the controls for whatever kind of thing the tile holds, and there
/// is one menu at the end of it. See `CanvasTileCapsule`.
///
/// **One hosting view holding the pair**, rather than two views the pane would have to position. They
/// have to stay a pair: the control capsule is pinned to the window's trailing edge and the other grows
/// away from it leftward, which is the whole point of splitting them — stepping into a card must not
/// move Add and the options menu. Two separately-constrained views would have to agree about a gap and
/// about which of them collapses, and that agreement is what an `HStack` already is.
///
/// **A capsule arrives by materializing, and the row never animates.** It had a transition once — a
/// blur replace, over an animated row — and the animation was doing the exact thing the split was there
/// to prevent. A stack lays its children out from its leading edge, and that edge is what moves when the
/// row changes width: Auto Layout takes the origin from `intrinsicContentSize`, which is the settled
/// size and arrives in one step, while SwiftUI interpolates the offsets over the duration. Two clocks
/// for one number. Measured, because it is not obvious from either side — switching between a project
/// tile and a web tile threw the whole row 174 points sideways and slid it back over a fifth of a
/// second. See `HeaderChromeMotionTests`, which also measures the way out that would have kept the
/// animation: a fixed box with the capsules right-aligned in it never moves, and hit-tests the whole
/// band, which is the thing this header is islands to avoid.
///
/// The rule that follows, and it holds one level down too: **nothing in this chrome animates a change
/// that alters its own width.** Opacity, a swapped glyph, a colour, glass coming in — those are free, and
/// they are what is left. So a capsule that comes and goes is a `HeaderPresence`: the row snaps to make
/// room, and then the capsule materializes where it already stands.
struct CanvasHeaderTrailingChrome: View {
    var model: CanvasHeaderModel
    @State private var focus = HeaderPresence<CanvasHeaderModel.Focus>()
    /// The container's own namespace, so each capsule can say which piece of glass it is across a
    /// change of contents — see `headerBacking`. Without it a capsule that changes width arrives as a
    /// shape the container has never seen and its material is built again from nothing, which is what
    /// flashed when you moved between tiles of different kinds.
    @Namespace private var glass

    var body: some View {
        // **One container for both pieces of glass**, because glass cannot sample other glass and
        // pieces in separate containers render inconsistently beside one another. Its spacing is the
        // gap *inside* a capsule, well under the gap between them, so the two stay two at rest rather
        // than pooling into one blob.
        GlassEffectContainer(spacing: HeaderMetrics.gap) {
            // Bottom-aligned, so the capsules share a baseline whatever they turn out to be. They are
            // the same height today — one row of `itemHeight` in the same inset — and centring them
            // would hide it the day one of them isn't.
            HStack(alignment: .bottom, spacing: HeaderMetrics.capsuleGap) {
                // **First, so the scopes widen toward the window's edge**: what you are standing in,
                // then the board it is on. In a tiled view the focused tile *is* the engaged card
                // (`CanvasBoardView.tileClicked` selects and engages together), so one capsule is
                // describing one thing — which is why it is one capsule.
                if let shown = focus.shown {
                    CanvasTileCapsule(model: model, focus: shown)
                        .headerMaterialized(focus.materialized)
                }
                CanvasControlCapsule(model: model)
            }
            // On the row, which is always there — see `HeaderPresence`.
            .headerPresence(of: model.focus, in: $focus)
        }
        // Both capsules are shapes in this container, and each carries its own name inside it.
        .environment(\.headerGlassNamespace, glass)
        // The drop belongs to the row, not to any capsule in it. See `TitlebarDrop`.
        .modifier(TitlebarDrop(model: model))
    }
}

/// The one card whose page is live under your hands, and everything you do to it.
///
/// **Items rather than a capsule**, and it was a capsule. It sat beside the tile's, which on a web tile
/// meant two pieces of glass describing the same object at two scales and each ending in its own `…`.
/// These are now the leading run of `CanvasTileCapsule`, which is where the rest of what that tile can
/// be told already lived.
///
/// **Laid out the way a browser lays this out**: the buttons that move you through history, then where
/// you are, then — only when it applies — the two ways back to where the board says you should be. The
/// address used to come first, which put the one item in the row made of words between two runs of
/// glyphs with `HeaderMetrics.gap` on each side. Four points of air around a hostname is why this felt
/// tight; the reading order is why it felt unfamiliar.
struct CanvasPageControls: View {
    var model: CanvasHeaderModel
    let page: CanvasHeaderModel.Page

    var body: some View {
        Group {
            CanvasBackButton(page: page, back: model.pageBack, backTo: model.pageBackTo)
            HeaderSymbolButton(symbol: "chevron.right", help: "Forward",
                               enabled: page.canGoForward, action: model.pageForward)
            HeaderGap()
            // Reload and Stop are inside the field now, as they are in Safari — see
            // `CanvasAddressField`.
            CanvasAddressField(page: page, width: model.room.addressWidth,
                               openToken: model.addressFocusToken, go: model.pageGo,
                               reload: model.pageReload, hardReload: model.pageHardReload,
                               emptyCacheAndReload: model.pageEmptyCacheAndReload,
                               stop: model.pageStop,
                               candidates: model.addressCandidates)

            // Home and Pin are the two answers to "this card is not on its own address", and there is
            // no such question when it is. Home was permanently present and permanently dimmed before —
            // a control that spends most of its life saying nothing, in the row that had least space to
            // spare. Now the pair arrives with the state it resolves, next to the address that is
            // showing you the problem.
            if page.wandered {
                HeaderGap()
                HeaderSymbolButton(symbol: "house", help: "Back to this card\u{2019}s address",
                                   action: model.pageHome)
                HeaderSymbolButton(symbol: "pin", help: "Set as this card\u{2019}s address",
                                   action: model.pageAdoptAddress)
            }
        }
    }
}

// MARK: - Back, and everywhere Back has been

/// Back, with the pages behind it on a press-and-hold.
///
/// **Zero points**: it is a gesture on a button that was already in the row, which is the whole reason
/// it is here rather than in a slot of its own. It is also what every browser does, so it is a gesture
/// people arrive already knowing — the one objection being that a hidden gesture is one nobody finds,
/// which is the complaint ⌘-click had before it reached a menu. The tooltip says so.
///
/// A `Menu` with a `primaryAction` rather than a long-press gesture and a popover: this is exactly the
/// control AppKit means by that, so the click, the hold, the keyboard path and the accessibility tree
/// are all the system's rather than four things to get right by hand. With nothing behind it the menu
/// would be empty, and an empty menu opening on a hold is worse than nothing happening — so a card with
/// no history gets a plain button.
private struct CanvasBackButton: View {
    let page: CanvasHeaderModel.Page
    let back: () -> Void
    let backTo: (Int) -> Void

    var body: some View {
        if page.back.isEmpty {
            HeaderSymbolButton(symbol: "chevron.left", help: "Back",
                               enabled: page.canGoBack, action: back)
        } else {
            Menu {
                ForEach(Array(page.back.enumerated()), id: \.offset) { step, item in
                    Button(item.title) { backTo(step + 1) }
                }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: HeaderMetrics.iconSize, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: HeaderMetrics.hitWidth, height: HeaderMetrics.itemHeight)
                    .contentShape(Rectangle())
            } primaryAction: {
                back()
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: HeaderMetrics.hitWidth, height: HeaderMetrics.itemHeight)
            .help("Back \u{2014} hold for where you have been")
            .accessibilityLabel(Text("Back"))
        }
    }
}

// MARK: - The window's tabs, in this header

/// The project window's tab bar as the board's header carries it.
///
/// A wrapper for one reason: the drop that puts a piece of this header level with the traffic lights is
/// the canvas header's own (`TitlebarDrop`, which reads measured button metrics off `CanvasHeaderModel`),
/// while the bar itself has to be the same view the task column renders and so cannot know about any of
/// that.
struct CanvasTabBar: View {
    var model: CanvasHeaderModel
    var tabs: ProjectTabModel

    var body: some View {
        ProjectTabBarHost(model: tabs)
            .modifier(TitlebarDrop(model: model))
    }
}
