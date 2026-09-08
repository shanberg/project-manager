import AppKit

/// A number that eases between 0 and 1, for things drawn in `draw(_:)` rather than composited by a
/// layer.
///
/// The board's transient chrome — the dot grid, the alignment ghosts — is painted, not built out of
/// views, so none of it can be handed to `animator()` and faded by Core Animation. Painted things
/// switch on and off, and switched-on chrome is the difference between a hint and a flinch: a guide
/// that appears the instant two edges agree and vanishes the instant they stop is a flicker attached
/// to your hand, and it reads as the board glitching rather than as the board answering.
///
/// So it is a timer and a step, which is the unglamorous version of the same thing. The two durations
/// are always different: coming up has to beat your eye to the change, and going away has nothing
/// left to prove and should not look like a blink between two quick drags.
///
/// Reduce Motion collapses both to nothing — `Motion.duration` returns zero, the value arrives at its
/// target on the same code path, and the caller redraws once. See `Motion`.
@MainActor
final class CanvasFade {
    /// Where the fade is now: 0 is gone, 1 is fully present. Multiply alphas by it.
    private(set) var presence: Double = 0

    private var target: Double = 0
    private var timer: Timer?
    private let rise: Double
    private let fall: Double
    /// Called on every step, including the last. The owner redraws whatever this fades.
    private let onChange: @MainActor () -> Void

    init(rise: Double, fall: Double, onChange: @escaping @MainActor () -> Void) {
        self.rise = rise
        self.fall = fall
        self.onChange = onChange
    }

    deinit { timer?.invalidate() }

    /// Whether the thing this fades is currently drawn at all — a fading-out ghost is still drawn.
    var isVisible: Bool { presence > 0.001 }

    func set(_ wanted: Bool) {
        let next: Double = wanted ? 1 : 0
        guard next != target else { return }
        target = next

        timer?.invalidate()
        let seconds = Motion.duration(next > presence ? rise : fall)
        guard seconds > 0 else {
            timer = nil
            presence = next
            return onChange()
        }
        let step = max(0.001, abs(next - presence) / (seconds * 60))
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { timer in
            Task { @MainActor [weak self] in
                guard let self else { return timer.invalidate() }
                presence = next > presence ? min(next, presence + step) : max(next, presence - step)
                onChange()
                guard presence == next else { return }
                timer.invalidate()
                self.timer = nil
            }
        }
    }
}
