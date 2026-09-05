import AppKit

/// What a canvas is painted with.
///
/// **PM does not render card or line colour, and does not offer to set it.** Obsidian gives a card one
/// of six presets — stored as `"1"`…`"6"` — or a hex string from a colour picker, and PM used to copy
/// those values exactly so a board read the same in both apps. That is no longer what the board is
/// for. A canvas here is read at a glance across a dozen cards, and six hues spent on borders and
/// washes were competing with the only thing on a card worth looking at, which is the card's contents.
/// So a board is drawn in the theme's own greys, and what distinguishes one card from another is what
/// is in it.
///
/// The stored value is **kept, not stripped**: `color` is a field on `CanvasNode` and `CanvasEdge`,
/// read and written untouched (see `CanvasJSON`), so a board coloured in Obsidian round-trips through
/// PM with its colours intact. PM simply has no opinion about them. Anyone who wants to see or change
/// them has Obsidian, which is the app that believes in them.
enum CanvasPalette {
    /// A card's hairline.
    ///
    /// Weaker in light appearance than in dark, and that asymmetry is the point. In light the card's
    /// shadow already separates it from the board, so a full-strength edge on top of that reads as a
    /// drawn outline around a drawing. In dark a black shadow on a near-black board says almost
    /// nothing, and the hairline is the whole of what tells a card from the ground it sits on.
    static let cardBorder = NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor(white: 1, alpha: 0.15) : NSColor(white: 0, alpha: 0.10)
    }

    /// A line between two cards. Deliberately not `.labelColor`: a board is mostly lines and cards, and
    /// lines drawn at full label contrast read as the subject rather than as the relationships between
    /// the things that are.
    static let edge = NSColor.tertiaryLabelColor

    /// The card surface itself, and the board it sits on.
    static let card = NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor(white: 0.13, alpha: 1) : NSColor(white: 1, alpha: 1)
    }
    static let board = NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor(white: 0.086, alpha: 1) : NSColor(srgbRed: 0.937, green: 0.941, blue: 0.953, alpha: 1)
    }
    /// The dot grid, at `presence` of its full strength.
    ///
    /// Present at all, rather than a flat board, because a canvas has no edges and no content of its
    /// own — without a texture that moves, panning an empty region looks like a window that has frozen.
    /// Faded by the caller as you zoom in, which is when that stops being true: see
    /// `CanvasBoardView.drawGrid`.
    ///
    /// A function rather than a colour and a `withAlphaComponent` at the call site, because the alpha
    /// isn't the same in both appearances and reading a component off a dynamic colour resolves it
    /// against whatever appearance happens to be current — which, during drawing, is not reliably the
    /// view's.
    static func grid(_ presence: Double) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.isDark ? NSColor(white: 1, alpha: 0.08 * presence)
                              : NSColor(white: 0, alpha: 0.10 * presence)
        }
    }
    /// A group's frame and the fill inside it.
    static let groupStroke = NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor(white: 1, alpha: 0.22) : NSColor(white: 0, alpha: 0.20)
    }
    static let groupFill = NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor(white: 1, alpha: 0.035) : NSColor(white: 0, alpha: 0.028)
    }
}

extension NSAppearance {
    /// Whether this appearance is one of the dark ones — asked by every dynamic colour above.
    var isDark: Bool {
        bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}
