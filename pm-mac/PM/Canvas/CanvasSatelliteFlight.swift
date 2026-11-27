import AppKit
import QuartzCore
import WebKit

/// A card crossing between its tile and a window of its own: out of the tile's rect into the window,
/// and back into the slot it kept.
///
/// **A satellite is its tile, lifted out**, and the crossing is what says so. Without it a window came
/// up in the middle of the screen with the system's generic grow, while its tile turned into "In a
/// window" in one frame, and Bring Back made the window vanish while the tile refilled in another:
/// nothing on screen said where the card had gone, or where it had come back from.
///
/// **A picture flies, not the window.** Animating the real window's frame resizes its content every
/// frame, and for a page that is WebKit laying out and repainting sixty times a second — the very cost
/// a resize already pays. A picture of the card, taken once and carried in a borderless panel of its
/// own, costs the web process nothing and can't tear; the real window is shown at its final frame,
/// invisible, and takes over from the picture in a short crossfade once it has landed. On the way home
/// the window goes at once and the card on the board stays hidden under the picture until it lands.
///
/// **Only for the moves you ask for** — Move to Window, Pop Out, Bring Back, Gather. A tile dragged out
/// already has the drag's own picture under the pointer, and windows coming back with their workspace
/// are being restored rather than moved; both fade (`arrive(_:from:)` with no origin).
///
/// **Reduce Motion: no travel.** The window fades in where it will be, and Bring Back closes as it
/// always did. A fade is Apple's own substitution for movement.
@MainActor
final class CanvasSatelliteFlight {
    /// Where a crossing starts or ends on screen, and the corners it has there.
    struct End {
        var rect: NSRect
        var radius: CGFloat
    }

    /// A plain titled window's corner, as `CanvasFocusHint` rings it.
    static let windowRadius: CGFloat = 16
    /// How long the picture and the real thing overlap once it has landed: long enough that neither
    /// is seen to pop, short enough to read as one surface.
    static let handOff = 0.08
    /// How long a picture of a page is waited for before flying without it. WebKit answers a snapshot
    /// in a frame or two when the page is painted; one that takes longer is not worth holding a press
    /// for, and the card's own ground stands in for the page.
    static let pictureDeadline = 0.12

    private let panel: NSPanel
    private let body = CALayer()
    private let surface = CALayer()
    private var at: End

    // MARK: Out

    /// Where a card's tile is on screen, and the picture to fly from it — nil when there is nothing to
    /// fly from: the board's window isn't on screen, the tile is scrolled out of sight, or Reduce Motion.
    static func origin(of card: CanvasNodeView) -> (End, NSImage?)? {
        guard !Motion.isReduced, let window = card.window, window.isVisible, window.isOnActiveSpace,
              !card.isHiddenOrHasHiddenAncestor else { return nil }
        let rect = window.convertToScreen(card.convert(card.bounds, to: nil))
        guard rect.width > 8, rect.height > 8, window.frame.intersects(rect) else { return nil }
        let radius = CGFloat(CanvasTiling.innerRadius * card.board.liveScale)
        return (End(rect: rect, radius: radius), still(of: card))
    }

    /// Show a satellite's window: flown out of `origin`, or faded in where it is when there is none.
    ///
    /// The window is ordered in at once, invisible, so it is key and taking keys from the first frame;
    /// it becomes visible as the picture lands on it.
    static func arrive(_ controller: NSWindowController, from origin: (End, NSImage?)?) {
        guard let window = controller.window else { return }
        let behavior = window.animationBehavior
        window.animationBehavior = .none
        window.alphaValue = 0
        controller.showWindow(nil)
        let reveal = { (duration: Double) in
            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration  // motion: fade-only
                window.animator().alphaValue = 1
            } completionHandler: {
                MainActor.assumeIsolated { window.animationBehavior = behavior }
            }
        }
        guard let origin, !Motion.isReduced else { return reveal(Motion.Tempo.quick) }
        let to = End(rect: contentRect(of: window), radius: windowRadius)
        let flight = CanvasSatelliteFlight(picture: origin.1, at: origin.0, scale: window.backingScaleFactor)
        flight.go(to: to, duration: Motion.Tempo.travel, lifting: true) { reveal(handOff) }
    }

    // MARK: Home

    /// Bring satellites home: each one's picture flies from its window into its card's slot.
    ///
    /// `closing` is the move itself — closing the windows, which puts the content back in the cards and
    /// brings the workspace's window forward — and is run once the pictures are up over the windows, so
    /// nothing is seen to vanish. Where a card lands is asked for after it, since that is when the
    /// workspace's window is where it is going to be and Gather has laid the tiles out.
    static func home(_ satellites: [CanvasSatelliteWindow], closing: @escaping () -> Void) {
        guard !Motion.isReduced else { return closing() }
        let leaving: [(window: NSWindow, card: CanvasNodeView, view: NSView)] = satellites.compactMap { satellite in
            guard let window = satellite.window, window.isVisible, window.isOnActiveSpace,
                  !window.isMiniaturized, !window.styleMask.contains(.fullScreen),
                  let card = satellite.shownCard, let view = card.cardContent, view.window === window
            else { return nil }
            return (window, card, view)
        }
        guard !leaving.isEmpty else { return closing() }
        var pictures = [NSImage?](repeating: nil, count: leaving.count)
        var waiting = leaving.count
        var started = false
        func start() {
            guard !started else { return }
            started = true
            let flights = leaving.indices.map { index in
                let window = leaving[index].window
                window.animationBehavior = .none
                return CanvasSatelliteFlight(picture: pictures[index],
                                             at: End(rect: contentRect(of: window), radius: windowRadius),
                                             scale: window.backingScaleFactor)
            }
            closing()
            for (flight, one) in zip(flights, leaving) {
                let card = one.card
                guard let landing = slot(of: card) else {
                    flight.fadeOut(Motion.Tempo.exit)
                    continue
                }
                card.alphaValue = 0
                flight.go(to: landing, duration: 0.24, lifting: false) { [weak card] in
                    NSAnimationContext.runAnimationGroup { context in
                        context.duration = handOff  // motion: fade-only
                        card?.animator().alphaValue = 1
                    }
                }
            }
        }
        for (index, leaving) in leaving.enumerated() {
            picture(of: leaving.view) { image in
                pictures[index] = image
                waiting -= 1
                if waiting == 0 { start() }
            }
        }
        // A press is held for the pictures only so long.
        DispatchQueue.main.asyncAfter(deadline: .now() + pictureDeadline + 0.02) { start() }
    }

    /// Where a card is on the board once it is home, if it is somewhere that can be seen.
    private static func slot(of card: CanvasNodeView) -> End? {
        guard let window = card.window, window.isVisible, window.isOnActiveSpace, card.lentTo == nil,
              !card.isHiddenOrHasHiddenAncestor else { return nil }
        let rect = window.convertToScreen(card.convert(card.bounds, to: nil))
        guard rect.width > 8, rect.height > 8, window.frame.intersects(rect) else { return nil }
        return End(rect: rect, radius: CGFloat(CanvasTiling.innerRadius * card.board.liveScale))
    }

    /// The part of a satellite under its header, on screen: where its card's content is.
    private static func contentRect(of window: NSWindow) -> NSRect {
        var rect = window.frame
        rect.size.height = max(1, rect.height - CanvasSatelliteWindow.headerHeight)
        return rect
    }

    // MARK: Pictures

    /// A card as it is drawn now, without its page: what `cacheDisplay` can reach in one go. For the
    /// flight out, which starts on the press; a page's last picture at a tile's shape stands in for
    /// the page, when there is one.
    private static func still(of card: CanvasNodeView) -> NSImage? {
        guard card.bounds.width > 1, card.bounds.height > 1,
              let rep = card.bitmapImageRepForCachingDisplay(in: card.bounds) else { return nil }
        card.cacheDisplay(in: card.bounds, to: rep)
        let size = card.bounds.size
        let page = (card as? CanvasLinkNodeView).flatMap { _ in
            CanvasPageSnapshots.of(CanvasPageHandover.key(canvas: card.board.store.url, card: card.node.id), tiled: true)
        }
        return NSImage(size: size, flipped: false) { bounds in
            rep.draw(in: bounds)
            page?.draw(in: bounds)
            return true
        }
    }

    /// A view as it looks now, its pages included: drawn by `cacheDisplay`, with each page WebKit is
    /// showing in it asked for its own picture and laid over its place (as `WindowSnapshot` does for a
    /// window). `done` is called once — with the pages, or without them at `pictureDeadline`.
    private static func picture(of view: NSView, _ done: @escaping (NSImage?) -> Void) {
        guard view.bounds.width > 1, view.bounds.height > 1,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return done(nil) }
        view.cacheDisplay(in: view.bounds, to: rep)
        let size = view.bounds.size
        func compose(_ pages: [(NSImage, NSRect)]) -> NSImage {
            NSImage(size: size, flipped: false) { bounds in
                rep.draw(in: bounds)
                for (page, rect) in pages { page.draw(in: rect) }
                return true
            }
        }
        let webs = pages(in: view)
        guard !webs.isEmpty else { return done(compose([])) }
        var got: [(NSImage, NSRect)] = []
        var waiting = webs.count
        var finished = false
        func finish() {
            guard !finished else { return }
            finished = true
            done(compose(got))
        }
        for web in webs {
            var rect = view.convert(web.bounds, from: web)
            if view.isFlipped { rect.origin.y = size.height - rect.maxY }
            web.takeSnapshot(with: nil) { image, _ in
                MainActor.assumeIsolated {
                    if let image { got.append((image, rect)) }
                    waiting -= 1
                    if waiting == 0 { finish() }
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + pictureDeadline) { finish() }
    }

    private static func pages(in view: NSView) -> [WKWebView] {
        var found: [WKWebView] = []
        func walk(_ view: NSView) {
            if view.isHidden || view.alphaValue == 0 { return }
            if let web = view as? WKWebView {
                if !web.visibleRect.isEmpty { found.append(web) }
                return
            }
            view.subviews.forEach(walk)
        }
        walk(view)
        return found
    }

    // MARK: The flight

    /// A picture up on screen at `at`, over everything, ready to go.
    private init(picture: NSImage?, at start: End, scale: CGFloat) {
        at = start
        panel = NSPanel(contentRect: start.rect, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        // Over the window it is leaving and the one it is going to, both of which come forward under
        // it. Only for the length of a crossing.
        panel.level = .floating
        panel.animationBehavior = .none
        panel.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(origin: .zero, size: start.rect.size))
        root.wantsLayer = true
        panel.contentView = root

        // Resolved now, in the app's appearance: a dynamic colour's `cgColor` is whichever it was asked in.
        var ground = NSColor.windowBackgroundColor.cgColor
        NSApp.effectiveAppearance.performAsCurrentDrawingAppearance {
            ground = NSColor.windowBackgroundColor.cgColor
        }
        body.backgroundColor = ground
        body.cornerCurve = .continuous
        body.shadowColor = NSColor.black.cgColor
        body.shadowRadius = 18
        body.shadowOffset = CGSize(width: 0, height: -6)
        body.shadowOpacity = 0
        surface.masksToBounds = true
        surface.cornerCurve = .continuous
        surface.contentsGravity = .resizeAspectFill
        surface.contentsScale = scale
        // An `NSImage` as contents is drawn once, at the layer's scale.
        surface.contents = picture
        body.addSublayer(surface)
        root.layer?.addSublayer(body)
        place(start, in: start.rect)
        panel.orderFrontRegardless()
    }

    /// The body at `end`, in a panel whose frame is `frame` — without animating.
    private func place(_ end: End, in frame: NSRect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let local = CGRect(x: end.rect.minX - frame.minX, y: end.rect.minY - frame.minY,
                           width: end.rect.width, height: end.rect.height)
        body.frame = local
        body.cornerRadius = end.radius
        surface.frame = CGRect(origin: .zero, size: local.size)
        surface.cornerRadius = end.radius
        CATransaction.commit()
    }

    /// Fly to `to`, and call `landed` as it arrives — for whatever takes over from the picture — then
    /// fade the picture out over the hand-off.
    ///
    /// **Two curves, one movement**, as a crossing on the board is (`Motion.Phase`): where it is spends
    /// itself early on `Motion.settle`, and its size follows on `Phase.leads`, so a picture changing
    /// shape as it travels traces a curve rather than sliding along a diagonal. Lifting out, a shadow
    /// comes up under it; going home, the shadow it had goes down as it lands.
    private func go(to: End, duration: Double, lifting: Bool, landed: @escaping () -> Void) {
        let frame = at.rect.union(to.rect)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        panel.setFrame(frame, display: false)
        panel.contentView?.frame = NSRect(origin: .zero, size: frame.size)
        CATransaction.commit()
        let from = at
        place(from, in: frame)
        func local(_ rect: NSRect) -> CGRect {
            CGRect(x: rect.minX - frame.minX, y: rect.minY - frame.minY, width: rect.width, height: rect.height)
        }
        let start = local(from.rect), end = local(to.rect)
        let lifted: Float = 0.28

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [self] in
            MainActor.assumeIsolated {
                landed()
                fadeOut(Self.handOff)
            }
        }
        func animate(_ layer: CALayer, _ key: String, _ from: Any, _ to: Any, _ timing: CAMediaTimingFunction) {
            let animation = CABasicAnimation(keyPath: key)
            animation.fromValue = from
            animation.toValue = to
            animation.duration = duration
            animation.timingFunction = timing
            layer.add(animation, forKey: key)
        }
        let position = NSValue(point: NSPoint(x: end.midX, y: end.midY))
        let size = NSValue(rect: CGRect(origin: .zero, size: end.size))
        body.position = CGPoint(x: end.midX, y: end.midY)
        body.bounds = CGRect(origin: .zero, size: end.size)
        body.cornerRadius = to.radius
        surface.position = CGPoint(x: end.width / 2, y: end.height / 2)
        surface.bounds = CGRect(origin: .zero, size: end.size)
        surface.cornerRadius = to.radius
        body.shadowOpacity = lifting ? lifted : 0
        animate(body, "position", NSValue(point: NSPoint(x: start.midX, y: start.midY)), position, Motion.settle)
        animate(body, "bounds", NSValue(rect: CGRect(origin: .zero, size: start.size)), size, Motion.Phase.leads.timing)
        animate(body, "cornerRadius", from.radius, to.radius, Motion.Phase.leads.timing)
        animate(surface, "position", NSValue(point: NSPoint(x: start.width / 2, y: start.height / 2)),
                NSValue(point: NSPoint(x: end.width / 2, y: end.height / 2)), Motion.Phase.leads.timing)
        animate(surface, "bounds", NSValue(rect: CGRect(origin: .zero, size: start.size)), size, Motion.Phase.leads.timing)
        animate(surface, "cornerRadius", from.radius, to.radius, Motion.Phase.leads.timing)
        animate(body, "shadowOpacity", lifting ? Float(0) : lifted, lifting ? lifted : Float(0), Motion.Curve.out)
        CATransaction.commit()
        at = to
        // Nothing else holds a flight once it has been set going; it lets itself go in `fadeOut`.
        Self.held[ObjectIdentifier(self)] = self
    }

    /// The picture gone over `duration`, and the panel with it.
    private func fadeOut(_ duration: Double) {
        Self.held[ObjectIdentifier(self)] = self
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration  // motion: fade-only
            context.timingFunction = Motion.Curve.exit
            panel.animator().alphaValue = 0
        } completionHandler: { [self] in
            MainActor.assumeIsolated {
                panel.orderOut(nil)
                Self.held[ObjectIdentifier(self)] = nil
            }
        }
    }

    private static var held: [ObjectIdentifier: CanvasSatelliteFlight] = [:]
}
