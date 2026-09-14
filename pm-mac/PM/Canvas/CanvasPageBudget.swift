import Foundation

/// How many live web pages a board is allowed to be running at once, and which ones they are.
///
/// A dashboard board is a dozen or more embeds — Jira, Slack, a saved search — and every one of them
/// that is live is a renderer process with its own memory, its own timers and its own network. Left
/// ungoverned that is a board which costs more the more useful it is, and the cost lands on the
/// machine you are trying to work on.
///
/// So a board runs at most `livePages` of them and freezes the rest. Freezing is meant to be
/// invisible: a paused card keeps a picture of the page it was showing, so a board of frozen cards
/// still looks like a board of pages rather than a board of globes, and it wakes up when you look
/// back at it.
///
/// **Two numbers bound the cost, and both are yours to set**: how many pages run at once, and how long
/// one goes on running after you have stopped looking at it. Everything else — where the card is, how
/// far from the middle, whether a tiling is covering it — only decides *who* gives up a slot when more
/// cards want one than there are slots. So a board keeps a good deal more alive than it is showing, and
/// you stop having to think about where the edge of the window is.
///
/// The timeout is a *ceiling on waste*, not a way of trimming the board. It was ninety seconds once,
/// which is shorter than the gap between two glances at the same dashboard: panning is how you read a
/// board, and a page that died while you looked at the other end of it made you think about where the
/// edge of the window was. Ten minutes is past the point where you are still using a card and well
/// short of a board you wandered off from before lunch holding a gigabyte all afternoon.
///
/// **The board decides, not the card.** A card can only say that it is ready to run — it is zoomed in
/// far enough, it has an address, you have stepped into it — and the board answers, because the
/// question is a comparison between cards and no card can see the others. That is also what keeps the
/// answer testable: this is a value in, a set out, with no views in sight.
enum CanvasPageBudget {
    /// The number of pages a board keeps live.
    ///
    /// Eight is chosen from what a board is *for*: a dashboard you are reading has a region under your
    /// eye — the cards you can see at a readable zoom — and eight covers that region on a normal window
    /// while staying well short of the point where the renderers make the machine noticeable. It is a
    /// per-board number, and boards you are not looking at give theirs up on a timer, so the total is
    /// bounded by the board in front of you rather than by how many you have ever opened.
    static let defaultLivePages = 8

    /// What a page actually costs, which is the reason this has an upper end at all: a real page's
    /// renderer is tens to a few hundred megabytes, so the difference between 8 and 24 is measured in
    /// gigabytes on a busy board. The low end is 1 rather than 0 because a board that runs nothing is
    /// what the web-cards switch is for.
    static let allowed = 1...24

    static let defaultsKey = "PMCanvasLivePages"

    /// How long a page goes on running after it has left the window — or `nil` for as long as the
    /// limit above allows, which is the position that nothing but the count should ever pause a card.
    ///
    /// Coarse on purpose, like the refresh cadence: this is "how long after I stop looking is it still
    /// worth having ready", and nobody answers that in units of one minute.
    static let graceChoices: [TimeInterval] = [60, 5 * 60, 10 * 60, 30 * 60, 60 * 60]

    static let defaultOffScreenGrace: TimeInterval = 10 * 60

    static let graceDefaultsKey = "PMCanvasOffScreenGrace"

    /// Zero is the stored form of never, because `@AppStorage` wants a number and a picker wants a tag.
    /// It comes back as `.infinity`, so every comparison downstream is the same comparison.
    static var offScreenGrace: TimeInterval {
        guard let stored = UserDefaults.standard.object(forKey: graceDefaultsKey) as? Double else {
            return defaultOffScreenGrace
        }
        return stored > 0 ? stored : .infinity
    }

    /// Posted when the number changes, so boards already open re-decide rather than waiting for the
    /// next scroll. Nothing about a settings flip looks like the events the budget normally reacts to.
    static let didChange = Notification.Name("PMCanvasPageBudgetDidChange")

    /// How many pages this Mac keeps live. Clamped on read, so a number typed into `defaults write`
    /// cannot ask a board for four hundred renderers.
    static var livePages: Int {
        guard let stored = UserDefaults.standard.object(forKey: defaultsKey) as? Int else {
            return defaultLivePages
        }
        return min(max(allowed.lowerBound, stored), allowed.upperBound)
    }

    /// Say a setting moved. The pane writes the values itself — through `@AppStorage`, like every
    /// other switch in Settings — and this is how the boards already open hear about it.
    static func changed() { NotificationCenter.default.post(name: didChange, object: nil) }

    /// One card, as the budget sees it.
    struct Candidate: Equatable {
        let id: String
        /// The card is ready to run a page: it has an address, embedding is on, and the board is
        /// zoomed in far enough for a page to be worth drawing.
        var wantsPage: Bool
        /// Any part of the card is in the window.
        var isVisible: Bool
        /// You have stepped into it and are using it.
        var isEngaged: Bool
        /// How far the card's middle is from the middle of what you are looking at, in canvas points.
        var distanceFromCentre: Double
        /// How long since the card was last in the window. Zero while it is.
        var secondsSinceVisible: Double = 0
        /// The page is playing something — a video, a stream, music.
        var isPlaying = false

        /// Whether somebody is using this card, looking at it or not: stepped into it, or listening to
        /// it. A page that is playing is a page you would notice stopping, which is all "in use" means
        /// to the budget — and playing is the one kind of use that carries on with the window hidden.
        var isInUse: Bool { isEngaged || isPlaying }
    }

    /// Which cards get to be live. Everything else pauses.
    ///
    /// **Leaving the window is not what takes a page away** — the budget is, and then only when more
    /// cards want a slot than there are slots. Being off screen is mostly a ranking, so panning across
    /// a board is free and a card you scrolled past is still running when you scroll back. `grace` is
    /// the far end of that: past it a card has stopped being something you are in the middle of and
    /// gives its slot up whether or not anything is waiting for it.
    ///
    /// In order:
    ///
    /// 1. **A card you are using is always live**, budget or no budget, on screen or off — stepped into,
    ///    or playing. Freezing the page under someone's pointer to save a renderer is a trade nobody
    ///    would take, and neither is stopping the music.
    /// 2. **What's on screen, nearest the middle first.** When more of the board is visible than the
    ///    budget covers — which is what zooming out means — the cards at the centre are the ones being
    ///    looked at and the ones at the edges are about to be scrolled away.
    /// 3. **Then what you were looking at most recently**, out to `grace`. A card only loses its slot
    ///    to a card you can actually see, or to one you saw more recently — or to the clock.
    static func live(among cards: [Candidate], budget: Int = livePages,
                     grace: TimeInterval = offScreenGrace) -> Set<String> {
        let wanting = cards.filter(\.wantsPage)
        var chosen = Set(wanting.filter(\.isInUse).map(\.id))
        let waiting = wanting.filter { !$0.isInUse }
        for card in nearestFirst(waiting) + mostRecentlySeen(waiting, within: grace)
            where chosen.count < budget {
            chosen.insert(card.id)
        }
        return chosen
    }

    /// Which cards run in a tiled view: every tile, and then the budget's leftovers.
    ///
    /// **Every tile runs, and never mind the budget.** The budget exists because a board is larger than
    /// the window and most of what is on it is not being looked at — so it is a guess, made from
    /// distance and from how long ago you last saw a card, about which pages you would miss. A tiling
    /// answers that question outright. You named the cards; the window is showing every one of them, in
    /// full, at once, because that is what tiling *is*. There is nothing here for the guess to do, and
    /// getting it wrong costs more than usual: a frozen tile is a page that has stopped updating and a
    /// click that lands on a picture of a page, in the one view whose whole purpose is several live
    /// things side by side.
    ///
    /// **The cards it hid are not thrown away.** They used to be — a tiling froze the rest of the board
    /// outright, which made entering a workspace a way to lose every page you had going and leaving it
    /// a wait while they all came back. Being hidden by a tiling is the same fact as being off screen,
    /// and it is answered the same way, `grace` and all: they queue by how recently you saw them, take
    /// whatever slots the tiles left, and time out on the same clock. A tiling of four, on a budget of
    /// eight, keeps four of them warm — and a workspace you have been in for half an hour is back to
    /// just its tiles, which is the right answer for a view you have plainly settled into.
    static func liveWhileTiled(among cards: [Candidate], budget: Int = livePages,
                               grace: TimeInterval = offScreenGrace) -> Set<String> {
        let wanting = cards.filter(\.wantsPage)
        var chosen = Set(wanting.filter { $0.isVisible || $0.isInUse }.map(\.id))
        let hidden = wanting.filter { !$0.isVisible && !$0.isInUse }
        for card in mostRecentlySeen(hidden, within: grace) where chosen.count < budget {
            chosen.insert(card.id)
        }
        return chosen
    }

    /// Which cards keep running once you have looked away — the window is no longer the key one, but
    /// PM is still on screen.
    ///
    /// **The card you are standing in, what is playing, and nothing else.** The idle pause exists because a board left
    /// behind your work is renderers that are all cost and no benefit, and that is true of every card
    /// on it *except* the one you had stepped into. Freezing that one is the trade rule one of
    /// `live(among:)` already refuses to make, and it costs more here than under the budget: waking a
    /// card builds a new web view and restores it from `interactionState`, which restores where the
    /// page had got to and not what it was holding. A form half filled in, a sign-in waiting on a
    /// code — anything the page kept in memory rather than in its address is gone. The snapshot is
    /// what makes that unforgivable rather than merely annoying: the card goes on looking exactly as
    /// you left it while being none of it.
    ///
    /// **On screen is the whole condition, for the card you are standing in.** Hidden, minimised or
    /// completely covered, PM is not something you are in the middle of looking at, and the pause takes
    /// that card with the rest — that is what the timer is for. Visible but not key is the case this
    /// exists for, and it is the ordinary one: a board sitting beside the window you are typing in is
    /// still a board you are working with.
    ///
    /// **What is playing is spared either way.** Music is the case that asked: a window put behind
    /// another so you can get on with something is exactly the window whose sound you still want, and a
    /// video frozen mid-sentence is a page anybody would notice stopping. Hiding PM is not asking it to
    /// go quiet; pausing the player is, and the page says so the next time it is asked.
    static func liveWhileAway(among cards: [Candidate], onScreen: Bool) -> Set<String> {
        Set(cards.filter { $0.wantsPage && ($0.isPlaying || (onScreen && $0.isEngaged)) }.map(\.id))
    }

    // MARK: Who gives up a slot first

    // Ties broken by id throughout, so a board with two cards equally far out settles on the same
    // answer every time rather than swapping which one is live on each scroll — and every swap is a
    // renderer killed and a renderer started.

    private static func nearestFirst(_ cards: [Candidate]) -> [Candidate] {
        cards.filter(\.isVisible)
            .sorted { ($0.distanceFromCentre, $0.id) < ($1.distanceFromCentre, $1.id) }
    }

    private static func mostRecentlySeen(_ cards: [Candidate],
                                         within grace: TimeInterval) -> [Candidate] {
        cards.filter { !$0.isVisible && $0.secondsSinceVisible < grace }
            .sorted { ($0.secondsSinceVisible, $0.id) < ($1.secondsSinceVisible, $1.id) }
    }
}
