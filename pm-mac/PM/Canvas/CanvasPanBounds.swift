import Foundation

/// How far a board may be pushed around inside its window.
///
/// A scroll view scrolls what overflows, so a board with three cards on it — or any board zoomed far
/// enough out that the whole of it fits — is nailed in place: you can look at it and you cannot move
/// it, which is the one thing an infinite plane must never do. Panning is how you make room to think.
///
/// So position is free and only *losing your way* is prevented: at least `keep` of the cards stays in
/// the window.
///
/// **The limit is the board's own frame** (2026-11-05). The frame is the cards' extent plus `room` on
/// every side, which is exactly the travel that leaves `keep` of them showing, so the scroll view's own
/// edge is the limit and AppKit's elastic bounce and momentum work at all four of them. Before, the
/// frame was the cards plus a fixed 1600pt and the limit was a second, inner edge enforced by
/// `constrainBoundsRect` — which wheel scrolls and zooms never ask, so a board could be panned off its
/// cards; and where the inner edge was met first there was a dead stop instead of a bounce.
///
/// Pure arithmetic, out here so the cases with wrong answers can be written down: see
/// `CanvasPanBoundsTests`. The caller is `CanvasBoardView.recomputeContent`.
enum CanvasPanBounds {
    /// How much of the cards has to stay in the window, in screen points. A sliver is enough: it is a
    /// way back, not a view, and it leaves the rest of the window empty to spread into.
    static let keep: CGFloat = 120

    /// The room the frame keeps past the cards on each side, in board points.
    ///
    /// - `visible`: the window's size in board points (the clip's bounds), so a zoomed-out board gets
    ///   more room, as it should — the window covers more of it.
    /// - `scale`: board points per screen point (`visible` over the clip's frame), which turns `keep`
    ///   into board points: 120pt on screen at any zoom. Held in board points it was 10 pixels at 8%.
    /// - `cards`: the cards' extent. You cannot keep more of it in the window than there is, so a
    ///   board narrower than the sliver is held whole.
    static func room(visible: CGSize, scale: CGFloat, cards: CGSize) -> CGSize {
        let keepX = min(keep * scale, cards.width)
        let keepY = min(keep * scale, cards.height)
        return CGSize(width: max(0, visible.width - keepX), height: max(0, visible.height - keepY))
    }
}
