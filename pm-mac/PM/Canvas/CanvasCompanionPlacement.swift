import AppKit

/// Where the session companion sits beside its satellite.
/// See `CanvasSatelliteCompanion`.
///
/// **Four anchors.** Outside the window at its top-left or top-right, hanging from the window's top
/// edge; inside it at its bottom-left or bottom-right, standing on its bottom edge. A panel that grows
/// grows away from the corner it is pinned to.
///
/// **Auto order:** outside on the side facing the screen's centre, the other outside, inside on the side
/// facing the centre, the other inside. A spot you dragged it to wins while it isn't blocked.
///
/// **Blocked:** an outside anchor that leaves the screen; an inside anchor in a window too small to
/// hold the panel below its header. Other windows don't block — the companion sits over them as the
/// dock does. With every anchor blocked it shrinks to a pill in the inside corner.
///
/// Screen coordinates, so up is +y. A file of its own so it compiles alone into `PMViewTests`.
enum CanvasCompanionPlacement {
    enum Anchor: String, CaseIterable, Codable {
        case outsideTopLeft, outsideTopRight, insideBottomLeft, insideBottomRight

        var isInside: Bool { self == .insideBottomLeft || self == .insideBottomRight }
    }

    static let width: CGFloat = 320
    static let gap: CGFloat = 12
    static let inset: CGFloat = 10

    /// The panel's frame at `anchor` beside `window`, kept on `screen` top to bottom.
    static func frame(at anchor: Anchor, size: NSSize, window: NSRect, screen: NSRect) -> NSRect {
        var origin: NSPoint
        switch anchor {
        case .outsideTopLeft: origin = NSPoint(x: window.minX - gap - size.width, y: window.maxY - size.height)
        case .outsideTopRight: origin = NSPoint(x: window.maxX + gap, y: window.maxY - size.height)
        case .insideBottomLeft: origin = NSPoint(x: window.minX + inset, y: window.minY + inset)
        case .insideBottomRight: origin = NSPoint(x: window.maxX - inset - size.width, y: window.minY + inset)
        }
        origin.y = min(max(origin.y, screen.minY), screen.maxY - size.height)
        return NSRect(origin: origin, size: size)
    }

    static func isBlocked(_ anchor: Anchor, size: NSSize, window: NSRect, screen: NSRect, header: CGFloat) -> Bool {
        if anchor.isInside {
            return size.height > window.height - header - 2 * inset || size.width > window.width - 2 * inset
        }
        let frame = frame(at: anchor, size: size, window: window, screen: screen)
        return frame.minX < screen.minX || frame.maxX > screen.maxX
    }

    /// The auto order for a window: its side facing the screen's centre first, outside before inside.
    static func order(window: NSRect, screen: NSRect) -> [Anchor] {
        window.midX < screen.midX
            ? [.outsideTopRight, .outsideTopLeft, .insideBottomRight, .insideBottomLeft]
            : [.outsideTopLeft, .outsideTopRight, .insideBottomLeft, .insideBottomRight]
    }

    struct Choice: Equatable {
        var anchor: Anchor
        /// Every anchor is blocked: show the pill, in the inside corner `anchor` names.
        var asPill: Bool
    }

    /// Where it goes. `size` is the open panel's, so a pill opening never changes corner.
    static func choose(spot: Anchor?, size: NSSize, window: NSRect, screen: NSRect, header: CGFloat) -> Choice {
        let order = order(window: window, screen: screen)
        let open = { (anchor: Anchor) in !isBlocked(anchor, size: size, window: window, screen: screen, header: header) }
        if let spot, open(spot) { return Choice(anchor: spot, asPill: false) }
        if let first = order.first(where: open) { return Choice(anchor: first, asPill: false) }
        return Choice(anchor: order.first(where: \.isInside) ?? .insideBottomRight, asPill: true)
    }

    /// Where a drag let go at `dropped` snaps to: the nearest anchor that isn't blocked, nil if none is.
    static func nearest(to dropped: NSRect, size: NSSize, window: NSRect, screen: NSRect, header: CGFloat) -> Anchor? {
        Anchor.allCases
            .filter { !isBlocked($0, size: size, window: window, screen: screen, header: header) }
            .min { a, b in
                distance(frame(at: a, size: size, window: window, screen: screen), dropped)
                    < distance(frame(at: b, size: size, window: window, screen: screen), dropped)
            }
    }

    private static func distance(_ a: NSRect, _ b: NSRect) -> CGFloat { hypot(a.midX - b.midX, a.midY - b.midY) }
}
