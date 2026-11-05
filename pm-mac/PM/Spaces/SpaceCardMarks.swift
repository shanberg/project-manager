import PmLib

/// Pinned and favourite, as marks on a card in the board's file (docs/spaces.md § The frame).
///
/// - `pmPinned`, `pmFavorite`: `true`, or absent. Obsidian keeps keys it doesn't know.
/// - A favourite is pinned too: unpinning clears both.
/// - Everything else on a space's board is Today.
enum SpaceCardMarks {
    static let pinnedKey = "pmPinned"
    static let favoriteKey = "pmFavorite"

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
}
