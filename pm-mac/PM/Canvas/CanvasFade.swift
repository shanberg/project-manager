import AppKit
import QuartzCore

/// A number that eases between 0 and 1, for things drawn in `draw(_:)` rather than composited by a
/// layer.
///
/// The board's transient chrome — the dot grid, the alignment ghosts — is painted, not built out of
/// views, so none of it can be handed to `animator()` and faded by Core Animation. Painted things
/// switch on and off, and switched-on chrome is the difference between a hint and a flinch: a guide
/// that appears the instant two edges agree and vanishes the instant they stop is a flicker attached
/// to your hand, and it reads as the board glitching rather than as the board answering.
///
/// So it is a clock and a curve, which is the unglamorous version of the same thing. The two durations
/// are always different: coming up has to beat your eye to the change, and going away has nothing
/// left to prove and should not look like a blink between two quick drags.
///
/// **The clock is the display's**, and it used to be a `Timer` at 1/60 stepping the value by a fixed
/// amount per tick. See `DisplayTicker` for the three ways that is not the same thing — the short
/// version being that this Mac's panel refreshes 120 times a second, and a fade drawn in sixty steps
/// against six other things each keeping their own approximate sixtieth is a crossing assembled out
/// of pictures that never quite agree about what time it is.
///
/// The value is therefore read from the clock rather than accumulated: where should this be at the
/// moment the frame being prepared is shown. That also makes a dropped frame cost a frame rather than
/// stretching the animation — the fade stays on time and simply has fewer pictures in it, which is
/// what every other animation in the app does when the machine is busy.
///
/// Reduce Motion collapses both durations to nothing — `Motion.duration` returns zero, the value
/// arrives at its target on the same code path, and the caller redraws once. See `Motion`. A view with
/// no screen to tick against takes that same path; see `DisplayTicker.start(on:)`.
@MainActor
final class CanvasFade {
    /// Where the fade is now: 0 is gone, 1 is fully present. Multiply alphas by it.
    private(set) var presence: Double = 0

    private var target: Double = 0
    private let rise: Double
    private let fall: Double
    /// The view whose display this fade runs on. Weak because the view owns the fade.
    private weak var view: NSView?
    /// Called on every step, including the last. The owner redraws whatever this fades.
    private let onChange: @MainActor () -> Void

    private lazy var ticker = DisplayTicker { [weak self] now in self?.step(at: now) }

    /// The travel under way: where it started, and when it started and ends. Read against the clock on
    /// every frame rather than advanced by one step per tick — see the note above.
    private var travel: (from: Double, startedAt: CFTimeInterval, seconds: Double)?

    init(rise: Double, fall: Double, on view: NSView, onChange: @escaping @MainActor () -> Void) {
        self.rise = rise
        self.fall = fall
        self.view = view
        self.onChange = onChange
    }

    /// Whether the value is travelling right now — which is what "the board is mid-crossing" means
    /// for everything that has to keep out of the way of one.
    var isMoving: Bool { travel != nil }

    /// Whether the thing this fades is currently drawn at all — a fading-out ghost is still drawn.
    var isVisible: Bool { presence > 0.001 }

    /// Put the value somewhere without moving it — a state to animate *from*.
    ///
    /// For a view that has just been handed a pose to arrive from: a board coming forward as the canvas
    /// you were looking at a moment ago starts fully tiled and eases out of it, which it cannot do if
    /// its only way to reach 1 is to travel there. See `CanvasBoardView.arrive(from:)`.
    func hold(_ value: Double) {
        ticker.stop()
        travel = nil
        presence = min(1, max(0, value))
        target = presence
        onChange()
    }

    func set(_ wanted: Bool) {
        let next: Double = wanted ? 1 : 0
        guard next != target else { return }
        target = next

        // The whole duration whatever distance is left, which is what it has always done: a fade
        // reversed halfway takes the same third of a second to travel the half it has to travel. The
        // curve is linear for the same reason — this is the arithmetic that was here, moved onto a
        // clock that can be trusted, and not an occasion to change how any of it looks.
        let seconds = Motion.duration(next > presence ? rise : fall)
        guard seconds > 0, let view, ticker.start(on: view) else {
            ticker.stop()
            travel = nil
            presence = next
            return onChange()
        }
        travel = (from: presence, startedAt: CACurrentMediaTime(), seconds: seconds)
    }

    /// Where the fade should be on the frame about to be shown. See `DisplayTicker`, which explains
    /// why the answer is read from `now` rather than added to `presence`.
    private func step(at now: CFTimeInterval) {
        guard let travel else { return ticker.stop() }
        let fraction = min(1, max(0, (now - travel.startedAt) / travel.seconds))
        presence = travel.from + (target - travel.from) * fraction
        if fraction >= 1 {
            presence = target
            self.travel = nil
            ticker.stop()
        }
        onChange()
    }
}
