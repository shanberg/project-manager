import AppKit
import SwiftUI
import QuartzCore
import CoreImage

/// SwiftUI-observable panel chrome state. Currently tracks whether a resize animation is in flight so
/// the content view can hide its scrollbar for the duration (avoiding a flash mid-animation).
///
/// Deliberately minimal: every property here is read by `PanelView`'s root, so a write republishes the
/// whole panel body. The window's height used to live here too, which meant each frame of a resize
/// drag rebuilt the entire tree — the content sizes itself off the window now instead (see
/// `hosting.sizingOptions` in `init`).
final class PanelChrome: ObservableObject {
    @Published var isResizing = false
}

/// Owns the floating PM Panel window (an `NSPanel` hosting `PanelView`). Reproduces the retired Tauri
/// panel's behavior: fixed 380 pt width with auto-fitting height, summon/dismiss, blur-to-hide with a
/// grace period (suppressed when pinned), and float-above-others when the float setting is on.
/// A borderless panel that can still take key focus. `NSWindow` refuses key status to borderless windows
/// by default, and the panel hosts text fields (task titles, the note editor) that need it.
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    private let store: PMStore
    private let panel: NSPanel
    private var settings: PanelSettings

    /// Fixed width of the panel's content column (tasks, header, details). Never changes.
    static let contentWidth: CGFloat = 420
    /// Width the optional project sidebar adds to the left of the content column. Sized for its
    /// two-line rows (project name over its next task) without crowding them.
    static let sidebarWidth: CGFloat = 224
    /// `UserDefaults` key behind `PanelView`'s sidebar toggle (an `@AppStorage`), read directly here
    /// because the window needs its width in `init` — before any SwiftUI layout has run.
    static let sidebarDefaultsKey = "PMPanelSidebar"
    static var isSidebarVisible: Bool { UserDefaults.standard.bool(forKey: sidebarDefaultsKey) }

    /// The panel's current width: the content column, plus the sidebar when it's showing. The height
    /// auto-fits; this changes only when the sidebar is toggled.
    static var width: CGFloat { contentWidth + (isSidebarVisible ? sidebarWidth : 0) }
    /// Window identifier so the panel's outside-click monitor can scope to this window.
    static let windowIdentifier = "PMPanel"
    /// Max height as a Tarot-card proportion of the width (~2.75×4.75). Content beyond this scrolls;
    /// below it, the panel fits exactly.
    static let maxHeightRatio: CGFloat = 4.75 / 2.75
    /// The panel's rounded-corner radius. Since the window is borderless, nothing rounds it for us: the
    /// glass background and the SwiftUI content each clip to this, and the window shadow follows from
    /// the shape they render.
    static let cornerRadius: CGFloat = 16

    /// SwiftUI-observable chrome shared with `PanelView` (hides the scrollbar during a resize).
    private let chrome: PanelChrome

    /// Grace period before a blurred (unpinned) panel hides — long enough to ride out transient focus
    /// blips (a popover, a quick app switch, the summon shortcut itself).
    private let blurHideDelay: TimeInterval = 0.2
    private var pendingHide: DispatchWorkItem?
    /// Set on summon so the first auto-fit after showing snaps instead of animating a grow-on-open.
    private var suppressNextFitAnimation = false

    /// Edge/corner snapping. A drop settles onto one of eight anchors (four corners + four edge
    /// centers), each held a deliberate gap in from the screen edges. `snapCheck` polls for the drag to
    /// end (button released), `dragControlHeld` records whether ⌃ was down during the drag (which
    /// disables snapping for free placement), and `isProgrammaticMove` marks our own auto-fit/snap
    /// frame changes so `windowDidMove` doesn't mistake them for a user drag and re-trigger snapping.
    private var dragTimer: Timer?
    private var dragControlHeld = false
    private var isProgrammaticMove = false

    /// Translucent preview of where a drop will land, shown live during a snappable drag.
    private lazy var ghost = SnapGhostWindow()

    /// How far the snapped panel sits from the screen edges — ~1 menu-bar height: a small breathing
    /// gap so it reads as a floating panel, not a docked strip.
    private var snapGap: CGFloat { NSStatusBar.system.thickness }

    /// Only snap (and only preview) when the panel's nearest anchor is within this distance of its
    /// current position; farther than this, a drop stays where it's dropped. Lets the middle of the
    /// screen be free-placement while the corners/edges are magnetic.
    static let snapThreshold: CGFloat = 150

    private let hosting: NSHostingController<PanelView>

    init(store: PMStore, settings: PanelSettings) {
        self.store = store
        self.settings = settings

        self.chrome = PanelChrome()
        hosting = NSHostingController(rootView: PanelView(store: store, chrome: PanelChrome()))
        // Borderless: a `.titled` window carries an `NSThemeFrame` that paints its own rounded backing
        // and hairline border, which showed through this transparent panel as an outline sitting behind
        // the shadow. With no frame view, the only thing drawn is our glass, and the window shadow is
        // derived from that shape alone.
        panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 420),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()

        // Restore the height the user last dragged the panel to (with the sidebar open).
        let saved = UserDefaults.standard.double(forKey: Self.userHeightKey)
        userHeight = saved > 0 ? saved : nil

        // Inject panel callbacks now that `self` exists: Escape-to-hide, content-driven auto-fit, and
        // the bottom grab handle's live height drag.
        hosting.rootView = PanelView(
            store: store,
            chrome: chrome,
            onDismiss: { [weak self] in self?.hide() },
            onContentHeight: { [weak self] height in self?.fit(toContentHeight: height) },
            onResizeBegan: { [weak self] in self?.resizeBegan() },
            onResizeChanged: { [weak self] delta in self?.resize(byHeightDelta: delta) },
            onResizeEnded: { [weak self] in self?.resizeEnded() }
        )

        // The glass/vibrant material is a SwiftUI background inside PanelView, so it fills the
        // content's layout rather than fighting it. The window is non-opaque so that material shows
        // through.
        panel.contentViewController = hosting
        // `fit(toContentHeight:)` is the *only* thing that sizes this window.
        //
        // The default (`.preferredContentSize`) has AppKit resize the window whenever the SwiftUI
        // content's ideal size changes — which, with the sidebar in the layout, closed a loop: the
        // sidebar column sized itself to the window's height, so the content's ideal height *was* the
        // window's height, feeding straight back into the window frame. Two authorities on the same
        // number, one reading its answer from the other. With sizing off, the hosting view simply
        // fills whatever frame `fit` sets, and the columns fill it in turn.
        hosting.sizingOptions = []

        panel.isOpaque = false
        panel.backgroundColor = .clear
        // The panel has no titlebar to drag by, so its background is the drag region. Everything the
        // user clicks *into* has to carve itself back out with `WindowDragExcluder` — a mouse-down on a
        // draggable region is swallowed by AppKit's drag-tracking loop and never reaches the view, which
        // reads as a click that didn't take.
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        // Tag the window so PanelView's outside-click monitor can tell our clicks from other windows'.
        panel.identifier = NSUserInterfaceItemIdentifier(Self.windowIdentifier)
        applySettings(settings)
        restorePosition()
    }

    // MARK: Show / hide

    var isVisible: Bool { panel.isVisible }

    func toggle() { isVisible ? hide() : show() }

    func show() {
        pendingHide?.cancel()
        suppressNextFitAnimation = true
        Self.wasOpen = true
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func hide() {
        pendingHide?.cancel()
        dragTimer?.invalidate()
        dragTimer = nil
        ghost.hide()
        Self.wasOpen = false
        panel.orderOut(nil)
    }

    // MARK: Open-state restore

    /// Whether the panel was open (user intent, not transient visibility) when the app last ran, so it
    /// can reopen on relaunch. Set by the explicit summon/dismiss paths (`show`/`hide`); the blur
    /// auto-hide deliberately leaves it set, since an unpinned panel that hid on blur is still "open".
    /// App-local (`UserDefaults`) rather than in the Raycast-shared settings file.
    static var wasOpen: Bool {
        get { UserDefaults.standard.bool(forKey: wasOpenKey) }
        set { UserDefaults.standard.set(newValue, forKey: wasOpenKey) }
    }
    private static let wasOpenKey = "PMPanelWasOpen"

    /// Reopen the panel on launch if it was open when the app was last quit.
    func restoreIfNeeded() {
        if Self.wasOpen { show() }
    }

    // MARK: Settings

    func applySettings(_ new: PanelSettings) {
        settings = new
        panel.level = new.floating ? .floating : .normal
    }

    // MARK: Window position persistence

    /// Persisted position, anchored to whichever corner is nearest a screen edge. Storing offsets
    /// from the near edges (rather than an absolute point) keeps the panel the same distance from
    /// that edge across resolution/display changes, and the vertical anchor also drives which edge
    /// the auto-fit grows from — see `verticalAnchorNearTop` / `fit(toContentHeight:)`.
    private struct SavedPosition: Codable {
        var fromRight: Bool     // horizontal anchor: nearer the right screen edge?
        var xOffset: CGFloat    // distance from that edge to the panel's near vertical side
        var fromTop: Bool       // vertical anchor: nearer the top screen edge?
        var yOffset: CGFloat    // distance from that edge to the panel's near horizontal side
    }
    private static let positionKey = "PMPanelAnchor"

    private var visibleFrame: NSRect? { (panel.screen ?? NSScreen.main)?.visibleFrame }

    /// Whether the panel's top edge is currently the nearer of the two horizontal screen edges. The
    /// auto-fit keeps this edge fixed so growth happens away from the nearby edge. Defaults to top.
    private var verticalAnchorNearTop: Bool {
        guard let vf = visibleFrame else { return true }
        return (vf.maxY - panel.frame.maxY) <= (panel.frame.minY - vf.minY)
    }

    /// The horizontal counterpart, matching `savePosition`'s `fromRight`. Toggling the sidebar changes
    /// the panel's width, and keeping the anchored vertical edge fixed means a right-anchored panel
    /// grows leftward (into the screen) rather than sliding off the right edge.
    private var horizontalAnchorNearRight: Bool {
        guard let vf = visibleFrame else { return false }
        return (vf.maxX - panel.frame.maxX) < (panel.frame.minX - vf.minX)
    }

    private func savePosition() {
        guard let vf = visibleFrame else { return }
        let f = panel.frame
        let fromRight = (vf.maxX - f.maxX) < (f.minX - vf.minX)
        let fromTop = verticalAnchorNearTop
        let pos = SavedPosition(
            fromRight: fromRight,
            xOffset: fromRight ? vf.maxX - f.maxX : f.minX - vf.minX,
            fromTop: fromTop,
            yOffset: fromTop ? vf.maxY - f.maxY : f.minY - vf.minY
        )
        if let data = try? JSONEncoder().encode(pos) {
            UserDefaults.standard.set(data, forKey: Self.positionKey)
        }
    }

    /// Restore the panel relative to its nearest-edge corner, or center on first run. A later auto-fit
    /// keeps the anchored vertical edge fixed, preserving the position.
    ///
    /// This runs in `init`, before the hosting controller has laid out the SwiftUI content, so at this
    /// point `panel.frame.size` is still `.zero`. We must therefore anchor off the panel's known fixed
    /// width (`Self.width`) rather than the not-yet-measured `frame.width`: a right-anchored panel sets
    /// its left edge here, and the auto-fit grows width from that left edge, so using a zero width would
    /// leave the panel one full width too far right. Height needs no such care — the top-anchored case
    /// cancels height out (top edge = origin.y + height), and the bottom-anchored case ignores it.
    private func restorePosition() {
        // Programmatic: restoring must not arm snapping, or a ⌃-placed (freely positioned) panel would
        // snap to an anchor on the next launch.
        isProgrammaticMove = true
        defer { isProgrammaticMove = false }
        guard let data = UserDefaults.standard.data(forKey: Self.positionKey),
              let pos = try? JSONDecoder().decode(SavedPosition.self, from: data),
              let vf = visibleFrame else {
            panel.center()
            return
        }
        let height = panel.frame.height
        let rawX = pos.fromRight ? vf.maxX - pos.xOffset - Self.width : vf.minX + pos.xOffset
        let rawY = pos.fromTop ? vf.maxY - pos.yOffset - height : vf.minY + pos.yOffset
        // Clamp on-screen so a stale/odd saved offset can't strand the panel off the visible frame.
        let x = min(max(rawX, vf.minX), max(vf.minX, vf.maxX - Self.width))
        let y = min(max(rawY, vf.minY), max(vf.minY, vf.maxY - height))
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    /// The smallest the panel will shrink to. Kept just below the most compact real content (a focused
    /// single task with no breadcrumb or Next line, ~93pt) so that case fits exactly, while still
    /// guarding against a degenerate window if a transient measurement reports a near-zero height.
    static let minHeight: CGFloat = 80

    /// The smallest it will shrink to *with the project sidebar open*, where the panel stops being a
    /// task card and becomes a two-column workspace: tall enough for a useful stretch of the project
    /// list. The hug-a-single-task heights only make sense with the sidebar hidden.
    static let sidebarMinHeight: CGFloat = 400

    /// The tallest the panel goes: a Tarot-card proportion of the *content* column (not the window,
    /// so opening the sidebar widens the panel without also letting it grow taller), or 95% of the
    /// screen, whichever is smaller.
    private var maxPanelHeight: CGFloat {
        let screenMax = (panel.screen ?? NSScreen.main)?.visibleFrame.height ?? 900
        return min(Self.contentWidth * Self.maxHeightRatio, floor(screenMax * 0.95))
    }

    /// The height the user dragged the panel to while the sidebar was open. Nil until they resize it
    /// — until then the panel still auto-fits its content, just never below `sidebarMinHeight`.
    /// App-local (`UserDefaults`); written on mouse-up rather than on every frame of a drag.
    private static let userHeightKey = "PMPanelSidebarHeight"
    private var userHeight: CGFloat?
    /// Height at the start of the current grab, so a drag is applied as one absolute offset rather
    /// than an accumulation of deltas that could drift.
    private var resizeStartHeight: CGFloat = 0

    /// Auto-fit the panel to its content: height from the measured content, width from whether the
    /// project sidebar is showing.
    ///
    /// With the sidebar open the height is the user's instead: their dragged height if they have one,
    /// else the content's, and never below `sidebarMinHeight`. So this stays a no-op for height while
    /// they're working in a resized panel, and still tracks the content when the sidebar is hidden.
    private func fit(toContentHeight height: CGFloat) {
        let maxHeight = maxPanelHeight
        let target: CGFloat
        if Self.isSidebarVisible {
            target = min(max(userHeight ?? ceil(height), Self.sidebarMinHeight), maxHeight)
        } else {
            target = min(max(ceil(height), Self.minHeight), maxHeight)
        }
        let targetWidth = Self.width
        // The sidebar toggle can change the width with the height unchanged, so both are checked here.
        guard abs(panel.frame.height - target) > 1 || abs(panel.frame.width - targetWidth) > 1 else { return }
        var frame = panel.frame
        // Grow/shrink from whichever screen edge the panel is anchored to: keep the top edge fixed when
        // anchored near the top (grows downward), else keep the bottom edge fixed (grows upward), and
        // likewise keep the right edge fixed when anchored near the right. Either way the panel expands
        // away from the nearby edge, not across it.
        if verticalAnchorNearTop { frame.origin.y += frame.height - target }
        if horizontalAnchorNearRight { frame.origin.x += frame.width - targetWidth }
        frame.size = NSSize(width: targetWidth, height: target)

        // Animate the resize, except for the first fit right after summon and while hidden, which
        // should snap. The scrollbar is hidden for the duration so it doesn't flash while the viewport
        // and content are briefly mismatched mid-animation.
        let animate = panel.isVisible && !suppressNextFitAnimation
        suppressNextFitAnimation = false
        isProgrammaticMove = true
        if animate {
            chrome.isResizing = true
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.24
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                ctx.allowsImplicitAnimation = true
                panel.animator().setFrame(frame, display: true)
            } completionHandler: { [weak self] in
                self?.chrome.isResizing = false
                self?.isProgrammaticMove = false
                // The shadow is cached from the window's rendered alpha, so a resize leaves the old
                // shape behind until it's invalidated — visible as a stale outline around the panel.
                self?.panel.invalidateShadow()
            }
        } else {
            panel.setFrame(frame, display: true, animate: false)
            isProgrammaticMove = false
            panel.invalidateShadow()
        }
    }

    // MARK: Height drag (the panel's own grab handle, offered only with the sidebar open)

    /// A borderless window has no frame to grab, so the panel draws its own handle along the bottom
    /// edge and drives these. The top edge stays put for the whole drag — a bottom grip pulls the
    /// bottom edge down, whichever screen edge the panel is otherwise anchored to.

    func resizeBegan() {
        resizeStartHeight = panel.frame.height
    }

    /// `delta` is the drag's total translation from where it began (positive downward), so the height
    /// follows the pointer exactly instead of accumulating rounding drift.
    func resize(byHeightDelta delta: CGFloat) {
        let target = min(max((resizeStartHeight + delta).rounded(), Self.sidebarMinHeight), maxPanelHeight)
        userHeight = target
        guard abs(panel.frame.height - target) > 0.5 else { return }
        var frame = panel.frame
        frame.origin.y += frame.height - target   // top edge fixed
        frame.size.height = target
        // A panel sitting low on the screen would otherwise grow off the bottom; slide it up instead.
        if let vf = visibleFrame, frame.minY < vf.minY {
            frame.origin.y = min(vf.minY, vf.maxY - frame.height)
        }
        isProgrammaticMove = true
        panel.setFrame(frame, display: true, animate: false)
        isProgrammaticMove = false
        // No `invalidateShadow()` here: on a borderless, non-opaque window it re-rasterizes the whole
        // window's alpha to re-derive the shadow shape, which is far too much to do per mouse-moved
        // event. The shadow lags the edge during the drag and is corrected on mouse-up.
    }

    /// Persist the height and the (possibly shifted) position once the mouse comes up.
    func resizeEnded() {
        panel.invalidateShadow()
        UserDefaults.standard.set(userHeight ?? 0, forKey: Self.userHeightKey)
        savePosition()
    }

    // MARK: NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        // Pinned panels stay open on blur; otherwise hide after a short grace period unless focus
        // returns (a later becomeKey cancels the pending hide).
        guard !settings.pinned else { return }
        pendingHide?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.panel.isKeyWindow else { return }
            self.panel.orderOut(nil)
        }
        pendingHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + blurHideDelay, execute: work)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        pendingHide?.cancel()
    }

    func windowDidMove(_ notification: Notification) {
        // Ignore our own auto-fit / snap / restore moves entirely: they can fire mid-flight with a
        // transient (e.g. zero) size, and persisting then corrupts the saved offsets — a restore that
        // runs before the content lays out would otherwise save a right-anchor x-offset one panel-width
        // too large, drifting the panel left on every relaunch. A completed snap persists itself; a
        // genuine user drag persists here.
        guard !isProgrammaticMove else { return }
        savePosition()
        dragControlHeld = NSEvent.modifierFlags.contains(.control)
        updateSnapGhost()
        startDragTracking()
    }

    // MARK: Edge/corner snapping

    /// A repeating tick that runs for the duration of a drag (added in `.common` modes so it fires
    /// during AppKit's window-drag tracking loop). It settles the snap on mouse-up and — crucially —
    /// keeps the preview in sync when only ⌃ changes, so pressing/releasing ⌃ mid-drag shows/hides the
    /// ghost immediately, without needing a mouse move to drive `windowDidMove`.
    private func startDragTracking() {
        guard dragTimer == nil else { return }
        let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in self?.dragTick() }
        RunLoop.main.add(t, forMode: .common)
        dragTimer = t
    }

    private func dragTick() {
        if NSEvent.pressedMouseButtons & 0x1 == 0 {   // button released → drag is over
            dragTimer?.invalidate()
            dragTimer = nil
            snapToNearestAnchor()
            return
        }
        dragControlHeld = NSEvent.modifierFlags.contains(.control)
        updateSnapGhost()
    }

    /// Show/hide the drop preview live: visible only when a snap is eligible (an anchor within threshold
    /// and ⌃ not held), tracking the anchor the drop would land on and fading toward the screen center.
    private func updateSnapGhost() {
        guard let vf = visibleFrame, let target = eligibleSnapFrame() else { ghost.hide(); return }
        ghost.show(at: target, fadingToward: directionTowardCenter(of: target, in: vf), below: panel)
    }

    /// Unit vector from an anchor's center toward the screen center — the direction along which the
    /// ghost fades (opaque at the screen-edge side, translucent toward the middle).
    private func directionTowardCenter(of frame: NSRect, in vf: NSRect) -> CGVector {
        let dx = vf.midX - frame.midX, dy = vf.midY - frame.midY
        let len = max(hypot(dx, dy), 0.0001)
        return CGVector(dx: dx / len, dy: dy / len)
    }

    /// On drop: dismiss the preview and glide the panel onto the previewed anchor, if one is eligible.
    private func snapToNearestAnchor() {
        ghost.hide()
        guard let target = eligibleSnapFrame(),
              hypot(target.origin.x - panel.frame.origin.x, target.origin.y - panel.frame.origin.y) > 1
        else { return }
        isProgrammaticMove = true
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.24
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ctx.allowsImplicitAnimation = true
            panel.animator().setFrame(target, display: true)
        } completionHandler: { [weak self] in
            self?.isProgrammaticMove = false
            self?.savePosition()
        }
    }

    /// The frame the panel would snap to right now — its nearest anchor — or nil when snapping is off
    /// (⌃ held), the panel is hidden, or the nearest anchor is beyond `snapThreshold`.
    private func eligibleSnapFrame() -> NSRect? {
        guard !dragControlHeld, panel.isVisible, let vf = visibleFrame else { return nil }
        let f = panel.frame
        let origin = nearestAnchorOrigin(for: f, in: vf)
        guard snapDistance(from: f.origin, to: origin, size: f.size, in: vf) <= Self.snapThreshold else { return nil }
        return NSRect(origin: origin, size: f.size)
    }

    /// Distance from the panel to an anchor for threshold purposes, but with *outward* overshoot
    /// ignored: pushing the panel past a corner/edge anchor toward the screen edge (even offscreen)
    /// counts as zero on that axis, so a fling into a corner snaps cleanly no matter how far it's flung.
    /// Only the inward (toward-center) gap is measured against the threshold.
    private func snapDistance(from p: CGPoint, to a: CGPoint, size: CGSize, in vf: NSRect) -> CGFloat {
        let gap = snapGap
        let leftX = vf.minX + gap, rightX = vf.maxX - gap - size.width
        let bottomY = vf.minY + gap, topY = vf.maxY - gap - size.height
        var dx = p.x - a.x, dy = p.y - a.y
        if a.x == leftX,  dx < 0 { dx = 0 }   // overshot left
        if a.x == rightX, dx > 0 { dx = 0 }   // overshot right
        if a.y == bottomY, dy < 0 { dy = 0 }  // overshot down
        if a.y == topY,    dy > 0 { dy = 0 }  // overshot up
        return hypot(dx, dy)
    }

    /// The nearest snap origin (bottom-left) to the panel's current position: four corners plus four
    /// edge centers, each inset `snapGap` from the near edges and centered along the parallel axis.
    /// Anchors share the panel's size, so origin distance equals center distance.
    private func nearestAnchorOrigin(for f: NSRect, in vf: NSRect) -> NSPoint {
        let gap = snapGap
        let w = f.width, h = f.height
        let leftX = vf.minX + gap, rightX = vf.maxX - gap - w, midX = vf.midX - w / 2
        let bottomY = vf.minY + gap, topY = vf.maxY - gap - h, midY = vf.midY - h / 2
        let anchors = [
            NSPoint(x: leftX,  y: topY),    NSPoint(x: midX,   y: topY),    NSPoint(x: rightX, y: topY),
            NSPoint(x: leftX,  y: midY),                                    NSPoint(x: rightX, y: midY),
            NSPoint(x: leftX,  y: bottomY), NSPoint(x: midX,   y: bottomY), NSPoint(x: rightX, y: bottomY),
        ]
        let c = f.origin
        return anchors.min { hypot($0.x - c.x, $0.y - c.y) < hypot($1.x - c.x, $1.y - c.y) } ?? c
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Closing hides rather than destroying the panel; it's summoned again later.
        hide()
        return false
    }
}

/// A borderless, click-through preview of where a snap will land, shown during a drag so the snap
/// never surprises. A frosted `NSVisualEffectView` gives it a soft, blurry body; a feathered gradient
/// mask makes it more opaque toward the screen edge it docks to and fades it toward the center. It
/// fades in/out and glides between anchors, and sits just beneath the panel so the panel stays on top.
@MainActor
final class SnapGhostWindow {
    /// Matches `PanelController.cornerRadius` (copied rather than referenced: this is read from the
    /// ghost's non-isolated mask drawing, which can't touch a main-actor constant).
    static let cornerRadius: CGFloat = 16
    /// Resting opacity — translucent so it reads as a placeholder, not a second live panel.
    private static let restingAlpha: CGFloat = 0.72
    private static let fade = 0.16

    private let window: NSWindow
    private let effect: GhostEffectView
    private var visible = false

    init() {
        effect = GhostEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: PanelController.width, height: 200),
                          styleMask: [.borderless], backing: .buffered, defer: true)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.alphaValue = 0
        window.collectionBehavior = [.transient, .ignoresCycle]
        window.contentView = effect
    }

    /// Show (or move) the preview at `frame`, fading along `direction` (toward the screen center), kept
    /// just below `panel`. Fades in on first show and glides between anchors thereafter.
    func show(at frame: NSRect, fadingToward direction: CGVector, below panel: NSWindow) {
        window.level = panel.level
        window.appearance = panel.appearance
        effect.fadeDirection = direction
        if !visible {
            visible = true
            window.setFrame(frame, display: false)
            window.order(.below, relativeTo: panel.windowNumber)
            animate { self.window.animator().alphaValue = Self.restingAlpha }
        } else if window.frame != frame {
            window.order(.below, relativeTo: panel.windowNumber)
            animate {
                NSAnimationContext.current.allowsImplicitAnimation = true
                self.window.animator().setFrame(frame, display: true)
            }
        }
    }

    func hide() {
        guard visible else { return }
        visible = false
        animate({ self.window.animator().alphaValue = 0 }) { [weak self] in
            guard let self, self.window.alphaValue == 0 else { return }
            self.window.orderOut(nil)
        }
    }

    private func animate(_ body: @escaping () -> Void, completion: (() -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Self.fade
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            body()
        }, completionHandler: completion)
    }
}

/// A frosted preview view. Its `maskImage` is a soft-edged rounded rectangle carrying a directional
/// alpha gradient (opaque at the screen-edge side, gently translucent toward the center). The mask is a
/// dynamic drawing-handler image regenerated at the view's exact size, so it renders crisp at any
/// backing scale (a rasterized fixed-size mask tiles 2×2 on Retina — which is why the feather is drawn
/// with Core Graphics here rather than via a Core Image round-trip). Regenerated only when the size or
/// fade direction changes — during an anchor-to-anchor glide the size is constant, so it's cheap.
private final class GhostEffectView: NSVisualEffectView {
    /// Unit vector pointing toward the screen center; the mask fades from opaque (opposite side) to
    /// translucent along it.
    var fadeDirection = CGVector(dx: 0, dy: 1) {
        didSet {
            guard fadeDirection.dx != oldValue.dx || fadeDirection.dy != oldValue.dy else { return }
            needsRemask = true
            needsLayout = true
        }
    }

    private var needsRemask = true
    private var maskedSize: CGSize = .zero
    private var maskedScale: CGFloat = 0
    /// Edge softness (points): how far the boundary fades from opaque to clear.
    private static let feather: CGFloat = 6
    private static let ciContext = CIContext(options: nil)

    override func layout() {
        super.layout()
        guard bounds.width > 0, bounds.height > 0 else { return }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        if needsRemask || maskedSize != bounds.size || maskedScale != scale {
            maskImage = Self.mask(size: bounds.size, scale: scale, toward: fadeDirection)
            maskedSize = bounds.size
            maskedScale = scale
            needsRemask = false
        }
    }

    /// A rounded-rect alpha mask: a directional gradient (opaque on the screen-edge side to a still-
    /// mostly-opaque center — a gentle fade), softly feathered at the boundary via a real Gaussian blur
    /// so the ghost blurs off rather than cutting hard.
    ///
    /// Rendered into a bitmap at the view's backing `scale` and wrapped as a points-sized `NSImage`, so
    /// the hi-res CGImage maps 1:1 to the Retina backing (a 1×-scale mask would tile 2×2 — the bug that
    /// killed the earlier `NSCIImageRep` approach). The shape is inset by `feather` so the blur has room
    /// to fall off inside the canvas instead of being clipped at the edge.
    private static func mask(size: CGSize, scale: CGFloat, toward u: CGVector) -> NSImage? {
        let pxW = Int((size.width * scale).rounded()), pxH = Int((size.height * scale).rounded())
        guard pxW > 0, pxH > 0,
              let ctx = CGContext(data: nil, width: pxW, height: pxH, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)   // draw in points

        let rect = CGRect(origin: .zero, size: size)
        let inset = rect.insetBy(dx: feather, dy: feather)
        ctx.addPath(CGPath(roundedRect: inset, cornerWidth: SnapGhostWindow.cornerRadius,
                           cornerHeight: SnapGhostWindow.cornerRadius, transform: nil))
        ctx.clip()

        let colors = [CGColor(red: 1, green: 1, blue: 1, alpha: 1.0),
                      CGColor(red: 1, green: 1, blue: 1, alpha: 0.3)] as CFArray
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                        colors: colors, locations: [0, 1]) else { return nil }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let span = max(rect.width, rect.height)
        let opaque = CGPoint(x: center.x - u.dx * span, y: center.y - u.dy * span)  // edge side
        let clear  = CGPoint(x: center.x + u.dx * span, y: center.y + u.dy * span)  // center side
        ctx.drawLinearGradient(gradient, start: opaque, end: clear,
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

        guard let sharp = ctx.makeImage() else { return nil }
        let input = CIImage(cgImage: sharp)
        guard let blur = CIFilter(name: "CIGaussianBlur") else { return NSImage(cgImage: sharp, size: size) }
        blur.setValue(input.clampedToExtent(), forKey: kCIInputImageKey)
        blur.setValue(feather * scale, forKey: kCIInputRadiusKey)   // radius is in pixels
        guard let output = blur.outputImage?.cropped(to: input.extent),
              let blurred = ciContext.createCGImage(output, from: input.extent) else {
            return NSImage(cgImage: sharp, size: size)
        }
        return NSImage(cgImage: blurred, size: size)
    }
}
