import AppKit
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

    /// A SwiftUI animation, or none — `nil` is what `withAnimation` and `.animation(_:value:)` take to
    /// mean "change immediately".
    static func animation(_ wanted: Animation) -> Animation? { isReduced ? nil : wanted }
}
