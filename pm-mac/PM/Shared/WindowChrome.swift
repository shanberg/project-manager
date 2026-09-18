import AppKit
import SwiftUI

/// Whether a floating header belongs to the window you are working in. docs/header-chrome.md §3.
///
/// **Two states, and there were three.** A third, *engaged*, lit the glass while the pointer was over a
/// capsule — which meant something while the backing was a material with a strength to turn up, and
/// nothing once it became glass, which has one strength. The pointer's one response is now the
/// highlight behind the control under it (`HeaderHoverHighlight`), which is the response a Mac toolbar
/// gives.
///
/// Shared by every header in the app, so the pieces of one strip cannot disagree about which window
/// they are in.
enum HeaderChrome: Equatable {
    /// Another window has the focus. The content recedes; the glass is whatever the system draws for a
    /// window that is not key.
    case dormant
    /// This window is the one you are working in.
    case active

    init(active: ControlActiveState) {
        self = active == .inactive ? .dormant : .active
    }

    /// How strongly the content renders. Dimmed in a background window, slightly — "subdued and seem
    /// visually farther away", in the HIG's words, and receding is a job for less contrast rather than
    /// for none.
    var contentOpacity: Double { self == .dormant ? 0.85 : 1 }
}

extension View {
    /// Puts a group of header controls on Liquid Glass. One modifier for every piece in every header, so
    /// they can't drift apart.
    ///
    /// **The same glass in every state** (docs/header-chrome.md R5). It used to go off over a tiled
    /// workspace, which made one set of controls two different materials depending on what happened to
    /// be under them — and read as two different sets of controls. What glass was being asked to do
    /// there, keep the header distinct from a board scrolling under it, is the board's own edge's job
    /// now (`CanvasSoftEdge`). Glass says one thing: *these belong together, and you can press
    /// them*. So it is on controls and never on a title.
    ///
    /// The one time it is not `.regular` is while a capsule is arriving or leaving — see
    /// `HeaderPresence`, which is the only writer of `headerMaterialized`.
    ///
    /// **Not `.interactive()`**, which was tried as the system's hover (docs/header-chrome.md P2) and
    /// shows nothing when the pointer is over it: on the Mac it answers presses, not hovering. The
    /// pointer's answer is `HeaderHoverHighlight`.
    /// `id` names this piece of glass inside its `GlassEffectContainer` — see `HeaderBacking`. Omit it
    /// for a capsule that stands on its own, where there is nothing to be told apart from.
    func headerBacking(in shape: some Shape, id: AnyHashable? = nil) -> some View {
        modifier(HeaderBacking(shape: shape, id: id))
    }
}

private struct HeaderBacking<S: Shape>: ViewModifier {
    let shape: S
    let id: AnyHashable?
    @Environment(\.headerMaterialized) private var materialized
    @Environment(\.headerGlassNamespace) private var namespace

    func body(content: Content) -> some View {
        // `.identity` rather than a condition around the modifier: the same view either way, so nothing
        // inside is rebuilt, and the glass itself animates in or out under whatever transaction changed
        // it — which `HeaderPresence` sees to is one with no layout in it.
        let glass = content.glassEffect(materialized ? .regular : .identity, in: shape)
        // **And the shape says which shape it is, which is what stops it flashing.**
        //
        // A `GlassEffectContainer` renders its shapes together, and without an identity it has no way
        // to know that the capsule it is being handed now is the one it drew last time: a capsule whose
        // contents change — stepping from a web tile to a project tile takes a whole run of controls
        // out of it — arrives as a *different* shape at a different size, and the material is built
        // again from nothing rather than carried across. That rebuild is the flash.
        //
        // `glassEffectID` is the framework's answer and the one Apple's own guidance points at
        // (docs/header-chrome.md §2, "Applying Liquid Glass to custom views"). It changes no geometry
        // and schedules no animation, so it costs the rule in `CanvasHeaderTrailingChrome` nothing —
        // the row still takes its new width in one frame. It only means: same glass, new size.
        if let id, let namespace {
            glass.glassEffectID(id, in: namespace)
        } else {
            glass
        }
    }
}

extension EnvironmentValues {
    /// Whether the glass under this piece of chrome is all the way in. False only for the moment a
    /// `HeaderPresence` is bringing a capsule in or taking one out.
    @Entry var headerMaterialized = true
    /// The `GlassEffectContainer` the capsules in this header are tracked in, set by whoever owns that
    /// container. Nil where a capsule stands alone and has nothing to be told apart from.
    @Entry var headerGlassNamespace: Namespace.ID?
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

    /// Full screen has no buttons at rest, so nothing to clear on the leading edge — but the header keeps
    /// the drop a window gives it, which is where the unified titlebar centres its buttons. So going full
    /// screen doesn't move the header up, and the board's top edge has the margin it had in a window.
    /// When the system's bar comes down over it, `fullScreenTitlebarReach` says by how far to move.
    static let fullScreen = TitlebarButtonMetrics(leadingInset: 0, buttonCenterY: 26)
}

extension NSWindow {
    /// The window's own button geometry, or nil when it can't be read yet.
    ///
    /// Full screen has no titlebar over the content and no traffic lights sitting in it, so a header
    /// there wants no leading inset — asking the buttons where they are would answer for the auto-hiding
    /// bar, which is not where the content is. See `TitlebarButtonMetrics.fullScreen`.
    ///
    /// Measured in the content view's own space, not the window's. A header is laid out from the top of
    /// the content view, and that is not reliably the top of the window frame — a tab bar moves one and
    /// not the other, and a window-frame-relative drop puts the header the height of the tab bar out of
    /// true. AppKit's coordinates are bottom-left and the views' are top-down, hence the flip through
    /// the content view's height.
    func titlebarButtonMetrics() -> TitlebarButtonMetrics? {
        guard let content = contentView else { return nil }
        guard !styleMask.contains(.fullScreen) else { return .fullScreen }
        guard let close = standardWindowButton(.closeButton),
              let zoom = standardWindowButton(.zoomButton) else { return nil }
        let box = content.convert(close.bounds, from: close)
        return TitlebarButtonMetrics(leadingInset: content.convert(zoom.bounds, from: zoom).maxX + 12,
                                     buttonCenterY: content.bounds.height - box.midY)
    }
}

extension NSWindow {
    /// The bar the system slides down over a full-screen window when the pointer reaches the top of the
    /// screen: the window it lives in, and the view that carries the traffic lights and the toolbar.
    ///
    /// **It is not this window.** In full screen AppKit moves the titlebar into a window of its own
    /// (`NSToolbarFullScreenWindow`), reached through the close button. Measured 2026-09-16 on a real
    /// reveal: that window is transparent at rest and its titlebar container sits out of its bounds; on
    /// the reveal it turns opaque and the container slides in, while the window itself springs a few
    /// points — every frame of it posting the window's move notification, both ways. Nil outside full
    /// screen, or while the bar is still this window's own.
    var fullScreenTitlebar: (window: NSWindow, strip: NSView)? {
        guard styleMask.contains(.fullScreen), let close = standardWindowButton(.closeButton),
              let bar = close.window, bar !== self else { return nil }
        let ancestors = sequence(first: close as NSView, next: \.superview)
        let strip = ancestors.first { String(describing: type(of: $0)).contains("TitlebarContainer") }
            ?? close.superview ?? close
        return (bar, strip)
    }

    /// Let the board show through the full-screen bar, as it does through a window's own titlebar.
    ///
    /// `titlebarAppearsTransparent` is not carried over to the bar's window: it paints itself in the
    /// window background colour, which is the canvas's ground but not a workspace's darker one, so over a
    /// tiling the bar read as a strip of a different grey. Its background is a private view found by
    /// name, hidden again on every move because the system may show it again on the next reveal; if a
    /// later macOS renames it, this finds nothing and the bar is merely painted.
    func clearFullScreenTitlebarBackground() {
        guard let (_, strip) = fullScreenTitlebar else { return }
        for view in strip.subviews
        where String(describing: type(of: view)).contains("TitlebarBackground") && !view.isHidden {
            view.isHidden = true
        }
    }

    /// How far down into this window's content the full-screen bar reaches right now: zero while it is
    /// hidden, its height once it is down, and every value between while it slides.
    ///
    /// Read off where the bar's strip actually is on screen, clipped to the window it is drawn in,
    /// against the top of the content — so a display with a notch (the menu bar above the content) and
    /// one without (the menu bar over it, pushing the bar further down) both come out as what is covered.
    func fullScreenTitlebarReach() -> CGFloat {
        guard let (bar, strip) = fullScreenTitlebar, bar.isVisible, bar.alphaValue > 0.01,
              let content = contentView else { return 0 }
        let shown = bar.convertToScreen(strip.convert(strip.bounds, to: nil)).intersection(bar.frame)
        guard !shown.isNull, shown.height > 0.5 else { return 0 }
        let top = convertToScreen(content.convert(content.bounds, to: nil)).maxY
        return max(0, top - shown.minY)
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
    ///
    /// **Equal in x and y, on purpose.** Every item's own highlight or hover capsule is a true
    /// `Capsule()` sized to its frame, so its radius is exactly `itemHeight / 2`; the outer glass
    /// capsule's radius is that plus this inset. Two stadiums only share a center — read as one
    /// shape nested in another, corners included — when the margin between them is the same on
    /// every side. A tab sitting at either end of the row makes this visible: unequal insets show a
    /// tighter gap top-and-bottom than left-and-right against the outer capsule.
    static let capsuleInset = (horizontal: 4.0, vertical: 4.0)
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
    /// Which piece of glass this is, for the container it lives in — see `headerBacking`. A capsule
    /// whose contents change shape needs one; a capsule that stands alone doesn't.
    var glass: AnyHashable?
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: HeaderMetrics.gap) { content }
            .opacity(chrome.contentOpacity)
            .padding(.horizontal, HeaderMetrics.capsuleInset.horizontal)
            .padding(.vertical, HeaderMetrics.capsuleInset.vertical)
            .headerBacking(in: Capsule(), id: glass)
            // A click on a control is a click on that control, not the start of a window drag.
            //
            // **Both sides, and the overlay is the one that does the work.** AppKit settles a press in
            // the titlebar band by building a region out of the view tree in z-order: a view answering
            // `mouseDownCanMoveWindow` with no carves its frame out, and any view *in front of it*
            // answering yes puts that frame back. For a capsule of text and symbols the background was
            // enough, because nothing else in one is a real AppKit view. Several things are: a `Menu`
            // arrives with `_NSGraphicsView`s and a `_FocusRingView`, a `ScrollView` with a clip and a
            // document view, and every one of them says yes — so the board's options menu, sitting in
            // the top-right corner, started a window move instead of opening (canvas-backlog.md 22,
            // reproduced in `WindowDragBandTests`).
            //
            // The overlay is last in the capsule and so in front of all of them. It takes no hit
            // testing, which makes it invisible to everything except this one question — the controls
            // underneath still get every click. The background stays because it is what marks where the
            // capsule *is* for `HeaderChromeMotionTests`, which reads capsules by their excluders.
            .background(WindowDragExcluder())
            .overlay { WindowDragExcluder().allowsHitTesting(false) }
            // A window going to the background is a change people expect to see happen smoothly (HIG,
            // Designing for macOS). Opacity only, so it may animate — see `HeaderPresence` for why
            // nothing else here does.
            .animation(Motion.animation(.easeOut(duration: 0.18)), value: chrome)
    }
}

/// A capsule that comes and goes — the page's, the tile's, the tab bar at one tab ↔ two. It
/// **materializes**: the row takes its new width in one frame, and then the capsule's glass and its
/// contents come in where it already stands. Going, the reverse — it fades out in place, and only then
/// does the row close up.
///
/// **Why by hand, and not `.transition` or `.glassEffectTransition(.materialize)`.** Both run under the
/// transaction that inserts the view, and an animated insertion animates the row's layout as well:
/// Auto Layout gives the hosting view its new width in one step while SwiftUI slides the capsules to
/// theirs over the duration, so for a fifth of a second everything in the row is somewhere neither of
/// them meant — 174pt out, measured (`HeaderChromeMotionTests`). So the two halves go on two
/// transactions. Insert with none, and the layout snaps; *then* animate the one thing that changes no
/// geometry — the glass from `.identity` to `.regular`, and the contents' opacity. Which is also what
/// Apple's `materialize` is described as doing: fading the content and animating the material in,
/// without matching geometry.
///
/// **State in the parent, tracking on the row.** The parent holds a `HeaderPresence` and draws
/// `if let shown = presence.shown { … .headerMaterialized(presence.materialized) }`; the row that
/// always exists carries `.headerPresence(of:in:)`. Not a wrapper view, which is the obvious shape and
/// does not work: a wrapper that is showing nothing *is* nothing, and SwiftUI attaches modifiers to the
/// views a body produces — so its `onChange` would never hear the value come back.
struct HeaderPresence<Value: Equatable> {
    /// What is on screen, which outlives the value for as long as it takes to fade out.
    fileprivate(set) var shown: Value?
    fileprivate(set) var materialized = false
    /// Bumped by every arrival and departure, so a departure's completion that lands after the value
    /// has come back doesn't take away the capsule that has just returned.
    fileprivate var generation = 0

    init() {}

    static var animation: Animation? { Motion.animation(.easeOut(duration: 0.2)) }
}

extension View {
    /// Keep `presence` following `value` — see `HeaderPresence`. Put it on a view that is always there.
    func headerPresence<Value: Equatable>(of value: Value?,
                                          in presence: Binding<HeaderPresence<Value>>) -> some View {
        modifier(HeaderPresenceTracker(value: value, presence: presence))
    }

    /// Draw a capsule as far in as its presence says: its contents faded, its glass thinned toward
    /// `.identity`, and no clicks until it is all the way there.
    func headerMaterialized(_ materialized: Bool) -> some View {
        opacity(materialized ? 1 : 0)
            .environment(\.headerMaterialized, materialized)
            .allowsHitTesting(materialized)
    }
}

private struct HeaderPresenceTracker<Value: Equatable>: ViewModifier {
    let value: Value?
    @Binding var presence: HeaderPresence<Value>

    func body(content: Content) -> some View {
        content
            // Present when the header is built — a window opening — is present, not arriving.
            .onAppear {
                presence.shown = value
                presence.materialized = value != nil
            }
            .onChange(of: value) { _, new in change(to: new) }
    }

    private func change(to new: Value?) {
        presence.generation &+= 1
        let arrival = presence.generation
        let binding = $presence
        guard let new else {
            guard presence.shown != nil else { return }
            withAnimation(HeaderPresence<Value>.animation) {
                binding.wrappedValue.materialized = false
            } completion: {
                guard binding.wrappedValue.generation == arrival else { return }
                var still = Transaction()
                still.disablesAnimations = true
                withTransaction(still) { binding.wrappedValue.shown = nil }
            }
            return
        }
        let arriving = presence.shown == nil || !presence.materialized
        presence.shown = new
        guard arriving else { return }
        // A turn later: the insertion has to have been laid out, in a transaction of its own, before
        // anything animates — otherwise the two share one and the row slides. Not `afterCurrentUpdate`,
        // whose job is AppKit re-entrancy; this is a SwiftUI transaction boundary, and it has to stay
        // compilable in the test bundle that measures it.
        DispatchQueue.main.async {
            guard binding.wrappedValue.generation == arrival else { return }
            withAnimation(HeaderPresence<Value>.animation) { binding.wrappedValue.materialized = true }
        }
    }
}


/// A soft capsule behind a header control while the pointer is over it.
///
/// **The pointer's one response in a header** (docs/header-chrome.md L4). The glass says a group is
/// controls; this says which one of them the click will land on — the way a toolbar button on this Mac
/// does. The system has no hover of its own to offer custom glass (P2), and there is no capsule-wide
/// hover state any more (`HeaderChrome`).
///
/// The same capsule, at a lighter weight, as the current tab's backing (`ProjectTabBar`), so the two
/// read as one family: the tab is where you are, the hover is where you are about to be.
struct HeaderHoverHighlight: ViewModifier {
    var enabled = true
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .modifier(HeaderHoverCapsule(visible: hovering && enabled))
            .onHover { hovering = $0 }
    }
}

/// The hover capsule itself, for a control that learns about the pointer some other way — see
/// `HeaderMenuButton`, whose AppKit half is what the pointer is over.
struct HeaderHoverCapsule: ViewModifier {
    var visible: Bool

    func body(content: Content) -> some View {
        content
            .background {
                Capsule()
                    .fill(.primary.opacity(0.07))
                    .opacity(visible ? 1 : 0)
            }
            .animation(Motion.animation(.easeOut(duration: 0.12)), value: visible)
    }
}

extension View {
    /// See `HeaderHoverHighlight`.
    func headerHoverHighlight(enabled: Bool = true) -> some View {
        modifier(HeaderHoverHighlight(enabled: enabled))
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
    /// The tooltip. **Empty for a control that should not have one** — a sentence that changes with
    /// the selection cannot be read before you act on it, since it only appears a second after you
    /// have stopped moving. Such a control still has a `label`.
    var help: String = ""
    /// What the control is called, for anyone who asks rather than hovers. Defaults to the tooltip,
    /// which for most of these is the same sentence said once.
    var label: String?
    var enabled = true
    let action: () -> Void

    var body: some View {
        button
            .disabled(!enabled)
            .accessibilityLabel(Text(label ?? help))
    }

    @ViewBuilder private var button: some View {
        if help.isEmpty { core } else { core.help(help) }
    }

    private var core: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: HeaderMetrics.iconSize, weight: .medium))
                // A glyph that stands for a state — Reload/Stop, maximize/restore — swaps in place, and
                // the swap is worth drawing: the button does not move, so the only thing saying the
                // click landed is the mark changing. Free of the width rule for the same reason, since
                // the hit area is `hitWidth` whatever is in it.
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(enabled ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                .frame(width: HeaderMetrics.hitWidth, height: HeaderMetrics.itemHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .headerHoverHighlight(enabled: enabled)
    }
}

/// A header glyph that opens an AppKit menu, on mouse-down and just below itself, as a pull-down does.
///
/// **For a menu something else already builds.** A SwiftUI `Menu` has to spell out its items in
/// SwiftUI, which is how the focus capsule's `…` came to be a second, hand-kept copy of a card's
/// contextual menu — one that every new kind of card had to remember to extend, and the folder card
/// didn't. This takes an `NSMenu` built wherever the commands live, so the two menus are one.
///
/// The click lands on an `NSControl`, not on SwiftUI: a control is what carves a press out of the
/// titlebar's window-drag band (see `WindowDragBlocker`), and it hands `open` a view to position the
/// menu against. The glyph and its hover capsule are drawn in SwiftUI like every other header item.
struct HeaderMenuButton: View {
    let symbol: String
    /// The tooltip, and what the control is called.
    let help: String
    /// Changed to open the menu without a click — from a key, say — against this same button. The
    /// value the button first appears with opens nothing.
    var openToken = 0
    /// Show the menu against this view — `NSMenu.popUpBelow(_:)` does the positioning.
    let open: (NSView) -> Void
    @State private var hovering = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: HeaderMetrics.iconSize, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: HeaderMetrics.hitWidth, height: HeaderMetrics.itemHeight)
            .accessibilityHidden(true)
            .overlay(MenuPressArea(help: help, openToken: openToken, open: open, hovering: $hovering))
            .modifier(HeaderHoverCapsule(visible: hovering))
    }
}

private struct MenuPressArea: NSViewRepresentable {
    let help: String
    let openToken: Int
    let open: (NSView) -> Void
    @Binding var hovering: Bool

    func makeNSView(context: Context) -> Control {
        let control = Control()
        control.openToken = openToken
        return control
    }

    func updateNSView(_ view: Control, context: Context) {
        view.open = open
        view.hovered = { hovering = $0 }
        view.toolTip = help
        view.setAccessibilityLabel(help)
        if view.openToken != openToken {
            view.openToken = openToken
            // After the update, not inside it: a menu runs its own tracking loop, and SwiftUI would be
            // left mid-transaction for as long as the menu is open.
            DispatchQueue.main.async { [weak view] in
                guard let view, view.window != nil else { return }
                view.open(view)
            }
        }
    }

    final class Control: NSControl {
        var open: (NSView) -> Void = { _ in }
        var hovered: (Bool) -> Void = { _ in }
        var openToken = 0

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {
            hovered(false)
            open(self)
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: .zero,
                                           options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                           owner: self))
        }
        override func mouseEntered(with event: NSEvent) { hovered(true) }
        override func mouseExited(with event: NSEvent) { hovered(false) }

        override func isAccessibilityElement() -> Bool { true }
        override func accessibilityRole() -> NSAccessibility.Role? { .menuButton }
        override func accessibilityPerformPress() -> Bool { open(self); return true }
    }
}

extension NSMenu {
    /// Pop up as a pull-down from `view`: its leading edge, a few points under it.
    func popUpBelow(_ view: NSView) {
        let y = view.isFlipped ? view.bounds.maxY + 4 : view.bounds.minY - 4
        popUp(positioning: nil, at: NSPoint(x: view.bounds.minX, y: y), in: view)
    }
}
