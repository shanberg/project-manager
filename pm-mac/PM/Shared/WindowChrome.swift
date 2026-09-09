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
/// Shared by the task list's header and the board's, which is the whole point — the canvas was asked to
/// follow the pattern of the main window, and following it means using the same components rather than a
/// second set that looks like them and drifts.
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

// MARK: - The metrics both headers are laid out on

/// The one set of numbers a floating header's contents are built from.
///
/// Both headers grew the same way: each element arrived with padding chosen for itself, which is fine
/// at three items and falls apart at ten. Counted at the point this was written, one row held six
/// different item heights — 18pt symbol buttons, 19pt renderer segments, menus with no height set at
/// all, bare caption text, a bordered `.small` button and a 21pt search field — plus three hit widths,
/// two different dividers with different insets and colours, and a readout with padding on one side.
/// Nothing there is a wrong value. There was no layout system, so there was nothing for a value to be
/// wrong against.
///
/// A header item is a box of `itemHeight`. That is the whole rule, and it is what stops the row
/// wobbling: text, buttons, menus, a search field and a segmented switch are wildly different things
/// vertically, and the only way they read as one row is if something insists they are the same height.
enum HeaderMetrics {
    /// Every item is this tall. Chosen off the tallest thing that has to appear in a header — a small
    /// `NSSearchField` — because forcing a control below its natural height clips it, while giving a
    /// glyph more room than it needs only makes it easier to hit.
    static let itemHeight: CGFloat = 21
    /// A glyph button's hit area. Wider than the glyph, so a control can be clicked without aiming.
    static let hitWidth: CGFloat = 24
    static let iconSize: CGFloat = 12
    /// Between items that belong together.
    static let gap: CGFloat = 2
    /// Between two groups inside one capsule — a run of buttons and the words they drive. A
    /// divider says "different scope"; this says "same scope, different job", and the page capsule needs
    /// the quieter of the two: back/forward/reload and the address are one control between them.
    static let groupGap: CGFloat = 10
    /// Between two capsules in the same header. Wider than anything inside one, because the gap is the
    /// only thing saying they are two.
    static let capsuleGap: CGFloat = 10
    /// Inside a run of text, so words don't sit against the item beside them.
    static let textInset: CGFloat = 6
    /// The capsule's own inset around its row.
    static let capsuleInset = (horizontal: 6.0, vertical: 4.0)
    /// The pill's, which is looser because it holds a name rather than controls.
    static let pillInset = (horizontal: 14.0, vertical: 7.0)
}

extension View {
    /// Make this a header item: one height, whatever it is inside.
    func headerItem() -> some View {
        frame(height: HeaderMetrics.itemHeight)
    }

    /// A run of words in a header — a readout, not a control.
    func headerCaption() -> some View {
        font(.caption)
            .monospacedDigit()
            .padding(.horizontal, HeaderMetrics.textInset)
            .headerItem()
    }
}

/// The trailing capsule both headers wear: one row, one spacing, one inset, one piece of glass.
///
/// A container rather than a convention, because a convention is what the two headers already had and
/// they drifted apart twice in a day — the two divider implementations, written an hour apart in two
/// files, are the receipt. Supplying items to a shared container is the only version of this that
/// cannot drift.
struct HeaderCapsule<Content: View>: View {
    let chrome: HeaderChrome
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: HeaderMetrics.gap) { content }
            .opacity(chrome.contentOpacity)
            .padding(.horizontal, HeaderMetrics.capsuleInset.horizontal)
            .padding(.vertical, HeaderMetrics.capsuleInset.vertical)
            .headerBacking(chrome, in: Capsule())
            // A click on a control is a click on that control, not the start of a window drag.
            .background(WindowDragExcluder())
    }
}

/// The air between two groups of items inside one capsule.
///
/// A spacer rather than a divider, and sized so the total gap is `groupGap` rather than `groupGap` plus
/// the row's own spacing on each side — otherwise the one number here is not the number on screen.
struct HeaderGap: View {
    var body: some View {
        Color.clear
            .frame(width: max(0, HeaderMetrics.groupGap - HeaderMetrics.gap * 2), height: 1)
    }
}

/// The line between two groups of header items.
struct HeaderDivider: View {
    var body: some View {
        Rectangle()
            .fill(.quaternary)
            .frame(width: 1, height: 14)
            .padding(.horizontal, 4)
    }
}

/// One control in a header: a symbol at the size and weight every other one uses, in a hit area big
/// enough to click without aiming.
///
/// Shared by both headers so they cannot drift, which they had — the task list's buttons and the
/// board's were the same code written twice, and were already a point apart.
struct HeaderSymbolButton: View {
    let symbol: String
    let help: String
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: HeaderMetrics.iconSize, weight: .medium))
                .foregroundStyle(enabled ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                .frame(width: HeaderMetrics.hitWidth, height: HeaderMetrics.itemHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
        .accessibilityLabel(Text(help))
    }
}
