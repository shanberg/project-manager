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

    /// ⌘Return. Fill the window with the selection, or with what is on screen when nothing is selected.
    ///
    /// Pressed *inside* a tiling it drills in rather than leaving: with one tile picked out of six, the
    /// obvious next thing to want is that one filling the window, and Escape then comes back to the six
    /// before it comes back to the board. That is the same command meaning the same thing at a third
    /// scale — a card, a handful, the board — rather than a second key for going deeper.
    ///
    /// With nothing left to narrow to — one tile, or all of them picked — it is the way out, and it
    /// goes all the way out. See `leaveTiling`, and `CanvasTiling.commandTitle`, which has been calling
    /// this case "Leave Tiled View" the whole time.
    @objc func tileSelection(_ sender: Any?) {
        if let session = tiling {
            let picked = selection.intersection(session.ids)
            guard !picked.isEmpty, picked.count < session.ids.count else {
                // Nothing left to drill into, so this is the other end of the command: the board.
                // Not `untile`, which unwinds one level — from a card you had drilled into, that
                // handed you back the tiling you came from, and the next press drilled straight into
                // it again. ⌘↩ alternated between the two forever with the card still filling the
                // window, which is the one way out of a tiling that has to work.
                return leaveTiling(animated: true)
            }
            tilingHistory.append(session)
            return tile(picked)
        }
        let ids = tileTargets
        guard !ids.isEmpty else { return NSSound.beep() }
        tile(ids)
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
        // Nothing selected: everything you can currently see. A board you have scrolled to a corner of
        // is a selection you made with the scroll bar.
        if ids.isEmpty {
            let visible = canvasRect(visibleRect)
            ids = Set(document.nodes.filter { !$0.isGroup && $0.frame.intersects(visible) }.map(\.id))
        }
        return ids
    }

    /// What ⌘Return is called right now. See `CanvasTiling.commandTitle`, which owns the wording.
    var tileCommandTitle: String {
        CanvasTiling.commandTitle(tiled: tiling?.ids.count,
                                  picked: tiling.map { selection.intersection($0.ids).count } ?? 0,
                                  // Not asked for when nothing is selected: `tileTargets` would scan
                                  // the visible region to answer, and the wording does not use it.
                                  targets: isTiled || selection.isEmpty ? 0 : tileTargets.count,
                                  selected: !selection.isEmpty)
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
        // **Which workspace this is now, and the one place a named one is left.**
        //
        // ⌘Return does not mean "adjust this"; it means "these cards, now" — it is the act that made
        // the workspace in the first place, and it is the only tiling command that replaces the set
        // wholesale rather than editing it. So it starts a fresh, unnamed workspace and leaves the
        // named one exactly as it was. That carve-out is what makes writing an adjustment straight back
        // to a named workspace safe enough to do without a Save (docs/canvas-workspaces.md §7b), since
        // a tiling has no undo to fall back on.
        //
        // Two things are not that act, and both keep the name. `remembered` applying means these are
        // the same cards as the workspace you just left, so you are resuming it rather than building
        // another. A non-empty history means you are drilling *into* the one you are already in, which
        // Escape unwinds — and a drill-in that renamed the board's workspace to nothing would strand
        // you, one press from a tiling with no name and nowhere to put it back.
        //
        // **What is left behind keeps a tab**, rather than only a line in a menu. The workspace you
        // were in still exists in the durable store and is still one click away — and now the click is
        // on a chip beside this one, because the window is where the workspaces you have open live
        // (docs/canvas-workspaces.md §7c). It is the pane in front of you that becomes the fresh
        // Untitled one, since that is the pane holding the selection this command just acted on.
        if remembered == nil, tilingHistory.isEmpty {
            let left = workspaceName
            workspaceName = nil
            left.map(onLeftWorkspace)
        }
        // **At 100%, whatever the board was at.** A tiling fills the window with cards, and on a board
        // zoomed out to 40% — where you nearly always are when you decide to fill the window with
        // something — it would fill it with cards whose text is at 40%. Filling the window is a request
        // to *read* the thing, so the zoom is part of what the command means rather than something it
        // happens to inherit. Set before the area is measured: `tileableRect` is in canvas coordinates,
        // and how much canvas the window covers is exactly what just changed.
        let restoreZoom = tiling?.restoreZoom ?? Double(scrollView?.magnification ?? 1)
        scrollView?.canvasScroll?.setZoom(1)
        let area = tileableRect
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
        setLayout(session.layout, animated: true)
        onTilingChanged?()
        announceTiling()
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
    func restoreTiling(_ remembered: CanvasViewState.Tiling, named name: String? = nil) {
        let live = remembered.ids.filter { document.node(id: $0).map { !$0.isGroup } ?? false }
        guard !live.isEmpty else { return }
        workspaceName = name
        // Whatever you were drilled into belonged to the workspace being replaced. Left behind, Escape
        // would hand you back a narrowing of a workspace you are no longer in.
        tilingHistory.removeAll()
        // The zoom a tiling is shown at, and the fitted zoom to hand back on the way out — the same
        // two `tile` sets, arrived at the same way round. See there for why.
        let restoreZoom = Double(scrollView?.magnification ?? 1)
        scrollView?.canvasScroll?.setZoom(1)
        let session = CanvasTileSession(ids: live,
                                        arrangement: remembered.arrangement,
                                        masterFraction: remembered.masterFraction,
                                        // Only for cards that are still here: a size left behind for a
                                        // deleted card would come back the moment its id was reused.
                                        sizes: (remembered.sizes ?? [:]).filter { live.contains($0.key) },
                                        area: tileableRect,
                                        // Where leaving puts you back. Not remembered: it is the region
                                        // the board would be showing anyway, which on one just opened
                                        // is the whole of it — the right place to be returned to.
                                        restoreVisible: canvasRect(visibleRect),
                                        restoreZoom: restoreZoom)
        tiling = session
        lastTiling = memory(of: session)
        selection = [live[0]]
        setLayout(session.layout, animated: false)
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

    /// Escape. Back out one level of drill-in — **and stop at the root.**
    ///
    /// It used to keep going: at the root of the stack the next Escape left the tiled view altogether.
    /// That was one step too far. A tiled view is where you are *working*, and Escape is the key that
    /// dismisses a menu, cancels a field and steps out of a card — all of them smaller acts that
    /// happen *inside* a workspace. Making the same key also close the workspace means every cancelled
    /// edit is one keystroke away from tearing down a workspace you built by hand.
    ///
    /// So at the root it does nothing, which is the right amount for a key with nothing left to cancel.
    /// Leaving has its own three doors and always did: ⌘↩, the header's ✕, and stepping to a frame.
    /// See `leaveTiling`.
    func untile(animated: Bool) {
        guard tiling != nil, let previous = tilingHistory.popLast() else { return }
        tiling = previous
        selection = selection.intersection(previous.ids)
        setLayout(previous.layout, animated: animated)
        onTilingChanged?()
        announceTiling()
    }

    /// Leave the tiled view altogether, however deep into it you have drilled.
    ///
    /// **Escape unwinds; everything else leaves.** The drill-in is a stack and backing out of it one
    /// level at a time is exactly what Escape is for — see `untile`. Every other way out means the
    /// board and says so: ⌘↩ is one command at both ends, the header's ✕ is labelled "leave the
    /// tiled view", and stepping to a frame is a request to go and look at somewhere else.
    ///
    /// **What is kept is the workspace you built, not the card you left through.** The order you
    /// dragged the tiles into and the widths you set are the deliberate work; a fullscreen card you
    /// drilled into to read is not something to hand back the next time you tile those cards. So the
    /// stack's root is the session that gets remembered — see `CanvasViewState.lastTiling`.
    func leaveTiling(animated: Bool) {
        guard let current = tiling else { return }
        let session = tilingHistory.first ?? current
        tilingHistory.removeAll()
        // Step out of whatever tile you were typing in. Engagement is the tiled view's own doing — see
        // `tileClicked` — and leaving it holding would hand back a board with one card open in an
        // editor, which is a state you never asked the board for.
        for id in current.ids { nodeViews[id]?.engage(false) }
        // Kept, not discarded — see `CanvasViewState.lastTiling`.
        lastTiling = memory(of: session)
        tiling = nil
        // **The view first, then the cards.** Both halves of leaving change where a card is drawn: the
        // zoom changes how canvas coordinates map to the window, and the layout changes which canvas
        // coordinates each card has. Done the other way round — as this was — the cards are set
        // animating toward frames measured in the old zoom, and the magnification changes out from
        // under the animation while it runs. What lands is every card at its 100% size on a board that
        // is now at 35%, which is one card filling the window and the rest somewhere off the edge of it.
        scrollView?.canvasScroll?.setZoom(CGFloat(session.restoreZoom))
        scrollView?.canvasScroll?.centre(on: CanvasPoint(x: session.restoreVisible.midX,
                                                         y: session.restoreVisible.midY))
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
    /// **Every level of the drill-in, not only the one you can see.** Drilled into one card and asked
    /// for a link, you get two tiles; Escape then has to hand you back the six you came from *plus*
    /// the new one. Adding only to the visible session would instead make the card vanish on the way
    /// out — you would have added something to a view that was about to be discarded, which is the one
    /// outcome nobody could have meant. `removeFromTiling` is symmetric for the same reason.
    ///
    /// A frame is a container of cards rather than a card, so there is no tile it could be.
    func addToTiling(_ id: String) {
        guard var session = tiling, document.node(id: id).map({ !$0.isGroup }) ?? false else { return }
        session.add(id)
        guard session != tiling else { return }
        for index in tilingHistory.indices { tilingHistory[index].add(id) }
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
        for position in tilingHistory.indices { tilingHistory[position].remove(id) }
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
        for id in gone {
            next.remove(id)
            for index in tilingHistory.indices { tilingHistory[index].remove(id) }
        }
        // A level of the drill-in that has lost everything is a level Escape would back out *into*,
        // which is a blank window. Unlike in `removeFromTiling`, where a level always keeps at least
        // one card, a delete can empty one outright.
        tilingHistory.removeAll { $0.ids.isEmpty }
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
