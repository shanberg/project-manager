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
    @objc func tileSelection(_ sender: Any?) {
        if let session = tiling {
            let picked = selection.intersection(session.ids)
            guard !picked.isEmpty, picked.count < session.ids.count else {
                return untile(animated: true)
            }
            tilingHistory.append(session)
            return tile(picked)
        }
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
        guard !ids.isEmpty else { return NSSound.beep() }
        tile(ids)
    }

    /// Tile these cards, whatever asked for it.
    func tile(_ ids: Set<String>, arrangement: CanvasTiling.Arrangement? = nil) {
        let cards = document.nodes.filter { ids.contains($0.id) && !$0.isGroup }
            .map { (id: $0.id, frame: $0.frame) }
        guard !cards.isEmpty else { return NSSound.beep() }
        let visible = canvasRect(visibleRect)
        // Inset so tiles sit inside the window rather than against its edges, and clear of the header
        // floating over the top of the board.
        let area = CanvasRect(x: visible.minX + 18 / liveScale,
                              y: visible.minY + 54 / liveScale,
                              width: max(80, visible.width - 36 / liveScale),
                              height: max(80, visible.height - 72 / liveScale))
        let order = CanvasTiling.order(cards)
        let session = CanvasTileSession(
            ids: order,
            arrangement: arrangement ?? CanvasTiling.savedArrangement
                ?? preferredArrangement(for: cards.count),
            area: area,
            restoreVisible: tiling?.restoreVisible ?? visible)
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
        tiling = nil
        setLayout(.document, animated: animated)
        announceTiling()
        // Back to the region you were looking at, which a tiled view never moved but a fullscreen of one
        // card may well have made meaningless to return to blind.
        scrollView?.canvasScroll?.centre(on: CanvasPoint(x: session.restoreVisible.midX,
                                                         y: session.restoreVisible.midY))
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

    /// Make the focused card the master tile — ⌘⇧Return, and a double-click on a stack tile.
    func promoteInTiling(_ id: String) {
        guard var session = tiling else { return }
        session.promote(id)
        tiling = session
        setLayout(session.layout, animated: true)
    }

    /// A drag inside a tiled view: the two cards change places.
    func swapInTiling(_ id: String, with other: String) {
        guard var session = tiling else { return }
        session.swap(id, with: other)
        tiling = session
        setLayout(session.layout, animated: true)
    }

    /// Drag the divider between the master tile and the stack.
    func setMasterFraction(_ fraction: Double) {
        guard var session = tiling, session.arrangement == .masterStack else { return }
        session.masterFraction = min(0.85, max(0.3, fraction))
        tiling = session
        setLayout(session.layout, animated: false)
    }

    /// Remember where the divider was left. On mouse-up rather than on every frame of the drag, which
    /// would write to defaults at the rate the mouse reports.
    func rememberMasterFraction() {
        guard let tiling, tiling.arrangement == .masterStack else { return }
        CanvasTiling.savedMasterFraction = tiling.masterFraction
    }

    /// The window changed size, so the region the tiles were laid out in is the wrong shape.
    ///
    /// Without this a tiled view stops filling the window the moment you resize it — the tiles keep the
    /// canvas coordinates they were given, which were the window's at the time, and drift out of it. A
    /// tiling manager's whole promise is that the windows fill the screen, and one that stopped when
    /// you dragged a corner would be making the promise in past tense.
    func retileForWindowSize() {
        guard var session = tiling else { return }
        let visible = canvasRect(visibleRect)
        session.area = CanvasRect(x: visible.minX + 18 / liveScale,
                                  y: visible.minY + 54 / liveScale,
                                  width: max(80, visible.width - 36 / liveScale),
                                  height: max(80, visible.height - 72 / liveScale))
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
        if isTiled { untile(animated: false) }
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
