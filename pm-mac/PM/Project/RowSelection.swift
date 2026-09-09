import AppKit

/// Which rows of a list are picked, and where a range extends from.
///
/// **Value semantics and no views in sight**, for the reason `ProjectTabSet` has them: what a ⇧-click
/// covers, where ↑ lands with nothing selected, what survives a reload — that is arithmetic over an
/// ordered list of keys, and it is the part worth being sure about. Held as a view's `@State` on one
/// surface and as an `ObservableObject`'s field on the other; neither of them owns the rules.
///
/// **Written down because there are now two lists that need it.** The project window's column has had
/// this behaviour since it had rows, spelled out inline. The project card is becoming the same list on
/// a board (docs/canvas-workspaces.md §7d), and a second copy of "what does ⇧-click do" is two answers
/// waiting to drift — the same argument `WorkspaceCommands` makes one layer up.
///
/// A key is whatever the list calls a row: a task's `PMStore.key`, or a session header's `"sess:<n>"`.
/// This type never looks inside one. The *order* comes in with each call rather than being stored,
/// because the rows a list is drawing change with its filter and its find bar, and a selection that
/// remembered an order would answer against a list that is no longer on screen.
struct RowSelection: Equatable {
    /// The picked rows. A set, because a selection has no order of its own — the list supplies it.
    private(set) var keys: Set<String> = []
    /// The row a ⇧-click or ⇧-arrow extends *from* — the last row picked without ⇧.
    private(set) var anchor: String?

    init() {}

    var isEmpty: Bool { keys.isEmpty }
    var count: Int { keys.count }
    func contains(_ key: String) -> Bool { keys.contains(key) }

    /// The one picked row, when exactly one is picked. What a command acting on "the row you are on"
    /// asks for, and nil the moment that question has more than one answer.
    var single: String? { keys.count == 1 ? keys.first : nil }

    // MARK: Picking

    /// A click on a row. The standard Mac list: a plain click takes just that row, ⇧ extends the range
    /// from the anchor, ⌘ toggles the row in and out.
    ///
    /// ⇧ with no anchor falls through to a plain click rather than doing nothing — there is no range
    /// without two ends, and the row you clicked is the honest first one.
    mutating func click(_ key: String, modifiers: NSEvent.ModifierFlags, in rows: [String]) {
        if modifiers.contains(.shift), let anchor {
            keys = Self.range(from: anchor, to: key, in: rows)
        } else if modifiers.contains(.command) {
            if keys.contains(key) { keys.remove(key) } else { keys.insert(key) }
            anchor = key
        } else {
            keys = [key]
            anchor = key
        }
    }

    /// ↑ / ↓. `extending` is ⇧ held: the range grows or shrinks from the anchor rather than moving.
    ///
    /// With nothing selected, ↓ starts at the top and ↑ at the bottom — a list you arrow into from
    /// nowhere should enter at the end you are travelling from. Hands back the row it landed on, which
    /// is what a caller scrolls to; nil when there is nowhere to go.
    ///
    /// **A plain step leaves from the end it is heading for** — ↓ from the last selected row, ↑ from
    /// the first — so arrowing out of a range carries on past it instead of walking back through it.
    ///
    /// **An extending step moves the other end.** A range has a fixed end and a moving one, and the
    /// fixed end is the anchor; ⇧↑ on a range you built downwards has to *shrink* it. Stepping from
    /// the same end a plain step uses would instead jump the far side of the range across the anchor
    /// and grow it upwards, which is the shape of bug you notice as "it went the wrong way".
    @discardableResult
    mutating func step(_ delta: Int, extending: Bool, in rows: [String]) -> String? {
        guard !rows.isEmpty, delta != 0 else { return nil }
        let picked = rows.indices.filter { keys.contains(rows[$0]) }
        let anchorIndex = anchor.flatMap(rows.firstIndex(of:))
        let from: Int
        if extending, let first = picked.first, let last = picked.last {
            // The end that is not the anchor. With the anchor at the top of the range that is the
            // bottom of it, and vice versa; on a single row the two are the same row.
            from = anchorIndex == first ? last : first
        } else {
            from = delta < 0 ? (picked.first ?? rows.count) : (picked.last ?? -1)
        }
        let key = rows[min(max(from + delta, 0), rows.count - 1)]
        if extending {
            let anchor = self.anchor ?? key
            keys = Self.range(from: anchor, to: key, in: rows)
            self.anchor = anchor
        } else {
            keys = [key]
            anchor = key
        }
        return key
    }

    /// ⌘A.
    mutating func selectAll(in rows: [String]) {
        keys = Set(rows)
        anchor = rows.first
    }

    /// Take exactly these rows — what a paste does with what it just landed, the way every Mac list
    /// leaves an insertion selected.
    mutating func select(_ rows: [String]) {
        keys = Set(rows)
        anchor = rows.first
    }

    mutating func clear() {
        keys = []
        anchor = nil
    }

    /// Move the highlight onto a right-clicked row that is not already part of the selection —
    /// Finder's rule, and the other half of `targets(clicked:)`. False when the click landed inside the
    /// selection, which is the caller's cue that there is nothing to redraw.
    @discardableResult
    mutating func revealForContextMenu(_ key: String) -> Bool {
        guard !keys.contains(key) else { return false }
        keys = [key]
        anchor = key
        return true
    }

    /// What a row's command acts on: the whole selection when the clicked row is inside it, and just
    /// that row when it is not. Finder's rule again, and the reason a right-click on an unselected row
    /// moves the highlight first.
    ///
    /// Pure, and it has to stay that way — SwiftUI builds a `.contextMenu`'s content while it builds
    /// the row, so this runs for every visible row on every pass. See `ProjectView.contextTargets`.
    func targets(clicked key: String) -> Set<String> {
        keys.contains(key) ? keys : [key]
    }

    // MARK: Keeping it honest

    /// Drop every key that no longer names a row.
    ///
    /// Keys are document positions, so they only mean anything against the rows currently loaded:
    /// completing a task hides it under the Incomplete filter, a find narrows the list, another window
    /// edits the file. A selection holding keys that are not on screen would keep ⌘N and Return
    /// pointing at rows nobody can see.
    mutating func keep(within rows: [String]) {
        let live = Set(rows)
        guard !keys.isSubset(of: live) else { return }
        keys.formIntersection(live)
        if let anchor, !live.contains(anchor) { self.anchor = nil }
    }

    /// Drop the keys a predicate names — the collapse of a section whose rows stop existing rather than
    /// stop being drawn.
    mutating func remove(where drop: (String) -> Bool) {
        keys = keys.filter { !drop($0) }
        if let anchor, drop(anchor) { self.anchor = nil }
    }

    /// Every row between two rows inclusive, in the order the list is drawing them. A range whose ends
    /// are not both on screen collapses to the row that was clicked, which is the only end still real.
    static func range(from anchor: String, to key: String, in rows: [String]) -> Set<String> {
        guard let i = rows.firstIndex(of: anchor), let j = rows.firstIndex(of: key) else { return [key] }
        return Set(rows[min(i, j)...max(i, j)])
    }
}
