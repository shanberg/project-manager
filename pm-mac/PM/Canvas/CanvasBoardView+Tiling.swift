import AppKit
import PmLib

/// The board as a window manager: filling the window with a handful of cards, and the small grammar
/// that applies while it is doing so.
///
/// **⌘Return is one command at both ends.** With one card selected it fills the window with that card,
/// which is today's most tedious manoeuvre on a board — zoom in, pan, find it. With six selected it is a
/// grid. Fullscreen and tile are the same idea at different counts, and making them one key is what
/// makes it worth learning.
///
/// While tiled the board has a different grammar rather than a broken version of its usual one. There is
/// no free space to move a card into, so a drag *swaps* two cards, which is what a drag means in every
/// tiling manager. There is nothing to marquee and nothing to wire together, so the sweep and the
/// connection dots are off. What is left is: look, focus, step in, swap, and leave.
@MainActor
extension CanvasBoardView {

    var isTiled: Bool { tiling != nil }

    // MARK: Entering and leaving

    /// ⌘Return. Make a workspace out of the selection — or, inside one, go back to the canvas.
    ///
    /// **One meaning in each place, which it did not have.** Pressed inside a tiling this used to drill
    /// in: with one tile picked out of six, the six went away and that one filled the window, and only
    /// with nothing left to narrow to did the same key become the way out. So the key you press to
    /// leave a workspace usually did not leave it. That is now the only thing it does there, and
    /// looking at one tile on its own is `toggleMaximizeTile` — a different act, with a key of its own,
    /// that puts the workspace back when you are done.
    ///
    /// **A workspace is made out of a selection or not at all.** Nothing selected used to tile whatever
    /// was on screen. A tiled view was a way of looking and that was a fair thing for it to mean; a
    /// workspace is a named thing that is saved and gets a tab, and making one out of whatever you
    /// happen to be scrolled to is a surprise you then have to go and delete. See
    /// `CanvasTiling.commandTitle`, which dims rather than guessing.
    @objc func tileSelection(_ sender: Any?) {
        guard tiling == nil else {
            // **A change of tab, not a change to the board.** The tiles stay exactly as they are; the
            // window shows its canvas. See `onGoToCanvas`.
            return onGoToCanvas()
        }
        let ids = tileTargets
        guard !ids.isEmpty else { return NSSound.beep() }
        // **The tiling this is about to make is a workspace, so it wants a tab.** Offered to the window
        // before it is laid out here, because the window is what keeps a workspace and what holds the
        // tabs — and because the pane that ends up showing it is the workspace's own, not this one.
        // See `onTileAsWorkspace`. A board with no window to ask tiles itself, as it always did.
        guard !offerAsWorkspace(ids) else { return }
        tile(ids)
    }

    /// What tiling these cards would produce, without producing it.
    ///
    /// Split out of `tile(_:)` so a workspace can be *made* before a board is laid out into it — the
    /// window keeps the workspace and opens its tab, and the pane that tab builds restores it. Every
    /// choice here is `tile(_:)`'s, made in the same order and for the same reasons; what is missing is
    /// the part that depends on the window, which is where the tiles physically land.
    func plannedTiling(for ids: Set<String>,
                       arrangement: CanvasTiling.Arrangement? = nil) -> CanvasViewState.Tiling? {
        let cards = document.nodes.filter { ids.contains($0.id) && !$0.isGroup }
            .map { (id: $0.id, frame: $0.frame) }
        guard !cards.isEmpty else { return nil }
        // The same cards as last time means the same arrangement as last time: the order they were
        // dragged into, the widths, the pin. Matched on the set rather than the order, because the
        // order is one of the things being remembered.
        let remembered = lastTiling.flatMap { Set($0.ids) == Set(cards.map(\.id)) ? $0 : nil }
        return CanvasViewState.Tiling(
            ids: remembered?.ids ?? CanvasTiling.order(cards),
            arrangement: arrangement ?? remembered?.arrangement ?? CanvasTiling.savedArrangement
                ?? preferredArrangement(for: cards.count),
            masterFraction: remembered?.masterFraction ?? CanvasTiling.savedMasterFraction,
            sizes: remembered?.sizes)
    }

    /// Hand this tiling to the window as a workspace, and say whether it took it. Only from a board
    /// that is not already tiled — inside a workspace ⌘↩ is the way out, and there is nothing to make.
    func offerAsWorkspace(_ ids: Set<String>,
                          arrangement: CanvasTiling.Arrangement? = nil) -> Bool {
        guard tiling == nil, let plan = plannedTiling(for: ids, arrangement: arrangement) else {
            return false
        }
        return onTileAsWorkspace(plan)
    }

    /// The cards ⌘Return would fill the window with, given what is selected right now.
    ///
    /// Split out of `tileSelection` so the menus can *name* them before you commit. Naming them means
    /// counting them, and counting them means running exactly this — a menu that guessed at the number
    /// by looking at `selection.count` would be wrong in both of the cases below, which are the two
    /// cases where being told the number matters.
    var tileTargets: Set<String> {
        var ids = selection.filter { document.node(id: $0).map { !$0.isGroup } ?? false }
        // A frame is a container of cards, so tiling one means tiling what is in it — "make a workspace
        // out of this region", and the one point where frames and workspaces should meet. See `frames`
        // for why that is the whole of the relationship rather than the two being the same thing.
        for id in selection {
            guard let node = document.node(id: id), node.isGroup else { continue }
            ids.formUnion(canvasCardsInside(node.frame, of: document))
        }
        // **Nothing selected is nothing to make**, and it used to be everything on screen. A tiled
        // view was a way of looking, so "fill the window with what I can see" was a fair reading of an
        // empty selection; a workspace is saved, named and given a tab, and one made out of wherever
        // the board happened to be scrolled is a thing you then have to go and delete. It also cost
        // this property a scan of the visible region on every call — see `tileCommandTitle`, which had
        // to route around it.
        return ids
    }

    /// What ⌘Return is called right now. See `CanvasTiling.commandTitle`, which owns the wording.
    var tileCommandTitle: String {
        CanvasTiling.commandTitle(tiled: isTiled, targets: isTiled ? 0 : tileTargets.count)
    }

    /// Whether ⌘Return has anything to do: a workspace to make, or one to leave.
    var canRunTileCommand: Bool { isTiled || !tileTargets.isEmpty }

    /// What the header's tile capsule draws, or nil when there is no one tile to draw it for.
    ///
    /// **The conditions are decided here**, on the board, rather than in the capsule — a tile in a grid
    /// has no master to become, and a tile in a grid of both rows and columns has no run to pin along,
    /// and those are facts about the arrangement rather than about the chrome. The capsule is then a
    /// drawing of a state instead of a second copy of these rules, which is what stops the header and
    /// the contextual menu offering different verbs for the same tile.
    ///
    /// **Nil in a workspace of one tile**, which is the project-note view: nothing to promote, nothing
    /// to pin, and a tile that already fills the room. A capsule there would be two controls that
    /// cannot do anything.
    var tileControls: CanvasHeaderModel.TileControls? {
        guard let tiling, tiling.ids.count > 1, let id = focusedTile else { return nil }
        return CanvasHeaderModel.TileControls(
            isMaximized: tiling.maximized != nil,
            canPromote: tiling.arrangement == .masterStack && tiling.ids.first != id,
            pinTitle: pinnableTile == nil ? nil : pinTileTitle)
    }

    /// Tile these cards, whatever asked for it.
    func tile(_ ids: Set<String>, arrangement: CanvasTiling.Arrangement? = nil) {
        let cards = document.nodes.filter { ids.contains($0.id) && !$0.isGroup }
            .map { (id: $0.id, frame: $0.frame) }
        guard !cards.isEmpty else { return NSSound.beep() }
        let visible = canvasRect(visibleRect)
        // The same cards as last time means the same arrangement as last time: the order they were
        // dragged into, the widths, the pin. Matched on the set rather than the order, because the
        // order is one of the things being remembered.
        let remembered = lastTiling.flatMap { Set($0.ids) == Set(cards.map(\.id)) ? $0 : nil }
        // **This does not decide which workspace you are in any more, and it used to.** ⌘↩ went
        // straight through here and cleared `workspaceName` on the way, which is what made an untitled
        // workspace: a set of tiles with nothing pointing at it. There is no such thing now (§7i), and
        // the decision moved one step earlier — `tileSelection` offers the tiling to the window, which
        // names it and opens its tab, and the pane that tab builds arrives here through
        // `restoreTiling` with the name already in hand.
        //
        // What reaches this now is the two tilings that are not workspaces: the project-note view
        // (`CanvasPaneController.goToProjectNote`), and any board with no window around it to keep a
        // workspace for it.
        // **At 100%, whatever the board was at.** A tiling fills the window with cards, and on a board
        // zoomed out to 40% — where you nearly always are when you decide to fill the window with
        // something — it would fill it with cards whose text is at 40%. Filling the window is a request
        // to *read* the thing, so the zoom is part of what the command means rather than something it
        // happens to inherit. Set before the area is measured: `tileableRect` is in canvas coordinates,
        // and how much canvas the window covers is exactly what just changed.
        let restoreZoom = tiling?.restoreZoom ?? Double(scrollView?.magnification ?? 1)
        // **Measured for 100%, then travelled to.** This used to set the zoom outright and measure
        // afterwards, which is the same arithmetic with the journey missing — see
        // `tileableRect(atZoom:)` and `CanvasScrollView.fly(to:centre:animated:)`.
        let area = FrameMeter.span("tileableRect") { tileableRect(atZoom: 1) }
        let order = remembered?.ids ?? CanvasTiling.order(cards)
        let session = CanvasTileSession(
            ids: order,
            arrangement: arrangement ?? remembered?.arrangement ?? CanvasTiling.savedArrangement
                ?? preferredArrangement(for: cards.count),
            masterFraction: remembered?.masterFraction ?? CanvasTiling.savedMasterFraction,
            sizes: remembered?.sizes ?? [:],
            area: area,
            restoreVisible: tiling?.restoreVisible ?? visible,
            restoreZoom: restoreZoom)
        tiling = session
        // Something has to be focused on the way in, or the arrows and Return have nothing to act on
        // and the first thing you try does nothing. Whatever of the selection survived, else the first
        // tile — which in master-and-stack is the master, the one you are most likely to mean.
        let kept = selection.intersection(ids)
        selection = kept.isEmpty ? [order[0]] : kept
        // Started before the movement rather than with it, so the first frames — the most expensive
        // ones, where every card is invalidated at once — are inside the measurement. See `FrameMeter`.
        FrameMeter.measure("canvas → tiles (\(nodeViews.count) views, \(order.count) tiles, "
                              + "\(pagesLive.count) live)", on: self)
        flyToTiles(of: session, animated: true)
        setLayout(session.layout, animated: true)
        onTilingChanged?()
        announceTiling()
    }

    /// Take the board to the zoom and the place a tiling is laid out for.
    ///
    /// **Not the area's own centre**, which is what this flew to at first and is wrong by half the
    /// margins: the tiles are pushed down by the header's clearance and in by the sidebar, so the middle
    /// of the tiles is not the middle of the window. `CanvasTiling.centre(framing:margins:)` is the
    /// inverse of the measurement, and lives beside it for that reason.
    ///
    /// For a board entering its own workspace this is the centre it is already at, so nothing slides —
    /// the flight is only about the zoom. For one posing as a workspace it borrowed from another pane
    /// (`poseAsTiling`) it is the centre that frames those tiles the way that pane had them, which is
    /// the whole point of the pose.
    func flyToTiles(of session: CanvasTileSession, animated: Bool) {
        let centre = CanvasTiling.centre(framing: session.area, margins: tileMargins(atZoom: 1))
        scrollView?.canvasScroll?.fly(to: 1, centre: centre, animated: animated)
    }

    // MARK: Arriving from the pane before this one

    /// What this board looks like at the moment the window stops showing it, for the board that is
    /// about to take its place. See `CanvasArrival`.
    var departure: CanvasArrival {
        CanvasArrival(zoom: Double(scrollView?.magnification ?? 1),
                      centre: canvasPoint(NSPoint(x: visibleRect.midX, y: visibleRect.midY)),
                      tiling: tiling)
    }

    /// Stand exactly where the board before this one was standing, wearing the workspace it was wearing
    /// — and do it in one frame, with nothing animated.
    ///
    /// **The pose, which is the whole trick.** Going from a workspace to the canvas is not one board
    /// changing its mind, it is one *pane* being hidden and another shown (`ProjectContentPane.show`):
    /// two boards, two sets of card views, on the same document. Nothing can fly across that seam. What
    /// can happen is that the board arriving starts out identical to the one leaving — same zoom, same
    /// centre, same tiles, same ground — so that the swap itself has nothing to show, and then leaves
    /// the tiling in the ordinary way, which is a thing this board already knows how to animate.
    ///
    /// The restore point is overwritten with *this* board's own, because that is where leaving has to
    /// put you: the tiles are borrowed, but the board underneath them is this pane's and it was already
    /// looking somewhere.
    func poseAsTiling(_ session: CanvasTileSession) {
        var posed = session
        posed.restoreZoom = Double(scrollView?.magnification ?? 1)
        posed.restoreVisible = canvasRect(visibleRect)
        tiling = posed
        // Held rather than set: `tiling` starts the crossing fading *towards* tiles, and this board is
        // to be found already there. See `CanvasFade.hold`.
        holdTiledness(1)
        setLayout(posed.layout, animated: false)
        flyToTiles(of: posed, animated: false)
    }

    /// The same pose the other way round: the board as the canvas the pane before this one was showing.
    ///
    /// Leaving first, because a workspace pane that has been visited before is still tiled and has to
    /// stop being, and because `leaveTiling` is where the tiles are let go of properly — the engaged
    /// card stepped out of, the arrangement kept for next time.
    func poseAsCanvas(zoom: Double, centre: CanvasPoint) {
        // Kept across the leave: this pane's tab is still pinned to its workspace, and it is about to
        // be tiled into it again a runloop turn from now.
        let name = workspaceName
        leaveTiling(animated: false)
        workspaceName = name
        holdTiledness(0)
        scrollView?.canvasScroll?.fly(to: CGFloat(zoom), centre: centre, animated: false)
    }

    /// Put back the tiling a board was left in — see `CanvasViewState`.
    ///
    /// Not `tile(_:)`, which re-derives the order from where the cards sit. The order is the one part of
    /// a tiling you edit while you are in it: every swap and every promotion is a change to nothing
    /// else. Restoring through `tile` would lay the cards back out in reading order and quietly undo
    /// all of it, which is the failure mode where remembering is worse than forgetting.
    ///
    /// Cards that have gone since are dropped rather than treated as a reason to give up — a board you
    /// deleted one card from is still the board you were looking at.
    /// `animated` is for the one case where there is something to watch: a board that is *already* on
    /// screen showing its cards, being asked to make them into this workspace. A pane built to show a
    /// workspace has nothing to animate from and passes false — see `CanvasPaneController.arrive(from:)`,
    /// which is how a pane comes to have something to animate from after all.
    func restoreTiling(_ remembered: CanvasViewState.Tiling, named name: String? = nil,
                       animated: Bool = false) {
        let live = remembered.ids.filter { document.node(id: $0).map { !$0.isGroup } ?? false }
        guard !live.isEmpty else { return }
        workspaceName = name
        // The zoom a tiling is shown at, and the fitted zoom to hand back on the way out — the same
        // two `tile` sets, arrived at the same way round. See there for why.
        let restoreZoom = Double(scrollView?.magnification ?? 1)
        let session = CanvasTileSession(ids: live,
                                        arrangement: remembered.arrangement,
                                        masterFraction: remembered.masterFraction,
                                        // Only for cards that are still here: a size left behind for a
                                        // deleted card would come back the moment its id was reused.
                                        sizes: (remembered.sizes ?? [:]).filter { live.contains($0.key) },
                                        area: FrameMeter.span("tileableRect") { tileableRect(atZoom: 1) },
                                        // Where leaving puts you back. Not remembered: it is the region
                                        // the board would be showing anyway, which on one just opened
                                        // is the whole of it — the right place to be returned to.
                                        restoreVisible: canvasRect(visibleRect),
                                        restoreZoom: restoreZoom)
        tiling = session
        lastTiling = memory(of: session)
        selection = [live[0]]
        if animated {
            FrameMeter.measure("canvas → tiles (\(nodeViews.count) views, \(live.count) tiles, "
                                  + "\(pagesLive.count) live)", on: self)
        }
        flyToTiles(of: session, animated: animated)
        setLayout(session.layout, animated: animated)
        onTilingChanged?()
        announceTiling()
    }

    /// What is worth remembering about a tiling: everything except where the window happened to be.
    func memory(of session: CanvasTileSession) -> CanvasViewState.Tiling {
        CanvasViewState.Tiling(ids: session.ids, arrangement: session.arrangement,
                               masterFraction: session.masterFraction,
                               sizes: session.sizes.isEmpty ? nil : session.sizes)
    }

    /// The workspace this board would carry into another session: the one that is up, or the last one
    /// there was.
    var tilingMemory: CanvasViewState.Tiling? { tiling.map(memory(of:)) ?? lastTiling }

    /// Say out loud what just happened to the board.
    ///
    /// A tiled view hides most of a board and moves the rest, which is a large change to something you
    /// cannot see happen if you are not looking at it. `NSAccessibility.post` with
    /// `.layoutChanged` is what the system uses for a window rearranging itself, which is exactly what
    /// this is.
    private func announceTiling() {
        setAccessibilityLabel(tilingSummary.map { "Canvas, tiled, \($0.long)" } ?? "Canvas")
        NSAccessibility.post(element: self, notification: .layoutChanged)
    }

    /// A grid, unless there are enough cards that one of them ought to be the one you are working in.
    ///
    /// Two or three tiles are peers and a grid says so. Past four, a grid makes every card equally small
    /// — which is the wrong answer to "I am reading this one and watching those", the shape a board of
    /// this size is nearly always in.
    private func preferredArrangement(for count: Int) -> CanvasTiling.Arrangement {
        count >= 4 ? .masterStack : .grid
    }

    // MARK: Maximizing one tile

    /// The tile filling the window on its own, if one is.
    var maximizedTile: String? { tiling?.maximized }

    /// Fill the room with one tile for a moment, or put the workspace back — **maximizing a window,
    /// not drilling into a tiling.**
    ///
    /// The difference is what happens next. Drilling in made a real tiling of the one card and pushed
    /// the six you came from onto a history, so everything downstream had to reason about which of the
    /// two you meant: ⌘Return meant "narrow further" until it didn't, Escape unwound a stack, and the
    /// write-through to `CanvasWorkspaces` needed a guard to stop a workspace being reduced to the tile
    /// you were reading. None of that is here. `maximized` is one field on the session, it is not in
    /// `memory(of:)`, and restoring is the same layout you already had.
    ///
    /// **Maximize, not zoom**, though the Mac calls the green button Zoom: this board already has a
    /// magnification, and cards have a content zoom of their own, and a third meaning of the word would
    /// be one too many.
    ///
    /// Nothing to do in a workspace of one tile — it already fills the room.
    func toggleMaximizeTile(_ id: String, animated: Bool = true) {
        guard var session = tiling, session.ids.count > 1, session.ids.contains(id) else { return }
        session.maximized = session.maximized == id ? nil : id
        tiling = session
        // The tile you are looking at is the tile the arrows and the menus are about. Maximizing one
        // you had not picked would otherwise leave the selection on a tile that is no longer drawn.
        if session.maximized != nil { selection = [id] }
        setLayout(session.layout, animated: animated)
        onTilingChanged?()
        announceTiling()
    }

    /// Put the workspace back, if a tile is filling it. Answers whether it had anything to do, because
    /// Escape has somewhere else to go when it doesn't — see `cancelOperation`.
    @discardableResult
    func restoreMaximizedTile(animated: Bool = true) -> Bool {
        guard let id = maximizedTile else { return false }
        toggleMaximizeTile(id, animated: animated)
        return true
    }

    /// Restore first, then act — for the commands that rearrange a workspace you cannot currently see.
    ///
    /// Promoting or removing a tile while one is maximized changes an order whose evidence is all off
    /// screen, and leaves you looking at the same single tile with no sign anything happened. Putting
    /// the workspace back first makes the change the thing you watch.
    func restoringMaximized(_ work: () -> Void) {
        restoreMaximizedTile(animated: false)
        work()
    }

    /// Leave the tiled view altogether.
    ///
    /// **What is kept is the workspace, not the tile you left through.** A maximized tile is a way of
    /// looking at the workspace for a moment (see `toggleMaximizeTile`), so it is not in
    /// `memory(of:)` and cannot be what comes back next time. This used to have to say that out loud:
    /// the drill-in made a *real* tiling of one card, so leaving had to reach past a history to find
    /// the session worth remembering. There is no history now, and the session in hand is the one.
    func leaveTiling(animated: Bool) {
        guard let session = tiling else { return }
        let current = session
        // Step out of whatever tile you were typing in. Engagement is the tiled view's own doing — see
        // `tileClicked` — and leaving it holding would hand back a board with one card open in an
        // editor, which is a state you never asked the board for.
        for id in current.ids { nodeViews[id]?.engage(false) }
        // Kept, not discarded — see `CanvasViewState.lastTiling`.
        lastTiling = memory(of: session)
        tiling = nil
        // **The view and the cards, started together and travelling together.** Both halves of leaving
        // change where a card is drawn: the zoom changes how canvas coordinates map to the window, and
        // the layout changes which canvas coordinates each card has. This used to set the view outright
        // and then animate the cards, and the order mattered enormously — done the other way round, the
        // cards were set animating toward frames measured in the old zoom and the magnification changed
        // out from under the animation while it ran, landing every card at its 100% size on a board now
        // at 35%.
        //
        // What makes the two safe to run at once is that neither is answering the other's question. The
        // flight owns the zoom and the scroll — how the board is drawn and where — and the cards own
        // their canvas frames, which the zoom does not enter into. Every frame has one answer for each.
        // See `CanvasScrollView.fly(to:centre:animated:)`.
        if animated {
            FrameMeter.measure("tiles → canvas (\(nodeViews.count) views, \(current.ids.count) tiles, "
                                   + "\(pagesLive.count) live)", on: self)
        }
        scrollView?.canvasScroll?.fly(to: CGFloat(session.restoreZoom),
                                      centre: CanvasPoint(x: session.restoreVisible.midX,
                                                          y: session.restoreVisible.midY),
                                      animated: animated)
        setLayout(.document, animated: animated)
        announceTiling()
        onTilingChanged?()
    }

    /// Swap the arrangement without leaving the tiling.
    func setArrangement(_ arrangement: CanvasTiling.Arrangement) {
        guard var session = tiling, session.arrangement != arrangement else { return }
        CanvasTiling.savedArrangement = arrangement
        session.arrangement = arrangement
        tiling = session
        setLayout(session.layout, animated: true)
        onTilingChanged?()
    }

    /// Put a card into the tiled view that is up. Nothing at all when there isn't one, which is what
    /// lets every add command call it unconditionally.
    ///
    /// **The workspace, even while one tile is filling the room.** A card added while a tile is
    /// maximized goes into the arrangement underneath, so restoring shows it in its place rather than
    /// producing it out of nowhere. That falls out of there being one session: this used to have to
    /// walk a stack of them, because a drill-in was a real tiling and a card added to the one you could
    /// see would have vanished the moment you backed out of it.
    ///
    /// A frame is a container of cards rather than a card, so there is no tile it could be.
    func addToTiling(_ id: String) {
        guard var session = tiling, document.node(id: id).map({ !$0.isGroup }) ?? false else { return }
        session.add(id)
        guard session != tiling else { return }
        tiling = session
        setLayout(session.layout, animated: true)
        onTilingChanged?()
        announceTiling()
    }

    /// Take a tile out of the view, leaving the card exactly where it is on the board.
    ///
    /// **Stop showing it, never delete it.** A tile is a view of a card, so the obvious word for this —
    /// close — is the dangerous one: deleting through a view is how people lose work, and the view is
    /// precisely the place where you cannot see what you would be losing. The card is still on the
    /// board, in the same spot, and leaving the tiling shows it there.
    ///
    /// The last tile is the way out. A tiling of nothing is not a state — the window would be empty
    /// with no way to say what it was — so removing the only tile means leaving, which is also what
    /// anybody doing it was asking for.
    func removeFromTiling(_ id: String) {
        guard var session = tiling, let index = session.ids.firstIndex(of: id) else { return }
        guard session.ids.count > 1 else { return leaveTiling(animated: true) }
        session.remove(id)
        tiling = session
        // Something has to stay focused, for the same reason entering a tiling focuses something: the
        // arrows and Return act on it. The tile that took this one's place, else the new last one.
        selection.remove(id)
        if selection.isDisjoint(with: session.ids) {
            selection = [session.ids[min(index, session.ids.count - 1)]]
        }
        setLayout(session.layout, animated: true)
        onTilingChanged?()
        announceTiling()
    }

    /// A card that has gone takes its tile with it.
    ///
    /// `ids` is a list of names, and nothing was checking that they still named anything — a card
    /// deleted while it was up left a tile-shaped hole in the arrangement that no card would ever fill
    /// and no gesture could close. Reachable in the ordinary way (⌫ on a focused tile) and now in an
    /// unremarkable one too: an empty text card you click into and click away from deletes itself, and
    /// clicking into one is exactly what a tiled view now offers.
    ///
    /// Losing the last one leaves the tiling, for the reason `removeFromTiling` gives: a tiling of
    /// nothing is not a state.
    func pruneTilingOfDeletedCards() {
        guard let session = tiling else { return }
        let gone = session.ids.filter { document.node(id: $0) == nil }
        guard !gone.isEmpty else { return }
        guard gone.count < session.ids.count else { return leaveTiling(animated: true) }
        var next = session
        for id in gone { next.remove(id) }
        tiling = next
        if selection.isDisjoint(with: next.ids) { selection = [next.ids[0]] }
        setLayout(next.layout, animated: true)
        onTilingChanged?()
        announceTiling()
    }

    // MARK: Which tile has the keyboard

    /// While a tiling is up, watch for a click landing inside a tile.
    ///
    /// A watch rather than a `mouseDown`, because the board never sees these clicks and that is the
    /// point: a tiled card takes its own — `CanvasNodeView.takesItsOwnClicks` grants it outright, so
    /// you can scroll a page in one tile and tick a task in another without focusing either first. The
    /// board is only told about the edge bands and the gaps. So the one thing still missing was not a
    /// click *for* the card but a click the board could hear *about*.
    ///
    /// Put and taken away with the tiling itself, from `tiling`'s `didSet`, so an untiled board carries
    /// nothing. The event is returned unchanged: this listens, it never consumes.
    func watchTileClicks(_ watching: Bool) {
        if let existing = tileClickWatch { NSEvent.removeMonitor(existing) }
        tileClickWatch = nil
        guard watching else { return }
        tileClickWatch = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            self?.tileClicked(event)
            return event
        }
    }

    /// **The tile you clicked into is the tile you can type in.**
    ///
    /// Editing a card meant stepping into it, and a tile was never stepped into — so a task row on a
    /// project tile opened an editor with the keyboard still on the board, and a text tile had no
    /// gesture at all that would show you its editor. Return on the focused tile always worked, which
    /// is a thing you have to be told; a click is the thing everybody tries.
    ///
    /// **The click is not spent on this.** It goes on to whatever it was aimed at, and because a local
    /// monitor runs before the window routes the event, a text card that swaps its rendering for an
    /// editor here has that editor in place by the time the click lands in it — you click on the
    /// sentence and the caret is in the sentence.
    ///
    /// `engage` rather than `beginEditing`, which is not the same errand on every kind of card: a file
    /// card's opens the file in whatever owns it, and a project card's, on one too small to read, walks
    /// out of the board to the project window. Neither is a thing a click inside a tile should do.
    /// Step into a card without a click having landed on it.
    ///
    /// What the note-only view does with the one card it shows (docs/canvas-workspaces.md §7d): the
    /// commands that act on "the project you are standing in" — New Session, New Task, Edit Details,
    /// and find — all ask `engagedProjectCard`, and a view whose whole content is one project should
    /// not need a click to admit which project that is. Selection first and then engagement, in that
    /// order and for the reason `tileClicked` gives.
    func engage(cardWithID id: String) {
        guard let card = nodeViews[id] else { return }
        selection = [id]
        card.engage(true)
    }

    private func tileClicked(_ event: NSEvent) {
        guard event.window === window,
              let hit = window?.contentView?.hitTest(event.locationInWindow) else { return }
        // AppKit's own answer to "whose click is this". A press on the band the board keeps along a
        // tile's edge, on a boundary, or in a gap hit-tests to the board itself and walks up to nothing
        // — which is exactly right, since those presses are the arrangement's rather than the card's.
        var view: NSView? = hit
        while let current = view, !(current is CanvasNodeView) { view = current.superview }
        guard let card = view as? CanvasNodeView, tiling?.ids.contains(card.node.id) == true else {
            return
        }
        // Focused as well as engaged, and in that order. They have to be the same tile or the menus
        // are about one card while the keyboard is in another — and setting the selection is what
        // steps every *other* card back out, through `CanvasNodeView.selectionChanged`.
        selection = [card.node.id]
        card.engage(true)
    }

    /// Move a tile along the order — the handlebar's drag. See `CanvasTileSession.move`.
    func moveInTiling(_ id: String, to index: Int) {
        guard var session = tiling else { return }
        session.move(id, to: index)
        guard session != tiling else { return }
        tiling = session
        setLayout(session.layout, animated: true)
        onTilingChanged?()
    }

    /// Drag a boundary: the two tiles either side of it change length, and nothing else moves.
    ///
    /// **Local, and that is the whole design.** The alternative — attributing the drag to one card and
    /// letting the rest of the run absorb it — moves tiles you never touched, three boundaries away,
    /// and is what makes a layout feel like it is arguing with you. Every split view on the Mac works
    /// this way for the same reason.
    ///
    /// **What gets written depends on what the tile is.** A pinned tile takes its new length in points;
    /// a flexible one takes it as a weight. Weights are only meaningful against each other, so writing
    /// a tile's *current* length as its weight changes nothing about where it is — which is what lets
    /// the first drag in a run quietly restate every flexible tile in points and leave the picture
    /// identical. Pinned tiles that were not dragged are left alone: their current length may be a pin
    /// the window is too small to honour, and rewriting it would bake the squeeze in permanently.
    func dragTileDivider(_ divider: CanvasTileDivider, from: CanvasPoint, to now: CanvasPoint,
                         lengths: [Double]) {
        guard var session = tiling, lengths.count == divider.run.count,
              divider.before + 1 < lengths.count else { return }
        let before = divider.before, after = before + 1
        let pair = lengths[before] + lengths[after]
        let floor = min(CanvasTiling.minimumTile, pair / 2)
        let delta = divider.isVertical ? now.x - from.x : now.y - from.y
        let grown = min(pair - floor, max(floor, lengths[before] + delta))

        // The master against the stack is a proportion of the window rather than two lengths — it is
        // the one boundary whose meaning is "how much of this window", and it stays that unless the
        // master has been pinned, at which point it is points like everything else.
        if divider.isMasterSplit, case .pinned? = session.sizes[session.ids[0]] {
            session.sizes[session.ids[0]] = .pinned(grown)
            tiling = session
            setLayout(session.layout, animated: false)
            return
        }
        if divider.isMasterSplit { return setMasterFraction(grown / max(1, pair)) }

        for (position, index) in divider.run.enumerated() {
            let id = session.ids[index]
            let length = position == before ? grown
                       : position == after ? pair - grown
                       : lengths[position]
            if case .pinned? = session.sizes[id] {
                guard position == before || position == after else { continue }
                session.sizes[id] = .pinned(length)
            } else {
                session.sizes[id] = .flexible(length)
            }
        }
        tiling = session
        setLayout(session.layout, animated: false)
    }

    /// Hold this tile's length against the window — or let it go back to sharing.
    ///
    /// The deliberate half of the mechanism. A drag can *change* a pin but must never *create* one:
    /// if dragging pinned things, every tile you ever adjusted would stop responding to the window and
    /// the arrangement would gradually turn into a fixed layout without anyone asking for it.
    func togglePinTile(_ id: String) {
        guard var session = tiling, let frame = session.layout.frames[id] else { return }
        if case .pinned? = session.sizes[id] {
            session.sizes[id] = nil
        } else {
            session.sizes[id] = .pinned(tileRunIsVertical(id) ? frame.height : frame.width)
        }
        tiling = session
        setLayout(session.layout, animated: true)
        onTilingChanged?()
    }

    /// Whether this tile's run flows top to bottom — so whether pinning it holds its height rather
    /// than its width. The stack does; a row of tiles doesn't.
    func tileRunIsVertical(_ id: String) -> Bool {
        guard let tiling, let index = tiling.ids.firstIndex(of: id) else { return false }
        switch tiling.arrangement {
        case .masterStack: return index > 0
        case .grid: return gridRunIsHorizontal == false
        }
    }

    /// Whether this tile is holding a length of its own.
    func isTilePinned(_ id: String) -> Bool {
        if case .pinned? = tiling?.sizes[id] { return true }
        return false
    }

    /// Make the focused card the master tile — ⌘⇧Return, the View menu, and the tile's own menu.
    ///
    /// It used to claim a double-click on a stack tile as well. That was never dispatched: the second
    /// click of a double-click is answered before the tiled view is, and the ⌘⇧Return it also claimed
    /// was written on a contextual-menu item, which is drawn and never searched. Both are real now,
    /// and the double-click is gone rather than fixed — see `CanvasBoardView.mouseDown`.
    func promoteInTiling(_ id: String) {
        guard var session = tiling else { return }
        session.promote(id)
        tiling = session
        setLayout(session.layout, animated: true)
        // The order is part of what a tiling *is*, and it is what promoting changes. Anyone who cares
        // that a tiling changed cares about this one — see `CanvasViewState.Tiling`.
        onTilingChanged?()
    }

    /// A drag inside a tiled view: the two cards change places.
    func swapInTiling(_ id: String, with other: String) {
        guard var session = tiling else { return }
        session.swap(id, with: other)
        tiling = session
        setLayout(session.layout, animated: true)
        onTilingChanged?()
    }

    /// Drag the divider between the master tile and the stack.
    func setMasterFraction(_ fraction: Double) {
        guard var session = tiling, session.arrangement == .masterStack else { return }
        session.masterFraction = min(0.85, max(0.3, fraction))
        tiling = session
        setLayout(session.layout, animated: false)
    }

    /// Let go of a boundary. Where you dragged it to is part of the arrangement now, so it gets written
    /// down — see `CanvasPaneController.rememberViewState`, which listens on `onTilingChanged` precisely
    /// because there is no reliable moment on the way out to write on instead.
    ///
    /// **Every boundary, not only the master's.** Only the master split used to reach this, and it
    /// reached it by accident: it has a second, app-wide preference to write as well as a layout, and it
    /// fired the notification on its way past. Every other divider — the stack's, a single-run grid's —
    /// changed `sizes` in memory and told nobody. Those widths then lasted exactly as long as the tiling
    /// did: leaving wrote them on the way past, but quitting or closing the window while still tiled,
    /// which is the ordinary way to stop looking at a board, wrote the state as it was before the drag.
    /// The master split kept its position and the stack beside it came back even, which is a board that
    /// remembers half of what you did to it.
    ///
    /// On mouse-up rather than on every frame of the drag, which would write to defaults at the rate the
    /// mouse reports.
    func rememberTileSizes(_ divider: CanvasTileDivider) {
        guard let tiling else { return }
        // The one boundary with a preference behind it as well as a layout: a divider you drag back to
        // the same place on every board is a setting you have already made.
        if divider.isMasterSplit, tiling.arrangement == .masterStack {
            CanvasTiling.savedMasterFraction = tiling.masterFraction
        }
        onTilingChanged?()
    }

    /// The window changed size, so the region the tiles were laid out in is the wrong shape.
    ///
    /// Without this a tiled view stops filling the window the moment you resize it — the tiles keep the
    /// canvas coordinates they were given, which were the window's at the time, and drift out of it. A
    /// tiling manager's whole promise is that the windows fill the screen, and one that stopped when
    /// you dragged a corner would be making the promise in past tense.
    func retileForWindowSize() {
        guard var session = tiling else { return }
        // **Not while there is nothing to lay out into**, which is the state a tab that is not the one
        // you are looking at spends its life in.
        //
        // A project window keeps every tab's pane mounted and hides the ones that are not up
        // (`ProjectContentPane.show`), and a hidden view keeps its frame but reports an *empty*
        // `visibleRect` — so `tileableRect`, which is built from it, collapses to its own 80pt floor at
        // whatever origin the empty rect had. Auto Layout still resizes a hidden pane, so every window
        // resize reached the workspaces you were not in and quietly re-tiled them into an 80×80 region
        // off the side of the board. Switching to one then showed a board with no tiles on it, and
        // resizing the window — the one thing that runs this again with a real rectangle — was what put
        // them back. See `CanvasPaneController.paneBecameVisible`, which is the other half: a pane that
        // was hidden through a resize has one waiting for it when it comes back.
        guard !visibleRect.isEmpty else { return }
        // **Nor mid-crossing.** The board is somewhere between two zooms while it flies into or out of a
        // workspace (`CanvasScrollView.fly`), so `tileableRect` measured now describes a window nobody
        // is looking at — and re-laying the tiles into it would retarget every card in mid-air. The
        // flight lands at the zoom the tiles were measured for, which is the answer this would be
        // looking for anyway.
        guard scrollView?.canvasScroll?.isFlying != true else { return }
        session.area = tileableRect
        tiling = session
        setLayout(session.layout, animated: false)
    }

    // MARK: Frames

    /// The board's frames, in reading order — the regions of it you can step between.
    ///
    /// **These used to be called workspaces, and they are not.** The noticing behind that name was
    /// right as far as it went — a frame is a named container of cards, and so is a workspace — and it
    /// is also the entire overlap between them. A frame has a position, a size and a place in the
    /// `.canvas` that Obsidian opens; a workspace has no position at all and never touches the file.
    /// You drag a card *into* a frame; you choose cards *into* a workspace. A frame's layout is where
    /// you put the cards; a workspace's is computed from an arrangement and some sizes.
    ///
    /// So the word went to the thing that had no other name — a saved tiling, `CanvasWorkspaces` — and
    /// frames went back to being frames. The relationship survives and is the useful one: ⌘Return on a
    /// frame tiles what is inside it, which is *make a workspace out of this region*, and that is the
    /// one point where the two should meet. See docs/canvas-workspaces.md §7.
    var frames: [CanvasNode] {
        document.nodes.filter(\.isGroup).sorted {
            $0.frame.minY == $1.frame.minY ? $0.frame.minX < $1.frame.minX
                                           : $0.frame.minY < $1.frame.minY
        }
    }

    /// ⌃1…9. Go to a frame: fit it in the window and select what is in it.
    ///
    /// Fitting rather than tiling, because a frame was arranged by hand and the arrangement is the
    /// point — that is what distinguishes a frame from a bag of cards. ⌘Return then tiles what this
    /// selected, for the times it isn't.
    @objc func goToFrame(_ sender: Any?) {
        guard let index = (sender as? NSMenuItem)?.tag, index >= 0 else { return }
        let frames = self.frames
        guard index < frames.count else { return NSSound.beep() }
        let frame = frames[index]
        if isTiled { leaveTiling(animated: false) }
        selection = canvasCardsInside(frame.frame, of: document)
        scrollView?.canvasScroll?.zoom(toFit: frame.frame.inset(by: 60))
    }

    /// What the window's header says while a tiling is up.
    ///
    /// It has to say *something*. A board showing six of forty-three cards, with the other
    /// thirty-seven hidden and the lines between them gone, looks exactly like a board most of which has
    /// been deleted — and the moment you think that is the moment you stop trusting the feature.
    var tilingSummary: (long: String, short: String)? {
        guard let tiling else { return nil }
        let total = document.nodes.filter { !$0.isGroup }.count
        let long = tiling.ids.count == 1 ? "1 card of \(total)"
                                         : "\(tiling.ids.count) of \(total) cards"
        return (long, "\(tiling.ids.count)/\(total)")
    }
}

/// The cards a frame contains — the ones whose centres fall inside it.
///
/// By centre rather than by containment, which is how a frame on a real board actually holds things: a
/// card nudged so its corner pokes out of the frame it belongs to is still in the group, and every
/// other part of this app agrees (see `canvasDragSet`).
func canvasCardsInside(_ frame: CanvasRect, of document: CanvasDocument) -> Set<String> {
    Set(document.nodes.filter { node in
        !node.isGroup && frame.contains(x: node.frame.midX, y: node.frame.midY)
    }.map(\.id))
}

// MARK: - Frames a tab can be pinned to

@MainActor
extension CanvasBoardView {
    /// A frame's name, or nil when there is no such frame any more.
    ///
    /// Nil is the interesting answer: a tab pinned to a frame somebody has since deleted in Obsidian
    /// should say so rather than disappear, because a tab vanishing out of the bar is alarming in a way
    /// that a tab reading "Frame" is not.
    func frameLabel(_ id: String) -> String? {
        guard let node = document.node(id: id), node.isGroup,
              case .group(let label, _, _) = node.content else { return nil }
        return (label?.isEmpty == false) ? label : "Untitled Frame"
    }

    /// Every frame on the board, in reading order, as (id, name) — what the add menu offers.
    var frameChoices: [(id: String, name: String)] {
        frames.map { node in
            var name = "Untitled Frame"
            if case .group(let label, _, _) = node.content, let label, !label.isEmpty { name = label }
            return (node.id, name)
        }
    }

    /// Show a frame: fit it in the window and select what is in it. The same act as ⌃1…9, addressed by
    /// id rather than by position, because a tab holds the frame rather than the slot it happened to
    /// be in when the tab was made.
    func goTo(frame id: String) {
        guard let node = document.node(id: id), node.isGroup else { return }
        if isTiled { leaveTiling(animated: false) }
        selection = canvasCardsInside(node.frame, of: document)
        scrollView?.canvasScroll?.zoom(toFit: node.frame.inset(by: 60))
    }
}

/// What one pane hands the next when a tab switch crosses between the canvas and one of its workspaces.
///
/// A window's tabs are separate panes with separate boards, hidden and shown rather than swapped in
/// place, so the crossing the user sees is not something either board is doing — it is something the
/// *window* is doing to two of them. This is the whole of what has to travel for the board arriving to
/// be able to draw it: where the board before it was looking, how far in, and what it was showing.
///
/// See `CanvasBoardView.poseAsTiling`, `CanvasPaneController.arrive(from:)` and
/// `ProjectSplitViewController.applySelectedTab`, which are the three ends of it.
struct CanvasArrival {
    var zoom: Double
    var centre: CanvasPoint
    /// The workspace the pane being left behind was showing, or nil when it was showing the canvas.
    var tiling: CanvasTileSession?
}
