import Foundation
import PmLib

/// Arranging a handful of cards to fill the window, the way a tiling window manager arranges windows.
///
/// Pure geometry, so it can be reasoned about and tested without a board. What it is *for* is the
/// argument in `CanvasLayout`: a canvas is a spatial document and its positions mean something, so
/// tiling is a way of looking rather than a rewrite. This produces the frames a look is made of.
///
/// **A workspace is columns of tiles** — a row of columns, each a stack of tiles, each tile a card or
/// several as tabs (docs/canvas-workspaces.md §7k). Two levels and no deeper: enough to say "beside
/// this one" and "below this one", which is every question a tiling manager is asked about place, and
/// nothing a tree would have to be stored for. BSP is absent for that reason rather than the one it
/// used to be, which was that a board's cards all exist already.
///
/// **Grid and master-and-stack are the two ways to fill the columns** — commands, not modes. A grid,
/// for "show me these nine at once", and a master and stack, because that is the literal shape of a
/// dashboard: the thing you are working in, plus the things you are watching. After either has run,
/// the columns are yours to change.
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
        /// the hairline drawn inside a card's edge — see `CanvasNodeView.drawRim`.
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

    // MARK: Peeking

    /// How much of the window is left round a card being peeked at, in window points — enough that it
    /// reads as a card on the board brought close rather than as the window.
    static let peekRoom: Double = 32

    /// **Where to look to peek at a card** (docs/canvas-workspaces.md §7k): the zoom that shows it whole
    /// at a size you can read — its own size where the window has room, smaller where it hasn't, and
    /// never larger, since a card blown up past 100% is not easier to read, only blurrier — and the
    /// centre that puts it in the middle of what the sidebar and the header leave.
    ///
    /// `window` and `margins` are in window points, since the zoom is what is being decided; the centre
    /// is in the board's.
    static func peek(at card: CanvasRect, in window: (width: Double, height: Double),
                     margins: Margins) -> (zoom: Double, centre: CanvasPoint) {
        let room = (width: window.width - margins.leading - margins.trailing - 2 * peekRoom,
                    height: window.height - margins.top - 2 * peekRoom)
        let zoom = max(0.01, min(1, room.width / max(1, card.width), room.height / max(1, card.height)))
        let scaled = Margins(leading: margins.leading / zoom, trailing: margins.trailing / zoom,
                             top: margins.top / zoom)
        return (zoom, centre(framing: card, margins: scaled))
    }

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
        return targets > 0 ? "New Workspace from Selection" : "New Workspace"
    }

    /// The order cards tile in: reading order of where they actually sit on the board.
    ///
    /// The rule itself is `canvasReadingOrder` in PmLib, because a list borrows it too (docs/items.md
    /// D4) and a board is not the only thing that reads a scatter as rows. This is the board's name
    /// for it, which every tiling call site already uses.
    static func order(_ cards: [(id: String, frame: CanvasRect)]) -> [String] {
        canvasReadingOrder(cards)
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

    // MARK: The shape a workspace has

    /// One tile: a card, or several sharing the slot as tabs, and which of them is showing.
    ///
    /// **Tabs are in the shape before anything can make one** (docs/canvas-workspaces.md §7k). This is
    /// what a workspace is saved as, and a shape that grew the field later would be a second
    /// conversion of everything saved in between.
    struct Tile: Codable, Equatable, Sendable {
        var cards: [String]
        var showing: Int
        /// How long it is down its column. The tile's, not the card's: see `CanvasTileSession.columns`.
        var height: Size
        /// Whether its tabs run down its leading side rather than across its top (backlog 36). The
        /// tile's, set from its menu and saved with the workspace, and kept while it has only one card
        /// so the next tab goes where the last ones were.
        var tabsOnSide: Bool

        init(_ cards: [String], showing: Int = 0, height: Size = .even, tabsOnSide: Bool = false) {
            self.cards = cards
            self.showing = showing
            self.height = height
            self.tabsOnSide = tabsOnSide
        }

        private enum CodingKeys: String, CodingKey { case cards, showing, height, tabsOnSide }

        /// Read with the flag optional, since every workspace saved before it has none; and written only
        /// when it is on, so a workspace that never used it is saved exactly as it was.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            cards = try container.decode([String].self, forKey: .cards)
            showing = try container.decode(Int.self, forKey: .showing)
            height = try container.decode(Size.self, forKey: .height)
            tabsOnSide = try container.decodeIfPresent(Bool.self, forKey: .tabsOnSide) ?? false
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(cards, forKey: .cards)
            try container.encode(showing, forKey: .showing)
            try container.encode(height, forKey: .height)
            if tabsOnSide { try container.encode(tabsOnSide, forKey: .tabsOnSide) }
        }

        init(_ card: String, height: Size = .even) { self.init([card], height: height) }

        /// The card that is drawn. Clamped, so an index left stale by a card going away draws the
        /// nearest one rather than nothing.
        var shown: String {
            cards.isEmpty ? "" : cards[min(max(0, showing), cards.count - 1)]
        }
    }

    /// A column: how wide it is, and the tiles stacked down it, top to bottom.
    struct Column: Codable, Equatable, Sendable {
        var width: Size
        var tiles: [Tile]

        init(width: Size = .even, _ tiles: [Tile]) {
            self.width = width
            self.tiles = tiles
        }
    }

    /// How tall a tile's tab strip is, when it holds more than one card. Tuned by eye with the strip's
    /// look (backlog 21, 2026-09-16): 32, which leaves each tab 26 once it is inset from the band.
    static let tabStrip: Double = 32
    /// The widest a tab gets. Two tabs on a wide tile don't want to be two half-tile buttons.
    static let longestTab: Double = 190

    /// Where each tab sits in a strip: side by side from the leading edge, sharing the width, none
    /// wider than `longestTab`. What the strip is drawn by and what a click on it is read against, so
    /// the two cannot disagree.
    ///
    /// Room is kept after the last one for the strip's + (`newTabButton`), so the tabs never run under it.
    static func tabs(in band: CanvasRect, count: Int) -> [CanvasRect] {
        guard count > 0 else { return [] }
        let height = max(0, band.height - 6)
        let room = band.width - tabInset * 2 - gap * Double(count) - height
        let width = min(longestTab, room / Double(count))
        return (0..<count).map {
            CanvasRect(x: band.minX + tabInset + Double($0) * (width + gap), y: band.minY + 3,
                       width: max(0, width), height: height)
        }
    }

    /// The strip's +, a square as tall as a tab, just after the last tab — where a browser puts it, so
    /// it moves along as tabs come and go rather than sitting at the far end of a wide tile.
    static func newTabButton(in band: CanvasRect, count: Int) -> CanvasRect {
        let height = max(0, band.height - 6)
        let after = tabs(in: band, count: count).last.map { $0.maxX + gap } ?? band.minX + tabInset
        return CanvasRect(x: after, y: band.minY + 3, width: height, height: height)
    }

    private static let tabInset = 4.0

    // MARK: Tabs down the side (backlog 36)

    /// How wide a tile's tabs are down its side: an icon and a name, the width a sidebar gives one.
    static let sideStrip: Double = 180
    /// The side strip of a tile too narrow to spare `sideStrip`: a column of icons alone.
    static let iconStrip: Double = 40
    /// The narrowest tile that keeps its tabs' names down its side. Below it, 180 of it would be a third
    /// of the card or more.
    static let sideNamesFrom: Double = 540

    /// Where each tab sits down a side strip: stacked from the top, a top tab's height each, the whole
    /// width of the band — moved up by `scroll`, since a column of tabs longer than its tile scrolls.
    static func sideTabs(in band: CanvasRect, count: Int, scroll: Double = 0) -> [CanvasRect] {
        let height = tabStrip - 6
        return (0..<count).map {
            CanvasRect(x: band.minX + tabInset, y: band.minY + tabInset - scroll + Double($0) * (height + gap),
                       width: max(0, band.width - tabInset * 2), height: height)
        }
    }

    /// The side strip's +, in the row after the last tab: a square at the leading edge beside names, and
    /// the width of the icons in a column of icons, so it lines up with what is above it.
    static func sideNewTabButton(in band: CanvasRect, count: Int, scroll: Double = 0) -> CanvasRect {
        let height = tabStrip - 6
        let width = band.width < sideStrip ? max(0, band.width - tabInset * 2) : height
        return CanvasRect(x: band.minX + tabInset,
                          y: band.minY + tabInset - scroll + Double(count) * (height + gap),
                          width: width, height: height)
    }

    /// How long a side strip's contents are — every tab and the + — which is what it scrolls through.
    static func sideTabsLength(count: Int) -> Double {
        let height = tabStrip - 6
        return tabInset * 2 + Double(count + 1) * height + Double(count) * gap
    }

    /// Where every tile goes inside `area`: a list of frames per column, in the columns' order.
    ///
    /// `run` twice — once across the width for the columns, once down each column for its tiles — so
    /// pinning and sharing mean exactly what they meant when there was one run.
    static func frames(of columns: [Column], in area: CanvasRect) -> [[CanvasRect]] {
        guard !columns.isEmpty else { return [] }
        let inner = space(of: area)
        guard inner.width > gap, inner.height > gap else {
            return columns.map { $0.tiles.map { _ in area } }
        }
        let widths = run(columns.map(\.width), across: inner.width - gap * Double(columns.count - 1))
        return zip(zip(offsets(widths, from: inner.minX), widths), columns).map { place, column in
            let heights = run(column.tiles.map(\.height),
                              across: inner.height - gap * Double(max(0, column.tiles.count - 1)))
            return zip(offsets(heights, from: inner.minY), heights).map {
                CanvasRect(x: place.0, y: $0, width: place.1, height: $1)
            }
        }
    }

    /// Fill columns with these tiles the way `arrangement` lays them out.
    ///
    /// **A command, not a mode.** What comes back is columns like any others, and nothing remembers
    /// which arrangement made them — which is what lets a tile be moved across afterwards without
    /// the arrangement snapping it back.
    ///
    /// The tiles come in reading order and keep their cards and tabs; their sizes are not kept, which
    /// is what makes arranging an even start. `sizes` is for the one caller with lengths to honour: a
    /// workspace saved before columns existed, whose lengths were kept per card. They are honoured
    /// where that arrangement honoured them — along a run — and ignored where it didn't.
    static func columns(_ arrangement: Arrangement, of tiles: [Tile], in area: CanvasRect,
                        masterFraction: Double, sizes: [String: Size] = [:]) -> [Column] {
        func plain(_ tile: Tile) -> Tile { Tile(tile.cards, showing: tile.showing, tabsOnSide: tile.tabsOnSide) }
        func sized(_ tile: Tile) -> Tile {
            Tile(tile.cards, showing: tile.showing, height: sizes[tile.shown] ?? .even, tabsOnSide: tile.tabsOnSide)
        }
        guard tiles.count > 1 else { return tiles.map { Column([plain($0)]) } }

        switch arrangement {
        case .grid:
            // As square as the room allows. The column count is chosen against the area's own
            // proportions rather than being ceil(sqrt(n)): six tiles in a wide window want three
            // across, and the same six in a tall one want two.
            let room = space(of: area)
            let count = tiles.count
            let across = max(1, min(count, Int((Double(count) * room.width / max(room.height, 1))
                .squareRoot().rounded())))
            // Dealt out a row at a time, so a full grid reads in the order the board does. A short last
            // row leaves the columns past its end one tile shorter, and their tiles taller.
            var columns = (0..<across).map { column in
                Column(stride(from: column, to: count, by: across).map { plain(tiles[$0]) })
            }
            // One row, or one column, is a run, and gets the lengths it was given. A grid of both keeps
            // even cells, as it always has: a width there was a column's, never one tile's.
            if across == count {
                for index in columns.indices {
                    columns[index].width = sizes[columns[index].tiles[0].shown] ?? .even
                }
            } else if across == 1 {
                columns[0].tiles = tiles.map(sized)
            }
            return columns

        case .masterStack:
            // The master against the stack is a fraction of the window, unless the master was pinned,
            // in which case it is points like anything else.
            let fraction = min(0.85, max(0.3, masterFraction))
            var master = Size.flexible(fraction)
            if case .pinned? = sizes[tiles[0].shown] { master = sizes[tiles[0].shown]! }
            return [Column(width: master, [plain(tiles[0])]),
                    Column(width: .flexible(1 - fraction), tiles.dropFirst().map(sized))]
        }
    }

}

// MARK: - What a workspace is made of

/// The tiling decisions that used to be computed properties on `CanvasBoardView`, and read only the
/// document, the selection and the last tiling. Moved beside the rest of the tiling rules for the same
/// reason those are here: nothing in the test bundle can build a board, so a rule that lives on one
/// cannot be checked. See `CanvasTilingPlanTests`.
extension CanvasTiling {

    /// What a fresh tiling of `count` cards is dealt as, when nothing remembered or saved says otherwise.
    static func preferredArrangement(for count: Int) -> Arrangement {
        count >= 4 ? .masterStack : .grid
    }

    /// What a tiling is dealt as: the arrangement asked for, else the one these cards had last time, else
    /// the one last chosen anywhere, else what suits this many cards.
    ///
    /// **One place for the order**, because it was written twice — here for a plan, and again in the
    /// board's `tile` for a tiling dealt out afresh — and two copies of a precedence are two chances for
    /// them to disagree about which card count gets which layout.
    static func arrangement(asked: Arrangement?, remembered: Arrangement?, saved: Arrangement?,
                            cardCount: Int) -> Arrangement {
        asked ?? remembered ?? saved ?? preferredArrangement(for: cardCount)
    }

    /// The cards a tiling of the current selection would hold.
    ///
    /// A frame is a container of cards, so tiling one means tiling what is in it — "make a workspace out
    /// of this region", and the one point where frames and workspaces should meet.
    ///
    /// **Nothing selected is nothing to make**, and it used to be everything on screen. A tiled view was a
    /// way of looking, so "fill the window with what I can see" was a fair reading of an empty selection;
    /// a workspace is saved, named and given a tab, and one made out of wherever the board happened to be
    /// scrolled is a thing you then have to go and delete.
    static func targets(of selection: Set<String>, in document: CanvasDocument) -> Set<String> {
        var ids = selection.filter { document.node(id: $0).map { !$0.isGroup } ?? false }
        for id in selection {
            guard let node = document.node(id: id), node.isGroup else { continue }
            ids.formUnion(canvasCardsInside(node.frame, of: document))
        }
        return ids
    }

    /// The tiling `ids` would be laid out as, or nil when none of them is a card.
    ///
    /// **The same cards as last time means the same arrangement as last time**: the order they were
    /// dragged into, the widths, the pin. Matched on the set rather than the order, because the order is
    /// one of the things being remembered.
    ///
    /// **Asking for an arrangement is asking for the tiles to be dealt out again**, so what was kept of
    /// their columns and sizes is set aside. The order is kept: it is where the cards were.
    ///
    /// - Parameters:
    ///   - savedArrangement: The arrangement last chosen anywhere, from the user's defaults. A parameter
    ///     so the rule can be checked without them; callers pass nothing.
    ///   - savedMasterFraction: Likewise for the master column's share.
    static func plan(for ids: Set<String>, in document: CanvasDocument,
                     remembered last: CanvasViewState.Tiling?, arrangement: Arrangement?,
                     savedArrangement: Arrangement? = CanvasTiling.savedArrangement,
                     savedMasterFraction: Double = CanvasTiling.savedMasterFraction) -> CanvasViewState.Tiling? {
        let cards = document.nodes.filter { ids.contains($0.id) && !$0.isGroup }
            .map { (id: $0.id, frame: $0.frame) }
        guard !cards.isEmpty else { return nil }
        let remembered = last.flatMap { Set($0.ids) == Set(cards.map(\.id)) ? $0 : nil }
        if arrangement == nil, let remembered { return remembered }
        return CanvasViewState.Tiling(
            ids: remembered?.ids ?? order(cards),
            arrangement: Self.arrangement(asked: arrangement, remembered: remembered?.arrangement,
                                     saved: savedArrangement, cardCount: cards.count),
            masterFraction: remembered?.masterFraction ?? savedMasterFraction,
            sizes: nil)
    }

    /// How a tiling describes itself in the header: "3 of 12 cards" and "3/12". Frames are not cards and
    /// are not counted, so a board of nine cards in three frames reads "of 9".
    static func summary(cardsInTiling count: Int, of document: CanvasDocument) -> (long: String, short: String) {
        let total = document.nodes.filter { !$0.isGroup }.count
        let long = count == 1 ? "1 card of \(total)" : "\(count) of \(total) cards"
        return (long, "\(count)/\(total)")
    }
}

/// The cards a frame contains — the ones whose centres fall inside it.
///
/// By centre rather than by containment, which is how a frame on a real board actually holds things: a
/// card nudged so its corner pokes out of the frame it belongs to is still in the group, and every
/// other part of this app agrees (see `canvasDragSet`).
func canvasCardsInside(_ frame: CanvasRect, of document: CanvasDocument) -> Set<String> {
    Set(document.nodes.filter { node in
        !node.isGroup && frame.contains(x: node.frame.midX, y: node.frame.midY)
    }.map(\.id))
}
