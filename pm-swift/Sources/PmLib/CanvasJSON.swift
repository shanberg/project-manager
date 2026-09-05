import Foundation

/// Bridging `JSONSerialization` output into `JSONValue`, for reading a canvas file.
///
/// `JSONValue` already round-trips through `Codable` — that is how the API layer, which it was written
/// for, uses it. A canvas can't take that route: the whole point of reading one is to keep the keys PM
/// has no field for, and a `Codable` decode of a fixed shape is precisely the thing that drops them.
/// So a canvas is parsed generically, and this is what turns the `Any` that comes back into a value
/// that is `Equatable` (so a round-trip can be asserted) and `Sendable` (so a document can be handed
/// between actors).
public extension JSONValue {
    /// Wrap what `JSONSerialization` produced.
    ///
    /// The `CFBoolean` check is the whole reason this isn't a one-line switch. `JSONSerialization`
    /// represents `true` as an `NSNumber` that is also `1`, so asking "is this a number?" first would
    /// turn every boolean in the file into a number, and `"isStartNode":true` would come back out as
    /// `"isStartNode":1`. Obsidian would read that as truthy and nothing would visibly break — which is
    /// exactly why it has to be caught here rather than noticed later.
    init(json: Any) {
        switch json {
        case is NSNull:
            self = .null
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else {
                self = .number(number.doubleValue)
            }
        case let string as String:
            self = .string(string)
        case let array as [Any]:
            self = .array(array.map(JSONValue.init(json:)))
        case let object as [String: Any]:
            self = .object(object.mapValues(JSONValue.init(json:)))
        default:
            // Not reachable from `JSONSerialization` output, which only ever produces the five kinds
            // above. Null rather than a trap: a canvas that somehow held something else should open.
            self = .null
        }
    }
}

// MARK: - Writing

/// How a canvas file is laid out on disk.
///
/// Obsidian's own writer indents with tabs and puts each node and each edge on a single line as
/// compact JSON — a shape that makes a canvas readable in a diff, because moving one card changes one
/// line. That is worth matching exactly, and `.obsidian` does.
///
/// It is only worth matching *approximately*, though, because there is no one format: of the canvases
/// in a real vault, some are Obsidian's tabs-and-one-line-per-node, some are fully expanded with the
/// keys in a different order, and some are two-space-indented with every key sorted alphabetically —
/// three different writers, all of which Obsidian opens without complaint. So PM writes the native
/// shape and lets a file written by something else normalise on its first save, rather than trying to
/// reproduce a format it can't reliably detect.
public enum CanvasFormat: Sendable {
    /// Tabs; `"nodes":[` with one node per line. What Obsidian writes.
    case obsidian
    /// Two spaces, every value on its own line. For a test that wants to read the output.
    case expanded
}

/// Render `value` as JSON text.
///
/// Hand-rolled rather than `JSONSerialization.WritingOptions.prettyPrinted`, which indents with two
/// spaces, expands every array onto its own lines, and offers no way to say "this array's elements go
/// one per line, compact". That last one is the entire point of the format, so the writer has to be
/// ours. Key order is `sortedKeys` for everything PM doesn't place explicitly, so a file PM writes
/// twice from the same document is byte-identical both times.
func canvasJSONText(_ value: JSONValue, indent: String, level: Int, compact: Bool) -> String {
    let pad = compact ? "" : String(repeating: indent, count: level)
    let childPad = compact ? "" : String(repeating: indent, count: level + 1)
    let newline = compact ? "" : "\n"
    let colon = compact ? ":" : ": "

    switch value {
    case .null: return "null"
    case .bool(let b): return b ? "true" : "false"
    case .number(let n): return canvasNumberText(n)
    case .string(let s): return canvasStringText(s)
    case .array(let items):
        if items.isEmpty { return "[]" }
        let body = items
            .map { childPad + canvasJSONText($0, indent: indent, level: level + 1, compact: compact) }
            .joined(separator: "," + newline)
        return "[" + newline + body + newline + pad + "]"
    case .object(let fields):
        if fields.isEmpty { return "{}" }
        let body = fields.keys.sorted()
            .map { key in
                childPad + canvasStringText(key) + colon
                    + canvasJSONText(fields[key]!, indent: indent, level: level + 1, compact: compact)
            }
            .joined(separator: "," + newline)
        return "{" + newline + body + newline + pad + "}"
    }
}

/// A number as JSON, integral when it can be.
///
/// Canvas coordinates are whole numbers and are written as whole numbers; a `sideRatio` is not. Going
/// through `Double` for both means the integral ones have to be recognised on the way out, or every
/// coordinate in the file gains a `.0` the first time PM saves it. The 2^53 bound is where `Double`
/// stops being able to tell consecutive integers apart — past it, "is this integral?" isn't a question
/// with a useful answer, so the plain description is the honest output.
func canvasNumberText(_ n: Double) -> String {
    guard n.isFinite else { return "0" }
    if n == n.rounded(), abs(n) < 9_007_199_254_740_992 {
        return String(Int64(n))
    }
    return String(n)
}

/// A string as a JSON string literal.
///
/// The escapes JSON requires, and no more. Notably *not* escaping non-ASCII: canvas text is people's
/// prose, and a note with an em dash or an emoji in it should read as itself in the file, the way
/// Obsidian writes it. Control characters below 0x20 have no literal form and go out as `\u00xx`.
func canvasStringText(_ s: String) -> String {
    var out = "\""
    out.reserveCapacity(s.utf8.count + 2)
    for scalar in s.unicodeScalars {
        switch scalar {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        case "\u{08}": out += "\\b"
        case "\u{0C}": out += "\\f"
        default:
            if scalar.value < 0x20 {
                out += String(format: "\\u%04x", scalar.value)
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
    }
    return out + "\""
}

/// An object whose keys go out in a chosen order rather than sorted.
///
/// `JSONValue.object` is a dictionary and a dictionary has no order, so the generic writer sorts — the
/// only way to make repeated writes of one document identical. A node is the exception: Obsidian
/// writes `id`, `type`, the payload, then the frame, and a PM save that re-sorted those into
/// `color, file, height, id…` would rewrite every line of a file it had only moved one card in.
///
/// So nodes and edges are rendered from an ordered list of pairs instead. Keys the caller didn't place
/// follow, sorted, which is what carries a plugin's `styleAttributes` through in a stable position.
func canvasObjectText(_ pairs: [(String, JSONValue)],
                      indent: String,
                      level: Int,
                      compact: Bool) -> String {
    if pairs.isEmpty { return "{}" }
    let pad = compact ? "" : String(repeating: indent, count: level)
    let childPad = compact ? "" : String(repeating: indent, count: level + 1)
    let newline = compact ? "" : "\n"
    let colon = compact ? ":" : ": "

    let body = pairs
        .map { key, value in
            childPad + canvasStringText(key) + colon
                + canvasJSONText(value, indent: indent, level: level + 1, compact: compact)
        }
        .joined(separator: "," + newline)
    return "{" + newline + body + newline + pad + "}"
}

/// `fields` as pairs: the keys named in `order` first and in that order, then everything else sorted.
func canvasOrderedPairs(_ fields: [String: JSONValue], order: [String]) -> [(String, JSONValue)] {
    var pairs: [(String, JSONValue)] = []
    var remaining = fields
    for key in order {
        if let value = remaining.removeValue(forKey: key) { pairs.append((key, value)) }
    }
    for key in remaining.keys.sorted() { pairs.append((key, remaining[key]!)) }
    return pairs
}
