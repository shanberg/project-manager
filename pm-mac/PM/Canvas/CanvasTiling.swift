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
    ///
    /// **Deliberately about half what a board's cards get.** A card is paper on a desk and needs room
    /// to read as a separate sheet; a tile is a pane let into the ground, and panes that are held far
    /// apart stop reading as one arrangement. See `CanvasPalette.tileGround`, which is the other half
    /// of the same argument — the ground goes darker so the gap can go narrower without the tiles
    /// running together.
    static let gap: Double = 4

    /// The margin around the whole arrangement, which is deliberately wider than the gap between tiles.
    ///
    /// Not one number for both, which is what this briefly was. A gap between two tiles is shared —
    /// each tile contributes half of it — while the margin at the window's edge is the tile's alone and
    /// has a hard frame on the other side of it. Set them equal and the outside reads as about half the
    /// inside, which is the tightness that made "one number" look right in the arithmetic and wrong on
    /// the screen. Half again the gap is the ratio that landed, and it is the ratio these still hold:
    /// both came down together when tiles stopped being cards laid out in rows.
    static let edgeGap: Double = 6

    // MARK: The shape of a tile

    /// A tile's corner where it meets another tile, and where it meets the frame.
    ///
    /// **Two radii, because a tiling has two kinds of corner.** The outside of the arrangement is an
    /// edge you can see past — it wants the softer curve, the one a window has. Everything inside is a
    /// seam between two panes, and a seam drawn at the same radius reads as two rounded rectangles
    /// that happen to be adjacent rather than as one thing divided. Tightening only the inside is what
    /// makes a tiling read as a single object with cuts in it.
    ///
    /// Both are fixed, unlike `CanvasNodeView.cornerRadius(for:)`, which scales with the card. A card's
    /// radius scales because cards come at every size and one number cannot look like one number across
    /// all of them. Tiles are all sized by the same arrangement in the same window, so they are already
    /// of a piece, and a radius that varied between them would be the only thing on screen suggesting
    /// they weren't.
    static let innerRadius: Double = 5
    static let outerRadius: Double = 9

    /// Which of a tile's corners are corners of the tile space itself.
    ///
    /// **Both directions, not either.** A corner goes wide only where it sits at the frame horizontally
    /// *and* vertically. The looser rule — either edge is enough — rounds the master's top-right away
    /// from the divider it is supposed to run parallel with, and softens seams that are the whole
    /// argument for having two radii. Under this rule every tile in a grid gets exactly one wide
    /// corner, the one facing out, and the four of them together trace the outline of the arrangement.
    struct Corners: Equatable {
        var topLeft: Bool
        var topRight: Bool
        var bottomRight: Bool
        var bottomLeft: Bool

        /// A tile that is the whole of the space — the only tile up, or a card on a board.
        static let all = Corners(topLeft: true, topRight: true, bottomRight: true, bottomLeft: true)

        /// The radii these corners get, given the two numbers.
        func radii(inner: Double, outer: Double) -> Radii {
            Radii(topLeft: topLeft ? outer : inner, topRight: topRight ? outer : inner,
                  bottomRight: bottomRight ? outer : inner, bottomLeft: bottomLeft ? outer : inner)
        }
    }

    /// The corners `tile` has, laid out in `area` — which is the region the tiles were placed in, so
    /// `space(of:)` rather than the session's own `area`.
    static func corners(of tile: CanvasRect, in area: CanvasRect) -> Corners {
        // Generous, because these are floating-point ends of a division: a run of three tiles sharing a
        // height lands on the last tile's bottom edge through two roundings.
        let slack = 0.5
        let left = abs(tile.minX - area.minX) < slack
        let right = abs(tile.maxX - area.maxX) < slack
        let top = abs(tile.minY - area.minY) < slack
        let bottom = abs(tile.maxY - area.maxY) < slack
        return Corners(topLeft: top && left, topRight: top && right,
                       bottomRight: bottom && right, bottomLeft: bottom && left)
    }

    /// The radius each corner of a tile is drawn at — what `Corners` becomes once the two numbers are
    /// filled in. Carried as four values rather than a flag and a pair, because everything downstream
    /// of here wants the corner it is drawing, not the rule that decided it.
    struct Radii: Equatable {
        var topLeft: Double
        var topRight: Double
        var bottomRight: Double
        var bottomLeft: Double

        static func uniform(_ radius: Double) -> Radii {
            Radii(topLeft: radius, topRight: radius, bottomRight: radius, bottomLeft: radius)
        }

        /// True when this is really one radius — a card, or a tile with nothing outer about it. The
        /// cheap path: a layer can round itself, and only a mixed set needs a shape to be cut from.
        var isUniform: Bool {
            topLeft == topRight && topRight == bottomRight && bottomRight == bottomLeft
        }

        /// The same corners, `distance` further in. A curve inset from another curve stays parallel to
        /// it only when its radius drops by the inset; equal radii pinch shut at the corners. Used for
        /// the clip inside the hairline — see `CanvasNodeView.layout`.
        func inset(by distance: Double) -> Radii {
            Radii(topLeft: max(0, topLeft - distance), topRight: max(0, topRight - distance),
                  bottomRight: max(0, bottomRight - distance), bottomLeft: max(0, bottomLeft - distance))
        }

        /// The same rule outward, for a ring drawn around the thing rather than inside it.
        func grown(by distance: Double) -> Radii { inset(by: -distance) }

        /// Part way from one set of corners to another, for a card turning into a tile — see
        /// `CanvasBoardView.tiledness`. Corner by corner, because that is the point: a card's four equal
        /// radii do not all arrive at the same number.
        static func mix(_ from: Radii, _ to: Radii, at fraction: Double) -> Radii {
            guard fraction > 0.001 else { return from }
            guard fraction < 0.999 else { return to }
            func step(_ a: Double, _ b: Double) -> Double { a + (b - a) * fraction }
            return Radii(topLeft: step(from.topLeft, to.topLeft),
                         topRight: step(from.topRight, to.topRight),
                         bottomRight: step(from.bottomRight, to.bottomRight),
                         bottomLeft: step(from.bottomLeft, to.bottomLeft))
        }
    }

    /// The room the tiles themselves get: what was on screen, less the margin at the frame.
    ///
    /// Named and shared because two things have to agree about it — `frames` places tiles inside it,
    /// and `corners(of:in:)` decides what is an outer corner by comparing against it. A second copy of
    /// `inset(by: -edgeGap)` is a second answer, and the symptom would be a tiling whose outer corners
    /// were all tight.
    static func space(of area: CanvasRect) -> CanvasRect { area.inset(by: -edgeGap) }

    // MARK: The window, and the part of it tiles get

    /// What stands between everything a window can show and the region its tiles are laid into: the
    /// sidebar the board runs underneath, and the room the floating header needs at the top.
    ///
    /// In canvas points rather than view points, because everything on this side of the board is — the
    /// same inset is worth twice as many canvas points at 50% as it is at 100%.
    struct Margins: Equatable {
        var leading: Double = 0
        var trailing: Double = 0
        var top: Double = 0
    }

    /// The region tiles are laid out in, out of everything the window can show.
    static func area(of visible: CanvasRect, margins: Margins) -> CanvasRect {
        CanvasRect(x: visible.minX + margins.leading,
                   y: visible.minY + margins.top,
                   width: max(minimumArea, visible.width - margins.leading - margins.trailing),
                   height: max(minimumArea, visible.height - margins.top))
    }

    /// **The inverse: where the window has to be looking for that area to be framed as it was measured.**
    ///
    /// Written here, beside the thing it inverts, because it exists at all only as the other half of
    /// `area(of:margins:)` — and the first version of it was not, which cost exactly what leaving two
    /// halves of one piece of arithmetic in two files costs. Entering a workspace measures the area for
    /// the zoom it is about to travel to and then flies the board there, and flying it to the *area's*
    /// centre put every tiling half the header clearance too high and half the sidebar too far left. The
    /// area is not centred in the window: it is pushed down and inward by margins that are only on two
    /// of its four sides, so its middle is not the window's middle.
    ///
    /// Exact except in a window too small to tile, where `minimumArea` has clamped the area and there is
    /// no size left to invert. What is drawn there is wrong by whatever the clamp took, which is the
    /// least of that window's problems.
    static func centre(framing area: CanvasRect, margins: Margins) -> CanvasPoint {
        CanvasPoint(x: area.midX + (margins.trailing - margins.leading) / 2,
                    y: area.midY - margins.top / 2)
    }

    /// The floor on a tiled region, for a window too narrow or too short to honour the margins.
    static let minimumArea: Double = 80

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
    /// two counts, and three places have to say it: the View menu, the contextual menu and the header
    /// button. Three copies of a sentence is three chances for the board to promise one thing in one
    /// menu and something else in another.
    ///
    /// **One meaning per place, and that is new.** This used to fork four ways, because ⌘Return meant
    /// "narrow further" inside a tiled view: with two tiles of six picked it read "Fill Window with
    /// These 2 Tiles", and it only became the way out once there was nothing left to narrow to. So the
    /// key you press to leave a workspace usually did not leave it — it drilled you further in, which
    /// is the one thing a person pressing it at that moment cannot mean. Inside a workspace this is
    /// now always the way out, and the way to look at one tile on its own is Maximize, which is a
    /// different act with a different key and puts everything back afterwards.
    ///
    /// **"Selection", and it used to be a count** — "These 6 Cards" — on the grounds that making a
    /// workspace out of more than you meant is the command's one hazard. It reads as one fixed command
    /// now, because in the contextual menu it sits above a Workspaces submenu listing the ones that
    /// already hold these cards, and a title that changed with every selection made the pair read as
    /// two variable things rather than "make one" beside "the ones there are".
    ///
    /// **A workspace is made out of a selection or not at all.** With nothing selected this used to
    /// tile whatever was on screen; a workspace is a named thing that persists, and making one out of
    /// "whatever you happen to be scrolled to" is a surprise with a name attached. The command is dim
    /// instead, and says what it would make rather than nothing.
    ///
    /// - Parameters:
    ///   - tiled: whether a tiled view is up.
    ///   - targets: how many cards a selection would end up in the workspace, after frames are opened
    ///     out. Zero means nothing is selected, and the command is unavailable.
    static func commandTitle(tiled: Bool, targets: Int) -> String {
        guard !tiled else { return "Show Canvas" }
        return targets > 0 ? "Create Workspace from Selection" : "Create Workspace"
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
        let inner = space(of: area)
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
