import Foundation

/// The workspaces you named and kept, per board.
///
/// **A workspace is a particular set of tiles, their relative placement and size, and their pinning —
/// named or not, and ephemeral unless named.** Which is `CanvasViewState.Tiling` field for field, so
/// there is no type here beyond the two stores: the unnamed one lives in `CanvasViewMemory` and naming
/// it promotes it into this file. The word is the whole of what this rename added; the structure was
/// already right. See docs/canvas-workspaces.md §7.
///
/// **A different store from `CanvasViewMemory`, on purpose, and the reason is lifetime** — which is
/// also why "ephemeral unless named" is a fact about where a workspace is kept rather than a rule
/// imposed on top. That memory is volatile: it is rewritten on every change to how you are looking at a
/// board, so that leaving one tiled and coming back finds it tiled. These are deliberate — you built a
/// workspace, you named it, and you expect it to be there next month. Keeping both in one row would
/// mean every pan across a board rewriting the file your named workspaces live in, which is one
/// careless memberwise initialiser away from losing all of them. Same format, different file, different
/// lifetime.
///
/// In defaults rather than in the `.canvas`, for the reason `CanvasViewMemory` already gives: a
/// workspace is a private, per-machine way of looking at a document that Obsidian also opens and git
/// may well be watching, and it must not show up there as an edit.
///
/// The name is the identity. There is nothing else to point at — a workspace's whole content is a list
/// of card ids and some widths — so a tab pinned to one holds its name, and renaming is making a
/// different workspace.
///
/// **The defaults key keeps its old spelling on purpose.** `PMCanvasArrangements` is private to this
/// file and is read by nothing else, so renaming it would buy a tidier string at the cost of every
/// workspace anybody has already saved.
///
/// **There is no "last used" row here, and there was.** It existed because leaving a tiled view
/// un-pins the tab from its workspace, so the stored tab selection was thought unable to answer "which
/// workspace was I in". §7g made that false in the same act that created the need: leaving a workspace
/// now *keeps its chip*, so the row still holds the workspace, and the selection honestly records that
/// you were looking at the whole board when you closed the window. A second store answering the same
/// question could only disagree with the first, and it did — it reopened you into a workspace you had
/// deliberately zoomed out of hours earlier. A tab is where a workspace lives; the selection is which
/// one you were in. See docs/canvas-workspaces.md §7h.
enum CanvasWorkspaces {
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

    /// The names of the workspaces that hold any of these cards, in menu order.
    ///
    /// Any rather than all: right-clicking three cards is asking "where else do these live", and a
    /// workspace holding two of the three is an answer to that, not a near miss.
    static func names(holdingAnyOf ids: Set<String>, of url: URL) -> [String] {
        names(holdingAnyOf: ids, in: of(url))
    }

    /// `names(holdingAnyOf:of:)` over workspaces already read — pure, so it can be pinned in a test.
    static func names(holdingAnyOf ids: Set<String>,
                      in all: [String: CanvasViewState.Tiling]) -> [String] {
        guard !ids.isEmpty else { return [] }
        return all.filter { !ids.isDisjoint(with: $0.value.ids) }.keys
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    static func tiling(named name: String, of url: URL) -> CanvasViewState.Tiling? {
        of(url)[name]
    }

    /// Keep `tiling` under `name`, replacing one already there. Replacing rather than refusing: saving
    /// over a workspace you have adjusted is the common case, and asking about it every time would
    /// make keeping one cost more than rebuilding it.
    static func save(_ tiling: CanvasViewState.Tiling, as name: String, for url: URL) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var all = of(url)
        all[trimmed] = tiling
        write(all, for: url)
    }

    /// Whether this name is already somebody's.
    ///
    /// Asked before a name is *acquired* — named, renamed into, duplicated as — because `save` below
    /// replaces, and the workspace it would replace is not the one you are looking at. See
    /// `WorkspaceNamePrompt.confirmReplacing`.
    static func exists(_ name: String, of url: URL) -> Bool {
        of(url)[name] != nil
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

    private static let defaultsKey = "PMCanvasWorkspaces"

    private static func stored() -> [String: Data] {
        UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Data] ?? [:]
    }

    /// The path, standardized — the same key `CanvasViewMemory` uses, so one board is one row in both.
    private static func key(_ url: URL) -> String { url.standardizedFileURL.path }
}
