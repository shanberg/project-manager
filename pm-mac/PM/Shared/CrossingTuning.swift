import Foundation

/// Which of the crossing's costs are being paid on this run — **scaffolding, not a feature**.
///
/// Measuring one optimisation at a time means one build per variant, one install per build, and a
/// comparison spread across however long that takes: different thermal state, different pages loaded,
/// different everything. The differences being looked for here are a few milliseconds off a p95, which
/// is smaller than the drift between two sessions — so a spread measured that way is unreadable no
/// matter how carefully each half is run.
///
/// One build that can be told which costs to pay fixes that: `CrossingBench` walks the configurations
/// back to back on one board in one minute, and the only thing that differs between two numbers is the
/// thing being tested.
///
/// **Most of what was here has gone.** Five flags were measured flat over several hundred crossings —
/// the invalidation guards, the display clock, rasterising the fading cards, hiding the web views, and
/// deferring the page budget — so the two that were worth keeping became unconditional and the three
/// that bought nothing were deleted rather than kept switchable. What is left is the one lever still
/// unresolved, and this file goes with it.
struct CrossingTuning: OptionSet {
    let rawValue: Int

    /// Arrive at the tiling's zoom in one frame instead of flying to it, which takes
    /// `NSScrollView.magnification` — and the rescale of every layer under it, web views included —
    /// out of all but one frame.
    ///
    /// **A probe, not a shippable change**: it removes the animation rather than making it cheap, and
    /// the animation is what tells you which card went where. It stands for the option of doing the
    /// zoom as a layer transform, and it is here because leaving a workspace measured 70% of frames
    /// delivered with it against 13% without — the largest single lever found, and the only one that
    /// has not yet been either built or ruled out.
    static let skipZoomFlight = CrossingTuning(rawValue: 1 << 0)

    /// What the app does when nobody is benching.
    static let shipping: CrossingTuning = []

    /// The configuration in force. Set only by `CrossingBench`; `shipping` at every other moment, and
    /// put back when a run ends.
    @MainActor static var current: CrossingTuning = .shipping

    /// The configurations the bench walks, with the names the log uses.
    @MainActor static let spread: [(name: String, tuning: CrossingTuning)] = [
        ("shipping", .shipping),
        ("shipping+nozoom", [.skipZoomFlight]),
    ]

    /// Kept as a separate name because `CrossingBench` takes one, and because a longer list will be
    /// wanted again the moment there is a second thing to compare.
    @MainActor static let focused = spread
}
