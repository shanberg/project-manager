import Foundation

/// A project's links, kept as web cards in a frame on its canvas — and `## Links` in its notes as a
/// mirror of that frame.
///
/// **One thing, not two.** A link in the notes and a web card on the board were separate: the same
/// address could be both, neither knew about the other, and the bridges between them — Add Link from a
/// page, a Links row dragged onto the board — made copies. docs/items.md D1 had already refused a second
/// store of what a project contains. So the link *is* the card: it has an id a workspace can hold, the
/// browser session and zoom a card carries, and a place on the board. Its name, which a web card never
/// needed, is kept on the node (`labelKey`).
///
/// **The notes keep a list, written from the frame.** A project's notes are read in Obsidian and in git,
/// and `## Links` is where anyone reading them looks. So the section stays, in the format it always had,
/// and is rewritten whenever the frame changes. Edits made to it by hand are not lost: `sync` compares
/// the notes and the frame against the list it last wrote (`mirrorKey`) and takes in whatever changed
/// in the notes since — a line added becomes a card, a line removed removes one, a name changed renames
/// it. The first sync of a project has written nothing yet, so every link in its notes is new, and
/// that is the whole of migrating a project.
///
/// **Found by its mark, as the Inbox is** (`CanvasItemPlacement.roleKey`). A frame somebody already
/// called Links is adopted and marked the first time it's needed, so it goes on being the Links frame
/// when it's renamed.
public enum ProjectLinksFrame {
    /// `CanvasItemPlacement.roleKey`'s value on the frame that holds the project's links.
    public static let role = "links"
    /// What a new Links frame is called.
    public static let label = "Links"
    /// A link card's name, as its row in the Links list says it. A web card is otherwise named by the
    /// page it last loaded, which is a title the site chose, not the one you gave the link.
    public static let labelKey = "pmLabel"
    /// On the frame: the list as it was last written to the notes, as JSON — what `sync` measures
    /// hand edits against.
    public static let mirrorKey = "pmLinksMirror"
    /// The size a link card is born.
    public static let cardSize = (width: 400.0, height: 300.0)

    /// The project's Links frame, or nil for a canvas that hasn't got one.
    public static func frame(of document: CanvasDocument) -> CanvasNode? {
        document.nodes.first { $0.isGroup && $0.extra[CanvasItemPlacement.roleKey]?.stringValue == role }
    }

    /// The frame, made — or an unmarked one called Links adopted — if there isn't one.
    @discardableResult
    public static func frame(in document: inout CanvasDocument) -> String {
        if let existing = frame(of: document) { return existing.id }
        let id = CanvasItemPlacement.frame(labelled: label, in: &document, cardSize: cardSize)
        if let index = document.nodes.firstIndex(where: { $0.id == id }) {
            document.nodes[index].extra[CanvasItemPlacement.roleKey] = .string(role)
        }
        return id
    }

    /// One link as the frame holds it: a card, or a frame inside the Links frame holding several.
    public struct Link: Equatable, Sendable {
        public var id: String
        public var label: String?
        public var url: String?
        public var children: [Link]

        public var entry: LinkEntry {
            children.isEmpty
                ? LinkEntry(label: label, url: url)
                : LinkEntry(label: label, children: children.map { LinkEntry(url: $0.url) })
        }
    }

    /// The links in the frame, in the order the board reads them — down and across (`canvasReadingOrder`).
    ///
    /// Only web cards are links. A note dropped into the frame is somebody's note about the links and
    /// stays a note; a frame inside it is a group, as `- Label` over indented lines is in the notes.
    public static func links(of document: CanvasDocument) -> [Link] {
        guard let home = frame(of: document) else { return [] }
        let inside = document.nodes.filter { $0.id != home.id && home.frame.contains(x: $0.frame.midX, y: $0.frame.midY) }
        let groups = inside.filter(\.isGroup)
        func inGroup(_ node: CanvasNode) -> Bool {
            groups.contains { $0.id != node.id && $0.frame.contains(x: node.frame.midX, y: node.frame.midY) }
        }
        func link(_ node: CanvasNode) -> Link? {
            guard case .link(let url) = node.content else { return nil }
            return Link(id: node.id, label: node.extra[labelKey]?.stringValue, url: url, children: [])
        }
        func ordered(_ nodes: [CanvasNode]) -> [CanvasNode] {
            let byID = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            return canvasReadingOrder(nodes.map { ($0.id, $0.frame) }).compactMap { byID[$0] }
        }
        let top = inside.filter { !inGroup($0) && ($0.isGroup || link($0) != nil) }
        return ordered(top).compactMap { node in
            guard node.isGroup else { return link(node) }
            let members = ordered(inside.filter { !$0.isGroup && node.frame.contains(x: $0.frame.midX, y: $0.frame.midY) })
                .compactMap(link)
            return Link(id: node.id, label: canvasFrameLabel(node), url: nil, children: members)
        }
    }

    /// Whether a list has any link in it — a new project's notes carry one blank row.
    public static func hasLinks(_ entries: [LinkEntry]) -> Bool { entries.contains { !isBlank($0) } }

    /// Whether the frame has changed since the notes were last written from it — a card added, taken
    /// out, moved or renamed on the board. Cheap, for asking on every change to a board.
    public static func isAheadOfNotes(_ document: CanvasDocument) -> Bool {
        guard frame(of: document) != nil else { return false }
        return links(of: document).map(\.entry) != mirror(of: document)
    }

    /// The notes file at `notesPath`, as `rawText`, with its `## Links` replaced by `links` and
    /// everything else as it was — or nil when it already says that.
    public static func notes(_ rawText: String, with links: [LinkEntry], notesPath: String) throws -> String? {
        var notes = try parseNotes(markdown: rawText)
        guard notes.links != links else { return nil }
        notes.links = links
        let kind = ProjectKind.of(notesPath: notesPath)
        let out = try writeNotesPreservingFormat(rawText: rawText, incoming: notes, kind: kind)
            ?? serializeNotes(notes, kind: kind)
        // A list that reads back differently but is written the same — a name with a colon in it,
        // which the parser splits and `repaired` joins — is no change, and writing it would be read
        // as one and synced again.
        return out == rawText ? nil : out
    }

    /// `sync`, on the files: a project's notes and its canvas, made if the project has links and no
    /// board. For a writer with no board open to go through — `notes.addLink`, from `pm`, the MCP
    /// server or Raycast, which may run while the app isn't — so a link added there is a card already,
    /// not one waiting for the app to next read the project.
    @discardableResult
    public static func syncFiles(projectPath: String, notesPath: String, io: NotesIO) throws -> Synced? {
        let raw = try io.readContent(path: notesPath)
        let links = try parseNotes(markdown: raw).links
        var canvasPath = try resolveProjectCanvasPath(projectPath: projectPath)
        if canvasPath == nil {
            guard hasLinks(links) else { return nil }
            canvasPath = try createProjectCanvas(projectPath: projectPath, notesPath: notesPath)
        }
        guard let canvasPath else { return nil }
        let url = URL(fileURLWithPath: canvasPath)
        var document = try CanvasDocument.read(contentsOf: url)
        let synced = sync(notes: links, canvas: &document)
        if synced.canvasChanged { try document.write(to: url) }
        if synced.notesChanged, let out = try notes(raw, with: synced.links, notesPath: notesPath) {
            try io.writeContent(path: notesPath, content: out)
        }
        return synced
    }

    /// What `sync` did.
    public struct Synced: Equatable {
        /// The project's links, as the notes should now say them — the frame's, with a blank row for a
        /// project that has none, as a new project's notes carry.
        public var links: [LinkEntry]
        public var canvasChanged: Bool
        /// Whether `links` differs from what the notes said.
        public var notesChanged: Bool
    }

    /// Bring the frame and the notes' `## Links` into one list.
    ///
    /// **Three-way, against the list last written.** The notes and the frame can each have moved since
    /// the last sync — a line typed into the notes in Obsidian, a card added on the board — and neither
    /// alone says which. Compared with what was last written, each change has an author:
    /// - in the notes but not the mirror: added by hand, so a card is made for it;
    /// - in the mirror but gone from the notes: removed by hand, so its card goes;
    /// - on the frame but not the mirror: added on the board, and the notes are told;
    /// - in the mirror but gone from the frame: removed on the board, and the notes are told;
    /// - a name that differs from the mirror's in the notes: renamed by hand, and the card takes it.
    ///
    /// Links are matched by address. The same address twice is one link, which is also what
    /// `ProjectLinks.has` has always said.
    ///
    /// A project with no links and no frame is left without one: a frame is made only when there is
    /// something to put in it.
    public static func sync(notes: [LinkEntry], canvas document: inout CanvasDocument) -> Synced {
        let written = notes.filter { !isBlank($0) }.map(repaired).filter(isLink)
        // Rows that aren't links — a line of prose, an address with no scheme — stay in the notes as they
        // were and never go on the board. The list written back keeps them, after the links.
        let strays = notes.filter { !isBlank($0) }.map(repaired).filter { !isLink($0) }
        let before = document
        guard frame(of: document) != nil || !written.isEmpty else {
            return Synced(links: notes, canvasChanged: false, notesChanged: false)
        }
        let home = frame(in: &document)
        let base = mirror(of: document)

        let inBase = flatten(base)
        let inNotes = flatten(written)
        let onBoard = flatten(links(of: document).map(\.entry))
        var cardFor: [String: String] = [:]
        for link in links(of: document) {
            if let url = link.url { cardFor[url] = cardFor[url] ?? link.id }
            for child in link.children { if let url = child.url { cardFor[url] = cardFor[url] ?? child.id } }
        }

        // Removed by hand: in what was written, gone from the notes, still on the board.
        for url in inBase.keys where inNotes[url] == nil {
            if let id = cardFor[url] { remove(id, from: &document) }
        }
        // Added by hand, in the order the notes have them.
        for (url, row) in flatten(ordered: written) where inBase[url] == nil && onBoard[url] == nil {
            add(url, label: row.label, group: row.group, to: home, in: &document)
        }
        // Renamed by hand — and, for a link that was on both sides before either had been written, the
        // notes' name for a card that has none.
        for (url, row) in inNotes {
            guard let id = cardFor[url], let index = document.nodes.firstIndex(where: { $0.id == id }) else { continue }
            let wanted = name(row.label, for: url)
            let current = name(document.nodes[index].extra[labelKey]?.stringValue, for: url)
            let byHand = inBase[url].map { name($0.label, for: url) != wanted } ?? (current == nil)
            guard byHand, wanted != current else { continue }
            if let wanted { document.nodes[index].extra[labelKey] = .string(wanted) }
            else { document.nodes[index].extra.removeValue(forKey: labelKey) }
        }

        reorderByHand(notes: written, base: base, in: &document)

        let result = links(of: document).map(\.entry)
        setMirror(result, on: home, in: &document)
        let list = result + strays
        return Synced(links: list.isEmpty ? [LinkEntry()] : list,
                      canvasChanged: document != before,
                      notesChanged: comparable(list) != comparable(notes.filter { !isBlank($0) }.map(repaired)))
    }

    /// The notes put the links in a new order and the board didn't: the cards trade places to match.
    ///
    /// **Places, not a new layout.** The cards keep the set of positions they had and are dealt back
    /// into them in the notes' order, so the frame looks as it did with the links moved round in it —
    /// nothing else on the board moves, and a card sized by hand keeps its size. Top-level links only:
    /// a group is one place, and its links are its own.
    private static func reorderByHand(notes: [LinkEntry], base: [LinkEntry], in document: inout CanvasDocument) {
        let top = links(of: document).filter { $0.url != nil }
        let onBoard = top.compactMap(\.url)
        let common = Set(onBoard)
        func order(_ list: [LinkEntry]) -> [String] {
            var seen = Set<String>()
            return list.compactMap(\.url).filter { common.contains($0) && seen.insert($0).inserted }
        }
        let wanted = order(notes)
        guard wanted.count == onBoard.count, wanted != onBoard, order(base) == onBoard else { return }
        let places = top.compactMap { link in document.node(id: link.id)?.frame }
        let idFor = Dictionary(top.map { ($0.url!, $0.id) }, uniquingKeysWith: { first, _ in first })
        for (url, place) in zip(wanted, places) {
            guard let id = idFor[url], let index = document.nodes.firstIndex(where: { $0.id == id }) else { continue }
            document.nodes[index].frame.x = place.x
            document.nodes[index].frame.y = place.y
        }
    }

    // MARK: Pieces

    /// A row the notes' parser split in the wrong place, put back together.
    ///
    /// `- Name: address` is split at the first colon, so a name with a colon in it — a page title such
    /// as "Lain [English Sub] : Internet Archive" — came out as a short name and an "address" holding
    /// the rest of the name and then the address. The address is taken from the last scheme in the row
    /// instead, and everything before it is the name.
    static func repaired(_ entry: LinkEntry) -> LinkEntry {
        guard let url = entry.url, !hasScheme(url),
              let start = ["https://", "http://"].compactMap({ url.range(of: $0, options: .backwards)?.lowerBound }).max()
        else { return entry }
        let rest = url[..<start].trimmingCharacters(in: .whitespaces)
        let tail = rest.hasSuffix(":") ? String(rest.dropLast()).trimmingCharacters(in: .whitespaces) : rest
        let label = [entry.label?.trimmingCharacters(in: .whitespaces), tail]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " : ")
        return LinkEntry(label: label.isEmpty ? nil : label, url: String(url[start...]))
    }

    /// Whether a row is a link the board can hold: an address with a scheme, or a group of them.
    private static func isLink(_ entry: LinkEntry) -> Bool {
        if let children = entry.children, !children.isEmpty { return children.contains { $0.url.map(hasScheme) ?? false } }
        return entry.url.map(hasScheme) ?? false
    }

    private static func hasScheme(_ url: String) -> Bool {
        url.range(of: #"^[a-zA-Z][a-zA-Z0-9+.-]*:"#, options: .regularExpression) != nil
            && !url.contains(" ")
    }

    private struct Row { var label: String?; var group: String? }

    private static func isBlank(_ entry: LinkEntry) -> Bool {
        entry.url == nil && (entry.children ?? []).isEmpty && named(entry.label) == nil
    }

    private static func named(_ label: String?) -> String? {
        guard let label = label?.trimmingCharacters(in: .whitespaces), !label.isEmpty else { return nil }
        return label
    }

    /// A link's name, or nil for none — and none for a name that is only the address again, which is
    /// what `notes.addLink` writes for a link nobody named.
    private static func name(_ label: String?, for url: String) -> String? {
        guard let label = named(label), label != url else { return nil }
        return label
    }

    /// A list as the notes would say it, for asking whether the notes need writing.
    private static func comparable(_ entries: [LinkEntry]) -> [String] {
        entries.filter { !isBlank($0) }.map { entry in
            if let children = entry.children, !children.isEmpty {
                return "group " + (named(entry.label) ?? "") + " " + children.compactMap(\.url).joined(separator: " ")
            }
            return (named(entry.label) ?? "") + " " + (entry.url ?? "")
        }
    }

    private static func flatten(_ entries: [LinkEntry]) -> [String: Row] {
        Dictionary(flatten(ordered: entries), uniquingKeysWith: { first, _ in first })
    }

    private static func flatten(ordered entries: [LinkEntry]) -> [(String, Row)] {
        entries.flatMap { entry -> [(String, Row)] in
            if let children = entry.children, !children.isEmpty {
                return children.compactMap { child in child.url.map { ($0, Row(label: nil, group: entry.label)) } }
            }
            return entry.url.map { [($0, Row(label: entry.label, group: nil))] } ?? []
        }
    }

    private static func mirror(of document: CanvasDocument) -> [LinkEntry] {
        guard let text = frame(of: document)?.extra[mirrorKey]?.stringValue,
              let list = try? JSONDecoder().decode([LinkEntry].self, from: Data(text.utf8)) else { return [] }
        return list
    }

    private static func setMirror(_ list: [LinkEntry], on home: String, in document: inout CanvasDocument) {
        guard let index = document.nodes.firstIndex(where: { $0.id == home }),
              let data = try? JSONEncoder().encode(list),
              let text = String(data: data, encoding: .utf8) else { return }
        if document.nodes[index].extra[mirrorKey]?.stringValue != text {
            document.nodes[index].extra[mirrorKey] = .string(text)
        }
    }

    /// A card for `url`, in the Links frame or in the group frame inside it — made if it isn't there.
    private static func add(_ url: String, label: String?, group: String?, to home: String,
                            in document: inout CanvasDocument) {
        var target = home
        if let group = named(group) {
            let existing = links(of: document).first { $0.url == nil && $0.label == group }
            if let existing { target = existing.id } else {
                let made = CanvasItemPlacement.place(
                    CanvasNode(content: .group(label: group, background: nil, backgroundStyle: nil),
                               frame: CanvasRect(x: 0, y: 0, width: cardSize.width + 40, height: cardSize.height + 60)),
                    to: &document, frame: home)
                target = made.id
            }
        }
        var node = CanvasNode(content: .link(url: url),
                              frame: CanvasRect(x: 0, y: 0, width: cardSize.width, height: cardSize.height))
        if let title = name(label, for: url) { node.extra[labelKey] = .string(title) }
        CanvasItemPlacement.place(node, to: &document, frame: target)
        // A group frame grows to hold its cards; the Links frame has to grow to hold the group, or the
        // group's last card is outside the frame its links are read from.
        if target != home, let group = document.node(id: target)?.frame,
           let index = document.nodes.firstIndex(where: { $0.id == home }) {
            let outer = document.nodes[index].frame
            document.nodes[index].frame.height = max(outer.height, group.maxY + CanvasItemPlacement.gutter - outer.minY)
            document.nodes[index].frame.width = max(outer.width, group.maxX + CanvasItemPlacement.gutter - outer.minX)
        }
    }

    private static func remove(_ id: String, from document: inout CanvasDocument) {
        document.nodes.removeAll { $0.id == id }
        document.edges.removeAll { $0.fromNode == id || $0.toNode == id }
    }
}
