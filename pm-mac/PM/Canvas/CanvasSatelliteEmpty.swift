import AppKit

/// What a tile shows while its card is out in a satellite: the slot kept, saying what is out and where.
///
/// **The slot stays.** A tile moved out used to leave the tiling, the rest closing up over its place,
/// so the window gave no sign the card had ever been there and people lost track of their windows.
/// Now the card stays in its tile and draws this in place of its content (`CanvasNodeView.lend`): its
/// icon and name, that it is in a window, Show to bring that window forward and Bring Back to put the
/// card home — into this slot, since it never left it.
///
/// AppKit controls on the card's own ground, as a Finder empty state is drawn: no frame of its own,
/// since the tile is already one.
@MainActor
final class CanvasSatelliteEmpty: NSView {
    private unowned let card: CanvasNodeView
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")

    init(card: CanvasNodeView) {
        self.card = card
        super.init(frame: .zero)
        let described = card.board.describeCard(card.node.id)
        icon.image = CanvasSatelliteWindow.symbol(for: described?.kind)?
            .withSymbolConfiguration(.init(pointSize: 22, weight: .regular))
        icon.contentTintColor = .tertiaryLabelColor
        title.stringValue = described?.title ?? "Card"
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .labelColor
        title.alignment = .center
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let note = NSTextField(labelWithString: "In a window")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor

        let show = NSButton(title: "Show", target: self, action: #selector(showWindow))
        show.toolTip = "Bring its window forward"
        let back = NSButton(title: "Bring Back", target: self, action: #selector(bringBack))
        back.toolTip = "Put it back in this tile"
        back.bezelColor = .controlAccentColor
        for button in [show, back] {
            button.bezelStyle = .push
            button.controlSize = .small
            button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        }
        let buttons = NSStackView(views: [show, back])
        buttons.spacing = 6

        let stack = NSStackView(views: [icon, title, note, buttons])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 4
        stack.setCustomSpacing(10, after: note)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("\(title.stringValue), in a window")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func showWindow() { card.lentTo?.reveal(card) }
    @objc private func bringBack() { card.lentTo?.giveBack(card) }
}
