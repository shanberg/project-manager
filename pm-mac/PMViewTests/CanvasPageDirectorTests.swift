import Foundation
import PmLib
import XCTest

/// *When* the page budget is applied, which is most of what deciding it consists of.
///
/// **None of this was reachable before.** The rules themselves have had tests since they were lifted
/// into `CanvasPageBudget` — a value, so the interesting comparisons could be asserted directly. The
/// scheduling around them stayed in `CanvasBoardView` among a hundred and thirty other members, and
/// asking "does a review during a crossing become a settle" needed a board, a window, a scroll view
/// mid-flight and a web renderer. `CanvasPageDirector` sees the board through seven members and the
/// cards through ten, so both are things a test can be.
///
/// The case worth having is `testAReviewDuringACrossingIsDeferredUntilTheBoardStops`: entering a
/// workspace carries every web card across the zoom at which it would run a page, each one asks for a
/// review, and building a renderer per card in the middle of a 350ms animation was measured at
/// 165–206ms of stall.
@MainActor
final class CanvasPageDirectorTests: XCTestCase {

    // MARK: A board that is only what the director can see

    private final class Stage: CanvasPageStage {
        var pageCards: [String: CanvasPageCard] = [:]
        var onScreenCanvasRect = CanvasRect(x: 0, y: 0, width: 1000, height: 1000)
        var frames: [String: CanvasRect] = [:]
        var showsTiles = false
        var isCrossing = false
        var hasWindow = true
        var isOnScreen = true

        func frame(ofNode id: String) -> CanvasRect? { frames[id] }

        /// Put a card on the stage at `frame`, and answer with it.
        @discardableResult
        func add(_ id: String, at frame: CanvasRect = CanvasRect(x: 0, y: 0, width: 100, height: 100),
                 wants: Bool = true, isPage: Bool = true, hidden: Bool = false) -> Card {
            let card = Card(wants: wants, isPage: isPage, hidden: hidden)
            pageCards[id] = card
            frames[id] = frame
            return card
        }
    }

    private final class Card: CanvasPageCard {
        let isPageCard: Bool
        let wantsPage: Bool
        var isEngaged = false
        var isPlayingMedia = false
        var isCardHidden: Bool
        var lastVisibleAt = Date.distantPast

        /// What the director did to it.
        var live: Bool?
        var ticks = 0
        var reconsidered = 0
        var reclaimed = 0
        var staleChecks: [TimeInterval] = []

        init(wants: Bool, isPage: Bool, hidden: Bool) {
            wantsPage = wants
            isPageCard = isPage
            isCardHidden = hidden
        }

        func setPageLive(_ live: Bool) { self.live = live }
        func timePassed() { ticks += 1 }
        func reconsiderLoading() { reconsidered += 1 }
        func reclaimPage() { reclaimed += 1 }
        func reloadIfStale(after interval: TimeInterval) { staleChecks.append(interval) }
    }

    /// The main queue, held still, so "end of this turn" and "when the movement stops" are things the
    /// test decides rather than things it waits for.
    private final class Clock {
        var soonQueue: [() -> Void] = []
        var delayed: [(delay: TimeInterval, work: DispatchWorkItem)] = []

        /// Run whatever `review` scheduled for the end of the turn.
        func runTurn() {
            let pending = soonQueue
            soonQueue = []
            pending.forEach { $0() }
        }

        /// Run whatever `settle` scheduled, skipping anything since cancelled.
        func runDelayed() {
            let pending = delayed
            delayed = []
            for item in pending where !item.work.isCancelled { item.work.perform() }
        }
    }

    private var stage: Stage!
    private var clock: Clock!
    private var director: CanvasPageDirector!

    override func setUp() {
        super.setUp()
        stage = Stage()
        clock = Clock()
        director = CanvasPageDirector(stage: stage)
        director.schedule.soon = { [clock] in clock!.soonQueue.append($0) }
        director.schedule.after = { [clock] delay, work in clock!.delayed.append((delay, work)) }
    }

    override func tearDown() {
        director.schedule.stopTicking()
        super.tearDown()
    }

    // MARK: Deciding at the right moment

    /// Eight cards each deciding they would like a page, in one pass of `refreshNodeViews`, is one
    /// decision rather than eight.
    func testABurstOfReviewsIsOneDecision() {
        let card = stage.add("a")
        for _ in 0..<8 { director.review() }
        XCTAssertNil(card.live, "nothing is decided inside the pass that is still asking")

        clock.runTurn()
        XCTAssertEqual(card.live, true)
        XCTAssertEqual(card.ticks, 1, "one pass, so the card is told once that time has passed")
    }

    /// **The case this type exists for.** A review asked for mid-crossing is not answered next turn —
    /// next turn is the middle of the animation.
    func testAReviewDuringACrossingIsDeferredUntilTheBoardStops() {
        let card = stage.add("a")
        stage.isCrossing = true

        director.review()
        clock.runTurn()
        XCTAssertNil(card.live, "a review during a crossing must not land next turn")
        XCTAssertEqual(clock.delayed.count, 1, "it became a settle")

        stage.isCrossing = false
        clock.runDelayed()
        XCTAssertEqual(card.live, true)
    }

    /// Each scroll pushes the decision back, so the board acts on where you stopped rather than on
    /// everywhere you passed through.
    func testEachSettleCancelsTheOneBeforeIt() {
        stage.add("a")
        for _ in 0..<5 { director.settle() }

        let live = clock.delayed.filter { !$0.work.isCancelled }
        XCTAssertEqual(live.count, 1, "five scroll events, one pending decision")
        XCTAssertEqual(live.first?.delay, CanvasPageDirector.settleDelay)
    }

    func testNothingIsDecidedWithoutAWindow() {
        let card = stage.add("a")
        stage.hasWindow = false

        director.apply()

        XCTAssertNil(card.live, "a board with no window is not a board anyone is looking at")
    }

    // MARK: What the cards are told

    /// A card a tiled view has hidden is not on screen however central the file thinks it is.
    func testAHiddenCardIsNotOnScreenHoweverCentralItIs() {
        let hidden = stage.add("hidden", at: CanvasRect(x: 400, y: 400, width: 10, height: 10),
                               hidden: true)
        director.apply()
        XCTAssertEqual(hidden.lastVisibleAt, .distantPast,
                       "a hidden card was never drawn, so its grace period is still running")
    }

    func testACardOutsideTheWindowIsNotMarkedAsSeen() {
        let far = stage.add("far", at: CanvasRect(x: 90_000, y: 90_000, width: 10, height: 10))
        let near = stage.add("near")
        director.apply()

        XCTAssertEqual(far.lastVisibleAt, .distantPast)
        XCTAssertNotEqual(near.lastVisibleAt, .distantPast)
    }

    func testOnlyPageCardsAreGovernedAtAll() {
        let plain = stage.add("text", isPage: false)
        director.apply()
        XCTAssertNil(plain.live, "a text card has no page to be told about")
    }

    // MARK: The heartbeat

    /// It runs only while something is live, because all it does is apply the budget again.
    func testTheHeartbeatRunsOnlyWhileSomethingIsLive() {
        stage.add("a")
        director.apply()
        XCTAssertTrue(director.schedule.isTicking, "a live page needs its grace period watched")

        director.pauseEverything()
        XCTAssertFalse(director.schedule.isTicking)
    }

    func testABoardWithNothingToRunDoesNotTick() {
        stage.add("a", wants: false)
        director.apply()
        XCTAssertFalse(director.schedule.isTicking)
    }

    // MARK: Stopping

    func testPausingEverythingFreezesEveryCardAndClearsWhatIsLive() {
        let card = stage.add("a")
        director.apply()
        XCTAssertEqual(director.live, ["a"])

        director.pauseEverything()

        XCTAssertEqual(card.live, false)
        XCTAssertTrue(director.live.isEmpty)
    }

    /// Off screen with nothing playing, looking away costs the whole board — the card you are standing
    /// in as well.
    func testPausingWhileAwayFromAnOffScreenBoardFreezesEverything() {
        let card = stage.add("a")
        director.apply()
        stage.isOnScreen = false

        director.pauseWhileAway()

        XCTAssertEqual(card.live, false)
        XCTAssertTrue(director.live.isEmpty)
    }

    /// On screen, the card being worked in keeps its page. See `CanvasPageBudget.liveWhileAway`.
    func testPausingWhileAwayOnScreenSparesTheCardInUse() {
        let engaged = stage.add("engaged")
        engaged.isEngaged = true
        let other = stage.add("other")
        director.apply()

        director.pauseWhileAway()

        XCTAssertEqual(engaged.live, true, "the card you are standing in is the one to spare")
        XCTAssertEqual(other.live, false)
    }

    /// Hidden, minimised or covered, what is playing keeps playing — and nothing else is spared.
    func testPausingWhileAwayFromAnOffScreenBoardSparesWhatIsPlaying() {
        let music = stage.add("music")
        music.isPlayingMedia = true
        let engaged = stage.add("engaged")
        engaged.isEngaged = true
        director.apply()
        stage.isOnScreen = false

        director.pauseWhileAway()

        XCTAssertEqual(music.live, true)
        XCTAssertEqual(engaged.live, false, "off screen, standing in a card is not using it")
        XCTAssertEqual(director.live, ["music"])
    }

    // MARK: Refreshing

    func testStaleCardsAreCheckedAgainstTheBoardsCadence() {
        let card = stage.add("a")
        director.refreshInterval = 300

        XCTAssertEqual(card.staleChecks, [300],
                       "setting a cadence applies the budget, which is what starts the refreshing")
    }

    func testNoCadenceMeansNothingIsEverAskedToReload() {
        let card = stage.add("a")
        director.apply()
        XCTAssertTrue(card.staleChecks.isEmpty)
    }

    /// Setting the same cadence again is not a change, so it does not re-run the budget — the guard
    /// that stops a menu re-pick costing a pass over every card.
    func testSettingTheSameCadenceTwiceDecidesOnce() {
        let card = stage.add("a")
        director.refreshInterval = 300
        director.refreshInterval = 300
        XCTAssertEqual(card.staleChecks, [300])
    }

    func testAChangedCadenceIsAnnounced() {
        var announced = 0
        director.onRefreshIntervalChanged = { announced += 1 }
        director.refreshInterval = 60
        director.refreshInterval = 60
        director.refreshInterval = nil
        XCTAssertEqual(announced, 2, "two changes, one repeat")
    }

    // MARK: Settings and handover

    func testASettingsChangeAsksEveryCardToReconsiderAndThenDecides() {
        let card = stage.add("a")
        director.settingsChanged()

        XCTAssertEqual(card.reconsidered, 1,
                       "a card only reconsiders on its own when its zoom or address moves")
        XCTAssertEqual(card.live, true, "and then the budget is applied, immediately")
    }

    func testReclaimingTakesBackThePagesTheOtherTabWasRunning() {
        let card = stage.add("a")
        director.reclaim()
        XCTAssertEqual(card.reclaimed, 1)
    }
}
