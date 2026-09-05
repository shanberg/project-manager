import AppKit

/// The header on a card that stands for something else — a file, a page.
///
/// It exists to answer "what am I looking at, and is it what the canvas says it is". A plain card of
/// markdown needs no such strip and doesn't get one.
///
/// **It is a caption, not a bar.** No fill, no rule, no button: what identifies the card is the file's
/// name, and everything that used to be drawn around that name was the header competing with the thing
/// it labels. On a board the eye is picking cards out at a distance, and a filled strip with a hairline
/// under it reads as a second object stacked on the card rather than as a label on one. So the strip is
/// gone and only the words are left — small, grey, set in from the edge by the same margin the note's
/// own text uses, so the caption and the first line beneath it sit on one left edge.
///
/// The one exception is a card whose file has moved, which stays orange. That emphasis was always the
/// point, and it reads far harder now the quiet state has stopped shouting alongside it.
@MainActor
final class CanvasCardChip: NSView {
    /// The row of glyph and name. Held so the chip can report its own height — see
    /// `intrinsicContentSize`.
    private let stack: NSStackView
    private let glyph = NSImageView()
    private let label: NSTextField

    init(title: String, symbol: String, warning: String?) {
        stack = NSStackView()
        label = NSTextField(labelWithString: title)
        super.init(frame: .zero)

        glyph.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        glyph.symbolConfiguration = .init(pointSize: 9.5, weight: .regular)
        glyph.contentTintColor = warning == nil ? .tertiaryLabelColor : .systemOrange
        glyph.setContentHuggingPriority(.required, for: .horizontal)

        label.font = .systemFont(ofSize: 10.5, weight: .regular)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        stack.setViews([glyph, label], in: .leading)
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.alignment = .centerY
        // Tighter under than over, so the name sits with the content it names rather than floating
        // between the card's edge and the body. Leading matches the note preview's own 11pt inset:
        // with no strip to hold it, the caption is placed by lining it up rather than by boxing it in.
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 11, bottom: 2, right: 10)

        if let warning {
            let note = NSTextField(labelWithString: warning)
            note.font = .systemFont(ofSize: 10)
            note.textColor = .systemOrange
            note.lineBreakMode = .byTruncatingHead
            note.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
            note.toolTip = "The canvas points somewhere else. PM followed it — "
                + "the card's stored path can be corrected from the selection bar."
            stack.addArrangedSubview(note)
        }

        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setContentHuggingPriority(.required, for: .vertical)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Rename the card to whatever it is showing *now*.
    ///
    /// A web card's caption used to be fixed at the address written in the file, and a page is free to
    /// navigate anywhere — a link, a redirect, a sign-on handoff. So a card could be showing one site
    /// while its caption named another, and the moment that matters is exactly the moment you are
    /// least able to afford it: a password field is only safe to type into if you can see whose it is.
    /// The caption now follows the page, and says so when the page has left the site the card is for.
    func setTitle(_ title: String, wandered: Bool) {
        label.stringValue = title
        label.textColor = wandered ? .systemOrange : .secondaryLabelColor
        glyph.contentTintColor = wandered ? .systemOrange : .tertiaryLabelColor
        label.toolTip = wandered
            ? "This card has navigated away from the address saved on the board."
            : nil
    }

    /// The height of the row inside it, and no opinion about width.
    ///
    /// Without this the chip ate the card. It sits in a `.fill` stack above the preview, and vertical
    /// hugging — which is what is supposed to keep a header the size of its contents — has no meaning
    /// on a view that reports no intrinsic size: there is nothing for the priority to hug. So the
    /// stack was free to hand the slack to whichever view would take it, and the hosted preview,
    /// which *does* report an intrinsic size, held its ground. In a 400pt card the chip took 334 and
    /// the note got 66; behind an image, which reports nothing either, the chip took all 400 and the
    /// picture was given none. `fittingSize` is read live so the row's own font metrics decide the
    /// number rather than a constant that would drift the first time the type changed.
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: stack.fittingSize.height)
    }
}
