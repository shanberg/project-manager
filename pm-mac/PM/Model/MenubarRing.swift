import AppKit

/// A drawn circular progress ring (finer-grained than Raycast's 5-step CircleProgress), used both by
/// the menubar glyph and by the panel's project switcher so a project's completion reads the same in
/// either place. `tint == nil` yields a template image the menubar recolors for its glyph; a non-nil
/// tint (the stale yellow/red) draws in that color and opts out of template recoloring.
enum MenubarRing {
    /// Drawn rings, keyed by what they depict. Without this every caller gets a freshly-allocated
    /// `NSImage`: SwiftUI compares images by identity, so a row that draws its ring inside `body`
    /// hands back a "new" image on every pass and redraws for no reason — visible as flicker in a
    /// list of them. The key quantizes the fill to whole percent, which is finer than 15pt of arc can
    /// show, so the cache stays small (a few hundred entries at worst) and needs no eviction.
    private struct RingKey: Hashable {
        let percent: Int
        let hasProject: Bool
        let tint: String?
    }
    private static var cache: [RingKey: NSImage] = [:]

    static func image(fraction: Double, hasProject: Bool, tint: NSColor?) -> NSImage {
        let key = RingKey(percent: Int((min(max(fraction, 0), 1) * 100).rounded()),
                          hasProject: hasProject,
                          tint: tint?.description)
        if let cached = cache[key] { return cached }
        let drawn = draw(fraction: fraction, hasProject: hasProject, tint: tint)
        cache[key] = drawn
        return drawn
    }

    private static func draw(fraction: Double, hasProject: Bool, tint: NSColor?) -> NSImage {
        let size = NSSize(width: 15, height: 15)
        let img = NSImage(size: size, flipped: false) { rect in
            let lineWidth: CGFloat = 1.6
            let inset = rect.insetBy(dx: lineWidth, dy: lineWidth)
            let color = tint ?? .black  // black draws as a template that the menubar recolors
            let center = NSPoint(x: inset.midX, y: inset.midY)
            let radius = min(inset.width, inset.height) / 2

            // Track ring.
            let track = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius,
                                                    width: radius * 2, height: radius * 2))
            track.lineWidth = lineWidth
            color.withAlphaComponent(0.35).setStroke()
            track.stroke()

            // Progress arc (clockwise from 12 o'clock).
            let clamped = min(max(fraction, 0), 1)
            if hasProject && clamped > 0 {
                let arc = NSBezierPath()
                arc.appendArc(withCenter: center, radius: radius,
                              startAngle: 90, endAngle: 90 - 360 * clamped, clockwise: true)
                arc.lineWidth = lineWidth
                color.setStroke()
                arc.stroke()
            }
            return true
        }
        img.isTemplate = (tint == nil)  // colored (stale) rings must not be template-recolored
        return img
    }
}
