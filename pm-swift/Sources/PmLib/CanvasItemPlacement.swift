import Foundation

/// Where a card goes when nobody said where (docs/items.md D6).
///
/// **Every item is placed** (items.md, rule 2). There is no unplaced state — JSON Canvas gives every
/// node a rectangle, a board opened in Obsidian has to show the card somewhere sensible, and a list
/// that quietly left cards off the board would be the second truth D1 refused. What changes between
/// the board and a lens is not *whether* a card has a position but *who decides* it: the board asks
/// you, and this answers for the list, for `card.add`, and for anything else that adds without a point.
///
/// **The answer is a frame.** A frame is already a named set of cards with a position, already a tab,
/// already what a list groups by, and already what Tidy grows to hold its contents — so "somewhere
/// sensible" costs no new concept. Added under a frame, the card joins that frame; added under none,
/// it joins **Inbox**, made the first time something needs it.
///
/// This is not `CanvasTidy`, which re-lays out cards that are already somewhere. This finds the next
/// free slot and leaves everything else exactly where it is: adding an item must never move the cards
/// you arranged.
public enum CanvasItemPlacement {
    /// What the frame is called when a card had nowhere else to go.
    ///
    /// Not [views.md](views.md)'s rejected inbox — that was about task capture, which already has a
    /// right answer (the focused project's current sitting). A card has no such home. And this is an
    /// ordinary frame: rename it, move it, delete it, open it in a tab. What PM keeps of it is a mark
    /// on the node (`roleKey`) rather than a state of the project, and a label is only what a frame is
    /// called — so this is the default name for a new one, not how an existing one is found.
    public static let inboxLabel = "Inbox"

    /// The key a frame carries to say what PM keeps it for, and the one role there is.
    ///
    /// **The Inbox is a node, not a name.** "Inbox" is an ordinary word and a real board will already
    /// have frames called it — somebody's reading pile, a triage column drawn by hand — so a rule that
    /// found the Inbox by its label would pour PM's cards into whichever of those it met first, and
    /// would lose the frame the moment it was renamed. The frame PM adds into is marked instead, in
    /// the node's extra keys: unknown keys are what `CanvasDocument` keeps verbatim, so the mark
    /// survives every program that round-trips the file, Obsidian included. It is hidden in the sense
    /// that nothing draws it — a marked frame is an ordinary frame in every other way.
    ///
    /// Spelled as a role rather than a flag (`"pmRole": "inbox"`) to match `pmView`, and because the
    /// question a reader of the file has is *what is this frame for*.
    public static let roleKey = "pmRole"
    /// `roleKey`'s value on the frame that takes cards added without a place.
    public static let inboxRole = "inbox"

    /// The lattice every position lands on, matching the board's snapping.
    public static let lattice: Double = 10
    /// Between two cards in a frame's grid, and between a card and the frame's edge. `CanvasTidy`'s.
    public static let gutter: Double = 20
    /// The band at the top of a frame its label is drawn in, left clear so the first row of cards
    /// doesn't sit under the name of the thing it is in.
    public static let headroom: Double = 40
    /// How wide a new Inbox is: three cards across at the usual size, plus its gutters.
    public static let inboxColumns = 3

    /// Put a card on the board, in `frame` or in the Inbox, and answer it as it went in.
    ///
    /// **The node arrives whole and only its rectangle changes.** Everything a card carries — the
    /// browser session it was born on, `pmShows`, `pmView`, its colour — is set before it is placed,
    /// and a placement that built a fresh node would drop all of it. Its size is honoured: a card is
    /// born the size its kind is born, and where it goes is the only question here.
    ///
    /// The document is edited in place so a caller can do this inside one `store.change` — one write,
    /// one undo, whether or not the Inbox had to be made on the way.
    @discardableResult
    public static func place(_ node: CanvasNode,
                             to document: inout CanvasDocument,
                             frame frameID: String? = nil) -> CanvasNode {
        let size = (width: node.frame.width, height: node.frame.height)
        let home = resolveFrame(frameID, in: &document, cardSize: size)
        var placed = node
        placed.frame = nextSlot(in: home, of: document, size: size)
        document.nodes.append(placed)
        grow(home, in: &document, toHold: placed.frame)
        return placed
    }

    /// The same, for a caller that has content rather than a node — a line typed into a list's add row.
    @discardableResult
    public static func add(_ content: CanvasContent,
                           to document: inout CanvasDocument,
                           frame frameID: String? = nil,
                           size: (width: Double, height: Double) = (400, 400),
                           id: String = CanvasID.make()) -> CanvasNode {
        place(CanvasNode(id: id, content: content,
                         frame: CanvasRect(x: 0, y: 0, width: size.width, height: size.height)),
              to: &document, frame: frameID)
    }

    /// Move cards that are already on the board into `frame` — what a drop onto a section means
    /// (docs/items.md D7). Answers the ones that moved.
    ///
    /// The same slots `place` fills, for the same reason: a card joining a frame from a list should sit
    /// where a card added to that frame sits, not at whatever point the pointer happened to be over a
    /// row at.
    ///
    /// **A card already in the destination is left exactly where it is.** The list is sorted rather
    /// than ordered (items.md D2), so there is no dropping one card *between* two others to be done —
    /// and re-slotting a card onto the end of the frame it is already in would move something on the
    /// board in return for nothing in the list, which is the arrangement damage this whole file exists
    /// to avoid.
    @discardableResult
    public static func move(_ ids: [String], to frameID: String? = nil,
                            in document: inout CanvasDocument) -> [String] {
        // Asked before anything is resolved: a move of nothing must not be the thing that brings an
        // Inbox into being.
        guard let first = ids.compactMap({ document.node(id: $0) }).first(where: { !$0.isGroup }) else {
            return []
        }
        let home = resolveFrame(frameID, in: &document,
                                cardSize: (width: first.frame.width, height: first.frame.height))
        var moved: [String] = []
        for id in ids {
            guard let index = document.nodes.firstIndex(where: { $0.id == id }),
                  !document.nodes[index].isGroup,
                  let inside = document.node(id: home)?.frame else { continue }
            let card = document.nodes[index].frame
            if inside.contains(x: card.midX, y: card.midY) { continue }
            let slot = nextSlot(in: home, of: document, size: (width: card.width, height: card.height))
            document.nodes[index].frame = slot
            grow(home, in: &document, toHold: slot)
            moved.append(id)
        }
        return moved
    }

    /// The frame a card added here belongs to: the one named, else the Inbox, made if there isn't one.
    ///
    /// A named frame that has gone — a stale id from a list that has not reloaded — falls back to the
    /// Inbox rather than to nothing, because "add this" should not fail silently on a race.
    private static func resolveFrame(_ frameID: String?, in document: inout CanvasDocument,
                                     cardSize: (width: Double, height: Double)) -> String {
        if let frameID, document.nodes.contains(where: { $0.id == frameID && $0.isGroup }) { return frameID }
        return inbox(in: &document, cardSize: cardSize)
    }

    /// The board's Inbox, or nil for a board that hasn't got one.
    ///
    /// The marked frame first, whatever it is now called, and only then a frame labelled `Inbox` that
    /// nothing has marked — one somebody made themselves, or one PM made before it marked anything.
    /// Reading is forgiving in that second way so that an unmarked board still has an Inbox; writing,
    /// below, settles the question by marking whichever frame it found.
    public static func inbox(of document: CanvasDocument) -> CanvasNode? {
        document.nodes.first { $0.isGroup && $0.extra[roleKey]?.stringValue == inboxRole }
            ?? document.nodes.first { $0.isGroup && isLabelled($0, inboxLabel) }
    }

    /// The same, made if the board hasn't got one — and marked either way.
    ///
    /// **A frame already called Inbox is adopted, not doubled.** Two frames with one name, one of them
    /// the "real" one, is the confusing outcome; a person who drew a frame and called it Inbox meant
    /// the thing the word means. Marking it on the way past is what makes that a decision taken once:
    /// from then on the frame is the Inbox by identity, so renaming it to `Reading` keeps cards
    /// landing where they have been landing rather than starting a second pile.
    @discardableResult
    public static func inbox(in document: inout CanvasDocument,
                             cardSize: (width: Double, height: Double) = (400, 400)) -> String {
        let id = inbox(of: document)?.id ?? frame(labelled: inboxLabel, in: &document, cardSize: cardSize)
        if let index = document.nodes.firstIndex(where: { $0.id == id }) {
            document.nodes[index].extra[roleKey] = .string(inboxRole)
        }
        return id
    }

    private static func isLabelled(_ node: CanvasNode, _ label: String) -> Bool {
        canvasFrameLabel(node).compare(label, options: .caseInsensitive) == .orderedSame
    }

    /// The frame with this label, made — below everything already on the board — if there isn't one.
    ///
    /// What `card.add --frame Reading` resolves to, and what the Inbox itself is. A label rather than
    /// an id, because a caller that is not looking at the board has no ids and a frame's label is what
    /// it is called everywhere a person reads it.
    public static func frame(labelled label: String, in document: inout CanvasDocument,
                             cardSize: (width: Double, height: Double) = (400, 400)) -> String {
        if let existing = document.nodes.first(where: { $0.isGroup && isLabelled($0, label) }) {
            return existing.id
        }
        let width = snapped(Double(inboxColumns) * cardSize.width + Double(inboxColumns + 1) * gutter)
        let height = snapped(headroom + cardSize.height + gutter)
        // Below everything already on the board, a clear gutter down: a new frame must not land on the
        // arrangement somebody made, and below is the direction a board grows in reading order.
        let origin: (x: Double, y: Double)
        if let bounds = document.bounds {
            origin = (snapped(bounds.minX), snapped(bounds.maxY + gutter * 2))
        } else {
            origin = (0, 0)
        }
        let frame = CanvasNode(content: .group(label: label, background: nil, backgroundStyle: nil),
                               frame: CanvasRect(x: origin.x, y: origin.y, width: width, height: height))
        document.nodes.append(frame)
        return frame.id
    }

    /// The next free cell of the frame's grid: as many columns as the frame is wide enough for, filled
    /// left to right and then down, after however many cards are already in it.
    ///
    /// **Counted, not searched.** The slot is decided by how many cards the frame holds rather than by
    /// looking for a gap, so adding four items in a row puts them in four cells in the order you typed
    /// them — and a card you then drag out of the middle doesn't make the next add land back in the
    /// hole, which would reorder what you were writing.
    private static func nextSlot(in frameID: String, of document: CanvasDocument,
                                 size: (width: Double, height: Double)) -> CanvasRect {
        guard let frame = document.node(id: frameID) else {
            return CanvasRect(x: 0, y: 0, width: size.width, height: size.height)
        }
        let usable = frame.frame.width - gutter * 2
        let columns = max(1, Int((usable + gutter) / (size.width + gutter)))
        let taken = document.nodes.filter {
            !$0.isGroup && frame.frame.contains(x: $0.frame.midX, y: $0.frame.midY)
        }.count
        let column = taken % columns
        let row = taken / columns
        return CanvasRect(x: snapped(frame.frame.minX + gutter + Double(column) * (size.width + gutter)),
                          y: snapped(frame.frame.minY + headroom + Double(row) * (size.height + gutter)),
                          width: size.width, height: size.height)
    }

    /// A frame grows to hold its grid and never shrinks — `CanvasTidy`'s rule, and for its reason: a
    /// frame that shrank would move its own edge out from under cards somebody had put near it.
    private static func grow(_ frameID: String, in document: inout CanvasDocument, toHold card: CanvasRect) {
        guard let index = document.nodes.firstIndex(where: { $0.id == frameID }) else { return }
        let frame = document.nodes[index].frame
        let needed = card.maxY + gutter - frame.minY
        if needed > frame.height { document.nodes[index].frame.height = snapped(needed) }
        let across = card.maxX + gutter - frame.minX
        if across > frame.width { document.nodes[index].frame.width = snapped(across) }
    }

    private static func snapped(_ value: Double) -> Double { (value / lattice).rounded() * lattice }
}

/// The address a typed line is, or nil for a line that is prose (docs/items.md D6).
///
/// **What you typed decides what you get.** A line that says it is an address — a scheme, or a leading
/// `www.` — makes a web card; everything else makes a text card. Deliberately stricter than
/// `CanvasAddress.normalized`, which is the right rule for a field you opened *in order to* type an
/// address into and the wrong one here: most of what is typed into an add row is prose, and
/// `roadmap.md` is a note about a roadmap rather than a website in Moldova.
///
/// Shared by the list's add row and by `card.add`, so what a line becomes does not depend on which
/// surface you typed it into.
public func canvasTypedAddress(_ text: String) -> String? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace) else { return nil }
    if trimmed.contains("://") { return URL(string: trimmed) == nil ? nil : trimmed }
    guard trimmed.lowercased().hasPrefix("www.") else { return nil }
    let guessed = "https://" + trimmed
    return URL(string: guessed) == nil ? nil : guessed
}
