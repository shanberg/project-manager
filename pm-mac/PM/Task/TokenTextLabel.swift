import AppKit
import SwiftUI
import PmLib

/// A wrapping, read-only label that draws `[[…]]` as pills and passes every other click through.
///
/// A row can't get a real pill out of SwiftUI. `AttributedString` can set a background colour, which
/// is a rectangle hugging the letters with no padding and no corners — the janky version. A rounded,
/// padded pill needs custom drawing, which needs a layout manager, which means AppKit. Sharing
/// `TokenLayoutManager` with the editors is also what stops the two from drifting: one drawing path,
/// so a token looks the same whether you're reading it or typing it.
///
/// **It is transparent to clicks except on a pill.** `hitTest` returns nil anywhere else, so the row
/// underneath keeps its own click, double-click and drag exactly as before — which is the behaviour
/// that matters, because a label that swallowed clicks would break selecting a task by clicking its
/// text.
struct TokenTextLabel: NSViewRepresentable {
    let attributed: NSAttributedString
    /// Open the project a pill names. Nil where the surface has nowhere to go.
    var onOpenProject: ((String) -> Void)?

    func makeNSView(context: Context) -> TokenLabelView {
        let view = TokenLabelView()
        view.onOpenProject = onOpenProject
        view.attributed = attributed
        return view
    }

    func updateNSView(_ view: TokenLabelView, context: Context) {
        view.onOpenProject = onOpenProject
        if view.attributed != attributed { view.attributed = attributed }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TokenLabelView,
                      context: Context) -> CGSize? {
        nsView.size(offered: proposal.width)
    }

    /// Where the first line's baseline sits, measured from the top of the view.
    ///
    /// The row is an `HStack(alignment: .firstTextBaseline)`, and a representable reports no baseline
    /// of its own — so SwiftUI falls back to the view's bottom edge and aligns the checkbox to *that*,
    /// which is the gap that appeared above every task. Given as an alignment guide by the caller.
    static func firstBaseline(size: CGFloat, focused: Bool) -> CGFloat {
        let font = NSFont.systemFont(ofSize: size, weight: focused ? .semibold : .regular)
        return NSLayoutManager().defaultBaselineOffset(for: font)
    }
}

/// The view behind `TokenTextLabel`. Its own TextKit stack rather than an `NSTextView`, because it
/// needs none of a text view's editing, selection or responder behaviour — only its layout and its
/// drawing.
final class TokenLabelView: NSView {
    /// The width a container is given when measuring text that shouldn't wrap.
    ///
    /// Large and finite, **not** `CGFloat.greatestFiniteMagnitude`. TextKit does arithmetic on the
    /// container's size, and at 1.8e308 that arithmetic overflows — the layout it returns is garbage,
    /// and the garbage came back as an "ideal" width of a few hundred points, which is why every row in
    /// the list wrapped into a narrow column while the window had room to spare. Any value past the
    /// longest line anybody will type does the job.
    static let unbounded: CGFloat = 100_000

    var onOpenProject: ((String) -> Void)?

    private let storage = NSTextStorage()
    private let layoutManager = TokenLayoutManager()
    private let container = NSTextContainer(size: NSSize(width: 0, height: TokenLabelView.unbounded))

    var attributed: NSAttributedString = NSAttributedString() {
        didSet {
            storage.setAttributedString(attributed)
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        NotificationCenter.default.addObserver(forName: TokenDisplay.didChange, object: nil,
                                               queue: .main) { [weak self] _ in
            self?.reflowForDisplayChange()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    /// Flipping the syntax preference changes how wide every token lays out, so the glyphs have to be
    /// regenerated rather than merely redrawn.
    private func reflowForDisplayChange() {
        layoutManager.invalidateGlyphs(forCharacterRange: NSRange(location: 0, length: storage.length),
                                changeInLength: 0, actualCharacterRange: nil)
        layoutManager.invalidateLayout(forCharacterRange: NSRange(location: 0, length: storage.length),
                                actualCharacterRange: nil)
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    /// The size to report for a proposed width: never wider than one line needs, never wider than
    /// offered, and as tall as the result actually wraps to.
    ///
    /// Both halves matter, and each was a bug on its own. Reporting the *wrapped* width measured at the
    /// proposal told the stack this view wanted only as much as it had just squeezed itself into, so it
    /// never grew back. Reporting the *proposal* in full made it as greedy as the `Spacer` beside it,
    /// and SwiftUI split the row between them — which is why a short task wrapped in a window with room
    /// to spare. The ideal is measured unconstrained and is the ceiling.
    func size(offered proposal: CGFloat?) -> CGSize {
        let ideal = layoutSize(fitting: TokenLabelView.unbounded)
        guard let proposal, proposal.isFinite else { return ideal }
        // SwiftUI probes with a zero width to learn how small this view can go, and the honest answer
        // is the widest single word — a wrapping label can be that narrow and no narrower. Answering
        // with the *ideal* made it look inflexible at its full width, and a stack with two
        // apparently-inflexible children divides the space between them.
        guard proposal > 0 else {
            return CGSize(width: minimumWidth, height: layoutSize(fitting: minimumWidth).height)
        }
        let width = min(proposal, ideal.width)
        return CGSize(width: width, height: layoutSize(fitting: width).height)
    }

    /// The narrowest this can wrap to without breaking a word.
    ///
    /// Measured word by word rather than by laying out in a 1pt container, which is the obvious thing
    /// and gives the wrong answer: `usedRect` is clamped to the container, so a container narrower
    /// than the longest word reports the container's width and a column of single characters. The
    /// widest word is the real floor.
    private var minimumWidth: CGFloat {
        let text = storage.string as NSString
        var widest: CGFloat = 0
        text.enumerateSubstrings(in: NSRange(location: 0, length: text.length),
                                 options: [.byWords, .substringNotRequired]) { _, range, _, _ in
            guard range.upperBound <= self.storage.length else { return }
            widest = max(widest, ceil(self.storage.attributedSubstring(from: range).size().width))
        }
        return max(widest, 1)
    }

    /// What the text actually occupies at a given container width, unclamped.
    ///
    /// Separate from `size(fitting:)` because the clamp that one applies — never report more width
    /// than offered — is right for a view reporting its own frame and wrong for a measurement. Asked
    /// for the minimum at a 1pt container, the clamped version dutifully answered "1pt".
    private func layoutSize(fitting width: CGFloat) -> CGSize {
        container.size = NSSize(width: width, height: TokenLabelView.unbounded)
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container)
        return CGSize(width: ceil(used.width), height: ceil(used.height))
    }

    func size(fitting width: CGFloat) -> CGSize {
        let used = layoutSize(fitting: width)
        return CGSize(width: min(width, used.width), height: used.height)
    }

    override var intrinsicContentSize: NSSize {
        size(fitting: bounds.width > 0 ? bounds.width : TokenLabelView.unbounded)
    }

    override func layout() {
        super.layout()
        if container.size.width != bounds.width {
            container.size = NSSize(width: bounds.width, height: TokenLabelView.unbounded)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let glyphs = layoutManager.glyphRange(for: container)
        layoutManager.drawBackground(forGlyphRange: glyphs, at: .zero)
        layoutManager.drawGlyphs(forGlyphRange: glyphs, at: .zero)
    }

    // MARK: clicks

    /// The token name under a point in this view's coordinates, if there is one.
    private func tokenName(at point: NSPoint) -> String? {
        guard onOpenProject != nil else { return nil }
        let text = storage.string
        layoutManager.ensureLayout(for: container)
        // `glyphIndex(for:in:fractionOfDistanceThrough:)` returns the nearest glyph even when the point
        // is past the end of the line, so the hit is confirmed against the glyph's own rect before it
        // counts — otherwise clicking the empty space to the right of a line would open whatever token
        // that line happens to end with.
        var fraction: CGFloat = 0
        let glyph = layoutManager.glyphIndex(for: point, in: container,
                                      fractionOfDistanceThroughGlyph: &fraction)
        guard glyph < layoutManager.numberOfGlyphs else { return nil }
        let rect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        guard rect.contains(point) else { return nil }
        let character = layoutManager.characterIndexForGlyph(at: glyph)
        guard character < (text as NSString).length else { return nil }
        let index = String.Index(utf16Offset: character, in: text)
        guard let span = wikilinkSpans(in: text).first(where: {
            $0.lowerBound <= index && index < $0.upperBound
        }), !text[span].hasPrefix("!") else { return nil }
        return wikilinkDisplayName(String(text[span]))
    }

    /// Transparent to everything but a pill, so the row underneath keeps its own gestures.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return tokenName(at: local) != nil ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        guard let name = tokenName(at: local) else { return }
        onOpenProject?(name)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        // A pointing hand over a pill, which is how anything clickable says so.
        let text = storage.string
        layoutManager.ensureLayout(for: container)
        for span in wikilinkSpans(in: text) where !text[span].hasPrefix("!") {
            let glyphs = layoutManager.glyphRange(forCharacterRange: NSRange(span, in: text),
                                           actualCharacterRange: nil)
            layoutManager.enumerateEnclosingRects(forGlyphRange: glyphs,
                                           withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                           in: container) { rect, _ in
                self.addCursorRect(rect, cursor: .pointingHand)
            }
        }
    }
}
