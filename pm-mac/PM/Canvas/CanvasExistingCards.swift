import Foundation
import PmLib

/// The cards on a board that the tiled view in front of you isn't showing — what Add Card from Canvas
/// offers.
///
/// **A list, not pictures.** A card's own face is the most informative thing about it, and the board
/// already draws every one of them; the only thing a picker adds is a way to name one without leaving
/// the workspace. So this names them the way the board does when it is zoomed too far out to read —
/// the one line that stands for a card (`canvasCardSummary`), a file's name, a page's remembered title
/// — beside the icon the card itself would draw at that size. Nothing is rendered, and no page is
/// woken up to have its picture taken.
///
/// **Grouped by frame, in reading order.** Where a card sits is the one thing the board knows that a
/// flat list throws away, and the frames are the part of that which has names. A card in no frame
/// comes first, under no header; each frame follows under its own label, in the order the frames sit
/// on the board. Within a group it is `CanvasTiling.order`, which is also the order the tiles
/// themselves were laid in.
enum CanvasExistingCards {
    /// One name for the command in every place it is offered — the tile's menu, the board's, the `+`
    /// menu and the View menu — for the reason `CanvasAddCommand` gives.
    static let title = "Add Card from Canvas"

    struct Card: Equatable {
        enum Kind: Equatable {
            case text
            /// A file from the vault, as the SF Symbol its card draws zoomed out.
            case file(symbol: String)
            /// A web page, which the site's icon stands for when the app has one.
            case page(host: String)
        }

        var id: String
        var name: String
        var kind: Kind
    }

    struct Section: Equatable {
        /// The label of the frame these cards sit in, or nil for the ones loose on the board.
        var frame: String?
        var cards: [Card]
    }

    /// The cards not in `shown`, grouped and ordered for a menu. Empty when every card is showing.
    ///
    /// A frame is never offered: it is a container of cards rather than a card, so there is no tile
    /// it could be — see `CanvasBoardView.addToTiling`.
    static func sections(of document: CanvasDocument, showing shown: [String]) -> [Section] {
        let showing = Set(shown)
        let candidates = document.nodes.filter { !$0.isGroup && !showing.contains($0.id) }
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

        var sections: [Section] = []
        if let loose = byFrame[nil] {
            sections.append(Section(frame: nil, cards: ordered(loose)))
        }
        let framesByID = Dictionary(uniqueKeysWithValues: frames.map { ($0.id, $0) })
        for id in CanvasTiling.order(frames.map { ($0.id, $0.frame) }) {
            guard let nodes = byFrame[id], let frame = framesByID[id] else { continue }
            sections.append(Section(frame: label(of: frame), cards: ordered(nodes)))
        }
        return sections
    }

    private static func ordered(_ nodes: [CanvasNode]) -> [Card] {
        let byID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        return CanvasTiling.order(nodes.map { ($0.id, $0.frame) }).compactMap { byID[$0].flatMap(card) }
    }

    private static func label(of frame: CanvasNode) -> String {
        guard case .group(let label, _, _) = frame.content,
              let label = label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty
        else { return "Frame" }
        return label
    }

    /// What one card is called in the list, and what stands beside it.
    static func card(_ node: CanvasNode) -> Card? {
        switch node.content {
        case .text(let text):
            let summary = canvasCardSummary(text)
            return Card(id: node.id, name: summary.isEmpty ? "Empty Card" : clipped(summary), kind: .text)
        case .file(let path, let subpath):
            // The heading after the name, the way the card describes itself — two cards on one note
            // are told apart by nothing else.
            var name = canvasFileCardName(path)
            if let heading = subpath?.trimmingCharacters(in: CharacterSet(charactersIn: "#")),
               !heading.isEmpty {
                name += " \u{00B7} " + heading
            }
            return Card(id: node.id, name: clipped(name), kind: .file(symbol: canvasFileSymbol(path)))
        case .link(let url):
            // The page's own name when one has ever been seen, else whose page it is — the same two
            // lines the card shows, the first of them when it has it. See `CanvasPageTitles`.
            let host = URL(string: url)?.host() ?? url
            return Card(id: node.id, name: clipped(CanvasPageTitles.of(url) ?? host), kind: .page(host: host))
        case .group:
            return nil
        }
    }

    /// Longest a name gets before it is cut. A menu is as wide as its widest item, and one card whose
    /// first line is a paragraph would otherwise make every other name sit in a menu half a screen wide.
    static let longestName = 60

    private static func clipped(_ name: String) -> String {
        guard name.count > longestName else { return name }
        return name.prefix(longestName - 1).trimmingCharacters(in: .whitespaces) + "\u{2026}"
    }
}

/// What a file card is called when it is one line: the file's name without its extension.
///
/// A project's notes file is named for the project, so the `Notes - ` prefix is the one part of the
/// filename that says nothing — and at this zoom the card is one line of text, which makes eight
/// wasted characters a third of it. Every board of projects otherwise reads as a row of cards all
/// starting with the same word.
///
/// Shared by the card's zoomed-out face and Add Card from Canvas, so the list names a card the way the
/// board does.
func canvasFileCardName(_ path: String) -> String {
    let name = ((path as NSString).deletingPathExtension as NSString).lastPathComponent
    guard projectFolder(ofNotesPath: path) != nil, name.hasPrefix("Notes - ") else { return name }
    return String(name.dropFirst("Notes - ".count))
}

/// The SF Symbol a file card draws when it is one line, by the kind of file it is.
func canvasFileSymbol(_ path: String) -> String {
    switch (path as NSString).pathExtension.lowercased() {
    case "md", "markdown", "txt": return "doc.text"
    case "png", "jpg", "jpeg", "gif", "heic", "webp", "tiff": return "photo"
    case "pdf": return "doc.richtext"
    default: return "doc"
    }
}
