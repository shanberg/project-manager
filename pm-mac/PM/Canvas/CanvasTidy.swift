import Foundation
import PmLib

/// Tidy Up: a rough cluster of cards laid back out as a clean grid (backlog 7).
///
/// FigJam's, and not the tiling's. A tiling is a way of looking that leaves the file alone; this edits
/// the document, as one undoable change, and the board stays a board afterwards.
///
/// **The rows people meant stay rows, and the columns line up.** Each row is as tall as its tallest
/// card and each column as wide as its widest, with a 20pt gutter — the one a multi-card drop already
/// uses, on the 10pt lattice a drag snaps to. Cards keep their sizes and sit at the top-left of their
/// cell, which is where a card that has been snapped by hand sits too.
///
/// **Running it twice changes nothing.** That is the property the row rule is chosen for, and why it
/// is not `CanvasTiling.order`'s: that one bands cards by their middles, and a tidied row of a 400pt
/// card beside a 60pt note has its middles 170 points apart, so a second tidy would split the row it
/// had just made.
enum CanvasTidy {

    /// The gutter between two cards, and between a frame's edge and what it holds.
    static let gap: Double = 20

    /// What a Tidy Up on `selection` would do: the new frame of every node that moves, or nil when
    /// there is nothing to tidy.
    ///
    /// Two or more selected cards tidy among themselves. One frame selected alone tidies what it holds,
    /// inside it, and the frame grows if the grid needs more room than it has — never shrinks, because
    /// the space in a frame is often the point of it. A frame in a larger selection is one item like
    /// any card, and carries what it holds with it, the way a drag does.
    static func plan(_ selection: Set<String>, in document: CanvasDocument) -> [String: CanvasRect]? {
        let nodes = Dictionary(document.nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        let items: [String]
        let origin: CanvasPoint?
        var frame: CanvasNode?
        if selection.count == 1, let only = selection.first, let group = nodes[only], group.isGroup {
            items = outermost(document.nodes.filter { $0.id != group.id && group.frame.contains($0.frame) },
                              in: document)
            origin = CanvasPoint(x: group.frame.minX + gap, y: group.frame.minY + gap)
            frame = group
        } else {
            items = outermost(document.nodes.filter { selection.contains($0.id) }, in: document)
            origin = nil
        }
        guard items.count >= (frame == nil ? 2 : 1) else { return nil }

        let placed = grid(items.compactMap { id in nodes[id].map { (id: id, frame: $0.frame) } },
                          at: origin)
        var out: [String: CanvasRect] = [:]
        for (id, to) in placed {
            guard let from = nodes[id]?.frame else { continue }
            let dx = to.minX - from.minX, dy = to.minY - from.minY
            guard dx != 0 || dy != 0 else { continue }
            for moving in canvasDragSet([id], in: document) {
                guard let node = nodes[moving] else { continue }
                var moved = node.frame
                moved.x += dx; moved.y += dy
                out[moving] = moved
            }
        }

        if let group = frame, let box = placed.values.reduce(nil, { $0?.union($1) ?? $1 }) {
            let needed = CanvasRect(x: group.frame.minX, y: group.frame.minY,
                                    width: max(group.frame.width, box.maxX + gap - group.frame.minX),
                                    height: max(group.frame.height, box.maxY + gap - group.frame.minY))
            if needed != group.frame { out[group.id] = needed }
        }
        return out
    }

    /// Where each card goes in the grid, keyed by id.
    ///
    /// `origin` is the grid's top-left; nil keeps the cards where they are, at the top-left of the box
    /// around them, brought onto the 10pt lattice.
    static func grid(_ cards: [(id: String, frame: CanvasRect)], at origin: CanvasPoint? = nil)
        -> [String: CanvasRect] {
        guard !cards.isEmpty else { return [:] }
        let rows = rows(cards)
        let start = origin ?? {
            let lattice = CanvasSnapping.grid
            let minX = cards.map(\.frame.minX).min()!, minY = cards.map(\.frame.minY).min()!
            return CanvasPoint(x: (minX / lattice).rounded() * lattice, y: (minY / lattice).rounded() * lattice)
        }()

        let columns = rows.map(\.count).max() ?? 0
        let widths = (0..<columns).map { column in
            rows.compactMap { column < $0.count ? $0[column].frame.width : nil }.max() ?? 0
        }
        var out: [String: CanvasRect] = [:]
        var y = start.y
        for row in rows {
            var x = start.x
            for (column, card) in row.enumerated() {
                out[card.id] = CanvasRect(x: x, y: y, width: card.frame.width, height: card.frame.height)
                x += widths[column] + gap
            }
            y += (row.map(\.frame.height).max() ?? 0) + gap
        }
        return out
    }

    /// The rows the cards were meant to be in, top to bottom, each left to right.
    ///
    /// A card joins a row when its top is above the middle of the row's first card — or within 20pt of
    /// that card's top, so two small notes a little out of true still share a row. Read off the top
    /// edge because a tidied row is top-aligned, which is what makes a second tidy a no-op.
    static func rows(_ cards: [(id: String, frame: CanvasRect)]) -> [[(id: String, frame: CanvasRect)]] {
        var rows: [[(id: String, frame: CanvasRect)]] = []
        let sorted = cards.sorted { ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX) }
        for card in sorted {
            if let first = rows.last?.first,
               card.frame.minY - first.frame.minY <= max(first.frame.height / 2, gap) {
                rows[rows.count - 1].append(card)
            } else {
                rows.append([card])
            }
        }
        return rows.map { $0.sorted { $0.frame.minX < $1.frame.minX } }
    }

    /// The items among `nodes` that are not inside another frame among them — those move with it.
    private static func outermost(_ nodes: [CanvasNode], in document: CanvasDocument) -> [String] {
        let groups = nodes.filter(\.isGroup)
        return nodes.filter { node in
            !groups.contains { $0.id != node.id && $0.frame.contains(node.frame) }
        }.map(\.id)
    }
}
