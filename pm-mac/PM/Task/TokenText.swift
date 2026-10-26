import AppKit
import SwiftUI
import PmLib

/// A wrapping, read-only label that draws `[[…]]` as pills — `TokenTextLabel`'s job, done in SwiftUI.
///
/// **Why it isn't the AppKit label any more.** Every NSView in a scrolled document costs time on
/// every scroll tick, and each label drew itself through a layout manager as it came into view.
/// Measured on S-004's card (2026-10-24, headless): 3.1 → 2.3ms median per tick, and 3.1 → 2.7ms with
/// a pill on every row. What is left is the lazy stack's own bookkeeping, not the rows.
///
/// **How SwiftUI gets a real pill.** `AttributedString`'s background colour hugs the letters with no
/// padding and no corners, which is why the row went to AppKit in the first place. A `TextRenderer`
/// fixes it: the layout is still `Text`'s, and the renderer paints a rounded fill behind the token's
/// runs before drawing them. The padding is the same trick `TokenLayoutManager` plays — the brackets
/// stay in the text, kerned to a quarter of `TokenLayoutManager.padding` each and drawn clear — so a
/// pill is as wide here as in the editors, and a `CODE-NNN ` prefix the app isn't writing is left out.
///
/// **Transparent to clicks except on a pill.** A pill reports where it landed through
/// `Text.LayoutKey` and gets a tap target of its own; the rest of the row keeps its click,
/// double-click and drag.
struct TokenText: View {
    let attributed: NSAttributedString
    /// Open the project a pill names. Nil where the surface has nowhere to go.
    var onOpenProject: ((String) -> Void)?

    // Read so flipping either preference redraws the row: one changes whether there are pills at
    // all, the other which code prefixes a pill leaves out.
    @AppStorage(TokenDisplay.defaultsKey) private var showsSyntax = false
    @AppStorage(ProjectCodes.defaultsKey) private var codesShown = true

    var body: some View {
        let tokenised = TokenisedText(attributed, showsSyntax: showsSyntax)
        if tokenised.tokens.isEmpty {
            tokenised.text
        } else if let onOpenProject {
            tokenised.text
                .textRenderer(TokenPillRenderer())
                .modifier(TokenClicks(open: onOpenProject))
        } else {
            tokenised.text.textRenderer(TokenPillRenderer())
        }
    }
}

/// A run of a pill, so the renderer can find its edges and the click layer its name.
struct TokenRun: TextAttribute {
    /// Which token in the text, so a token's runs are told apart from its neighbour's.
    let token: Int
    /// The name a click opens, as `TokenLabelView` gave it: the token's own text, code and all.
    let name: String
    /// A bracket — the pill's padding, which takes room and shows nothing.
    let isPadding: Bool
}

/// `attributed` as one `Text`, each token's runs marked with `TokenRun`.
struct TokenisedText {
    let text: Text
    let tokens: [String]

    @MainActor
    init(_ attributed: NSAttributedString, showsSyntax: Bool) {
        let string = attributed.string
        let ns = string as NSString
        var tokens: [String] = []
        var text = Text(verbatim: "")
        var location = 0

        func append(_ range: NSRange, as tag: TokenRun? = nil) {
            guard range.length > 0 else { return }
            attributed.enumerateAttributes(in: range) { attributes, run, _ in
                var piece = Self.piece(ns.substring(with: run), attributes, padding: tag?.isPadding == true)
                if let tag { piece = piece.customAttribute(tag) }
                text = Text("\(text)\(piece)")
            }
        }

        if !showsSyntax {
            for span in wikilinkSpans(in: string) where !string[span].hasPrefix("!") {
                let range = NSRange(span, in: string)
                guard range.length > 4 else { continue }
                append(NSRange(location: location, length: range.location - location))
                let id = tokens.count
                let name = wikilinkDisplayName(String(string[span]))
                tokens.append(name)
                let opening = NSRange(location: range.location, length: 2)
                let closing = NSRange(location: range.upperBound - 2, length: 2)
                let code = TokenLayoutManager.codeRange(inTokenAt: range, in: string)
                let innerStart = code?.upperBound ?? opening.upperBound
                append(opening, as: TokenRun(token: id, name: name, isPadding: true))
                append(NSRange(location: innerStart, length: closing.location - innerStart),
                       as: TokenRun(token: id, name: name, isPadding: false))
                append(closing, as: TokenRun(token: id, name: name, isPadding: true))
                location = range.upperBound
            }
        }
        append(NSRange(location: location, length: ns.length - location))
        self.text = text
        self.tokens = tokens
    }

    /// One attribute run as `Text`. Only what `taskLineAttributed` sets is carried: font, colour,
    /// strikethrough and the wait's glyph.
    @MainActor
    private static func piece(_ string: String, _ attributes: [NSAttributedString.Key: Any],
                              padding: Bool) -> Text {
        if let attachment = attributes[.attachment] as? NSTextAttachment, let image = attachment.image {
            // An attachment's bounds are relative to the baseline, as `baselineOffset` is.
            return Text(Image(nsImage: image)).baselineOffset(attachment.bounds.minY)
        }
        var piece = Text(verbatim: string)
        let font = attributes[.font] as? NSFont ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        piece = piece.font(Font(font as CTFont))
        let color = (attributes[.foregroundColor] as? NSColor).map { Color(nsColor: $0) } ?? .primary
        // A bracket is laid out and drawn like any glyph, only clear — so a struck-through task's line
        // still runs through the pill's padding, as it does in `TokenLayoutManager`.
        piece = piece.foregroundColor(padding ? .clear : color)
        if let style = attributes[.strikethroughStyle] as? Int, style != 0 {
            piece = piece.strikethrough(color: color)
        }
        if padding { piece = piece.kerning(bracketKern(font)) }
        return piece
    }

    /// What a bracket's advance has to change by to come to a quarter of the pill's padding.
    @MainActor
    private static func bracketKern(_ font: NSFont) -> CGFloat {
        if let known = kerns[font] { return known }
        let advance = NSAttributedString(string: "[", attributes: [.font: font]).size().width
        let kern = TokenLayoutManager.padding / 4 - advance
        kerns[font] = kern
        return kern
    }

    // `]` and `[` are mirror images in the system font, so one advance serves both.
    @MainActor private static var kerns: [NSFont: CGFloat] = [:]
}

/// Paints each token's pill behind its runs.
struct TokenPillRenderer: TextRenderer {
    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        // `Color.primary`, not `Color(nsColor: TokenLayoutManager.fill)`: a dynamic AppKit colour with
        // an alpha came out clear in a renderer. Primary is the label colour, resolved in context.
        let fill = Color.primary.opacity(TokenLayoutManager.fillAlpha)
        for line in layout {
            // Per line, so a token that wraps gets a pill on each line it sits on.
            var pills: [Int: CGRect] = [:]
            for run in line {
                guard let tag = run[TokenRun.self] else { continue }
                let rect = run.typographicBounds.rect
                pills[tag.token] = pills[tag.token].map { $0.union(rect) } ?? rect
            }
            for rect in pills.values {
                context.fill(Path(roundedRect: rect, cornerRadius: TokenLayoutManager.radius), with: .color(fill))
            }
            context.draw(line)
        }
    }
}

/// A tap target over each pill, from where the text's layout says the pill went.
///
/// **Only while the pointer is over the text.** A click needs the pointer there first, and building
/// the targets for every row on screen — a geometry reader and a pass over the layout each — was
/// what a long project's card spent scrolling, more than drawing the pills.
struct TokenClicks: ViewModifier {
    let open: (String) -> Void
    @State private var pointing = false

    struct Zone: Equatable {
        let name: String
        let rect: CGRect
    }

    func body(content: Content) -> some View {
        // Hover outside the overlay, so the targets appearing under the pointer don't count as it
        // leaving.
        content
            .overlayPreferenceValue(Text.LayoutKey.self) { layouts in
                if pointing { targets(layouts) }
            }
            .onHover { pointing = $0 }
    }

    private func targets(_ layouts: [Text.LayoutKey.AnchoredLayout]) -> some View {
        GeometryReader { proxy in
            ForEach(Array(Self.zones(in: layouts, proxy: proxy).enumerated()), id: \.offset) { _, zone in
                Color.clear
                    .contentShape(Rectangle())
                    .frame(width: zone.rect.width, height: zone.rect.height)
                    .position(x: zone.rect.midX, y: zone.rect.midY)
                    .onTapGesture { open(zone.name) }
                    .pointerStyle(.link)
            }
        }
    }

    static func zones(in layouts: [Text.LayoutKey.AnchoredLayout], proxy: GeometryProxy) -> [Zone] {
        layouts.flatMap { anchored in
            let origin = proxy[anchored.origin]
            return anchored.layout.flatMap { line in
                var pills: [Int: Zone] = [:]
                for run in line {
                    guard let tag = run[TokenRun.self] else { continue }
                    let rect = run.typographicBounds.rect.offsetBy(dx: origin.x, dy: origin.y)
                    pills[tag.token] = Zone(name: tag.name, rect: pills[tag.token].map { $0.rect.union(rect) } ?? rect)
                }
                return pills.keys.sorted().compactMap { pills[$0] }
            }
        }
    }
}
