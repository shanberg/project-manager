import XCTest

/// Which loads the window is told about.
///
/// A card left open on a dashboard reported a real main-frame load every few seconds — the shell
/// re-fetching itself — and the header answered each one: Reload to Stop and back, the progress bar up
/// and out along the address field. The complaint was that the chrome had become a metronome, and the
/// rule that answers it is here. See `CanvasPageLoad`.
final class CanvasPageLoadTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// Nothing loading is nothing to say.
    func testNoLoadIsNotReported() {
        XCTAssertFalse(CanvasPageLoad.isWorthReporting(startedAt: nil, now: now))
    }

    /// **The case this exists for.** A poll that is over in a fifth of a second is never mentioned; a
    /// receipt for it is a flash and nothing else.
    func testALoadThatIsOverBeforeYouCouldReadItIsNotReported() {
        XCTAssertFalse(CanvasPageLoad.isWorthReporting(startedAt: now.addingTimeInterval(-0.05), now: now))
        XCTAssertFalse(CanvasPageLoad.isWorthReporting(startedAt: now.addingTimeInterval(-0.2), now: now))
        XCTAssertFalse(CanvasPageLoad.isWorthReporting(startedAt: now.addingTimeInterval(-0.39), now: now))
    }

    /// And the two cases the readout is actually for — a load you started, and a load that is stuck —
    /// both of which last.
    ///
    /// Either side of the threshold rather than exactly on it: `Date` arithmetic lands a hair under a
    /// literal 0.4, and a test that depended on which side of a float the boundary fell on would be
    /// asserting something nobody means.
    func testALoadThatLastsIsReported() {
        XCTAssertTrue(CanvasPageLoad.isWorthReporting(startedAt: now.addingTimeInterval(-0.41), now: now))
        XCTAssertTrue(CanvasPageLoad.isWorthReporting(startedAt: now.addingTimeInterval(-2), now: now))
        XCTAssertTrue(CanvasPageLoad.isWorthReporting(startedAt: now.addingTimeInterval(-90), now: now))
    }

    /// The threshold is a tenth of the time a person waits before wondering, not a tenth of a second:
    /// pinned so that dropping it back to nothing has to be done on purpose.
    func testTheThresholdIsLongEnoughToCoverAPollAndShortEnoughToBeInvisible() {
        XCTAssertGreaterThanOrEqual(CanvasPageLoad.worthReporting, 0.25)
        XCTAssertLessThanOrEqual(CanvasPageLoad.worthReporting, 0.75)
    }
}
