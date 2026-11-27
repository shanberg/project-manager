import Foundation
import PmLib

/// Closing under a space's or project's frame: a tile is a tab. The decisions, apart from the window,
/// so they can be tested; `SpaceFrame.close` acts on them. docs/spaces.md § Closing.
enum SpaceClosing {
    /// What closing some cards does to the layout.
    struct Plan: Equatable {
        /// The card in front, closing, and the card that takes its slot (not up yet).
        var replace: (closing: String, with: String)?
        /// Closing cards that leave the layout, which closes up round them.
        var leave: [String]
        /// The card brought forward afterwards, if any: the slot's new card, or a tab already up.
        var next: String?

        static func == (a: Plan, b: Plan) -> Bool {
            a.replace?.closing == b.replace?.closing && a.replace?.with == b.replace?.with
                && a.leave == b.leave && a.next == b.next
        }
    }

    /// The layout's part of closing `ids`. `front` is the card in front; `recent` the cards in front
    /// most recently first; `exists` whether a card is on the board.
    ///
    /// The card in front, if it closes, goes as a browser's tab does:
    /// - a tab in a tile of several: the tab of that tile in front most lately comes forward;
    /// - a tile among others (a split): the tile goes and the layout closes up, as Arc's;
    /// - the only tile: the card in front before it, from anywhere on the board, takes its slot —
    ///   unless `fillsSlot` is false (a named layout, whose cards are its own: § Cards in layouts).
    /// With nothing remembered, the layout's own rule: the neighbouring tab or tile, or the board.
    static func plan(closing ids: [String], front: String?, tiling: CanvasTileSession, recent: [String],
                     fillsSlot: Bool = true, exists: (String) -> Bool) -> Plan {
        let up = ids.filter(tiling.cards.contains)
        guard !up.isEmpty else { return Plan(replace: nil, leave: [], next: nil) }
        let going = Set(ids)
        let closingFront = front.flatMap { front in up.first { $0 == front } }
        var next: String?
        if let closingFront {
            let tabs = tiling.tabs(of: closingFront)
            if tabs.count > 1 {
                next = nextFront(closing: closingFront, recent: recent, tabs: tabs) {
                    exists($0) && !going.contains($0)
                }
            } else if tiling.ids.count == 1, fillsSlot {
                next = nextFront(closing: closingFront, recent: recent, tabs: []) {
                    exists($0) && !going.contains($0) && !tiling.cards.contains($0)
                }
            }
        }
        if let closingFront, let next, !tiling.cards.contains(next) {
            return Plan(replace: (closingFront, next), leave: up.filter { $0 != closingFront }, next: next)
        }
        return Plan(replace: nil, leave: up, next: next)
    }

    /// The card in front before `closed` that is still on the board (`recent`, most recent first) —
    /// one of `tabs` when it had others, so closing a tab stays in its tile.
    static func nextFront(closing closed: String, recent: [String], tabs: [String],
                          exists: (String) -> Bool) -> String? {
        let candidates = recent.filter { $0 != closed && exists($0) }
        if tabs.count > 1 { return candidates.first(where: tabs.contains) }
        return candidates.first
    }

    /// Cards off a board, their lines with them.
    static func takeOff(_ ids: Set<String>, from document: inout CanvasDocument) {
        document.nodes.removeAll { ids.contains($0.id) }
        document.edges.removeAll { ids.contains($0.id) || ids.contains($0.fromNode) || ids.contains($0.toNode) }
    }

    /// Cards back on a board as they were — Undo, Keep, ⇧⌘T — and their lines to cards that are there.
    /// A card already back (⌘Z) is left as it is.
    static func putBack(_ nodes: [CanvasNode], edges: [CanvasEdge], into document: inout CanvasDocument) {
        for node in nodes where document.node(id: node.id) == nil { document.nodes.append(node) }
        let ids = Set(document.nodes.map(\.id)), have = Set(document.edges.map(\.id))
        for edge in edges where !have.contains(edge.id) && ids.contains(edge.fromNode) && ids.contains(edge.toNode) {
            document.edges.append(edge)
        }
    }
}

/// Cards in layouts (docs/spaces.md § Cards in layouts): an unpinned card lives in one place, Today /
/// Cards or one layout; a card in two layouts is pinned. The decisions, apart from the sidebar.
enum SpaceLayoutCards {
    /// The layouts holding each card, in the order given (the sidebar's).
    static func membership(_ layouts: [(name: String, cards: [String])]) -> [String: [String]] {
        var held: [String: [String]] = [:]
        for layout in layouts {
            for id in Set(layout.cards) { held[id, default: []].append(layout.name) }
        }
        return held
    }

    /// Unpinned cards in two or more layouts, which are pinned for you. `exempt`: the project's notes.
    static func toPin(_ held: [String: [String]], isPinned: (String) -> Bool, exempt: String? = nil) -> [String] {
        held.filter { $0.value.count > 1 && $0.key != exempt && !isPinned($0.key) }.keys.sorted()
    }

    /// The layouts a card has joined since `before`.
    static func joined(_ id: String, now: [String: [String]], before: [String: [String]]) -> [String] {
        let was = Set(before[id] ?? [])
        return (now[id] ?? []).filter { !was.contains($0) }
    }

    /// The layouts left with no cards once `going` have left them (cards gone from the board count as
    /// gone).
    static func emptied(by going: Set<String>, layouts: [(name: String, cards: [String])],
                        exists: (String) -> Bool) -> [String] {
        layouts.filter { layout in
            !layout.cards.isEmpty && layout.cards.allSatisfy { going.contains($0) || !exists($0) }
        }.map(\.name)
    }
}
