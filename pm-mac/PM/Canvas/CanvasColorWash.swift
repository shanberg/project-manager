import AppKit
import PmLib

/// A board's ground, and the project's colour washed down it from the top of the window (backlog 29).
///
/// **Behind the cards and the tiles.** It sits behind the scroll view, and the board paints no
/// ground of its own, so the colour is part of what the board lies on rather than a film over it: it
/// shows between cards, in a tiling's gaps and up behind the header, and never on a card.
///
/// It fills the scroll view and doesn't move with it — the wash is anchored to the window, not to the
/// board — so panning slides the cards over a still ground.
///
/// **Smooth rather than linear.** A straight 1→0 ramp of alpha has a visible start and a visible end —
/// the eye finds the two corners of the curve — so the fall-off is a smootherstep, flat at both ends.
/// And a faint colour over a couple of hundred pixels is only a few dozen 8-bit levels, which shows as
/// bands; so the ramp is rendered into a bitmap once per colour, height and scale, with each pixel
/// dithered by up to half a level before it is rounded. The bands dissolve and nothing looks grainy.
final class CanvasColorWash: NSView {

    /// How far down the window the colour reaches: three and a half header bands.
    static let height = (CanvasSoftEdge.band * 3.5).rounded()

    /// Strongest at the very top. Dark appearance takes more, since a colour over near-black reads
    /// weaker than the same alpha over near-white.
    static func peak(dark: Bool) -> Double { dark ? 0.26 : 0.2 }

    var color: ProjectColor? {
        didSet {
            guard color != oldValue else { return }
            cached = nil
            needsDisplay = true
        }
    }

    /// The project's texture, feathered into the top-left above the wash and inked in its colour — see
    /// `CanvasTexture`. Nil for none.
    var texture: CanvasTexture.Spec? {
        didSet {
            guard texture != oldValue else { return }
            cachedTexture = nil
            needsDisplay = true
        }
    }

    /// How far down this view the colour reaches. `height` on a board; the settings sheet's preview,
    /// a window in miniature, scales it to its own size so the two keep their proportions.
    var washHeight: CGFloat = CanvasColorWash.height {
        didSet {
            guard washHeight != oldValue else { return }
            cached = nil
            needsDisplay = true
        }
    }

    /// What the wash lies on — `CanvasPalette.board`, or a tiling's ground mid-crossing.
    var ground: NSColor = CanvasPalette.board {
        didSet { needsDisplay = true }
    }

    private var cached: (key: String, image: CGImage)?
    private var cachedTexture: (key: String, image: CGImage)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        // The texture stands down under Increase Contrast and Reduce Transparency, and comes back
        // without a relaunch when they're turned off.
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(displayOptionsChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { NSWorkspace.shared.notificationCenter.removeObserver(self) }

    @objc private func displayOptionsChanged() { needsDisplay = true }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        cached = nil
        cachedTexture = nil
        needsDisplay = true
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        if texture != nil { needsDisplay = true }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        cached = nil
        needsDisplay = true
    }

    override func draw(_ dirty: NSRect) {
        ground.setFill()
        dirty.fill()
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        var rgb: (Double, Double, Double)?
        var dark = false
        // Resolved in this view's appearance, since a named colour is a different colour in dark.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            if let resolved = color?.nsColor.usingColorSpace(.sRGB) {
                rgb = (resolved.redComponent, resolved.greenComponent, resolved.blueComponent)
            }
        }
        if let rgb, dirty.minY < washHeight { drawWash(rgb: rgb, dark: dark, in: dirty, context: context) }
        drawTexture(rgb: rgb, dark: dark, in: dirty, context: context)
    }

    /// The texture over the wash, from the corner — in the wash's colour, so the two are one ground.
    ///
    /// Its reach is a share of this view, so a resize redraws it — except mid-drag, where the last one
    /// is kept and redrawn once the drag ends. Only the reach lags; the pixels stay whole either way.
    private func drawTexture(rgb: (Double, Double, Double)?, dark: Bool, in dirty: NSRect, context: CGContext) {
        guard let texture, !CanvasTexture.isSuppressed else { return }
        let reach = CanvasTexture.reach(texture.style, in: bounds.size)
        guard dirty.intersects(CGRect(origin: .zero, size: reach)) || inLiveResize else { return }
        let ink = CanvasTexture.ink(for: rgb, dark: dark)
        let key = "\(ink)|\(dark)|\(reach)"
        if cachedTexture?.key != key, !(inLiveResize && cachedTexture != nil) {
            let pixel = CGFloat(texture.style.pixel)
            guard let image = CanvasTexture.image(tile: texture.tile, ink: ink,
                                                  alpha: CanvasTexture.alpha(texture.style, dark: dark),
                                                  pixel: pixel, reach: reach)
            else { return }
            cachedTexture = (key, image)
        }
        guard let image = cachedTexture?.image else { return }
        let pixel = CGFloat(texture.style.pixel)
        let size = CGSize(width: CGFloat(image.width) * pixel, height: CGFloat(image.height) * pixel)
        context.saveGState()
        // Each cell a hard-edged square of whole points: no smoothing between them.
        context.interpolationQuality = .none
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: size))
        context.restoreGState()
    }

    private func drawWash(rgb: (Double, Double, Double), dark: Bool, in dirty: NSRect, context: CGContext) {
        let scale = window?.backingScaleFactor ?? 2
        let rows = Int((washHeight * scale).rounded())
        guard rows > 0 else { return }
        let key = "\(rgb)|\(dark)|\(rows)"
        if cached?.key != key {
            guard let image = Self.ramp(rgb: rgb, peak: Self.peak(dark: dark), rows: rows) else { return }
            cached = (key, image)
        }
        guard let image = cached?.image else { return }
        // A tile of `tileWidth` pixels, repeated across: the dither is noise, and noise tiled sideways
        // at this size is not a pattern anyone can see.
        let tile = CGFloat(Self.tileWidth) / scale
        context.saveGState()
        // The bitmap's first row is its top; this view is flipped, so undo the flip for the draw.
        context.translateBy(x: 0, y: washHeight)
        context.scaleBy(x: 1, y: -1)
        var x = (dirty.minX / tile).rounded(.down) * tile
        while x < dirty.maxX {
            context.draw(image, in: CGRect(x: x, y: 0, width: tile, height: washHeight))
            x += tile
        }
        context.restoreGState()
    }

    static let tileWidth = 128

    /// How strong the wash is `t` of the way down, 0 at the top to 1 at the bottom: smootherstep's
    /// complement, which leaves the top and the bottom with no slope to see.
    static func strength(at t: Double) -> Double {
        let t = min(max(t, 0), 1)
        return 1 - t * t * t * (t * (t * 6 - 15) + 10)
    }

    /// The ramp as premultiplied sRGB pixels, dithered.
    static func ramp(rgb: (Double, Double, Double), peak: Double, rows: Int) -> CGImage? {
        let width = tileWidth
        var pixels = [UInt8](repeating: 0, count: width * rows * 4)
        var random = SystemRandomNumberGenerator()
        for y in 0..<rows {
            let alpha = peak * strength(at: (Double(y) + 0.5) / Double(rows))
            let channels = [rgb.0 * alpha, rgb.1 * alpha, rgb.2 * alpha, alpha]
            for x in 0..<width {
                let base = (y * width + x) * 4
                // One dither value per pixel for all four channels, so the colour doesn't drift.
                let dither = Double.random(in: -0.5..<0.5, using: &random)
                let a = min(max((channels[3] * 255 + dither).rounded(), 0), 255)
                for c in 0..<3 {
                    // Premultiplied: a channel can't exceed its alpha.
                    pixels[base + c] = UInt8(min(max((channels[c] * 255 + dither).rounded(), 0), a))
                }
                pixels[base + 3] = UInt8(a)
            }
        }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: rows, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
