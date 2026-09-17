import AppKit
import QuartzCore

/// What separates the window's chrome from a board scrolling under it: the cards fade out along the
/// top of the pane before they reach the controls. docs/header-chrome.md L1.
///
/// **A mask on the cards, not a film over them.** This was a view laid over the board — a blur, masked
/// to fade out, under a tint toward the board's grey — and the tint was grey whatever was beneath it,
/// so once the ground under the board could carry a project's colour (`CanvasColorWash`) the edge sat
/// on it as a muddy band exactly where the colour is strongest. Masking the scroll view instead fades
/// the cards themselves to nothing, and what shows through is the real ground, washed or not. The blur
/// went with it: there is nothing left over the header to blur.
///
/// **Why ours.** A scroll view under this window's titlebar already has AppKit's edge view — an
/// `NSScrollPocket` exactly the height of the band — but it never switches on (`ScrollEdgeEffectTests`,
/// which will say so if that ever changes).
///
/// **The board's, not a workspace's.** The fade reaches well below where a workspace's tiles begin
/// (`CanvasBoardView.headerClearance` plus `CanvasTiling.edgeGap`), so over a tiling it would eat into
/// the top of every tile — its tabs included. It stands down as the board crosses into a tiling, at
/// the pace the tiles fly (`tiled`), and comes back as they leave.
enum CanvasSoftEdge {
    /// From the top of the pane to where a workspace's tiles begin — the header's own band.
    static var band: CGFloat { CGFloat(CanvasBoardView.headerClearance + CanvasTiling.edgeGap) }

    /// How far the fade runs, from nothing showing to all of a card: twice the band's first fade, which
    /// ran over three quarters of it.
    static var breadth: Double { Double(band) * 0.75 * 2 }

    /// Where the fade starts. Clear above — the strip the pill and the capsules sit in — by a quarter of
    /// the band, and a further tenth of the fade's breadth.
    static var start: Double { Double(band) * 0.25 + breadth * 0.1 }

    /// From the top of the pane to where the cards are fully there.
    static var height: CGFloat { CGFloat(start + breadth) }

    /// How much of a card shows `y` points down from the top of the pane, 0…1: nothing above `start`,
    /// then a smootherstep to full, so neither end of the fade has an edge to see. `tiled` lifts it
    /// toward fully shown, since a tiling has no edge.
    static func opacity(at y: Double, tiled: Double = 0) -> Double {
        let t = min(max((y - start) / breadth, 0), 1)
        let faded = t * t * t * (t * (t * 6 - 15) + 10)
        return faded + (1 - faded) * min(max(tiled, 0), 1)
    }

    /// A mask for a layer `bounds` tall: clear at the top, opaque from `height` down.
    ///
    /// `flipped` is whether the layer's own y runs downward — a gradient's points are in the layer's
    /// unit space, whichever way that faces.
    static func mask(for bounds: CGRect, flipped: Bool, tiled: Double) -> CAGradientLayer {
        let mask = CAGradientLayer()
        update(mask, for: bounds, flipped: flipped, tiled: tiled)
        return mask
    }

    static func update(_ mask: CAGradientLayer, for bounds: CGRect, flipped: Bool, tiled: Double) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.frame = bounds
        let stops = (0...16).map { Double($0) / 16 }
        mask.colors = stops.map { NSColor.black.withAlphaComponent(opacity(at: $0 * Double(height), tiled: tiled)).cgColor }
            + [NSColor.black.cgColor]
        let reach = bounds.height > 0 ? Double(height / bounds.height) : 1
        mask.locations = (stops.map { $0 * reach } + [1]).map { NSNumber(value: $0) }
        mask.startPoint = CGPoint(x: 0.5, y: flipped ? 0 : 1)
        mask.endPoint = CGPoint(x: 0.5, y: flipped ? 1 : 0)
        CATransaction.commit()
    }
}
