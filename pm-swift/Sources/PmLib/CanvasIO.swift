import Foundation

public enum CanvasError: Error, LocalizedError, Equatable {
    case notJSON
    case notAnObject

    public var errorDescription: String? {
        switch self {
        case .notJSON: return "This file isn't valid JSON, so it can't be read as a canvas."
        case .notAnObject: return "This canvas file's top level isn't an object."
        }
    }
}

// MARK: - Reading

public extension CanvasDocument {
    static func parse(_ data: Data) throws -> CanvasDocument {
        guard let any = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else { throw CanvasError.notJSON }
        guard let fields = JSONValue(json: any).objectValue else { throw CanvasError.notAnObject }
        return CanvasDocument(fields: fields)
    }

    static func read(contentsOf url: URL) throws -> CanvasDocument {
        try parse(try Data(contentsOf: url))
    }

    /// Parse from already-decoded JSON.
    ///
    /// Lenient by design, and it takes some saying why: a canvas is somebody's board, and the failure
    /// PM must never have is "one node this version doesn't understand, so none of it opens". A node
    /// with an unrecognised `type`, or with no `type` at all, is kept whole in `unparsedNodes` and
    /// written back exactly as it came in — invisible in the window, untouched in the file. Same for
    /// edges. Only a file that isn't a JSON object at all is refused, because there is nothing there to
    /// be lenient about.
    init(fields: [String: JSONValue]) {
        let nodeValues = fields["nodes"]?.arrayValue ?? []
        let edgeValues = fields["edges"]?.arrayValue ?? []

        var nodes: [CanvasNode] = []
        var unparsedNodes: [JSONValue] = []
        for value in nodeValues {
            if let node = CanvasNode(json: value) { nodes.append(node) } else { unparsedNodes.append(value) }
        }

        var edges: [CanvasEdge] = []
        var unparsedEdges: [JSONValue] = []
        for value in edgeValues {
            if let edge = CanvasEdge(json: value) { edges.append(edge) } else { unparsedEdges.append(value) }
        }

        var extra = fields
        extra["nodes"] = nil
        extra["edges"] = nil
        if !unparsedNodes.isEmpty { extra[Self.unparsedNodesKey] = .array(unparsedNodes) }
        if !unparsedEdges.isEmpty { extra[Self.unparsedEdgesKey] = .array(unparsedEdges) }

        self.init(nodes: nodes, edges: edges, extra: extra)
    }

    /// Where nodes and edges PM couldn't parse are parked between read and write.
    ///
    /// In `extra` rather than in a field of their own so that every path that already carries `extra`
    /// through — the initialisers, `Equatable`, the writer — carries these too, with nothing to
    /// remember. The `$` prefix is not a key any writer of this format would produce, and the writer
    /// below strips both before serialising, so they never reach the file under these names.
    static var unparsedNodesKey: String { "$pmUnparsedNodes" }
    static var unparsedEdgesKey: String { "$pmUnparsedEdges" }
}

private extension CanvasNode {
    init?(json: JSONValue) {
        guard let fields = json.objectValue, let type = fields["type"]?.stringValue else { return nil }

        let content: CanvasContent
        switch type {
        case "text":
            content = .text(fields["text"]?.stringValue ?? "")
        case "file":
            guard let path = fields["file"]?.stringValue else { return nil }
            content = .file(path: path, subpath: fields["subpath"]?.stringValue)
        case "link":
            guard let url = fields["url"]?.stringValue else { return nil }
            content = .link(url: url)
        case "group":
            content = .group(label: fields["label"]?.stringValue,
                             background: fields["background"]?.stringValue,
                             backgroundStyle: fields["backgroundStyle"]?.stringValue)
        default:
            return nil
        }

        var extra = fields
        for key in ["id", "type", "x", "y", "width", "height", "color",
                    "text", "file", "subpath", "url", "label", "background", "backgroundStyle"] {
            extra[key] = nil
        }

        self.init(id: fields["id"]?.stringValue ?? CanvasID.make(),
                  content: content,
                  frame: CanvasRect(x: fields["x"]?.doubleValue ?? 0,
                                    y: fields["y"]?.doubleValue ?? 0,
                                    // Obsidian's own defaults for a new card, for a node that somehow
                                    // arrived without a size. A zero-sized card can't be clicked, so
                                    // it would be there in the file and gone from the board.
                                    width: fields["width"]?.doubleValue ?? 250,
                                    height: fields["height"]?.doubleValue ?? 60),
                  color: fields["color"].flatMap(canvasColorString),
                  extra: extra)
    }
}

private extension CanvasEdge {
    init?(json: JSONValue) {
        guard let fields = json.objectValue,
              let from = fields["fromNode"]?.stringValue,
              let to = fields["toNode"]?.stringValue
        else { return nil }

        var extra = fields
        for key in ["id", "fromNode", "fromSide", "fromEnd", "toNode", "toSide", "toEnd",
                    "color", "label"] {
            extra[key] = nil
        }

        self.init(id: fields["id"]?.stringValue ?? CanvasID.make(),
                  fromNode: from,
                  fromSide: fields["fromSide"]?.stringValue.flatMap(CanvasSide.init(rawValue:)),
                  fromEnd: fields["fromEnd"]?.stringValue.flatMap(CanvasEnd.init(rawValue:)),
                  toNode: to,
                  toSide: fields["toSide"]?.stringValue.flatMap(CanvasSide.init(rawValue:)),
                  toEnd: fields["toEnd"]?.stringValue.flatMap(CanvasEnd.init(rawValue:)),
                  color: fields["color"].flatMap(canvasColorString),
                  label: fields["label"]?.stringValue,
                  extra: extra)
    }
}

/// A colour as the string the format uses, from whatever the file actually held.
///
/// The spec says a preset is a string (`"4"`), and every file Obsidian writes obeys it — but a canvas
/// hand-edited or written by a script can hold the bare number, and reading `4` as "no colour" would
/// silently repaint somebody's card on the next save.
private func canvasColorString(_ value: JSONValue) -> String? {
    if let s = value.stringValue { return s.isEmpty ? nil : s }
    if let n = value.doubleValue { return canvasNumberText(n) }
    return nil
}

// MARK: - Writing

public extension CanvasDocument {
    /// The file's text, in Obsidian's own shape.
    ///
    /// Keys are placed rather than sorted — `id`, `type`, the payload, then the frame — because that's
    /// the order Obsidian writes and matching it keeps a PM save from rewriting every line of a file it
    /// only moved one card in. Everything in `extra` follows, sorted, so that two saves of the same
    /// document are byte-identical.
    func serialized(format: CanvasFormat = .obsidian) -> String {
        let indent = format == .obsidian ? "\t" : "  "
        let compactRows = format == .obsidian
        let colon = format == .obsidian ? ":" : ": "

        func row(_ pairs: [(String, JSONValue)]) -> String {
            indent + indent + canvasObjectText(pairs, indent: indent, level: 2, compact: compactRows)
        }
        func rawRow(_ value: JSONValue) -> String {
            indent + indent + canvasJSONText(value, indent: indent, level: 2, compact: compactRows)
        }

        var rendered = nodes.map { row($0.pairs) }
        rendered += (extra[Self.unparsedNodesKey]?.arrayValue ?? []).map(rawRow)
        var edgeRows = edges.map { row($0.pairs) }
        edgeRows += (extra[Self.unparsedEdgesKey]?.arrayValue ?? []).map(rawRow)

        func array(_ rows: [String]) -> String {
            rows.isEmpty ? "[]" : "[\n" + rows.joined(separator: ",\n") + "\n" + indent + "]"
        }

        var lines = [indent + "\"nodes\"" + colon + array(rendered),
                     indent + "\"edges\"" + colon + array(edgeRows)]

        var rest = extra
        rest[Self.unparsedNodesKey] = nil
        rest[Self.unparsedEdgesKey] = nil
        for key in rest.keys.sorted() {
            lines.append(indent + canvasStringText(key) + colon
                + canvasJSONText(rest[key]!, indent: indent, level: 1, compact: false))
        }

        return "{\n" + lines.joined(separator: ",\n") + "\n}"
    }

    /// Write the canvas to `url`, atomically.
    ///
    /// Atomically because the file is open in Obsidian at the same time as often as not, and a reader
    /// that catches a half-written canvas doesn't get an error — it gets a board with the bottom half
    /// of its cards missing, and may well write that back.
    func write(to url: URL, format: CanvasFormat = .obsidian) throws {
        try Data(serialized(format: format).utf8).write(to: url, options: .atomic)
    }
}

private extension CanvasNode {
    var pairs: [(String, JSONValue)] {
        var fields: [String: JSONValue] = extra
        fields["id"] = .string(id)
        fields["type"] = .string(content.type)
        switch content {
        case .text(let text):
            fields["text"] = .string(text)
        case .file(let path, let subpath):
            fields["file"] = .string(path)
            if let subpath, !subpath.isEmpty { fields["subpath"] = .string(subpath) }
        case .link(let url):
            fields["url"] = .string(url)
        case .group(let label, let background, let backgroundStyle):
            if let label { fields["label"] = .string(label) }
            if let background { fields["background"] = .string(background) }
            if let backgroundStyle { fields["backgroundStyle"] = .string(backgroundStyle) }
        }
        fields["x"] = .number(frame.x)
        fields["y"] = .number(frame.y)
        fields["width"] = .number(frame.width)
        fields["height"] = .number(frame.height)
        if let color { fields["color"] = .string(color) }
        return canvasOrderedPairs(fields, order: ["id", "type", "text", "file", "subpath", "url",
                                                  "label", "background", "backgroundStyle",
                                                  "x", "y", "width", "height", "color"])
    }
}

private extension CanvasEdge {
    var pairs: [(String, JSONValue)] {
        var fields: [String: JSONValue] = extra
        fields["id"] = .string(id)
        fields["fromNode"] = .string(fromNode)
        if let fromSide { fields["fromSide"] = .string(fromSide.rawValue) }
        if let fromEnd { fields["fromEnd"] = .string(fromEnd.rawValue) }
        fields["toNode"] = .string(toNode)
        if let toSide { fields["toSide"] = .string(toSide.rawValue) }
        if let toEnd { fields["toEnd"] = .string(toEnd.rawValue) }
        if let color { fields["color"] = .string(color) }
        if let label { fields["label"] = .string(label) }
        return canvasOrderedPairs(fields, order: ["id", "fromNode", "fromSide", "fromEnd",
                                                  "toNode", "toSide", "toEnd", "color", "label"])
    }
}
