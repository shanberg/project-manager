import Foundation

/// The tilings you named and kept, per board.
///
/// **A different store from `CanvasViewMemory`, on purpose, and the reason is lifetime.** That memory
/// is volatile: it is rewritten on every change to how you are looking at a board, so that leaving one
/// tiled and coming back finds it tiled. These are deliberate — you built an arrangement, you named it,
/// and you expect it to be there next month. Keeping both in one row would mean every pan across a
/// board rewriting the file your saved arrangements live in, which is one careless memberwise
/// initialiser away from losing all of them. Same format, different file, different lifetime.
///
/// In defaults rather than in the `.canvas`, for the reason `CanvasViewMemory` already gives: a saved
/// arrangement is a private, per-machine way of looking at a document that Obsidian also opens and git
/// may well be watching, and it must not show up there as an edit.
///
/// The name is the identity. There is nothing else to point at — an arrangement's whole content is a
/// list of card ids and some widths — so a tab pinned to one holds its name, and renaming is making a
/// different arrangement.
enum CanvasArrangements {
    /// Everything saved for this board.
    static func of(_ url: URL) -> [String: CanvasViewState.Tiling] {
        guard let data = stored()[key(url)],
              let all = try? JSONDecoder().decode([String: CanvasViewState.Tiling].self, from: data)
        else { return [:] }
        return all
    }

    /// The names, in the order a menu should list them. Alphabetical rather than by when they were
    /// made: a dictionary has no order to preserve, and a list you look things up in wants the order
    /// you would look them up in.
    static func names(of url: URL) -> [String] {
        of(url).keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    static func tiling(named name: String, of url: URL) -> CanvasViewState.Tiling? {
        of(url)[name]
    }

    /// Keep `tiling` under `name`, replacing one already there. Replacing rather than refusing: saving
    /// over an arrangement you have adjusted is the common case, and asking about it every time would
    /// make keeping one cost more than rebuilding it.
    static func save(_ tiling: CanvasViewState.Tiling, as name: String, for url: URL) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var all = of(url)
        all[trimmed] = tiling
        write(all, for: url)
    }

    static func remove(_ name: String, for url: URL) {
        var all = of(url)
        guard all.removeValue(forKey: name) != nil else { return }
        write(all, for: url)
    }

    private static func write(_ all: [String: CanvasViewState.Tiling], for url: URL) {
        var rows = stored()
        rows[key(url)] = all.isEmpty ? nil : try? JSONEncoder().encode(all)
        UserDefaults.standard.set(rows, forKey: defaultsKey)
    }

    private static let defaultsKey = "PMCanvasArrangements"

    private static func stored() -> [String: Data] {
        UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Data] ?? [:]
    }

    /// The path, standardized — the same key `CanvasViewMemory` uses, so one board is one row in both.
    private static func key(_ url: URL) -> String { url.standardizedFileURL.path }
}
