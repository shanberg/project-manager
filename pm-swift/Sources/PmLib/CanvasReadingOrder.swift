import Foundation

/// The order cards are read in: down and across the board, as they actually sit on it.
///
/// **The one order a board already has**, and therefore the one a list can borrow without inventing a
/// second opinion about which card comes first (docs/items.md D4). It is what tiles are laid in
/// (`CanvasTiling.order`, which calls this), what Add Card from Canvas offers, and the item lenses'
/// default sort.
///
/// This is what makes it a *canvas's* order rather than a generic one. The cards were placed on
/// purpose, and an order that scattered them into arbitrary cells would throw away the one thing the
/// board knows that a list doesn't. Rows first — cards within a band of each other vertically read as
/// a row, and are then sorted left to right — because that is how the boards in this vault are
/// actually built.
public func canvasReadingOrder(_ cards: [(id: String, frame: CanvasRect)]) -> [String] {
    guard !cards.isEmpty else { return [] }
    // A row is a band as tall as the median card. Taken from the cards themselves rather than fixed,
    // because a board of 400pt dashboard tiles and a board of 60pt sticky notes disagree about what
    // "the same row" means by an order of magnitude.
    let heights = cards.map(\.frame.height).sorted()
    let band = max(20, heights[heights.count / 2] * 0.6)

    var rows: [[(id: String, frame: CanvasRect)]] = []
    for card in cards.sorted(by: { $0.frame.midY < $1.frame.midY }) {
        if let last = rows.last, let first = last.first,
           abs(card.frame.midY - first.frame.midY) <= band {
            rows[rows.count - 1].append(card)
        } else {
            rows.append([card])
        }
    }
    return rows.flatMap { $0.sorted { $0.frame.midX < $1.frame.midX }.map(\.id) }
}
