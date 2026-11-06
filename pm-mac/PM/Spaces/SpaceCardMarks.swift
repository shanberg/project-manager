import AppKit
import PmLib
import UniformTypeIdentifiers

/// Pinned and favourite, as marks on a card in the board's file (docs/spaces.md § The frame).
///
/// - `pmPinned`, `pmFavorite`: `true`, or absent. Obsidian keeps keys it doesn't know.
/// - A favourite is pinned too: unpinning clears both.
/// - Everything else on a space's board is Today.
/// - `pmOrder`: a card's place in its sidebar list, set by dragging a row. Unmarked cards follow the
///   marked ones, in reading order.
enum SpaceCardMarks {
    static let pinnedKey = "pmPinned"
    static let favoriteKey = "pmFavorite"
    static let orderKey = "pmOrder"

    static func isPinned(_ node: CanvasNode) -> Bool { flag(pinnedKey, node) || isFavorite(node) }
    static func isFavorite(_ node: CanvasNode) -> Bool { flag(favoriteKey, node) }

    static func setPinned(_ on: Bool, on node: inout CanvasNode) {
        node.extra[pinnedKey] = on ? .bool(true) : nil
        if !on { node.extra[favoriteKey] = nil }
    }

    static func setFavorite(_ on: Bool, on node: inout CanvasNode) {
        node.extra[favoriteKey] = on ? .bool(true) : nil
        if on { node.extra[pinnedKey] = .bool(true) }
    }

    private static func flag(_ key: String, _ node: CanvasNode) -> Bool {
        if case .bool(let on)? = node.extra[key] { return on }
        return false
    }

    // MARK: Order

    static func order(_ node: CanvasNode) -> Double? {
        if case .number(let place)? = node.extra[orderKey] { return place }
        return nil
    }

    /// Marked items by their mark, then unmarked ones in the order given. Stable.
    static func sorted<T>(_ items: [T], by order: (T) -> Double?) -> [T] {
        items.enumerated().sorted { a, b in
            switch (order(a.element), order(b.element)) {
            case let (x?, y?): return x == y ? a.offset < b.offset : x < y
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): return a.offset < b.offset
            }
        }.map(\.element)
    }

    // MARK: Moving a row

    /// The sidebar's lists a row can be dropped into. A folder is a frame on the board; nil is loose.
    enum List: Hashable {
        case favorites
        case pinned(folder: String?)
        case today(folder: String?)

        var folder: String? {
            switch self {
            case .favorites: return nil
            case .pinned(let folder), .today(let folder): return folder
            }
        }
    }

    /// The smallest frame holding the card's centre — the folder `CanvasItems.sections` lists it in.
    static func folder(of node: CanvasNode, in document: CanvasDocument) -> String? {
        document.nodes
            .filter { $0.isGroup && $0.id != node.id && $0.frame.contains(x: node.frame.midX, y: node.frame.midY) }
            .min { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }?.id
    }

    /// Card `id` dropped at slot `index` of `list` (before `members[index]`), whose cards are `members`
    /// in sidebar order (with or without `id`). Sets the marks the list means, moves the card into or out of a frame when the
    /// list is another folder's, and numbers the list's cards in their new order.
    static func move(_ id: String, to list: List, at index: Int, members: [String], in document: inout CanvasDocument) {
        guard let at = document.nodes.firstIndex(where: { $0.id == id }) else { return }
        var node = document.nodes[at]
        switch list {
        case .favorites:
            setFavorite(true, on: &node)
        case .pinned:
            if isFavorite(node) { node.extra[favoriteKey] = nil }
            setPinned(true, on: &node)
        case .today:
            setPinned(false, on: &node)
        }
        document.nodes[at] = node
        if list != .favorites, folder(of: node, in: document) != list.folder {
            relocate(id, into: list.folder, in: &document)
        }
        // `index` is a slot in `members` as they stand, so it counts the card's old place if it was
        // above the slot.
        let from = members.firstIndex(of: id)
        let slot = from.map { $0 < index ? index - 1 : index } ?? index
        var ordered = members.filter { $0 != id }
        ordered.insert(id, at: min(max(0, slot), ordered.count))
        for (place, member) in ordered.enumerated() {
            guard let i = document.nodes.firstIndex(where: { $0.id == member }) else { continue }
            document.nodes[i].extra[orderKey] = .number(Double(place))
        }
    }

    /// New cards onto the board, in order from slot `index` of `list` (whose cards are `members`).
    static func insert(_ nodes: [CanvasNode], into list: List, at index: Int, members: [String],
                       in document: inout CanvasDocument) {
        var order = members
        for (offset, node) in nodes.enumerated() {
            document.nodes.append(node)
            move(node.id, to: list, at: index + offset, members: order, in: &document)
            order.insert(node.id, at: min(index + offset, order.count))
        }
    }

    /// Put a card inside a frame (under the cards already in it, the frame growing to hold it), or out
    /// of every frame (right of everything on the board, where a new card goes).
    static func relocate(_ id: String, into frameID: String?, in document: inout CanvasDocument) {
        guard let at = document.nodes.firstIndex(where: { $0.id == id }) else { return }
        var node = document.nodes[at]
        let gap = 20.0
        guard let frameID, let f = document.nodes.firstIndex(where: { $0.id == frameID && $0.isGroup }) else {
            let right = document.nodes.filter { $0.id != id }.map(\.frame.maxX).max() ?? 0
            node.frame.x = right + 40
            node.frame.y = 0
            document.nodes[at] = node
            return
        }
        var frame = document.nodes[f].frame
        let inside = document.nodes.filter {
            !$0.isGroup && $0.id != id && folder(of: $0, in: document) == frameID
        }
        node.frame.x = inside.map(\.frame.minX).min() ?? frame.minX + gap
        node.frame.y = inside.map(\.frame.maxY).max().map { $0 + gap } ?? frame.minY + 2 * gap
        if node.frame.maxX + gap > frame.maxX { frame.width = node.frame.maxX + gap - frame.minX }
        if node.frame.maxY + gap > frame.maxY { frame.height = node.frame.maxY + gap - frame.minY }
        document.nodes[at] = node
        document.nodes[f].frame = frame
    }
}

/// A card's row being dragged out of a frame's sidebar: onto another place in the list, a workspace
/// row, or the tiles (docs/spaces.md § The frame).
///
/// The drag carries its own type, so the board can tell it from a link; which card and which board
/// are kept here, since the drag starts and ends in this process and SwiftUI's providers answer late.
/// A web row also carries its address, for other apps and other boards.
@MainActor
enum SpaceRowDrag {
    static let type = UTType(exportedAs: "com.stuarthanberg.pm.sidebar-card", conformingTo: .data)
    static var pasteboardType: NSPasteboard.PasteboardType { .init(type.identifier) }

    /// The row in flight, the board it's a card of, and its address if it's a web card.
    private(set) static var current: (card: String, canvas: URL, address: String?)?

    /// The card `drag` is carrying, if it's a row of the board at `canvas`.
    static func card(in drag: NSDraggingInfo, for canvas: URL) -> String? {
        guard isRow(drag), let current,
              current.canvas.standardizedFileURL == canvas.standardizedFileURL else { return nil }
        return current.card
    }

    /// Whether `drag` is a sidebar row of any board: its type on the pasteboard, or — however SwiftUI
    /// wrote the provider — a drag from this process while a row is in flight, since only one drag
    /// runs at a time.
    static func isRow(_ drag: NSDraggingInfo) -> Bool {
        current != nil && (drag.draggingPasteboard.types?.contains(pasteboardType) == true || drag.draggingSource != nil)
    }

    /// The row was let go somewhere that took it. Not left to the provider's release, which is the
    /// only end SwiftUI reports and may come later.
    static func end() { current = nil }

    /// A provider for dragging `card`'s row; `address` for a web card. `onEnd` runs when the drag is
    /// over, however it ended.
    static func itemProvider(card: String, canvas: URL, address: String?, onEnd: @escaping () -> Void) -> NSItemProvider {
        current = (card, canvas, address)
        let provider = NSItemProvider()
        if let address, let url = URL(string: address) { provider.registerObject(url as NSURL, visibility: .all) }
        provider.registerDataRepresentation(forTypeIdentifier: type.identifier, visibility: .ownProcess) { done in
            done(Data(card.utf8), nil)
            return nil
        }
        objc_setAssociatedObject(provider, &sentinelKey, DragEndSentinel {
            MainActor.assumeIsolated {
                if current?.card == card { current = nil }
                onEnd()
            }
        }, .OBJC_ASSOCIATION_RETAIN)
        return provider
    }

    private nonisolated(unsafe) static var sentinelKey: UInt8 = 0
}
