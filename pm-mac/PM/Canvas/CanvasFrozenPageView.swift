import AppKit

/// A picture of a page, drawn the way the page itself would have been.
///
/// It replaced an `NSImageView` set to `scaleAxesIndependently`, which stretches — and a card is very
/// often not the shape it was when the picture was taken. Change a workspace's arrangement and every
/// tile in it is a different shape; the frozen cards then showed a page squashed into a column or
/// pulled across the screen, which is the one way a placeholder can be worse than a globe. A globe
/// admits it isn't the page.
///
/// **Scaled to the width, anchored at the top.** That is how a picture of a page degrades honestly: the
/// column keeps its proportions, the headline stays a headline, and a card that got taller shows the
/// top of the page and then stops — which is what a page scrolled to the top actually looks like. The
/// alternative, fitting the whole picture inside and letterboxing it, centres the page in a grey frame
/// and reads as a photograph of a screen rather than as a screen.
///
/// The band below a picture too short for its card is painted in the colour WebKit gives a page that
/// asks for none, so it reads as the page continuing rather than as the card showing through.
@MainActor
final class CanvasFrozenPageView: NSView {
    var image: NSImage? {
        didSet { needsDisplay = true }
    }

    /// So that "the top of the picture" and "the top of the view" are the same y.
    override var isFlipped: Bool { true }

    /// The picture is opaque over its own area and the fill covers the rest, so nothing under this is
    /// ever visible — which lets AppKit skip drawing the placeholder beneath it.
    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        dirtyRect.fill()
        guard let image, image.size.width > 0, bounds.width > 0 else { return }
        let scale = bounds.width / image.size.width
        image.draw(in: NSRect(x: 0, y: 0, width: bounds.width, height: image.size.height * scale))
    }

    /// Redrawn on every resize, because the scale is a function of the width — without this a tile
    /// being dragged wider shows the picture at the width it had when it was installed.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }
}
