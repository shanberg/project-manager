import AppKit
import QuartzCore

/// One callback per screen refresh, for the animations AppKit will not run for us.
///
/// **A `Timer` at 1/60 is not a frame.** Most of what moves on the board is handed to Core Animation
/// and drawn by the render server, which is aligned to the display and needs none of this. What is
/// left is the handful of things that are *painted* — the crossing between a board and a workspace,
/// the dot grid, the zoom on the way into a tiling — and those were each driven by their own
/// `Timer.scheduledTimer(withTimeInterval: 1.0 / 60)`. Three problems, all of which show:
///
///   * **A timer is not vsync.** It fires whenever the run loop gets to it, which is a few
///     milliseconds either side of the refresh and drifts; two of them started together drift apart.
///     Work landing just after a refresh waits a whole frame to be seen, so a third of a second of
///     movement arrives in fewer distinct pictures than it was drawn in.
///   * **1/60 is a guess about the display.** This Mac's built-in panel is 120Hz and an external one
///     may be anything; a fade stepping a sixtieth of its distance per tick either takes twice as long
///     or moves in half as many steps as the screen could show, depending on how it does the sum.
///   * **A timer cannot say it is late.** A tick that arrives 40ms after the last one still advances
///     by one step, so a fade that is dropping frames finishes by *stretching* rather than by
///     skipping — the animation slows down instead of staying on time.
///
/// A `CADisplayLink` answers all three: it fires once per refresh, it says when the frame it is
/// preparing will actually be shown, and when the main thread misses a refresh it coalesces rather
/// than piling up. Everything driven from one should therefore work in *time* — where am I at this
/// timestamp — and never in steps per tick. See `CanvasFade` and `CanvasScrollView.fly`, which both do.
@MainActor
final class DisplayTicker {

    /// Called once per refresh with the time the frame being prepared will be presented.
    ///
    /// `targetTimestamp`, not "now": the value computed from it is the one that will be on screen, so
    /// working in it puts the animation where it should be when it is *seen* rather than where it was
    /// when the main thread woke up.
    private let onTick: (CFTimeInterval) -> Void

    init(onTick: @escaping (CFTimeInterval) -> Void) {
        self.onTick = onTick
        proxy.ticker = self
    }

    deinit { link?.invalidate() }

    private var link: CADisplayLink?

    /// **A link retains its target**, exactly as a repeating `Timer` does, and only `invalidate()` lets
    /// it go. A ticker that were its own target would therefore be kept alive by the link it owns, so
    /// the `deinit` that is supposed to invalidate that link could never run — and a view thrown away
    /// mid-fade would leave a link firing once per refresh, forever, into a closure whose `self` had
    /// gone. Every owner would have to remember to stop the ticker by hand, and the one that forgot
    /// would cost a callback a frame for the life of the process.
    ///
    /// So the link retains this instead, and this holds the ticker weakly. Nothing owns the ticker but
    /// whoever made it; when they let go, `deinit` runs and the link is invalidated on the way out.
    private let proxy = Proxy()

    private final class Proxy: NSObject {
        weak var ticker: DisplayTicker?

        /// Already on the main thread — the link is added to the main run loop — so this is an
        /// assertion of where we are rather than a hop.
        @objc func fire(_ link: CADisplayLink) {
            MainActor.assumeIsolated { ticker?.tick(link) }
        }
    }

    var isRunning: Bool { link != nil }

    /// Begin ticking against the display `view` is on.
    ///
    /// **False means there is no display**, which is a view that is not in a window or is in one that
    /// is off every screen. There are no frames to animate in for such a view and no way to be told
    /// about them; the caller's answer is to arrive at the end of whatever it was doing outright,
    /// which is the same answer `Motion` gives for Reduce Motion and along the same code path.
    @discardableResult
    func start(on view: NSView) -> Bool {
        stop()
        guard view.window?.screen != nil else { return false }
        let link = view.displayLink(target: proxy, selector: #selector(Proxy.fire))
        // `.common`, not the default mode: a card is dragged inside a mouse-tracking loop and the grid
        // fades up as it starts moving, so a ticker that stopped for tracking would stop for exactly
        // the gesture it exists to draw.
        link.add(to: .main, forMode: .common)
        self.link = link
        return true
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    fileprivate func tick(_ link: CADisplayLink) {
        onTick(link.targetTimestamp)
    }
}
