import AppKit
import PmLib

/// The chrome a tiled view puts on its tiles: the boundaries you drag to resize, and the handlebar you
/// drag to reorder.
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

    /// The handlebar on a tile: the bar that is drawn, and the band that catches a press on it.
    ///
    /// **Outside the tile, not on it.** It used to sit inside the card's own edge, which put a control
    /// on top of whatever the card was showing — a web page, usually — for as long as the tiling was
    /// up. A tiled view is for reading the cards, and chrome laid over the thing being read is chrome
    /// in the way. Out in the gap it belongs to the arrangement, which is what it is about.
    ///
    /// **On the off-axis edge that faces outwards.** A tile in a row moves left and right along it, so
    /// its bar goes underneath; a tile in a column moves up and down, so the bar goes beside it. Where
    /// one of the two side edges is a boundary you can drag — the stack's leading edge, against the
    /// master — the bar takes the other one, so a bar and a divider never share a band.
    func tileHandle(_ id: String) -> (bar: CanvasRect, hit: CanvasRect, edge: Edge)? {
        // A maximized tile has no order to be dragged along, and the bar sits in a gap that is not
        // there. Restoring is Escape, the double-click that got you here, or the menu.
        guard let tiling, !isPicking, tiling.maximized == nil, tiling.ids.count > 1,
              let at = tiling.position(of: id),
              let frame = tiling.layout.frames[id] else { return nil }
        // Below a tile with its column to itself, which moves left and right; beside one sharing its
        // column, which moves up and down — on the first column's leading side and every other's
        // trailing one, which puts it on the window's edge wherever the column has one.
        let edge: Edge
        if tiling.columns[at.column].tiles.count == 1 {
            edge = .below
        } else {
            edge = at.column == 0 ? .leading : .trailing
        }

        let length = Self.handleLength / liveScale
        let thickness = Self.handleThickness / liveScale
        let offset = Self.handleOffset / liveScale
        let bar: CanvasRect
        switch edge {
        case .below:
            bar = CanvasRect(x: frame.midX - length / 2, y: frame.maxY + offset,
                             width: length, height: thickness)
        case .leading:
            bar = CanvasRect(x: frame.minX - offset - thickness, y: frame.midY - length / 2,
                             width: thickness, height: length)
        case .trailing:
            bar = CanvasRect(x: frame.maxX + offset, y: frame.midY - length / 2,
                             width: thickness, height: length)
        }

        // Caught well outside the mark it draws — a hit area the size of a 3pt line is one nobody can
        // use — but never *into* the card, which is what lets a card you have stepped into keep every
        // click inside its own edges.
        let reach = bar.inset(by: Self.handleReach / liveScale)
        var hit = reach
        switch edge {
        case .below: hit = CanvasRect(x: reach.minX, y: max(reach.minY, frame.maxY),
                                      width: reach.width, height: reach.maxY - max(reach.minY, frame.maxY))
        case .leading: hit = CanvasRect(x: reach.minX, y: reach.minY,
                                        width: min(reach.maxX, frame.minX) - reach.minX,
                                        height: reach.height)
        case .trailing: hit = CanvasRect(x: max(reach.minX, frame.maxX), y: reach.minY,
                                         width: reach.maxX - max(reach.minX, frame.maxX),
                                         height: reach.height)
        }
        return (bar, hit, edge)
    }

    /// Which side of a tile its handlebar is on.
    enum Edge { case below, leading, trailing }

    /// Whether this tile is showing its handlebar: the one under the pointer, the one selected, and
    /// the one being dragged — which is the same tile, but stops the grip blinking out at the moment
    /// the pointer leaves the tile it belongs to and enters the gap the bar sits in.
    func showsTileHandle(_ id: String) -> Bool {
        // None while a tile is being carried: the grips belong to where tiles are, and a drag's
        // preview is drawing them where they would be.
        if case .placeTile? = gesture { return false }
        return hovered == id || selection.contains(id)
    }

    /// Tell the grips which tile they belong on now. They fade between there and wherever they were.
    ///
    /// Driven from everything that can change the answer — the pointer moving, the selection, a drag
    /// starting or ending, and the layout itself, since a tiling that has gone has no grips at all.
    func refreshTileHandles() {
        tileHandleView.shownTileHandles = tiling.map { Set($0.ids.filter(showsTileHandle)) } ?? []
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

    /// The tile whose handlebar is under the pointer.
    func tileHandle(at point: CanvasPoint) -> String? {
        guard let tiling else { return nil }
        return tiling.ids.first { id in
            guard let handle = tileHandle(id) else { return false }
            return handle.hit.contains(x: point.x, y: point.y)
        }
    }

    /// The bar's own size, and how far outside it a press still counts — all in view points over the
    /// zoom, like the rest of the board's chrome.
    static let handleLength: Double = 28
    static let handleThickness: Double = 2.5
    /// How far outside the tile's edge the bar sits — centred in the gap, and derived from it rather
    /// than typed.
    ///
    /// The bar has to fit *entirely* in the gap, or it draws over the tile next door, which is the one
    /// thing `tileHandle` exists to prevent. A typed 3 was roughly centred in a 9pt gap and would sit
    /// half on the neighbour in a 4pt one, so the number that stays fixed is the bar's thickness and
    /// this follows from it.
    static var handleOffset: Double { max(0.5, (CanvasTiling.gap - handleThickness) / 2) }
    static let handleReach: Double = 9
}
