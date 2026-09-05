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
    /// How much of the width the master tile takes, for `masterStack`. Dragged, not typed.
    var masterFraction: Double = 0.62
    /// The region being filled, in canvas coordinates: what was on screen when you entered.
    var area: CanvasRect
    /// What the board was looking at, so leaving can put it back exactly.
    var restoreVisible: CanvasRect

    /// The layout this session produces.
    var layout: CanvasLayout {
        let frames = CanvasTiling.frames(arrangement, count: ids.count, in: area,
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

    /// Make `id` the master tile, which is what promoting a window means in every manager that has a
    /// master. A no-op in a grid, where no tile is special.
    mutating func promote(_ id: String) {
        guard arrangement == .masterStack, let index = ids.firstIndex(of: id), index != 0 else { return }
        ids.remove(at: index)
        ids.insert(id, at: 0)
    }
}
