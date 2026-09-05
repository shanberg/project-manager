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
                        selection: selection, hovered: hovered)
    }

    private func point(_ event: NSEvent) -> CanvasPoint {
        canvasPoint(convert(event.locationInWindow, from: nil))
    }

    // MARK: Pressing

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let where_ = point(event)
        let extending = event.modifierFlags.contains(.shift) || event.modifierFlags.contains(.command)

        if event.clickCount == 2 {
            doubleClick(at: where_)
            return
        }

        switch hitTester.hit(where_) {
        case .handle(let id, let handle):
            guard let node = document.node(id: id) else { return }
            store.beginInteraction("Resize Card")
            gesture = .resize(id, handle, original: node.frame)

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

    // MARK: Dragging

    override func mouseDragged(with event: NSEvent) {
        let now = point(event)
        switch gesture {
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
            overlay.guides = snap.guides
            store.change("Move Card") { doc in
                for index in doc.nodes.indices {
                    guard let original = frames[doc.nodes[index].id] else { continue }
                    doc.nodes[index].frame.x = original.x + dx
                    doc.nodes[index].frame.y = original.y + dy
                }
            }

        case .resize(let id, let handle, let original):
            let snap = CanvasSnapping.resize(handle.resize(original, to: now), handle: handle,
                                             against: snapCandidates(excluding: [id]),
                                             reach: snapReach(event),
                                             snapsToGrid: snapsToGrid(event))
            overlay.guides = snap.guides
            store.change("Resize Card") { doc in
                guard let index = doc.nodes.firstIndex(where: { $0.id == id }) else { return }
                doc.nodes[index].frame = snap.frame
            }

        case .marquee(let from, let additive, let base):
            let rect = CanvasRect(x: min(from.x, now.x), y: min(from.y, now.y),
                                  width: abs(now.x - from.x), height: abs(now.y - from.y))
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
        autoscroll(with: event)
    }

    // MARK: Releasing

    override func mouseUp(with event: NSEvent) {
        defer {
            gesture = nil
            overlay.marquee = nil
            overlay.guides = []
            overlay.needsDisplay = true
        }
        switch gesture {
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
        let under: String?
        var line: String?
        switch hitTester.hit(where_) {
        case .node(let id), .handle(let id, _), .anchor(let id, _): under = id
        case .edge(let id): under = nil; line = id
        case .board: under = nil
        }
        if under != hovered {
            hovered = under
            if mode.showsConnectionAnchors { overlay.needsDisplay = true }
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
    }

    /// True when the pointer is over the part of a card that takes its own input.
    ///
    /// `hitTest` already encodes the whole rule — the edge band and the drag handle stay the board's,
    /// the controls and the page are the card's — so asking it is both correct and impossible to get
    /// out of step with.
    private var pointerIsInsideACard: Bool {
        guard let position = window?.mouseLocationOutsideOfEventStream else { return false }
        let local = convert(position, from: nil)
        return nodeViews.values.contains { $0.isEngaged && $0.hitTest(local) != nil }
    }

    /// The pointer over the board, and only over the board.
    ///
    /// The early return is the fix for a pointer that flickered several times a second over an engaged
    /// web card. A tracking area is not blocked by subviews, so the board went on receiving
    /// mouse-moved events over a page it no longer owned and went on setting the open hand for "you
    /// can drag this card" — while the page underneath set its own arrow, pointer or I-beam on the very
    /// same events. Two cursors set in alternation at the rate the mouse reports is exactly what a
    /// flickering pointer is.
    func refreshCursor() {
        guard !pointerIsInsideACard else { return }
        guard let position = window?.mouseLocationOutsideOfEventStream else { return }
        let where_ = canvasPoint(convert(position, from: nil))
        switch hitTester.hit(where_) {
        case .handle(_, let handle): cursor(for: handle).set()
        case .anchor: NSCursor.crosshair.set()
        case .node: NSCursor.openHand.set()
        case .edge, .board: NSCursor.arrow.set()
        }
    }

    private func cursor(for handle: CanvasHandle) -> NSCursor {
        switch handle {
        case .left, .right: return .resizeLeftRight
        case .top, .bottom: return .resizeUpDown
        // AppKit ships no public diagonal resize cursor. `.crosshair` is the honest stand-in — it says
        // "this grip does something in two directions" without pretending to be the arrow that would
        // mean one.
        case .topLeft, .topRight, .bottomLeft, .bottomRight: return .crosshair
        }
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        switch event.specialKey {
        case .delete, .deleteForward:
            deleteSelection()
        case .leftArrow: nudge(dx: -step(event), dy: 0)
        case .rightArrow: nudge(dx: step(event), dy: 0)
        case .upArrow: nudge(dx: 0, dy: -step(event))
        case .downArrow: nudge(dx: 0, dy: step(event))
        default:
            if event.charactersIgnoringModifiers == "\u{1b}" {
                selection = []
            } else if event.charactersIgnoringModifiers == "\r", let only = selection.first {
                beginEditing(only)
            } else {
                super.keyDown(with: event)
            }
        }
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
        onSelectionChanged?(selection)
    }

    /// The rectangle the floating bar should sit above: everything selected, in view coordinates.
    var selectionBounds: NSRect? {
        let frames = selection.compactMap { document.node(id: $0)?.frame }
        guard var box = frames.first else { return nil }
        for frame in frames.dropFirst() { box = box.union(frame) }
        return viewRect(box)
    }

    func select(_ ids: Set<String>) { selection = ids }
}

extension Sequence {
    /// The non-nil elements. Foundation grew `compacted()` for this on `Optional` sequences in a
    /// later SDK than this target's floor, so it is spelled out here.
    func compacted<Wrapped>() -> [Wrapped] where Element == Wrapped? { compactMap { $0 } }
}
