import AppKit
import QuartzCore
import PmLib

/// A tile picked up by its handlebar, from the press until it is let go.
///
/// **It leans before it comes out.** Short of `freeAt`, the tile stays in its slot and follows the
/// pointer part of the way, more slowly the further you pull, never more than `follows` of it; at
/// `freeAt` it goes back into its slot, the proxy takes over, and drops are marked. A press that wanders
/// a few points is not a move, and the pull says the tile is being lifted out before anything else on
/// the board changes. The curve is niri's rubber band (`RubberBand { stiffness: 1, limit }`,
/// src/rubber_band.rs), applied to the pull's squared distance as niri's interactive move does.
///
/// Tuned in the Tile Drag Lab mock, 2026-11-09: free at 48 pt, follows 50%, fades 0.26s, the mark
/// gliding 0.21s on `Motion.settle`, bars on the gap 28 pt thick.
struct CanvasTileCarry {
    /// How far the pointer goes, in screen points, before the tile comes out of its slot.
    static let freeAt: Double = 48
    /// The most of the pointer's travel a leaning tile follows — approached, never reached.
    static let follows: Double = 0.5
    /// The veil, the proxy and the mark coming and going.
    static let fade: Double = 0.26
    /// The mark moving from one target to the next.
    static let glide: Double = 0.21
    /// A leaning tile going back into its slot, as the proxy takes over or the press ends.
    static let release: Double = Motion.Tempo.standard
    /// How thick a "beside" mark is, in screen points: a bar centred on the gap the tile would open,
    /// or along the edge where there is no neighbour to share one with.
    static let bar: Double = 28

    /// Where the press was, on the board.
    let start: CanvasPoint
    /// Out of its slot: the proxy is up and drops are marked. A tab pulled off its strip is out at once.
    var isFree: Bool

    /// How far a pull of (`dx`, `dy`) screen points gets the tile: the fraction of the pull it follows,
    /// and whether the pull has gone far enough for it to come out.
    static func lean(dx: Double, dy: Double) -> (fraction: Double, free: Bool) {
        let x = (dx * dx + dy * dy) / (freeAt * freeAt)
        return ((1 - 1 / (x / follows + 1)) * follows, x >= 1)
    }
}

/// A rectangle that moves to each new place along `Motion.settle`, for a mark drawn in `draw(_:)`.
///
/// `CanvasFade`'s sibling, on the same display clock (`DisplayTicker`): read from the time rather than
/// stepped, and arriving at once under Reduce Motion or with no screen to tick against. A move that
/// starts while one is under way sets off from where the rectangle is drawn, so a mark changing its
/// mind mid-glide turns rather than jumping back.
@MainActor
final class CanvasGlide {
    private var from: CanvasRect?
    private(set) var target: CanvasRect?
    private var progress: Double = 1
    private var startedAt: CFTimeInterval = 0
    private var duration: Double = 0
    private let seconds: Double
    private weak var view: NSView?
    private let onChange: @MainActor () -> Void
    private lazy var ticker = DisplayTicker { [weak self] now in self?.step(at: now) }

    init(seconds: Double, on view: NSView, onChange: @escaping @MainActor () -> Void) {
        self.seconds = seconds
        self.view = view
        self.onChange = onChange
    }

    /// Where the rectangle is drawn now.
    var current: CanvasRect? {
        guard let target else { return nil }
        guard let from, progress < 1 else { return target }
        let k = Motion.settled(progress)
        return CanvasRect(x: from.minX + (target.minX - from.minX) * k,
                          y: from.minY + (target.minY - from.minY) * k,
                          width: from.width + (target.width - from.width) * k,
                          height: from.height + (target.height - from.height) * k)
    }

    /// Be at `rect` with no travel — a mark appearing, rather than moving.
    func jump(to rect: CanvasRect) {
        ticker.stop()
        from = nil
        target = rect
        progress = 1
        onChange()
    }

    /// Travel to `rect` from wherever the rectangle is drawn now.
    func move(to rect: CanvasRect) {
        guard rect != target else { return }
        guard let here = current else { return jump(to: rect) }
        duration = Motion.duration(seconds)
        guard duration > 0, let view, ticker.start(on: view) else { return jump(to: rect) }
        from = here
        target = rect
        progress = 0
        startedAt = CACurrentMediaTime()
        onChange()
    }

    private func step(at now: CFTimeInterval) {
        progress = min(1, max(0, (now - startedAt) / duration))
        if progress >= 1 { ticker.stop() }
        onChange()
    }
}
