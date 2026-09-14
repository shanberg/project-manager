import AppKit
import PmLib

/// A link dragged off a card. A copy wherever it goes — the card it came from keeps it — and a link as
/// well outside the app, which is what a browser's address bar asks for. See `dragLink`.
extension CanvasBoardView: NSDraggingSource {
    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .copy : [.copy, .link]
    }
}

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
        // Space held is the hand: the press takes hold of the board, and nothing else. See
        // `holdForPanning`.
        if takesHoldWithSpace(event) { return }
        let where_ = point(event)
        let extending = event.modifierFlags.contains(.shift) || event.modifierFlags.contains(.command)

        // **Picking cards on the board, a click is a card going in or coming out** — see `pick`. Before
        // everything else, links included: nothing here is moved, selected, opened or followed, and a
        // double-click is still one pick rather than an add and a take-out.
        if isPicking {
            guard event.clickCount == 1 else { return }
            // Peeking, the card brought close answers as Return does, and anywhere else puts it back.
            if let peek = peeking {
                switch hitTester.hit(where_) {
                case .node(let id), .handle(let id, _), .anchor(let id, _):
                    id == peek.card ? finishPeek() : endPeek()
                case .edge, .board: endPeek()
                }
                return
            }
            switch hitTester.hit(where_) {
            case .node(let id), .handle(let id, _), .anchor(let id, _): pick(id)
            case .edge, .board: break
            }
            return
        }

        // **A link is the pointer's before it is the card's** — stepped in or not, tiled or not. Asked
        // before the double-click, so the second click of a pair on a link is still the link's rather
        // than a request to open the card under it. See `CanvasLinkZones`.
        if let pressed = link(at: convert(event.locationInWindow, from: nil)) {
            gesture = .link(pressed.url, from: where_)
            return
        }

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

        if isTiled {
            return tiledMouseDown(at: where_, extending: extending, clicks: event.clickCount)
        }

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
    private func tiledMouseDown(at where_: CanvasPoint, extending: Bool, clicks: Int) {
        // A tile's tab strip is its title bar. A click on a tab shows it; a drag on one pulls that card
        // out, or carries the tile when it is the only tab; and the rest of the strip carries the tile,
        // like the handlebar. Asked first, because the strip is not a card and nothing else answers
        // for it.
        if let owner = tabStrip(at: where_) {
            let chip = tabChip(at: where_)
            let id = chip?.card ?? owner
            if chip != nil { showTab(id) } else { selection = [id] }
            if clicks == 2 { return toggleMaximizeTile(id) }
            guard tiling?.tileFrames[id] != nil else { return }
            gesture = .placeTile(id, base: tiling?.tileFrames ?? [:], drop: nil,
                                 pulling: (chip?.count ?? 0) > 1)
            return
        }
        if let id = tileHandle(at: where_), tiling?.tileFrames[id] != nil {
            selection = [id]
            // **Double-clicking the bar maximizes the tile**, because the bar is the tile's title bar
            // and double-clicking a title bar is how a window is zoomed on this platform. The gesture
            // is already in people's hands; this is only the tiled reading of it. See
            // `toggleMaximizeTile`.
            if clicks == 2 { return toggleMaximizeTile(id) }
            gesture = .placeTile(id, base: tiling?.tileFrames ?? [:], drop: nil, pulling: false)
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
        tiling?.lengths(of: divider.run) ?? []
    }

    // MARK: Dragging

    override func mouseDragged(with event: NSEvent) {
        if let grab = spaceGrab { return pan(keeping: grab, under: event) }
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
            // A page squeezed too narrow to read says so while the boundary is moving.
            overlay.needsDisplay = true

        case .placeTile(let id, let base, let drop, let pulling):
            // **A proxy comes with you, and nothing else moves.** The tile stays in its slot, dimmed,
            // and the tiles around it stay where they are until you let go — a board rearranging
            // itself under the pointer was a target that moved while you aimed at it (docs/canvas-
            // workspaces.md §7k). So only the overlay redraws on this event.
            dragPoint = now
            overlay.needsDisplay = true
            // What letting go here would do: near a tile's edge is a place beside it, the top band is
            // its tabs, and the middle is a swap. Marked on the tiles as they stand, and remarked only
            // when the answer changes.
            //
            // A tab pulled out of a tile of several can land beside the tile it came from — that is
            // the commonest place for it — but not back into its own tabs, which is where it already
            // is. Its middle joins a tile's tabs rather than swapping, since one card is not a tile.
            let under = base.first { ($0.key != id || pulling) && $0.value.contains(x: now.x, y: now.y) }
            var next = under.map {
                (target: $0.key, drop: CanvasTileSession.drop(at: now, on: $0.value,
                                                              middle: pulling ? .beside(.tab) : .swap))
            }
            if next?.target == id, next?.drop == .beside(.tab) { next = nil }
            guard next?.target != drop?.target || next?.drop != drop?.drop else { break }
            gesture = .placeTile(id, base: base, drop: next, pulling: pulling)
            previewDrop(of: id, next, pulling: pulling)

        case .move(let from, let frames):
            let wanted = (dx: now.x - from.x, dy: now.y - from.y)
            let box = frames.values.dropFirst().reduce(frames.values.first ?? .init(x: 0, y: 0, width: 0, height: 0)) {
                $0.union($1)
            }
            let snap = CanvasSnapping.move(box, by: wanted,
                                           against: snapCandidates(excluding: Set(frames.keys)),
                                           reach: snapReach(event),
                                           showReach: ghostReach(event),
                                           snapsToGrid: snapsToGrid(event))
            let dx = snap.frame.minX - box.minX, dy = snap.frame.minY - box.minY
            // The offer is made about the box and drawn about the cards: a rectangle around three
            // dragged cards is a shape none of them has, and an outline you cannot match a card to is
            // not a target. The same translation the cards are getting, applied to where they are now.
            //
            // The matches take no translation at all — they are about cards standing still, and those
            // are where they are.
            overlay.ghost = snap.ghost.map { ghost in
                let gdx = ghost.frame.minX - box.minX, gdy = ghost.frame.minY - box.minY
                return CanvasOverlayView.Ghost(
                    ghost,
                    frames: frames.keys.sorted().compactMap { frames[$0] }.map {
                        CanvasRect(x: $0.x + gdx, y: $0.y + gdy, width: $0.width, height: $0.height)
                    },
                    beneath: standingCards(excluding: Set(frames.keys)))
            }
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
                                             showReach: ghostReach(event),
                                             snapsToGrid: snapsToGrid(event))
            // Fitted into the offered box by the same function that fits them into the settled one, so
            // the outline is exactly the frame each card would get and not an approximation of it.
            overlay.ghost = snap.ghost.map { ghost in
                let fitted = CanvasGroupResize.frames(originals, from: box, to: ghost.frame)
                return CanvasOverlayView.Ghost(
                    ghost,
                    frames: fitted.keys.sorted().compactMap { fitted[$0] },
                    beneath: standingCards(excluding: Set(originals.keys)))
            }
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

        case .link(let url, let from):
            // Past the slop a press on a link is a drag of the link. Handed to AppKit as a real drag,
            // so it can go anywhere a link can — and when it comes back down on this board the drop
            // reads it like any other and makes it a card, or in a tiled view a tile.
            let slop = 3 / liveScale
            guard abs(now.x - from.x) > slop || abs(now.y - from.y) > slop else { break }
            gesture = nil
            dragLink(url, with: event)

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
        if spaceGrab != nil {
            spaceGrab = nil
            return refreshCursor()
        }
        defer {
            gesture = nil
            overlay.marquee = nil
            overlay.ghost = nil
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
            overlay.needsDisplay = true

        case .placeTile(let id, _, let drop, let pulling):
            // Let go: what the mark said happens, and the tiles move — once, now.
            dragPoint = nil
            finishDrop(of: id, drop, pulling: pulling)
        case .move(let from, _):
            store.endInteraction()
            stepIn(pressedAt: from, released: event)
        case .resize:
            store.endInteraction()
        case .connect(let id, let side, _):
            finishConnection(from: id, side: side, at: point(event))
        case .link(let url, _):
            // Let go without going anywhere: follow it. The first click of a run only — a
            // double-click on a link is one link, opened once.
            if event.clickCount == 1 { NSWorkspace.shared.open(url) }
        case .marquee, nil:
            break
        }
    }

    // MARK: Links

    /// The link under `point`, in the board's coordinates, on the card a press there would go to.
    ///
    /// Only in view mode: connecting is wiring cards together, and the whole of a card is the thing
    /// being wired. And never on a tiled view's own chrome — the handlebar and the boundaries answer
    /// first there, as they do for every other press.
    func link(at point: NSPoint) -> (card: String, url: URL)? {
        guard mode == .view else { return nil }
        let where_ = canvasPoint(point)
        if isTiled, tileHandle(at: where_) != nil || tileDivider(at: where_) != nil { return nil }
        guard case .node(let id) = hitTester.hit(where_),
              let url = nodeViews[id]?.link(at: point) else { return nil }
        return (id, url)
    }

    /// Carry a link off the card it is drawn on.
    ///
    /// Written the way a browser writes a dragged link — the address as `public.url` and again as text
    /// — so a browser, a text field and this board all read it; a link to a file goes as the file, so
    /// it lands as a file card rather than a card of its `file://` address. See `CanvasDrop.read`.
    private func dragLink(_ url: URL, with event: NSEvent) {
        let item = NSPasteboardItem()
        if url.isFileURL {
            item.setString(url.absoluteString, forType: .fileURL)
        } else {
            item.setString(url.absoluteString, forType: .URL)
            item.setString(url.absoluteString, forType: .string)
        }
        let dragging = NSDraggingItem(pasteboardWriter: item)
        let picture = Self.linkDragPicture(url)
        let at = convert(event.locationInWindow, from: nil)
        dragging.setDraggingFrame(NSRect(x: at.x - picture.size.width / 2,
                                         y: at.y - picture.size.height / 2,
                                         width: picture.size.width, height: picture.size.height),
                                  contents: picture)
        beginDraggingSession(with: [dragging], event: event, source: self)
    }

    /// What a dragged link looks like until it is over a board, which turns it into the card it will be
    /// (`carry`): the page's host, or the file's name, on a capsule.
    private static func linkDragPicture(_ url: URL) -> NSImage {
        let name = url.isFileURL ? url.lastPathComponent : (url.host() ?? url.absoluteString)
        let label = NSAttributedString(string: name, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.labelColor,
        ])
        let text = label.size()
        let size = NSSize(width: ceil(min(text.width, 280)) + 24, height: 24)
        return NSImage(size: size, flipped: false) { rect in
            let capsule = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
                                       xRadius: rect.height / 2, yRadius: rect.height / 2)
            NSColor.windowBackgroundColor.setFill()
            capsule.fill()
            NSColor.separatorColor.setStroke()
            capsule.stroke()
            label.draw(with: NSRect(x: 12, y: (rect.height - text.height) / 2,
                                    width: rect.width - 24, height: text.height),
                       options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            return true
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
    func snapCandidates(excluding moving: Set<String>) -> [CanvasRect] {
        let region = canvasRect(visibleRect).inset(by: 400)
        return document.nodes
            .filter { !moving.contains($0.id) && $0.frame.intersects(region) }
            .map(\.frame)
    }

    /// The cards the ghost is drawn beneath: every card on screen that isn't being placed.
    ///
    /// Not the frames. A frame is ground, painted by the board under everything, cards included — see
    /// `CanvasOverlayView.tuckBeneathStandingCards`.
    func standingCards(excluding moving: Set<String>) -> [CanvasRect] {
        let region = canvasRect(visibleRect)
        return document.nodes
            .filter { !$0.isGroup && !moving.contains($0.id) && $0.frame.intersects(region) }
            .map(\.frame)
    }

    /// How near counts as a snap, in canvas units — a fixed distance on screen, so it doesn't get
    /// coarser as you zoom out. ⌥ collapses it to nothing, which is the standard Mac override and the
    /// reason snapping can be on by default: the cases it gets wrong are one modifier away from right.
    private func snapReach(_ event: NSEvent) -> Double {
        event.modifierFlags.contains(.option) ? 0 : CanvasSnapping.reach / liveScale
    }

    /// How near counts as worth *offering*, in canvas units — the radius the ghost appears within,
    /// which is much wider than the snap's. See `CanvasGhost` for why the two are different numbers.
    /// ⌥ collapses it along with the snap it belongs to: the modifier means "leave me alone", and a
    /// board still offering matches would only be a quieter way of not doing that.
    private func ghostReach(_ event: NSEvent) -> Double {
        event.modifierFlags.contains(.option) ? 0 : CanvasSnapping.showReach / liveScale
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
        // The side buttons are Back and Forward, which is all they mean anywhere. A card you have not
        // stepped into doesn't take clicks, so the board is what hears them and hands them to the web
        // card under the pointer; a page taking its own clicks hears them itself — see
        // `CanvasPageView.historyStep`.
        if let step = CanvasPageView.historyStep(event) {
            guard !isTiled, let card = card(under: point(event)) as? CanvasLinkNodeView else {
                return super.otherMouseDown(with: event)
            }
            return step < 0 ? card.goBack() : card.goForward()
        }
        guard event.buttonNumber == 2, !isTiled else { return super.otherMouseDown(with: event) }
        window?.makeFirstResponder(self)
        panGrab = convert(event.locationInWindow, from: nil)
        NSCursor.closedHand.push()
    }

    override func otherMouseDragged(with event: NSEvent) {
        guard let grab = panGrab else { return super.otherMouseDragged(with: event) }
        pan(keeping: grab, under: event)
    }

    /// Space held down turns the pointer into a hand, and a drag with it pans.
    ///
    /// The middle button's gesture for everyone whose pointer hasn't got one — a trackpad most of all,
    /// where two fingers pan but a click-drag draws a marquee — and the one every canvas agrees on:
    /// Figma, Sketch, Photoshop, Illustrator. Only with nothing stepped into, because Space inside a
    /// card is a space, or a page's own play button; and not in a tiled view, which has nothing to pan.
    /// Returns whether the key was spent. See `CanvasBoardKeys.holdsToPan`.
    func holdForPanning(_ event: NSEvent) -> Bool {
        guard !isTiled, !nodeViews.values.contains(where: \.isEngaged),
              CanvasBoardKeys.holdsToPan(.init(event)) else { return false }
        if !spaceHeld {
            spaceHeld = true
            refreshCursor()
        }
        return true
    }

    override func keyUp(with event: NSEvent) {
        guard spaceHeld, event.charactersIgnoringModifiers == " " else { return super.keyUp(with: event) }
        spaceHeld = false
        // A pan still under way finishes as the pan it began as; the hand goes when the button does.
        if spaceGrab == nil { refreshCursor() }
    }

    /// Whether a left press takes hold of the board, because Space is down.
    ///
    /// Asked of the keyboard as well as of the flag: a Space let go while another window had the keys
    /// never reaches `keyUp` here, and a board that went on believing it was held would turn the next
    /// ordinary click into a pan.
    func takesHoldWithSpace(_ event: NSEvent) -> Bool {
        guard spaceHeld else { return false }
        guard !isTiled, CGEventSource.keyState(.combinedSessionState, key: Self.spaceKeyCode) else {
            spaceHeld = false
            return false
        }
        spaceGrab = convert(event.locationInWindow, from: nil)
        NSCursor.closedHand.set()
        return true
    }

    /// The Space bar's virtual key code — `kVK_Space`, in Carbon's table.
    private static let spaceKeyCode: CGKeyCode = 0x31

    /// Keep the point you grabbed under the pointer. Both ways of holding the board come here: the
    /// middle button, and the left one with Space down.
    ///
    /// Stated as "put the grabbed point back" rather than "scroll by however far the mouse moved". The
    /// two agree — `convert` has already divided by the magnification, so a pan moves the board at the
    /// pointer's speed at every zoom — but only this one corrects itself. Each event is worked out from
    /// where the board actually is, so a scroll the clip view clamped at the edge of the content, or a
    /// content origin that moved underneath the gesture, leaves no accumulated drift: the board is
    /// stuck to the pointer rather than following it.
    func pan(keeping grab: NSPoint, under event: NSEvent) {
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
            // Picking, the card under the pointer is ringed in the colour of what a click will do.
            if isPicking { overlay.needsDisplay = true }
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
    /// The gap between two tiles cannot be relied on to fix that. It is a few points wide; a pointer
    /// moved at any speed crosses it between two mouse-moved reports, and the board never gets the
    /// event in which it was over the gap and would have set a cursor. So the board watches for the
    /// pointer *changing hands* instead, and takes the cursor back at that moment — once, and then
    /// leaves the new card to it, which is what the page's next mouse-moved does with a page that has
    /// anything to say about the matter.
    func refreshCursor() {
        // Holding Space, the pointer is a hand over everything — cards included, since the press is
        // the board's wherever it lands. See `holdForPanning`.
        if spaceHeld || spaceGrab != nil {
            return (spaceGrab == nil ? NSCursor.openHand : NSCursor.closedHand).set()
        }
        let owner = cardUnderPointer
        defer { cursorOwner = owner }
        if owner != nil {
            if cursorOwner != nil && cursorOwner != owner { NSCursor.arrow.set() }
            return
        }
        guard let position = window?.mouseLocationOutsideOfEventStream else { return }
        let where_ = canvasPoint(convert(position, from: nil))
        // A link says so, the way one does everywhere else on the Mac — and on a card you have not
        // stepped into, it is the only thing under the pointer that is not the open hand.
        if link(at: convert(position, from: nil)) != nil { return NSCursor.pointingHand.set() }
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

    /// Escape backs out one step at a time, the way it does everywhere: out of a maximized tile first,
    /// and only then out of a selection.
    ///
    /// **It never leaves a workspace.** A workspace is where you are *working*, and Escape is the key
    /// that dismisses a menu, cancels a field and steps out of a card — all of them smaller acts that
    /// happen inside one. Making the same key also close the workspace would put every cancelled edit
    /// one keystroke away from tearing down something you built by hand. Leaving is ⌘↩ and the canvas
    /// tab, both of which say so.
    ///
    /// Nor does it clear the selection in a tiled view: there the selection is which tile the arrows
    /// and Return are about, and a tiling deliberately never has none (see `tile`).
    ///
    /// **This used to unwind a stack** — the drill-in, one level per press. The stack is gone with the
    /// drill-in, and what is left is the same instinct with a floor under it: one bounded thing to
    /// cancel, which is the amount of undoing a person expects from this key.
    ///
    /// Here rather than only in `keyDown` because Escape reaches the board two ways. A page card hands
    /// the key to WebKit, which sends it back as this command rather than as a key event, and a card
    /// that isn't engaged passes it up to us.
    override func cancelOperation(_ sender: Any?) {
        // Picking cards on the board: out of a peek first, then back into the workspace, keeping
        // whatever was picked.
        if isPicking { return peeking != nil ? endPeek() : endPicking() }
        // Where the next card was going, first: the smallest thing there is to cancel.
        if cancelPlacement() { return }
        if restoreMaximizedTile() { return }
        if !isTiled { selection = [] }
    }

    override func keyDown(with event: NSEvent) {
        // A key typed into a card you are standing in belongs to that card, whether or not its editor
        // has got round to taking first responder — see `strandedCardEditor`. First, because every
        // answer below it is the board's answer to a key that was never the board's: ⌫ would delete
        // the card you are typing in, ↓ would nudge it across the document, and anything else would
        // reach `super` to be beeped at and dropped.
        //
        // Escape is the exception, and stays the board's. It means the same thing here as it does in
        // the editor — step back out — and the board is where that is written down.
        if event.charactersIgnoringModifiers != "\u{1b}", let editor = strandedCardEditor {
            window?.makeFirstResponder(editor)
            editor.keyDown(with: event)
            return
        }
        // Picking cards on the board takes the keyboard whole. Space peeks at the card under the pointer;
        // Escape, Return and ⌥B go back to the workspace — or, peeking, Space and Escape put the card
        // back and Return adds it. Nothing else means anything: ⌫ there would delete a card off the
        // board you are only choosing from.
        if isPicking {
            // Which key is which command is `CanvasBoardKeys.picking`; this only does it.
            switch CanvasBoardKeys.picking(.init(event), peeking: peeking != nil, hovering: hovered != nil) {
            case .swallow: break
            case .endPicking: endPicking()
            case .endPeek: endPeek()
            case .finishPeek: finishPeek()
            case .beginPeek: if let id = hovered { beginPeek(id) }
            case .beep: NSSound.beep()
            }
            return
        }
        // The workspace's own keys — see `tilingTakes`.
        if isTiled, tilingTakes(event) { return }
        // A project card you are standing in is a list, and a list answers three of these keys. See
        // `projectCardTakes`.
        if projectCardTakes(event) { return }
        if holdForPanning(event) { return }
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
            } else if event.charactersIgnoringModifiers == "\r",
                      let commands = engagedProjectCard?.projectCommands, commands.selectedRows == 1 {
                // A list's "open": Return on one selected row focuses that task, the same act as its
                // double-click. One row only, for the reason the window gives — Return has to name a
                // single thing to open.
                commands.requestOpenRow()
            } else if event.charactersIgnoringModifiers == "\r", let only = selection.first {
                beginEditing(only)
            } else {
                super.keyDown(with: event)
            }
        }
    }

    /// The list keys, handed to the project card you have stepped into.
    ///
    /// **Because the board is the only thing that can tell what they mean.** ↑/↓, ⌘A and ⌫ are all keys
    /// the board already answers about its cards; a card claiming them from inside SwiftUI would be
    /// claiming them for the whole window, and a card that never claimed them would let ↓ nudge itself
    /// across the document while you were reading its tasks. So they are decided here, by the same rule
    /// the zoom commands and find already use: inside a card, a command means the card. §7d left this
    /// undone and called it a question with an obvious answer; this is the answer.
    ///
    /// Three deliberate exceptions:
    ///
    /// - **⌥ arrows stay the board's.** Moving between cards is the gesture a tiling window manager is
    ///   built around, and it is still worth having with a card open — see `moveFocus`.
    /// - **⌫ with no rows picked out is the card's own delete**, not a delete of nothing. That is what
    ///   the board would have done anyway, and the card says how many rows it has (`selectedRows`).
    /// - **A text field is first responder while you are typing in one**, so none of this is reached
    ///   then. That is not a check here; it is how the responder chain already works, and it is why
    ///   these can be unconditional.
    private func projectCardTakes(_ event: NSEvent) -> Bool {
        guard let commands = engagedProjectCard?.projectCommands else { return false }
        let extending = event.modifierFlags.contains(.shift)
        switch event.specialKey {
        case .delete, .deleteForward:
            guard commands.selectedRows > 0 else { return false }
            commands.requestDeleteRows()
        case .upArrow where !event.modifierFlags.contains(.option):
            commands.stepRows(-1, extending: extending)
        case .downArrow where !event.modifierFlags.contains(.option):
            commands.stepRows(1, extending: extending)
        default:
            return false
        }
        return true
    }

    /// The workspace's keys (docs/canvas-workspaces.md §7k): ⌥ with the arrows, =, −, 0, `, [, ], T, N,
    /// B and ⌫, and while ⌥N is choosing, the plain arrows, T and Return.
    ///
    /// **Here, and not as menu key equivalents**, because a key equivalent is taken before the view you
    /// are typing in ever sees it — and in a text card ⌥= is ≠, ⌥⇧← selects a word, and ⌥N starts a
    /// tilde. A key only reaches the board when nothing that types wanted it, which is exactly when it
    /// can safely mean the workspace. ⌥ arrows have always worked this way.
    private func tilingTakes(_ event: NSEvent) -> Bool {
        // Which key is which command is `CanvasBoardKeys.workspace`; this only does it.
        guard let command = CanvasBoardKeys.workspace(.init(event), choosingPlacement: isChoosingPlacement,
                                                      hasFocusedTile: focusedTile != nil,
                                                      step: Self.tileStep) else { return false }
        switch command {
        case .choosePlacement(let side): choosePlacement(side)
        case .confirmPlacement: confirmPlacement()
        case .moveTile(let direction): moveTile(direction)
        case .moveFocus(let direction):
            moveFocus(direction, extending: false)
            // Choosing where the next card goes, the place follows the focus onto the next tile.
            if isChoosingPlacement { retargetPlacement() }
        case .removeTile: removeTile(nil)
        case .grow(let vertically, let delta): growTile(vertically: vertically, by: delta)
        case .balance: balanceTiles()
        case .sizeToContent: sizeTilesToContent()
        case .beginPicking: beginPicking()
        case .focusPrevious: focusPreviousTile()
        case .stepTab(let step): stepTab(by: step)
        case .pullTabOut: if let id = focusedTile { pullTabOut(id) }
        case .beginPlacing: beginPlacing()
        case .cancelPlacement: _ = cancelPlacement()
        case .beep: NSSound.beep()
        }
        return true
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
        // The same sentence for a tile maximized out of several, and it is the *workspace* it walks
        // rather than the board — the six cards you put in it are the list you are looking through.
        // Without this the arrows would move the focus between tiles that are not drawn: `moveFocus`
        // only considers cards the layout shows, so every press would land on nothing and beep.
        if maximizedTile != nil { return cycleMaximizedTile(direction) }
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

    /// Step the maximization on to the next tile in the workspace — ⌥ arrows while one fills the room.
    ///
    /// **A cut rather than a move.** The two tiles occupy the same rectangle, so there is no distance
    /// for an animation to cover; sliding one out while the other slides into the identical frame reads
    /// as a flicker. Switching which window is maximized does not animate on a desktop either.
    private func cycleMaximizedTile(_ direction: CanvasNavigation.Direction) {
        guard var session = tiling, let showing = session.maximized,
              let index = session.ids.firstIndex(of: showing), session.ids.count > 1 else { return }
        let forward = direction == .right || direction == .down
        let next = session.ids[(index + (forward ? 1 : session.ids.count - 1)) % session.ids.count]
        session.maximized = next
        tiling = session
        selection = [next]
        setLayout(session.layout, animated: false)
        onTilingChanged?()
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
        // What ⌥` goes back to: the tile you were on before this one.
        if isTiled, previous.count == 1, selection.count == 1, let old = previous.first,
           tiling?.position(of: old) != nil {
            previousTile = old
        }
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
