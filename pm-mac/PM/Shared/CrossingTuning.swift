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
    ///
    /// **Confirmed on a second journey, 2026-09-11.** `pmpanel://bench?spread=1&journey=picking`, six
    /// crossings per configuration on a board of eight cards, interleaved: shipping dropped 8, 9, 10,
    /// 11, 11 and 10 frames of 22 (~57% delivered, worst frame 40-51ms); with the flight skipped it
    /// dropped 3, 1, 5, 2, 1 and 0 (~89% delivered, worst frame mostly 33ms, one crossing complete at
    /// 23 of 23). The two sets do not overlap. Main-thread work is not the constraint on either side —
    /// the pass that removed 48ms of per-frame layout from this same journey changed the frame count
    /// not at all (`CanvasBoardView.refreshVisibleCards`) — so what is left is the rescale itself.
    static let skipZoomFlight = CrossingTuning(rawValue: 1 << 0)

    /// Do the zoom as a layer transform: arrive at the destination magnification in one step, and ease
    /// a counter-transform on the board's layer back to identity so the travel is the render server's
    /// work rather than a rescale of every layer under the clip, once per frame.
    ///
    /// **What `skipZoomFlight` stands for, built** — the animation is kept rather than removed. See
    /// `CanvasScrollView.flyByTransform` for what it costs: content is rasterised at the destination
    /// scale and transformed to the intermediate ones, and the cards are where they will be rather than
    /// where they are drawn, so a click mid-flight reads the destination's geometry.
    ///
    /// **Measured on the picker, 2026-09-11**, six crossings per configuration interleaved: shipping
    /// dropped 11, 9, 9, 9, 6 and 10 frames of 22; skipping the flight dropped 2, 4, 4, 3, 2 and 4;
    /// this dropped 4, 1, 5, 2, 3 and 2, with the worst frame 33-36ms against shipping's 39-50ms. So it
    /// buys what removing the animation bought, and keeps the animation. **What is still unmeasured is
    /// how it looks** — softness on the way through a long zoom-out, and a click landing on the
    /// destination's geometry — which no frame count can answer. `pmpanel://tuning?zoom=transform`
    /// holds it on so it can be watched.
    ///
    /// **Watched, and parked — it does not read as a crossing.** With it on, a canvas becoming a
    /// workspace looks like the board being scaled, not like cards gathering into tiles, which is the
    /// one thing the animation exists to say (§7k: "six cards appearing in a grid says nothing about
    /// which card went where"). Every measurement says the movement is there: at the midpoint of a
    /// crossing the card's presented frame is identical under both configurations, and the board's
    /// layer is at 0.869 where the geometric curve wants 0.879. So the geometry is right and the
    /// reading of it is wrong — most likely because every card is rasterised wearing its destination
    /// face and then scaled, so a uniform scale is the whole of what the eye is given. Not shipped,
    /// and not deleted: what is wrong with it is a perception, and the next person to try this should
    /// see the numbers before spending the night finding them again.
    ///
    /// **Shipping where nothing gathers, without this flag.** The objection is about cards being read
    /// against a scale, so it does not reach a journey where the zoom is the whole movement: a peek asks
    /// for the transform outright (`CanvasScrollView.fly(to:centre:animated:alone:)`), and this flag is
    /// only what turns it on for the journeys that also move cards. Measured on peek the same way, six
    /// round trips apiece: peeking in dropped 2, 3, 2, 1, 3 and 3 frames of 22 on the ticked flight and
    /// 1, 1, 0, 0, 0 and 1 on the transform.
    static let zoomAsTransform = CrossingTuning(rawValue: 1 << 1)

    /// What the app does when nobody is benching.
    static let shipping: CrossingTuning = []

    /// The configuration in force. Set only by `CrossingBench`; `shipping` at every other moment, and
    /// put back when a run ends.
    @MainActor static var current: CrossingTuning = .shipping

    /// The configurations the bench walks, with the names the log uses.
    @MainActor static let spread: [(name: String, tuning: CrossingTuning)] = [
        ("shipping", .shipping),
        ("shipping+nozoom", [.skipZoomFlight]),
        ("shipping+transform", [.zoomAsTransform]),
    ]

    /// Kept as a separate name because `CrossingBench` takes one, and because a longer list will be
    /// wanted again the moment there is a second thing to compare.
    @MainActor static let focused = spread
}
