import AppKit
import PmLib
import UniformTypeIdentifiers

/// A drag in progress over a board: what it would make, where, and what the dragged image looked like
/// before the board turned it into the cards it is about to be.
struct CanvasDropSession {
    /// Which drag this is about. AppKit numbers them, and a session left behind by a drag that ended
    /// somewhere else must not be taken for the one arriving.
    let sequence: Int
    /// Nil for a pasteboard with nothing on it a board can hold — a drag the board declines.
    var drop: CanvasDrop?
    /// The drag pasteboard's change count when `drop` was read from it.
    ///
    /// **A drag's pasteboard is not settled when the drag arrives.** WebKit begins a link's dragging
    /// session and writes the link a few hundredths of a second later, twice, from the web process — and
    /// until it has, the shared drag pasteboard still holds the *previous* drag's link. A drag started on
    /// a page is over the board from its first moment, so reading once on the way in and trusting it
    /// for the rest of the drag made a card of the link dragged last time (backlog 42).
    /// `CanvasPageLinkDragTests` measures the premise. So every ask checks this and reads again.
    var pasteboardChange: Int
    /// The cards laid out centred under the pointer, before the snap.
    var carried: [CanvasRect] = []
    /// Where they would land if you let go now — `carried`, snapped — and where the picture is drawn.
    var landing: [CanvasRect] = []
    /// The source's own images, and where each sat relative to the pointer, so they can be given back
    /// when the drag leaves. Nil while the source's images are the ones on screen.
    var original: [Int: (components: [NSDraggingImageComponent], offset: NSPoint, size: NSSize)]?
    /// The picture the board gave the drag, drawn once and handed over again when AppKit asks.
    var picture: NSImage?
    /// A dragged image's bytes, decoded off main: nil until that lands, then the picture or nil for
    /// bytes that weren't one. `decodingImage` while it's out.
    var decodedImage: Picture??
    var decodingImage = false
    /// The folder card, and the folder in it, that files are over — where they'd be filed rather than
    /// made into cards. See `CanvasFolderDrop`.
    var folder: (card: String, url: URL)?
}

/// Dropping onto a board.
///
/// **The thing you are dragging becomes the card it will be.** Over the board a dragged link stops
/// being a link's picture and turns into the card the drop would make, at the size it will be, and the
/// board's own placement guides come up around it exactly as they do for a card being moved — the
/// outline where it would snap, and a glow on the cards it would be agreeing with. Let go and it
/// settles into the snapped place and is a card. Carry it off the board, or over something that has
/// somewhere to put it — a text card's open editor, a field on a web page — and it turns back into what
/// it was, because it is going to be that instead.
///
/// The turning is AppKit's own: a destination may give the items being dragged new images, and AppKit
/// animates the change and undoes it when the drag moves on — which is how the Finder turns an icon
/// into a list row. Nothing here animates anything by hand. See `carry`.
///
/// **What is shown is what lands.** The preview and the drop read the pasteboard through the one
/// `CanvasDrop`, lay it out through the one `frames(centredOn:)`, and snap it through the one
/// `CanvasSnapping.move` a dragged card uses. A preview with its own opinion would be a board that
/// shows you one thing and makes another.
///
/// Not in a tiled view, where there is no free space to show a card being placed in: a drop there is
/// marked on the tiles instead — beside the tile under the pointer, or into its tabs — and goes up
/// there (`markTileDrop`).
extension CanvasBoardView: CanvasPageDropClaim {
    /// Registering here rather than in the board's initialiser keeps the list beside the code that
    /// interprets it. See `CanvasDrop.read` for what each type becomes.
    func registerForDrops() {
        registerForDraggedTypes(Self.droppedTypes)
        rowDropCatcher.board = self
        NotificationCenter.default.addObserver(self, selector: #selector(rowDragChanged),
                                               name: SpaceRowDrag.didChange, object: nil)
    }

    /// Every type the board takes a drop of — and so `CanvasRowDropCatcher`'s too.
    static var droppedTypes: [NSPasteboard.PasteboardType] {
        [.fileURL, .string, .URL, SpaceRowDrag.pasteboardType] + NoteImagePasteboard.imageTypes
    }

    /// A row started or stopped travelling: the catcher is up over this board while one of its own is.
    @objc private func rowDragChanged() {
        let ours = SpaceRowDrag.current.map { $0.canvas.standardizedFileURL == store.url.standardizedFileURL } ?? false
        rowDropCatcher.frame = bounds
        rowDropCatcher.isHidden = !ours
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if let row = rowDrop(sender) { return row }
        let drop = CanvasDrop.read(sender.draggingPasteboard, cardsType: Self.pasteboardType)
        dropSession = CanvasDropSession(sequence: sender.draggingSequenceNumber, drop: drop,
                                        pasteboardChange: sender.draggingPasteboard.changeCount)
        if let filing = fileIntoFolder(sender) { clearTileDropMark(); return filing }
        guard let drop else { return [] }
        if !isTiled {
            place(sender)
            carry(sender, as: drop)
        } else {
            markTileDrop(sender)
        }
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if let row = rowDrop(sender) { return row }
        guard let session = dropSession, session.sequence == sender.draggingSequenceNumber else {
            return draggingEntered(sender)
        }
        if session.pasteboardChange != sender.draggingPasteboard.changeCount {
            return rereadDrop(sender)
        }
        if let filing = fileIntoFolder(sender) { clearTileDropMark(); return filing }
        guard let drop = session.drop else { return [] }
        if !isTiled {
            place(sender)
            // Back off a folder card: the files turn into the cards they would make again.
            // And a picture that landed since the drag's was drawn (see `face(forFile:)`) is drawn in.
            if dropSession?.original == nil || dropSession?.picture == nil { carry(sender, as: drop) }
        } else {
            markTileDrop(sender)
        }
        return .copy
    }

    // MARK: A row from the sidebar

    /// A card's row dragged from this board's sidebar (`SpaceRowDrag`). Over the tiles it goes where a
    /// dragged tile would — beside one at its edges, into its tabs at its top band — or, in a tile's
    /// middle, in that tile's place; marked on the tiles as they stand, and nothing moves until it's
    /// let go. Anywhere else it's refused: it's a card here already. Nil for any other drag, which
    /// includes a row of another board's sidebar (that one is its address, and makes a card).
    private func rowDrop(_ sender: NSDraggingInfo) -> NSDragOperation? {
        guard let id = SpaceRowDrag.card(in: sender, for: store.url) else { return nil }
        let target = rowTarget(id, at: canvasPoint(convert(sender.draggingLocation, from: nil)))
        let mark = target.flatMap { target in
            tiling?.dragMark(target.drop, on: target.target, bar: dragMarkBar).map { (rect: $0, title: rowDropTitle(id, target.drop)) }
        }
        if dropMark?.rect != mark?.rect || dropMark?.title != mark?.title {
            dropMark = mark
            overlay.needsDisplay = true
        }
        tileDropMarked = mark != nil
        guard target != nil else { return [] }
        let allowed = sender.draggingSourceOperationMask
        return allowed.contains(.move) ? .move : allowed.contains(.copy) ? .copy : .generic
    }

    /// Where a row let go at `point` would land in the tiling, or nil for nowhere (`CanvasTileSession.drop(ofCard:at:)`).
    func rowTarget(_ id: String, at point: CanvasPoint) -> (target: String, drop: CanvasTileSession.Drop)? {
        guard !isPicking else { return nil }
        return tiling?.drop(ofCard: id, at: point)
    }

    /// What the mark says: a card that isn't up takes a tile's place rather than swapping with it.
    private func rowDropTitle(_ id: String, _ drop: CanvasTileSession.Drop) -> String {
        drop == .swap && tiling?.cards.contains(id) != true ? "Replace" : drop.title
    }

    /// Let go of a row over the tiles: what the mark said, and the card focused.
    /// `others`: picked rows carried with it, which join its tile as tabs after it.
    func landRow(_ id: String, _ target: (target: String, drop: CanvasTileSession.Drop), with others: [String] = []) {
        let undoFrom = beginTilingUndo()
        defer { endTilingUndo("Add to Layout", from: undoFrom) }
        guard var session = tiling, document.node(id: id).map({ !$0.isGroup }) ?? false else { return }
        if session.cards.contains(id) {
            session.land(id, on: target.target, target.drop, pulling: true)
        } else {
            switch target.drop {
            case .swap: guard session.replace(target.target, with: id) else { return NSSound.beep() }
            case .beside(let side): session.add(id, at: .init(target: target.target, side: side))
            }
        }
        let others = others.filter { $0 != id && document.node(id: $0).map { !$0.isGroup } ?? false }
        if !others.isEmpty {
            for other in others where !session.cards.contains(other) {
                session.add(other, at: .init(target: id, side: .tab))
            }
            let tile = session.tabs(of: id)
            let before = tile.prefix { $0 != id }.filter { !others.contains($0) }.count
            session.gatherTabs([id] + others, into: id, at: before)
        }
        _ = session.showTab(id)
        guard session != tiling else { return }
        tiling = session
        select([id])
        setLayout(session.layout, animated: true)
        onTilingChanged?()
        announceTiling()
    }

    // MARK: A note, file or link over the tiles

    /// Something dragged in from outside over the tiles goes where the pointer says, the way a sidebar
    /// row does: beside a tile at its edges, into its tabs on its strip or in its middle
    /// (`CanvasTileSession.drop(ofNewCardAt:)`). Off the tiles, it goes where the next card goes.
    ///
    /// This is how a note goes up beside the Figma file you have open. A web tile keeps the middle —
    /// files dropped there are the page's (`CanvasPageLinkHost.pageTakesFiles`) — and gives its edges
    /// and strip to the tiling (`tilingTakesDrop`).
    func tileDropTarget(at point: CanvasPoint) -> (target: String, drop: CanvasTileSession.Drop)? {
        guard !isPicking else { return nil }
        return tiling?.drop(ofNewCardAt: point)
    }

    /// Whether a drag over a web tile at `sender`'s pointer is the tiling's rather than the page's: on
    /// the tile's edges or strip, carrying something the board can make a card of. Asked by
    /// `CanvasPageView` before the page.
    func tilingTakesDrop(_ sender: NSDraggingInfo) -> Bool {
        guard let tiling, !isPicking, SpaceRowDrag.card(in: sender, for: store.url) == nil,
              tiling.isTilingGround(canvasPoint(convert(sender.draggingLocation, from: nil))) else { return false }
        return CanvasDrop.read(sender.draggingPasteboard, cardsType: Self.pasteboardType) != nil
    }

    func claimsDrop(_ sender: NSDraggingInfo) -> Bool { tilingTakesDrop(sender) }

    /// Mark where the drop would land, on the tiles as they stand — nothing moves until it's let go.
    private func markTileDrop(_ sender: NSDraggingInfo) {
        let target = tileDropTarget(at: canvasPoint(convert(sender.draggingLocation, from: nil)))
        let mark = target.flatMap { target in
            tiling?.dragMark(target.drop, on: target.target, bar: dragMarkBar).map { (rect: $0, title: target.drop.title) }
        }
        if dropMark?.rect != mark?.rect || dropMark?.title != mark?.title {
            dropMark = mark
            overlay.needsDisplay = true
        }
        tileDropMarked = mark != nil
    }

    private func clearTileDropMark() {
        guard tileDropMarked else { return }
        tileDropMarked = false
        dropMark = nil
        overlay.needsDisplay = true
    }

    // MARK: Filing into a folder card

    /// Files over a folder card go into its folder, the Finder's drop — or into the folder row under
    /// the pointer. Answers the operation while that is where they'd go, having put the source's own
    /// picture back and lit the target; nil when they aren't over one, having put the target out.
    ///
    /// Only files from outside the board: the board's own cards, dragged, carry their own pasteboard
    /// type and stay cards.
    private func fileIntoFolder(_ sender: NSDraggingInfo) -> NSDragOperation? {
        let target = folderTarget(sender)
        let files = target == nil ? [] : Self.files(on: sender.draggingPasteboard)
        let operation = target.map {
            CanvasFolderDrop.operation(for: files, into: $0.url, allowed: sender.draggingSourceOperationMask)
        } ?? []
        let aimed = operation.isEmpty ? nil : target
        if dropSession?.folder?.card != aimed?.card || dropSession?.folder?.url != aimed?.url {
            if let was = dropSession?.folder { folderModel(was.card)?.dropTarget = nil }
            if let aimed { folderModel(aimed.card)?.dropTarget = aimed.url }
            dropSession?.folder = aimed
        }
        guard aimed != nil else { return nil }
        giveBack(sender)
        dropSession?.original = nil
        overlay.ghost = nil
        showGrid(false)
        return operation
    }

    private func folderTarget(_ sender: NSDraggingInfo) -> (card: String, url: URL)? {
        let pasteboard = sender.draggingPasteboard
        guard pasteboard.types?.contains(Self.pasteboardType) != true,
              pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        else { return nil }
        let point = convert(sender.draggingLocation, from: nil)
        // A folder tile's edges and strip are the tiling's, like any tile's: the files go beside it.
        if tiling?.isTilingGround(canvasPoint(point)) == true { return nil }
        guard case .node(let id) = hitTester.hit(canvasPoint(point)), let model = folderModel(id) else { return nil }
        // Over one of its folders: that folder. Anywhere else on the card: the folder it is showing.
        if let row = (nodeViews[id] as? CanvasFileNodeView)?.folderRow(at: point),
           CanvasFolderModel.contains(model.url, row) {
            return (id, row)
        }
        return (id, model.location)
    }

    private func folderModel(_ id: String) -> CanvasFolderModel? {
        (nodeViews[id] as? CanvasFileNodeView)?.folderModel
    }

    private static func files(on pasteboard: NSPasteboard) -> [URL] {
        (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    /// Let go over a folder card: file them, and make it undoable.
    private func performFiling(_ sender: NSDraggingInfo, into folder: URL) -> Bool {
        let files = Self.files(on: sender.draggingPasteboard)
        let operation = CanvasFolderDrop.operation(for: files, into: folder, allowed: sender.draggingSourceOperationMask)
        guard !operation.isEmpty else { return false }
        let copying = operation == .copy
        // Off main, the card saying so meanwhile: the drop is accepted now and lands when it's done.
        let model = dropSession?.folder.flatMap { folderModel($0.card) }
        CanvasFolderDrop.file(files, into: folder, copying: copying, model: model) { [weak self] done, failure in
            if let failure {
                NSSound.beep()
                Log.write("folder drop failed: \(folder.path): \(failure)")
            }
            self?.registerFilingUndo(done, copied: copying)
            model?.refresh()
        }
        return true
    }

    private func registerFilingUndo(_ done: [(from: URL, to: URL)], copied: Bool) {
        guard !done.isEmpty, let undo = window?.undoManager else { return }
        undo.registerUndo(withTarget: self) { _ in
            MainActor.assumeIsolated { CanvasFolderDrop.undoInBackground(done, copied: copied) }
        }
        let what = done.count == 1 ? "“\(done[0].to.lastPathComponent)”" : "\(done.count) Items"
        undo.setActionName(copied ? "Copy of \(what)" : "Move of \(what)")
    }

    /// The pasteboard changed under a drag already here: read it again, and redraw what is carried.
    ///
    /// The picture goes with the drop it was drawn from. The source's own images, if they have been
    /// swapped out, are given back first when there is nothing left to show instead.
    private func rereadDrop(_ sender: NSDraggingInfo) -> NSDragOperation {
        let drop = CanvasDrop.read(sender.draggingPasteboard, cardsType: Self.pasteboardType)
        dropSession?.pasteboardChange = sender.draggingPasteboard.changeCount
        dropSession?.picture = nil
        guard let drop else {
            giveBack(sender)
            clearTileDropMark()
            dropSession?.drop = nil
            overlay.ghost = nil
            showGrid(false)
            return []
        }
        dropSession?.drop = drop
        if !isTiled {
            place(sender)
            carry(sender, as: drop)
        } else {
            markTileDrop(sender)
        }
        return .copy
    }

    /// AppKit's own moment for a destination to change the dragging images — once a drop here looks
    /// likely, per `NSDragging.h`. The picture was handed over on the way in already; this answers the
    /// question the way the header asks for it to be answered.
    override func updateDraggingItemsForDrag(_ sender: NSDraggingInfo?) {
        guard let sender, !isTiled, dropSession?.sequence == sender.draggingSequenceNumber else { return }
        if dropSession?.pasteboardChange != sender.draggingPasteboard.changeCount {
            _ = rereadDrop(sender)
            return
        }
        guard let drop = dropSession?.drop else { return }
        carry(sender, as: drop)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        clearTileDropMark()
        if let sender { giveBack(sender) }
        endDropPreview()
    }

    /// Said outright rather than left to `NSView`, because a web card asks it on the board's behalf —
    /// see `CanvasPageView` — and a drop the board has already shown you a card for should not then be
    /// refused by a default nobody chose.
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if let id = SpaceRowDrag.card(in: sender, for: store.url) {
            return rowTarget(id, at: canvasPoint(convert(sender.draggingLocation, from: nil))) != nil
        }
        return dropSession?.folder != nil || dropSession?.drop != nil
            || CanvasDrop.read(sender.draggingPasteboard, cardsType: Self.pasteboardType) != nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { endDropPreview() }
        if let id = SpaceRowDrag.card(in: sender, for: store.url) {
            tileDropMarked = false
            dropMark = nil
            overlay.needsDisplay = true
            guard let target = rowTarget(id, at: canvasPoint(convert(sender.draggingLocation, from: nil))) else {
                return false
            }
            let carried = SpaceRowDrag.cards(in: sender, for: store.url)
            SpaceRowDrag.end()
            landRow(id, target, with: Array(carried.dropFirst()))
            return true
        }
        if dropSession?.sequence == sender.draggingSequenceNumber, let folder = dropSession?.folder {
            return performFiling(sender, into: folder.url)
        }
        // Read again if the pasteboard moved since the last ask: letting go is the one moment it has to be
        // right, and the drop is made from what it holds now rather than from what it held on the way in.
        if dropSession?.sequence == sender.draggingSequenceNumber,
           dropSession?.pasteboardChange != sender.draggingPasteboard.changeCount {
            _ = rereadDrop(sender)
        }
        let session = dropSession?.sequence == sender.draggingSequenceNumber ? dropSession : nil
        guard let drop = session?.drop
                ?? CanvasDrop.read(sender.draggingPasteboard, cardsType: Self.pasteboardType) else {
            return false
        }
        // Placed once more at the pointer's last position, so the card lands where the guides said it
        // would at the moment you let go rather than where they said it one update ago.
        let point = canvasPoint(convert(sender.draggingLocation, from: nil))
        var frames = drop.frames(centredOn: point)
        if !isTiled, session != nil {
            place(sender)
            frames = dropSession?.landing ?? frames
        }
        clearTileDropMark()
        // Over a tile: where the mark said. A drop's middle is always a tab, never a swap.
        let tile = tileDropTarget(at: point).flatMap { target -> CanvasTileSession.Placement? in
            guard case .beside(let side) = target.drop else { return nil }
            return .init(target: target.target, side: side)
        }
        guard commit(drop, frames: frames, beside: tile) else { return false }
        if dropSession?.original != nil { settle(sender, onto: frames) }
        return true
    }

    // MARK: Placing

    /// Lay the drop out under the pointer and snap it, putting up the guides a moving card gets.
    ///
    /// ⌘ and ⌃ are read off the keyboard rather than off an event, because a drag delivers none: they
    /// mean "leave me alone" here exactly as they do for a card you are moving.
    private func place(_ sender: NSDraggingInfo) {
        guard let drop = dropSession?.drop else { return }
        let carried = drop.frames(centredOn: canvasPoint(convert(sender.draggingLocation, from: nil)))
        guard let box = Self.bounds(of: carried) else { return }
        let free = !Self.suspendsSnapping(NSEvent.modifierFlags)
        let snap = CanvasSnapping.move(box, by: (dx: 0, dy: 0),
                                       against: snapCandidates(excluding: []),
                                       reach: free ? CanvasSnapping.reach / liveScale : 0,
                                       showReach: free ? CanvasSnapping.showReach / liveScale : 0,
                                       snapsToGrid: free)
        let landing = Self.shifted(carried, onto: snap.frame, from: box)
        dropSession?.carried = carried
        dropSession?.landing = landing
        // **The picture is where the card will land**, not centred on the pointer beside an outline
        // saying otherwise (backlog 44). It steps with the snap as the outline does, and letting go is
        // no longer a jump by the snap's offset. Only once the picture is the board's: the source's own
        // image rides under the pointer until `carry` has swapped it out.
        if dropSession?.original != nil, let frame = Self.bounds(of: landing).map(viewRect) {
            sender.enumerateDraggingItems(options: [], for: self, classes: [NSPasteboardItem.self],
                                          searchOptions: [:]) { item, _, _ in
                item.draggingFrame = frame
            }
        }
        overlay.ghost = snap.ghost.map {
            CanvasOverlayView.Ghost($0, frames: Self.shifted(carried, onto: $0.frame, from: box),
                                    beneath: standingCards(excluding: []))
        }
        showGrid(free)
    }

    private func endDropPreview() {
        if let folder = dropSession?.folder { folderModel(folder.card)?.dropTarget = nil }
        dropSession = nil
        overlay.ghost = nil
        showGrid(false)
    }

    // MARK: Turning the dragged thing into cards

    /// Give the items being dragged the picture of the cards they would make.
    ///
    /// **All of it on the first item.** A drag of three browser tabs is three items and makes three
    /// cards, but a drag of one text selection is one item and still one card, and copied cards are one
    /// item and any number of cards — there is no pairing of items with cards that holds in general. So
    /// the first item carries a single picture of every card, laid out as they will land, and the rest
    /// are emptied into it: AppKit animates each of them to its new frame and contents, so the others
    /// visibly fold into the one that becomes the cards.
    ///
    /// The source's images are kept first, with where they sat relative to the pointer, for
    /// `giveBack`. AppKit undoes a destination's images when a drag leaves it, but not when the drag
    /// moves between the board and a page inside one of its cards — which to AppKit is one view the
    /// whole time. See `CanvasPageView`.
    ///
    /// Asked again by `updateDraggingItemsForDrag`, so the source's images are taken only the first
    /// time, while they are still the source's, and the picture is drawn once and handed over again.
    private func carry(_ sender: NSDraggingInfo, as drop: CanvasDrop) {
        guard let carried = dropSession?.carried, let box = Self.bounds(of: carried) else { return }
        let picture = dropSession?.picture ?? protoCards(drop, frames: carried, in: box)
        // Drawn from `carried` and put at `landing`: the two are the same cards moved by the snap, so the
        // picture is the same either way and only where it goes differs. See `place`.
        let frame = viewRect(dropSession.flatMap { Self.bounds(of: $0.landing) } ?? box)
        let pointer = convert(sender.draggingLocation, from: nil)
        let kept = dropSession?.original
        var original: [Int: (components: [NSDraggingImageComponent], offset: NSPoint, size: NSSize)] = [:]
        sender.draggingFormation = .none
        sender.enumerateDraggingItems(options: [], for: self, classes: [NSPasteboardItem.self],
                                      searchOptions: [:]) { item, index, _ in
            if kept == nil {
                original[index] = (item.imageComponents ?? [],
                                   NSPoint(x: item.draggingFrame.minX - pointer.x,
                                           y: item.draggingFrame.minY - pointer.y),
                                   item.draggingFrame.size)
            }
            if index == 0 {
                item.setDraggingFrame(frame, contents: picture)
            } else {
                item.draggingFrame = frame
                item.imageComponentsProvider = { [] }
            }
        }
        dropSession?.original = kept ?? original
        dropSession?.picture = picture
    }

    /// Put the source's own images back, under the pointer where it has got to.
    private func giveBack(_ sender: NSDraggingInfo) {
        guard let original = dropSession?.original else { return }
        let pointer = convert(sender.draggingLocation, from: nil)
        sender.enumerateDraggingItems(options: [], for: self, classes: [NSPasteboardItem.self],
                                      searchOptions: [:]) { item, index, _ in
            guard let saved = original[index] else { return }
            item.draggingFrame = NSRect(origin: NSPoint(x: pointer.x + saved.offset.x,
                                                        y: pointer.y + saved.offset.y),
                                        size: saved.size)
            let components = saved.components
            item.imageComponentsProvider = { components }
        }
        dropSession?.original = nil
        dropSession?.picture = nil
    }

    /// Slide the picture into the place the cards were given, rather than letting it vanish where the
    /// pointer happened to be. The picture already rides at the snapped place (`place`), so this is
    /// what keeps it there for the last frame rather than a correction of any size.
    private func settle(_ sender: NSDraggingInfo, onto frames: [CanvasRect]) {
        guard let box = Self.bounds(of: frames) else { return }
        let frame = viewRect(box)
        sender.animatesToDestination = true
        sender.enumerateDraggingItems(options: [], for: self, classes: [NSPasteboardItem.self],
                                      searchOptions: [:]) { item, _, _ in
            item.draggingFrame = frame
        }
    }

    // MARK: The picture

    /// What one card of a drop shows while it is still only a picture.
    private enum ProtoFace {
        /// A web page: the site's icon if the app already has it, and whose page it is — which is what
        /// a link card shows until its page arrives.
        case page(icon: NSImage?, name: String)
        case prose(String)
        case file(icon: NSImage, name: String)
        case picture(NSImage)
        case blank(String?)
    }

    /// Every card of a drop drawn into one picture, at the size and in the arrangement they will land.
    ///
    /// Drawn in canvas units and handed to AppKit at the card's frame in the board's coordinates, so
    /// the picture is exactly as large on screen as the card will be at the zoom you are at. Vector
    /// all the way down — the drawing handler runs at whatever resolution the drag is shown at.
    private func protoCards(_ drop: CanvasDrop, frames: [CanvasRect], in box: CanvasRect) -> NSImage {
        let faces = protoFaces(drop)
        let appearance = effectiveAppearance
        return NSImage(size: NSSize(width: box.width, height: box.height), flipped: true) { _ in
            appearance.performAsCurrentDrawingAppearance {
                for (frame, face) in zip(frames, faces) {
                    Self.draw(face, in: NSRect(x: frame.minX - box.minX, y: frame.minY - box.minY,
                                               width: frame.width, height: frame.height),
                              radius: CanvasNodeView.cornerRadius(for: frame))
                }
            }
            return true
        }
    }

    private func protoFaces(_ drop: CanvasDrop) -> [ProtoFace] {
        switch drop {
        case .cards(let document): return document.nodes.map { Self.face(for: $0.content) }
        case .files(let files): return files.map(face(forFile:))
        case .image(let data, _):
            // Decoded off main, once per drag, and the picture drawn again when it lands. See `PictureStore`.
            if let decoded = dropSession?.decodedImage { return [decoded.map { .picture($0.image) } ?? .blank(nil)] }
            if dropSession?.decodingImage != true {
                dropSession?.decodingImage = true
                let sequence = dropSession?.sequence
                PictureStore.decode(data, maxSide: 1024) { [weak self] picture in
                    guard let self, dropSession?.sequence == sequence else { return }
                    dropSession?.decodedImage = .some(picture)
                    dropSession?.picture = nil
                }
            }
            return [.blank(nil)]
        case .links(let links): return links.map { Self.face(forPage: $0.address) }
        case .text(let text): return [.prose(text)]
        }
    }

    private static func face(for content: CanvasContent) -> ProtoFace {
        switch content {
        case .text(let text): return .prose(text)
        case .link(let url): return face(forPage: url)
        case .file(let path, _):
            let ext = (path as NSString).pathExtension
            return .file(icon: NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data),
                         name: (path as NSString).lastPathComponent)
        case .group(let label, _, _): return .blank(label)
        }
    }

    /// A picture file shows itself once `PictureStore` has it — read and decoded off main — and its
    /// icon until then; the drag's picture is drawn again when it lands.
    private func face(forFile file: URL) -> ProtoFace {
        if isMarkdownImagePath(file.path) {
            let sequence = dropSession?.sequence
            let lookup = PictureStore.shared.picture(at: file, maxSide: 1024, owner: self) { [weak self] in
                guard let self, dropSession?.sequence == sequence else { return }
                dropSession?.picture = nil
            }
            if let picture = lookup.picture { return .picture(picture.image) }
        }
        return .file(icon: NSWorkspace.shared.icon(forFile: file.path), name: file.lastPathComponent)
    }

    private static func face(forPage address: String) -> ProtoFace {
        let host = URL(string: address)?.host() ?? address
        return .page(icon: FaviconLoader.shared.cached(for: host), name: host)
    }

    private static func draw(_ face: ProtoFace, in rect: NSRect, radius: Double) {
        let card = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        CanvasPalette.card.setFill()
        card.fill()

        NSGraphicsContext.saveGraphicsState()
        card.addClip()
        switch face {
        case .page(let icon, let name):
            let globe = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 24, weight: .light)
                    .applying(NSImage.SymbolConfiguration(hierarchicalColor: .tertiaryLabelColor)))
            centred(icon ?? globe, side: 28, name: name,
                    font: .systemFont(ofSize: 13, weight: .medium), in: rect)
        case .file(let icon, let name):
            centred(icon, side: 48, name: name, font: .systemFont(ofSize: 12), in: rect)
        case .picture(let image):
            let size = image.size
            if size.width > 0, size.height > 0 {
                let fit = min(rect.width / size.width, rect.height / size.height)
                let drawn = NSSize(width: size.width * fit, height: size.height * fit)
                image.draw(in: NSRect(x: rect.midX - drawn.width / 2, y: rect.midY - drawn.height / 2,
                                      width: drawn.width, height: drawn.height),
                           from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
        case .prose(let text):
            (text as NSString).draw(with: rect.insetBy(dx: 11, dy: 9),
                                    options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                    attributes: [.font: NSFont.systemFont(ofSize: 13),
                                                 .foregroundColor: NSColor.labelColor])
        case .blank(let label):
            if let label {
                (label as NSString).draw(with: rect.insetBy(dx: 11, dy: 9),
                                         options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                         attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium),
                                                      .foregroundColor: NSColor.secondaryLabelColor])
            }
        }
        NSGraphicsContext.restoreGraphicsState()

        CanvasPalette.cardBorder.setStroke()
        card.lineWidth = CanvasNodeView.hairline
        card.stroke()
    }

    /// An icon over a name, the pair centred in the card — the shape of a link card's placeholder.
    private static func centred(_ icon: NSImage?, side: Double, name: String, font: NSFont, in rect: NSRect) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor,
                                                         .paragraphStyle: paragraph]
        let width = max(0, rect.width - 24)
        let measured = (name as NSString).boundingRect(
            with: NSSize(width: width, height: font.pointSize * 3),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes)
        let gap = 8.0, textHeight = ceil(measured.height)
        let top = rect.midY - (side + gap + textHeight) / 2
        icon?.draw(in: NSRect(x: rect.midX - side / 2, y: top, width: side, height: side),
                   from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        (name as NSString).draw(with: NSRect(x: rect.minX + 12, y: top + side + gap, width: width,
                                             height: textHeight),
                                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                attributes: attributes)
    }

    // MARK: Geometry

    static func bounds(of frames: [CanvasRect]) -> CanvasRect? {
        guard let first = frames.first else { return nil }
        return frames.dropFirst().reduce(first) { $0.union($1) }
    }

    /// `frames`, moved as one by however far `box` has to go to become `target`.
    static func shifted(_ frames: [CanvasRect], onto target: CanvasRect, from box: CanvasRect) -> [CanvasRect] {
        let dx = target.minX - box.minX, dy = target.minY - box.minY
        return frames.map { CanvasRect(x: $0.x + dx, y: $0.y + dy, width: $0.width, height: $0.height) }
    }
}
