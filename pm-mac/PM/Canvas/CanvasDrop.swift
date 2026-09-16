import AppKit
import PmLib

/// What a pasteboard would put on a board, read once — and answered the same way for the card a drag
/// shows you on its way in and for the card the drop then makes.
///
/// **One reading for both, which is the point of it being a value.** The preview used to be nothing,
/// so there was nothing for it to disagree with; the moment a drag shows a card before you let go, a
/// second reading of the pasteboard is a second opinion, and the first time the two differ the board
/// has shown you one thing and made another. So the preview asks this, the drop asks this, and a paste
/// asks this too.
///
/// **The order is most-specific first, and it matters at every step:** a copied *image file* has to be
/// caught before the image bytes some apps put down beside it, or the board gets a second copy of a
/// picture already in the vault; a file URL has to be caught before the string form of that URL, or a
/// dragged note becomes a card containing the text `file:///Users/…`; and a link has to be caught
/// before its text, or a link dragged out of a text card becomes a card of its markdown.
enum CanvasDrop {
    /// Cards copied off a board, keeping everything about themselves but their identities.
    case cards(CanvasDocument)
    /// Files, including pictures that already have one.
    case files([URL])
    /// A picture with no file of its own — dragged out of a web page, a screenshot on the clipboard —
    /// which the board writes into the vault when it lands, and not a moment before: a drag that is
    /// only passing over the board must not leave a file behind it.
    case image(data: Data, ext: String)
    /// Web pages. See `canvasLinks`.
    case links([CanvasDroppedLink])
    /// Anything else with words in it.
    case text(String)

    /// Read `pasteboard`, or nil when nothing on it is anything a board can hold. `cardsType` is the
    /// board's own clipping format, passed in so this can be asked without a board.
    static func read(_ pasteboard: NSPasteboard, cardsType: NSPasteboard.PasteboardType) -> CanvasDrop? {
        if let data = pasteboard.data(forType: cardsType), let copied = try? CanvasDocument.parse(data),
           !copied.nodes.isEmpty {
            return .cards(copied)
        }
        if let files = NoteImagePasteboard.imageFiles(on: pasteboard) { return .files(files) }
        if let image = NoteImagePasteboard.imageData(on: pasteboard) {
            return .image(data: image.data, ext: image.ext)
        }
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        if let files = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL],
           !files.isEmpty {
            return .files(files)
        }
        let links = canvasLinks(on: pasteboard)
        if !links.isEmpty { return .links(links) }
        if let text = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            return .text(text)
        }
        return nil
    }

    /// How many cards this makes.
    var count: Int {
        switch self {
        case .cards(let document): return document.nodes.count
        case .files(let files): return files.count
        case .image: return 1
        case .links(let links): return links.count
        case .text: return 1
        }
    }

    /// Where each card would go for a drop at `point`, in the order the cards are made.
    ///
    /// **Centred on the point**, which a drag makes non-negotiable: the card is shown under the pointer
    /// on the way in, and a card that then landed with its corner there would have moved the moment you
    /// let go. Several of a kind are laid out as a block — see `block`. Copied cards keep the
    /// arrangement they were copied in, moved as one so that the middle of the set is at the point.
    func frames(centredOn point: CanvasPoint) -> [CanvasRect] {
        switch self {
        case .cards(let document):
            guard let bounds = document.bounds else { return document.nodes.map(\.frame) }
            let dx = point.x - bounds.midX, dy = point.y - bounds.midY
            return document.nodes.map {
                CanvasRect(x: $0.frame.x + dx, y: $0.frame.y + dy, width: $0.frame.width, height: $0.frame.height)
            }
        case .files(let files):
            return Self.block(files.count, width: 400, centredOn: point) {
                Self.isTall(files[$0]) ? 400 : 300
            }
        case .image:
            return Self.block(1, width: 400, centredOn: point) { _ in 400 }
        case .links(let links):
            return Self.block(links.count, width: 400, centredOn: point) { _ in 400 }
        case .text:
            return Self.block(1, width: 250, centredOn: point) { _ in 120 }
        }
    }

    /// `count` cards of one kind, laid out as a block centred on `point`.
    ///
    /// **They used to cascade, 30pt down and right from the first, and a cascade is a pile.** It is the
    /// right shape for windows, where the one on top is the one you asked for and the rest are
    /// evidence that they are still there. It is the wrong shape for cards: a board's cards are all
    /// equally present, and dropping six files left six cards each obscuring the one behind it and six
    /// drags to do by hand before the drop had told you anything.
    ///
    /// So: reading order across and then down, in the order the files arrived, the whole block centred
    /// on the pointer — which is what `frames` promises for one card and has no reason to stop
    /// promising for six.
    ///
    /// **About as square as the count allows**, and that follows from being centred: a row of six
    /// 400pt cards is 2.5 metres of board, so the pointer would end up in the middle of a line whose
    /// ends are off screen in both directions. `ceil(sqrt(n))` columns gives 2 for a pair, 3 for five,
    /// 4 for a dozen, and keeps the thing you dropped inside the window you dropped it in.
    ///
    /// A 20pt gutter, on the 10pt lattice a drag snaps to, so a block lands agreeing with the grid
    /// rather than two points off it. Rows are pitched by their own tallest card, since a file's card
    /// is 400 tall or 300 depending on what it holds, and a fixed pitch would either overlap them or
    /// leave a gap under every short row.
    ///
    /// A short last row is left-aligned under the others rather than centred: a grid with a centred
    /// last row reads as a pyramid, and these are cards in rows.
    private static func block(_ count: Int, width: Double, centredOn point: CanvasPoint,
                              height: (Int) -> Double) -> [CanvasRect] {
        guard count > 1 else {
            let tall = count == 1 ? height(0) : 0
            return count == 1 ? [CanvasRect(x: point.x - width / 2, y: point.y - tall / 2,
                                            width: width, height: tall)] : []
        }
        let gutter: Double = 20
        let columns = max(1, Int(Double(count).squareRoot().rounded(.up)))
        let heights = (0..<count).map(height)
        let rows = (count + columns - 1) / columns
        /// The tallest card in each row, which is what that row is pitched by.
        let rowHeights = (0..<rows).map { row in
            heights[(row * columns)..<min(count, (row + 1) * columns)].max() ?? 0
        }
        let across = Double(columns) * width + Double(columns - 1) * gutter
        let down = rowHeights.reduce(0, +) + Double(rows - 1) * gutter
        let left = point.x - across / 2
        let top = point.y - down / 2
        return (0..<count).map { index in
            let row = index / columns, column = index % columns
            let above = rowHeights.prefix(row).reduce(0, +) + Double(row) * gutter
            return CanvasRect(x: left + Double(column) * (width + gutter),
                              y: top + above, width: width, height: heights[index])
        }
    }

    /// A picture or a PDF is given a square card, since both are more likely tall than wide and a
    /// short card would show a strip of one. So is a folder, which is a list and wants the rows.
    static func isTall(_ file: URL) -> Bool {
        isMarkdownImagePath(file.path) || file.pathExtension.lowercased() == "pdf"
            || CanvasFolderListing.isFolder(file)
    }
}

/// A link on a pasteboard: where it goes, and what the source called it.
///
/// The name is `public.url-name`, which every browser puts down beside the address and which the board
/// used to read straight past. It is the page's own title, already fetched by the browser you dragged
/// it out of — so a card made from a dropped link can be named the moment it lands rather than staying
/// a globe and a hostname until it has loaded, which on a board of eleven is the difference between a
/// board you can read and a board you have to wait for.
struct CanvasDroppedLink: Equatable {
    var address: String
    var name: String? = nil
}

/// The web pages a pasteboard is carrying, when what it carries is links rather than words — in the
/// order they were put down, and empty when it is anything else.
///
/// **The URL flavour first, then the text.** A browser dragging a link puts it down several ways at
/// once — `public.url`, the link's name, and the address again as plain text — but not every source is
/// that generous, and a pasteboard carrying `public.url` alone used to be accepted by the board and then
/// quietly produce nothing. A link dragged out of a text card is the other way round: its text is the
/// markdown that spells it, `[label](url)`, and the address is only in the URL flavour beside it. Asking
/// the URL first answers both; the text is asked only when there is no URL, which is an address or a
/// markdown link copied as words.
///
/// Per item rather than per pasteboard, because several tabs dragged out of a browser are several items,
/// and the pasteboard's own `string(forType:)` answers for the first of them only.
///
/// File URLs are not links here. The board reads those before it gets to this, as files, and a page is
/// the only thing a link card can show.
func canvasLinks(on pasteboard: NSPasteboard) -> [CanvasDroppedLink] {
    let links = (pasteboard.pasteboardItems ?? []).compactMap { item -> CanvasDroppedLink? in
        guard let address = item.string(forType: .URL)?
            .trimmingCharacters(in: .whitespacesAndNewlines), isWebAddress(address) else { return nil }
        let name = item.string(forType: .urlName)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return CanvasDroppedLink(address: address, name: name?.isEmpty == false ? name : nil)
    }
    if !links.isEmpty { return links }
    // A markdown link copied as words carries its label in the text itself, which `soleWebLink` has
    // already separated out — the one name on this path, and the one the writer chose.
    if let text = pasteboard.string(forType: .string), let link = soleWebLink(in: text) {
        return [CanvasDroppedLink(address: link.address, name: link.label)]
    }
    return []
}
