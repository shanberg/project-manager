import AppKit
import PmLib

/// Whether tokens are drawn as pills or left as the markup they are.
///
/// App-wide rather than per-view: a reference should look the same in the note, in a task row and in
/// the menubar, and a per-surface answer is how three surfaces end up disagreeing about one thing.
/// Stored in `UserDefaults` beside the app's other view preferences (`PMLogEnabled`, the favicon
/// switch), read live so flipping it repaints rather than requiring a relaunch.
enum TokenDisplay {
    static let defaultsKey = "PMShowsLinkSyntax"

    /// True when `[[…]]` should read as written — brackets and all.
    ///
    /// Off by default: the pill is the point. On, for anyone who wants to see what is actually in the
    /// file, and for editing a link whose target needs correcting by hand.
    static var showsSyntax: Bool {
        get { UserDefaults.standard.bool(forKey: defaultsKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: defaultsKey)
            NotificationCenter.default.post(name: Self.didChange, object: nil)
        }
    }

    static let didChange = Notification.Name("PMTokenDisplayDidChange")
}

/// Draws `[[…]]` as a pill: the brackets become the pill's own padding, and a rounded fill is drawn
/// behind the whole token.
///
/// The brackets are marked as **control characters** rather than nulled. A null glyph has no width and
/// simply disappears, which is why the first version of this produced a bare background hugging the
/// letters with nothing around it. A control character can be given a width of the layout manager's
/// choosing and draws nothing — so the same characters that used to be visible punctuation become the
/// space inside the pill, and the leading pair leaves room for the glyph that marks what kind of thing
/// the token names.
///
/// Nothing here changes the text. The file still says `[[W-3 Vendor Contract]]`; `NotesRawEdit` still
/// splices raw text; the revision a write asserts against is still a revision of the real bytes. The
/// characters are all still there, and every offset in the document still counts them — which is what
/// lets the same string be drawn as a pill here and read as markdown by Obsidian.
final class TokenLayoutManager: NSLayoutManager, NSLayoutManagerDelegate {
    /// Horizontal room inside the pill, at each end. The trailing pair of brackets supplies the right,
    /// the leading pair the left — plus the glyph's width.
    /// Total horizontal room inside the pill, split across the two bracket pairs.
    private let padding: CGFloat = 8
    /// Rounded, not a capsule: a capsule on a 16pt line reads as a button, and this is a word.
    private let radius: CGFloat = 4

    override init() {
        super.init()
        // Its own delegate: glyph generation and glyph drawing are two halves of one decision, and an
        // object apart from the drawing would only have to be kept in step with it.
        delegate = self
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        delegate = self
    }

    /// The token spans of the current text, and the bracket runs inside each.
    private func tokens(in text: String) -> [(span: NSRange, opening: NSRange, closing: NSRange)] {
        wikilinkSpans(in: text).compactMap { span in
            guard !text[span].hasPrefix("!") else { return nil }
            let range = NSRange(span, in: text)
            guard range.length > 4 else { return nil }
            return (range,
                    NSRange(location: range.location, length: 2),
                    NSRange(location: range.upperBound - 2, length: 2))
        }
    }

    private func isBracket(_ character: Int, in text: String) -> Bool {
        tokens(in: text).contains {
            NSLocationInRange(character, $0.opening) || NSLocationInRange(character, $0.closing)
        }
    }

    // MARK: glyph generation

    func layoutManager(_ layoutManager: NSLayoutManager,
                       shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                       properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
                       characterIndexes charIndexes: UnsafePointer<Int>,
                       font: NSFont, forGlyphRange glyphRange: NSRange) -> Int {
        guard !TokenDisplay.showsSyntax, let text = layoutManager.textStorage?.string else { return 0 }
        var properties = Array(UnsafeBufferPointer(start: props, count: glyphRange.length))
        var changed = false
        for i in 0..<glyphRange.length where isBracket(charIndexes[i], in: text) {
            properties[i] = .controlCharacter
            changed = true
        }
        guard changed else { return 0 }
        layoutManager.setGlyphs(glyphs, properties: &properties, characterIndexes: charIndexes,
                                font: font, forGlyphRange: glyphRange)
        return glyphRange.length
    }

    func layoutManager(_ layoutManager: NSLayoutManager,
                       shouldUse action: NSLayoutManager.ControlCharacterAction,
                       forControlCharacterAt charIndex: Int) -> NSLayoutManager.ControlCharacterAction {
        guard !TokenDisplay.showsSyntax, let text = layoutManager.textStorage?.string,
              isBracket(charIndex, in: text) else { return action }
        // Whitespace, so the pair occupies a width this decides and paints nothing.
        return .whitespace
    }

    func layoutManager(_ layoutManager: NSLayoutManager,
                       boundingBoxForControlGlyphAt glyphIndex: Int,
                       for textContainer: NSTextContainer,
                       proposedLineFragment proposedRect: NSRect,
                       glyphPosition: NSPoint, characterIndex charIndex: Int) -> NSRect {
        guard !TokenDisplay.showsSyntax, let text = layoutManager.textStorage?.string,
              let token = tokens(in: text).first(where: {
                  NSLocationInRange(charIndex, $0.opening) || NSLocationInRange(charIndex, $0.closing)
              }) else { return .zero }
        // Two characters per side, so each carries half the padding. The opening pair carries the glyph
        // as well, which is why it is the wider of the two.
        _ = token
        // A **quarter** each. This is asked per glyph, and there are two bracket characters on each
        // side — so a half here gave each side a full `padding` and the token twice what was set.
        return NSRect(x: glyphPosition.x, y: 0, width: padding / 4, height: proposedRect.height)
    }

    // MARK: drawing

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard !TokenDisplay.showsSyntax, let text = textStorage?.string else { return }
        for token in tokens(in: text) {
            let glyphs = glyphRange(forCharacterRange: token.span, actualCharacterRange: nil)
            guard NSIntersectionRange(glyphs, glyphsToShow).length > 0 else { continue }
            // Per line fragment, so a token that wraps gets a pill on each line rather than one
            // rectangle spanning the gap between them.
            enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                    in: textContainers[0]) { rect, _ in
                // The whole line fragment, not an inset of it. Insetting made the pill shorter than
                // the line it sits on, which is what left the horizontal padding looking oversized
                // next to nothing vertical.
                let pill = NSRect(x: rect.minX + origin.x, y: rect.minY + origin.y,
                                  width: rect.width, height: rect.height)
                // A wash off the text colour rather than a grey of its own: `quaternaryLabelColor` is
                // already light in dark mode, and at any alpha strong enough to see it read as a
                // filled button rather than as a marked word.
                NSColor.labelColor.withAlphaComponent(0.09).setFill()
                NSBezierPath(roundedRect: pill, xRadius: self.radius, yRadius: self.radius).fill()
            }
        }
    }

}
