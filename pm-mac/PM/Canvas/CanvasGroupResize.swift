import Foundation
import PmLib

/// Resizing several cards at once, by their shared bounding box.
///
/// The obvious rule — scale every coordinate by the same factor — is the one every drawing tool uses,
/// and it is wrong for a board. Cards on a board are arranged with *gaps*: a column of notes 20 points
/// apart is 20 points apart because that is what a gap between two cards looks like, not because 20 is
/// a fifth of a card. Scale it and a selection dragged to twice its size comes back with 40-point
/// canyons through it, and you tidy the spacing by hand afterwards — which is the work you were trying
/// to avoid by selecting them all in the first place.
///
/// So the gaps are held and the cards absorb the change. Stated per axis: the space between the
/// selection's outer edges is cut into runs at every card edge in it, each run is either *covered* by
/// at least one card or is empty board, and only the covered runs stretch. A run of empty board comes
/// out of a resize exactly as long as it went in, wherever it sits and however many cards are on
/// either side of it.
///
/// Per axis, and independently, because that is the only reading that survives cards which overlap or
/// which start and end at unrelated places. There is no grid to reason about here, no rows and no
/// columns — only a set of rectangles — and a rule that needed to find the rows first would be a rule
/// with an opinion about what a board is allowed to look like.
///
/// One card selected is the same arithmetic with nothing to hold: two edges, one covered run, no gaps,
/// so the factor is just the ratio of the widths and this reduces to a plain resize. That is
/// deliberate — the single-card path goes through here too, and a special case that only ever ran for
/// n = 1 would be a second implementation nobody exercised.
enum CanvasGroupResize {

    /// The smallest a card is allowed to get, matching `CanvasSnapping`'s own floor.
    static let minimum: Double = 40

    /// Where each of `frames` lands when the box around them is dragged from `box` to `target`.
    ///
    /// `box` is passed rather than recomputed so it is the box the gesture started from — the frames
    /// have been moving all through the drag, and recomputing would measure the answer to the previous
    /// mouse event.
    static func frames(_ frames: [String: CanvasRect],
                       from box: CanvasRect,
                       to target: CanvasRect) -> [String: CanvasRect] {
        guard !frames.isEmpty else { return [:] }
        let x = Ruler(spans: frames.values.map { ($0.minX, $0.maxX) },
                      from: (box.minX, box.maxX), to: (target.minX, target.maxX))
        let y = Ruler(spans: frames.values.map { ($0.minY, $0.maxY) },
                      from: (box.minY, box.maxY), to: (target.minY, target.maxY))

        return frames.mapValues { frame in
            let left = x.map(frame.minX), right = x.map(frame.maxX)
            let top = y.map(frame.minY), bottom = y.map(frame.maxY)
            return CanvasRect(x: left, y: top, width: right - left, height: bottom - top)
        }
    }

    /// One axis of the map: where each edge in the selection ends up.
    ///
    /// Held as the sorted edge positions and where each of them lands, so `map` is a lookup and a lerp
    /// rather than a re-derivation. Every card edge is one of the breaks by construction, so a card's
    /// own coordinates map exactly and two cards that shared an edge going in still share one coming
    /// out — no card drifts a fraction of a point away from a neighbour it was flush with.
    struct Ruler {
        private var breaks: [Double] = []
        private var landings: [Double] = []
        /// The translation applied outside the box. Only reachable by a caller asking about a
        /// coordinate that wasn't in the selection, which `frames` never does.
        private var shift: Double = 0

        init(spans: [(Double, Double)], from: (Double, Double), to: (Double, Double)) {
            shift = to.0 - from.0

            var edges = Set<Double>()
            for span in spans { edges.insert(span.0); edges.insert(span.1) }
            edges.insert(from.0)
            edges.insert(from.1)
            breaks = edges.sorted()
            guard breaks.count >= 2 else {
                landings = breaks.map { $0 + shift }
                return
            }

            // Which runs are card and which are board, and how much of each there is.
            var covered: [Bool] = []
            var cardTotal = 0.0, boardTotal = 0.0
            for index in 0..<(breaks.count - 1) {
                let low = breaks[index], high = breaks[index + 1]
                let isCard = spans.contains { $0.0 <= low && $0.1 >= high }
                covered.append(isCard)
                if isCard { cardTotal += high - low } else { boardTotal += high - low }
            }

            // The gaps are spent first; whatever room is left is what the cards have to share.
            let wanted = to.1 - to.0
            var factor = cardTotal > 0 ? (wanted - boardTotal) / cardTotal : 1
            // A selection can be dragged smaller than its gaps, at which point the arithmetic above
            // asks the cards to be zero or negative. The floor is per *card* rather than on the box:
            // what must not collapse is the smallest card in the selection, and holding the box to
            // some minimum instead would let a 60pt card vanish inside a 900pt one.
            if let smallest = spans.map({ $0.1 - $0.0 }).filter({ $0 > 0 }).min(), smallest > 0 {
                factor = max(factor, CanvasGroupResize.minimum / smallest)
            }
            factor = max(factor, 0.001)

            landings = [to.0]
            var cursor = to.0
            for index in 0..<(breaks.count - 1) {
                let length = breaks[index + 1] - breaks[index]
                cursor += covered[index] ? length * factor : length
                landings.append(cursor)
            }
        }

        func map(_ value: Double) -> Double {
            guard let first = breaks.first, let last = breaks.last, breaks.count >= 2 else {
                return value + shift
            }
            if value <= first { return landings[0] + (value - first) }
            if value >= last { return landings[landings.count - 1] + (value - last) }
            for index in 0..<(breaks.count - 1) where value <= breaks[index + 1] {
                let run = breaks[index + 1] - breaks[index]
                guard run > 0 else { return landings[index] }
                let along = (value - breaks[index]) / run
                return landings[index] + along * (landings[index + 1] - landings[index])
            }
            return landings[landings.count - 1]
        }
    }
}
