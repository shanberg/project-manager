import Foundation
import PmLib

/// Moving the selection from card to card by direction.
///
/// The navigation half of thinking about a board as a window manager. A tiling window manager's most
/// used gesture isn't a layout command at all — it's "focus the window to my left", and it works there
/// because tiled windows have unambiguous neighbours. A canvas has *better* spatial information than a
/// desktop does: cards were put where they are on purpose, and "the one above this" is a fact about the
/// board rather than an accident of what happened to be opened when.
///
/// So this works everywhere, not only while tiled. It is the same code either way — it reads the frames
/// it is given, which is the document's layout on a free board and the tiled layout inside one.
enum CanvasNavigation {
    enum Direction {
        case left, right, up, down

        /// The axis the move is along, and the way along it.
        var isHorizontal: Bool { self == .left || self == .right }
        var sign: Double { (self == .left || self == .up) ? -1 : 1 }
    }

    /// The card to move to from `current`, or nil when there is nothing that way.
    ///
    /// **A cone, not a ray.** Requiring a card to overlap the current one's band would miss the card
    /// that is up and slightly right, which on a real board is most of them; taking the nearest card in
    /// the half-plane instead would let a card far off to the side beat one almost straight ahead. So a
    /// candidate has to be *ahead* — its centre past the current card's, on the axis being travelled —
    /// and is then scored by distance along that axis plus a heavy penalty for drifting off it.
    ///
    /// The penalty is what makes this feel like a direction rather than a search. At 3× the off-axis
    /// distance a card one row over has to be three times closer to win, which in practice means the
    /// obvious neighbour always does.
    static func next(from current: CanvasRect, direction: Direction,
                     among others: [(id: String, frame: CanvasRect)]) -> String? {
        let from = (x: current.midX, y: current.midY)
        var best: (id: String, score: Double)?

        for candidate in others {
            let to = (x: candidate.frame.midX, y: candidate.frame.midY)
            let along = direction.isHorizontal ? (to.x - from.x) * direction.sign
                                               : (to.y - from.y) * direction.sign
            // Strictly ahead. A card whose centre sits level with this one is a neighbour in the other
            // axis, and stepping onto it would make the same key move you somewhere different each
            // time depending on rounding.
            guard along > 0.5 else { continue }
            let across = direction.isHorizontal ? abs(to.y - from.y) : abs(to.x - from.x)
            let score = along + across * 3
            if best == nil || score < best!.score { best = (candidate.id, score) }
        }
        return best?.id
    }
}
