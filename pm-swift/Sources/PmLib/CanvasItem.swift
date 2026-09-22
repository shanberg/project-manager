import Foundation

/// A card on a board, seen apart from where it sits — the item primitive (docs/items.md D2).
///
/// **One truth, several lenses.** The `.canvas` is the store; a list, a grid and a picker are reads of
/// it (D1). So this is not a stored thing: it is what one node *is*, worked out from the node, and the
/// only fields on it are the ones a lens draws. A card is never named twice — `canvasCardSummary`, a
/// file's name and a view's kind are the same answers the board gives when it is zoomed too far out to
/// read a card, which is what keeps a list and the board from disagreeing about what a card is called.
///
/// **Nothing is rendered to make one.** No page is woken up, no markdown laid out, no picture taken.
/// That is what makes a list of forty items cost nothing where a board of forty cards costs forty
/// renderers, and it is the property to protect when a field is added here.
public struct CanvasItem: Equatable, Sendable, Identifiable {
    /// What the item is, and what stands beside it in a list.
    ///
    /// **The four kinds a node can be**, not the six a menu offers: a folder is a file card with a
    /// folder's symbol (`CanvasFolderCard`), the project's note is a file card pointing at the notes,
    /// and a view is a text node carrying `pmView`. A frame is not an item at all — it is what items
    /// are grouped *by* (D3).
    public enum Kind: Equatable, Sendable {
        /// Markdown typed onto the board.
        case text
        /// A file from the vault — or a folder — as the SF Symbol its card draws zoomed out.
        case file(symbol: String)
        /// A view (docs/views.md), as the symbol of the question it asks: a Today card is a calendar,
        /// not the text card it is stored as.
        case view(symbol: String)
        /// A web page, which the site's icon stands for when the app has one.
        case page(host: String)

        /// Kinds together, for the sort that groups them (`CanvasItemSort.kind`). An order, not a
        /// ranking — what it is for is putting the pages next to the pages.
        var rank: Int {
            switch self {
            case .text: return 0
            case .file: return 1
            case .page: return 2
            case .view: return 3
            }
        }
    }

    /// The node's id, which is what every lens hands back when you act on a row.
    public var id: String
    /// The one line that stands for the card. Clipped to `longestTitle`.
    public var title: String
    public var kind: Kind
    /// The second line, where a lens has room for one: a page's host, a file's folder. Nil when it
    /// would only repeat the title, which is the common case for a page named after its site.
    public var detail: String?
    /// The id of the frame it sits in, or nil for a card loose on the board. Set by `CanvasItems`,
    /// which is the only thing that knows the rest of the document.
    public var frame: String?
    /// Where it is. Not shown and not sortable except as reading order (D10) — it is here because the
    /// lenses that place things (a drag onto the board, Tidy) need it.
    public var rect: CanvasRect

    /// What one card is, or nil for a frame.
    ///
    /// `lookups` is the app's knowledge: what the disk says is a folder, what page titles have been
    /// seen, what a view card calls itself once its settings are read. Every one of them has a
    /// truthful answer without the app (`CanvasItemLookups.plain`), which is what lets `card.list`
    /// describe a board from the command line.
    public static func of(_ node: CanvasNode, lookups: CanvasItemLookups = .plain) -> CanvasItem? {
        // Before the text case: a view is stored as a text node, and its own name and symbol are what
        // it is called everywhere else.
        if let kind = CanvasViewKind.of(node) {
            return CanvasItem(id: node.id, title: clipped(lookups.viewTitle(node) ?? kind.title),
                              kind: .view(symbol: kind.symbol), rect: node.frame)
        }
        switch node.content {
        case .text(let text):
            let summary = canvasCardSummary(text)
            return CanvasItem(id: node.id, title: summary.isEmpty ? "Empty Card" : clipped(summary),
                              kind: .text, rect: node.frame)
        case .file(let path, let subpath):
            // The heading after the name, the way the card describes itself — two cards on one note
            // are told apart by nothing else.
            let folder = lookups.isFolder(path)
            var name = canvasFileCardName(path, isFolder: folder)
            if let heading = subpath?.trimmingCharacters(in: CharacterSet(charactersIn: "#")),
               !heading.isEmpty {
                name += " \u{00B7} " + heading
            }
            let parent = (path as NSString).deletingLastPathComponent
            return CanvasItem(id: node.id, title: clipped(name),
                              kind: .file(symbol: canvasFileSymbol(path, isFolder: folder)),
                              detail: parent.isEmpty ? nil : parent, rect: node.frame)
        case .link(let url):
            // The page's own name when one has ever been seen, else whose page it is — the same two
            // lines the card shows, the first of them when it has it. See `CanvasPageTitles`.
            let host = URL(string: url)?.host() ?? url
            let title = lookups.pageTitle(url) ?? host
            return CanvasItem(id: node.id, title: clipped(title), kind: .page(host: host),
                              detail: title == host ? nil : host, rect: node.frame)
        case .group:
            return nil
        }
    }

    /// Longest a title gets before it is cut. A menu is as wide as its widest item, and one card whose
    /// first line is a paragraph would otherwise make every other name sit in a menu half a screen wide.
    public static let longestTitle = 60

    private static func clipped(_ name: String) -> String {
        guard name.count > longestTitle else { return name }
        return name.prefix(longestTitle - 1).trimmingCharacters(in: .whitespaces) + "\u{2026}"
    }
}

/// What only the running app knows about a card, asked rather than assumed.
///
/// Three questions a document can't answer: whether a stored path is a folder (the disk), what a page
/// is called (titles the app has seen and remembered), and what a view card names itself once its
/// period and projects are read (`CanvasViewSpec`, which is the app's). Each has an honest answer
/// without an app — a file, the host, the kind's own name — so a lens that has no app still describes
/// every card, just with less to say about three of them.
public struct CanvasItemLookups {
    public var isFolder: (String) -> Bool
    public var pageTitle: (String) -> String?
    public var viewTitle: (CanvasNode) -> String?

    public init(isFolder: @escaping (String) -> Bool = { _ in false },
                pageTitle: @escaping (String) -> String? = { _ in nil },
                viewTitle: @escaping (CanvasNode) -> String? = { _ in nil }) {
        self.isFolder = isFolder
        self.pageTitle = pageTitle
        self.viewTitle = viewTitle
    }

    /// Nobody to ask. What `pm` and a test get.
    public static let plain = CanvasItemLookups()
}

/// The items of one frame, or of the board itself (D3).
public struct CanvasItemSection: Equatable, Sendable {
    /// The id of the frame these items sit in, or nil for the ones loose on the board.
    public var frame: String?
    /// What that frame is called, `nil` alongside a `nil` frame. A frame with no label of its own is
    /// called "Frame", because a section header has to say something.
    public var label: String?
    public var items: [CanvasItem]

    public init(frame: String? = nil, label: String? = nil, items: [CanvasItem]) {
        self.frame = frame
        self.label = label
        self.items = items
    }
}

/// What orders a list of items (docs/items.md D4).
///
/// **A sort, never an arrangement.** Dragging a row does not reorder anything: two cards would be
/// first, one on the board and one in the list, and nothing reconciles them. Arranging is the board's
/// job, and reading order is how a list borrows the arrangement it already made.
public enum CanvasItemSort: String, CaseIterable, Codable, Sendable {
    /// Down and across the board, as the cards actually sit on it — `canvasReadingOrder`.
    case reading
    /// The order the nodes sit in the file, which is insertion order near enough, and therefore the
    /// newest last. **Named for what it is rather than for what it is usually right about**: Obsidian
    /// appends and so does PM, but a file rewritten by hand owes nobody an insertion order.
    case file
    /// By title, case- and diacritic-insensitively.
    case name
    /// Pages together, files together, views together; by title within each.
    case kind

    public var title: String {
        switch self {
        case .reading: return "Reading Order"
        case .file: return "File Order"
        case .name: return "Name"
        case .kind: return "Kind"
        }
    }
}

/// Reading a document as items: grouped into sections, ordered by a sort.
public enum CanvasItems {
    /// Every item on the board, grouped by frame (D3) and ordered by `sort` within each group.
    ///
    /// A frame is never an item: it is a container of cards rather than a card, so there is no tile it
    /// could be and no row it could be — see `CanvasBoardView.addToTiling` and D3.
    ///
    /// - Parameters:
    ///   - showing: ids to leave out, which is what makes this Add Card from Canvas as well as a lens:
    ///     a picker offers the cards a tiled view isn't already showing.
    ///   - first: an id to lead the list whatever frame it sits in — the project's note, which is the
    ///     card most often meant when there is a tile to fill (canvas-backlog 8).
    public static func sections(of document: CanvasDocument,
                                showing: [String] = [],
                                first: String? = nil,
                                sort: CanvasItemSort = .reading,
                                lookups: CanvasItemLookups = .plain) -> [CanvasItemSection] {
        let hidden = Set(showing)
        let candidates = document.nodes.filter { !$0.isGroup && !hidden.contains($0.id) }
        guard !candidates.isEmpty else { return [] }

        // The smallest frame a card's centre is in, so a card in a frame inside a frame is listed under
        // the inner one — the name nearest to it. By centre for the reason `canvasCardsInside` gives.
        let frames = document.nodes.filter(\.isGroup)
        var byFrame: [String?: [CanvasNode]] = [:]
        for node in candidates {
            let home = frames
                .filter { $0.frame.contains(x: node.frame.midX, y: node.frame.midY) }
                .min { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
            byFrame[home?.id, default: []].append(node)
        }

        let position = Dictionary(uniqueKeysWithValues: document.nodes.enumerated().map { ($1.id, $0) })
        func ordered(_ nodes: [CanvasNode], in frame: String?) -> [CanvasItem] {
            let items = nodes.compactMap { node -> CanvasItem? in
                guard var item = CanvasItem.of(node, lookups: lookups) else { return nil }
                item.frame = frame
                return item
            }
            return sorted(items, by: sort, position: position)
        }

        var sections: [CanvasItemSection] = []
        let lead = candidates.first { $0.id == first }.flatMap { CanvasItem.of($0, lookups: lookups) }
        if lead != nil {
            for key in Array(byFrame.keys) { byFrame[key]?.removeAll { $0.id == first } }
            if byFrame[nil] == nil { byFrame[nil] = [] }
        }
        if let loose = byFrame[nil] {
            sections.append(CanvasItemSection(items: (lead.map { [$0] } ?? []) + ordered(loose, in: nil)))
        }
        let framesByID = Dictionary(uniqueKeysWithValues: frames.map { ($0.id, $0) })
        for id in canvasReadingOrder(frames.map { ($0.id, $0.frame) }) {
            guard let nodes = byFrame[id], !nodes.isEmpty, let frame = framesByID[id] else { continue }
            sections.append(CanvasItemSection(frame: id, label: canvasFrameLabel(frame),
                                              items: ordered(nodes, in: id)))
        }
        return sections
    }

    /// Every item on the board in one run, ungrouped — what `card.list` answers and what a lens draws
    /// when it is showing one frame rather than the board.
    public static func all(of document: CanvasDocument,
                           sort: CanvasItemSort = .reading,
                           lookups: CanvasItemLookups = .plain) -> [CanvasItem] {
        sections(of: document, sort: sort, lookups: lookups).flatMap(\.items)
    }

    private static func sorted(_ items: [CanvasItem], by sort: CanvasItemSort,
                               position: [String: Int]) -> [CanvasItem] {
        switch sort {
        case .reading:
            let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
            return canvasReadingOrder(items.map { ($0.id, $0.rect) }).compactMap { byID[$0] }
        case .file:
            return items.sorted { position[$0.id, default: 0] < position[$1.id, default: 0] }
        case .name:
            return items.sorted { byTitle($0, $1) }
        case .kind:
            return items.sorted {
                $0.kind.rank == $1.kind.rank ? byTitle($0, $1) : $0.kind.rank < $1.kind.rank
            }
        }
    }

    /// Ties broken by id, so a board with two cards called the same thing doesn't reshuffle them
    /// between reads — a list that changes order when nothing changed is a list you can't trust.
    private static func byTitle(_ a: CanvasItem, _ b: CanvasItem) -> Bool {
        let order = a.title.compare(b.title, options: [.caseInsensitive, .diacriticInsensitive])
        return order == .orderedSame ? a.id < b.id : order == .orderedAscending
    }
}

/// What a frame is called in a list. A frame with no label of its own is "Frame": a section header has
/// to say something, and the board draws an unlabelled frame as an empty band for the same reason.
public func canvasFrameLabel(_ frame: CanvasNode) -> String {
    guard case .group(let label, _, _) = frame.content,
          let label = label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty
    else { return "Frame" }
    return label
}
