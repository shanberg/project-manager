import CoreGraphics
import Foundation

/// What the overview shows and where its selection is. docs/spaces.md § Overview.
///
/// - Every place in the dock's order: projects, a divider, every space (closed ones dimmed), then +.
/// - Typing finds places: titles starting with what's typed first, then a word that does.
/// - Pure: built from plain values, so moves, finding and reordering are tested without a window
///   (`OverviewModelTests`).
struct OverviewModel: Equatable {
    struct Tile: Equatable {
        /// The dock group's key.
        var key: String
        var title: String
        var isSpace = false
        var isClosed = false
        var isFocused = false
        var isPlaying = false
    }

    /// The + at the end: a new space.
    static let plusKey = "new-space"

    private(set) var tiles: [Tile]
    /// The selected tile's key, or `plusKey`.
    private(set) var selected: String?
    private(set) var query = ""

    init(tiles: [Tile], selected: String?) {
        self.tiles = tiles
        self.selected = selected.flatMap { key in
            key == Self.plusKey || tiles.contains { $0.key == key } ? key : nil
        } ?? tiles.first?.key ?? Self.plusKey
    }

    var projects: [Tile] { visible.filter { !$0.isSpace } }
    var spaces: [Tile] { visible.filter(\.isSpace) }

    /// The tiles typing hasn't hidden, in the dock's order.
    var visible: [Tile] {
        guard !query.isEmpty else { return tiles }
        let found = SpaceOrder.matching(tiles.map { (id: $0.key, title: $0.title) }, query: query).map(\.id)
        return tiles.filter { found.contains($0.key) }
    }

    /// The + shows while nothing is being looked for.
    var showsPlus: Bool { query.isEmpty }

    /// What arrows and Tab walk: the visible tiles, then the +.
    var order: [String] { visible.map(\.key) + (showsPlus ? [Self.plusKey] : []) }

    /// Tab / ⇧Tab, → / ←: along the order, stopping at the ends.
    mutating func move(by step: Int) {
        let keys = order
        guard !keys.isEmpty else { return }
        guard let at = selected.flatMap({ keys.firstIndex(of: $0) }) else { selected = keys.first; return }
        selected = keys[max(0, min(keys.count - 1, at + step))]
    }

    mutating func select(_ key: String) {
        guard order.contains(key) else { return }
        selected = key
    }

    /// A character typed: finds places, selecting the first found.
    mutating func type(_ text: String) {
        query += text
        selected = order.first
    }

    /// Backspace: one character off what's typed.
    mutating func deleteBackward() {
        guard !query.isEmpty else { return }
        query.removeLast()
        if !order.contains(selected ?? "") { selected = order.first }
    }

    /// Esc with something typed: back to every place.
    mutating func clearQuery() { query = "" }

    /// A tile let go before or after another of its kind; projects and spaces never mix.
    mutating func move(_ key: String, to target: String, after: Bool) {
        guard let from = tiles.firstIndex(where: { $0.key == key }),
              let to = tiles.firstIndex(where: { $0.key == target }),
              tiles[from].isSpace == tiles[to].isSpace, key != target else { return }
        let tile = tiles.remove(at: from)
        var at = tiles.firstIndex { $0.key == target } ?? to
        if after { at += 1 }
        tiles.insert(tile, at: at)
    }
}

/// Where the overview's tiles go: one grid, the projects' rows, a divider, then the spaces' rows with the
/// + last. As CSS's `repeat(auto-fill, minmax(minTile, 1fr))`: as many columns as fit, sharing the width.
enum OverviewLayout {
    struct Result: Equatable {
        /// Each cell, picture and name, top-down (a flipped view's coordinates).
        var cells: [CGRect]
        /// The rule between projects and spaces, when there are both.
        var divider: CGRect?
        var columns: Int
        var height: CGFloat
    }

    static let aspect: CGFloat = 10.0 / 16.0
    static let label: CGFloat = 30
    static let gap: CGFloat = 18
    static let rowGap: CGFloat = 20
    static let dividerSpace: CGFloat = 24

    /// The picture's part of a cell.
    static func thumb(of cell: CGRect) -> CGRect {
        CGRect(x: cell.minX, y: cell.minY, width: cell.width, height: cell.width * aspect)
    }

    static func grid(projects: Int, others: Int, width: CGFloat, minTile: CGFloat = 210) -> Result {
        grid(projects: projects, others: others, width: width, columns: max(1, Int((width + gap) / (minTile + gap))))
    }

    static func grid(projects: Int, others: Int, width: CGFloat, columns: Int) -> Result {
        let columns = max(1, columns)
        let tile = (width - gap * CGFloat(columns - 1)) / CGFloat(columns)
        let cellHeight = tile * aspect + label
        var cells: [CGRect] = []
        var y: CGFloat = 0
        func rows(_ count: Int) {
            guard count > 0 else { return }
            for index in 0..<count {
                let column = index % columns, row = index / columns
                cells.append(CGRect(x: CGFloat(column) * (tile + gap), y: y + CGFloat(row) * (cellHeight + rowGap),
                                    width: tile, height: cellHeight))
            }
            let rowCount = (count + columns - 1) / columns
            y += CGFloat(rowCount) * cellHeight + CGFloat(rowCount - 1) * rowGap
        }
        rows(projects)
        var divider: CGRect?
        if projects > 0, others > 0 {
            divider = CGRect(x: 0, y: y + dividerSpace / 2, width: width, height: 1)
            y += dividerSpace
        }
        rows(others)
        return Result(cells: cells, divider: divider, columns: columns, height: y)
    }

    /// As Mission Control: the fewest columns, so the largest tiles, whose grid fits `height`. With
    /// more places than fit even one to a column each, every place in one row a section.
    static func filling(projects: Int, others: Int, width: CGFloat, height: CGFloat) -> Result {
        let count = max(1, projects + others)
        for columns in 1...count {
            let result = grid(projects: projects, others: others, width: width, columns: columns)
            if result.height <= height { return result }
        }
        return grid(projects: projects, others: others, width: width, columns: count)
    }

    /// How much smaller a window out is drawn than its place's own window, and the room between them,
    /// as a share of the own window's height.
    static let satelliteScale: CGFloat = 0.5
    static let satelliteGap: CGFloat = 0.05

    /// A place's windows in a cell's picture area: the first (its own) large; the rest smaller, in a
    /// column beside it on the side each is on screen, top to bottom as on screen, never overlapping;
    /// a column taller than the own window shrinks to its height. The whole scaled to fit, centred across
    /// and sitting on the area's foot, by its name. `frames` are screen rectangles (y up); the result is
    /// top-down, in `frames`' order.
    static func cluster(_ frames: [CGRect], in area: CGRect) -> [CGRect] {
        guard let main = frames.first, main.width > 0, main.height > 0 else { return frames.map { _ in area } }
        let gap = main.height * satelliteGap
        var placed = Array(repeating: CGRect.zero, count: frames.count)
        placed[0] = CGRect(origin: .zero, size: main.size)
        var bounds = placed[0]
        for left in [true, false] {
            let side = frames.indices.dropFirst()
                .filter { (frames[$0].midX < main.midX) == left }
                .sorted { frames[$0].maxY > frames[$1].maxY }
            guard !side.isEmpty else { continue }
            var sizes = side.map { CGSize(width: frames[$0].width * satelliteScale, height: frames[$0].height * satelliteScale) }
            let tall = sizes.reduce(0) { $0 + $1.height } + gap * CGFloat(sizes.count - 1)
            if tall > main.height {
                let shrink = (main.height - gap * CGFloat(sizes.count - 1)) / sizes.reduce(0) { $0 + $1.height }
                sizes = sizes.map { CGSize(width: $0.width * shrink, height: $0.height * shrink) }
            }
            let column = sizes.map(\.width).max() ?? 0
            var y: CGFloat = 0
            for (index, size) in zip(side, sizes) {
                let x = left ? -gap - (column + size.width) / 2 : main.width + gap + (column - size.width) / 2
                placed[index] = CGRect(x: x, y: y, width: size.width, height: size.height)
                bounds = bounds.union(placed[index])
                y += size.height + gap
            }
        }
        let scale = min(area.width / bounds.width, area.height / bounds.height)
        let left = area.midX - bounds.width * scale / 2, top = area.maxY - bounds.height * scale
        return placed.map { rect in
            CGRect(x: left + (rect.minX - bounds.minX) * scale, y: top + (rect.minY - bounds.minY) * scale,
                   width: rect.width * scale, height: rect.height * scale)
        }
    }

    /// From a cell, the one an ↑ or ↓ lands on: the nearest by centre in the next row that way.
    static func vertical(from index: Int, by step: Int, in cells: [CGRect]) -> Int? {
        guard cells.indices.contains(index) else { return nil }
        let here = cells[index]
        let candidates = cells.indices.filter { step > 0 ? cells[$0].minY > here.maxY - 1 : cells[$0].maxY < here.minY + 1 }
        guard let rowY = step > 0 ? candidates.map({ cells[$0].minY }).min() : candidates.map({ cells[$0].minY }).max()
        else { return nil }
        return candidates.filter { abs(cells[$0].minY - rowY) < 1 }
            .min { abs(cells[$0].midX - here.midX) < abs(cells[$1].midX - here.midX) }
    }
}

/// The projects' order in the dock, which the overview's drags set. Projects not placed yet keep the
/// order their windows opened in, after the placed ones.
enum DockOrder {
    static func sorted(_ keys: [String], preferred: [String]) -> [String] {
        let rank = Dictionary(preferred.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return keys.enumerated().sorted { a, b in
            let ra = rank[a.element] ?? Int.max, rb = rank[b.element] ?? Int.max
            return ra == rb ? a.offset < b.offset : ra < rb
        }.map(\.element)
    }

    /// The preferred order after a drag: the keys as they now stand, then any remembered keys not open
    /// now, so a project closed and reopened comes back where it was.
    static func remembered(_ now: [String], previous: [String]) -> [String] {
        now + previous.filter { !now.contains($0) }
    }
}
