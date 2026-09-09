import AppKit

/// A banner floating under a board's header, for the things the board itself can't say.
///
/// One is that cards on this board point at files that have moved — a property of the whole document,
/// not of any one card, and worth saying once at the top rather than only as a mark on each card you
/// happen to scroll past. That mark used to exist, on the card's header strip; cards have no header
/// strips now, and this is where the fact was always better said anyway. The other is that the file
/// changed in another app and PM re-read it, which the window owes you the moment it happens.
///
/// **Floating, not a bar.** It used to be a full-width strip stacked above the scroll view, which
/// pushed the whole board down by 32 points whenever it had something to say and put a hard edge across
/// the top of the window. Everything else in this window's chrome floats over the board on its own
/// material; a banner that shoves the content it is describing is the one piece that didn't. It takes
/// no space at all now — it is simply hidden when there is nothing to say.
@MainActor
final class CanvasNoticeBar: NSView {
    enum Kind {
        case warning, informational
    }

    var onRepairAll: (() -> Void)?
    var onReveal: (() -> Void)?
    /// Only for the close button. `dismiss()` is also called whenever there is simply nothing to say,
    /// and that is not the user telling us anything.
    var onDismissedByUser: (() -> Void)?

    private let label = NSTextField(labelWithString: "")
    private let actionButton = NSButton()
    private let revealButton = NSButton()
    private let dismissButton = NSButton()
    private var kind: Kind = .warning

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        // The rounded rectangle and its edge are drawn in `draw`, not set on the layer: a layer that
        // masks to its own bounds clips the shadow away, and this banner floats over a board and needs
        // the shadow to sit off it.
        shadow = NSShadow()
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.16
        layer?.shadowRadius = 10
        // Down. Negative here and positive on a card, and the difference is not a mistake: what flips
        // a layer's geometry — and its shadow with it — is being placed in a flipped *superview*, which
        // a card is and this banner isn't. Its own `isFlipped` only lays out its own subviews. See
        // `FlippedShadowTests`.
        layer?.shadowOffset = CGSize(width: 0, height: -3)
        isHidden = true

        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.lineBreakMode = .byTruncatingTail

        for (button, title, action) in [
            (revealButton, "Show Them", #selector(reveal)),
            (actionButton, "Repair Paths", #selector(repairAll)),
        ] {
            button.title = title
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.target = self
            button.action = action
        }
        dismissButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Dismiss")
        dismissButton.bezelStyle = .texturedRounded
        dismissButton.isBordered = false
        dismissButton.target = self
        dismissButton.action = #selector(dismissClicked)

        let stack = NSStackView(views: [label, revealButton, actionButton, dismissButton])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 7, left: 13, bottom: 7, right: 9)
        stack.setHuggingPriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: 9, cornerHeight: 9, transform: nil)
    }

    /// The tint sits *over* the window background rather than being the whole of the fill, so the
    /// banner is opaque enough to read against a board of cards passing under it. A translucent wash on
    /// its own let a white card show straight through the words.
    override func draw(_ dirty: NSRect) {
        let radius = 9.0
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                xRadius: radius, yRadius: radius)
        NSColor.windowBackgroundColor.setFill()
        path.fill()
        let tint: NSColor = kind == .warning
            ? NSColor.systemOrange.withAlphaComponent(0.18)
            : NSColor.controlAccentColor.withAlphaComponent(0.13)
        tint.setFill()
        path.fill()
        (kind == .warning ? NSColor.systemOrange.withAlphaComponent(0.35)
                          : NSColor.separatorColor).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    /// Put something up. Each button is shown only if it has been given a title, which is what lets one
    /// banner carry a warning with two actions on it and a one-line report with none.
    ///
    /// The two used to be one switch — the reveal button appeared whenever the action button did — and
    /// that was fine while there was one caller. It is wrong the moment a notice wants to say "Saved
    /// report.csv to Downloads" and offer only Show in Finder.
    func show(message: String, kind: Kind, actionTitle: String?, revealTitle: String? = nil) {
        self.kind = kind
        label.stringValue = message
        label.textColor = kind == .warning ? .labelColor : .secondaryLabelColor
        actionButton.isHidden = actionTitle == nil
        revealButton.isHidden = revealTitle == nil
        if let actionTitle { actionButton.title = actionTitle }
        if let revealTitle { revealButton.title = revealTitle }
        isHidden = false
        needsDisplay = true
    }

    func dismiss() {
        isHidden = true
    }

    @objc private func repairAll() { onRepairAll?() }
    @objc private func reveal() { onReveal?() }
    @objc private func dismissClicked() {
        dismiss()
        onDismissedByUser?()
    }
}
