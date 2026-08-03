import AppKit
import SwiftUI

/// The focus panel's translucent background: Liquid Glass (`NSGlassEffectView`). Used as a SwiftUI
/// `.background` so it fills the content's layout and resizes with the auto-fit rather than fighting it.
///
/// The focus panel's alone, deliberately. A floating HUD over other apps' windows is what this material
/// is for; project windows take the standard opaque window background, with the sidebar's own vibrancy
/// (supplied by the split view's sidebar item) providing the one contrast a source list needs.
///
/// The panel is borderless, so this view is its shape: it rounds its own corners, since nothing else
/// would, and the window's shadow is derived from it.
struct GlassBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let glass = NSGlassEffectView()
        glass.style = .regular
        glass.cornerRadius = ProjectWindow.cornerRadius
        return glass
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
