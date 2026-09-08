import Foundation
import PmLib

/// Arranging a handful of cards to fill the window, the way a tiling window manager arranges windows.
///
/// Pure geometry, so it can be reasoned about and tested without a board. What it is *for* is the
/// argument in `CanvasLayout`: a canvas is a spatial document and its positions mean something, so
/// tiling is a way of looking rather than a rewrite. This produces the frames a look is made of.
///
/// **Only two arrangements, and both earn it.** A grid, for "show me these nine at once". And a
/// master-stack — one large card with the rest down the side — because that is the literal shape of a
/// dashboard: the thing you are working in, plus the things you are watching. BSP, which is what most
/// tiling managers default to, is deliberately absent: it is a scheme for windows that arrive one at a
/// time and split whatever had focus, and a board's cards all exist already.
enum CanvasTiling {
    enum Arrangement: String, CaseIterable, Codable {
        case grid, masterStack

        var title: String {
            switch self {
            case .grid: return "Grid"
            case .masterStack: return "Master and Stack"
            }
        }
    }

    /// The gap between two tiles, in canvas points at 100%.
    static let gap: Double = 9

    /// The margin around the whole arrangement, which is deliberately wider than the gap between tiles.
    ///
    /// Not one number for both, which is what this briefly was. A gap between two tiles is shared —
    /// each tile contributes half of it — while the margin at the window's edge is the tile's alone and
    /// has a hard frame on the other side of it. Set them equal and the outside reads as about half the
    /// inside, which is the tightness that made "one number" look right in the arithmetic and wrong on
    /// the screen. Half again the gap is the ratio that landed; both were then taken to two thirds of
    /// what they were, which is the tightness that reads right without the tiles touching.
    static let edgeGap: Double = 13

    // MARK: What you chose last time

    /// The arrangement and the split you last set, remembered app-wide.
    ///
    /// App-wide rather than per board, and deliberately: this is a preference about how *you* like to
    /// look at a set of cards, not a fact about any one canvas. Somebody who works master-and-stack
    /// works that way on every board, and having to say so again on each one would be the app noticing
    /// the answer and then asking the question anyway.
    ///
    /// Unset until you choose, so a first tiling still gets the count-based guess — three cards are
    /// peers and a grid says so, while past four one of them is usually the one you are working in.
    /// A guess is a good default and a bad thing to overrule a stated preference with, so the moment
    /// there is a stated one it wins.
    private static let arrangementKey = "PMCanvasTileArrangement"
    private static let fractionKey = "PMCanvasTileMasterFraction"

    static var savedArrangement: Arrangement? {
        get {
            UserDefaults.standard.string(forKey: arrangementKey).flatMap(Arrangement.init(rawValue:))
        }
        set {
            UserDefaults.standard.set(newValue?.rawValue, forKey: arrangementKey)
        }
    }

    /// How much of the width the master tile takes. Dragged rather than typed, and kept because a
    /// divider you drag back to the same place every time is a setting you have already made.
    static var savedMasterFraction: Double {
        get {
            let stored = UserDefaults.standard.double(forKey: fractionKey)
            return stored > 0 ? min(0.85, max(0.3, stored)) : 0.62
        }
        set { UserDefaults.standard.set(min(0.85, max(0.3, newValue)), forKey: fractionKey) }
    }

    // MARK: What the command is called

    /// What ⌘Return will do next, in words.
    ///
    /// Here rather than on the board because it is a decision about wording, it is pure arithmetic on
    /// four counts, and three places now have to say it: the View menu, the contextual menu and the
    /// header button. Three copies of a sentence is three chances for the board to promise one thing in
    /// one menu and something else in another — which it already did, by saying "Leave Tiled View" for
    /// a ⌘Return that was about to drill in.
    ///
    /// It says the count out loud — "These 6 Cards" rather than "Selection" — because the command's
    /// one real hazard is tiling more than you meant to. A frame tiles what is inside it and an empty
    /// selection tiles everything on screen, and both are worth being told before you commit rather
    /// than after the board has rearranged itself.
    ///
    /// - Parameters:
    ///   - tiled: how many tiles are up, or nil when the board is showing itself.
    ///   - picked: how many of those tiles are selected. Meaningless when nothing is tiled.
    ///   - targets: how many cards a selection would end up tiling, after frames are opened out.
    ///     Consulted only when `selected`.
    ///   - selected: whether anything is selected at all.
    static func commandTitle(tiled: Int?, picked: Int, targets: Int, selected: Bool) -> String {
        if let tiled {
            // All of the tiles, or none of them, is not a narrowing — so ⌘Return is the way back out,
            // and the menu has to admit that rather than offering to fill the window again.
            guard picked > 0, picked < tiled else { return "Leave Tiled View" }
            return picked == 1 ? "Fill Window with This Tile"
                               : "Fill Window with These \(picked) Tiles"
        }
        // Nothing selected, so the fallback is whatever is on screen — and that is deliberately *not*
        // counted. The number changes as you scroll, and a title that has to be recomputed on every
        // scroll tick to stay honest is one that will eventually be caught lying. "Visible Cards" is
        // exact at every scroll position, and this is not the case where the count is the useful part.
        guard selected, targets > 0 else { return "Fill Window with Visible Cards" }
        return targets == 1 ? "Fill Window with This Card"
                            : "Fill Window with These \(targets) Cards"
    }

    /// The order cards tile in: reading order of where they actually sit on the board.
    ///
    /// This is what makes it a *canvas's* tiling rather than a generic one. The cards were placed on
    /// purpose, and an arrangement that scattered them into arbitrary cells would throw away the one
    /// thing the board knows that a desktop doesn't. Rows first — cards within a band of each other
    /// vertically read as a row, and are then sorted left to right — because that is how the boards in
    /// this vault are actually built.
    static func order(_ cards: [(id: String, frame: CanvasRect)]) -> [String] {
        guard !cards.isEmpty else { return [] }
        // A row is a band as tall as the median card. Taken from the cards themselves rather than fixed,
        // because a board of 400pt dashboard tiles and a board of 60pt sticky notes disagree about what
        // "the same row" means by an order of magnitude.
        let heights = cards.map(\.frame.height).sorted()
        let band = max(20, heights[heights.count / 2] * 0.6)

        var rows: [[(id: String, frame: CanvasRect)]] = []
        for card in cards.sorted(by: { $0.frame.midY < $1.frame.midY }) {
            if let last = rows.last, let first = last.first,
               abs(card.frame.midY - first.frame.midY) <= band {
                rows[rows.count - 1].append(card)
            } else {
                rows.append([card])
            }
        }
        return rows.flatMap { $0.sorted { $0.frame.midX < $1.frame.midX }.map(\.id) }
    }

    // MARK: How much room each tile gets

    /// How large one tile is along the axis its run flows in.
    ///
    /// **Two kinds, and the difference is what happens when the window changes size.** A flexible tile
    /// holds a *share* of whatever is left, so it grows and shrinks with the window; a pinned one holds
    /// a number of points and doesn't. A sidebar-shaped card — a chat panel, a dashboard, a page that
    /// is unreadable below 380pt — is the case pinning exists for: everything else should absorb the
    /// window's changes and that one should not.
    ///
    /// The weight is a bare number rather than a fraction, and only its ratio to the other weights in
    /// the same run means anything. That is what lets a drag write new weights for two tiles without
    /// having to renormalise the rest — see `CanvasBoardView.dragTileDivider`.
    enum Size: Equatable, Codable, Sendable {
        case flexible(Double)
        case pinned(Double)

        static let even = Size.flexible(1)
    }

    /// The smallest a tile is allowed to get. Below this a card is a coloured rectangle: no title
    /// legible, no content, nothing to tell it from its neighbour.
    static let minimumTile: Double = 64

    /// Lay a run of tiles along one axis: pinned ones take their points, the rest divide what is left.
    ///
    /// `extent` is the room for the tiles themselves — the caller has already taken the gaps out of it,
    /// because the gaps belong to the arrangement and not to any tile.
    ///
    /// **Pins yield rather than overflowing.** A pin is a request, and a request that would push tiles
    /// out of the window has to lose: the flexible tiles are held at the minimum and the pins are
    /// scaled down to fit what is left. A pinned sidebar in a window dragged to half its width becomes
    /// a narrower sidebar, and widening the window again gives it its number back — the pin is not
    /// destroyed by the squeeze, only overruled while it can't be honoured.
    static func run(_ sizes: [Size], across extent: Double) -> [Double] {
        guard !sizes.isEmpty else { return [] }
        // The floor gives way too, on a window too small to hold even the minimums: everything shares
        // equally rather than the first few tiles taking all of it and the rest getting nothing.
        let floor = min(minimumTile, extent / Double(sizes.count))

        var pinned: [Double?] = sizes.map {
            if case .pinned(let points) = $0 { return max(floor, points) }
            return nil
        }
        let flexible = sizes.indices.filter { pinned[$0] == nil }
        let needed = floor * Double(flexible.count)
        let claimed = pinned.compactMap { $0 }.reduce(0, +)
        if claimed + needed > extent {
            let allowed = max(0, extent - needed)
            let scale = claimed > 0 ? allowed / claimed : 0
            for index in pinned.indices where pinned[index] != nil { pinned[index]! *= scale }
        }

        var lengths = pinned.map { $0 ?? 0 }
        let free = max(0, extent - lengths.reduce(0, +))
        let weights = flexible.map { index -> Double in
            if case .flexible(let weight) = sizes[index] { return max(0.001, weight) }
            return 1
        }
        let total = weights.reduce(0, +)
        for (n, index) in flexible.enumerated() {
            lengths[index] = total > 0 ? free * weights[n] / total : free / Double(flexible.count)
        }
        return lengths
    }

    /// Where each tile in a run starts, given its length and the gap between them.
    private static func offsets(_ lengths: [Double], from origin: Double) -> [Double] {
        var at = origin
        return lengths.map { length in
            defer { at += length + gap }
            return at
        }
    }

    /// The frames these tiles get inside `area`.
    static func frames(_ arrangement: Arrangement, sizes: [Size], in area: CanvasRect,
                       masterFraction: Double) -> [CanvasRect] {
        let count = sizes.count
        guard count > 0 else { return [] }
        let inner = area.inset(by: -edgeGap)
        guard inner.width > gap, inner.height > gap else { return Array(repeating: area, count: count) }
        guard count > 1 else { return [inner] }

        switch arrangement {
        case .grid: return grid(sizes: sizes, in: inner)
        case .masterStack: return masterStack(sizes: sizes, in: inner, fraction: masterFraction)
        }
    }

    /// Rows and columns, as square as the area allows.
    ///
    /// The column count is chosen against the area's own proportions rather than being `ceil(sqrt(n))`:
    /// six cards in a wide window want three across and two down, and the same six in a tall one want
    /// two across and three down. A tiling that ignores the shape of the space it is filling produces
    /// letterboxed tiles in one dimension and cramped ones in the other.
    /// **A grid of one row, or one column, is a run** — and gets the sizes, because that is what two or
    /// three cards side by side is, and it is where pinning one and stretching the others is most of the
    /// point. A grid of more than one of each keeps even cells and ignores them: a width in a real grid
    /// is a *column's* width, shared by every row, and one tile cannot be given it without either
    /// breaking the columns or resizing cards you never touched.
    static func grid(sizes: [Size], in area: CanvasRect) -> [CanvasRect] {
        let count = sizes.count
        let columns = max(1, min(count, Int((Double(count) * area.width / max(area.height, 1))
            .squareRoot().rounded())))
        let rows = Int((Double(count) / Double(columns)).rounded(.up))
        if rows == 1 {
            let widths = run(sizes, across: area.width - gap * Double(count - 1))
            return zip(offsets(widths, from: area.minX), widths).map {
                CanvasRect(x: $0, y: area.minY, width: $1, height: area.height)
            }
        }
        if columns == 1 {
            let heights = run(sizes, across: area.height - gap * Double(count - 1))
            return zip(offsets(heights, from: area.minY), heights).map {
                CanvasRect(x: area.minX, y: $0, width: area.width, height: $1)
            }
        }
        let cellWidth = (area.width - gap * Double(columns - 1)) / Double(columns)
        let cellHeight = (area.height - gap * Double(rows - 1)) / Double(rows)

        return (0..<count).map { index in
            let row = index / columns
            let column = index % columns
            // The last row is centred rather than left-aligned when it is short. Seven cards in a
            // three-column grid leaves one tile alone under two, and pushed to the left it reads as a
            // mistake; centred it reads as the end of a list.
            let inRow = min(columns, count - row * columns)
            let indent = (area.width - (Double(inRow) * cellWidth + gap * Double(inRow - 1))) / 2
            return CanvasRect(x: area.minX + indent + Double(column) * (cellWidth + gap),
                              y: area.minY + Double(row) * (cellHeight + gap),
                              width: cellWidth, height: cellHeight)
        }
    }

    /// One large tile, and the rest in a column beside it.
    ///
    /// The stack goes on the trailing side and runs top to bottom, which is the arrangement every
    /// manager that offers this uses — and, more to the point, the one that leaves the master tile
    /// starting at the same corner the board's reading order starts at.
    static func masterStack(sizes: [Size], in area: CanvasRect, fraction: Double) -> [CanvasRect] {
        // The master against the stack is itself a run of two — the master, and the stack as one thing.
        // Pinning the master is a width in points; leaving it flexible is the fraction the divider has
        // always meant, which is why that is what an undragged master falls back to.
        let across = area.width - gap
        let masterWidth: Double
        if case .pinned(let points) = sizes[0] {
            masterWidth = min(across - minimumTile, max(minimumTile, points))
        } else {
            masterWidth = across * min(0.85, max(0.3, fraction))
        }
        let master = CanvasRect(x: area.minX, y: area.minY,
                                width: masterWidth, height: area.height)
        let stackWidth = across - masterWidth
        let stack = Array(sizes.dropFirst())
        let heights = run(stack, across: area.height - gap * Double(stack.count - 1))

        return [master] + zip(offsets(heights, from: area.minY), heights).map {
            CanvasRect(x: area.maxX - stackWidth, y: $0, width: stackWidth, height: $1)
        }
    }
}
