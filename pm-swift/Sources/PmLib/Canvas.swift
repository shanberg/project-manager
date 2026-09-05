import Foundation

/// An Obsidian canvas: cards laid out on an infinite plane, and the lines between them.
///
/// The file is JSON — the [JSON Canvas](https://jsoncanvas.org) format Obsidian opened up — holding a
/// list of nodes and a list of edges. A node is one of four things: a piece of markdown typed straight
/// onto the board, a file from the vault shown in place, a web page clipped as a card, or a labelled
/// frame drawn around a group of the others. An edge joins two nodes, optionally naming which side of
/// each it leaves and arrives at.
///
/// **The model is deliberately partial.** It types the fields PM draws and edits and keeps everything
/// else verbatim in `extra`, because a `.canvas` in a real vault is written by more than one program:
/// Advanced Canvas puts a `styleAttributes` object on every node and edge, the slides plugin puts
/// `sideRatio` and `isStartNode` on groups, and Obsidian's own `metadata` block is versioned and will
/// grow. PM has to be able to save a file those have touched without being the thing that erased them.
/// `JSONValue` is what makes that possible; the round-trip is asserted in `CanvasTests`.
public struct CanvasDocument: Equatable, Sendable {
    public var nodes: [CanvasNode]
    public var edges: [CanvasEdge]
    /// Top-level keys that aren't `nodes` or `edges` — `metadata`, today — carried through untouched.
    public var extra: [String: JSONValue]

    public init(nodes: [CanvasNode] = [], edges: [CanvasEdge] = [], extra: [String: JSONValue] = [:]) {
        self.nodes = nodes
        self.edges = edges
        self.extra = extra
    }

    public func node(id: String) -> CanvasNode? { nodes.first { $0.id == id } }

    /// The rectangle every node sits inside, or nil when the canvas is empty.
    ///
    /// What a freshly-opened window zooms to fit. Groups are included rather than skipped: a group is
    /// usually the largest thing on the board and drawn deliberately around the others, so leaving it
    /// out would frame a view that cuts its own label off.
    public var bounds: CanvasRect? {
        guard var box = nodes.first?.frame else { return nil }
        for node in nodes.dropFirst() { box = box.union(node.frame) }
        return box
    }
}

// MARK: - Geometry

/// A rectangle in canvas coordinates: y grows downward, as it does in the file and in Obsidian.
///
/// Its own type rather than `CGRect` because `PmLib` is the domain layer and doesn't link CoreGraphics
/// — and because canvas space is not view space. The view layer flips and scales into its own
/// coordinates; keeping the two apart is what stops a zoom factor from leaking into a saved file.
public struct CanvasRect: Equatable, Sendable {
    public var x: Double, y: Double, width: Double, height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }

    public var minX: Double { min(x, x + width) }
    public var minY: Double { min(y, y + height) }
    public var maxX: Double { max(x, x + width) }
    public var maxY: Double { max(y, y + height) }
    public var midX: Double { (minX + maxX) / 2 }
    public var midY: Double { (minY + maxY) / 2 }

    public func contains(x px: Double, y py: Double) -> Bool {
        px >= minX && px <= maxX && py >= minY && py <= maxY
    }

    public func intersects(_ other: CanvasRect) -> Bool {
        minX < other.maxX && maxX > other.minX && minY < other.maxY && maxY > other.minY
    }

    /// True when `other` lies wholly inside this rectangle — how a group decides which nodes it owns.
    /// Obsidian's rule too: a card half in and half out of a frame is not in the group.
    public func contains(_ other: CanvasRect) -> Bool {
        other.minX >= minX && other.maxX <= maxX && other.minY >= minY && other.maxY <= maxY
    }

    public func union(_ other: CanvasRect) -> CanvasRect {
        let x0 = min(minX, other.minX), y0 = min(minY, other.minY)
        return CanvasRect(x: x0, y: y0,
                          width: max(maxX, other.maxX) - x0,
                          height: max(maxY, other.maxY) - y0)
    }

    public func inset(by d: Double) -> CanvasRect {
        CanvasRect(x: minX - d, y: minY - d, width: width + 2 * d, height: height + 2 * d)
    }
}

/// Which edge of a card a line leaves from or arrives at.
public enum CanvasSide: String, Equatable, Sendable, CaseIterable {
    case top, right, bottom, left

    public var opposite: CanvasSide {
        switch self {
        case .top: return .bottom
        case .bottom: return .top
        case .left: return .right
        case .right: return .left
        }
    }
}

/// What a line has drawn at one of its ends.
public enum CanvasEnd: String, Equatable, Sendable {
    case none, arrow
}

// MARK: - Nodes

/// The four kinds of card, and what each one carries.
///
/// An enum rather than four optional fields on one struct, so that a link node cannot be holding
/// markdown and a text node cannot be holding a file path. The editor moves and resizes nodes without
/// caring which kind they are, and that generic half lives on `CanvasNode`; everything type-specific
/// is in here and has to be matched on.
public enum CanvasContent: Equatable, Sendable {
    /// Markdown typed onto the board.
    case text(String)
    /// A file from the vault, shown in place. The path is vault-root-relative as Obsidian writes it —
    /// which is exactly why it so often doesn't resolve; see `CanvasFileResolver`. `subpath` is the
    /// `#Heading` or `#^block` of the file to show rather than the whole thing.
    case file(path: String, subpath: String?)
    /// A web page, embedded live.
    case link(url: String)
    /// A labelled frame drawn behind the cards inside it.
    case group(label: String?, background: String?, backgroundStyle: String?)

    public var type: String {
        switch self {
        case .text: return "text"
        case .file: return "file"
        case .link: return "link"
        case .group: return "group"
        }
    }
}

public struct CanvasNode: Equatable, Sendable, Identifiable {
    public var id: String
    public var content: CanvasContent
    public var frame: CanvasRect
    /// Obsidian's preset `"1"`…`"6"`, or a `"#rrggbb"` hex. Nil is the theme's default card colour.
    public var color: String?
    /// Every other key on this node, verbatim. See `CanvasDocument`.
    public var extra: [String: JSONValue]

    public init(id: String = CanvasID.make(),
                content: CanvasContent,
                frame: CanvasRect,
                color: String? = nil,
                extra: [String: JSONValue] = [:]) {
        self.id = id
        self.content = content
        self.frame = frame
        self.color = color
        self.extra = extra
    }

    public var isGroup: Bool { if case .group = content { return true }; return false }

    /// The point a line touching `side` of this card should meet.
    public func anchor(_ side: CanvasSide) -> (x: Double, y: Double) {
        switch side {
        case .top: return (frame.midX, frame.minY)
        case .bottom: return (frame.midX, frame.maxY)
        case .left: return (frame.minX, frame.midY)
        case .right: return (frame.maxX, frame.midY)
        }
    }
}

// MARK: - Edges

public struct CanvasEdge: Equatable, Sendable, Identifiable {
    public var id: String
    public var fromNode: String
    public var fromSide: CanvasSide?
    public var fromEnd: CanvasEnd?
    public var toNode: String
    public var toSide: CanvasSide?
    public var toEnd: CanvasEnd?
    public var color: String?
    public var label: String?
    public var extra: [String: JSONValue]

    public init(id: String = CanvasID.make(),
                fromNode: String,
                fromSide: CanvasSide? = nil,
                fromEnd: CanvasEnd? = nil,
                toNode: String,
                toSide: CanvasSide? = nil,
                toEnd: CanvasEnd? = nil,
                color: String? = nil,
                label: String? = nil,
                extra: [String: JSONValue] = [:]) {
        self.id = id
        self.fromNode = fromNode; self.fromSide = fromSide; self.fromEnd = fromEnd
        self.toNode = toNode; self.toSide = toSide; self.toEnd = toEnd
        self.color = color; self.label = label; self.extra = extra
    }

    /// What the file means when it doesn't say: a line starts plain and ends in an arrowhead. Written
    /// out only when it differs, so PM saving an untouched file doesn't add keys Obsidian omitted.
    public var resolvedFromEnd: CanvasEnd { fromEnd ?? .none }
    public var resolvedToEnd: CanvasEnd { toEnd ?? .arrow }
}

// MARK: - Identity

public enum CanvasID {
    /// A new node or edge id, in the shape Obsidian uses: 16 lowercase hex characters.
    ///
    /// Matching the shape matters less than being unique, but it costs nothing and it keeps a file PM
    /// added to from being visibly sorted into "ours" and "theirs" when read in a diff.
    public static func make() -> String {
        let hex = "0123456789abcdef"
        return String((0..<16).map { _ in hex.randomElement()! })
    }
}
