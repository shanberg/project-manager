import Foundation

/// How far a board may be pushed around inside its window.
///
/// A scroll view scrolls what overflows, so a board with three cards on it — or any board zoomed far
/// enough out that the whole of it fits — is nailed in place: you can look at it and you cannot move
/// it, which is the one thing an infinite plane must never do. Panning is how you make room to think.
///
/// So position is free and only *losing your way* is prevented. Pure arithmetic on two rectangles, out
/// here rather than inside the clip view, because it is the part with a wrong answer in it: the board
/// is installed before its document is read, and asking this question of a board that has no size yet
/// is what put a window in the corner it could not pan back out of. That is a case you want to be able
/// to write down, not one you want to reproduce by switching projects until it happens.
///
/// See `CanvasClipView`, which is the only caller, and `CanvasPanBoundsTests`.
enum CanvasPanBounds {
    /// How much of the thing being held has to stay in the window. A sliver is enough: it is a way
    /// back, not a view. Held against a card, a sliver at the window's edge still leaves the whole rest
    /// of the window empty to work in — which is what the room was for.
    static let keep: CGFloat = 120

    /// Where `proposed` is allowed to settle, or **nil for "no opinion"** — hand the question back to
    /// `NSClipView`, whose own answer for a document with no size is a sensible one.
    ///
    /// Nil rather than a best guess, because the case is not "a very small board" but "not a board
    /// yet", and the two want different answers. A board of nothing has no position worth defending.
    ///
    /// **What is held is the cards, not the board.** The board's frame is the cards' extent grown by
    /// `CanvasBoardView.margin` — 1600pt on every side, which is drag headroom rather than anything
    /// anyone looks at — so a rule stated against the frame is satisfied by a window full of blank
    /// paper 1600pt from the nearest card, with nothing on screen to steer by and no scroll short of
    /// ⌘0 that finds the way back. Held against `CanvasDocument.bounds` the sliver is a card, which is
    /// the thing you were actually trying not to lose. See `CanvasClipView.held`.
    static func constrain(_ proposed: CGRect, holding held: CGRect,
                          keeping keep: CGFloat = keep) -> CGRect? {
        guard held.width > 0, held.height > 0 else { return nil }
        // You cannot keep more of it in the window than there is. Left unclamped, something narrower
        // than `keep` demands a sliver that does not exist, and the arithmetic settles on an origin
        // outside every position it can actually be seen at.
        let keepX = min(keep, held.width)
        let keepY = min(keep, held.height)
        var rect = proposed
        // The furthest the window can travel in each direction: until only that much is left at the
        // trailing edge, and until only that much is left at the leading one.
        rect.origin.x = min(max(rect.minX, held.minX - rect.width + keepX), held.maxX - keepX)
        rect.origin.y = min(max(rect.minY, held.minY - rect.height + keepY), held.maxY - keepY)
        return rect
    }
}
