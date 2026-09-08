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
        // A frame is a container of cards, so tiling one means tiling what is in it. This is the
        // "frames are workspaces" reading, and it is the one command where it pays off immediately.
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
    func restoreTiling(_ remembered: CanvasViewState.Tiling) {
        let live = remembered.ids.filter { document.node(id: $0).map { !$0.isGroup } ?? false }
        guard !live.isEmpty else { return }
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

    /// The arrangement this board would carry into another session: the one that is up, or the last one
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

    /// Escape. Back out one level: to the tiling you drilled in from, or to the board.
    ///
    /// One level is Escape's whole meaning and it is the only caller that wants it. Anything that means
    /// "leave the tiled view" wants `leaveTiling`.
    func untile(animated: Bool) {
        guard let session = tiling else { return }
        if let previous = tilingHistory.popLast() {
            tiling = previous
            selection = selection.intersection(previous.ids)
            setLayout(previous.layout, animated: animated)
            onTilingChanged?()
            announceTiling()
            return
        }
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

    /// Leave the tiled view altogether, however deep into it you have drilled.
    ///
    /// **Escape unwinds; everything else leaves.** The drill-in is a stack and backing out of it one
    /// level at a time is exactly what Escape is for — see `untile`. Every other way out means the
    /// board and says so: ⌘↩ is one command at both ends, the header's ✕ is labelled "leave the
    /// tiled view", and stepping to a frame is a request to go and look at somewhere else. All four
    /// used to call `untile`, so all four stopped one short.
    ///
    /// **What is kept is the arrangement you built, not the card you left through.** The order you
    /// dragged the tiles into and the widths you set are the deliberate work; a fullscreen card you
    /// drilled into to read is not something to hand back the next time you tile those cards. So the
    /// stack's root becomes the session `untile` remembers — see `CanvasViewState.lastTiling`.
    func leaveTiling(animated: Bool) {
        guard tiling != nil else { return }
        if let root = tilingHistory.first {
            tilingHistory.removeAll()
            // Assigned rather than laid out: nothing is drawn from it, and `untile` is about to
            // replace the layout wholesale. This is only about which session it keeps.
            tiling = root
        }
        untile(animated: animated)
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

    /// Make the focused card the master tile — ⌘⇧Return, and a double-click on a stack tile.
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

    // MARK: Frames as workspaces

    /// The board's frames, in reading order — the workspaces you can step between.
    ///
    /// A frame is already a named container of cards, which is what a workspace is. Nothing had to be
    /// built for this; it only had to be noticed.
    var workspaces: [CanvasNode] {
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
    @objc func goToWorkspace(_ sender: Any?) {
        guard let index = (sender as? NSMenuItem)?.tag, index >= 0 else { return }
        let frames = workspaces
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
        workspaces.map { node in
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
