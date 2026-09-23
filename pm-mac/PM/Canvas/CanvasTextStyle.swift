import AppKit
import PmLib

/// How a card of prose is set: how long its lines may get, and in which face.
///
/// Per card and kept on the node, for the reason `CanvasCardZoom` is — a setting that had to be made
/// again every time a card scrolled back into view would not be worth having. Beside zoom rather than
/// folded into it, because the three are independent: a card can be large and narrow, or small and
/// full width.
struct CanvasTextStyle: Equatable {
    var lineWidth: LineWidth = .readable
    var face: Face = .automatic

    /// The longest a line gets before the extra width becomes margin, in characters of the face.
    enum LineWidth: String, CaseIterable {
        case narrow, readable, wide, full

        /// Characters of prose per line, not counting the gutter the markers hang in. Nil runs to the
        /// card's edges. 78 is `MarkdownTextEditor.measureWidth`'s, so a card at the default reads at
        /// the width a note does in its window.
        var characters: CGFloat? {
            switch self {
            case .narrow: return 60
            case .readable: return 78
            case .wide: return 100
            case .full: return nil
            }
        }

        var title: String {
            switch self {
            case .narrow: return "Narrow"
            case .readable: return "Readable"
            case .wide: return "Wide"
            case .full: return "Full Width"
            }
        }
    }

    enum Face: String, CaseIterable {
        /// Proportional to read and monospaced to write — each for its own reason: the read view has no
        /// markers and sizes its headings, and the editor sets its markers on a grid that formatting
        /// can't move. See `MarkdownTextEditor.baseFont`.
        case automatic
        /// Monospaced reading as well as writing, so stepping in and out changes nothing on the card.
        case monospaced
        /// Proportional writing as well as reading. Bolding a word reflows its paragraph.
        case proportional

        var title: String {
            switch self {
            case .automatic: return "Automatic"
            case .monospaced: return "Monospaced"
            case .proportional: return "Proportional"
            }
        }
    }

    /// PM's own keys, namespaced like `pmZoom`.
    static let lineWidthKey = "pmLineWidth"
    static let faceKey = "pmFace"

    static func of(_ node: CanvasNode) -> CanvasTextStyle {
        var style = CanvasTextStyle()
        // Unknown values read as the default rather than failing: the file is shared, and a value from
        // a newer build — or a hand edit — should cost the setting, not the card.
        if case .string(let raw)? = node.extra[lineWidthKey], let width = LineWidth(rawValue: raw) {
            style.lineWidth = width
        }
        if case .string(let raw)? = node.extra[faceKey], let face = Face(rawValue: raw) {
            style.face = face
        }
        return style
    }

    /// Written as the absence of a key at its default, so a card set and set back leaves the file as
    /// it found it.
    static func set(_ style: CanvasTextStyle, on node: inout CanvasNode) {
        node.extra[lineWidthKey] = style.lineWidth == .readable ? nil : .string(style.lineWidth.rawValue)
        node.extra[faceKey] = style.face == .automatic ? nil : .string(style.face.rawValue)
    }

    /// The face to write in, at `size`.
    func editingFont(ofSize size: CGFloat) -> NSFont {
        face == .proportional ? .systemFont(ofSize: size) : .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// The face to read in, at `size`.
    func readingFont(ofSize size: CGFloat) -> NSFont {
        face == .monospaced ? .monospacedSystemFont(ofSize: size, weight: .regular) : .systemFont(ofSize: size)
    }

    /// The widest the column gets in `font`, in points, gutter included; nil for no cap. Measured in the
    /// face rather than assumed, so a zoomed card's column grows with its text.
    func maxColumnWidth(in font: NSFont, gutterAdvances: CGFloat = MarkdownTextEditor.gutterAdvances) -> CGFloat? {
        guard let characters = lineWidth.characters else { return nil }
        // An average advance for a proportional face — lowercase prose, not a row of zeros.
        let sample = font.isFixedPitch ? "0" : "abcdefghijklmnopqrstuvwxyz"
        let advance = (sample as NSString).size(withAttributes: [.font: font]).width / CGFloat(sample.count)
        return (advance * (characters + gutterAdvances)).rounded()
    }
}
