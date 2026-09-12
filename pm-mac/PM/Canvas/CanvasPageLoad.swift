import Foundation

/// Whether a load is worth telling the window about.
///
/// **A live page is not only the page you asked for.** An app shell polls, a socket reconnects, a
/// dashboard re-fetches itself every few seconds — and each of those is a real main-frame load that
/// begins and ends before anyone could read a thing about it. Reported honestly, they turned the
/// header into a metronome: Reload became Stop and back again, and the progress bar faded up and out
/// along the bottom of the address field, every few seconds, for as long as the card was open.
///
/// None of that was information. The readout has two jobs — a load *you* started, and a load that is
/// **stuck** — and both of those last. So a load has to have been going a while before the chrome says
/// anything, which is the same rule a browser follows: Safari does not flash its progress bar for a
/// load that is already over.
///
/// The card itself is never in any doubt: `CanvasLinkNodeView.isLoading` is unchanged and Stop stops
/// the load the moment the button is there. This is only about what is *said*.
enum CanvasPageLoad {
    /// **Four tenths of a second**, which is under the point where a wait starts to feel like a wait
    /// and over everything a page does to itself while you read it.
    ///
    /// Wrong in one direction only, and deliberately: a load that ends inside the threshold is never
    /// mentioned, which costs nothing, because a load nobody could see the start of is a load nobody
    /// needed a receipt for. What must never be lost is the other case — see `CanvasLinkNodeView`,
    /// which nudges the header at exactly this moment, because a *stuck* load is precisely the one
    /// that will send no further progress for anything to notice it on.
    static let worthReporting: TimeInterval = 0.4

    /// Whether a load that began at `startedAt` has been going long enough to be worth drawing.
    static func isWorthReporting(startedAt: Date?, now: Date = Date(),
                                 threshold: TimeInterval = CanvasPageLoad.worthReporting) -> Bool {
        guard let startedAt else { return false }
        return now.timeIntervalSince(startedAt) >= threshold
    }
}
