import AppKit

/// A picture on a card: fitted inside it, or filling it when the two are nearly the same shape.
///
/// **A board of photographs was a board of grey margins.** A picture card fitted its picture — the
/// whole of it, letterboxed — so a dozen pictures in a dozen proportions on cards in a dozen others
/// left every card with a different band of empty surface around a different edge. The picture is the
/// whole content of that card, and the margin was most of what you saw.
///
/// So a card that is *nearly* the picture's shape fills instead: the picture is scaled to cover the
/// card and the overflow is clipped. Within the tolerance below, what is lost is a few per cent off
/// two edges of a photograph, which nobody misses and no-one can see is missing; what is gained is a
/// board whose cards are the pictures rather than frames around them.
///
/// **Beyond the tolerance it goes on fitting, and that is the other half of the design.** A card
/// deliberately made wide under a tall picture is a decision — a panorama cropped to a square would
/// be the app throwing away the composition the card was shaped for. Fill is a tidy-up for a card
/// that is *approximately right already*, never a re-crop.
///
/// Built around `NSImageView` rather than drawing the picture here, so an animated GIF still animates
/// and the image still names itself to VoiceOver. The fill is done by *layout*: the image view is
/// given the smallest frame of the picture's own shape that covers the card, centred, and this view
/// clips. `scaleProportionallyUpOrDown` then fills that frame exactly, because the frame is the
/// picture's shape.
@MainActor
final class CanvasPictureView: NSView {
    private let picture = NSImageView()

    var image: NSImage? {
        get { picture.image }
        set {
            picture.image = newValue
            needsLayout = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // The overflow of a filled picture is clipped here rather than by the card, which masks
        // nothing: a card's shadow lives outside its own bounds. See `CanvasNodeView`.
        layer?.masksToBounds = true
        picture.imageScaling = .scaleProportionallyUpOrDown
        addSubview(picture)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func setAccessibilityLabel(_ label: String?) {
        picture.setAccessibilityLabel(label)
    }

    override func layout() {
        super.layout()
        guard let size = image?.size, size.width > 0, size.height > 0 else {
            picture.frame = bounds
            return
        }
        guard CanvasPictureFit.fills(card: bounds.size, picture: size) else {
            picture.frame = bounds
            return
        }
        // The smallest rect of the picture's shape that covers the card, centred on it. Rounded
        // outwards, so a half-point of rounding shows a half-point more picture rather than a
        // half-point of card.
        let scale = max(bounds.width / size.width, bounds.height / size.height)
        let filled = NSSize(width: (size.width * scale).rounded(.up),
                            height: (size.height * scale).rounded(.up))
        picture.frame = NSRect(x: ((bounds.width - filled.width) / 2).rounded(.down),
                               y: ((bounds.height - filled.height) / 2).rounded(.down),
                               width: filled.width, height: filled.height)
    }
}

/// Whether a card of one shape should fill with a picture of another, or fit it.
///
/// Pulled out of the view so the one judgement in it can be read and tested on its own: it is a
/// comparison of two aspect ratios against a tolerance, and nothing else.
enum CanvasPictureFit {
    /// **Eight per cent, and it is a constant nobody sees rather than a setting.**
    ///
    /// The entry that asked for this left three options open — a preference, a per-card switch, or a
    /// constant — and the constant is the only one that pays for itself. A preference is a question
    /// about every picture asked once, in a window nobody opens, to change a thing you would rather
    /// judge per card; and a per-card switch is a control on a card whose whole content is a picture,
    /// for a difference of a few per cent of its edges. If a card is the wrong shape for its picture,
    /// the thing to do is what you would do anyway — resize the card — and this follows.
    ///
    /// Eight per cent is what "nearly the same shape" is worth: filling then loses at most about seven
    /// per cent of one dimension, three and a half off each edge of a centred picture, which is inside
    /// what a photograph carries as margin. Twice that starts eating composition.
    static let tolerance = 0.08

    static func fills(card: CGSize, picture: CGSize, tolerance: Double = CanvasPictureFit.tolerance) -> Bool {
        guard card.width > 0, card.height > 0, picture.width > 0, picture.height > 0 else { return false }
        let cardShape = card.width / card.height
        let pictureShape = picture.width / picture.height
        // A ratio of the ratios rather than a difference, so the answer doesn't depend on which way up
        // the two are: 3:2 against 2:3 is the same disagreement read from either end.
        return max(cardShape / pictureShape, pictureShape / cardShape) - 1 <= tolerance
    }
}
