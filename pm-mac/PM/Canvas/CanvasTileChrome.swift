import AppKit
import PmLib

/// One draggable boundary between two tiles.
struct CanvasTileDivider: Equatable {
    /// True for a vertical line — one you drag left and right. The tiles it separates are laid out
    /// along x; a horizontal divider separates tiles laid out along y.
    var isVertical: Bool
    /// Where the line is, on the axis it moves along.
    var position: Double
    /// The run this belongs to, as positions in the session's `ids`, and which of them the line is
    /// after. A run is the set of tiles that share out one length — the stack, a single-row grid, or
    /// the master and the stack taken as two things.
    var run: [Int]
    var before: Int
    /// The master/stack split, which is a fraction of the window rather than two lengths — unless the
    /// master has been pinned, in which case it is points like anything else.
    var isMasterSplit: Bool
}

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
    static let dividerReach: Double = 9

    /// Every boundary in the current tiled view.
    ///
    /// Empty for a grid of more than one row *and* one column: there, a boundary is a whole column's or
    /// row's, shared by tiles that were never asked — see `CanvasTiling.grid`.
    var tileDividers: [CanvasTileDivider] {
        guard let tiling, tiling.ids.count > 1 else { return [] }
        let frames = tiling.layout.frames
        let half = CanvasTiling.gap / 2

        switch tiling.arrangement {
        case .masterStack:
            var dividers: [CanvasTileDivider] = []
            if let master = frames[tiling.ids[0]] {
                dividers.append(CanvasTileDivider(isVertical: true, position: master.maxX + half,
                                                  run: [0, 1], before: 0, isMasterSplit: true))
            }
            let stack = Array(1..<tiling.ids.count)
            for (n, index) in stack.dropLast().enumerated() {
                guard let rect = frames[tiling.ids[index]] else { continue }
                dividers.append(CanvasTileDivider(isVertical: false, position: rect.maxY + half,
                                                  run: stack, before: n, isMasterSplit: false))
            }
            return dividers

        case .grid:
            guard let horizontal = gridRunIsHorizontal else { return [] }
            let run = Array(tiling.ids.indices)
            return run.dropLast().compactMap { index in
                guard let rect = frames[tiling.ids[index]] else { return nil }
                return CanvasTileDivider(isVertical: horizontal,
                                         position: (horizontal ? rect.maxX : rect.maxY) + half,
                                         run: run, before: index, isMasterSplit: false)
            }
        }
    }

    /// Whether the grid on screen is a single row (`true`), a single column (`false`), or a real grid
    /// of both (`nil`).
    ///
    /// Read off the frames rather than recomputed, so this cannot disagree with what was actually laid
    /// out — `CanvasTiling.grid` picks its column count from the shape of the window, and a second
    /// copy of that arithmetic here would be a second answer to look for the bug in.
    var gridRunIsHorizontal: Bool? {
        guard let tiling, tiling.arrangement == .grid, tiling.ids.count > 1 else { return nil }
        let rects = tiling.ids.compactMap { tiling.layout.frames[$0] }
        guard rects.count == tiling.ids.count, let first = rects.first else { return nil }
        if rects.allSatisfy({ abs($0.minY - first.minY) < 0.5 }) { return true }
        if rects.allSatisfy({ abs($0.minX - first.minX) < 0.5 }) { return false }
        return nil
    }

    /// The boundary the pointer is on, if it is on one.
    func tileDivider(at point: CanvasPoint) -> CanvasTileDivider? {
        let reach = Self.dividerReach / liveScale
        return tileDividers.first { divider in
            abs((divider.isVertical ? point.x : point.y) - divider.position) <= reach
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
        guard let tiling, tiling.ids.count > 1, let index = tiling.ids.firstIndex(of: id),
              let frame = tiling.layout.frames[id] else { return nil }
        let edge: Edge
        switch tiling.arrangement {
        case .masterStack: edge = index == 0 ? .below : .trailing
        case .grid: edge = gridRunIsHorizontal == false ? .leading : .below
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
        if case .reorderTile(let moving, _, _)? = gesture { return moving == id }
        return hovered == id || selection.contains(id)
    }

    /// Tell the grips which tile they belong on now. They fade between there and wherever they were.
    ///
    /// Driven from everything that can change the answer — the pointer moving, the selection, a drag
    /// starting or ending, and the layout itself, since a tiling that has gone has no grips at all.
    func refreshTileHandles() {
        tileHandleView.shownTileHandles = tiling.map { Set($0.ids.filter(showsTileHandle)) } ?? []
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
    static let handleThickness: Double = 3.5
    /// How far outside the tile's edge the bar sits — roughly centred in the 9pt gap.
    static let handleOffset: Double = 3
    static let handleReach: Double = 9
}
