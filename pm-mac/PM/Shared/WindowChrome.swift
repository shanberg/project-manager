import AppKit
import SwiftUI

/// What a floating header's glass is doing right now: absent in a background window, present once the
/// window is active, and lit while the pointer is in it. Two inputs, three states — hover wins over the
/// window's state, so reaching for a control in a window you haven't clicked into yet still shows you
/// what you're reaching for.
///
/// One type rather than a pair of booleans read at each call site, because the pieces in a strip have
/// to agree: two pieces of glass in the same header disagreeing about whether they exist is worse than
/// either choice made consistently.
///
/// Shared by the project window's header and the canvas window's, which is the whole point — the canvas
/// was asked to follow the pattern of the main window, and following it means using the same components
/// rather than a second set that looks like them and drifts.
enum HeaderChrome: Equatable {
    /// Another window has the focus. No glass at all, and the content behind it recedes.
    case dormant
    /// This window is active, the pointer is elsewhere. Backed, at rest.
    case resting
    /// The pointer is in the header strip. Backed at full strength.
    case engaged

    init(active: ControlActiveState, hovering: Bool) {
        if hovering {
            self = .engaged
        } else if active == .inactive {
            self = .dormant
        } else {
            self = .resting
        }
    }

    /// How strongly the backing renders, 0–1.
    ///
    /// Nothing here goes to zero. An earlier pass had the dormant state drop its backing entirely, on
    /// the theory that a background window's chrome should get out of the way — but there's no bar
    /// behind these headers, so "nothing" meant the content scrolled up into the title and made it
    /// unreadable. Receding is a job for less contrast, not for none, and the floor is set by what
    /// stays legible rather than by how quiet it would be nice to be.
    var backingStrength: Double {
        switch self {
        case .dormant: return 0.7
        case .resting: return 0.85
        case .engaged: return 1
        }
    }

    /// How strongly the *content* renders. Dimmed in a background window, but only slightly: this is
    /// the same legibility problem from the other side, and text at half strength over a half-strength
    /// backing is no easier to read than text over nothing.
    var contentOpacity: Double { self == .dormant ? 0.85 : 1 }
}

extension View {
    /// Backs a piece of header chrome at the strength its state calls for. One modifier for every piece
    /// in both windows, so they can't drift apart.
    ///
    /// A plain material, not Liquid Glass, after trying both. `glassEffect` has no intensity control —
    /// its two variants are `.regular` and `.clear`, and `.clear` is the *media* variant, brighter and
    /// more present over a plain window rather than quieter. The only way to turn glass down is to fade
    /// the layer, which means putting it in a background so the title above keeps its own opacity — and
    /// glass in a background inside a `GlassEffectContainer` renders over its sibling content, which hid
    /// the very titles it was supposed to be backing.
    ///
    /// A material has the dial built in and composites the ordinary way, which is the whole requirement
    /// here: this chrome exists to hold a title legible over content that scrolls or pans beneath it, at
    /// a weight that changes with the window's state. Liquid Glass is still in the app where it earns
    /// its keep — the focus panel, a floating HUD over other apps' windows (see `GlassBackground`).
    func headerBacking(_ chrome: HeaderChrome, in shape: some Shape) -> some View {
        background {
            shape.fill(.regularMaterial).opacity(chrome.backingStrength)
        }
    }
}

/// Where a window's traffic lights are, for a header that runs up into the titlebar to sit level with
/// them.
///
/// Measured from the real buttons rather than hard-coded: Apple has moved these between releases, and a
/// stale constant shows up as a title either colliding with the zoom button or floating oddly far from
/// the edge. The unified titlebar both of this app's window kinds use sits them about twice as far down
/// as a compact one would, which is exactly the difference a constant would get wrong.
struct TitlebarButtonMetrics: Equatable {
    /// How far in from the leading edge the buttons reach, plus a margin.
    var leadingInset: CGFloat
    /// How far down from the top of the content view they are centred.
    var buttonCenterY: CGFloat

    /// Sensible values for the moment before a window has been laid out — 92pt of traffic lights and a
    /// compact titlebar's 13pt drop. Replaced by real ones as soon as there is a window to ask.
    static let unmeasured = TitlebarButtonMetrics(leadingInset: 92, buttonCenterY: 13)
}

extension NSWindow {
    /// The window's own button geometry, or nil when it can't be read yet.
    ///
    /// Full screen has no titlebar over the content and no traffic lights sitting in it, so a header
    /// there wants neither the leading inset nor the vertical drop — asking the buttons where they are
    /// would answer for the auto-hiding bar, which is not where the content is.
    ///
    /// Measured in the content view's own space, not the window's. A header is laid out from the top of
    /// the content view, and that is not reliably the top of the window frame — a tab bar moves one and
    /// not the other, and a window-frame-relative drop puts the header the height of the tab bar out of
    /// true. AppKit's coordinates are bottom-left and the views' are top-down, hence the flip through
    /// the content view's height.
    func titlebarButtonMetrics() -> TitlebarButtonMetrics? {
        guard let content = contentView else { return nil }
        guard !styleMask.contains(.fullScreen) else {
            return TitlebarButtonMetrics(leadingInset: 0, buttonCenterY: 0)
        }
        guard let close = standardWindowButton(.closeButton),
              let zoom = standardWindowButton(.zoomButton) else { return nil }
        let box = content.convert(close.bounds, from: close)
        return TitlebarButtonMetrics(leadingInset: content.convert(zoom.bounds, from: zoom).maxX + 12,
                                     buttonCenterY: content.bounds.height - box.midY)
    }
}
