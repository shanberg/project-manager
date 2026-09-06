import AppKit
import PmLib

/// A tiled view of some of a board's cards: what is in it, how it is arranged, and how to get out.
///
/// Entered on ⌘Return with a selection, left on Escape. It is a *view* — the file is untouched, and
/// leaving puts every card back where the board says it belongs. See `CanvasLayout`.
struct CanvasTileSession: Equatable {
    /// The cards in the tiling, in the order they are laid out — reading order of where they sit on the
    /// board, so an arrangement preserves the relationships you built rather than scrambling them.
    var ids: [String]
    var arrangement: CanvasTiling.Arrangement
    /// How much of the width the master tile takes, for `masterStack`. Dragged, not typed, and
    /// remembered — see `CanvasTiling.savedMasterFraction`.
    var masterFraction: Double = CanvasTiling.savedMasterFraction
    /// How much room each tile takes along its run, for the ones that aren't simply sharing evenly.
    ///
    /// **Keyed by card, not by position**, which is what makes a size follow a card when the order
    /// changes: reordering and swapping move ids about, and a size stored per slot would stay behind
    /// and hand the moved card its new neighbour's width.
    ///
    /// Absent means `.even`, so a tiling nobody has dragged carries nothing at all.
    var sizes: [String: CanvasTiling.Size] = [:]

    /// The region being filled, in canvas coordinates: what was on screen when you entered.
    var area: CanvasRect
    /// What the board was looking at, so leaving can put it back exactly.
    var restoreVisible: CanvasRect
    /// The zoom the board was at. A tiling is laid out and shown at 100% whatever the board was at —
    /// see `CanvasScrollView.setZoom` — and this is what leaving hands back.
    var restoreZoom: Double = 1

    /// What each tile is asking for, in the order they are laid out.
    var run: [CanvasTiling.Size] { ids.map { sizes[$0] ?? .even } }

    /// The layout this session produces.
    var layout: CanvasLayout {
        let frames = CanvasTiling.frames(arrangement, sizes: run, in: area,
                                         masterFraction: masterFraction)
        return CanvasLayout(frames: Dictionary(uniqueKeysWithValues: zip(ids, frames)),
                            visible: Set(ids))
    }

    /// Put `id` where `other` is and vice versa — a drag inside a tiled view.
    ///
    /// Swapping rather than moving, which is the difference between a tiling manager and a desktop:
    /// there is no free space to move a window *into*, so the only thing a drag can mean is "these two
    /// change places". Every tiling manager works this way and it is the reason dragging in one feels
    /// decisive rather than fiddly.
    mutating func swap(_ id: String, with other: String) {
        guard let a = ids.firstIndex(of: id), let b = ids.firstIndex(of: other), a != b else { return }
        ids.swapAt(a, b)
    }

    /// Take a tile out of the order and put it back at `index` — what the handlebar drags.
    ///
    /// Different from `swap`, and both are wanted. A swap is "these two change places", which is what
    /// dragging a tile onto another means. This is "this one goes *there*", which is the operation you
    /// need to build an order rather than to correct one, and the only one that can move a tile past
    /// two others without disturbing their order.
    mutating func move(_ id: String, to index: Int) {
        guard let from = ids.firstIndex(of: id) else { return }
        let to = min(max(0, index), ids.count - 1)
        guard to != from else { return }
        ids.remove(at: from)
        ids.insert(id, at: to)
    }

    /// Make `id` the master tile, which is what promoting a window means in every manager that has a
    /// master. A no-op in a grid, where no tile is special.
    mutating func promote(_ id: String) {
        guard arrangement == .masterStack, let index = ids.firstIndex(of: id), index != 0 else { return }
        ids.remove(at: index)
        ids.insert(id, at: 0)
    }
}
