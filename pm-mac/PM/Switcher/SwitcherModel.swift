import AppKit

/// What the ⌥Tab switcher shows and where its selection is. docs/spaces.md § Switcher.
///
/// - A row of cards, front window first; the first press lands on the second, as ⌘Tab does.
/// - Each card has a list (Notes, then its workspaces, each workspace's tiles under it); ↓ ↑ move into it.
/// - Pure: built from plain values, so the moves are tested without a window (`SwitcherModelTests`).
struct SwitcherModel: Equatable {
    struct Entry: Equatable {
        enum Target: Equatable {
            case notes
            case workspace(String)
            case tile(workspace: String, card: String)
        }
        var title: String
        var target: Target
        /// Tiles in a workspace, for its row's trailing count.
        var count: Int = 0
        var isTile: Bool { if case .tile = target { return true } else { return false } }
    }

    struct Card: Equatable {
        /// The dock group's key: what the controller jumps to.
        var key: String
        var title: String
        var isFocused = false
        /// A space: after the projects, past a divider, and never focused.
        var isSpace = false
        /// The latest session: its label and when.
        var session: String?
        /// The focused task's text.
        var focusedTask: String?
        var entries: [Entry] = []
    }

    private(set) var cards: [Card]
    /// The card picked.
    private(set) var index: Int
    /// The row picked inside that card, or nil for the card itself.
    private(set) var entry: Int?

    /// Opened on the card after the front one — or the only one, when there's one.
    init(cards: [Card]) {
        self.cards = cards
        index = cards.count > 1 ? 1 : 0
        entry = nil
    }

    var isEmpty: Bool { cards.isEmpty }
    var selectedCard: Card? { cards.indices.contains(index) ? cards[index] : nil }
    var selectedEntry: Entry? {
        guard let card = selectedCard, let entry, card.entries.indices.contains(entry) else { return nil }
        return card.entries[entry]
    }

    /// Tab / ⇧Tab, → / ←: along the row, wrapping. Leaves the card's list.
    mutating func move(by step: Int) {
        guard !cards.isEmpty else { return }
        index = ((index + step) % cards.count + cards.count) % cards.count
        entry = nil
    }

    /// ↓ / ↑: into and through the picked card's list. ↑ from the first row is back to the card.
    mutating func moveEntry(by step: Int) {
        guard let card = selectedCard, !card.entries.isEmpty else { return }
        let next = (entry ?? -1) + step
        entry = next < 0 ? nil : min(next, card.entries.count - 1)
    }

    /// The pointer over a card, or over one of its rows.
    mutating func point(at card: Int, entry: Int?) {
        guard cards.indices.contains(card) else { return }
        index = card
        self.entry = entry.flatMap { cards[card].entries.indices.contains($0) ? $0 : nil }
    }

    /// The rows for a card: Notes, then each workspace, with its tiles under it when there are any.
    static func entries(workspaces: [(name: String, tiles: [(id: String, title: String)])],
                        showingTiles: Bool = true) -> [Entry] {
        var rows = [Entry(title: "Notes", target: .notes)]
        for workspace in workspaces {
            rows.append(Entry(title: workspace.name, target: .workspace(workspace.name), count: workspace.tiles.count))
            guard showingTiles else { continue }
            rows += workspace.tiles.map {
                Entry(title: $0.title, target: .tile(workspace: workspace.name, card: $0.id))
            }
        }
        return rows
    }
}

/// Hold-to-switch, as ⌘Tab: the switcher opens on the press, commits when ⌥ comes up.
///
/// - A quick tap (⌥ up before `revealDelay`) switches without the panel ever drawing.
/// - Opened from a menu or the command bar, nothing is held: Return or a click commits.
struct SwitcherHold: Equatable {
    static let revealDelay: TimeInterval = 0.12

    private(set) var held: Bool
    private(set) var opened: Date

    init(held: Bool, at now: Date) {
        self.held = held
        opened = now
    }

    /// The modifier came up. True when that should commit.
    mutating func released() -> Bool {
        guard held else { return false }
        held = false
        return true
    }

    /// Whether the panel should be on screen yet.
    func shouldReveal(at now: Date) -> Bool { !held || now.timeIntervalSince(opened) >= Self.revealDelay }
}

/// A project's colour as text, outline and highlight on the switcher's glass.
///
/// Black on dark glass and white on light glass vanish, so those are pulled toward the other end until
/// they read. The icon keeps the true colour, as the dock's mark does.
enum SwitcherInk {
    static func legible(_ color: NSColor, dark: Bool) -> NSColor {
        let lum = luminance(color)
        if dark, lum < 0.3 { return color.blended(withFraction: 0.6, of: .white) ?? color }
        if !dark, lum > 0.8 { return color.blended(withFraction: 0.5, of: .black) ?? color }
        return color
    }

    /// Whether text on a fill of `color` should be black rather than white.
    static func onFillIsDark(_ color: NSColor) -> Bool { luminance(color) > 0.6 }

    static func luminance(_ color: NSColor) -> CGFloat {
        guard let rgb = color.usingColorSpace(.sRGB) else { return 0.5 }
        return 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
    }
}
