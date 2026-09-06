import Foundation

/// How a board was last being looked at: the mode it was in, and the tiling that was up.
///
/// A *view* state in the sense `CanvasLayout` means it — nothing here is in the file. The canvas
/// document says where the cards are; this says how you were looking at them, which until now was
/// thrown away every time a window closed. Coming back to a board you had left tiled and finding it
/// untiled is the same class of annoyance as coming back to a window that has moved itself.
struct CanvasViewState: Codable, Equatable {
    var mode: CanvasMode = .view
    /// The tiling that was up, if one was.
    var tiling: Tiling?
    /// The last one made on this board, kept after leaving it.
    ///
    /// **Leaving a tiled view is not throwing the arrangement away.** The order you dragged the tiles
    /// into, the widths you set, the tile you pinned — those took deliberate work, and until now
    /// pressing Escape discarded all of it, so coming back to the same six cards meant building it
    /// again. Escape means "show me the board", not "forget what I did".
    var lastTiling: Tiling?

    /// The tiled view that was up: which cards, in what order, arranged how.
    ///
    /// The order is stored because the order *is* the arrangement. Swapping two tiles and promoting one
    /// to master are edits to nothing but this list, so a restore that re-derived it from where the
    /// cards sit on the board would silently undo every one of them.
    struct Tiling: Codable, Equatable {
        var ids: [String]
        var arrangement: CanvasTiling.Arrangement
        var masterFraction: Double
        /// What each tile was holding — a pinned length, or a share. Optional so a tiling written
        /// before sizes existed still decodes; absent means every tile was sharing evenly.
        var sizes: [String: CanvasTiling.Size]?
    }

    /// A board nobody has done anything to. Stored as nothing at all rather than as a row saying so.
    var isUntouched: Bool { self == CanvasViewState() }
}

/// Where those are kept: one entry per canvas file.
///
/// **Keyed by the file, not by the project.** It is a fact about a board, and a board is one document
/// however you reached it — through a project window's renderer switch, through File ▸ Open Canvas, or
/// as a canvas that belongs to no project at all. One memory for the three of them is the only version
/// that cannot disagree with itself.
///
/// **In defaults, not in the canvas.** Writing "you had these six tiled" into the file would put a
/// private, per-machine, per-person view preference into a document that syncs between machines, that
/// Obsidian also opens, and that git may well be watching. A tiling is not an edit and must not show up
/// as one.
enum CanvasViewMemory {
    static func of(_ url: URL) -> CanvasViewState {
        guard let data = stored()[key(url)],
              let state = try? JSONDecoder().decode(CanvasViewState.self, from: data)
        else { return CanvasViewState() }
        return state
    }

    static func remember(_ state: CanvasViewState, for url: URL) {
        var all = stored()
        let key = key(url)
        guard all[key] != nil || !state.isUntouched else { return }
        all[key] = state.isUntouched ? nil : try? JSONEncoder().encode(state)
        // One row per canvas ever opened would grow for as long as the app is installed. The rows worth
        // dropping are the ones for files that are gone — nothing will ever ask for those again — and
        // the moment to find out is when there are enough of them to be worth the stat calls, not on
        // every tiling.
        if all.count > 60 { all = all.filter { FileManager.default.fileExists(atPath: $0.key) } }
        UserDefaults.standard.set(all, forKey: defaultsKey)
    }

    private static let defaultsKey = "PMCanvasViewState"

    private static func stored() -> [String: Data] {
        UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Data] ?? [:]
    }

    /// The path, standardized — so `/Users/me/Vault/./A.canvas` and `/Users/me/Vault/A.canvas` are one
    /// board rather than two memories of it.
    private static func key(_ url: URL) -> String { url.standardizedFileURL.path }
}
