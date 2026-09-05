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
    enum Arrangement: String, CaseIterable {
        case grid, masterStack

        var title: String {
            switch self {
            case .grid: return "Grid"
            case .masterStack: return "Master and Stack"
            }
        }
    }

    /// The gap between tiles, and between the tiles and the window's edge, in canvas points at 100%.
    static let gap: Double = 14

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

    /// The frames `count` tiles get inside `area`.
    static func frames(_ arrangement: Arrangement, count: Int, in area: CanvasRect,
                       masterFraction: Double) -> [CanvasRect] {
        guard count > 0 else { return [] }
        let inner = area.inset(by: -gap)
        guard inner.width > gap, inner.height > gap else { return Array(repeating: area, count: count) }
        guard count > 1 else { return [inner] }

        switch arrangement {
        case .grid: return grid(count: count, in: inner)
        case .masterStack: return masterStack(count: count, in: inner, fraction: masterFraction)
        }
    }

    /// Rows and columns, as square as the area allows.
    ///
    /// The column count is chosen against the area's own proportions rather than being `ceil(sqrt(n))`:
    /// six cards in a wide window want three across and two down, and the same six in a tall one want
    /// two across and three down. A tiling that ignores the shape of the space it is filling produces
    /// letterboxed tiles in one dimension and cramped ones in the other.
    static func grid(count: Int, in area: CanvasRect) -> [CanvasRect] {
        let columns = max(1, min(count, Int((Double(count) * area.width / max(area.height, 1))
            .squareRoot().rounded())))
        let rows = Int((Double(count) / Double(columns)).rounded(.up))
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
    static func masterStack(count: Int, in area: CanvasRect, fraction: Double) -> [CanvasRect] {
        let masterWidth = (area.width - gap) * min(0.85, max(0.3, fraction))
        let master = CanvasRect(x: area.minX, y: area.minY,
                                width: masterWidth, height: area.height)
        let stackWidth = area.width - masterWidth - gap
        let others = count - 1
        let cellHeight = (area.height - gap * Double(others - 1)) / Double(others)

        return [master] + (0..<others).map { index in
            CanvasRect(x: area.maxX - stackWidth, y: area.minY + Double(index) * (cellHeight + gap),
                       width: stackWidth, height: cellHeight)
        }
    }
}
