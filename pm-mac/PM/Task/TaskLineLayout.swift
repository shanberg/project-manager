import SwiftUI

/// A task's words, the badges after them, and an optional control that appears over the words' end.
///
/// **The words keep their width.** A badge column beside the text used to take whatever it needed and
/// leave the text the rest, so a narrow card with a date, a pick-up and a count wrapped a task into a
/// thin strip three lines deep. Now the badges stay on the line only while the text keeps at least
/// `minTextShare` of it. Past that they go to a line of their own under the text, the way Reminders
/// puts a task's details under it, and the words get the full width back.
///
/// **The third view is a ghost**: a control that shows on hover, like the card's "＋date". It is
/// placed at the end of the text's first line, over the words, and takes no room. A control that
/// held its space while invisible cost every task the width of a button nobody could see. It brings
/// its own backing to cover the words it sits on: the words are never masked, because a mask on a
/// hosted AppKit text view kept the size it had when it switched on and cut off every line but the
/// first.
struct TaskLineLayout: Layout {
    /// Between the words and the badges on one line.
    var gap: CGFloat = 6
    /// Between the words and the badges on a line of their own.
    var stackSpacing: CGFloat = 1
    /// The least of a line the words keep before its badges move under them.
    var minTextShare: CGFloat = 0.7

    struct Placement {
        var text: CGRect
        var badges: CGRect
        var ghost: CGRect?
        var textBaseline: CGFloat
        var size: CGSize
    }

    /// Placements already worked out, by the width they were worked out for.
    ///
    /// SwiftUI asks a layout the same question three ways in one pass — its size, where its subviews
    /// go, and where its baseline is — and each answer measures every subview again, the text by laying
    /// it out. A card of a long project runs that for every row on every change, so the answer is kept
    /// for the pass. SwiftUI replaces the cache whenever the subviews change (`updateCache` defaults to
    /// `makeCache`), which is exactly when a remembered placement would stop being true.
    typealias Cache = [CGFloat?: Placement]

    func makeCache(subviews: Subviews) -> Cache { [:] }

    private func place(width: CGFloat?, _ subviews: Subviews, cache: inout Cache) -> Placement {
        if let known = cache[width] { return known }
        let placement = place(width: width, subviews)
        cache[width] = placement
        return placement
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        place(width: proposal.width, subviews, cache: &cache).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        let placement = place(width: bounds.width, subviews, cache: &cache)
        func put(_ index: Int, _ rect: CGRect) {
            guard subviews.indices.contains(index) else { return }
            subviews[index].place(at: CGPoint(x: bounds.minX + rect.minX, y: bounds.minY + rect.minY),
                                  proposal: ProposedViewSize(rect.size))
        }
        put(0, placement.text)
        put(1, placement.badges)
        if let ghost = placement.ghost { put(2, ghost) }
    }

    /// The text's first baseline, so the row can line the box up with the words.
    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
                           subviews: Subviews, cache: inout Cache) -> CGFloat? {
        guard guide == .firstTextBaseline else { return nil }
        let placement = place(width: bounds.width, subviews, cache: &cache)
        return placement.text.minY + placement.textBaseline
    }

    private func place(width: CGFloat?, _ subviews: Subviews) -> Placement {
        guard let text = subviews.first else { return Placement(text: .zero, badges: .zero, textBaseline: 0, size: .zero) }
        let badges = subviews.count > 1 ? subviews[1] : nil
        let badgeSize = badges?.sizeThatFits(.unspecified) ?? .zero
        let hasBadges = badgeSize.width > 0.5
        let badgeRoom = hasBadges ? gap + badgeSize.width : 0

        let textWidth: CGFloat?
        let inline: Bool
        if let width {
            inline = !hasBadges || width - badgeRoom >= width * minTextShare
            textWidth = inline ? max(width - badgeRoom, 0) : width
        } else {
            inline = true
            textWidth = nil
        }
        let textProposal = ProposedViewSize(width: textWidth, height: nil)
        let textSize = text.sizeThatFits(textProposal)
        let textBaseline = text.dimensions(in: textProposal)[VerticalAlignment.firstTextBaseline]
        let columnWidth = textWidth ?? textSize.width
        let total = width ?? (columnWidth + badgeRoom)

        var textRect = CGRect(x: 0, y: 0, width: columnWidth, height: textSize.height)
        var badgeRect = CGRect.zero
        if hasBadges, let badges {
            let badgeBaseline = badges.dimensions(in: .unspecified)[VerticalAlignment.firstTextBaseline]
            if inline {
                // Baselines level; whichever reaches higher sets the top.
                var badgeY = textBaseline - badgeBaseline
                if badgeY < 0 {
                    textRect.origin.y = -badgeY
                    badgeY = 0
                }
                badgeRect = CGRect(x: total - badgeSize.width, y: badgeY,
                                   width: badgeSize.width, height: badgeSize.height)
            } else {
                badgeRect = CGRect(x: 0, y: textRect.maxY + stackSpacing,
                                   width: badgeSize.width, height: badgeSize.height)
            }
        }

        var ghostRect: CGRect?
        if subviews.count > 2 {
            let ghost = subviews[2]
            let size = ghost.sizeThatFits(.unspecified)
            let baseline = ghost.dimensions(in: .unspecified)[VerticalAlignment.firstTextBaseline]
            ghostRect = CGRect(x: textRect.maxX - size.width, y: textRect.minY + textBaseline - baseline,
                               width: size.width, height: size.height)
        }

        let height = max(textRect.maxY, hasBadges ? badgeRect.maxY : 0)
        return Placement(text: textRect, badges: badgeRect, ghost: ghostRect, textBaseline: textBaseline,
                         size: CGSize(width: total, height: height))
    }
}
