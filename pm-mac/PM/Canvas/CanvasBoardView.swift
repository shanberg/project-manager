import AppKit
import PmLib

/// The board: an infinite plane of cards, drawn and driven.
///
/// Flipped, so that canvas coordinates — where y grows downward, in the file and in Obsidian — are the
/// view's coordinates too, offset by wherever the content happens to start. Every conversion in here is
/// a subtraction rather than a matrix, and a card's frame in the file is legible in the debugger as a
/// frame on screen.
///
/// **Zoom belongs to the scroll view, not to this.** `NSScrollView.magnification` scales the whole
/// document view, so nothing here multiplies by a zoom factor: a card is laid out at its true size
/// once and the scroll view draws it smaller. That is what keeps text crisp at any zoom — the text is
/// rendered at the scaled size by the layer, not rasterised at 1× and shrunk — and it is why the hit
/// tester takes a `scale` but the layout doesn't.
///
/// Cards are **built only when they come into view**. A board of 117 cards is ordinary and a card can
/// be an embedded web page; building all of them on open would be a hundred renderers for the dozen
/// you can see. See `refreshNodeViews`.
@MainActor
final class CanvasBoardView: NSView {
    // Internal rather than private throughout: the mouse and keyboard live in
    // `CanvasBoardView+Input.swift`, and Swift's `private` doesn't reach across files even for an
    // extension of the same type. The split is worth that — drawing and driving are different jobs,
    // and one file holding both was the length where neither could be read.
    let store: CanvasDocumentStore
    weak var scrollView: NSScrollView?

    /// The part of the window a tiled view can actually fill.
    ///
    /// The visible rectangle, less anything covering it. In a project window the board runs beneath the
    /// floating sidebar, so tiles laid out across the whole visible width put their leading column
    /// behind it — the same mistake the header made, one layer down.
    ///
    /// The top is the header's, not a safe area's: the board deliberately runs up under the titlebar,
    /// and the room the floating chrome needs is a constant this owns rather than something AppKit
    /// reports.
    var tileableRect: CanvasRect { tileableRect(atZoom: liveScale) }

    /// The same, for a zoom the board is not at yet.
    ///
    /// **Because entering a workspace now travels to 100% rather than arriving there.** The tiles are
    /// laid out in canvas coordinates and have to be laid out for the zoom they will be *read* at, so
    /// the measurement has to be taken before the journey rather than after it — the board is still at
    /// 40% when this is asked and will be at 100% when the cards land. Measured about the same centre
    /// the window has now, which is the other half of it: a crossing that also slid sideways would be
    /// two changes to follow.
    func tileableRect(atZoom scale: Double) -> CanvasRect {
        CanvasTiling.area(of: visibleCanvasRect(atZoom: scale), margins: tileMargins(atZoom: scale))
    }

    /// Everything the window would be able to show at a given zoom, about the middle it is looking at
    /// now. The zoom the board is *at* answers with its own visible region exactly.
    private func visibleCanvasRect(atZoom scale: Double) -> CanvasRect {
        let visible = canvasRect(visibleRect)
        let ratio = liveScale / max(0.0001, scale)
        let width = visible.width * ratio
        let height = visible.height * ratio
        return CanvasRect(x: visible.midX - width / 2, y: visible.midY - height / 2,
                          width: width, height: height)
    }

    /// What the window keeps for itself out of that: the sidebar the board runs beneath, and the band
    /// the floating header needs. See `CanvasTiling.Margins`.
    func tileMargins(atZoom scale: Double) -> CanvasTiling.Margins {
        let covered = scrollView?.safeAreaInsets ?? NSEdgeInsets()
        return CanvasTiling.Margins(leading: Double(covered.left) / scale,
                                    trailing: Double(covered.right) / scale,
                                    top: Self.headerClearance / scale)
    }

    /// Room at the top for the floating header, and nothing else.
    ///
    /// This used to add 18pt on three sides as well, which `CanvasTiling.frames` then inset again — two
    /// margins asked the same question and answering it twice, for 32pt at the edges. The tiling owns
    /// the whole answer now; see `CanvasTiling.edgeGap`, which is where to go if it wants adjusting.
    ///
    /// Read by `CanvasEdgeView` too, which fades to nothing exactly where the tiles start.
    static let headerClearance: Double = 40

    /// The board's extent in canvas coordinates: everything on it, plus room to drag things outside it.
    /// The view's own size, and the origin every conversion subtracts.
    private(set) var content: CanvasRect = CanvasRect(x: 0, y: 0, width: 1, height: 1)
    private static let margin: Double = 1600

    var mode: CanvasMode = .view {
        didSet {
            guard mode != oldValue else { return }
            overlay.needsDisplay = true
            // The two vocabularies swap: rings and grips in edit, height in view.
            for view in nodeViews.values { view.refreshElevation() }
            onModeChanged?()
            refreshCursor()
        }
    }
    /// Where the cards are drawn — the document's own layout unless something is standing in for it.
    /// See `CanvasLayout` and `CanvasTiling`.
    private(set) var layout: CanvasLayout = .document

    /// The project whose store was edited more recently than the canvas document, if any — what ⌘Z
    /// should act on.
    ///
    /// Two undo systems meet on a board that holds project cards. The canvas document has an
    /// `UndoManager` the window hands back; a project has `PMStore`'s own snapshot stack, shared with
    /// every window showing that project. Neither knows the other exists, so ⌘Z on a board where you
    /// had just ticked a task undid the last card you moved — or nothing — and the task edit was
    /// unreachable. Which is worse than no undo, because you believe it worked.
    ///
    /// Nil means the canvas document. Set by a project card when its store records an edit, cleared
    /// whenever the canvas document changes, so it always names the most recent of the two.
    var lastEditedProject: PMStore?

    /// The last tiling made on this board, kept after it was left — see `CanvasViewState.lastTiling`.
    /// Tiling the same set of cards again picks this up rather than starting over.
    var lastTiling: CanvasViewState.Tiling?
    /// The name of the workspace that is up, or nil while this board is not in one.
    ///
    /// Read by the write-through that keeps a workspace level with the screen as you adjust it. **Never
    /// nil while `tiling` is set, in a board inside a window**: every set of tiles is a workspace and
    /// every workspace has a name (docs/canvas-workspaces.md §7i), so the nil case is a board that is
    /// not tiled — or one of the two tilings that are not workspaces, the project-note view and a board
    /// with no window around it to keep a workspace for it.
    var workspaceName: String?

    /// **⌘↩ on a board that is not tiled: this tiling is a workspace, so it wants a tab.**
    ///
    /// Handed the tiling it is about to lay out, before it lays it out. The window names it, keeps it,
    /// and opens it in a tab of its own — see `ProjectSplitViewController.tileAsWorkspace`. Answering
    /// true means it has been dealt with and this board should stay as it is; false is a board with no
    /// window to keep anything, which tiles itself and stays unnamed.
    var onTileAsWorkspace: (CanvasViewState.Tiling) -> Bool = { _ in false }

    /// **Show the canvas** — ⌘−, and ⌘↩ with nothing left to narrow.
    ///
    /// A workspace is a place, and the canvas is another place, so leaving one is going to the other
    /// rather than undoing anything. The board keeps its tiles; the window changes tabs. See
    /// `ProjectSplitViewController.goToCanvas`.
    var onGoToCanvas: () -> Void = {}

    /// Open part of this board as a tab of the window it is in — see `CanvasPaneController.tabModel`,
    /// which says why these are no longer optional.
    var onOpenInTab: (CanvasFocus) -> Void = { _ in }
    /// Keep the tiling that is up under a name.
    var onSaveWorkspace: (String) -> Void = { _ in }
    /// Forget a named workspace, leaving whatever is up on screen alone.
    var onRemoveWorkspace: (String) -> Void = { _ in }
    /// Switch to a named workspace. Routed out to the pane because the names live in a store the board
    /// has no url to read — the board knows cards, the pane knows which document they are in.
    var onGoToWorkspace: (String) -> Void = { _ in }
    /// Make a copy of a named workspace and open it. Routed out for the reason `duplicateWorkspace`
    /// gives: the copy wants a tab, and tabs are the window's.
    var onDuplicateWorkspace: (String) -> Void = { _ in }
    /// Rename a named workspace. Routed out with the rest, so the one implementation is the one that
    /// can also carry every tab pinned to the old name across — see
    /// `ProjectSplitViewController.renameWorkspace(named:)`.
    var onRenameWorkspace: (String) -> Void = { _ in }
    /// The board's named workspaces, for the menus that list them.
    var workspaceNames: () -> [String] = { [] }
    /// The named workspaces holding any of these cards — the contextual menu's Workspaces submenu.
    var workspacesHolding: (Set<String>) -> [String] = { _ in [] }

    /// The tiled view that is up, if one is. See `CanvasBoardView+Tiling`.
    var tiling: CanvasTileSession? {
        didSet {
            // Only the crossings, not every set. Dragging the master divider assigns this at the rate
            // the mouse reports, and none of those frames change whether a tiling is up.
            guard (oldValue == nil) != (tiling == nil) else { return }
            scrollView?.canvasScroll?.showsScrollers(!isTiled)
            watchTileClicks(isTiled)
            // Every card changes vocabulary at once, and it does it over a third of a second rather
            // than between two frames: height and a card's hairline on the way out, a tile's
            // near-invisible edge and its two radii on the way in, over a ground that darkens with
            // them. See `tiledness`, which is the number all of that is drawn against.
            tiledFade.set(isTiled)
        }
    }

    // MARK: Between the two modes

    /// How far this board is between showing itself and showing a workspace: 0 is a board, 1 is tiles.
    ///
    /// **A crossing you can watch.** Everything that tells a tile from a card is a *drawn* difference —
    /// the ground it sits on, the hairline, the two radii, the shadow it has or hasn't got — so none of
    /// it can be handed to `animator()` and none of it was animated: the cards slid into their tile
    /// positions (`settleIntoLayout`) while the vocabulary they were drawn in changed in a single
    /// frame. Half a transition reads worse than none, because the half that cuts is the half that says
    /// what kind of thing you are now looking at.
    ///
    /// So it is a number between the two, and every one of those differences is drawn against it. The
    /// mode itself is still a boolean and changes at once — `isTiled` is what the commands, the hit
    /// testing and the page budget ask, and a board that was *half* tiled to the keyboard would be a
    /// board with two grammars. This is about paint only.
    ///
    /// Independent of `tiling` for one reason, which is the whole of `arrive(from:)`: a board that is
    /// not tiled at all can be posed at 1 and asked to ease out of it, which is how a workspace's tiles
    /// are still on screen in the pane that takes over from it.
    var tiledness: Double { tiledFade.presence }

    /// Long enough to read as one thing turning into another, and the same third of a second the cards
    /// take to fly (`settleIntoLayout`). Coming and going are the same length here, unlike the grid's:
    /// this is not chrome answering your hand, it is the window changing what it is showing, and that
    /// costs the same either way.
    private lazy var tiledFade = CanvasFade(rise: 0.3, fall: 0.3, on: self) { [weak self] in
        self?.tilednessChanged()
    }

    /// Repaint everything the crossing is drawn into. Called on every step of the fade.
    ///
    /// The scroll view is told as well as the board: it paints the same colour behind an elastic
    /// overscroll, so without this a rubber-banded tiling flashes the board's grey at the edges.
    private func tilednessChanged() {
        FrameMeter.span("fadeStep") { tilednessChangedBody() }
    }

    private func tilednessChangedBody() {
        scrollView?.backgroundColor = ground
        needsDisplay = true
        for (id, view) in nodeViews { applyPresence(to: view, id: id) }
        overlay.needsDisplay = true
        // **The grips come up with the tiles, not before them.** They are drawn from the session, which
        // exists from the first frame of the crossing — so without this they are already lying in the
        // gaps between tiles that have not arrived yet, which is the one piece of a tiled view that can
        // be in the wrong place rather than merely early. Going the other way they are simply gone: the
        // session is cleared as leaving starts, and a grip belongs to the state that is over.
        tileHandleView.alphaValue = tiledness
        tileHandleView.needsDisplay = true
        tileGripView.alphaValue = tiledness
    }

    /// Pose the crossing without animating it — see `CanvasFade.hold` and `arrive(from:)`.
    func holdTiledness(_ value: Double) { tiledFade.hold(value) }

    /// Cross to tiles or back to the board without the tiling itself going anywhere — the board as the
    /// picker, which is a workspace drawn as a board. See `beginPicking`.
    func showTiledness(_ shown: Bool) { tiledFade.set(shown) }

    /// The watch that hands the keyboard to the tile you click into. Only while one is up — see
    /// `watchTileClicks`.
    var tileClickWatch: Any?
    /// Told when a tiling is entered, left or rearranged, so the window can say what it is showing.
    var onTilingChanged: (() -> Void)?

    var selection: Set<String> = [] { didSet { selectionChanged(from: oldValue) } }
    /// The card under the pointer. The board tracks it because the card can't: an unengaged card
    /// returns nil from `hitTest` and so never sees the mouse. Read by the overlay, the hit tester and
    /// the tile handlebars — nothing is drawn or said by hovering alone.
    var hovered: String?

    /// A card's answer about itself changed — a page navigated, a page got older.
    func descriptionChanged(for id: String) {
        if nodeViews[id]?.isEngaged == true { pageStateChanged() }
    }

    /// What the pointer is currently doing. Nil between gestures.
    var gesture: Gesture?
    enum Gesture {
        /// `copying` while an ⌥-drag has yet to make its copies — done on the first move, then cleared.
        case move(from: CanvasPoint, frames: [String: CanvasRect], copying: Bool)
        /// Dragging a grip or a card's edge. Carries the whole selection, not the card that was
        /// grabbed: several cards resize as one, and one card is that with a set of size one. `box` is
        /// what they occupied when the drag began — see `CanvasGroupResize`.
        case resize(CanvasHandle, from: CanvasPoint, originals: [String: CanvasRect], box: CanvasRect)
        case marquee(from: CanvasPoint, additive: Bool, base: Set<String>)
        case connect(from: String, side: CanvasSide, to: CanvasPoint)
        /// Inside a tiled view: dragging one tile over another to change their places. `over` is the
        /// tile the drop would land on, so the overlay can say so before you let go.
        case swap(from: String, over: String?)
        /// Inside a tiled view: dragging the boundary between two tiles. Carries the run's lengths as
        /// they were when the drag began, so every frame is computed from the start of the gesture
        /// rather than from the frame before it — which is what stops a slow drag accumulating drift.
        case resizeTiles(CanvasTileDivider, from: CanvasPoint, lengths: [Double])
        /// Inside a tiled view: dragging a tile by its handlebar or its tab to put it somewhere else.
        /// Nothing moves while it is carried — a proxy follows the pointer (`dragPoint`) and where it
        /// would land is marked — so `base`, where every tile is, holds for the whole gesture. `drop` is
        /// what letting go would do now. `pulling` is a tab taken from a tile of several: the one card
        /// comes out, rather than the tile.
        case placeTile(String, base: [String: CanvasRect],
                       drop: (target: String, drop: CanvasTileSession.Drop)?, pulling: Bool)
        /// Inside a tiled view: a tab pressed and dragged along its strip, which reorders the strip the
        /// way the window's own tab bar does — the tab follows the pointer and the others slide aside.
        /// Dragged far enough off the strip it becomes `placeTile(… pulling: true)`, and the card comes
        /// out. `from` is where the press was. See `tabSlide`.
        case slideTab(String, from: CanvasPoint)
        /// A press on a link drawn on a card: let go where it started and it opens, move and it is
        /// carried off as a drag the board — or anywhere else — can drop. See `CanvasLinkZones`.
        case link(URL, from: CanvasPoint)

        /// Whether the board should scroll to follow this gesture past the edge of the window.
        ///
        /// True for the gestures that are carrying something *to* somewhere — a card, a marquee, a
        /// line looking for its other end — and false for a resize, which is anchored to the edge it
        /// is not moving. See `mouseDragged`, which is the only caller.
        var pansTheBoard: Bool {
            switch self {
            case .move, .marquee, .connect: return true
            case .resize, .swap, .resizeTiles, .placeTile, .slideTab, .link: return false
            }
        }
    }

    var nodeViews: [String: CanvasNodeView] = [:]
    /// The drag over the board right now, if there is one. See `CanvasBoardView+Dropping`.
    var dropSession: CanvasDropSession?
    let overlay = CanvasOverlayView()
    /// The tile handlebars, at the bottom of the stack — above the board's own drawing and below
    /// every card. See `CanvasTileHandleView`.
    let tileHandleView = CanvasTileHandleView()
    let tileGripView = CanvasTileGripView()

    /// Whether this board is standing in for the project window's notes — tiled to the project's own
    /// card, and nothing else (docs/canvas-workspaces.md §7d).
    ///
    /// What it turns off is **naming this as a workspace**, which would give the app a second name for
    /// the shape it already has one for — the notes are the one workspace nobody had to name.
    ///
    /// It used to turn off leaving the tiled view too, on the grounds that it would leave a tab called
    /// "Notes" showing the whole board. That is no longer what happens: the tab follows its board (see
    /// `ProjectSplitViewController.reconcileTabsWithTheirBoards`), so leaving renames the chip, and
    /// leaving is now *the* way to the board rather than a way to break the tab. It is also what ⌘−
    /// means here, which is the only view where that key had nothing to say — the project's own card
    /// does not zoom its content, and zooming out of a workspace of one card is the board.
    var isProjectNoteView = false

    /// The card ⌥⌘↩ is filling the window with, from the board rather than from a workspace — backlog
    /// 41. The tiling that shows it is a way of looking for a moment, like a maximized tile: never
    /// remembered, never a workspace, and Escape, ⌥⌘↩, ⌘↩ or ⌘− puts the board back as it was. See
    /// `maximizeCard`.
    var maximizedCard: String?

    /// This board's project note, and whether we have been to look for it.
    ///
    /// Looked for once and remembered, including the answer "there isn't one": the canvas does not
    /// move, so neither does its project, and the question costs a directory listing. What is asked
    /// again is only whether the card is *on* the board — see `offersProjectNoteCard`, which every
    /// document change asks, which during a drag is every frame.
    private var projectNote: URL?
    private var lookedForProjectNote = false

    /// Whether the add menus should offer to put the project's note back on this board.
    var offersProjectNoteCard: Bool {
        if !lookedForProjectNote {
            lookedForProjectNote = true
            projectNote = CanvasProjectNoteCard.notes(forCanvasAt: store.url)
        }
        guard let projectNote else { return false }
        return !CanvasProjectNoteCard.isOn(document, notes: projectNote, resolver: store.resolver)
    }
    /// The project's note card, when it is on this board — what a list of cards to fill a tile with
    /// offers first.
    var projectNoteCardID: String? {
        _ = offersProjectNoteCard
        return projectNote.flatMap { CanvasProjectNoteCard.id(on: document, notes: $0, resolver: store.resolver) }
    }
    var trackingArea: NSTrackingArea?
    /// Where the right-click that opened the context menu landed. Held because the menu is long
    /// dismissed by the time an item fires, and "Paste" from that menu means *there*.
    var menuPoint: CanvasPoint?
    /// The boundary a right-click landed on, if it landed on one. Held for the same reason as
    /// `menuPoint`: the menu is long dismissed by the time an item fires.
    var menuDivider: CanvasTileDivider?
    /// The tile a right-click landed on, if it landed on one. Held for the same reason, and asked
    /// rather than the selection because a tile command names *this* tile — "make this the master" has
    /// no reading against four selected at once.
    var menuTile: String?
    /// The tile that had the focus before this one, for ⌥` — see `focusPreviousTile`.
    var previousTile: String?
    /// Whether ⌥N is choosing where the next card goes, which is what lets the plain arrows and Return
    /// choose. See `beginPlacing`.
    var isChoosingPlacement = false
    /// Where a tile carried by its handlebar would land if let go now, and what it would do there.
    /// See `previewDrop`.
    var dropMark: (rect: CanvasRect, title: String)?
    /// Whether the workspace is zoomed out to the board so you can pick its cards (⌥B). The tiling is
    /// still up — nothing about the workspace is set aside — and only what is drawn, and what a click
    /// means, changes. See `beginPicking` and `showsTiles`.
    var isPicking = false
    /// The card Space brought close while picking, and where the board was looking before it did, so
    /// that putting it back is exact. See `beginPeek`.
    var peeking: (card: String, zoom: CGFloat, centre: CanvasPoint)?

    /// The board a peek will return to, in canvas coordinates — the window as it will be at the zoom and
    /// centre `peeking` recorded. Nil when there is no peek to come back from.
    ///
    /// Measured from the region the board can see *now*, whatever zoom that is, so it answers the same
    /// rectangle whether it is asked mid-flight — where a transform flight has already jumped the
    /// visible rect to the peek's own zoom — or after the peek has landed. See `buildNodeViews`.
    private var peekOrigin: CanvasRect? {
        guard let peeking else { return nil }
        let visible = canvasRect(visibleRect)
        let ratio = liveScale / max(0.0001, Double(peeking.zoom))
        let width = visible.width * ratio
        let height = visible.height * ratio
        return CanvasRect(x: peeking.centre.x - width / 2, y: peeking.centre.y - height / 2,
                          width: width, height: height)
    }
    /// Where the pointer is while a tile is dragged, which is where its proxy is drawn. See
    /// `CanvasOverlayView.drawCarried`.
    var dragPoint: CanvasPoint?
    /// A link on a card being dragged along the list it is in (canvas backlog 14): which card and list,
    /// its place, the rows in canvas coordinates as they stood when the drag began, and where it would
    /// go if let go now — nil until the press has moved.
    var linkReorder: CanvasLinkReorder? {
        didSet { if linkReorder != oldValue { overlay.needsDisplay = true } }
    }
    /// A tab being dragged along its strip, while it is: drawn by `CanvasTileHandleView`.
    var tabSlide: CanvasTabSlide? {
        didSet { tileHandleView.tabSlideChanged(from: oldValue) }
    }
    /// The tab under the pointer, and whether the pointer is on its close button — drawn as a hover.
    var hoveredTab: (card: String, onClose: Bool)? {
        didSet {
            guard hoveredTab?.card != oldValue?.card || hoveredTab?.onClose != oldValue?.onClose else { return }
            tileHandleView.hoverChanged(from: oldValue?.card, to: hoveredTab?.card)
        }
    }
    /// The tile whose strip's + is under the pointer, or whose + has its menu open — drawn as a hover,
    /// and held while the menu is up so the button reads as the thing that opened it.
    var hoveredNewTab: String? {
        didSet { if hoveredNewTab != oldValue { tileHandleView.needsDisplay = true } }
    }
    /// A card in the strip the pointer is over, if it is over one: that strip shows its +. Any card of
    /// it rather than the one showing, so clicking a tab — which changes the one showing — doesn't read
    /// as leaving the strip.
    var hoveredStrip: String? {
        didSet { if hoveredStrip != oldValue { tileHandleView.stripHoverChanged(to: hoveredStrip) } }
    }
    var openNewTabMenu: String? {
        didSet { if openNewTabMenu != oldValue { tileHandleView.needsDisplay = true } }
    }
    /// The tile whose top centre the pointer is near, which is the one tile showing its grip.
    var gripTile: String?
    /// Which match ⌘G steps to next.
    var findCursor = 0
    /// Where a middle-button pan took hold of the board, in view coordinates. Non-nil only while that
    /// drag is running.
    ///
    /// Its own property rather than a `Gesture` case: the middle button is a separate stream of events
    /// from the left one, so a pan can begin in the middle of a marquee or a card drag, and storing it
    /// in `gesture` would throw that half-finished gesture away.
    var panGrab: NSPoint?
    /// Space is down with nothing stepped into, so a left press takes hold of the board rather than a
    /// card — and `spaceGrab` is where it took hold, while that press lasts. See `holdForPanning`.
    var spaceHeld = false
    var spaceGrab: NSPoint?
    /// The line under the pointer, so it can say it is clickable before it is clicked.
    var hoveredEdge: String?

    /// The card that was last left to set the pointer for itself, so the board can notice the pointer
    /// leaving it. See `refreshCursor`.
    var cursorOwner: String?

    /// The card a scroll gesture was aimed at when it started, held for the rest of it.
    ///
    /// A flick's momentum keeps arriving after the fingers have left, and re-reading the pointer on
    /// every one of those events would hand the tail of a gesture to whatever the pointer had since
    /// drifted over. Weak, because a card can be thrown away mid-flick — a board that scrolls past it,
    /// a tiling that hides it — and a dangling target would go on being scrolled.
    weak var scrollLatch: NSView?
    /// Whether the wheel gesture under way began over a side strip of tabs, and so scrolls it.
    var tabScrollLatch = false
    /// Set while an event is being handed to a card, so the one it hands back doesn't come straight
    /// back down again. See `scrollWheel`.
    var forwardingScroll = false

    /// The web card you have stepped into, if any. What the window's page controls act on — a board
    /// engages one card at a time, so there is never a question of which.
    var engagedPageCard: CanvasNodeView? {
        nodeViews.values.first { $0.isEngaged && $0.isPageCard }
    }

    /// The editor inside the text card you have stepped into, when the board is still holding the
    /// keys — the last line of defence against a keystroke being beeped away.
    ///
    /// A card's editor takes first responder a runloop turn after the card opens, so a key pressed in
    /// that turn arrives at the board rather than at the text view that is plainly ready for it. The
    /// board's answer to a key it doesn't recognise is `super`, and `NSResponder`'s answer is a beep
    /// and a lost character. Nil once the editor holds focus, because then the board never sees the
    /// key at all. See `keyDown`.
    var strandedCardEditor: NSTextView? {
        guard let card = nodeViews.values.first(where: { $0.isEngaged && $0 is CanvasTextNodeView })
        else { return nil }
        return card.firstTextView
    }

    /// The undo stack of the card you are typing in, if you are typing in one.
    ///
    /// While a card's editor is open, ⌘Z means that editor — the way it does in every text field on
    /// the Mac — rather than the board the card is standing on. What the board gets is one step for
    /// the whole session, when you step out. See `CanvasTextNodeView.editingUndo`.
    var engagedCardUndoManager: UndoManager? {
        nodeViews.values.compactMap { $0 as? CanvasTextNodeView }.first { $0.isEngaged }?.editingUndo
    }

    /// The project card you have stepped into, if any — the board's current project.
    ///
    /// **Aimed, where `lastEditedProject` remembers.** Undo takes the more recently edited of the two
    /// documents because "the thing I just did" is what ⌘Z means. New Session is not that kind of
    /// command: it is a thing you do *to* a project, so it takes the project you are standing in, and a
    /// board with nothing engaged has nothing to aim at rather than a best guess. One card at a time is
    /// engaged — a tile click engages the tile it lands in — so there is never a question of which.
    ///
    /// It is also the answer to what "the current project" means on a board holding six of them, which
    /// the window's own project cannot answer for a board opened straight from a file.
    var engagedProjectCard: CanvasFileNodeView? {
        nodeViews.values.compactMap { $0 as? CanvasFileNodeView }
            .first { $0.isEngaged && $0.isProjectCard }
    }

    /// Told when a page is stepped into or out of, or navigates — so the window can offer the controls
    /// for it, and only then.
    var onPageStateChanged: (() -> Void)?
    func pageStateChanged() { onPageStateChanged?() }

    /// Told when the mode changes, so the window's header can say which one the board is in.
    var onModeChanged: (() -> Void)?

    /// Told when the selection changes, so the floating bar can follow it.
    var onSelectionChanged: ((Set<String>) -> Void)?

    init(store: CanvasDocumentStore, scrollView: NSScrollView) {
        self.store = store
        self.scrollView = scrollView
        super.init(frame: .zero)
        wantsLayer = true
        tileHandleView.board = self
        tileGripView.board = self
        overlay.board = self
        // Order matters and is load-bearing. These two are the floor and the ceiling of the board's
        // subviews: cards are inserted `.below` the overlay, which keeps them above the handlebars and
        // below the grips for the life of the board without anything having to re-sort them.
        addSubview(tileHandleView)
        addSubview(overlay)
        // Above even the overlay: a tile's grip sits on the card it moves (backlog 20).
        addSubview(tileGripView)
        // Without this AppKit offers the board no drag at all, and the only drops that ever reached it
        // were the ones a web card's page handed on — so a link carried off a card onto open ground
        // went back to being a link, and nothing dropped on the ground made a card.
        registerForDrops()
        setAccessibilityRole(.group)
        setAccessibilityLabel("Canvas")
        recomputeContent()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var document: CanvasDocument { store.document }
    /// The zoom the hit tester and every screen-sized measurement work in.
    var liveScale: Double { Double(scrollView?.magnification ?? 1) }

    // MARK: Coordinates

    func viewPoint(_ p: CanvasPoint) -> NSPoint {
        NSPoint(x: p.x - content.minX, y: p.y - content.minY)
    }

    func viewRect(_ r: CanvasRect) -> NSRect {
        NSRect(x: r.minX - content.minX, y: r.minY - content.minY, width: r.width, height: r.height)
    }

    func canvasPoint(_ p: NSPoint) -> CanvasPoint {
        CanvasPoint(x: Double(p.x) + content.minX, y: Double(p.y) + content.minY)
    }

    func canvasRect(_ r: NSRect) -> CanvasRect {
        CanvasRect(x: Double(r.minX) + content.minX, y: Double(r.minY) + content.minY,
                   width: Double(r.width), height: Double(r.height))
    }

    /// Resize the board to hold what's on it, keeping what you're looking at where it is.
    ///
    /// The origin moves whenever a card is dragged out past the current extent, and every view
    /// coordinate is relative to that origin — so without compensating the scroll position, dragging a
    /// card off the left edge would yank the whole board sideways under the pointer.
    ///
    /// The compensation is a *wish*, not an answer: it asks for the position that leaves what you were
    /// looking at where it was, and a board that has just changed shape need not have such a position.
    /// Delete the card you were parked beside and the wish names a place the board no longer reaches.
    /// So it is put through the same rule a pan is — `setBoundsOrigin` does not consult
    /// `constrainBoundsRect`, only a scroll does, so a wish written straight in is written in
    /// unchecked, and the next pan is the first event to notice. That noticing is the jump in
    /// canvas-backlog item 1.
    func recomputeContent() {
        let bounds = document.bounds ?? CanvasRect(x: 0, y: 0, width: 800, height: 600)
        let next = bounds.inset(by: Self.margin)
        guard next != content else { return }

        let shift = NSPoint(x: content.minX - next.minX, y: content.minY - next.minY)
        content = next
        setFrameSize(NSSize(width: next.width, height: next.height))
        overlay.frame = NSRect(origin: .zero, size: frame.size)
        tileHandleView.frame = overlay.frame
        tileGripView.frame = overlay.frame

        if let clip = scrollView?.contentView, shift != .zero {
            var wanted = NSRect(origin: NSPoint(x: clip.bounds.origin.x + shift.x,
                                                y: clip.bounds.origin.y + shift.y),
                                size: clip.bounds.size)
            if !showsTiles, let cards = document.bounds,
               let settled = CanvasPanBounds.constrain(wanted, holding: viewRect(cards)) {
                wanted = settled
            }
            clip.setBoundsOrigin(wanted.origin)
            // The scrollers don't follow a bounds origin written directly — the same reason
            // `otherMouseDragged` says this after a `scroll(_:)`.
            scrollView?.reflectScrolledClipView(clip)
        }
        layoutNodeViews()
    }

    // MARK: Reacting to the document

    /// The document changed — rebuild what's on screen.
    ///
    /// A drag reports a change on every mouse-moved event, and the full rebuild is far more than those
    /// need: nothing has been added or removed, so there are no card views to build or throw away and
    /// no selection to prune. Mid-gesture it does the two things that actually changed — where the
    /// cards are, and what's drawn behind them — and leaves the rest alone.
    func documentChanged() {
        recomputeContent()
        if !store.isInteracting {
            selection = selection.filter { document.node(id: $0) != nil }
            // A tiling names its cards, so a card that has gone has to come out of it — see
            // `pruneTilingOfDeletedCards`. Before the views are rebuilt, since it decides which of
            // them there are.
            pruneTilingOfDeletedCards()
            // Build only: the layout pass below is the one this needs, and running both laid every
            // card out twice for every change the document reported.
            refreshVisibleCards()
        }
        layoutNodeViews()
        needsDisplay = true
        overlay.needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshNodeViews()
    }

    /// Build the card views the layout needs, and put them where it says.
    func refreshNodeViews() {
        buildNodeViews()
        layoutNodeViews()
    }

    /// Build the views the visible region now needs, and place nothing that is already on screen.
    ///
    /// **A scroll moves no card, and nor does a zoom.** `viewRect` has no scale in it: a card's frame is
    /// in canvas coordinates, and the board itself is the thing being scrolled and magnified. So the
    /// layout pass that panning and zooming used to run was a walk over every card on the board to write
    /// each one the frame it already had — and `buildNodeViews` places a card as it makes it, which is
    /// the only placement either gesture can owe.
    ///
    /// Measured: a crossing into the picker ran 55 of those passes in 0.35s, 51ms of the ~350 available,
    /// because a flight posts a bounds change per frame (`CanvasScrollView.visibleRegionChanged`) and
    /// `centre(on:)` asked for a second one on top of it.
    func refreshVisibleCards() { buildNodeViews() }

    /// Build and drop card views as the visible region moves — without moving the ones that stay.
    ///
    /// The keep-alive region is the visible rectangle grown by a screenful, so a card is ready before
    /// it is scrolled to rather than popping in at the edge — and a card scrolled just off screen isn't
    /// thrown away only to be rebuilt when you scroll back a little.
    ///
    /// **Building and placing are two steps, and that is what makes an animated layout animate.** This
    /// used to end in a layout pass of its own, which `setLayout` ran *before* opening its animation
    /// group: every card was handed the frame the group was about to animate it to, so by the time the
    /// group ran there was nothing left to move and every tiling snapped into place. See
    /// `settleIntoLayout`.
    private func buildNodeViews() {
        guard window != nil else { return }
        FrameMeter.span("build") { buildNodeViewsBody() }
    }

    private func buildNodeViewsBody() {
        let visible = canvasRect(visibleRect)
        var keep = visible.inset(by: max(visible.width, visible.height) * 0.5)
        // A transform flight jumps the visible rect to where it is going and lets the compositor show
        // the way there, so what is on screen is not what `visibleRect` says. Keep both — see
        // `CanvasScrollView.travelling`.
        if let travelling = scrollView?.canvasScroll?.travelling {
            keep = keep.union(travelling)
        }
        // **A peek is an excursion with a return ticket.** At the zoom a peek arrives at, the keep-alive
        // region is about one card wide, so every other card on the board was torn down for the two
        // seconds you spent reading this one and built again on the way out — and a web card rebuilt is
        // a renderer started. Measured: three of them, 110-180ms in the settle after a peek out, which
        // was the largest thing left in that journey once the zoom went to the compositor. The board
        // knows exactly where it is going back to (`peeking`), so it keeps that region as well.
        if let peekOrigin {
            keep = keep.union(peekOrigin)
        }

        // Which cards should have a view at all — see `CanvasVisibleCards`, which is where the reason a
        // workspace keeps the cards it is hiding is written out, and the reason it stops keeping one
        // that has been deleted.
        let wanted = CanvasVisibleCards.wanted(in: document, layout: layout,
                                               keep: keep, built: Set(nodeViews.keys))
        for node in document.nodes where wanted.contains(node.id) {
            if let existing = nodeViews[node.id] {
                existing.update(node: node, scale: liveScale)
            } else {
                let view = CanvasNodeView.make(node: node, board: self, scale: liveScale)
                nodeViews[node.id] = view
                addSubview(view, positioned: .below, relativeTo: overlay)
                view.update(node: node, scale: liveScale)
                // Placed as it is built, and never animated into place: a card that had no view a
                // moment ago has nowhere to have come *from*, and inside an animation group it would
                // fly in from the board's corner.
                view.isHidden = !layout.shows(node.id)
                view.frame = viewRect(layout.frame(of: node))
            }
        }
        for (id, view) in nodeViews where !wanted.contains(id) {
            view.prepareForRemoval()
            view.removeFromSuperview()
            nodeViews.removeValue(forKey: id)
        }
    }

    /// Put every card where the layout says, at once and without animation.
    ///
    /// Internal because a drag calls it directly: a card being carried is repositioned on every
    /// mouse-moved event, and going through `setLayout` would be asking the board to reconsider a
    /// layout that has not changed.
    /// The cards the current crossing is fading out or in — the ones a workspace leaves behind. Kept
    /// because `layout` stops being able to answer the question halfway through; see `setLayout`.
    private(set) var fadingCards: Set<String> = []

    /// Whether a card is drawn at all, and how strongly.
    ///
    /// **Faded, not hidden, while the crossing is on screen.** A workspace of six cards on a board of
    /// forty-three used to take the other thirty-seven away in the frame it opened, which is the one
    /// moment the board could have said what it was doing with them. Now they go as the six fly, and
    /// come back as the six return — which is the true account: they are still there, they are not in
    /// this workspace.
    ///
    /// Hidden at the end regardless. A card at zero alpha is still a card AppKit lays out, hit-tests
    /// and hands events to, and a board of forty-three of those under a tiling is the cost the hiding
    /// was there to avoid.
    private func applyPresence(to view: CanvasNodeView, id: String) {
        let fading = fadingCards.contains(id)
        view.refreshTiledness(fading: fading)
        view.isHidden = layout.hides(id, fading: fading, alpha: view.alphaValue)
    }

    func layoutNodeViews() {
        FrameMeter.span("layoutViews") { layoutNodeViewsBody() }
    }

    private func layoutNodeViewsBody() {
        // The tiles' grips move with the tiles, and they are drawn a layer down from them.
        refreshTileHandles()
        if isTiled {
            tileHandleView.needsDisplay = true
            tileGripView.needsDisplay = true
        }
        let nodes = nodesByID
        var flying = 0, placed = 0, hiddenNow = 0
        for (id, view) in nodeViews {
            guard let node = nodes[id] else { continue }
            if view.isHidden { hiddenNow += 1 }
            // Hidden rather than thrown away. A tiled view of six cards would otherwise tear down the
            // other thirty-seven and rebuild them on the way out — which for a board of web cards means
            // reloading every page you were watching, as the price of having glanced at six of them.
            // And faded rather than hidden while the crossing is running — see `applyPresence`.
            applyPresence(to: view, id: id)
            // The arrangement may have handed this tile different corners — a tile moved from the end
            // of a stack into the middle keeps its size and loses two of them. Cheap when it hasn't,
            // which is every frame of a card being dragged around a board.
            view.refreshChrome()
            let wanted = viewRect(layout.frame(of: node))
            if animatesLayout, view.frame != wanted, !view.isHidden {
                view.animator().frame = wanted
                flying += 1
            } else {
                view.frame = wanted
                if animatesLayout { placed += 1 }
            }
        }
        // What a crossing actually handed to Core Animation. A crossing where every card is *placed*
        // rather than flown looks like a zoom with the cards already where they are going — see
        // `settleIntoLayout`, and the transform flight, which is how that came up.
        if animatesLayout, FrameMeter.isEnabled {
            Log.write("LAYOUT \(flying) flying, \(placed) placed, \(hiddenNow) hidden")
        }
        overlay.frame = NSRect(origin: .zero, size: frame.size)
        tileHandleView.frame = overlay.frame
        tileGripView.frame = overlay.frame
        // After the frame, because these are placed in it. See `refreshStripExcluders`.
        tileHandleView.refreshStripExcluders()
    }

    /// Set while cards should slide to their new places rather than appear there — entering and leaving
    /// a tiled arrangement, and nothing else. Every other layout pass is a drag, a scroll or a resize,
    /// where the card is already following your hand and an animation would be a lag.
    private var animatesLayout = false

    /// Change what the board is showing, with the cards moving to their new frames.
    ///
    /// Both halves matter. The animation is what makes a tiled view legible — six cards appearing in a
    /// grid says nothing about which card went where, and six cards flying there says all of it — and
    /// it is the same argument in reverse on the way out.
    ///
    /// `seconds` and `timing` are the crossing's, for the one caller that gives the cards and the zoom
    /// different curves so that one leads and the other trails — see `CanvasBoardView.cross`. Everything
    /// else takes the spring over 0.3s that a card landing in a slot has always used.
    func setLayout(_ next: CanvasLayout, animated: Bool,
                   seconds: Double = 0.3, timing: CAMediaTimingFunction = Motion.spring) {
        // **While picking, the board is what is shown**, whatever the tiling would lay out. Every change
        // to the workspace a click makes there comes through here with the tiles' layout, and taking it
        // would fly the cards back into tiles in the middle of choosing them.
        let shown = isPicking ? CanvasLayout.document : next
        guard shown != layout else { return }
        // Whoever is out of the picture at either end of this change is out of it at both, as far as the
        // fade is concerned: going in they are the cards the workspace does not show, and coming out
        // they are the same cards arriving back. Worked out here because a moment later the layout
        // cannot say — on the way out every card is in the layout again the instant it is set.
        fadingCards = CanvasLayout.fading(from: layout, to: shown,
                                          among: Set(document.nodes.map(\.id)))
        layout = shown
        // Built first, placed second — and when the move is animated, placed inside the animation.
        // See `buildNodeViews`, which is the half that must not touch a card that is about to fly.
        buildNodeViews()
        guard animated else {
            layoutNodeViews()
            overlay.needsDisplay = true
            needsDisplay = true
            settlePageBudget()
            return
        }
        settleIntoLayout(seconds: seconds, timing: timing)
        overlay.needsDisplay = true
        needsDisplay = true
    }

    /// Let every card slide to where the layout says it belongs.
    ///
    /// Its own method because a reorder ends without the layout changing at all: the order was applied
    /// as you crossed, and what is left on mouse-up is one card that has been held away from a slot it
    /// already owns. `setLayout` would decline that as a no-op.
    func settleIntoLayout(seconds: Double = 0.3, timing: CAMediaTimingFunction = Motion.spring) {
        settling += 1
        let generation = settling
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Motion.duration(seconds)
            context.timingFunction = timing
            context.allowsImplicitAnimation = true
            animatesLayout = true
            layoutNodeViews()
            animatesLayout = false
        } completionHandler: { [weak self] in
            // Only the last one lands. A reorder retargets the tiles on every crossing, so the group
            // started two crossings ago finishes while the current one is still in the air — and its
            // tidy-up pass, which is not animated, would drop every card on its mark mid-flight.
            guard let self, generation == settling else { return }
            layoutNodeViews()
            settlePageBudget()
        }
    }

    /// Which settling pass is the current one — see the completion handler above.
    private var settling = 0


    /// Zoom changed: cards that render differently at different sizes get told.
    func magnificationChanged() {
        FrameMeter.span("magChanged") { magnificationChangedBody() }
    }

    private func magnificationChangedBody() {
        // One pass over the document rather than a linear search per view: `CanvasDocument.node(id:)`
        // scans `nodes`, so asking it once per card made this O(cards × nodes) — 43 × 43 on a real
        // board, on every frame of a zoom.
        let nodes = nodesByID
        for (id, view) in nodeViews {
            guard let node = nodes[id] else { continue }
            view.update(node: node, scale: liveScale)
        }
        overlay.needsDisplay = true
        needsDisplay = true
        // Zooming changes which cards are near enough to want a view, and moves none of them.
        refreshVisibleCards()
    }

    /// The document's cards by id, for a pass that would otherwise ask for each one by name. Built per
    /// pass rather than cached: the document is a value that can change under any of them, and a stale
    /// index would place cards where they used to be.
    private var nodesByID: [String: CanvasNode] {
        Dictionary(document.nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    // MARK: The page budget

    /// Which of this board's web cards run a renderer, and when that is decided again.
    ///
    /// Lifted out of this class into `CanvasPageDirector`, which sees the board through
    /// `CanvasPageStage` — seven members rather than all hundred and thirty-six. The methods below
    /// stay because they are the board's published surface (the scroll view, the link cards and the
    /// pane controller all call them) and because forwarding is what let the move happen without
    /// touching any of those callers.
    lazy var pages = CanvasPageDirector(stage: self)

    /// Whether the board is in the middle of a crossing — the fade still travelling, or the view still
    /// flying to the zoom a tiling is laid out at.
    var isCrossing: Bool { tiledFade.isMoving || scrollView?.canvasScroll?.isFlying == true }

    /// The cards running a page. Read by the frame meter's labels.
    var pagesLive: Set<String> { pages.live }

    /// How often this board's pages reload themselves, or nil for never. See `CanvasPageDirector`.
    var refreshInterval: TimeInterval? {
        get { pages.refreshInterval }
        set { pages.refreshInterval = newValue }
    }
    var onRefreshIntervalChanged: (() -> Void)? {
        get { pages.onRefreshIntervalChanged }
        set { pages.onRefreshIntervalChanged = newValue }
    }
    static var refreshChoices: [TimeInterval] { CanvasPageDirector.refreshChoices }

    func pageSettingsChanged() { pages.settingsChanged() }
    func reclaimPages() { pages.reclaim() }
    func reviewPageBudget() { pages.review() }
    func settlePageBudget() { pages.settle() }
    func applyPageBudget() { pages.apply() }
    func pauseAllPages() { pages.pauseEverything() }
    func pauseIdlePages() { pages.pauseWhileAway() }

    /// Let every card go, because the board is going with it.
    ///
    /// `refreshNodeViews` already calls `prepareForRemoval` on a card that scrolls out of view, which is
    /// where a card gives back whatever it is holding — a project's store, most of all. A window closing
    /// takes the whole board without scrolling anything anywhere, so nothing would be given back at the
    /// one moment everything should be.
    func releaseCards() {
        for view in nodeViews.values { view.prepareForRemoval() }
    }

    // MARK: Saying what just happened

    /// Told when something happened that the board cannot show — a file downloaded, a link handed to
    /// another app, a page refused the camera.
    ///
    /// The window puts it in the notice bar. It goes through the board because the thing that knows is
    /// always a card, and a card has no window chrome of its own to say anything in.
    var onReport: ((String, URL?) -> Void)?

    /// ⌘L: put the keyboard in the header's address field. Set by the window, which owns the header.
    var onFocusAddress: (() -> Void)?

    func report(_ message: String, reveal file: URL? = nil) {
        onReport?(message, file)
        Log.write("canvas: \(message)")
    }

    // MARK: The grid

    /// How present the dot grid is, 0…1. See `drawGrid`.
    ///
    /// Up in a couple of frames, because it has to be there by the time you have noticed the card is
    /// moving; down slowly enough not to read as a blink between two quick drags.
    private lazy var gridFade = CanvasFade(rise: 0.09, fall: 0.22, on: self) { [weak self] in
        guard let self else { return }
        setNeedsDisplay(visibleRect)
    }
    var gridPresence: Double { gridFade.presence }

    /// Bring the grid up, or take it away.
    ///
    /// Never in a tiled view. The tiles are placed by the arrangement and snap to nothing, so a
    /// lattice behind them would be a claim about a geometry they don't have — and there is nothing
    /// to see through them anyway.
    func showGrid(_ wanted: Bool) {
        gridFade.set(wanted && !isTiled)
    }

    // MARK: Drawing what isn't a card

    /// What this board is painted with. A tiling sits on a deeper ground than a board does, which is
    /// what buys the near-invisible tile edge and the four-point gap — see `CanvasPalette.tileGround`.
    ///
    /// Asked of `tiledness` rather than of `isTiled`, so the step between the two grounds is taken over
    /// the same third of a second the cards take to fly rather than in the frame the mode changed.
    var ground: NSColor { CanvasPalette.ground(tiled: tiledness) }

    override func draw(_ dirty: NSRect) {
        FrameMeter.span("boardDraw") { drawBody(dirty) }
    }

    private func drawBody(_ dirty: NSRect) {
        ground.setFill()
        dirty.fill()
        drawGrid(in: dirty)
        // Frames and lines are statements about where cards are, and a tiled view has moved them. A line
        // routed to a position a card no longer has would be fiction drawn at full contrast; a tiled
        // view is about content, and the relationships are still there when you come back out.
        guard layout.isDocument else { return }
        // **And they come back at the pace the cards do.** The layout is the document's again in the
        // frame leaving starts, while every card is still somewhere over the board — so drawn outright,
        // a connection line is a full-contrast statement about where two cards are that will not be true
        // for another third of a second. Faded in against the crossing, it is a claim that arrives as
        // its evidence does. See `tiledness`.
        guard tiledness < 0.999 else { return }
        NSGraphicsContext.current?.saveGraphicsState()
        NSGraphicsContext.current?.cgContext.setAlpha(CGFloat(1 - tiledness))
        drawGroups(in: dirty)
        drawEdges(in: dirty)
        NSGraphicsContext.current?.restoreGraphicsState()
    }

    /// The dot grid — **while you are moving something, and not otherwise**.
    ///
    /// It used to be always on, which is what a canvas inherits from every canvas app that came before
    /// it: a permanent texture that says "this is an infinite plane". That is a true thing to say once
    /// and a strange thing to keep saying, and it was doing it underneath every card on the board, all
    /// the time, in service of a fact you learn in the first second.
    ///
    /// So it earns its way back on by being about something. A drag snaps to a 10pt lattice, and the
    /// grid *is* that lattice — it comes up when a card starts moving, says what the card is landing
    /// on, and goes when the card stops. Which also makes it honest about the modifier: hold ⌘ or ⌃ to
    /// turn snapping off and the grid goes with it, so the ground under a free drag is plainly free.
    ///
    /// The spacing steps up as you zoom out so the dots stay roughly the same distance apart on screen
    /// — at 20% a 10pt grid is a 2pt grid, which is a texture rather than a grid. It doubles rather
    /// than quadrupling, so every spacing it lands on is a real multiple of the snap and the dots you
    /// see are dots a card can actually stop on.
    ///
    /// **Nailed to the canvas, not to the view.** The dots are stepped off in *canvas* coordinates and
    /// converted, rather than stepped off in the view's own. Those differ by `content.minX/minY`, which
    /// is not a constant: the board grows whenever a card is dragged past its current extent, and its
    /// origin moves when it does. A grid laid out in view coordinates therefore slid sideways under
    /// the cards at the moment a drag reached the edge of the board — the one moment it is on screen —
    /// by whatever the origin had shifted by.
    ///
    /// It was also, for the same reason, not the lattice it claims to be. Snapping rounds *canvas*
    /// coordinates to a multiple of ten, so dots placed at multiples of ten in view coordinates sat
    /// wherever `content.minX` modulo the spacing happened to put them, and a card snapped to a
    /// position between two of the dots that were supposedly showing it where it could go.
    private func drawGrid(in dirty: NSRect) {
        guard gridPresence > 0.01 else { return }
        var spacing = CanvasSnapping.grid
        while spacing * liveScale < 14, spacing < 4000 { spacing *= 2 }
        guard spacing < 4000 else { return }

        let region = canvasRect(dirty)
        let radius = min(1.2, 1.0 / liveScale)
        CanvasPalette.grid(gridPresence).setFill()
        let path = NSBezierPath()
        var y = (region.minY / spacing).rounded(.down) * spacing
        while y <= region.maxY {
            var x = (region.minX / spacing).rounded(.down) * spacing
            while x <= region.maxX {
                let at = viewPoint(CanvasPoint(x: x, y: y))
                path.appendOval(in: NSRect(x: at.x - radius, y: at.y - radius,
                                           width: radius * 2, height: radius * 2))
                x += spacing
            }
            y += spacing
        }
        path.fill()
    }

    /// Frames, drawn behind everything else — a frame is a background that says "these belong
    /// together", so it is painted rather than built as a view. Nothing about it is interactive except
    /// where it is clicked, and that lives in the hit tester.
    private func drawGroups(in dirty: NSRect) {
        for node in document.nodes where node.isGroup {
            let rect = viewRect(node.frame)
            guard rect.intersects(dirty.insetBy(dx: -40, dy: -40)) else { continue }
            let path = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
            CanvasPalette.groupFill.setFill()
            path.fill()
            let picked = selection.contains(node.id)
            (picked ? NSColor.controlAccentColor : CanvasPalette.groupStroke).setStroke()
            path.lineWidth = (picked ? 3 : 1.5) / liveScale
            path.stroke()

            if case .group(let label, _, _) = node.content, let label, !label.isEmpty {
                let size = max(11, min(17, 15 / liveScale))
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: size, weight: .semibold),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]
                let text = label as NSString
                let measured = text.size(withAttributes: attributes)
                text.draw(at: NSPoint(x: rect.minX + 2, y: rect.minY - measured.height - 3),
                          withAttributes: attributes)
            }
        }
    }

    private func drawEdges(in dirty: NSRect) {
        let region = canvasRect(dirty.insetBy(dx: -80, dy: -80))
        for edge in document.edges {
            guard let curve = canvasRoute(for: edge, in: document),
                  curve.bounds.inset(by: 40).intersects(region) else { continue }
            let selected = selection.contains(edge.id)
            let under = hoveredEdge == edge.id
            let color = selected ? NSColor.controlAccentColor
                : (under ? CanvasPalette.edge.blended(withFraction: 0.35, of: .labelColor)
                        ?? CanvasPalette.edge
                   : CanvasPalette.edge)
            drawCurve(curve, color: color, width: (selected ? 3.5 : under ? 3.0 : 2.2) / liveScale,
                      startEnd: edge.resolvedFromEnd, endEnd: edge.resolvedToEnd, label: edge.label)
        }
    }

    func drawCurve(_ curve: CanvasCurve,
                   color: NSColor,
                   width: Double,
                   startEnd: CanvasEnd,
                   endEnd: CanvasEnd,
                   label: String?,
                   dashed: Bool = false) {
        let path = NSBezierPath()
        path.move(to: viewPoint(curve.start))
        path.curve(to: viewPoint(curve.end),
                   controlPoint1: viewPoint(curve.control1),
                   controlPoint2: viewPoint(curve.control2))
        path.lineWidth = width
        path.lineCapStyle = .round
        if dashed { path.setLineDash([6 / liveScale, 5 / liveScale], count: 2, phase: 0) }
        color.setStroke()
        path.stroke()

        if endEnd == .arrow { drawArrowhead(at: 1, on: curve, color: color) }
        if startEnd == .arrow { drawArrowhead(at: 0, on: curve, color: color) }

        if let label, !label.isEmpty { drawEdgeLabel(label, on: curve, color: color) }
    }

    /// The arrowhead, pointed along the curve's own tangent rather than along the straight line between
    /// the ends — on a bowed line those differ by enough to look like a mistake.
    private func drawArrowhead(at t: Double, on curve: CanvasCurve, color: NSColor) {
        let tip = viewPoint(curve.point(at: t))
        var direction = curve.direction(at: t)
        if t == 0 { direction = CanvasPoint(x: -direction.x, y: -direction.y) }

        let size = 9.5 / liveScale
        let angle = atan2(direction.y, direction.x)
        let spread = 0.42
        let path = NSBezierPath()
        path.move(to: tip)
        path.line(to: NSPoint(x: tip.x - cos(angle - spread) * size, y: tip.y - sin(angle - spread) * size))
        path.line(to: NSPoint(x: tip.x - cos(angle + spread) * size, y: tip.y - sin(angle + spread) * size))
        path.close()
        color.setFill()
        path.fill()
    }

    private func drawEdgeLabel(_ label: String, on curve: CanvasCurve, color: NSColor) {
        let size = max(9, min(13, 12 / liveScale))
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size),
            .foregroundColor: NSColor.labelColor,
        ]
        let text = label as NSString
        let measured = text.size(withAttributes: attributes)
        let mid = viewPoint(curve.point(at: 0.5))
        let box = NSRect(x: mid.x - measured.width / 2 - 5 / liveScale,
                         y: mid.y - measured.height / 2 - 2 / liveScale,
                         width: measured.width + 10 / liveScale, height: measured.height + 4 / liveScale)
        CanvasPalette.board.setFill()
        NSBezierPath(roundedRect: box, xRadius: 4 / liveScale, yRadius: 4 / liveScale).fill()
        text.draw(at: NSPoint(x: mid.x - measured.width / 2, y: mid.y - measured.height / 2),
                  withAttributes: attributes)
    }
}

private extension NSView {
    /// The first text view in this view's subtree, in drawing order.
    ///
    /// A card's editor is built by SwiftUI inside a hosting view, so the board has no reference to it
    /// and no protocol to ask for one — the view tree is the only place the answer is written down.
    var firstTextView: NSTextView? {
        if let text = self as? NSTextView { return text }
        for subview in subviews {
            if let found = subview.firstTextView { return found }
        }
        return nil
    }
}

// MARK: - The board as a stage for the page director

/// The seven things `CanvasPageDirector` is allowed to see. Everything here already existed; naming
/// them in a protocol is what stops the director reaching past them.
extension CanvasBoardView: CanvasPageStage {
    var pageCards: [String: CanvasPageCard] { nodeViews }

    var onScreenCanvasRect: CanvasRect { canvasRect(visibleRect) }

    func frame(ofNode id: String) -> CanvasRect? {
        document.node(id: id).map { layout.frame(of: $0) }
    }

    var hasWindow: Bool { window != nil }

    /// Whether the board is actually in front of somebody: not hidden, not minimised, not entirely
    /// behind something else. `.visible` is any part of the window, which is the right threshold —
    /// a board you have left a corner of showing is a board you meant to keep.
    var isOnScreen: Bool { window?.occlusionState.contains(.visible) ?? false }
}

/// See `CanvasBoardView.linkReorder`.
struct CanvasLinkReorder: Equatable {
    var card: String
    var list: UUID
    var from: Int
    var rows: [CanvasRect]
    var to: Int?
}
