import AppKit

/// The board's clip view, which a drag doesn't scroll while the tiles are up.
///
/// AppKit scrolls the clip view under a drag held near its edge — a link carried to the top of the
/// window, or a sidebar row carried over the band above the top tile (2026-11-05) — and a tiled view
/// laid out to fill the window then slid partly out of it, with no way back but leaving the tiling.
/// The same rule as `CanvasScrollView.scrollWheel`: while tiled, the board doesn't move. Off the
/// tiles, a drag near the edge still scrolls the board.
///
/// AppKit's hook is private (`_autoscrollForDraggingInfo:timeDelta:`, NSClipView's own since at
/// least macOS 10.7); the dragging manager asks whether to autoscroll before calling it, so answering
/// that question instead changes nothing — measured with a stand-in drag, 2026-11-05.
final class CanvasClipView: NSClipView {
    var holdsStill: () -> Bool = { false }

    private static let dragScroll = NSSelectorFromString("_autoscrollForDraggingInfo:timeDelta:")

    @objc(_autoscrollForDraggingInfo:timeDelta:)
    func autoscroll(forDragging info: AnyObject?, timeDelta: Double) -> Bool {
        if holdsStill() { return false }
        typealias Original = @convention(c) (AnyObject, Selector, AnyObject?, Double) -> Bool
        guard let imp = class_getMethodImplementation(NSClipView.self, Self.dragScroll) else { return false }
        return unsafeBitCast(imp, to: Original.self)(self, Self.dragScroll, info, timeDelta)
    }
}
