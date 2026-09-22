import Foundation

/// How the canvas is drawn: as the board, as a list, or as a grid (docs/items.md D5).
///
/// **Not a mode.** `CanvasMode` is already the board's own — view or connect — and this is a different
/// axis entirely: the board has both modes whichever way it is being drawn, and a list has neither.
///
/// **Only the canvas tab has one.** A workspace is a tiling of cards and stays one; a frame tab gets
/// the lenses over that frame's items alone, because it is the same read narrowed. The canvas — the
/// whole board, never tiled — is the tab these three belong to.
///
/// **Remembered per canvas, not written into it** (`CanvasViewState`): a lens is a per-machine way of
/// looking, like a tiling and a refresh cadence, and a `.canvas` that syncs and that Obsidian also
/// opens is not the place for one. A project that wants to be a list is a list every time it opens,
/// which is the whole of what the setting is for.
enum CanvasPresentation: String, Codable, CaseIterable {
    /// The spatial board: cards where you put them. What every canvas was and still opens as.
    case board
    /// One row per item, grouped by frame, sorted — the dense index (D3, D4).
    case list
    /// The items' faces at one size, in a uniform grid — the visual index (D8).
    case grid

    /// What the View menu calls it. The Finder's words, because it is the Finder's question.
    var title: String {
        switch self {
        case .board: return "as Board"
        case .list: return "as List"
        case .grid: return "as Grid"
        }
    }

    /// ⌥⌘1…3. The Finder spends ⌘1…4 on exactly this, and ⌘1…9 is Go to Tab here — so the nod is kept
    /// and the modifier is the one the tabs left.
    var keyEquivalent: String {
        switch self {
        case .board: return "1"
        case .list: return "2"
        case .grid: return "3"
        }
    }

    /// Whether the board itself is on screen. Everything a board answers — zoom, tiling, find, the page
    /// controls — is dim in a lens, because there is no board in front of you to answer for.
    var showsBoard: Bool { self == .board }
}
