import AppKit
import PmLib

/// The board's mouse and keyboard.
///
/// One gesture at a time, decided on mouse-down by asking the hit tester what is under the pointer and
/// then held in `gesture` until mouse-up. Nothing here reads the document to decide *what* a click
/// means — that is the hit tester's job, and it is tested without a window — so this is only about
/// carrying a gesture through and turning it into a change.
extension CanvasBoardView {

    var hitTester: CanvasHitTester {
        CanvasHitTester(document: document, scale: liveScale, mode: mode,
                        selection: selection, hovered: hovered, layout: layout)
    }

    private func point(_ event: NSEvent) -> CanvasPoint {
        canvasPoint(convert(event.locationInWindow, from: nil))
    }

    // MARK: Pressing

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let where_ = point(event)
        let extending = event.modifierFlags.contains(.shift) || event.modifierFlags.contains(.command)

        // **A tiled view has no second meaning for a second click**, so the double-click branch is the
        // board's alone. Reached while tiled it answered from the *document's* hit test, which knows
        // nothing about the tiling: over a handlebar — which sits out in the gap, deliberately never on
        // the card (see `tileHandle`) — that reads as the background, and double-clicking the one
        // control you are meant to grab added a card to the board. The handlebar drags. That is all it
        // does; everything else a tile can be told is in the View menu and in its contextual menu.
        if event.clickCount == 2, !isTiled {
            doubleClick(at: where_)
            return
        }

        if isTiled { return tiledMouseDown(at: where_, extending: extending) }

        switch hitTester.hit(where_) {
        case .handle(let id, let handle):
            guard document.node(id: id) != nil else { return }
            // Grabbing a card's edge picks it, the way clicking a window's edge brings it forward. In
            // connect mode this is already true — the band is only offered on the selection — but in view
            // mode the edge belongs to whatever card is under it, and a drag there that left the
            // selection alone would be the one gesture on the board that acts on something it hasn't
            // said it is acting on.
            //
            // Grabbing the edge of a card that is *already* in a selection of several resizes the whole
            // selection, which is the other half of the same rule: the gesture acts on what the board
            // says is selected, and quietly dropping five of six cards because you took hold of the
            // sixth would be the board changing the subject.
            if !selection.contains(id) { selection = [id] }
            guard let resizing = framesOfResizeSet(), let box = resizing.box else { return }
            store.beginInteraction(resizing.frames.count > 1 ? "Resize Cards" : "Resize Card")
            gesture = .resize(handle, from: where_, originals: resizing.frames, box: box)

        case .anchor(let id, let side):
            gesture = .connect(from: id, side: side, to: where_)
            overlay.needsDisplay = true

        case .node(let id):
            if !selection.contains(id) {
                selection = extending ? selection.union([id]) : [id]
            } else if extending {
                selection.remove(id)
                return
            }
            store.beginInteraction(selection.count > 1 ? "Move Cards" : "Move Card")
            gesture = .move(from: where_, frames: framesOfDragSet())

        case .edge(let id):
            selection = extending ? selection.union([id]) : [id]

        case .board:
            let base = extending ? selection : []
            if !extending { selection = [] }
            gesture = .marquee(from: where_, additive: extending, base: base)
        }
    }

    /// A press inside a tiled view.
    ///
    /// There is no free space to move a card into and nothing to sweep or wire together, so the whole
    /// vocabulary is: pick a tile, drag its handlebar to move it along the order, drag it onto another
    /// to swap the two, or drag a boundary to change how the room is divided. A press on the background
    /// leaves the tiling, which is the tiled equivalent of clicking the desktop.
    ///
    /// The handlebar is asked first because it is drawn *inside* a tile, so a hit test on the card
    /// would answer for it; the boundary is asked next because it lies in the gap, where the card's own
    /// band would otherwise catch it.
    private func tiledMouseDown(at where_: CanvasPoint, extending: Bool) {
        if let id = tileHandle(at: where_), let frame = tiling?.layout.frames[id] {
            selection = [id]
            gesture = .reorderTile(id, grab: CanvasPoint(x: where_.x - frame.minX,
                                                         y: where_.y - frame.minY),
                                   displaced: nil)
            return
        }
        if let divider = tileDivider(at: where_) {
            gesture = .resizeTiles(divider, from: where_, lengths: lengths(of: divider))
            return
        }
        switch hitTester.hit(where_) {
        case .node(let id), .handle(let id, _), .anchor(let id, _):
            selection = extending ? selection.union([id]) : [id]
            gesture = .swap(from: id, over: nil)
        case .edge, .board:
            selection = []
        }
    }

    /// How long each tile in a boundary's run is right now, along the axis that run flows in.
    ///
    /// Measured off the laid-out frames rather than recomputed from the sizes, so a drag starts from
    /// what is on screen — including a run whose pins have been squeezed by a window too small to
    /// honour them. Dragging from the numbers that were *asked for* rather than the ones you can see
    /// would make the tile jump on the first pixel of the gesture.
    private func lengths(of divider: CanvasTileDivider) -> [Double] {
        guard let tiling else { return [] }
        if divider.isMasterSplit {
            guard let master = tiling.layout.frames[tiling.ids[0]] else { return [] }
            return [master.width, tiling.area.inset(by: -CanvasTiling.edgeGap).width
                        - CanvasTiling.gap - master.width]
        }
        return divider.run.compactMap { index in
            tiling.layout.frames[tiling.ids[index]].map { divider.isVertical ? $0.width : $0.height }
        }
    }

    // MARK: Dragging

    override func mouseDragged(with event: NSEvent) {
        let now = point(event)
        switch gesture {
        case .swap(let from, _):
            // The tile under the pointer, if it is a different one. Held on the gesture so the overlay
            // can show what the drop would do rather than making you guess.
            let over: String?
            switch hitTester.hit(now) {
            case .node(let id), .handle(let id, _), .anchor(let id, _): over = id == from ? nil : id
            case .edge, .board: over = nil
            }
            if case .swap(_, let previous) = gesture, previous != over {
                gesture = .swap(from: from, over: over)
                overlay.needsDisplay = true
            }

        case .resizeTiles(let divider, let from, let lengths):
            dragTileDivider(divider, from: from, to: now, lengths: lengths)

        case .reorderTile(let id, let grab, let displaced):
            // The card comes with you. Held off its slot rather than animating into each new one: what
            // is being dragged is the card, and a card that stayed in the grid while the pointer moved
            // would be a gesture you have to take on trust. Only this card moves on this event — see
            // `layoutCarriedCard`, and the tiles it deliberately leaves in flight.
            if let frame = tiling?.layout.frames[id] {
                reordering = (id, CanvasRect(x: now.x - grab.x, y: now.y - grab.y,
                                             width: frame.width, height: frame.height))
                layoutCarriedCard()
            }
            // The tile under the pointer decides where this one goes. Applied as you cross rather than
            // on the drop, so the arrangement rearranges itself under your hand and the order you are
            // making is the one you can see — but only once per crossing, which is
            // `CanvasTileSession.reorder`'s whole subject and the reason a drag held still over the
            // middle of the window no longer flickers.
            var over: String?
            if case .node(let hit) = hitTester.hit(now) { over = hit }
            let step = CanvasTileSession.reorder(carrying: id, over: over, displaced: displaced)
            if step.displaced != displaced {
                gesture = .reorderTile(id, grab: grab, displaced: step.displaced)
            }
            guard let onto = step.displace, let index = tiling?.ids.firstIndex(of: onto) else { break }
            moveInTiling(id, to: index)

        case .move(let from, let frames):
            let wanted = (dx: now.x - from.x, dy: now.y - from.y)
            let box = frames.values.dropFirst().reduce(frames.values.first ?? .init(x: 0, y: 0, width: 0, height: 0)) {
                $0.union($1)
            }
            let snap = CanvasSnapping.move(box, by: wanted,
                                           against: snapCandidates(excluding: Set(frames.keys)),
                                           reach: snapReach(event),
                                           snapsToGrid: snapsToGrid(event))
            let dx = snap.frame.minX - box.minX, dy = snap.frame.minY - box.minY
            guideView.guides = snap.guides
            showGrid(snapsToGrid(event))
            store.change("Move Card") { doc in
                for index in doc.nodes.indices {
                    guard let original = frames[doc.nodes[index].id] else { continue }
                    doc.nodes[index].frame.x = original.x + dx
                    doc.nodes[index].frame.y = original.y + dy
                }
            }

        case .resize(let handle, let from, let originals, let box):
            // The box is snapped, and then the cards are fitted into whatever box that produced. Doing
            // it the other way round — snapping each card and taking the box of the results — would
            // give a selection of six six chances to catch on something, and a box that jumped between
            // them as you dragged.
            let wanted = handle.resize(box, by: (dx: now.x - from.x, dy: now.y - from.y))
            let snap = CanvasSnapping.resize(wanted, handle: handle,
                                             against: snapCandidates(excluding: Set(originals.keys)),
                                             reach: snapReach(event),
                                             snapsToGrid: snapsToGrid(event))
            guideView.guides = snap.guides
            showGrid(snapsToGrid(event))
            let settled = CanvasGroupResize.frames(originals, from: box, to: snap.frame)
            store.change(originals.count > 1 ? "Resize Cards" : "Resize Card") { doc in
                for index in doc.nodes.indices {
                    guard let frame = settled[doc.nodes[index].id] else { continue }
                    doc.nodes[index].frame = frame
                }
            }

        case .marquee(let from, let additive, let base):
            // **⌥ sweeps from the centre.** The press is the middle of the rectangle rather than one
            // of its corners, which is the modifier every drawing tool gives a dragged-out shape — and
            // it earns its place on a selection for the case a corner cannot reach: a cluster in the
            // middle of a crowded board, where every corner you could start from is inside another
            // card and starting there would drag *it* instead. Read on every event, so pressing and
            // releasing ⌥ mid-sweep re-anchors the rectangle under your hand.
            //
            // No collision with ⌥'s other meaning: a sweep does not snap, so there is nothing here for
            // it to turn off. ⇧ is spoken for on the way down — it is what makes the sweep additive.
            let reach = (dx: abs(now.x - from.x), dy: abs(now.y - from.y))
            let rect = event.modifierFlags.contains(.option)
                ? CanvasRect(x: from.x - reach.dx, y: from.y - reach.dy,
                             width: reach.dx * 2, height: reach.dy * 2)
                : CanvasRect(x: min(from.x, now.x), y: min(from.y, now.y),
                             width: reach.dx, height: reach.dy)
            let swept = canvasMarqueeSelection(rect, in: document)
            selection = additive ? base.union(swept) : swept
            overlay.marquee = rect
            overlay.needsDisplay = true

        case .connect(let id, let side, _):
            gesture = .connect(from: id, side: side, to: now)
            overlay.needsDisplay = true

        case nil:
            break
        }
        // **Not while tiled.** Autoscroll exists so that dragging a card toward the edge of the window
        // takes you further across the board — which is the right answer when the window is a porthole
        // onto a plane, and the wrong one when it is the thing being filled. A tiled view has no
        // elsewhere: the tiles were laid out for this window at this scroll position, and scrolling
        // during a drag slides the whole arrangement out from under the pointer while leaving it
        // exactly where it was in canvas coordinates. Two systems, and only one of them is a scroll
        // area — see `CanvasScrollView.scrollWheel`, which declines the same thing from the other side.
        //
        // **And not while resizing.** Every other gesture is carrying something across the board, and
        // the board scrolling under it is how you carry it somewhere off screen. A resize is the one
        // gesture anchored to what it is *not* moving — the opposite edge, which is the thing you are
        // sizing against — so panning while it runs drags that anchor out from under the card and the
        // edge you are holding stops corresponding to the pointer at all. A card sized against the
        // window's edge is exactly where you notice it, which is exactly where autoscroll fires.
        if !isTiled, gesture?.pansTheBoard == true { autoscroll(with: event) }
    }

    // MARK: Releasing

    override func mouseUp(with event: NSEvent) {
        defer {
            gesture = nil
            overlay.marquee = nil
            guideView.guides = []
            overlay.needsDisplay = true
            showGrid(false)
        }
        switch gesture {
        case .swap(let from, let over):
            if let over {
                swapInTiling(from, with: over)
            } else if let view = nodeViews[from], view.engagesOnClick, !view.isEngaged {
                view.beginEditing()
            }
        case .resizeTiles(let divider, _, _):
            rememberTileSizes(divider)

        case .reorderTile:
            // Let go: the card springs back into the slot it has already been given.
            reordering = nil
            settleIntoLayout()
        case .move(let from, _):
            store.endInteraction()
            stepIn(pressedAt: from, released: event)
        case .resize:
            store.endInteraction()
        case .connect(let id, let side, _):
            finishConnection(from: id, side: side, at: point(event))
        case .marquee, nil:
            break
        }
    }

    /// A click that didn't move a card steps into it — if it is the kind of card that takes clicks.
    ///
    /// Decided at mouse-*up*, and that is the whole trick: at mouse-down a press on a card is not yet
    /// distinguishable from the start of a drag, and a card that engaged on the way down would be a
    /// card you could no longer pick up. Press and move, and it is a move; press and let go without
    /// going anywhere, and the card is yours to use.
    ///
    /// One card only. A shift-click that adds a web card to a selection of six is a selection, not a
    /// request to start using it.
    private func stepIn(pressedAt start: CanvasPoint, released event: NSEvent) {
        guard event.clickCount == 1, selection.count == 1, let id = selection.first,
              let view = nodeViews[id], view.engagesOnClick, !view.isEngaged else { return }
        let now = point(event)
        let slop = 3 / liveScale
        guard abs(now.x - start.x) <= slop, abs(now.y - start.y) <= slop else { return }
        view.beginEditing()
    }

    /// Drop a dragged connection: onto a card, and there's a new line; onto empty board, and there's a
    /// new card already joined to the one you started from.
    ///
    /// The second is the one that makes wiring a board quick, and it is why the gesture ends here
    /// rather than being cancelled when it misses. A line to nowhere isn't a thing the format can hold.
    private func finishConnection(from id: String, side: CanvasSide, at where_: CanvasPoint) {
        switch hitTester.hit(where_) {
        case .node(let target), .handle(let target, _), .anchor(let target, _):
            guard target != id else { return }
            store.change("Connect Cards") { doc in
                doc.edges.append(CanvasEdge(fromNode: id, fromSide: side, toNode: target,
                                            toSide: side.opposite))
            }
        case .edge, .board:
            let size = CanvasRect(x: where_.x, y: where_.y - 30, width: 250, height: 60)
            let new = CanvasNode(content: .text(""), frame: size)
            store.change("Add Connected Card") { doc in
                doc.nodes.append(new)
                doc.edges.append(CanvasEdge(fromNode: id, fromSide: side, toNode: new.id,
                                            toSide: side.opposite))
            }
            selection = [new.id]
            beginEditing(new.id)
        }
    }

    /// The cards a drag can align to: everything that isn't moving, and that is somewhere near enough
    /// to be looking at.
    ///
    /// Restricted to the visible region — generously, but restricted. Aligning to a card five thousand
    /// points off screen is an agreement nobody asked for and can't see, and the guide drawn for it
    /// would reach off the window in both directions saying nothing.
    private func snapCandidates(excluding moving: Set<String>) -> [CanvasRect] {
        let region = canvasRect(visibleRect).inset(by: 400)
        return document.nodes
            .filter { !moving.contains($0.id) && $0.frame.intersects(region) }
            .map(\.frame)
    }

    /// How near counts as a snap, in canvas units — a fixed distance on screen, so it doesn't get
    /// coarser as you zoom out. ⌥ collapses it to nothing, which is the standard Mac override and the
    /// reason snapping can be on by default: the cases it gets wrong are one modifier away from right.
    private func snapReach(_ event: NSEvent) -> Double {
        event.modifierFlags.contains(.option) ? 0 : CanvasSnapping.reach / liveScale
    }

    private func snapsToGrid(_ event: NSEvent) -> Bool {
        !event.modifierFlags.contains(.option)
    }

    private func framesOfDragSet() -> [String: CanvasRect] {
        var frames: [String: CanvasRect] = [:]
        for id in canvasDragSet(selection, in: document) {
            frames[id] = document.node(id: id)?.frame
        }
        return frames
    }

    /// What a resize acts on: the selection itself, and the box around it.
    ///
    /// The selection rather than `canvasDragSet` — a frame *carries* what it holds when it is dragged,
    /// because that is what makes it a group, but resizing a frame is changing how much board it
    /// claims, and dragging its corner has never been a request to scale the cards inside it. Obsidian
    /// agrees, and so does every other tool with a container that isn't a layout.
    private func framesOfResizeSet() -> (frames: [String: CanvasRect], box: CanvasRect?)? {
        var frames: [String: CanvasRect] = [:]
        for id in selection { frames[id] = document.node(id: id)?.frame }
        guard !frames.isEmpty else { return nil }
        let box = frames.values.dropFirst().reduce(frames.values.first) { $0?.union($1) }
        return (frames, box)
    }

    // MARK: Panning

    /// Middle-drag pans the board.
    ///
    /// The gesture the board was missing for anyone on a mouse. A trackpad pans with two fingers, and
    /// that is what the scroll view already does; a wheel pans one axis at a time and needs ⇧ for the
    /// other, which is not a way to cross a board. Middle-drag is what every other canvas — Figma,
    /// Blender, a browser's PDF view — offers instead, and it costs no key and no mode.
    ///
    /// Nothing to pan in a tiled view: the tiles were laid out to fill the window, which is the same
    /// reason scrolling is swallowed there. See `CanvasScrollView.scrollWheel`.
    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2, !isTiled else { return super.otherMouseDown(with: event) }
        window?.makeFirstResponder(self)
        panGrab = convert(event.locationInWindow, from: nil)
        NSCursor.closedHand.push()
    }

    /// Keep the point you grabbed under the pointer.
    ///
    /// Stated as "put the grabbed point back" rather than "scroll by however far the mouse moved". The
    /// two agree — `convert` has already divided by the magnification, so a pan moves the board at the
    /// pointer's speed at every zoom — but only this one corrects itself. Each event is worked out from
    /// where the board actually is, so a scroll the clip view clamped at the edge of the content, or a
    /// content origin that moved underneath the gesture, leaves no accumulated drift: the board is
    /// stuck to the pointer rather than following it.
    override func otherMouseDragged(with event: NSEvent) {
        guard let grab = panGrab else { return super.otherMouseDragged(with: event) }
        let now = convert(event.locationInWindow, from: nil)
        let origin = visibleRect.origin
        scroll(NSPoint(x: origin.x + grab.x - now.x, y: origin.y + grab.y - now.y))
        // The scrollers don't follow a `scroll(_:)` on their own, and the board's own reaction to the
        // new region — building the cards that came into view, and deciding which pages are worth
        // running — rides on the bounds change this posts.
        scrollView.map { $0.reflectScrolledClipView($0.contentView) }
    }

    override func otherMouseUp(with event: NSEvent) {
        guard panGrab != nil else { return super.otherMouseUp(with: event) }
        panGrab = nil
        NSCursor.pop()
        refreshCursor()
    }

    // MARK: Scrolling a card

    /// A wheel over a card scrolls that card, whether or not you have stepped into it.
    ///
    /// The card cannot take this event itself. A card that isn't taking its own clicks returns nil from
    /// `hitTest`, so AppKit never offers it anything and the wheel arrives *here*, at the board, on its
    /// way up to the scroll view — which is the one place that knows both what is under the pointer and
    /// what that card has to scroll. So the board hands it down. (A tiled view never comes through
    /// here: its tiles hit-test, so the wheel reaches them the ordinary way.)
    ///
    /// Only what the pointer is on. Nothing chains: a wheel over a card that has nothing more to show
    /// stops there rather than starting to pan the board underneath it, because the card's own scroll
    /// view is what runs out and rubber-bands. A card with nothing to scroll at all passes the event
    /// back up and the board moves, which is the same board it has always been.
    override func scrollWheel(with event: NSEvent) {
        guard !forwardingScroll else { return super.scrollWheel(with: event) }
        // A new gesture picks a card; the rest of that gesture — its `.changed` events and the
        // momentum after them — stays with the one it picked. A wheel on a mouse has no phases at all
        // and so is a fresh aim every tick, which is right: there is no gesture to stay inside of.
        if event.phase.contains(.began) || (event.phase.isEmpty && event.momentumPhase.isEmpty) {
            scrollLatch = scrollTarget(for: event)
        }
        guard let target = scrollLatch else { return super.scrollWheel(with: event) }
        forwardingScroll = true
        target.scrollWheel(with: event)
        forwardingScroll = false
    }

    /// What a wheel at this point should scroll, or nil for the board itself.
    private func scrollTarget(for event: NSEvent) -> NSView? {
        // ⌘ is the board's: it zooms, here as in every other canvas. A card that took it would zoom
        // nothing and scroll instead, which is the wrong answer given twice.
        guard !event.modifierFlags.contains(.command) else { return nil }
        return card(under: canvasPoint(convert(event.locationInWindow, from: nil)))?.contentScroller
    }

    /// The card drawn under a point, topmost first.
    ///
    /// In the document's order rather than the subviews' — cards are added to the board as they scroll
    /// into view, so the subview order is the order you happened to meet them in and says nothing about
    /// which one is on top. `CanvasHitTester` reads the board the same way, and this is deliberately
    /// only the card's *face*: a grip or an edge band sits on top of a card for a click, but a wheel
    /// has no use for either and a ring of dead points inside a selected card would be inexplicable.
    func card(under point: CanvasPoint) -> CanvasNodeView? {
        for node in document.nodes.reversed()
        where !node.isGroup && layout.shows(node.id)
            && layout.frame(of: node).contains(x: point.x, y: point.y) {
            return nodeViews[node.id]
        }
        return nil
    }

    // MARK: Hovering

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingArea.map(removeTrackingArea)
        let area = NSTrackingArea(rect: bounds,
                                  options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited,
                                            .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        let where_ = point(event)
        var under: String?
        var line: String?
        switch hitTester.hit(where_) {
        case .node(let id), .handle(let id, _), .anchor(let id, _): under = id
        case .edge(let id): under = nil; line = id
        case .board: under = nil
        }
        // A tile's grip is outside the tile, so reaching for it means leaving the card — and a grip
        // that vanished on the way to being grabbed would be a control you can see and cannot use.
        // The pointer being on the bar counts as being on the tile it belongs to.
        if isTiled, let id = tileHandle(at: where_) { under = id }
        if under != hovered {
            hovered = under
            // A tiled view repaints too: the handlebar appears on the tile under the pointer, and it
            // is drawn a layer below the cards.
            if mode.showsConnectionAnchors { overlay.needsDisplay = true }
            if isTiled { refreshTileHandles() }
        }
        // A line is a thin thing to aim at, so it says when the pointer has found it. Only the two
        // curves involved are redrawn rather than the whole board — this runs on every mouse-moved
        // event, and a board of 43 lines redrawn on each would be a board that stutters when you move
        // the pointer across it.
        if line != hoveredEdge {
            for id in [hoveredEdge, line].compacted() {
                guard let edge = document.edges.first(where: { $0.id == id }),
                      let curve = canvasRoute(for: edge, in: document) else { continue }
                setNeedsDisplay(viewRect(curve.bounds.inset(by: 20)))
            }
            hoveredEdge = line
        }
        refreshCursor()
    }

    override func mouseExited(with event: NSEvent) {
        hovered = nil
        overlay.needsDisplay = true
        // Off the board altogether, straight from a card — the sidebar, the header, another window.
        // The same handover as `refreshCursor` makes between two tiles, and needed here for the same
        // reason: whatever the card set is still the screen's cursor, and out here there is no page
        // coming along behind to replace it.
        if cursorOwner != nil {
            cursorOwner = nil
            NSCursor.arrow.set()
        }
    }

    /// The card the pointer is inside, in the sense that the card is taking its own input there.
    ///
    /// `hitTest` already encodes the whole rule — the edge band and the drag handle stay the board's,
    /// the controls and the page are the card's — so asking it is both correct and impossible to get
    /// out of step with.
    private var cardUnderPointer: String? {
        guard let position = window?.mouseLocationOutsideOfEventStream else { return nil }
        let local = convert(position, from: nil)
        return nodeViews.first { $0.value.takesItsOwnClicks && $0.value.hitTest(local) != nil }?.key
    }

    /// The pointer over the board, and only over the board.
    ///
    /// The early return is the fix for a pointer that flickered several times a second over an engaged
    /// web card. A tracking area is not blocked by subviews, so the board went on receiving
    /// mouse-moved events over a page it no longer owned and went on setting the open hand for "you
    /// can drag this card" — while the page underneath set its own arrow, pointer or I-beam on the very
    /// same events. Two cursors set in alternation at the rate the mouse reports is exactly what a
    /// flickering pointer is.
    ///
    /// **Handing it over is not the same as never taking it back.** A cursor on macOS is one setting
    /// for the whole screen, held by whoever set it last, and a card that sets one keeps it until
    /// something else sets another. A playing video is the case that shows this: YouTube hides the
    /// pointer over a player nobody has moved for a few seconds, which is the page's business and
    /// right — but the invisible pointer it set is the *screen's* now, and it followed the pointer out
    /// of that tile and into the next one, where the page had no reason to send a cursor of its own
    /// and so nothing put it back. A pointer that vanishes over a video and is still missing over the
    /// tile beside it reads as the app having lost it.
    ///
    /// The gap between two tiles cannot be relied on to fix that. It is nine points wide; a pointer
    /// moved at any speed crosses it between two mouse-moved reports, and the board never gets the
    /// event in which it was over the gap and would have set a cursor. So the board watches for the
    /// pointer *changing hands* instead, and takes the cursor back at that moment — once, and then
    /// leaves the new card to it, which is what the page's next mouse-moved does with a page that has
    /// anything to say about the matter.
    func refreshCursor() {
        let owner = cardUnderPointer
        defer { cursorOwner = owner }
        if owner != nil {
            if cursorOwner != nil && cursorOwner != owner { NSCursor.arrow.set() }
            return
        }
        guard let position = window?.mouseLocationOutsideOfEventStream else { return }
        let where_ = canvasPoint(convert(position, from: nil))
        if isTiled {
            if tileHandle(at: where_) != nil { return NSCursor.openHand.set() }
            if let divider = tileDivider(at: where_) {
                return (divider.isVertical ? NSCursor.resizeLeftRight : .resizeUpDown).set()
            }
            return NSCursor.arrow.set()
        }
        switch hitTester.hit(where_) {
        case .handle(_, let handle): cursor(for: handle).set()
        case .anchor: NSCursor.crosshair.set()
        case .node: NSCursor.openHand.set()
        case .edge, .board: NSCursor.arrow.set()
        }
    }

    /// The pointer for an edge or a corner.
    ///
    /// `NSCursor.frameResize(position:directions:)` is the system's own answer, and it is the answer to
    /// the right question: these are the cursors macOS shows on a window's edges, which is exactly what
    /// a card's edges now are. It also retires a stand-in — there was no public diagonal resize cursor
    /// before macOS 15, so the four corners used `.crosshair`, which says "this does something in two
    /// directions" and looks like a tool for drawing.
    ///
    /// `.all` rather than `.inward` or `.outward`: a card can be dragged either way from any of its
    /// edges, and the one-way variants are for an edge that has run out of room to go one of them.
    private func cursor(for handle: CanvasHandle) -> NSCursor {
        .frameResize(position: handle.resizePosition, directions: .all)
    }

    // MARK: Keys

    /// Escape backs out one step at a time, the way it does everywhere: out of a drill-in first, and
    /// only then out of a selection.
    ///
    /// **It stops at the root of a tiled view rather than leaving it** — see `untile`, which owns that
    /// argument. Nor does it clear the selection there: in a tiled view the selection is which tile the
    /// arrows and Return are about, and a tiling deliberately never has none (see `tile`).
    ///
    /// Here rather than only in `keyDown` because Escape reaches the board two ways. A page card hands
    /// the key to WebKit, which sends it back as this command rather than as a key event, and a card
    /// that isn't engaged passes it up to us.
    override func cancelOperation(_ sender: Any?) {
        if isTiled { untile(animated: true) } else { selection = [] }
    }

    override func keyDown(with event: NSEvent) {
        switch event.specialKey {
        case .delete, .deleteForward:
            deleteSelection()
        // ⌥ turns the arrows from "move this card" into "move to the next card", which is the gesture a
        // tiling window manager is built around and which a board has better information for than a
        // desktop does. See `CanvasNavigation`.
        case .leftArrow: arrow(.left, event)
        case .rightArrow: arrow(.right, event)
        case .upArrow: arrow(.up, event)
        case .downArrow: arrow(.down, event)
        default:
            if event.charactersIgnoringModifiers == "\u{1b}" {
                cancelOperation(nil)
            } else if event.charactersIgnoringModifiers == "\r", let only = selection.first {
                beginEditing(only)
            } else {
                super.keyDown(with: event)
            }
        }
    }

    private func arrow(_ direction: CanvasNavigation.Direction, _ event: NSEvent) {
        guard event.modifierFlags.contains(.option) else {
            let step = step(event)
            switch direction {
            case .left: return nudge(dx: -step, dy: 0)
            case .right: return nudge(dx: step, dy: 0)
            case .up: return nudge(dx: 0, dy: -step)
            case .down: return nudge(dx: 0, dy: step)
            }
        }
        moveFocus(direction, extending: event.modifierFlags.contains(.shift))
    }

    /// Move the selection to the neighbouring card in `direction`.
    ///
    /// With nothing selected it starts from the middle of what you are looking at, so the first press
    /// lands on the card nearest the centre of the window rather than doing nothing — the same courtesy
    /// a list gives when you press Down with no row selected.
    ///
    /// Shift extends rather than replaces, which is what shift means everywhere else in this app's
    /// selections. It also scrolls the card it lands on into view: a focus move you cannot see is a
    /// focus move that looks like nothing happened.
    func moveFocus(_ direction: CanvasNavigation.Direction, extending: Bool) {
        // One tile filling the window has no neighbours, and the arrows there mean the thing every
        // window manager means by them in that state: show me the next one. In the board's own reading
        // order, so cycling through a board is walking across it rather than shuffling it.
        if let tiling, tiling.ids.count == 1 { return cycleFullscreen(direction) }
        let candidates = focusCandidates
        guard !candidates.isEmpty else { return }
        let current = selection.compactMap { id in candidates.first { $0.id == id }?.frame }
            .reduce(nil) { (box: CanvasRect?, frame) in box.map { $0.union(frame) } ?? frame }
            ?? CanvasRect(x: canvasRect(visibleRect).midX, y: canvasRect(visibleRect).midY,
                          width: 0, height: 0)

        guard let next = CanvasNavigation.next(from: current, direction: direction,
                                               among: candidates.filter { !selection.contains($0.id) })
        else { return NSSound.beep() }
        selection = extending ? selection.union([next]) : [next]
        reveal(next)
    }

    /// Step the one filling the window on to the next card in the board's reading order.
    ///
    /// Left and up go back, right and down go forward, and it wraps — with one card on screen there is
    /// no edge of the board to run into, only a list to walk.
    private func cycleFullscreen(_ direction: CanvasNavigation.Direction) {
        guard let tiling, let showing = tiling.ids.first else { return }
        let all = CanvasTiling.order(document.nodes.filter { !$0.isGroup }
                                        .map { (id: $0.id, frame: $0.frame) })
        guard all.count > 1, let index = all.firstIndex(of: showing) else { return NSSound.beep() }
        let forward = direction == .right || direction == .down
        let next = all[(index + (forward ? 1 : all.count - 1)) % all.count]
        selection = [next]
        tile([next])
    }

    /// Every card the focus can land on, with the frame it is actually drawn at — so this follows a
    /// tiled arrangement rather than the positions the file records.
    private var focusCandidates: [(id: String, frame: CanvasRect)] {
        document.nodes.filter { !$0.isGroup && layout.shows($0.id) }
            .map { ($0.id, layout.frame(of: $0)) }
    }

    /// Bring a card into view if it isn't already, without moving the board when it is.
    private func reveal(_ id: String) {
        guard let node = document.node(id: id) else { return }
        let frame = layout.frame(of: node)
        let visible = canvasRect(visibleRect).inset(by: -40)
        guard !visible.contains(x: frame.midX, y: frame.midY) else { return }
        scrollView?.canvasScroll?.centre(on: CanvasPoint(x: frame.midX, y: frame.midY))
    }

    /// One point, or ten with shift — the same pair every Mac drawing surface uses.
    private func step(_ event: NSEvent) -> Double {
        event.modifierFlags.contains(.shift) ? 10 : 1
    }

    private func nudge(dx: Double, dy: Double) {
        guard !selection.isEmpty else { return }
        let moving = canvasDragSet(selection, in: document)
        store.change("Move Card") { doc in
            for index in doc.nodes.indices where moving.contains(doc.nodes[index].id) {
                doc.nodes[index].frame.x += dx
                doc.nodes[index].frame.y += dy
            }
        }
    }

    func deleteSelection() {
        guard !selection.isEmpty else { return }
        let going = selection
        store.change(going.count > 1 ? "Delete Cards" : "Delete Card") { doc in
            doc.nodes.removeAll { going.contains($0.id) }
            // A line whose card has gone goes with it. Leaving it would be a dangling edge — which the
            // renderer copes with, but which nothing would ever draw again, so it would sit in the file
            // accumulating.
            doc.edges.removeAll {
                going.contains($0.id) || going.contains($0.fromNode) || going.contains($0.toNode)
            }
        }
        selection = []
    }

    // MARK: Editing a card

    private func doubleClick(at where_: CanvasPoint) {
        switch hitTester.hit(where_) {
        case .node(let id), .handle(let id, _), .anchor(let id, _):
            selection = [id]
            beginEditing(id)
        case .edge, .board:
            let new = CanvasNode(content: .text(""),
                                 frame: CanvasRect(x: where_.x - 125, y: where_.y - 30,
                                                   width: 250, height: 60))
            store.change("Add Card") { $0.nodes.append(new) }
            selection = [new.id]
            beginEditing(new.id)
        }
    }

    /// Hand a card to whatever knows how to edit it — text opens an editor in place, a file card opens
    /// the file, a link card opens the page.
    func beginEditing(_ id: String) {
        refreshNodeViews()
        nodeViews[id]?.beginEditing()
    }

    func selectionChanged(from previous: Set<String>) {
        guard selection != previous else { return }
        for id in previous.union(selection) { nodeViews[id]?.selectionChanged() }
        overlay.needsDisplay = true
        // A selected tile shows its handlebar, and that is drawn under the cards.
        if isTiled { refreshTileHandles() }
        onSelectionChanged?(selection)
    }

    func select(_ ids: Set<String>) { selection = ids }
}

extension Sequence {
    /// The non-nil elements. Foundation grew `compacted()` for this on `Optional` sequences in a
    /// later SDK than this target's floor, so it is spelled out here.
    func compacted<Wrapped>() -> [Wrapped] where Element == Wrapped? { compactMap { $0 } }
}
