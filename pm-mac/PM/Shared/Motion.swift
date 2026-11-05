import AppKit
import QuartzCore
import SwiftUI

/// Whether this Mac has been asked to move things less, and what to do about it.
///
/// Every animation in the app exists to make a change legible — six cards flying into a grid say which
/// card went where, and six cards appearing there say nothing. That argument is exactly as true for
/// someone who has turned Reduce Motion on, and exactly as unhelpful: for them the movement is the
/// problem, and the change still has to be legible without it. So the answer is not "animate anyway,
/// slower" but "arrive already there", which is what a zero duration produces — the same code path, the
/// same completion handler, no interpolation.
///
/// One place rather than a check at each call site, because a setting honoured in three animations out
/// of five reads as a bug in the two.
enum Motion {
    static var isReduced: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// A duration, or none at all.
    static func duration(_ normal: Double) -> Double { isReduced ? 0 : normal }

    /// A curve that arrives fast and brakes hard onto its mark, for a tile landing in its slot.
    ///
    /// The nearest thing to a critically damped spring where AppKit will only take a timing function —
    /// anything animated through `animator()`, including a card's frame. **It never passes the target.**
    /// This used to be `(0.3, 1.35, 0.5, 1)`, which peaked at 1.041: a tile crossing 600 pt went 24 pt
    /// past its slot and came back, into its neighbour's gap, on an action done many times a day. The
    /// "landed, not placed" feel comes from the deceleration — most of the travel is spent in the first
    /// third — not from the overshoot.
    ///
    /// Reduce Motion is handled by the duration going to zero around it, which lands every card on its
    /// mark in one frame and never runs the curve at all.
    static var settle: CAMediaTimingFunction { CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1) }

    /// How long a change takes, by kind — so the same kind of thing moves at the same speed everywhere.
    /// Pass through `Motion.duration` (or `Motion.animation`) so Reduce Motion still takes it to zero.
    enum Tempo {
        /// A hover, a chip, a ghost, a small fade — something already where the eye is.
        static let quick = 0.12
        /// A panel resizing or snapping, a card pushing in, a banner arriving.
        static let standard = 0.2
        /// Something crossing the window: a board move, the sidebar, several tiles at once.
        static let travel = 0.3
        /// A departure next to `standard`'s arrival: leaving is quieter than arriving.
        static let exit = 0.12
    }

    /// The curves a timing function is drawn from, in place of the system's named ones — whose
    /// `easeInEaseOut` spends its first sixty-odd milliseconds barely moving, which on a resize the user
    /// just caused reads as lag.
    enum Curve {
        /// Something the user caused: moves at once and decelerates onto its mark.
        static var out: CAMediaTimingFunction { CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1) }
        /// Something on screen changing state in place.
        static var inOut: CAMediaTimingFunction { CAMediaTimingFunction(controlPoints: 0.77, 0, 0.175, 1) }
        /// Something leaving; pair with `Tempo.exit`.
        static var exit: CAMediaTimingFunction { CAMediaTimingFunction(controlPoints: 0.4, 0, 1, 1) }
    }

    /// A SwiftUI animation, or none — `nil` is what `withAnimation` and `.animation(_:value:)` take to
    /// mean "change immediately".
    static func animation(_ wanted: Animation) -> Animation? { isReduced ? nil : wanted }

    /// A transition that travels, or a plain fade when Reduce Motion is on: the change stays legible
    /// without the movement, which is Apple's own substitution.
    static func moving(_ travelling: AnyTransition) -> AnyTransition { isReduced ? .opacity : travelling }

    /// One movement made of two things that must not happen at the same rate.
    ///
    /// **A crossing is two changes — the cards' places and the board's zoom — and running both on one
    /// curve is why they cancel**: the eye is given two movements describing the same trajectory and
    /// reads one. Sequencing them instead reads as two beats, which is worse in a different way. A phase
    /// offset is the way out: both start together, both end together, and what differs is *when* each
    /// spends its movement. The part that leads is most of the way there before the part that trails has
    /// properly begun, and between them they trace a curved path rather than a straight one or a corner.
    ///
    /// Both are given twice — as a timing function, which is all AppKit will take for a view's frame,
    /// and as arithmetic, because a transform flight samples its own curve into keyframes
    /// (`CanvasScrollView.flyByTransform`). The two spellings are the standard cubics and match to
    /// within a frame; they must be changed together.
    enum Phase {
        /// Spends itself early: two thirds done at a third of the way through.
        case leads
        /// Holds, then goes: a tenth done where `leads` is two thirds.
        case trails

        var timing: CAMediaTimingFunction {
            switch self {
            // easeOutCubic and easeInOutCubic, as the CSS curves of the same names.
            case .leads: CAMediaTimingFunction(controlPoints: 0.33, 1, 0.68, 1)
            case .trails: CAMediaTimingFunction(controlPoints: 0.65, 0, 0.35, 1)
            }
        }

        func eased(_ fraction: Double) -> Double {
            switch self {
            case .leads: 1 - pow(1 - fraction, 3)
            case .trails: fraction < 0.5 ? 4 * pow(fraction, 3) : 1 - pow(-2 * fraction + 2, 3) / 2
            }
        }
    }
}
