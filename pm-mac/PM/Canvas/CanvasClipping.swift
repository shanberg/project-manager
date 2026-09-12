import AppKit
import PmLib

/// What leaves a board when you copy, and in what form.
///
/// Lifted out of `CanvasBoardView+Commands` because none of it is about a view. Both rules below are
/// decisions about a document and a set of ids, and both have a wrong answer that is invisible until
/// somebody pastes: an edge with one end missing, or a clipping that arrives in a text editor as
/// nothing at all. A value type is something those can be asserted about — see `CanvasClippingTests`.
enum CanvasClipping {

    /// The private flavour, carrying a whole canvas so a paste back into PM is lossless.
    static let pasteboardType = NSPasteboard.PasteboardType("com.stuarthanberg.pm.canvas-nodes")

    /// The cards, as a canvas of their own.
    ///
    /// Lines are carried only when **both** ends were copied. A line to a card you didn't copy has
    /// nowhere to land on paste, and the format has no way to express one — so it is dropped here
    /// rather than pasted as a dangling edge that nothing will ever draw.
    static func clipping(of ids: Set<String>, from document: CanvasDocument) -> CanvasDocument {
        CanvasDocument(nodes: document.nodes.filter { ids.contains($0.id) },
                       edges: document.edges.filter {
                           ids.contains($0.fromNode) && ids.contains($0.toNode)
                       })
    }

    /// What a card is worth outside a canvas: its prose, its address, its path.
    ///
    /// Empty cards are dropped rather than pasted as blank lines — a frame with no label carries
    /// nothing, and three of them would arrive somewhere else as six newlines.
    static func plainText(of ids: Set<String>, from document: CanvasDocument) -> String {
        document.nodes.filter { ids.contains($0.id) }.map { node in
            switch node.content {
            case .text(let text): return text
            case .link(let url): return url
            case .file(let path, let subpath): return path + (subpath ?? "")
            case .group(let label, _, _): return label ?? ""
            }
        }
        .filter { !$0.isEmpty }
        .joined(separator: "\n\n")
    }

    /// Both flavours, together. Anything that can read a canvas gets the canvas; everything else gets
    /// the prose, which is why a card copied out of PM lands as words in a mail message.
    static func write(_ ids: Set<String>, from document: CanvasDocument, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        pasteboard.setData(Data(clipping(of: ids, from: document).serialized().utf8),
                           forType: pasteboardType)
        pasteboard.setString(plainText(of: ids, from: document), forType: .string)
    }
}
