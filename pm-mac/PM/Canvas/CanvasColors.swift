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

    /// The card surface itself.
    static let card = NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor(white: 0.13, alpha: 1) : NSColor(white: 1, alpha: 1)
    }

    /// The board a card sits on.
    ///
    /// **The board is the window's own background.** It used to be a pair of hand-picked greys — a
    /// blue-tinted 0.937 in light, a near-black 0.086 in dark — inherited from Obsidian, where a canvas
    /// is a document with a look of its own. Here it isn't: a canvas is a pane in a PM window, sitting
    /// beside a sidebar and under a header that are painted in the system's colours, and a board that
    /// brought its own greys with it was the one surface in the app with an opinion. `windowBackground`
    /// also comes with things a constant cannot: it follows Increase Contrast, it follows a tinted
    /// appearance, and it will follow whatever the next macOS decides a window is painted with.
    ///
    /// It leaves a card the same colour as the board it sits on in light appearance, which sounds like
    /// a mistake and is the arrangement Freeform and Notes both ship. A card is told from the board by
    /// its shadow — see `CanvasNodeView.refreshElevation` — which is a truer account of what a card is
    /// anyway: a piece of paper on a desk, not a lighter rectangle.
    static let board = NSColor.windowBackgroundColor

    /// The dot grid, at `presence` of its full strength.
    ///
    /// Only drawn while something is being dragged or resized, and only while that drag is snapping —
    /// it is the lattice the card is landing on rather than a permanent texture. See
    /// `CanvasBoardView.drawGrid`, which owns the argument.
    ///
    /// Slightly stronger than it was, because it is now transient and has to register in the first
    /// tenth of a second rather than sit quietly under a board you are reading.
    ///
    /// A function rather than a colour and a `withAlphaComponent` at the call site, because the alpha
    /// isn't the same in both appearances and reading a component off a dynamic colour resolves it
    /// against whatever appearance happens to be current — which, during drawing, is not reliably the
    /// view's.
    static func grid(_ presence: Double) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.isDark ? NSColor(white: 1, alpha: 0.13 * presence)
                              : NSColor(white: 0, alpha: 0.14 * presence)
        }
    }
    /// The alignment ghosts, at `alpha`.
    ///
    /// Neutral, not the accent. A guide drawn in the accent is a blue line on a board where blue
    /// already means "selected", and at the weight a guide needs to be seen it reads as a second, more
    /// urgent selection — the eye goes to it instead of to the card you are placing. What is wanted
    /// here is the opposite of urgent: the soft grey-on-light, white-on-dark outline the desktop puts
    /// round a widget you are dragging, which you read without looking at.
    static func guide(_ alpha: Double) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.isDark ? NSColor(white: 1, alpha: alpha)
                              : NSColor(white: 0, alpha: alpha * 0.85)
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
