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
    /// Web pages. See `canvasLinkAddresses`.
    case links([String])
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
        let links = canvasLinkAddresses(on: pasteboard)
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
        case .links(let addresses): return addresses.count
        case .text: return 1
        }
    }

    /// Where each card would go for a drop at `point`, in the order the cards are made.
    ///
    /// **Centred on the point**, which a drag makes non-negotiable: the card is shown under the pointer
    /// on the way in, and a card that then landed with its corner there would have moved the moment you
    /// let go. Several of a kind cascade from the first by 30pt. Copied cards keep the arrangement they
    /// were copied in, moved as one so that the middle of the set is at the point.
    func frames(centredOn point: CanvasPoint) -> [CanvasRect] {
        func cascade(_ count: Int, width: Double, height: (Int) -> Double) -> [CanvasRect] {
            (0..<count).map { index in
                let h = height(index)
                return CanvasRect(x: point.x - width / 2 + Double(index) * 30,
                                  y: point.y - h / 2 + Double(index) * 30,
                                  width: width, height: h)
            }
        }
        switch self {
        case .cards(let document):
            guard let bounds = document.bounds else { return document.nodes.map(\.frame) }
            let dx = point.x - bounds.midX, dy = point.y - bounds.midY
            return document.nodes.map {
                CanvasRect(x: $0.frame.x + dx, y: $0.frame.y + dy, width: $0.frame.width, height: $0.frame.height)
            }
        case .files(let files):
            return cascade(files.count, width: 400) { Self.isTall(files[$0]) ? 400 : 300 }
        case .image:
            return cascade(1, width: 400) { _ in 400 }
        case .links(let addresses):
            return cascade(addresses.count, width: 400) { _ in 400 }
        case .text:
            return cascade(1, width: 250) { _ in 120 }
        }
    }

    /// A picture or a PDF is given a square card, since both are more likely tall than wide and a
    /// short card would show a strip of one.
    static func isTall(_ file: URL) -> Bool {
        isMarkdownImagePath(file.path) || file.pathExtension.lowercased() == "pdf"
    }
}

/// The web pages a pasteboard is carrying, when what it carries is links rather than words — one
/// address per link, in the order they were put down, and empty when it is anything else.
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
func canvasLinkAddresses(on pasteboard: NSPasteboard) -> [String] {
    let addresses = (pasteboard.pasteboardItems ?? [])
        .compactMap { $0.string(forType: .URL)?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter(isWebAddress)
    if !addresses.isEmpty { return addresses }
    if let text = pasteboard.string(forType: .string), let link = soleWebLink(in: text) {
        return [link.address]
    }
    return []
}
