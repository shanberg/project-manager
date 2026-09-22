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

/// The rows of a lens, dragged (docs/items.md D7): which cards they stand for, on a flavour only this
/// app reads.
///
/// **A dragged row is two things at once, and both are needed.** Carried out of the window it is the
/// link, the file or the prose `CanvasItemListView.dragged` writes — that is what a row is worth to
/// Mail, to the Finder, to a text field. Carried to another section of the same board it is not worth
/// anything of the sort: making a second card out of it would be duplicating the card you were trying
/// to move. So the ids ride along beside the public flavours, are read first, and are meaningful only
/// to the document they came out of — see `CanvasBoardView.accept(_:into:)`, which checks that the ids
/// are cards of *this* board before treating a drop as a move. A drag from one project's list onto
/// another's is then a copy, which is what it looks like and what it should be.
enum CanvasItemRows {
    static let pasteboardType = NSPasteboard.PasteboardType("com.stuarthanberg.pm.canvas-item-rows")

    /// Put a row's card on the item it is dragged as. One id per item, because AppKit drags a row as
    /// an item and a multi-row drag is several — no encoding of a list of anything is needed.
    static func write(_ id: String, to item: NSPasteboardItem) {
        item.setString(id, forType: pasteboardType)
    }

    /// The ids on a drag, in the order the rows were dragged, or empty for a drag that carries none.
    static func read(_ pasteboard: NSPasteboard) -> [String] {
        pasteboard.pasteboardItems?.compactMap { $0.string(forType: pasteboardType) } ?? []
    }

    /// What one row or tile is, dragged: its id for this app, and the link, the file or the prose it
    /// is worth to every other one — what the board writes for the same card dragged off a page
    /// (`CanvasBoardView.dragLink`), so an item lands the same wherever it is carried from.
    ///
    /// Nil for a card that has nothing to hand over: a frame, and a file card whose file the vault
    /// cannot find. A drag of nothing is better refused than begun and then dropped as an empty item.
    @MainActor
    static func item(for id: String, in store: CanvasDocumentStore) -> NSPasteboardItem? {
        guard let node = store.document.node(id: id) else { return nil }
        let item = NSPasteboardItem()
        write(id, to: item)
        switch node.content {
        case .link(let url):
            item.setString(url, forType: .URL)
            item.setString(url, forType: .string)
        case .file(let path, _):
            guard let url = store.resolver.resolve(path).url else { return nil }
            item.setString(url.absoluteString, forType: .fileURL)
        case .text(let text):
            item.setString(text, forType: .string)
        case .group:
            return nil
        }
        return item
    }
}
