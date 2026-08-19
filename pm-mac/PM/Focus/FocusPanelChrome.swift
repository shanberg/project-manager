import AppKit
import QuartzCore
import CoreImage

/// A borderless panel that can take key focus, but only when it says it needs to. `NSWindow` refuses
/// key status to borderless windows by default, and the focus panel hosts text fields (task text, the
/// add editor) that need it — and its ⏎-to-complete shortcut only binds while it's key.
///
/// Gated rather than unconditional, because key status is the keyboard: whichever window holds it takes
/// every keystroke, and a floating panel that grabs it on any click leaves you typing into thin air in
/// the window you were actually working in. AppKit's own guard for this is `becomesKeyOnlyIfNeeded`,
/// which hands a panel key only for a click that lands somewhere needing text input — but it asks the
/// view under the pointer, and an `NSHostingView` answers yes at *every* point, a plain button
/// included. On a SwiftUI panel it's a no-op. So the panel decides instead: `acceptsKey` is set for the
/// paths that genuinely want the keyboard — the ⌃⌥P summon, and the panel's own editors opening — and
/// cleared as soon as key goes elsewhere.
final class KeyablePanel: NSPanel {
    /// Whether the panel may take key focus right now. Read by AppKit on every click that might move
    /// key focus, so leaving it set is what stole the keystrokes in the first place.
    var acceptsKey = false

    override var canBecomeKey: Bool { acceptsKey }

    /// Take key focus deliberately. `canBecomeKey` is consulted at this moment, so the gate opens just
    /// long enough for the panel to become key; `FocusPanelController` shuts it again on resign.
    func takeKey() {
        acceptsKey = true
        makeKey()
    }
}

/// The focus panel's window behavior: a borderless window that hugs its content's height, floats above
/// everything on every Space, and snaps to the screen's edges and corners.
///
/// This was the whole of `PanelController` back when the panel *was* the app, and then briefly an
/// alternate chrome a project window could wear. It belongs to the focus panel now, which is the window
/// it was always describing — so the parts that only made sense for a full project window (a fixed
/// content column widened by a sidebar, a user-draggable height, per-project position memory) are gone.
/// What's left is what a HUD needs: fit to content, remember where you put it, snap to the edges.
@MainActor
final class FocusPanelChrome {
    private let panel: NSPanel
    private var settings: PanelSettings

    /// Grace period before a blurred (unpinned) panel hides — long enough to ride out transient focus
    /// blips (a popover, a quick app switch, the summon shortcut itself).
    private let blurHideDelay: TimeInterval = 0.2
    private var pendingHide: DispatchWorkItem?
    /// Set on summon so the first auto-fit after showing snaps instead of animating a grow-on-open.
    private var suppressNextFitAnimation = false

    /// Edge/corner snapping. A drop settles onto one of eight anchors (four corners + four edge
    /// centers), each held a deliberate gap in from the screen edges. `dragTimer` polls for the drag to
    /// end (button released) — see `startDragTracking` for why polling is the only option inside
    /// AppKit's drag loop — `dragControlHeld` records whether ⌃ was down during the drag (which
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

    /// The smallest the panel will shrink to. Kept just below the most compact real content (a single
    /// task with no breadcrumb or Next line) so that case fits exactly, while still guarding against a
    /// degenerate window if a transient measurement reports a near-zero height.
    static let minHeight: CGFloat = 80

    init(panel: NSPanel, settings: PanelSettings) {
        self.panel = panel
        self.settings = settings

        panel.isOpaque = false
        panel.backgroundColor = .clear
        // The panel has no titlebar to drag by, so its background is the drag region. Everything the
        // user clicks *into* has to carve itself back out with `WindowDragExcluder` — a mouse-down on a
        // draggable region is swallowed by AppKit's drag-tracking loop and never reaches the view,
        // which reads as a click that didn't take.
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        applySettings(settings)
        applyWindowSettings()
        anchor = UserDefaults.standard.data(forKey: positionKey)
            .flatMap { try? JSONDecoder().decode(SavedPosition.self, from: $0) }
    }

    // MARK: Settings

    func applySettings(_ new: PanelSettings) {
        settings = new
        panel.level = new.floating ? .floating : .normal
    }

    /// "Show on all Spaces", applied here rather than on the project window because this is the window
    /// it was always meant for.
    ///
    /// `.canJoinAllSpaces` alone only follows you between ordinary desktops; it will *not* put the panel
    /// over another app's full-screen window. `.fullScreenAuxiliary` is the flag that does, and a HUD
    /// whose whole job is being visible while you work in a full-screen editor needs both.
    func applyWindowSettings() {
        var behavior: NSWindow.CollectionBehavior = [.ignoresCycle]
        if WindowSettings.shared.showOnAllSpaces {
            behavior.insert(.canJoinAllSpaces)
            behavior.insert(.fullScreenAuxiliary)
        } else {
            behavior.insert(.moveToActiveSpace)
        }
        panel.collectionBehavior = behavior
    }

    /// Whether a blur should hide the panel.
    ///
    /// Inverted from the old panel's default. That panel was a summoned sheet of the whole app, so
    /// getting out of the way on blur was the courteous thing; this one exists to stay visible *while*
    /// you work elsewhere, so it only hides when the user has explicitly asked it to.
    var hidesOnBlur: Bool { !settings.pinned }

    func cancelPendingHide() { pendingHide?.cancel() }

    func prepareToShow() {
        pendingHide?.cancel()
        suppressNextFitAnimation = true
    }

    func prepareToHide() {
        pendingHide?.cancel()
        dragTimer?.invalidate()
        dragTimer = nil
        ghost.hide()
    }

    /// A blur: hide after a short grace period unless focus returns (a later `cancelPendingHide`
    /// cancels it).
    func scheduleBlurHide() {
        guard hidesOnBlur else { return }
        pendingHide?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.panel.isKeyWindow else { return }
            self.panel.orderOut(nil)
        }
        pendingHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + blurHideDelay, execute: work)
    }

    // MARK: Position persistence

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
    /// One key: there is exactly one focus panel, so its position isn't namespaced by project the way
    /// the old per-project panel's was.
    private let positionKey = "PMFocusPanelAnchor"

    /// Where the user last left the panel, as edge offsets. Held in memory (not re-read from defaults
    /// each time) because the auto-fit consults it on every resize.
    private var anchor: SavedPosition?

    private var visibleFrame: NSRect? { (panel.screen ?? NSScreen.main)?.visibleFrame }

    /// Whether the panel's top edge is currently the nearer of the two horizontal screen edges. The
    /// auto-fit keeps this edge fixed so growth happens away from the nearby edge. Defaults to top.
    private var verticalAnchorNearTop: Bool {
        guard let vf = visibleFrame else { return true }
        return (vf.maxY - panel.frame.maxY) <= (panel.frame.minY - vf.minY)
    }

    func savePosition() {
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
        anchor = pos
        if let data = try? JSONEncoder().encode(pos) {
            UserDefaults.standard.set(data, forKey: positionKey)
        }
    }

    /// The origin a panel of `size` should sit at: recomputed from the saved edge offsets rather than
    /// nudged from wherever the panel currently is.
    ///
    /// Recomputing is what makes the position stable. Nudging by the height delta looks equivalent, and
    /// was — until the panel started life at zero height (the hosting controller supplies the size, and
    /// the first measurement arrives after the window exists). The very first fit then "grew" the panel
    /// by its whole height and shifted it down by that much, every launch, forever. Offsets from the
    /// near edges hold the anchored edge fixed by construction, whatever the panel's height was before.
    private func origin(for size: NSSize) -> NSPoint {
        guard let vf = visibleFrame else { return panel.frame.origin }
        guard let a = anchor else {
            return NSPoint(x: (vf.midX - size.width / 2).rounded(),
                           y: (vf.midY - size.height / 2).rounded())
        }
        let rawX = a.fromRight ? vf.maxX - a.xOffset - size.width : vf.minX + a.xOffset
        let rawY = a.fromTop ? vf.maxY - a.yOffset - size.height : vf.minY + a.yOffset
        // Clamp on-screen so a stale/odd saved offset can't strand the panel off the visible frame.
        return NSPoint(x: min(max(rawX, vf.minX), max(vf.minX, vf.maxX - size.width)),
                       y: min(max(rawY, vf.minY), max(vf.minY, vf.maxY - size.height)))
    }

    // MARK: Auto-fit

    /// The tallest the panel goes: a Tarot-card proportion of its width, or 95% of the screen,
    /// whichever is smaller. Content beyond this scrolls inside the card rather than growing the panel
    /// into a second window.
    private var maxPanelHeight: CGFloat {
        let screenMax = (panel.screen ?? NSScreen.main)?.visibleFrame.height ?? 900
        return min(ProjectWindow.focusPanelWidth * ProjectWindow.maxHeightRatio, floor(screenMax * 0.95))
    }

    /// Fit the panel to its content's height.
    ///
    /// The width is set here too, though it never varies. Installing a hosting controller with
    /// `sizingOptions` cleared leaves the window at that controller's (zero) preferred size, so the
    /// first fit is also what gives the panel its width — and having one place own the whole frame
    /// beats seeding a size that a later layout pass would silently contradict.
    func fit(toContentHeight height: CGFloat) {
        let target = min(max(ceil(height), Self.minHeight), maxPanelHeight)
        let width = ProjectWindow.focusPanelWidth
        guard abs(panel.frame.height - target) > 1 || abs(panel.frame.width - width) > 1 else { return }
        // Grow/shrink from whichever screen edge the panel is anchored to, so it expands away from the
        // nearby edge rather than across it — see `origin(for:)`.
        var frame = panel.frame
        frame.size = NSSize(width: width, height: target)
        frame.origin = origin(for: frame.size)
        // Positioning here is programmatic; without this the move would look like a user drag and arm
        // the snapping machinery.
        isProgrammaticMove = true

        // Animate the resize, except for the first fit right after summon and while hidden, which
        // should snap.
        let animate = panel.isVisible && !suppressNextFitAnimation
        suppressNextFitAnimation = false
        if animate {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.22
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                ctx.allowsImplicitAnimation = true
                panel.animator().setFrame(frame, display: true)
            } completionHandler: { [weak self] in
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

    // MARK: Edge/corner snapping

    /// Called from the window delegate's `windowDidMove`. Ignores our own auto-fit / snap / restore
    /// moves entirely: they can fire mid-flight with a transient (e.g. zero) size, and persisting then
    /// corrupts the saved offsets — a restore that runs before the content lays out would otherwise
    /// save a right-anchor x-offset one panel-width too large, drifting the panel left on every
    /// relaunch. A completed snap persists itself; a genuine user drag persists here.
    func windowDidMove() {
        guard !isProgrammaticMove else { return }
        savePosition()
        dragControlHeld = NSEvent.modifierFlags.contains(.control)
        updateSnapGhost()
        startDragTracking()
    }

    /// A repeating tick that runs for the duration of a drag. It settles the snap on mouse-up and —
    /// crucially — keeps the preview in sync when only ⌃ changes, so pressing/releasing ⌃ mid-drag
    /// shows/hides the ghost immediately, without needing a mouse move to drive `windowDidMove`.
    ///
    /// Polling, deliberately, and not replaceable by an event monitor. `isMovableByWindowBackground`
    /// hands the drag to AppKit, which runs it as a modal tracking loop: it consumes the mouse and
    /// modifier events itself, so a `.leftMouseUp`/`.flagsChanged` monitor never sees them. A timer
    /// added in `.common` modes is what still runs inside that loop, which is why this is a tick rather
    /// than a callback.
    ///
    /// One display frame at a 60Hz floor, rather than the 0.05s it used to be. The rate is a latency
    /// budget on noticing the mouse came up — the snap fires on the tick that sees it, so a coarse tick
    /// is a visible pause between letting go and the panel settling. Cheap either way: a tick that
    /// finds nothing changed does two `NSEvent` reads and returns.
    private func startDragTracking() {
        guard dragTimer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.dragTick() }
        }
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
}

/// A borderless, click-through preview of where a snap will land, shown during a drag so the snap
/// never surprises. A frosted `NSVisualEffectView` gives it a soft, blurry body; a feathered gradient
/// mask makes it more opaque toward the screen edge it docks to and fades it toward the center. It
/// fades in/out and glides between anchors, and sits just beneath the panel so the panel stays on top.
@MainActor
final class SnapGhostWindow {
    /// Matches `ProjectWindow.cornerRadius` (copied rather than referenced: this is read from the
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

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: ProjectWindow.focusPanelWidth, height: 200),
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
