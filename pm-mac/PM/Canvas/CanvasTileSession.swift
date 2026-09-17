import AppKit
import PmLib

/// A tiled view of some of a board's cards: what is in it, how it is laid out, and how to get out.
///
/// Entered on ⌘Return with a selection, left on ⌘Return again. It is a *view* — the file is untouched,
/// and leaving puts every card back where the board says it belongs. See `CanvasLayout`.
struct CanvasTileSession: Equatable {
    /// The workspace itself: columns of tiles, left to right. See `CanvasTiling.Column`, and
    /// docs/canvas-workspaces.md §7k for why the shape is this rather than a list or a tree.
    ///
    /// **A width is the column's and a height is the tile's.** They used to be the card's — sizes were
    /// keyed by card id, so a size followed its card through a reorder — and in a set of columns that
    /// cannot be kept: a width that followed a card into a column of three would either be ignored,
    /// since the column already has one, or imposed on the two tiles already there, which is resizing
    /// cards you never touched. So swapping two tiles swaps the cards and leaves the sizes where they
    /// were, and a tile moved into another column takes that column's width.
    var columns: [CanvasTiling.Column]

    /// The region being filled, in canvas coordinates: what was on screen when you entered.
    var area: CanvasRect
    /// What the board was looking at, so leaving can put it back exactly.
    var restoreVisible: CanvasRect
    /// The zoom the board was at. A tiling is laid out and shown at 100% whatever the board was at —
    /// see `CanvasScrollView.setZoom` — and this is what leaving hands back.
    var restoreZoom: Double = 1

    /// The tile filling the area on its own, if one is — see `CanvasBoardView.toggleMaximizeTile`.
    ///
    /// **A flag, not a stack**, which is the whole difference between this and the drill-in it
    /// replaced. Drilling in made a *real* tiling of the cards you picked and pushed the one you came
    /// from onto a history, so ⌘Return inside a workspace meant "narrow further" and only meant "leave"
    /// once there was nothing left to narrow — which is why pressing it to get out gave you one tile
    /// filling the window instead. Maximizing is what it says: one tile fills the room for a moment,
    /// and restoring puts back exactly what was there.
    ///
    /// **Not part of what a workspace is.** `memory` names the fields it keeps and this is not one of
    /// them, so a maximized tile cannot be written through to `CanvasWorkspaces` by
    /// `keepNamedWorkspaceUpToDate` and cannot come back tomorrow as the workspace.
    var maximized: String?

    /// Where the next card goes, when ⌥N has said (docs/canvas-workspaces.md §7k). Nil means next to
    /// the focused tile, which is the board's to know — see `CanvasBoardView.nextPlacement`.
    ///
    /// **Shown, not only kept.** While there is one, `layout` draws the tiles moved aside for it, so
    /// the space the card will take is the space you see. **Not part of what a workspace is**, for the
    /// reason `maximized` isn't: it is where you are about to put something, not what you built.
    var preselection: Placement?

    // MARK: Reading it

    /// The cards being drawn, a column at a time and each column top to bottom.
    ///
    /// What everything that only wants to know *which* cards are up reads — membership, counting, the
    /// first one to focus. The order is the columns', which is not the board's reading order across a
    /// grid; `readingOrder` is, for the two callers that care.
    var ids: [String] { columns.flatMap { $0.tiles.map(\.shown) } }

    /// Every card the workspace holds, tabs that aren't showing included.
    var cards: [String] { columns.flatMap { $0.tiles.flatMap(\.cards) } }

    /// Where a tile is: which column, and how far down it.
    struct Position: Equatable {
        var column: Int
        var tile: Int
    }

    /// The tile holding this card, showing or not.
    func position(of id: String) -> Position? {
        for (c, column) in columns.enumerated() {
            if let t = column.tiles.firstIndex(where: { $0.cards.contains(id) }) {
                return Position(column: c, tile: t)
            }
        }
        return nil
    }

    /// The tiles in the order you would read them off the screen — rows top to bottom, each left to
    /// right — which across a grid is not the columns' order.
    ///
    /// What re-arranging deals out, so that switching a grid to a master and stack keeps the card you
    /// read first as the master rather than handing it the first *column*; what ⌃1…9 numbers the tiles
    /// by, and what an older build is given to lay out its own way (`memory`).
    ///
    /// **Each tile's own top-left corner decides where it comes, and nothing about the other tiles
    /// does.** This used to ask `CanvasTiling.order`, which is the board's rule and right for a board:
    /// scattered cards have no rows, so it invents them — a band as tall as the median card, measured
    /// from each card's middle. Tiles are not scattered. They are laid out in columns, so their rows
    /// are a fact and reading them off the top edges is exact, and two things went wrong from treating
    /// them as a scatter. A tall tile's *middle* is level with nothing in particular, so a full-height
    /// tile banded with whichever short tiles happened to sit across its midpoint rather than with the
    /// tiles beside it at the top: a plain grid of four already read top-left, bottom-left, top-middle,
    /// top-right. And the band came from the median of the heights, so **adding one tile changed what
    /// counted as a row for tiles that had not moved at all** — which is canvas-backlog.md 18. Ordering
    /// on each tile's own corner cannot do that: a tile that has not moved cannot change places with
    /// another tile that has not moved, whatever else arrives or leaves.
    ///
    /// The worst of it was not the numbering. `setArrangement` deals this out, so a master and stack
    /// nobody had touched — whose master is full height, and so whose middle is level with the middle
    /// of the stack rather than the top of it — read its first stack tile first, and running Master and
    /// Stack on it again promoted the wrong card. Both are pinned in `CanvasTileOrderTests`.
    var readingOrder: [CanvasTiling.Tile] {
        var placed: [(tile: CanvasTiling.Tile, frame: CanvasRect)] = []
        for (column, rows) in zip(columns, CanvasTiling.frames(of: columns, in: area)) {
            for (tile, frame) in zip(column.tiles, rows) { placed.append((tile, frame)) }
        }
        // Lexicographic on (top, left, where it sits in the columns) — a total order, so the sort is
        // given the strict weak ordering it requires and the answer is the same every time.
        return placed.enumerated().sorted { one, two in
            let (a, b) = (one.element.frame, two.element.frame)
            if a.minY != b.minY { return a.minY < b.minY }
            if a.minX != b.minX { return a.minX < b.minX }
            return one.offset < two.offset
        }.map(\.element.tile)
    }

    /// The tile filling the room, if the one named is still here to fill it.
    private var maximizedTile: String? {
        maximized.flatMap { ids.contains($0) ? $0 : nil }
    }

    /// The layout this session produces.
    ///
    /// **A maximized tile is a layout of one**, and the rest of the tiles are simply not in it. That
    /// is what `CanvasLayout.visible` is for, and it means maximizing needs no z-order and no hiding of
    /// its own: the covered tiles stop being drawn, and stop costing anything — `applyPageBudget` reads
    /// what is *drawn* rather than where the file says a card is, so their pages pause the same turn.
    /// A tab that isn't showing is left out the same way, for the same reasons.
    var layout: CanvasLayout {
        var frames: [String: CanvasRect] = [:]
        for placed in placedTiles {
            frames[placed.tile.shown] = placed.tile.cards.count > 1 ? Self.belowTabs(placed.frame)
                                                                     : placed.frame
        }
        return CanvasLayout(frames: frames, visible: Set(frames.keys))
    }

    /// Every tile on screen, whole — its tab strip included — keyed by the card it is showing.
    ///
    /// What a drag is read against, since the strip is part of the tile you are dropping on, and the
    /// top of it is where a drop joins its tabs.
    var tileFrames: [String: CanvasRect] {
        Dictionary(placedTiles.map { ($0.tile.shown, $0.frame) }, uniquingKeysWith: { first, _ in first })
    }

    /// A tile holding more than one card: the band across its top, and the cards the band holds.
    struct TabStrip: Equatable {
        var band: CanvasRect
        var cards: [String]
        var showing: Int
    }

    /// The tab strips on screen — one for every tile holding more than one card.
    var tabStrips: [TabStrip] {
        placedTiles.filter { $0.tile.cards.count > 1 }.map { placed in
            TabStrip(band: Self.tabBand(of: placed.frame), cards: placed.tile.cards,
                     showing: min(max(0, placed.tile.showing), placed.tile.cards.count - 1))
        }
    }

    /// The band across the top of a tile where its tabs go — never more than half the tile, so a
    /// squeezed one still shows some of its card.
    static func tabBand(of frame: CanvasRect) -> CanvasRect {
        CanvasRect(x: frame.minX, y: frame.minY, width: frame.width,
                   height: min(CanvasTiling.tabStrip, frame.height / 2))
    }

    /// The part of a tile left for the card, below its tabs.
    static func belowTabs(_ frame: CanvasRect) -> CanvasRect {
        let band = tabBand(of: frame).height
        return CanvasRect(x: frame.minX, y: frame.minY + band, width: frame.width, height: frame.height - band)
    }

    /// The tiles on screen and where each one is: every tile, or the one filling the room — with its
    /// tabs, since maximizing a tile is not closing any of them.
    private var placedTiles: [(tile: CanvasTiling.Tile, frame: CanvasRect)] {
        if let maximizedTile, let at = position(of: maximizedTile) {
            let tile = columns[at.column].tiles[at.tile]
            let whole = CanvasTiling.frames(of: [.init([.init(tile.cards, showing: tile.showing)])], in: area)
            return [(tile, whole[0][0])]
        }
        var placed: [(tile: CanvasTiling.Tile, frame: CanvasRect)] = []
        for (column, rows) in zip(columns, CanvasTiling.frames(of: columns, in: area)) {
            for (tile, frame) in zip(column.tiles, rows) {
                placed.append((tile, frame))
            }
        }
        return placed
    }

    /// Where the columns put every tile's shown card, whatever is maximized and whatever is chosen.
    var arrangedFrames: [String: CanvasRect] {
        var frames: [String: CanvasRect] = [:]
        for (column, rows) in zip(columns, CanvasTiling.frames(of: columns, in: area)) {
            for (tile, frame) in zip(column.tiles, rows) { frames[tile.shown] = frame }
        }
        return frames
    }

    /// Where the place the next card is going is marked — on the tiles as they stand, which is the mark
    /// a drag already uses (`dropMark`): a new column as the side of the whole column, above or below as
    /// half the tile, a tab as its top band.
    ///
    /// **Nothing moves until a card arrives.** This used to be the layout the change *would* produce,
    /// with the tiles drawn aside around a stand-in. Marking instead is what the drag settled on and for
    /// the same reason — what you are aiming at should not move while you aim — and it saves the pages
    /// in those tiles a reflow on every change of place.
    var placementFrame: CanvasRect? {
        guard maximizedTile == nil, let preselection, position(of: preselection.target) != nil
        else { return nil }
        return dropMark(.beside(preselection.side), on: preselection.target)
    }

    // MARK: The master

    /// The master tile, when the workspace has the shape master-and-stack makes: two columns, the
    /// first holding one tile.
    ///
    /// **Read off the shape, not remembered.** Nothing records which arrangement made the columns, so
    /// "is there a master" is a question about what is on screen — and a workspace you have moved into
    /// that shape by hand has one too, which is what it looks like.
    var master: String? {
        columns.count == 2 && columns[0].tiles.count == 1 ? columns[0].tiles[0].shown : nil
    }

    /// Whether this tile can be made the master: there is one, and it is another tile.
    func canPromote(_ id: String) -> Bool {
        guard let master, let at = position(of: id) else { return false }
        return columns[at.column].tiles[at.tile].shown != master
    }

    /// How much of the width the master has, as a share, when it is sharing rather than pinned —
    /// the number a master divider dragged back to the same place on every board is remembered as.
    var masterShare: Double? {
        guard master != nil, case .flexible(let a) = columns[0].width,
              case .flexible(let b) = columns[1].width, a + b > 0 else { return nil }
        return a / (a + b)
    }

    // MARK: Changing it

    /// Put a card into the tiling where `placement` says: beside a tile, splitting it (`insert`). Where
    /// that is, is the board's to decide — where ⌥N said, else next to the focused tile along its
    /// longer side (`CanvasBoardView.nextPlacement`). With nowhere said, the end.
    ///
    /// Silent about a card that is already up, because every caller's question is "is this card in the
    /// tiling now", and for that one the answer is already yes.
    mutating func add(_ id: String, at placement: Placement?) {
        guard !cards.contains(id) else { return }
        // A chosen place is used up by the card that arrives, wherever it was put — left standing, the
        // room kept for it would open again beside the card that just filled it.
        preselection = nil
        guard let placement, position(of: placement.target) != nil else { return add(id) }
        insert(.init(id), placement)
    }

    /// The end: the bottom of the last column, which in a master and stack is the bottom of the stack
    /// rather than the master slot. Where a card goes when there is no one tile to go beside.
    mutating func add(_ id: String) {
        guard !cards.contains(id) else { return }
        guard let last = columns.indices.last else {
            columns = [.init([.init(id)])]
            return
        }
        columns[last].tiles.append(.init(id, height: Self.share(among: columns[last].tiles)))
    }

    /// The height a tile joining a column gets: a share the size of the average one already there.
    ///
    /// **A peer, not a sliver.** Once a divider has been dragged, a column's tiles hold weights stated
    /// in points, and a newcomer at the even weight of 1 would be a hairline among them. At the
    /// average it arrives the size of a neighbour — and taking it out again leaves the others exactly
    /// as they were, since nothing else was touched.
    static func share(among tiles: [CanvasTiling.Tile]) -> CanvasTiling.Size {
        share(of: tiles.map(\.height))
    }

    /// The same, for any run: the average of its shares, or even when nothing in it is sharing.
    static func share(of run: [CanvasTiling.Size]) -> CanvasTiling.Size {
        let weights = run.compactMap { size -> Double? in
            if case .flexible(let weight) = size { return weight }
            return nil
        }
        return weights.isEmpty ? .even : .flexible(weights.reduce(0, +) / Double(weights.count))
    }

    /// Take a card out of the view. **The card is not touched** — see `CanvasLayout`: a tiling is a way
    /// of looking, and the only thing this changes is what you are looking at.
    ///
    /// A tile with no card left goes, and a column with no tile left goes, and their lengths go with
    /// them: a length is a share of one particular run, and the rest divide what it had.
    mutating func remove(_ id: String) {
        guard let at = position(of: id) else { return }
        takeTab(id, at: at)
        if columns[at.column].tiles[at.tile].cards.isEmpty {
            columns[at.column].tiles.remove(at: at.tile)
            if columns[at.column].tiles.isEmpty { columns.remove(at: at.column) }
        }
        // A tile that has gone cannot be the one filling the window. Left behind, `layout` would fall
        // through to the columns anyway — but `isMaximized` would go on answering yes, and the menu
        // would offer to restore a tile that is not there.
        if maximized == id { maximized = nil }
        // Nor can it be the tile the next card was going beside.
        if preselection?.target == id { preselection = nil }
    }

    /// Put `id`'s tile where `other`'s is and vice versa — a drag inside a tiled view.
    ///
    /// Swapping rather than moving, which is the difference between a tiling manager and a desktop:
    /// there is no free space to move a window *into*, so the only thing a drag can mean is "these two
    /// change places". The cards change places and the sizes stay put — see `columns`.
    mutating func swap(_ id: String, with other: String) {
        guard let a = position(of: id), let b = position(of: other), a != b else { return }
        let first = columns[a.column].tiles[a.tile], second = columns[b.column].tiles[b.tile]
        columns[a.column].tiles[a.tile].cards = second.cards
        columns[a.column].tiles[a.tile].showing = second.showing
        columns[b.column].tiles[b.tile].cards = first.cards
        columns[b.column].tiles[b.tile].showing = first.showing
    }

    // MARK: Where things go

    /// A side of a tile, for something going beside it — or into it, as another of its tabs.
    enum Side: Equatable, CaseIterable {
        case left, right, above, below, tab

        /// Left and right are a new column; above and below are a new tile in this one.
        var opensColumn: Bool { self == .left || self == .right }

        /// What the place is called where it is drawn.
        var title: String {
            switch self {
            case .left, .right: return "New Column"
            case .above: return "New Tile Above"
            case .below: return "New Tile Below"
            case .tab: return "As a Tab"
            }
        }
    }

    /// Beside which tile, on which side.
    struct Placement: Equatable {
        var target: String
        var side: Side
    }

    /// Where the next card goes when nobody has said: next to `id`, **splitting it along its longer
    /// side** — a wide tile gets a new column beside it, a tall one a new tile below.
    ///
    /// This replaced "on the end", whose argument was that the end is the one position you can predict
    /// without learning anything. That was true of a list. In a set of columns there is no end to
    /// predict, and "beside the thing I'm looking at" is the prediction everybody already makes.
    func automaticPlacement(beside id: String) -> Placement? {
        guard let frame = arrangedFrames[id] else { return nil }
        return Placement(target: id, side: frame.width >= frame.height ? .right : .below)
    }

    /// Put a tile beside another. Left and right open a new column beside the target's *whole* column
    /// — the shape is two levels deep, so no one tile of a column is ever split sideways — and above
    /// and below open a new tile in the target's column.
    mutating func insert(_ tile: CanvasTiling.Tile, _ placement: Placement) {
        guard let at = position(of: placement.target) else { return }
        var tile = tile
        // As a tab: its cards join the target's, after the ones there, and the one it was showing is
        // the one that shows — it is what you just put there.
        if placement.side == .tab {
            var target = columns[at.column].tiles[at.tile]
            target.showing = target.cards.count + min(max(0, tile.showing), max(0, tile.cards.count - 1))
            target.cards += tile.cards
            columns[at.column].tiles[at.tile] = target
            return
        }
        if placement.side.opensColumn {
            let split = Self.split(columns[at.column].width, among: columns.map(\.width))
            columns[at.column].width = split.kept
            tile.height = .even
            columns.insert(.init(width: split.new, [tile]),
                           at: placement.side == .right ? at.column + 1 : at.column)
        } else {
            let split = Self.split(columns[at.column].tiles[at.tile].height,
                                   among: columns[at.column].tiles.map(\.height))
            columns[at.column].tiles[at.tile].height = split.kept
            tile.height = split.new
            columns[at.column].tiles.insert(tile, at: placement.side == .below ? at.tile + 1 : at.tile)
        }
    }

    /// What a length becomes when a newcomer opens beside it, and what the newcomer gets.
    ///
    /// **Even stays even**: in a run nobody has sized, everyone shares, the newcomer included. **A share
    /// is halved**, so the newcomer takes half of the one it opened beside and nothing else moves —
    /// which is what splitting a tile means. **A pin keeps its points**, and the newcomer arrives the
    /// size of an average share.
    static func split(_ size: CanvasTiling.Size, among run: [CanvasTiling.Size])
        -> (kept: CanvasTiling.Size, new: CanvasTiling.Size) {
        if run.allSatisfy({ $0 == .even }) { return (size, .even) }
        switch size {
        case .flexible(let weight): return (.flexible(weight / 2), .flexible(weight / 2))
        case .pinned: return (size, share(of: run))
        }
    }

    /// What a tile dropped on another does: change places with it, or go beside it.
    enum Drop: Equatable {
        case swap
        case beside(Side)

        var title: String {
            switch self {
            case .swap: return "Swap"
            case .beside(let side): return side.title
            }
        }
    }

    /// What dropping on `frame` at `point` would do: the band across the top joins the tile's tabs,
    /// near an edge is a place on that side, and the middle is `middle` — a swap for a tile, which is
    /// what a drag onto one has always meant here, and joining the tabs for a single tab pulled out.
    ///
    /// **A quarter and a bit of the way in.** Wide enough that the four sides are easy to hit on a small
    /// tile, and narrow enough that the middle is still the largest target.
    static func drop(at point: CanvasPoint, on frame: CanvasRect, middle: Drop = .swap) -> Drop {
        if point.y - frame.minY < tabBand(of: frame).height { return .beside(.tab) }
        let across = (point.x - frame.minX) / max(1, frame.width)
        let down = (point.y - frame.minY) / max(1, frame.height)
        let distances: [(side: Side, distance: Double)] = [(.left, across), (.right, 1 - across),
                                                            (.above, down), (.below, 1 - down)]
        let nearest = distances.min { $0.distance < $1.distance }!
        return nearest.distance < 0.27 ? .beside(nearest.side) : middle
    }

    /// Drop `id`'s tile on `target`'s: change places with it, or come out of its place and go beside
    /// it. The handlebar's whole vocabulary, and what `dropMark` marks before you let go.
    mutating func drop(_ id: String, on target: String, _ drop: Drop) {
        guard let from = position(of: id), let onto = position(of: target), from != onto else { return }
        switch drop {
        case .swap:
            swap(id, with: target)
        case .beside(let side):
            let tile = columns[from.column].tiles.remove(at: from.tile)
            if columns[from.column].tiles.isEmpty { columns.remove(at: from.column) }
            insert(tile, Placement(target: target, side: side))
        }
    }

    /// Where a drop on `target` would go, marked on the tiles as they stand — **nothing moves until you
    /// let go** (docs/canvas-workspaces.md §7k).
    ///
    /// Each mark is the part of the screen the drop is about: a swap is the whole tile, a tab its top
    /// band, a tile above or below the half of it that would give way — and a new column the side of
    /// the *whole column*, since that is what opens, however many tiles the column holds.
    func dropMark(_ drop: Drop, on target: String) -> CanvasRect? {
        guard let tile = tileFrames[target], let at = position(of: target) else { return nil }
        switch drop {
        case .swap:
            return tile
        case .beside(.tab):
            return Self.tabBand(of: tile)
        case .beside(.above):
            return CanvasRect(x: tile.minX, y: tile.minY, width: tile.width, height: tile.height / 2)
        case .beside(.below):
            return CanvasRect(x: tile.minX, y: tile.midY, width: tile.width, height: tile.height / 2)
        case .beside(.left), .beside(.right):
            let frames = tileFrames
            let column = columns[at.column].tiles.compactMap { frames[$0.shown] }
                .reduce(tile) { $0.union($1) }
            let half = column.width / 2
            return CanvasRect(x: drop == .beside(.left) ? column.minX : column.maxX - half,
                              y: column.minY, width: half, height: column.height)
        }
    }

    /// Carry out a drop: a whole tile's (`drop`), or — `pulling` — one tab's (`pull`).
    mutating func land(_ id: String, on target: String, _ drop: Drop, pulling: Bool) {
        if pulling, case .beside(let side) = drop {
            pull(id, to: Placement(target: target, side: side))
        } else {
            self.drop(id, on: target, drop)
        }
    }

    // MARK: Tabs

    /// Take one card out of its tile's tabs and put it where `placement` says: beside any tile — the
    /// one it came from included — or into another tile's tabs. A card with its tile to itself takes
    /// the tile with it, which is `drop`.
    mutating func pull(_ card: String, to placement: Placement) {
        guard let from = position(of: card), let onto = position(of: placement.target) else { return }
        guard columns[from.column].tiles[from.tile].cards.count > 1 else {
            return drop(card, on: placement.target, .beside(placement.side))
        }
        // Into the tabs it is already in is where it already is.
        if placement.side == .tab, onto == from { return }
        takeTab(card, at: from)
        // Beside its own tile: the tile is still there, showing another of its cards now.
        let target = onto == from ? columns[from.column].tiles[from.tile].shown : placement.target
        insert(.init(card), Placement(target: target, side: placement.side))
    }

    /// Take a card out of a tile's tabs, keeping the one that was showing if it is still there, else
    /// showing the one before it.
    private mutating func takeTab(_ card: String, at place: Position) {
        var tile = columns[place.column].tiles[place.tile]
        guard let index = tile.cards.firstIndex(of: card) else { return }
        tile.cards.remove(at: index)
        if tile.showing > index || tile.showing >= tile.cards.count {
            tile.showing = max(0, tile.showing - 1)
        }
        columns[place.column].tiles[place.tile] = tile
    }

    /// Move a tab along its own strip to `index`, the card showing staying the one that shows. Answers
    /// whether anything moved — a drag along the strip that let go where it started did nothing.
    @discardableResult
    mutating func moveTab(_ card: String, to index: Int) -> Bool {
        guard let at = position(of: card) else { return false }
        var tile = columns[at.column].tiles[at.tile]
        guard let from = tile.cards.firstIndex(of: card) else { return false }
        let to = min(max(0, index), tile.cards.count - 1)
        guard to != from else { return false }
        let shown = tile.shown
        tile.cards.remove(at: from)
        tile.cards.insert(card, at: to)
        tile.showing = tile.cards.firstIndex(of: shown) ?? 0
        columns[at.column].tiles[at.tile] = tile
        return true
    }

    /// Bring a tab to the front of its tile. Answers whether it wasn't there already.
    ///
    /// **A maximized tile stays maximized.** The tile filling the room is named by the card it is
    /// showing, so the name moves to the card that now is.
    @discardableResult
    mutating func showTab(_ card: String) -> Bool {
        guard let at = position(of: card),
              let index = columns[at.column].tiles[at.tile].cards.firstIndex(of: card) else { return false }
        let was = columns[at.column].tiles[at.tile].shown
        guard was != card else { return false }
        columns[at.column].tiles[at.tile].showing = index
        if maximized == was { maximized = card }
        return true
    }

    /// ⌥[ and ⌥]: the tab before or after the one showing in `id`'s tile, wrapping round. Answers the
    /// card now showing, or nil for a tile with only one.
    mutating func stepTab(of id: String, by step: Int) -> String? {
        guard let at = position(of: id) else { return nil }
        let tile = columns[at.column].tiles[at.tile]
        guard tile.cards.count > 1, let current = tile.cards.firstIndex(of: tile.shown) else { return nil }
        let count = tile.cards.count
        let next = tile.cards[((current + step) % count + count) % count]
        showTab(next)
        return next
    }

    // MARK: Picking on the board

    /// Each card's tile, numbered in the order the workspace reads — what the board shows on the
    /// workspace's cards while you pick them (⌥B). Tabs share their tile's number: they are one place.
    var tileNumbers: [String: Int] {
        var numbers: [String: Int] = [:]
        for (index, tile) in readingOrder.enumerated() {
            for card in tile.cards { numbers[card] = index + 1 }
        }
        return numbers
    }

    /// What a click on the board does while picking.
    enum Pick: Equatable {
        /// These go in, in this order.
        case add([String])
        /// These come out.
        case remove([String])
        /// Nothing: there is nothing to add, and taking these out would leave nothing.
        case refuse
    }

    /// A card — or a frame's cards — clicked while picking: whatever of them isn't in goes in, and when
    /// all of them are in already they come out. Never the last card out: a workspace of nothing is
    /// not a state.
    func pick(_ ids: [String]) -> Pick {
        guard !ids.isEmpty else { return .refuse }
        let held = Set(cards)
        let missing = ids.filter { !held.contains($0) }
        if !missing.isEmpty { return .add(missing) }
        return held.count > ids.count ? .remove(ids) : .refuse
    }

    /// Whether this card's tile holds others too.
    func hasTabs(_ id: String) -> Bool {
        guard let at = position(of: id) else { return false }
        return columns[at.column].tiles[at.tile].cards.count > 1
    }

    /// Every card in this card's tile, in the strip's order — itself alone for a tile without tabs.
    func tabs(of id: String) -> [String] {
        guard let at = position(of: id) else { return [] }
        return columns[at.column].tiles[at.tile].cards
    }

    // MARK: The keys

    /// ⌥⇧← and →: into the next column over, level with where it was — or, past the last column, out
    /// into one of its own. Answers whether anything moved: a tile alone in its column at the edge has
    /// nowhere to go.
    @discardableResult
    mutating func moveAcross(_ id: String, by step: Int) -> Bool {
        guard let from = position(of: id) else { return false }
        let to = from.column + step
        guard columns.indices.contains(to) else {
            guard columns[from.column].tiles.count > 1 else { return false }
            var tile = columns[from.column].tiles.remove(at: from.tile)
            tile.height = .even
            columns.insert(.init(width: Self.share(of: columns.map(\.width)), [tile]),
                           at: step > 0 ? columns.count : 0)
            return true
        }
        let frames = arrangedFrames
        let level = frames[id]?.midY ?? 0
        let index = columns[to].tiles.filter { (frames[$0.shown]?.midY ?? 0) < level }.count
        var tile = columns[from.column].tiles.remove(at: from.tile)
        tile.height = Self.share(among: columns[to].tiles)
        columns[to].tiles.insert(tile, at: index)
        if columns[from.column].tiles.isEmpty { columns.remove(at: from.column) }
        return true
    }

    /// ⌥⇧↑ and ↓: change places with the tile above or below. The height goes with the tile, as it
    /// always has along a column.
    @discardableResult
    mutating func moveWithin(_ id: String, by step: Int) -> Bool {
        guard let at = position(of: id), columns[at.column].tiles.indices.contains(at.tile + step)
        else { return false }
        columns[at.column].tiles.swapAt(at.tile, at.tile + step)
        return true
    }

    /// ⌥= and ⌥−, and with ⇧ the height: grow or shrink a tile's column, or the tile down its column,
    /// by `delta` points — taken from, or given to, the others sharing that run in proportion to their
    /// size. A pin that isn't the one being sized holds still. Answers whether there was room.
    @discardableResult
    mutating func grow(_ id: String, vertically: Bool, by delta: Double) -> Bool {
        guard let at = position(of: id) else { return false }
        let run: CanvasTileDivider.Run = vertically ? .tiles(inColumn: at.column) : .columns
        let index = vertically ? at.tile : at.column
        var sizes = sizes(of: run)
        let lengths = lengths(of: run)
        guard sizes.count > 1, sizes.count == lengths.count else { return false }
        var others: [Int] = []
        for position in sizes.indices where position != index {
            if case .flexible = sizes[position] { others.append(position) }
        }
        let room = others.reduce(0) { $0 + lengths[$1] }
        let next = lengths[index] + delta
        guard room > delta, next >= CanvasTiling.minimumTile else { return false }
        let scale = (room - delta) / room
        guard others.allSatisfy({ lengths[$0] * scale >= CanvasTiling.minimumTile }) else { return false }
        for position in others { sizes[position] = .flexible(lengths[position] * scale) }
        if case .pinned = sizes[index] { sizes[index] = .pinned(next) } else { sizes[index] = .flexible(next) }
        set(sizes, of: run)
        return true
    }

    /// ⌥0: every column and every tile back to sharing equally, pins included.
    mutating func balance() {
        for column in columns.indices {
            columns[column].width = .even
            for tile in columns[column].tiles.indices { columns[column].tiles[tile].height = .even }
        }
    }

    /// Size to Content: every column's share of the width becomes what the widest card it holds reads
    /// best at (`contentWidth`), tabs that aren't showing included.
    ///
    /// **Shares, not pins**, so the columns still fit the window — a page and a text card side by side
    /// come out about three to one whatever the window is. A pinned column keeps its pin, since a pin
    /// is you having said so. Heights are left alone: what is in a card says how wide it wants to be,
    /// and nothing about how tall.
    mutating func sizeToContent(_ width: (String) -> Double) {
        for index in columns.indices {
            if case .pinned = columns[index].width { continue }
            let widest = columns[index].tiles.flatMap(\.cards).map(width).max() ?? 1
            columns[index].width = .flexible(widest)
        }
    }

    /// Make `id` the master tile, which is what promoting a window means in every manager that has a
    /// master. The old master goes to the top of the stack and the tiles above `id` move down one.
    ///
    /// **The cards move and the slots stay** — the master keeps its width and every tile in the stack
    /// its height, which is what a drag left them at. See `columns`.
    mutating func promote(_ id: String) {
        guard canPromote(id), let at = position(of: id) else { return }
        var stack = columns[at.column].tiles
        let promoted = stack.remove(at: at.tile)
        let order = [columns[0].tiles[0]] + stack
        columns[0].tiles[0].cards = promoted.cards
        columns[0].tiles[0].showing = promoted.showing
        for (index, tile) in order.enumerated() {
            columns[at.column].tiles[index].cards = tile.cards
            columns[at.column].tiles[index].showing = tile.showing
        }
    }

    // MARK: How much room each tile gets

    /// Every boundary you can drag: one between each pair of columns, and one between each pair of
    /// tiles down every column. None while one tile fills the room — the boundaries belong to an
    /// arrangement that is not on screen, and a drag on one would resize tiles you cannot see.
    var dividers: [CanvasTileDivider] {
        // A place chosen for the next card is no longer a reason to withdraw them: it is marked on the
        // tiles as they stand, so every boundary is still where the columns put it.
        guard maximizedTile == nil, ids.count > 1 else { return [] }
        let frames = CanvasTiling.frames(of: columns, in: area)
        let room = CanvasTiling.space(of: area)
        let half = CanvasTiling.gap / 2
        var dividers: [CanvasTileDivider] = []
        for (index, rows) in frames.dropLast().enumerated() {
            guard let rect = rows.first else { continue }
            dividers.append(CanvasTileDivider(run: .columns, before: index, position: rect.maxX + half,
                                              span: room.minY...room.maxY))
        }
        for (column, rows) in frames.enumerated() {
            for (index, rect) in rows.dropLast().enumerated() {
                dividers.append(CanvasTileDivider(run: .tiles(inColumn: column), before: index,
                                                  position: rect.maxY + half,
                                                  span: rect.minX...rect.maxX))
            }
        }
        return dividers
    }

    /// What each thing in a run is asking for.
    func sizes(of run: CanvasTileDivider.Run) -> [CanvasTiling.Size] {
        switch run {
        case .columns: return columns.map(\.width)
        case .tiles(let column):
            return columns.indices.contains(column) ? columns[column].tiles.map(\.height) : []
        }
    }

    private mutating func set(_ sizes: [CanvasTiling.Size], of run: CanvasTileDivider.Run) {
        switch run {
        case .columns:
            guard sizes.count == columns.count else { return }
            for index in columns.indices { columns[index].width = sizes[index] }
        case .tiles(let column):
            guard columns.indices.contains(column), sizes.count == columns[column].tiles.count else { return }
            for index in columns[column].tiles.indices { columns[column].tiles[index].height = sizes[index] }
        }
    }

    /// How long each thing in a run is right now, along the axis it flows in — measured off the frames,
    /// so a drag starts from what is on screen, including a pin squeezed by a window too small for it.
    func lengths(of run: CanvasTileDivider.Run) -> [Double] {
        let frames = CanvasTiling.frames(of: columns, in: area)
        switch run {
        case .columns: return frames.map { $0.first?.width ?? 0 }
        case .tiles(let column): return frames.indices.contains(column) ? frames[column].map(\.height) : []
        }
    }

    /// Drag a boundary: the two either side of it change length, and nothing else moves.
    ///
    /// **What gets written depends on what each is.** A pinned one takes its new length in points; a
    /// flexible one takes its *current* length as its weight, which changes nothing about where it is
    /// — so the first drag in a run quietly restates every flexible length in points and leaves the
    /// picture identical. Pins that were not dragged are left alone: their current length may be a pin
    /// the window is too small to honour, and rewriting it would bake the squeeze in permanently.
    mutating func resize(_ run: CanvasTileDivider.Run, before: Int, lengths: [Double], to grown: Double) {
        var sizes = sizes(of: run)
        let after = before + 1
        guard sizes.count == lengths.count, after < lengths.count else { return }
        let pair = lengths[before] + lengths[after]
        for index in sizes.indices {
            let length = index == before ? grown : index == after ? pair - grown : lengths[index]
            if case .pinned = sizes[index] {
                if index == before || index == after { sizes[index] = .pinned(length) }
            } else {
                sizes[index] = .flexible(length)
            }
        }
        set(sizes, of: run)
    }

    /// The run a tile's own pin holds it along, and where it is in it: its height, when it shares its
    /// column, and its column's width when it has the column to itself — the stack's tiles and the
    /// master, as it always was.
    func run(of id: String) -> (run: CanvasTileDivider.Run, index: Int)? {
        guard let at = position(of: id) else { return nil }
        return columns[at.column].tiles.count > 1 ? (.tiles(inColumn: at.column), at.tile)
                                                  : (.columns, at.column)
    }

    /// Whether this tile's pin holds a height rather than a width.
    func runIsVertical(_ id: String) -> Bool {
        if case .tiles? = run(of: id)?.run { return true }
        return false
    }

    func isPinned(_ run: CanvasTileDivider.Run, at index: Int) -> Bool {
        let sizes = sizes(of: run)
        guard sizes.indices.contains(index), case .pinned = sizes[index] else { return false }
        return true
    }

    func isPinned(_ id: String) -> Bool {
        guard let place = run(of: id) else { return false }
        return isPinned(place.run, at: place.index)
    }

    /// Hold one length against the window, or let it go back to sharing.
    ///
    /// **Letting go keeps the picture.** It takes its current length as its weight, and every other
    /// sharing length in the run is restated the same way — so a tile that stops holding its width
    /// stays exactly the width it was until the window next changes, rather than jumping to an even
    /// share of a run whose other weights are in points.
    mutating func togglePin(_ run: CanvasTileDivider.Run, at index: Int) {
        var sizes = sizes(of: run)
        let lengths = lengths(of: run)
        guard sizes.indices.contains(index), sizes.count == lengths.count else { return }
        if case .pinned = sizes[index] {
            for position in sizes.indices {
                if position == index { sizes[position] = .flexible(lengths[position]); continue }
                if case .flexible = sizes[position] { sizes[position] = .flexible(lengths[position]) }
            }
        } else {
            sizes[index] = .pinned(lengths[index])
        }
        set(sizes, of: run)
    }

    mutating func togglePin(_ id: String) {
        guard let place = run(of: id) else { return }
        togglePin(place.run, at: place.index)
    }

    /// Put a run back to sharing equally — pins included, which is the way out of an arrangement you
    /// have over-adjusted, and the one thing a drag genuinely cannot express.
    mutating func evenOut(_ run: CanvasTileDivider.Run) {
        set(sizes(of: run).map { _ in .even }, of: run)
    }

}

// In an extension so the struct keeps its memberwise initialiser, which this one is built on.
extension CanvasTileSession {

    // MARK: What is in a card

    /// The width a card reads best at, by the kind of card it is — what Size to Content shares the
    /// columns out by. A window manager cannot know what is in a window; the board knows every card's
    /// kind (docs/canvas-workspaces.md §7k).
    ///
    /// A project's card is its notes and its tasks together, and sized as the notes; any other note is
    /// prose and reads at the same measure.
    static func contentWidth(of node: CanvasNode) -> Double {
        switch node.content {
        case .link: return 1024
        case .file(let path, _):
            switch (path as NSString).pathExtension.lowercased() {
            case "pdf": return 720
            case "md", "markdown", "txt": return 640
            case "png", "jpg", "jpeg", "gif", "heic", "webp", "tiff", "bmp": return 560
            default: return 320
            }
        case .text, .group: return 320
        }
    }

    /// Where a page stops reading: most sites switch to their phone layout below about this, and it is
    /// the width pinning exists to protect. A boundary dragged past it says so.
    static let narrowestPage: Double = 380

    // MARK: What is kept

    /// A saved workspace, back as a session — or nil when none of its cards are left.
    ///
    /// Cards that have gone since are dropped rather than treated as a reason to give up: a board you
    /// deleted one card from is still the board you were looking at. A tiling saved before columns
    /// existed is laid out by the arrangement it was saved with, into this window — which is the one
    /// conversion there is, and why it happens here rather than when the row is decoded.
    init?(restoring saved: CanvasViewState.Tiling, keeping isLive: (String) -> Bool,
          area: CanvasRect, restoreVisible: CanvasRect, restoreZoom: Double) {
        var columns: [CanvasTiling.Column]
        if let saved = saved.columns {
            columns = saved.compactMap { column in
                var column = column
                column.tiles = column.tiles.compactMap { tile in
                    let showing = tile.shown
                    var tile = tile
                    tile.cards = tile.cards.filter(isLive)
                    guard !tile.cards.isEmpty else { return nil }
                    tile.showing = tile.cards.firstIndex(of: showing) ?? 0
                    return tile
                }
                return column.tiles.isEmpty ? nil : column
            }
        } else {
            let live = saved.ids.filter(isLive).map { CanvasTiling.Tile($0) }
            columns = CanvasTiling.columns(saved.arrangement, of: live, in: area,
                                           masterFraction: saved.masterFraction,
                                           sizes: saved.sizes ?? [:])
        }
        guard !columns.isEmpty else { return nil }
        self.init(columns: columns, area: area, restoreVisible: restoreVisible, restoreZoom: restoreZoom)
    }

    /// What is worth remembering about this tiling: everything except where the window happened to be,
    /// and which tile was filling it.
    ///
    /// The old fields are filled in for a build from before columns, which reads nothing else — every
    /// card in reading order, and the arrangement the shape looks like — so it can open this workspace
    /// and lay it out its own way. See `CanvasViewState.Tiling`.
    var memory: CanvasViewState.Tiling {
        CanvasViewState.Tiling(ids: readingOrder.flatMap(\.cards),
                               arrangement: master == nil ? .grid : .masterStack,
                               masterFraction: masterShare.map { min(0.85, max(0.3, $0)) }
                                   ?? CanvasTiling.savedMasterFraction,
                               sizes: nil,
                               columns: columns)
    }
}

/// One draggable boundary: between two columns, or between two tiles in one column.
struct CanvasTileDivider: Equatable {
    /// The things this boundary divides the room between.
    enum Run: Equatable {
        /// The columns, left to right.
        case columns
        /// The tiles down one column.
        case tiles(inColumn: Int)
    }

    var run: Run
    /// Which of the run the line is after.
    var before: Int
    /// Where the line is, on the axis it moves along.
    var position: Double
    /// How far it reaches along the other axis. A boundary between two tiles is only as long as their
    /// column is wide — without this a press level with it in the next column would catch it.
    var span: ClosedRange<Double>

    /// True for a line you drag left and right — one between columns.
    var isVertical: Bool { run == .columns }
}
