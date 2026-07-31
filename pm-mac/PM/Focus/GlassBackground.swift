import AppKit
import SwiftUI

/// The focus panel's translucent background: Liquid Glass (`NSGlassEffectView`) on macOS 26+, falling
/// back to `NSVisualEffectView` vibrancy below. Used as a SwiftUI `.background` so it fills the
/// content's layout and resizes with the auto-fit rather than fighting it.
///
/// The focus panel's alone, deliberately. A floating HUD over other apps' windows is what this material
/// is for; project windows take the standard opaque window background, with the sidebar's own vibrancy
/// (supplied by the split view's sidebar item) providing the one contrast a source list needs.
///
/// The panel is borderless, so this view is its shape: it rounds its own corners, since nothing else
/// would, and the window's shadow is derived from it.
struct GlassBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = ProjectWindow.cornerRadius
            return glass
        }
        let effect = MaskedVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        return effect
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Pre-26 fallback background. `.behindWindow` vibrancy isn't clipped by a layer corner radius, so the
/// rounding has to go through `maskImage` — a nine-part rounded rect whose caps let AppKit stretch it to
/// whatever height the auto-fit lands on.
private final class MaskedVisualEffectView: NSVisualEffectView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard maskImage == nil else { return }
        let r = ProjectWindow.cornerRadius
        let side = r * 2 + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
        image.resizingMode = .stretch
        maskImage = image
    }
}
