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
    static let livePages = 8

    /// How long a page goes on running after it has left the window.
    ///
    /// Long, and that is the point. Panning and zooming are how you *read* a board — you move about it
    /// constantly and without thinking, and the earlier version of this pausing a page the moment it
    /// crossed the edge of the window meant every pan cost you the thing you had just been looking at.
    /// The budget is what bounds the cost; time off screen only decides who gives up a slot *first*
    /// when the budget is under pressure, and a page nobody has been near for a minute and a half is a
    /// fair answer to that question.
    static let offFrameGrace: TimeInterval = 90

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
    }

    /// Which cards get to be live. Everything else pauses.
    ///
    /// The budget is the only thing that actually takes a page away. Leaving the window does not —
    /// it only decides the order in which slots are given up when there aren't enough to go round, so
    /// that panning across a board is free and you never have to think about where the edge is.
    ///
    /// In order:
    ///
    /// 1. **A card you are using is always live**, budget or no budget, on screen or off. Freezing the
    ///    page under someone's pointer to save a renderer is a trade nobody would take.
    /// 2. **What's on screen, nearest the middle first.** When more of the board is visible than the
    ///    budget covers — which is what zooming out means — the cards at the centre are the ones being
    ///    looked at and the ones at the edges are about to be scrolled away.
    /// 3. **Then what you were looking at most recently**, out to `offFrameGrace`. This is the rule
    ///    that makes panning free: a card you scrolled past a moment ago is still running when you
    ///    scroll back, and it only loses its slot to a card you can actually see.
    static func live(among cards: [Candidate], budget: Int = livePages,
                     grace: TimeInterval = offFrameGrace) -> Set<String> {
        let wanting = cards.filter(\.wantsPage)
        var chosen = Set(wanting.filter(\.isEngaged).map(\.id))

        // Ties broken by id throughout, so a board with two cards equally far out settles on the same
        // answer every time rather than swapping which one is live on each scroll — and every swap is
        // a renderer killed and a renderer started.
        let onScreen = wanting.filter { $0.isVisible && !$0.isEngaged }
            .sorted { ($0.distanceFromCentre, $0.id) < ($1.distanceFromCentre, $1.id) }
        let justLeft = wanting.filter { !$0.isVisible && !$0.isEngaged && $0.secondsSinceVisible < grace }
            .sorted { ($0.secondsSinceVisible, $0.id) < ($1.secondsSinceVisible, $1.id) }

        for card in onScreen + justLeft where chosen.count < budget { chosen.insert(card.id) }
        return chosen
    }
}
