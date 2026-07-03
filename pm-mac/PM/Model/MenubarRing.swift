import AppKit

/// A drawn circular progress ring (finer-grained than Raycast's 5-step CircleProgress), used both by
/// the menubar glyph and by the panel's project switcher so a project's completion reads the same in
/// either place. `tint == nil` yields a template image the menubar recolors for its glyph; a non-nil
/// tint (the stale yellow/red) draws in that color and opts out of template recoloring.
enum MenubarRing {
    static func image(fraction: Double, hasProject: Bool, tint: NSColor?) -> NSImage {
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
