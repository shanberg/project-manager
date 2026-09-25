import AppKit
import PmLib

/// The chrome a tiled view puts on its tiles: the boundaries you drag to resize, and the grip you drag
/// to reorder.
///
/// Geometry only — where these things are, in canvas coordinates. What a drag on one *means* is in
/// `CanvasBoardView+Input`, and what they look like is in `CanvasOverlayView`. Kept in one place because
/// three files have to agree about it, and a hit area that has drifted from the mark it belongs to is
/// the specific failure that makes a control feel broken rather than missing.
@MainActor
extension CanvasBoardView {

    /// How close the pointer has to be to a boundary, in view points.
    ///
    /// **Half the gap, plus a fixed lap onto the tiles either side.** It used to be a flat 9, which was
    /// the whole of a 9pt gap and lapped 4.5pt onto each neighbour — generous, and deliberately so: a
    /// boundary is a line with no width and has to be catchable anyway. Left flat when the gap came
    /// down to 4 it would have lapped 7pt onto each tile instead, which is a strip along every tile
    /// edge that resizes rather than picks. The lap is the number worth holding still; the gap is not.
    static var dividerReach: Double { CanvasTiling.gap / 2 + 4.5 }

    /// Every boundary in the current tiled view: between each pair of columns, and between each pair of
    /// tiles down every column. See `CanvasTileSession.dividers`.
    var tileDividers: [CanvasTileDivider] { tiling?.dividers ?? [] }

    /// The boundary the pointer is on, if it is on one: near the line, and alongside the stretch of it
    /// that is there. A boundary between two tiles is only as long as their column is wide.
    func tileDivider(at point: CanvasPoint) -> CanvasTileDivider? {
        let reach = Self.dividerReach / liveScale
        return tileDividers.first { divider in
            abs((divider.isVertical ? point.x : point.y) - divider.position) <= reach
                && divider.span.contains(divider.isVertical ? point.y : point.x)
        }
    }

    /// The grip on a tile: the bar that is drawn, and the band that catches a press on it.
    ///
    /// **On the tile, at its top centre, and only when the pointer is near there** (backlog 20,
    /// 2026-09-16 — modelled on how Claude's desktop app moves its panels). It was a bar in the gap on
    /// whichever side faced outwards, which was a consistent rule that put the handle somewhere
    /// different on every tile. The top is where a window is taken hold of, so it is where a tile is.
    ///
    /// It lies over the card, which the gap was chosen to avoid, and that is paid for by appearing only
    /// when asked: it is drawn while the pointer is in the top-centre zone (`tileGripZone`) and nowhere
    /// else, so reading a page never has a control on it. A press has to reach the board over a card
    /// that would otherwise take it, which is `CanvasTileGripView`'s catcher.
    ///
    /// **A tile with tabs across its top has none.** Its strip is already there, and the strip is what
    /// moves it — a tab pulls its card, the rest of the strip carries the tile. One with its tabs down
    /// its side keeps its grip, over the card beside them: a column of tabs can be full to the bottom,
    /// with no bare strip left to take hold of.
    func tileHandle(_ id: String) -> (bar: CanvasRect, hit: CanvasRect)? {
        // A maximized tile keeps its grip, and only so the double-click that got you here is there to
        // take you back — as a zoomed window's title bar still unzooms it. It has no order to be
        // dragged along, so a press on it carries nothing (`tiledMouseDown`). Escape and the menu
        // restore it too, but they are not where the pointer already is.
        guard let tiling, !isPicking, tiling.maximized == nil || tiling.maximized == id, tiling.ids.count > 1,
              !tiling.hasTabs(id) || tiling.tabsOnSide(id), let frame = tiling.layout.frames[id] else { return nil }
        let scale = liveScale
        let bar = CanvasRect(x: frame.midX - Self.gripLength / 2 / scale, y: frame.minY + Self.gripInset / scale,
                             width: Self.gripLength / scale, height: Self.gripThickness / scale)
        // Caught well outside the mark, which is 5pt of line, but only down from the tile's own top edge.
        let hit = CanvasRect(x: frame.midX - Self.gripHitWidth / 2 / scale, y: frame.minY,
                             width: Self.gripHitWidth / scale, height: Self.gripHitHeight / scale)
        return (bar, hit)
    }

    /// The tile whose top-centre zone the pointer is in — the one whose grip shows.
    func tileGripZone(at point: CanvasPoint) -> String? {
        guard let tiling, !isPicking else { return nil }
        let scale = liveScale
        return tiling.ids.first { id in
            guard tileHandle(id) != nil, let frame = tiling.layout.frames[id] else { return false }
            return abs(point.x - frame.midX) <= Self.gripZoneWidth / 2 / scale
                && point.y >= frame.minY && point.y <= frame.minY + Self.gripZoneHeight / scale
        }
    }

    /// Whether this tile is showing its grip: the pointer is near its top centre, and no tile is being
    /// carried — the grips belong to where tiles are, and a drag's preview is drawing where they would be.
    func showsTileHandle(_ id: String) -> Bool {
        if case .placeTile? = gesture { return false }
        return gripTile == id && tileHandle(id) != nil
    }

    /// Tell the grips which tile they belong on now. They fade between there and wherever they were.
    ///
    /// Driven from everything that can change the answer — the pointer moving, a drag starting or
    /// ending, and the layout itself, since a tiling that has gone has no grips at all.
    func refreshTileHandles() {
        tileGripView.shownTileHandles = tiling.map { Set($0.ids.filter(showsTileHandle)) } ?? []
    }

    /// The corners this tile has at the frame of the tile space.
    ///
    /// Here with the dividers and the handlebars because it is the same kind of fact — where a tile
    /// sits in the arrangement — and because the same three files have to agree about it. What the two
    /// radii are, and why there are two, is `CanvasTiling.Corners`; who draws them is
    /// `CanvasNodeView.chromeRadii` and `CanvasOverlayView.drawSwapInFlight`.
    ///
    /// Nil when nothing is tiled or this card isn't in the tiling, which is the caller's cue to use the
    /// card's own one radius.
    func tileCorners(_ id: String) -> CanvasTiling.Corners? {
        guard let tiling, let frame = tiling.layout.frames[id] else { return nil }
        return CanvasTiling.corners(of: frame, in: CanvasTiling.space(of: tiling.area))
    }

    /// The tile whose grip is under the pointer — only a grip that is showing, since one that isn't
    /// is a stretch of somebody's page.
    func tileHandle(at point: CanvasPoint) -> String? {
        guard let tiling else { return nil }
        return tiling.ids.first { id in
            guard showsTileHandle(id), let handle = tileHandle(id) else { return false }
            return handle.hit.contains(x: point.x, y: point.y)
        }
    }

    /// The grip's size, where it sits and how far round it a press counts, and the zone that brings it
    /// up — all in view points over the zoom, like the rest of the board's chrome.
    static let gripLength: Double = 36
    static let gripThickness: Double = 5
    static let gripInset: Double = 7
    static let gripHitWidth: Double = 72
    static let gripHitHeight: Double = 20
    static let gripZoneWidth: Double = 160
    static let gripZoneHeight: Double = 34
}
