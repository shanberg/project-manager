import AppKit

/// The strip along the top of a canvas window, for the two things the board itself can't say.
///
/// One is that cards on this board point at files that have moved — which is a property of the whole
/// document, not of any one card, and which is worth saying once at the top rather than only as a
/// mark on each card you happen to scroll past. The other is that the file changed in another app and
/// PM re-read it, which the window owes you the moment it happens.
///
/// It takes no space when there's nothing to say: the bar's height collapses to zero rather than
/// leaving an empty band, so an ordinary board is board all the way to the titlebar.
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
    private var heightConstraint: NSLayoutConstraint!
    private var kind: Kind = .warning

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

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
        ])
        heightConstraint = heightAnchor.constraint(equalToConstant: 0)
        heightConstraint.isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    override func draw(_ dirty: NSRect) {
        guard heightConstraint.constant > 0 else { return }
        let tint: NSColor = kind == .warning
            ? NSColor.systemOrange.withAlphaComponent(0.16)
            : NSColor.controlAccentColor.withAlphaComponent(0.12)
        tint.setFill()
        bounds.fill()
        NSColor.separatorColor.setStroke()
        let line = NSBezierPath()
        line.move(to: NSPoint(x: 0, y: bounds.maxY - 0.5))
        line.line(to: NSPoint(x: bounds.maxX, y: bounds.maxY - 0.5))
        line.stroke()
    }

    func show(message: String, kind: Kind, actionTitle: String?) {
        self.kind = kind
        label.stringValue = message
        label.textColor = kind == .warning ? .labelColor : .secondaryLabelColor
        actionButton.isHidden = actionTitle == nil
        revealButton.isHidden = actionTitle == nil
        if let actionTitle { actionButton.title = actionTitle }
        heightConstraint.constant = 32
        needsDisplay = true
    }

    func dismiss() {
        heightConstraint.constant = 0
        needsDisplay = true
    }

    @objc private func repairAll() { onRepairAll?() }
    @objc private func reveal() { onReveal?() }
    @objc private func dismissClicked() {
        dismiss()
        onDismissedByUser?()
    }
}
