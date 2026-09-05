import AppKit

/// The colours a canvas card can be painted, and what PM does with them.
///
/// Obsidian gives a card one of six presets — stored as `"1"`…`"6"` — or a hex string a colour picker
/// produced. The six are Obsidian's own values, copied deliberately rather than approximated: a board
/// is read in both apps, often side by side, and a red card that is a slightly different red in PM
/// reads as a mistake in one of them.
///
/// A colour is spent on the **border and a wash**, not a bar or a solid fill, for the same reason: it
/// is what Obsidian does, so a board keeps its shape when you switch apps. The wash is faint enough
/// that a card's text keeps the contrast of ordinary label text on ordinary card background, which a
/// solid fill in any of these six hues would not.
enum CanvasPalette {
    /// Obsidian's six, in order.
    static let presets: [NSColor] = [
        NSColor(srgbRed: 0.984, green: 0.275, blue: 0.298, alpha: 1),  // 1 red
        NSColor(srgbRed: 0.914, green: 0.592, blue: 0.247, alpha: 1),  // 2 orange
        NSColor(srgbRed: 0.878, green: 0.871, blue: 0.443, alpha: 1),  // 3 yellow
        NSColor(srgbRed: 0.267, green: 0.812, blue: 0.431, alpha: 1),  // 4 green
        NSColor(srgbRed: 0.325, green: 0.874, blue: 0.867, alpha: 1),  // 5 cyan
        NSColor(srgbRed: 0.659, green: 0.510, blue: 1.000, alpha: 1),  // 6 purple
    ]

    /// The colour a stored token names, or nil for "no colour" — which is a card in the theme's own
    /// colours and is by far the commonest card.
    ///
    /// Anything unrecognised reads as nil rather than as an error. A canvas can hold a token from a
    /// newer Obsidian or a plugin's own scheme, and a card that loses its tint is a much smaller wrong
    /// than a board that refuses to open — the token itself is still written back untouched.
    static func color(_ token: String?) -> NSColor? {
        guard let token = token?.trimmingCharacters(in: .whitespaces), !token.isEmpty else { return nil }
        if let index = Int(token), (1...presets.count).contains(index) { return presets[index - 1] }
        return hex(token)
    }

    /// `#rgb`, `#rrggbb` or `#rrggbbaa`, with or without the hash.
    static func hex(_ text: String) -> NSColor? {
        var digits = text.hasPrefix("#") ? String(text.dropFirst()) : text
        if digits.count == 3 {
            digits = digits.map { "\($0)\($0)" }.joined()
        }
        guard digits.count == 6 || digits.count == 8,
              digits.allSatisfy(\.isHexDigit),
              let value = UInt32(digits, radix: 16)
        else { return nil }

        let hasAlpha = digits.count == 8
        let r = Double((value >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
        let g = Double((value >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
        let b = Double((value >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
        let a = hasAlpha ? Double(value & 0xFF) / 255 : 1
        return NSColor(srgbRed: r, green: g, blue: b, alpha: a)
    }

    // MARK: What a card is painted with

    /// A card's border.
    ///
    /// Dynamic rather than fixed, because the same six hues have to sit on both a near-white and a
    /// near-black card. On a light background the preset is darkened a little so a pale yellow border
    /// is still a border; on a dark one it's used as it is, which is the appearance it was picked for.
    static func border(_ token: String?) -> NSColor {
        guard let base = color(token) else { return .separatorColor }
        return NSColor(name: nil) { appearance in
            appearance.isDark ? base.withAlphaComponent(0.85) : base.shaded(by: 0.22)
        }
    }

    /// The wash behind a coloured card — a hint of the hue over the ordinary card background.
    static func wash(_ token: String?) -> NSColor {
        guard let base = color(token) else { return .clear }
        return NSColor(name: nil) { appearance in
            base.withAlphaComponent(appearance.isDark ? 0.13 : 0.09)
        }
    }

    /// A line between two cards. Uncoloured lines are deliberately not `.labelColor`: a board is mostly
    /// lines and cards, and lines drawn at full label contrast read as the subject rather than as the
    /// relationships between the things that are.
    static func edge(_ token: String?) -> NSColor {
        color(token) ?? NSColor.tertiaryLabelColor
    }

    /// The card surface itself, and the board it sits on.
    static let card = NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor(white: 0.13, alpha: 1) : NSColor(white: 1, alpha: 1)
    }
    static let board = NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor(white: 0.086, alpha: 1) : NSColor(srgbRed: 0.937, green: 0.941, blue: 0.953, alpha: 1)
    }
    /// The dot grid. Present at all, rather than a flat board, because a canvas has no edges and no
    /// content of its own — without a texture that moves, panning an empty region looks like a window
    /// that has frozen.
    static let grid = NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor(white: 1, alpha: 0.08) : NSColor(white: 0, alpha: 0.10)
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

private extension NSColor {
    /// The same hue, moved toward black by `amount`. For putting a pale preset on a light card.
    func shaded(by amount: Double) -> NSColor {
        guard let rgb = usingColorSpace(.sRGB) else { return self }
        return NSColor(srgbRed: rgb.redComponent * (1 - amount),
                       green: rgb.greenComponent * (1 - amount),
                       blue: rgb.blueComponent * (1 - amount),
                       alpha: rgb.alphaComponent)
    }
}
