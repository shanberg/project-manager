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
/// Not in a tiled view, where there is no free space to show a card being placed in: a drop there
/// still makes the card, where the pointer was, and the tiling takes it from there.
extension CanvasBoardView {
    /// Registering here rather than in the board's initialiser keeps the list beside the code that
    /// interprets it. See `CanvasDrop.read` for what each type becomes.
    func registerForDrops() {
        registerForDraggedTypes([.fileURL, .string, .URL] + NoteImagePasteboard.imageTypes)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let drop = CanvasDrop.read(sender.draggingPasteboard, cardsType: Self.pasteboardType)
        dropSession = CanvasDropSession(sequence: sender.draggingSequenceNumber, drop: drop,
                                        pasteboardChange: sender.draggingPasteboard.changeCount)
        if let filing = fileIntoFolder(sender) { return filing }
        guard let drop else { return [] }
        if !isTiled {
            place(sender)
            carry(sender, as: drop)
        }
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let session = dropSession, session.sequence == sender.draggingSequenceNumber else {
            return draggingEntered(sender)
        }
        if session.pasteboardChange != sender.draggingPasteboard.changeCount {
            return rereadDrop(sender)
        }
        if let filing = fileIntoFolder(sender) { return filing }
        guard let drop = session.drop else { return [] }
        if !isTiled {
            place(sender)
            // Back off a folder card: the files turn into the cards they would make again.
            if dropSession?.original == nil { carry(sender, as: drop) }
        }
        return .copy
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
        guard case .node(let id) = hitTester.hit(canvasPoint(point)), let model = folderModel(id) else { return nil }
        // Over one of its folders: that folder. Anywhere else on the card: the folder it is showing.
        if let row = nodeViews[id]?.link(at: point), row.hasDirectoryPath || CanvasFolderListing.isFolder(row),
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
        do {
            let done = try CanvasFolderDrop.perform(files, into: folder, copying: copying)
            registerFilingUndo(done, copied: copying)
            return true
        } catch {
            NSSound.beep()
            Log.write("folder drop failed: \(folder.path): \(error)")
            return false
        }
    }

    private func registerFilingUndo(_ done: [(from: URL, to: URL)], copied: Bool) {
        guard !done.isEmpty, let undo = window?.undoManager else { return }
        undo.registerUndo(withTarget: self) { _ in CanvasFolderDrop.undo(done, copied: copied) }
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
            dropSession?.drop = nil
            overlay.ghost = nil
            showGrid(false)
            return []
        }
        dropSession?.drop = drop
        if !isTiled {
            place(sender)
            carry(sender, as: drop)
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
        if let sender { giveBack(sender) }
        endDropPreview()
    }

    /// Said outright rather than left to `NSView`, because a web card asks it on the board's behalf —
    /// see `CanvasPageView` — and a drop the board has already shown you a card for should not then be
    /// refused by a default nobody chose.
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropSession?.folder != nil || dropSession?.drop != nil
            || CanvasDrop.read(sender.draggingPasteboard, cardsType: Self.pasteboardType) != nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { endDropPreview() }
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
        var frames = drop.frames(centredOn: canvasPoint(convert(sender.draggingLocation, from: nil)))
        if !isTiled, session != nil {
            place(sender)
            frames = dropSession?.landing ?? frames
        }
        guard commit(drop, frames: frames) else { return false }
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
        case .files(let files): return files.map(Self.face(forFile:))
        case .image(let data, _): return [NSImage(data: data).map(ProtoFace.picture) ?? .blank(nil)]
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

    private static func face(forFile file: URL) -> ProtoFace {
        if isMarkdownImagePath(file.path), let image = NSImage(contentsOf: file) { return .picture(image) }
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
