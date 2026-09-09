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
    /// Which named workspace `tiling` *is*, or nil for an unnamed one.
    ///
    /// **The one field the whole of §7b rides on.** Without it a board can be in a workspace and have
    /// no way to say which, so naming one produces no visible change, the menu has nothing to tick, and
    /// an adjustment has nowhere to be written back to. `CanvasFocus.workspace(_:)` is not this: that is
    /// a tab *pinned* to a workspace, and a board tiled ad hoc in a whole-board tab has no tab-level
    /// place to record what it is in.
    ///
    /// Optional so a state written before workspaces had names still decodes — as an unnamed one, which
    /// is exactly what it was.
    var workspaceName: String?
    /// How often this board reloads its pages, in seconds, or nil for never.
    ///
    /// A way of looking rather than a fact about the document, which is what puts it here and not in
    /// the `.canvas`: a cadence is a per-machine choice about a board you are watching, and Obsidian
    /// opening the same file has no use for it. Optional so a state written before cadences existed
    /// still decodes.
    var refreshInterval: TimeInterval?
    /// The last one made on this board, kept after leaving it.
    ///
    /// **Leaving a tiled view is not throwing the workspace away.** The order you dragged the tiles
    /// into, the widths you set, the tile you pinned — those took deliberate work, and until now
    /// pressing Escape discarded all of it, so coming back to the same six cards meant building it
    /// again. Escape means "show me the board", not "forget what I did".
    var lastTiling: Tiling?

    /// The tiled view that was up: which cards, in what order, arranged how.
    ///
    /// **This is the workspace**, and the whole of one: a set of tiles, their relative placement (which
    /// is the order), their relative size, and their pinning. Named or not — naming is what promotes a
    /// copy of this into `CanvasWorkspaces`, and it adds nothing to the structure, which is why the
    /// definition needed no designing. See docs/canvas-workspaces.md §7.
    ///
    /// It keeps the name `Tiling` rather than becoming `Workspace` because it is the *data*, and both
    /// stores hold it: the unnamed one that is up, and the named ones you kept. A workspace is a tiling
    /// that may have a name, so the type is a tiling and `CanvasWorkspaces` is where the named ones
    /// live. `CanvasTileSession` is the third of these and the one that is alive — this is what it
    /// flattens down to.
    ///
    /// The order is stored because the order is the placement. Swapping two tiles and promoting one to
    /// master are edits to nothing but this list, so a restore that re-derived it from where the cards
    /// sit on the board would silently undo every one of them.
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
/// however you reached it — through a window's renderer switch, through File ▸ Open Canvas, or in a
/// second window on the same file. One memory for all of them is the only version that cannot disagree
/// with itself.
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

    /// **The workspace this board was left in, read once and forgotten.**
    ///
    /// A carry-over, not a store. Before §7i a board could be *in* a named workspace while its tab said
    /// `.whole`, so the one place that recorded which workspace you were in was this row — and the tab
    /// selection, which is where §7i puts the answer, has nothing to say about a window closed before
    /// then. So a row written by the old code is read for its name on the way in and cleared in the
    /// same act, which is what keeps this from becoming the second store answering "which workspace was
    /// I in" that §7h took a whole section to remove. Nothing writes the field any more; every board
    /// answers nil exactly once and nil for ever after.
    static func takeWorkspaceName(of url: URL) -> String? {
        var state = of(url)
        guard let name = state.workspaceName else { return nil }
        state.workspaceName = nil
        state.tiling = nil
        remember(state, for: url)
        return name
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
