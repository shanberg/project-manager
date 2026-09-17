import AppKit

/// What separates the window's chrome from a board scrolling under it: a soft edge along the board's
/// top, where cards blur and fade into the board's own ground before they reach the controls.
/// docs/header-chrome.md L1.
///
/// **Ours, and the spec wanted the system's.** A scroll view under this window's titlebar already has
/// AppKit's edge view — an `NSScrollPocket` exactly the height of the band — but it never switches on:
/// its soft and hard layers stayed hidden at zero size with the titlebar drawn or transparent, with or
/// without a soft-preferring accessory, and with or without items in the toolbar
/// (`ScrollEdgeEffectTests`, which will say so if that ever changes). The one supported way to ask for
/// the style, an accessory, adds a strip *below* the titlebar and takes clicks. So this draws the soft
/// edge the way the system's is described — a blur, masked to fade out, over a tint toward the ground —
/// and nothing else.
///
/// **The same in every view, and nothing to switch.** It ends exactly where a workspace's tiles begin
/// (`CanvasBoardView.headerClearance` plus `CanvasTiling.edgeGap`), so over a workspace there is only
/// ground under it — blurred ground tinted toward itself, which is to say nothing — while over the
/// canvas it has cards to soften. docs/header-chrome.md Q6.
///
/// **It takes no clicks.** A drawing, not a strip: a click between the islands lands on the board
/// exactly as before.
final class CanvasEdgeView: NSView {
    /// From the top of the pane to where the fade reaches nothing.
    static var height: CGFloat { CGFloat(CanvasBoardView.headerClearance + CanvasTiling.edgeGap) }

    private let blur = NSVisualEffectView()
    private let tint = Tint()

    override init(frame: NSRect) {
        super.init(frame: frame)
        // Blurs what the window has already drawn behind it — the board — rather than what is behind
        // the window.
        blur.blendingMode = .withinWindow
        blur.material = .contentBackground
        // A background window's chrome recedes, and this is part of it (HIG: inactive windows don't use
        // materials) — the system's own answer, not a second one.
        blur.state = .followsWindowActiveState
        for layer in [blur, tint] as [NSView] {
            layer.translatesAutoresizingMaskIntoConstraints = false
            addSubview(layer)
            NSLayoutConstraint.activate([
                layer.topAnchor.constraint(equalTo: topAnchor),
                layer.leadingAnchor.constraint(equalTo: leadingAnchor),
                layer.trailingAnchor.constraint(equalTo: trailingAnchor),
                layer.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }
        blur.maskImage = Self.fade(height: Self.height)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var mouseDownCanMoveWindow: Bool { true }

    /// Opaque at the top, clear at the bottom — solid for the half the controls sit in, then gone by
    /// where the tiles start. Stretched across the width; only its alpha is read.
    private static func fade(height: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: 1, height: height), flipped: true) { rect in
            NSGradient(colorsAndLocations: (.black, 0), (.black, 0.45), (.clear, 1))?
                .draw(in: rect, angle: 90)
            return true
        }
        image.resizingMode = .stretch
        return image
    }

    /// The fade toward the board's own ground, over the blur. Drawn rather than a layer so the colour
    /// follows light and dark by itself.
    private final class Tint: NSView {
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func draw(_ dirtyRect: NSRect) {
            let ground = CanvasPalette.board
            NSGradient(colorsAndLocations: (ground.withAlphaComponent(0.72), 0),
                       (ground.withAlphaComponent(0.5), 0.45),
                       (ground.withAlphaComponent(0), 1))?
                .draw(in: bounds, angle: 90)
        }
    }
}
