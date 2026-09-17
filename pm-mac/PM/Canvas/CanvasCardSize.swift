import Foundation
import PmLib

/// Size ▸ in a card's menu (backlog 27): a card set to a proportion, or to an exact size.
///
/// ⇧ on a grip already keeps the shape a card has; this is for giving it a shape it doesn't. A menu
/// rather than snaps during a resize, so it costs nothing to anyone who never opens it — which is also
/// why there is no switch in Settings for it.
///
/// **The width stays and the top-left stays**, so a card set to a proportion grows or shrinks
/// downwards, the way a window's content does when it is told a new height. Every card in the
/// selection is set on its own, from its own width; a frame is set like any card, and what it holds
/// is left where it is.
enum CanvasCardSize {

    /// A proportion, width to height.
    struct Ratio: Equatable {
        let width: Double
        let height: Double
        var title: String { "\(Int(width)):\(Int(height))" }
    }

    /// Widest first. 5:7 and 11:19 are a playing card's and a tarot card's, listed by proportion alone.
    static let ratios: [Ratio] = [
        Ratio(width: 16, height: 9), Ratio(width: 3, height: 2), Ratio(width: 4, height: 3),
        Ratio(width: 1, height: 1),
        Ratio(width: 3, height: 4), Ratio(width: 5, height: 7), Ratio(width: 2, height: 3),
        Ratio(width: 11, height: 19), Ratio(width: 9, height: 16),
    ]

    /// The smallest a card goes on either axis — a resize's floor.
    static let minimum: Double = 40

    /// `frame` at `ratio`: its width and top-left kept, its height to match, in whole points. A card so
    /// narrow the height would fall under the floor is widened to meet it instead.
    static func frame(_ frame: CanvasRect, at ratio: Ratio) -> CanvasRect {
        var width = frame.width
        var height = (width * ratio.height / ratio.width).rounded()
        if height < minimum {
            height = minimum
            width = (height * ratio.width / ratio.height).rounded()
        }
        return CanvasRect(x: frame.minX, y: frame.minY, width: width, height: height)
    }

    /// `frame` at an exact size, top-left kept. Nil on an axis keeps that axis as it is — how one field
    /// of Exact Size is left alone across cards of different sizes.
    static func frame(_ frame: CanvasRect, width: Double?, height: Double?) -> CanvasRect {
        CanvasRect(x: frame.minX, y: frame.minY,
                   width: max(minimum, (width ?? frame.width).rounded()),
                   height: max(minimum, (height ?? frame.height).rounded()))
    }

    /// The new frame of every selected card that changes.
    static func plan(_ selection: Set<String>, in document: CanvasDocument,
                     _ resize: (CanvasRect) -> CanvasRect) -> [String: CanvasRect] {
        var out: [String: CanvasRect] = [:]
        for node in document.nodes where selection.contains(node.id) {
            let to = resize(node.frame)
            if to != node.frame { out[node.id] = to }
        }
        return out
    }

    /// Whether every one of `frames` is already at `ratio` — the tick in the menu. Within a point of
    /// height, since that is what the rounding leaves.
    static func all(_ frames: [CanvasRect], at ratio: Ratio) -> Bool {
        !frames.isEmpty && frames.allSatisfy { abs($0.height - $0.width * ratio.height / ratio.width) <= 1 }
    }
}
