import AppKit
import Foundation
import PmLib

/// A card, as the page director sees one.
///
/// Deliberately not `CanvasNodeView`. Everything the director does to a card is on this list, and a
/// list of ten is something a test can be — which is the difference between the decisions below
/// being checkable and needing a board, a window, a scroll view and a web renderer to ask a question
/// about a timer. `CanvasNodeView` conforms; the three page-only methods are no-ops on it and
/// overridden by `CanvasLinkNodeView`.
@MainActor
protocol CanvasPageCard: AnyObject {
    /// Whether the budget governs this card at all. Only web cards say yes.
    var isPageCard: Bool { get }
    /// Whether the card is ready to run a page. A card only ever asks; the director decides.
    var wantsPage: Bool { get }
    /// Whether somebody is working in it — an engaged card keeps its page whatever the budget says.
    var isEngaged: Bool { get }
    /// Hidden by a tiled view, which is not the same as being off screen and has to beat it.
    var isCardHidden: Bool { get }
    /// When the card was last drawn. Written by the director, read by the budget.
    var lastVisibleAt: Date { get set }

    func setPageLive(_ live: Bool)
    func timePassed()
    func reconsiderLoading()
    func reclaimPage()
    func reloadIfStale(after interval: TimeInterval)
}

/// What the page director is allowed to see of the board.
///
/// **The point of this being a protocol is what it leaves out.** `CanvasBoardView` has 136 members,
/// all of them `internal` because an extension in another file cannot see `private`, so anything
/// holding the board can reach all of it. Seven members is what deciding which pages run actually
/// needs, and a director that can only see seven cannot come to depend on the other hundred and
/// twenty-nine. It is also what makes the decisions below testable without a board, a window, or a
/// web renderer.
@MainActor
protocol CanvasPageStage: AnyObject {
    /// The cards currently built, by id. Ones far enough off screen to have been dropped are
    /// missing — see `refreshNodeViews`.
    var pageCards: [String: CanvasPageCard] { get }

    /// The part of the canvas on screen right now, in canvas coordinates.
    var onScreenCanvasRect: CanvasRect { get }

    /// Where a card sits, in canvas coordinates. Nil when the id names no node in the document.
    func frame(ofNode id: String) -> CanvasRect?

    /// A tiled view runs every tile — see `CanvasPageBudget.liveWhileTiled`.
    var showsTiles: Bool { get }

    /// A fade still travelling, or the view still flying to a zoom. A decision taken mid-crossing is
    /// a decision about where the board isn't yet.
    var isCrossing: Bool { get }

    /// Whether the board is in a window at all, and whether that window is actually in front of
    /// somebody — not hidden, not minimised, not entirely behind something else.
    var hasWindow: Bool { get }
    var isOnScreen: Bool { get }
}

/// Decides which of a board's web cards are running a renderer, and when to decide it again.
///
/// **`CanvasPageBudget` answers the question; this one asks it at the right moments.** That split
/// already existed and the second half had nowhere to live, so it sat in `CanvasBoardView` as six
/// stored properties and eleven methods among a hundred and thirty others — next to the grid fade, the
/// drop mark and the tracking area, none of which have anything to do with it.
///
/// Three moments, and they are different on purpose:
///
///   * **now** (`apply`) — a setting changed, or a card was handed back from another tab. A deliberate
///     act, answered immediately.
///   * **end of this turn** (`review`) — a card decided it would like a page. Eight cards deciding
///     that in one pass of `refreshNodeViews` is one decision, not eight.
///   * **when the movement stops** (`settle`) — a scroll or a zoom. Applying a budget on every frame
///     of a gesture would start and kill renderers the whole way, which is the most expensive
///     possible response to a gesture that has not finished saying what it wants.
///
/// A review *during* a crossing is downgraded to a settle, which is the case the settling was written
/// for and the one place it was being routed around: entering a workspace takes the board to 100%,
/// carrying every web card across `pagesLoadAbove`, and each one asks for a review — landing next
/// turn, mid-animation, building a renderer per card while the tiles are trying to fly. Measured at
/// 165–206ms in a single synchronous pass, inside a 350ms movement.
@MainActor
final class CanvasPageDirector {
    private weak var stage: CanvasPageStage?

    init(stage: CanvasPageStage) {
        self.stage = stage
    }

    // MARK: What is live

    /// The cards running a page. Kept only so a change can be logged once rather than on every settle.
    private(set) var live: Set<String> = []

    /// How often this board's pages reload themselves, or nil for never.
    ///
    /// **A dashboard is a thing you leave up.** The board already knows how old each page is — it says
    /// so in the header for the card you are in — and until this did nothing whatever about it: a wall
    /// of tickets left open since the morning is a wall of tickets as they were in the morning,
    /// indistinguishable from how they are now. Off by default, because a page reloading itself is a
    /// network call you didn't ask for and some pages cost real money to fetch.
    ///
    /// Per board rather than per card, and per board rather than app-wide: the cadence belongs to the
    /// thing being watched. Kept in `CanvasViewMemory` with the rest of how you were looking at this
    /// board, which is also why it is not in the `.canvas`.
    var refreshInterval: TimeInterval? {
        didSet {
            guard refreshInterval != oldValue else { return }
            onRefreshIntervalChanged?()
            // A cadence set on a board whose pages have all settled has nothing to start it: the
            // heartbeat stops when nothing is live, and the cards are already loaded and quiet.
            apply()
        }
    }
    var onRefreshIntervalChanged: (() -> Void)?

    /// The cadences the menu offers, in seconds. Coarse on purpose — this is "how stale am I willing
    /// to let this get", which nobody answers in units of one minute.
    static let refreshChoices: [TimeInterval] = [60, 5 * 60, 15 * 60, 60 * 60]

    // MARK: Asking again

    /// Decide again at the end of the current run loop pass, or when the board stops moving if it is
    /// in the middle of a crossing.
    func review() {
        guard let stage else { return }
        if stage.isCrossing { return settle() }
        guard !reviewQueued else { return }
        reviewQueued = true
        schedule.soon { [weak self] in
            self?.reviewQueued = false
            self?.apply()
        }
    }

    /// Decide again once the view has stopped moving. Each new request pushes the decision back, so
    /// the board acts on where you stopped rather than on everywhere you passed through.
    func settle() {
        settleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.apply() }
        settleWork = work
        schedule.after(Self.settleDelay, work)
    }

    func apply() {
        FrameMeter.span("pageBudget") { applyBody() }
    }

    /// The page settings changed under the board — the number of pages kept live, or whether link
    /// cards run pages at all.
    ///
    /// Both are read where they are used rather than cached, so the number takes effect the moment the
    /// budget is next applied; the switch needs the cards asked again, because a card only reconsiders
    /// whether it *wants* a page when its own zoom or address moves, and neither of those has.
    /// Immediate rather than settled: this is a deliberate act in a settings window, not a gesture that
    /// might still be going.
    func settingsChanged() {
        guard let stage else { return }
        for card in stage.pageCards.values { card.reconsiderLoading() }
        apply()
    }

    /// Bring over the pages the tab you just left was running for this board's cards — see
    /// `CanvasLinkNodeView.reclaimPage`. Before the budget, which then decides about them like any
    /// other.
    func reclaim() {
        guard let stage else { return }
        for card in stage.pageCards.values { card.reclaimPage() }
    }

    // MARK: Stopping

    /// Freeze every page on this board, without exception — the board itself is going away.
    ///
    /// For giving the board up. Looking away is `pauseWhileAway`, which is not the same question and
    /// must not have the same answer.
    func pauseEverything() {
        settleWork?.cancel()
        settleWork = nil
        if !live.isEmpty { Log.write("canvas pages paused: \(live.count)") }
        live = []
        keepWatching(false)
        for view in stage?.pageCards.values ?? [:].values where view.isPageCard { view.setPageLive(false) }
    }

    /// Freeze this board's pages because the window has been left alone for a while — sparing the card
    /// you are standing in, as long as PM is still on screen.
    ///
    /// The rule and the reasons are in `CanvasPageBudget.liveWhileAway`. Off screen, or with no window
    /// at all, this is `pauseEverything` and says so by calling it.
    func pauseWhileAway() {
        guard let stage, stage.hasWindow, stage.isOnScreen else { return pauseEverything() }
        settleWork?.cancel()
        settleWork = nil
        let spared = CanvasPageBudget.liveWhileAway(among: candidates(), onScreen: true)
        if live != spared {
            Log.write("canvas pages paused: \(live.subtracting(spared).count), "
                + "kept \(spared.count) in use")
        }
        live = spared
        // Stopped even with a card still live, because all the heartbeat does is apply the budget
        // again — which would wake every card this just froze. The window becoming key starts it.
        keepWatching(false)
        for (id, view) in stage.pageCards where view.isPageCard {
            view.setPageLive(spared.contains(id))
        }
    }

    // MARK: The decision

    private func applyBody() {
        settleWork?.cancel()
        settleWork = nil
        guard let stage, stage.hasWindow else { return }
        let candidates = candidates()
        // A tiled view is not a budget problem — every tile runs. See `CanvasPageBudget.liveWhileTiled`.
        let decided = stage.showsTiles ? CanvasPageBudget.liveWhileTiled(among: candidates)
                                       : CanvasPageBudget.live(among: candidates)
        if decided != live {
            Log.write("canvas pages live: \(decided.count) of \(candidates.count)")
            live = decided
        }
        for (id, view) in stage.pageCards where view.isPageCard {
            view.setPageLive(decided.contains(id))
            view.timePassed()
        }
        refreshStale()
        keepWatching(!decided.isEmpty)
    }

    /// Every page card on the board, as the budget sees it.
    ///
    /// This is the one place `lastVisibleAt` is written, and writing it here rather than at the top of
    /// a particular caller is deliberate: the grace period measures how long ago a card was last
    /// *drawn*, and every question about the budget is asked at a moment when the answer to that is
    /// whatever is on screen right now.
    private func candidates() -> [CanvasPageBudget.Candidate] {
        guard let stage else { return [] }
        let visible = stage.onScreenCanvasRect
        let centre = CanvasPoint(x: visible.midX, y: visible.midY)

        let now = schedule.now()
        var out: [CanvasPageBudget.Candidate] = []
        for (id, view) in stage.pageCards where view.isPageCard {
            guard let frame = stage.frame(ofNode: id) else { continue }
            // What is *drawn*, and only if it is drawn at all: the cards a tiled view has hidden are
            // not on screen however central the file thinks they are.
            let onScreen = view.isCardHidden ? false : frame.intersects(visible)
            if onScreen { view.lastVisibleAt = now }
            out.append(.init(id: id,
                             wantsPage: view.wantsPage,
                             isVisible: onScreen,
                             isEngaged: view.isEngaged,
                             distanceFromCentre: hypot(frame.midX - centre.x, frame.midY - centre.y),
                             secondsSinceVisible: now.timeIntervalSince(view.lastVisibleAt)))
        }
        return out
    }

    /// Reload whatever has gone stale, on the heartbeat that is already running.
    ///
    /// No timer of its own: the heartbeat ticks every 20 seconds whenever anything is live, which is
    /// exactly when a refresh could be due, and a second timer would be a second thing to keep in step
    /// with the budget. The cards decide whether they are actually stale — see `reloadIfStale`.
    private func refreshStale() {
        guard let refreshInterval, let stage else { return }
        for card in stage.pageCards.values { card.reloadIfStale(after: refreshInterval) }
    }

    // MARK: The heartbeat

    /// A slow tick, running only while the board has something live.
    ///
    /// Two things need it, and neither is caused by anything the board could be told about: a page's
    /// grace period runs out while you sit perfectly still looking at something else on the board, and
    /// the "as of" on a card gets older whether or not anyone touches it.
    private func keepWatching(_ wanted: Bool) {
        if wanted {
            guard !schedule.isTicking else { return }
            schedule.startTicking(every: Self.heartbeatInterval) { [weak self] in self?.apply() }
        } else {
            schedule.stopTicking()
        }
    }

    // MARK: Timing, injectable so the decisions above can be tested

    /// When things happen. Real time and the real main queue in the app; something a test can drive in
    /// `CanvasPageDirectorTests` — which is the point, because *when* a decision is taken is most of
    /// what this type is.
    @MainActor
    final class Schedule {
        var now: () -> Date = Date.init
        var soon: (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) }
        var after: (TimeInterval, DispatchWorkItem) -> Void = { delay, work in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }

        private var timer: Timer?
        var isTicking: Bool { timer != nil }

        func startTicking(every interval: TimeInterval, _ tick: @escaping @MainActor () -> Void) {
            timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
                Task { @MainActor in tick() }
            }
        }

        func stopTicking() {
            timer?.invalidate()
            timer = nil
        }
    }

    let schedule = Schedule()

    static let settleDelay: TimeInterval = 0.75
    private static let heartbeatInterval: TimeInterval = 20

    private var reviewQueued = false
    private var settleWork: DispatchWorkItem?
}
