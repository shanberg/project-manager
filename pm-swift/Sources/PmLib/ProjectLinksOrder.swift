import Foundation

/// Reordering a project's `## Links` (canvas backlog 14): a link dragged along the list the project card
/// shows goes where it was let go, and the file is written in that order — the order of the lines is
/// the only order links have, so moving one is moving its line.
///
/// **Groups stay where they are.** A group heading with its indented URLs holds its place in the list,
/// and only the links on their own lines move, around it. The blank placeholder a new project's list is
/// written with doesn't move either: it is not a link.
extension Array where Element == LinkEntry {
    /// Where the links that can move are, in the list: every entry on a line of its own with something
    /// in it — a label, an address or both — and no group under it.
    public var movableLinkSlots: [Int] {
        indices.filter { index in
            let entry = self[index]
            let filled = !(entry.label ?? "").trimmingCharacters(in: .whitespaces).isEmpty
                || !(entry.url ?? "").trimmingCharacters(in: .whitespaces).isEmpty
            return filled && (entry.children ?? []).isEmpty
        }
    }

    /// The list with the `from`th movable link taken out and put back as the `to`th, counted among the
    /// movable links alone. Everything else keeps its index. Out-of-range answers the list unchanged.
    public func movingLink(from: Int, to: Int) -> [LinkEntry] {
        let slots = movableLinkSlots
        guard slots.indices.contains(from), slots.indices.contains(to), from != to else { return self }
        var order = slots.map { self[$0] }
        order.insert(order.remove(at: from), at: to)
        var out = self
        for (slot, entry) in zip(slots, order) { out[slot] = entry }
        return out
    }
}
