import Foundation
import PmLib

/// How far a card's own content is zoomed, independent of the board's zoom.
///
/// **Two zooms, and they answer different questions.** The board's zoom is how far away you are
/// standing from the plane; a card's is how large that page is set. Zooming the board at a web card
/// scales its frame along with its text, so a page you can finally read is a card covering four times
/// as much board — and in a tiled view, where the frame is the arrangement's to decide, the board's
/// zoom cannot help you at all. That is the case this is for: a site that renders at 11px, filling half
/// the window, still unreadable.
///
/// **Kept on the node, in the file.** A zoom set again on every rebuild — which is every time a card
/// scrolls out of the keep-alive region and back — would not be worth having. `extra` is how
/// `CanvasNode` carries keys the format doesn't define, and this is one: PM's own, namespaced, and left
/// alone by everything else that opens the file. It is the same bargain PM asks of Advanced Canvas's
/// `styleAttributes`, from the other side of it.
enum CanvasCardZoom {
    /// The key PM writes. Prefixed because a `.canvas` is a shared document — Obsidian's own keys are
    /// unprefixed and the plugins that write to one all namespace themselves, for the same reason.
    static let key = "pmZoom"

    /// A card nobody has zoomed. Written as the absence of the key rather than as `1`.
    static let normal: Double = 1

    /// The stops ⌘+ and ⌘− walk between — a browser's ladder, which is what a page zoom should feel
    /// like. Coarse at the ends and fine around 100%, where the adjustments you actually make are.
    static let steps: [Double] = [0.5, 0.67, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3]

    static func of(_ node: CanvasNode) -> Double {
        guard case .number(let zoom)? = node.extra[key] else { return normal }
        // Clamped on the way in, not trusted: the number came out of a file, which another program
        // may have written and a person may have edited.
        return min(steps.last!, max(steps.first!, zoom))
    }

    static func set(_ zoom: Double, on node: inout CanvasNode) {
        let wanted = min(steps.last!, max(steps.first!, zoom))
        // Back at 100% the key goes rather than being written as the default, so a card you zoomed and
        // unzoomed leaves the file exactly as it found it.
        node.extra[key] = isNormal(wanted) ? nil : .number(wanted)
    }

    static func isNormal(_ zoom: Double) -> Bool { abs(zoom - normal) < 0.001 }

    /// The next stop up (`1`) or down (`-1`) from wherever a card is now.
    ///
    /// Off the ladder rather than by a factor, so a card that arrived at 1.37 from somewhere else lands
    /// on a stop instead of walking its own private sequence, and so the ends are ends: ⌘+ at 300% is a
    /// no-op rather than a card that quietly goes on growing.
    static func stepped(_ current: Double, by direction: Int) -> Double {
        guard direction != 0 else { return current }
        if direction > 0 { return steps.first { $0 > current + 0.001 } ?? steps.last! }
        return steps.last { $0 < current - 0.001 } ?? steps.first!
    }
}
