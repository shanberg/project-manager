import XCTest
@testable import PMViewTests

/// Which cards get to run a page.
///
/// The rule is a comparison between cards, so it is a value rather than a method on a view — which
/// means the interesting cases (more of the board on screen than the budget covers, a card you are
/// using while the board is zoomed out) can be asserted directly instead of through a window and a
/// scroll position.
final class CanvasPageBudgetTests: XCTestCase {
    /// A card that wants to run, `distance` points from the middle of the window.
    private func card(_ id: String, distance: Double, visible: Bool = true,
                      engaged: Bool = false, wants: Bool = true,
                      goneFor: Double = 0, playing: Bool = false,
                      kept: Bool = false) -> CanvasPageBudget.Candidate {
        .init(id: id, wantsPage: wants, isVisible: visible, isEngaged: engaged,
              distanceFromCentre: distance, secondsSinceVisible: goneFor, isPlaying: playing,
              keepsRunning: kept)
    }

    /// Backlog 26: a card set to keep running is past the clock and over the budget, like music — off
    /// screen for an hour, it still beats a card in the middle of the window.
    func testACardKeptRunningIsLivePastTheGraceAndOverTheBudget() {
        let cards = [card("near", distance: 10), card("dashboard", distance: 0, visible: false,
                                                       goneFor: 3600, kept: true)]
        XCTAssertEqual(CanvasPageBudget.live(among: cards, budget: 1, grace: 60), ["dashboard"])
        XCTAssertEqual(CanvasPageBudget.live(among: cards, budget: 0, grace: 60), ["dashboard"],
                       "over the budget, too")
        XCTAssertEqual(CanvasPageBudget.liveWhileTiled(among: cards, budget: 1, grace: 60),
                       ["near", "dashboard"])
    }

    /// …but not past the zoom: a board zoomed out too far to draw pages runs none of them.
    func testACardKeptRunningStillNeedsToWantItsPage() {
        let cards = [card("dashboard", distance: 0, wants: false, kept: true)]
        XCTAssertEqual(CanvasPageBudget.live(among: cards), [])
        XCTAssertEqual(CanvasPageBudget.liveWhileAway(among: cards, onScreen: false), [])
    }

    func testAQuietBoardRunsEverythingOnScreen() {
        let cards = (0..<5).map { card("\($0)", distance: Double($0) * 100) }
        XCTAssertEqual(CanvasPageBudget.live(among: cards).count, 5)
    }

    /// The complaint this rule exists for: panning is how you read a board, and a page that died the
    /// moment it crossed the edge of the window made you think about where the edge was.
    func testPanningPastACardDoesNotCostYouIt() {
        let live = CanvasPageBudget.live(among: [card("here", distance: 10),
                                                card("justPast", distance: 4000, visible: false,
                                                     goneFor: 4)])
        XCTAssertEqual(live, ["here", "justPast"], "there is room for both, so both keep running")
    }

    /// And a good deal longer than ninety seconds, which is what it used to be: shorter than the gap
    /// between two glances at the same dashboard, so a card was frozen on a board with slots going
    /// spare. Ten minutes off screen is still a card you are using.
    func testACardYouPannedPastMinutesAgoKeepsItsSlot() {
        let live = CanvasPageBudget.live(among: [card("here", distance: 10),
                                                 card("earlier", distance: 4000, visible: false,
                                                      goneFor: 9 * 60)],
                                         grace: CanvasPageBudget.defaultOffScreenGrace)
        XCTAssertEqual(live, ["here", "earlier"], "inside the timeout, and there is room for both")
    }

    /// The far end of it. Past the timeout a card gives its slot up whether or not anything is waiting
    /// for it — that is the point of a timeout rather than a queue position, and it is what stops a
    /// board you wandered away from holding its pages all afternoon.
    func testACardLeftFarBehindGivesUpItsSlotEvenWithRoomToSpare() {
        let live = CanvasPageBudget.live(among: [card("here", distance: 10),
                                                 card("longGone", distance: 4000, visible: false,
                                                      goneFor: 11 * 60)],
                                         grace: CanvasPageBudget.defaultOffScreenGrace)
        XCTAssertEqual(live, ["here"])
    }

    /// Never is a real answer, and the one that says nothing but the count should ever pause a card.
    func testTheTimeoutCanBeTurnedOff() {
        let live = CanvasPageBudget.live(among: [card("here", distance: 10),
                                                 card("longGone", distance: 4000, visible: false,
                                                      goneFor: 6 * 60 * 60)],
                                         grace: .infinity)
        XCTAssertEqual(live, ["here", "longGone"])
    }

    /// The other thing that takes a slot away, well inside the timeout: there simply isn't one.
    func testTheLimitCullsInsideTheTimeout() {
        var cards = (0..<3).map { card("onScreen\($0)", distance: Double($0) * 100) }
        cards.append(card("gone", distance: 4000, visible: false, goneFor: 10))
        XCTAssertEqual(CanvasPageBudget.live(among: cards, budget: 4).count, 4)
        XCTAssertFalse(CanvasPageBudget.live(among: cards, budget: 3).contains("gone"),
                       "three slots, three cards on screen, and the one off it is fourth in line")
    }

    /// Under pressure the window wins. A card you can see is worth more than a card you saw.
    func testWhatIsOnScreenTakesTheSlotsFirst() {
        var cards = (0..<8).map { card("onScreen\($0)", distance: Double($0) * 100) }
        cards.append(card("recent", distance: 5000, visible: false, goneFor: 1))
        let live = CanvasPageBudget.live(among: cards, budget: 8)
        XCTAssertEqual(live.count, 8)
        XCTAssertFalse(live.contains("recent"), "eight on screen leaves nothing for one off it")
    }

    /// And among the ones off screen, the one you left most recently is the one you are likeliest to
    /// come back to.
    func testTheMostRecentlySeenKeepsItsSlot() {
        var cards = (0..<6).map { card("onScreen\($0)", distance: Double($0) * 100) }
        cards.append(card("left5s", distance: 5000, visible: false, goneFor: 5))
        cards.append(card("left50s", distance: 5000, visible: false, goneFor: 50))
        cards.append(card("left80s", distance: 5000, visible: false, goneFor: 80))
        let live = CanvasPageBudget.live(among: cards, budget: 8)
        XCTAssertTrue(live.contains("left5s"))
        XCTAssertTrue(live.contains("left50s"))
        XCTAssertFalse(live.contains("left80s"), "two slots left, and it was third in line")
    }

    func testTheBudgetKeepsWhatIsNearestTheMiddle() {
        // Twelve cards on screen — what zooming out on a dashboard looks like.
        let cards = (0..<12).map { card("card\($0)", distance: Double($0) * 100) }
        let live = CanvasPageBudget.live(among: cards, budget: 8)
        XCTAssertEqual(live.count, 8)
        XCTAssertTrue(live.contains("card0"))
        XCTAssertTrue(live.contains("card7"), "the eighth nearest still makes it")
        XCTAssertFalse(live.contains("card8"), "the ninth is where the board stops paying")
    }

    /// The card under your pointer is the one case where the budget doesn't get a say.
    func testACardYouAreUsingStaysLive() {
        var cards = (0..<12).map { card("card\($0)", distance: Double($0) * 100) }
        cards[11].isEngaged = true
        let live = CanvasPageBudget.live(among: cards, budget: 8)
        XCTAssertTrue(live.contains("card11"), "furthest from the middle, but you are using it")
        XCTAssertEqual(live.count, 8)
    }

    func testACardYouAreUsingStaysLiveEvenOffScreen() {
        let live = CanvasPageBudget.live(among: [card("held", distance: 9000, visible: false,
                                                      engaged: true)])
        XCTAssertEqual(live, ["held"], "engaged wins over out of frame")
    }

    /// Zoomed out past the point a page is worth drawing, no card wants one — so nothing runs, budget
    /// or no budget.
    func testACardThatDoesNotWantAPageNeverGetsOne() {
        let cards = (0..<3).map { card("\($0)", distance: 0, wants: false) }
        XCTAssertTrue(CanvasPageBudget.live(among: cards).isEmpty)
    }

    /// A tiling is a set of cards you named, all on screen at once. The budget's guess about which of
    /// them you would miss has nothing left to decide, and a frozen tile is a picture of a page in a
    /// view whose whole purpose is several live ones.
    func testATiledViewRunsEveryTile() {
        let tiles = (0..<12).map { card("tile\($0)", distance: Double($0) * 100) }
        XCTAssertEqual(CanvasPageBudget.liveWhileTiled(among: tiles, budget: 8).count, 12,
                       "twelve tiles, twelve pages — the budget does not apply here")
    }

    /// And what it hid is not thrown away. Entering a workspace used to freeze the whole rest of the
    /// board at once — every page you had going, gone, and a wait for them all when you came back out.
    /// Being hidden by a tiling is the same fact as being off screen, and takes the same leftovers.
    func testATilingKeepsTheCardsItPutAwayWarm() {
        let live = CanvasPageBudget.liveWhileTiled(among: [card("tiled", distance: 0),
                                                           card("hidden", distance: 0, visible: false,
                                                                goneFor: 1)],
                                                   budget: 8)
        XCTAssertEqual(live, ["tiled", "hidden"], "one tile on a budget of eight leaves room to spare")
    }

    /// Warm for a while, not forever. A workspace you have been sitting in for half an hour is a view
    /// you have settled into, and the board behind it is on the same clock as anything else off screen.
    func testASettledTilingIsBackToJustItsTiles() {
        let live = CanvasPageBudget.liveWhileTiled(among: [card("tiled", distance: 0),
                                                           card("hidden", distance: 0, visible: false,
                                                                goneFor: 30 * 60)],
                                                   budget: 8,
                                                   grace: CanvasPageBudget.defaultOffScreenGrace)
        XCTAssertEqual(live, ["tiled"])
    }

    /// The leftovers are leftovers, though: the tiles are served first and are not counted out.
    func testATilingPastTheLimitLeavesNothingForWhatItHid() {
        var cards = (0..<10).map { card("tile\($0)", distance: Double($0) * 100) }
        cards.append(card("hidden", distance: 0, visible: false, goneFor: 1))
        let live = CanvasPageBudget.liveWhileTiled(among: cards, budget: 8)
        XCTAssertEqual(live.count, 10, "ten tiles run on a budget of eight — you named them")
        XCTAssertFalse(live.contains("hidden"))
    }

    /// Among the hidden ones it is the same queue as anywhere else: most recently seen first.
    func testATilingKeepsTheCardsYouSawMostRecently() {
        let live = CanvasPageBudget.liveWhileTiled(among: [card("tiled", distance: 0),
                                                           card("just", distance: 0, visible: false,
                                                                goneFor: 2),
                                                           card("older", distance: 0, visible: false,
                                                                goneFor: 200)],
                                                   budget: 2)
        XCTAssertEqual(live, ["tiled", "just"])
    }

    /// Two cards the same distance from the middle must not swap places on every scroll — each swap
    /// would be a renderer killed and a renderer started.
    func testTheAnswerIsStableWhenTwoCardsTie() {
        let tied = (0..<10).map { card("card\($0)", distance: 500) }
        let once = CanvasPageBudget.live(among: tied, budget: 8)
        XCTAssertEqual(once, CanvasPageBudget.live(among: tied.reversed(), budget: 8))
        XCTAssertEqual(once.count, 8)
    }

    // MARK: The number itself

    /// Unset, it is the eight the number has always been — so nobody's board changes because the
    /// setting arrived.
    func testTheLimitDefaultsToEight() {
        UserDefaults.standard.removeObject(forKey: CanvasPageBudget.defaultsKey)
        XCTAssertEqual(CanvasPageBudget.livePages, 8)
        XCTAssertEqual(CanvasPageBudget.livePages, CanvasPageBudget.defaultLivePages)
    }

    /// The whole cost of a board is now this one number, so a value typed straight into the defaults
    /// database is clamped rather than believed. Four hundred renderers is not a setting.
    func testTheLimitIsClampedToWhatAMachineCanCarry() {
        defer { UserDefaults.standard.removeObject(forKey: CanvasPageBudget.defaultsKey) }
        UserDefaults.standard.set(400, forKey: CanvasPageBudget.defaultsKey)
        XCTAssertEqual(CanvasPageBudget.livePages, CanvasPageBudget.allowed.upperBound)
        UserDefaults.standard.set(0, forKey: CanvasPageBudget.defaultsKey)
        XCTAssertEqual(CanvasPageBudget.livePages, CanvasPageBudget.allowed.lowerBound)
    }

    /// Unset, ten minutes — long enough that moving around a board is free, short enough to be a
    /// ceiling on a board nobody has looked at since lunch.
    func testTheTimeoutDefaultsToTenMinutes() {
        UserDefaults.standard.removeObject(forKey: CanvasPageBudget.graceDefaultsKey)
        XCTAssertEqual(CanvasPageBudget.offScreenGrace, 10 * 60)
    }

    /// Zero is how "never" is stored, because `@AppStorage` wants a number — and it has to come back
    /// as something every `secondsSinceVisible <` comparison can be written against unchanged.
    func testNeverIsStoredAsZeroAndReadAsForever() {
        defer { UserDefaults.standard.removeObject(forKey: CanvasPageBudget.graceDefaultsKey) }
        UserDefaults.standard.set(0.0, forKey: CanvasPageBudget.graceDefaultsKey)
        XCTAssertEqual(CanvasPageBudget.offScreenGrace, .infinity)
    }

    func testTheTimeoutIsWhatTheSettingSays() {
        defer { UserDefaults.standard.removeObject(forKey: CanvasPageBudget.graceDefaultsKey) }
        UserDefaults.standard.set(60.0, forKey: CanvasPageBudget.graceDefaultsKey)
        let live = CanvasPageBudget.live(among: [card("here", distance: 10),
                                                 card("gone", distance: 4000, visible: false,
                                                      goneFor: 90)])
        XCTAssertEqual(live, ["here"], "a minute, and it has been gone for a minute and a half")
    }

    func testTheLimitIsWhatTheSettingSays() {
        defer { UserDefaults.standard.removeObject(forKey: CanvasPageBudget.defaultsKey) }
        UserDefaults.standard.set(3, forKey: CanvasPageBudget.defaultsKey)
        let cards = (0..<10).map { card("card\($0)", distance: Double($0) * 100) }
        XCTAssertEqual(CanvasPageBudget.live(among: cards).count, 3)
    }

    // MARK: Looking away

    /// The bug this rule exists for. Clicking another window is not finishing with a card, and the
    /// idle pause used to take every page on the board regardless — including the one being typed
    /// into. Waking it restores where the page had got to and not what it was holding, and the
    /// snapshot means it still looks right, so the loss is silent.
    func testLookingAwayKeepsTheCardYouAreStandingIn() {
        let live = CanvasPageBudget.liveWhileAway(among: [card("typing", distance: 0, engaged: true),
                                                          card("beside", distance: 200),
                                                          card("away", distance: 4000, visible: false)],
                                                  onScreen: true)
        XCTAssertEqual(live, ["typing"], "the rest of the board pauses; this one does not")
    }

    /// Nothing is engaged, so looking away costs the whole board — which is what the timer is for.
    func testLookingAwayFromABoardNobodyIsInPausesAllOfIt() {
        let cards = (0..<5).map { card("\($0)", distance: Double($0) * 100) }
        XCTAssertTrue(CanvasPageBudget.liveWhileAway(among: cards, onScreen: true).isEmpty)
    }

    /// Hidden, minimised or completely covered is not "in the middle of using it".
    func testOffScreenPausesEvenTheEngagedCard() {
        let live = CanvasPageBudget.liveWhileAway(among: [card("typing", distance: 0, engaged: true)],
                                                  onScreen: false)
        XCTAssertTrue(live.isEmpty)
    }

    /// A card that has stopped wanting a page — zoomed out past the threshold, or with no address —
    /// has no renderer to spare, engaged or not.
    func testACardWithNoPageIsNotSpared() {
        let live = CanvasPageBudget.liveWhileAway(among: [card("empty", distance: 0, engaged: true,
                                                               wants: false)],
                                                  onScreen: true)
        XCTAssertTrue(live.isEmpty)
    }

    // MARK: Playing

    /// The complaint: music stopped once the window went behind something. Playing is using, so a
    /// playing card is spared wherever a card you are standing in is — and off screen as well.
    func testLookingAwayKeepsWhatIsPlayingEvenOffScreen() {
        let cards = [card("music", distance: 4000, visible: false, playing: true),
                     card("typing", distance: 0, engaged: true),
                     card("idle", distance: 100)]
        XCTAssertEqual(CanvasPageBudget.liveWhileAway(among: cards, onScreen: false), ["music"])
        XCTAssertEqual(CanvasPageBudget.liveWhileAway(among: cards, onScreen: true), ["music", "typing"])
    }

    /// The timeout is for pages nobody is getting anything from, and a playing page is not one.
    func testSomethingPlayingKeepsItsSlotPastTheTimeout() {
        let live = CanvasPageBudget.live(among: [card("here", distance: 10),
                                                 card("music", distance: 4000, visible: false,
                                                      goneFor: 11 * 60, playing: true)],
                                         grace: CanvasPageBudget.defaultOffScreenGrace)
        XCTAssertEqual(live, ["here", "music"])
    }

    /// And behind a tiling, which queues the cards it hid on the same clock.
    func testATilingKeepsWhatIsPlayingBehindIt() {
        let live = CanvasPageBudget.liveWhileTiled(among: [card("tile", distance: 0),
                                                           card("music", distance: 4000, visible: false,
                                                                goneFor: 11 * 60, playing: true)],
                                                   grace: CanvasPageBudget.defaultOffScreenGrace)
        XCTAssertEqual(live, ["tile", "music"])
    }

    /// Playing does not make a page out of nothing: a card that no longer wants one has none to keep.
    func testPlayingDoesNotKeepACardThatWantsNoPage() {
        let live = CanvasPageBudget.liveWhileAway(among: [card("gone", distance: 0, wants: false,
                                                               playing: true)],
                                                  onScreen: false)
        XCTAssertTrue(live.isEmpty)
    }
}
