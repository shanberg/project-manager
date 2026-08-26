import CoreGraphics
import SwiftUI

// MARK: Drag-to-reorder geometry
//
// The task list has one drop target for the whole list, not one per row. Everything that turns a
// pointer position into "this task goes here" lives in this file: the frames the rows and session
// headings publish, the resolved slot, the pure resolver that maps between them, and the delegate
// that drives it.
//
// Keeping the resolver a free function over plain values — no store, no view, no `@State` — is what
// makes the geometry checkable on its own, which the ad-hoc version inside `ProjectView` was not.

/// A visible task row's vertical extent and depth in the task-list coordinate space, published via
/// preference so the single list-level drop delegate can resolve the pointer into a gap + depth
/// without per-row drop targets. Carries the row's document identity (session/line) to name the move
/// anchor.
struct RowFrame: Equatable {
    let key: String
    let session: Int
    let line: Int
    let depth: Int
    let minY: CGFloat
    let maxY: CGFloat

    var midY: CGFloat { (minY + maxY) / 2 }
}

/// Collects every visible row's frame into one array for the drop delegate.
struct RowFramesKey: PreferenceKey {
    static var defaultValue: [RowFrame] = []
    static func reduce(value: inout [RowFrame], nextValue: () -> [RowFrame]) {
        value.append(contentsOf: nextValue())
    }
}

/// A rendered session heading's vertical extent — the header line, its note, and the padding around
/// them: the block a session occupies when it has no task rows of its own.
///
/// Published so a session with nothing in it is still a place you can drop on. Without it an empty
/// session was a hole in the list: the only slots on offer were the ones named by task rows, so the
/// one destination with no task rows to name it couldn't be reached at all — you had to drop the task
/// in a neighbouring session and drag it again once there was something there to aim at.
struct SessionFrame: Equatable {
    let index: Int
    let minY: CGFloat
    let maxY: CGFloat
}

/// Collects every rendered session heading's frame for the drop delegate.
struct SessionFramesKey: PreferenceKey {
    static var defaultValue: [SessionFrame] = []
    static func reduce(value: inout [SessionFrame], nextValue: () -> [SessionFrame]) {
        value.append(contentsOf: nextValue())
    }
}

/// Publishes a session heading's block as a drop target. Goes in the heading's `.background`, the way
/// a task row publishes its own frame.
///
/// Every rendered heading reports, empty or not — the resolver decides which ones are targets, since
/// "empty" means "no rows left once the dragged subtree is lifted out", which a heading can't know
/// about itself. Both headings wear it: the notes view's `SessionHeader` and the compact list's
/// caption. What each list chooses to draw is what's reachable, so a session hidden because a filter
/// emptied it isn't a target in either — see `ProjectView.sessionOrder`.
struct SessionFrameReporter: View {
    let index: Int
    var body: some View {
        GeometryReader { g in
            let f = g.frame(in: .named(TaskDropResolver.coordinateSpace))
            Color.clear.preference(key: SessionFramesKey.self,
                                   value: [SessionFrame(index: index, minY: f.minY, maxY: f.maxY)])
        }
    }
}

/// The resolved insertion slot for an in-flight drag: where to paint the one indicator (the gap's Y
/// and the chosen nesting depth) and the destination the move will use.
///
/// There is no "invalid" case. A slot either exists or it doesn't: the resolver lifts the dragged
/// subtree out of the list before it looks for one, so every slot it can name is a slot the move can
/// actually reach. Nil means there is nowhere to land — which happens only when the dragged subtree
/// is the entire list and no session heading is on screen to take it.
struct DropTarget: Equatable {
    let gapY: CGFloat
    let depth: Int
    let destination: Destination

    /// Where the move lands. Almost every drop names a task to sit beside, which fixes both the
    /// session and the position within it; a drop on a session with no tasks has only the session.
    enum Destination: Equatable {
        case beside(session: Int, line: Int, after: Bool)
        case endOfSession(Int)
    }
}

/// Turns a pointer position into exactly one insertion slot.
enum TaskDropResolver {
    /// The named coordinate space every published frame — task row and session heading — is measured
    /// in, and the one the drop delegate resolves the pointer against. It lives here rather than on
    /// the view so there's a single name the measurers and the reader can't disagree about.
    static let coordinateSpace = "pmTaskList"

    /// Resolve `pointer` (in `coordinateSpace`) against the visible rows and session headings.
    ///
    /// The dragged subtree is lifted out of `rows` first, so the list is read as it will be *after*
    /// the move rather than as it looks during it. That one step is what makes the gestures people
    /// actually make work: dragging a row rightward to indent it resolves against the row above the
    /// row being dragged, instead of resolving to "make this a child of itself" and refusing; and a
    /// gap bounded by the dragged subtree is an ordinary slot (a no-op one) rather than a forbidden
    /// cursor. It also means the answer is never illegal, so there is no invalid state to paint.
    ///
    /// - Parameters:
    ///   - sessionFrames: every rendered session heading, so a session with no rows left to name a
    ///     slot can still be dropped on.
    ///   - draggedSubtree: `PMStore` keys of the dragged task and its descendants.
    ///   - contentInset: x of a depth-0 row's content — the origin the pointer's depth is measured from.
    ///   - indentStep: horizontal pixels per nesting level.
    static func resolve(pointer: CGPoint,
                        rows: [RowFrame],
                        sessionFrames: [SessionFrame],
                        draggedSubtree: Set<String>,
                        contentInset: CGFloat,
                        indentStep: CGFloat) -> DropTarget? {
        let ordered = rows.sorted { $0.minY < $1.minY }
        let candidates = ordered.filter { !draggedSubtree.contains($0.key) }

        // A session heading with no task rows under it *is* the session, so the whole of its block is
        // the target — there's no gap to aim into. Checked before the gaps below, since a heading
        // standing between two sessions' tasks otherwise reads as part of the boundary between them.
        //
        // "No task rows" counts what's left after the lift, so a session whose only task is the one
        // being dragged becomes a destination for the duration of the drag. That's what lets you put
        // a task back where it came from instead of stranding it in the session next door.
        let occupied = Set(candidates.map(\.session))
        if let session = sessionFrames.first(where: {
            !occupied.contains($0.index) && pointer.y >= $0.minY && pointer.y < $0.maxY
        }) {
            return DropTarget(gapY: session.maxY, depth: 0, destination: .endOfSession(session.index))
        }

        guard !candidates.isEmpty else { return nil }

        // Gap index = how many rows sit (by midpoint) at or above the pointer → 0 = above the first
        // row, candidates.count = below the last (the trailing gap).
        let gapIndex = candidates.filter { $0.midY <= pointer.y }.count
        let above: RowFrame? = gapIndex > 0 ? candidates[gapIndex - 1] : nil
        let below: RowFrame? = gapIndex < candidates.count ? candidates[gapIndex] : nil
        let requested = Int(((pointer.x - contentInset) / indentStep).rounded())

        // A gap that straddles a session boundary is two slots wearing one gap: the end of the session
        // above and the start of the session below. They are different places in the document, and
        // with only the one slot the end of any session but the last was unreachable — aiming there
        // silently landed the task at the top of the *next* session, under an indicator drawn back in
        // the session it came from. The band between the two rows (which holds the session's heading)
        // is wide enough to split, so split it and let the indicator sit against whichever row owns
        // the chosen slot.
        if let a = above, let b = below, a.session != b.session {
            // The band is measured across *all* the rows, dragged ones included, so it's the heading's
            // real gap rather than whatever the lift happened to leave behind — the boundary sits in
            // the same place however much of the session above is currently in the air.
            let bandTop = ordered.filter { $0.session == a.session }.map(\.maxY).max() ?? a.maxY
            let bandBottom = ordered.filter { $0.session == b.session }.map(\.minY).min() ?? b.minY
            if pointer.y < (bandTop + bandBottom) / 2 {
                return slot(anchor: a, insertAfter: true, depth: clamp(requested, 0, a.depth + 1))
            }
            // First task of its session: nothing above it there to nest under, so depth is settled.
            return slot(anchor: b, insertAfter: false, depth: b.depth)
        }

        // Legal depth range at this gap: no shallower than the row below (else you'd re-parent it), no
        // deeper than one under the row above (its deepest legal child).
        let depth = clamp(requested,
                          below?.depth ?? 0,
                          above.map { $0.depth + 1 } ?? below?.depth ?? 0)

        // Resolve the document slot. Nesting deeper than the row below anchors on the row above (which
        // supplies the parent chain); otherwise anchor the row below and insert before it — this keeps
        // a plain sibling insert precise.
        switch (above, below) {
        case let (a?, b?):
            return depth > b.depth
                ? slot(anchor: a, insertAfter: true, depth: depth)
                : slot(anchor: b, insertAfter: false, depth: depth)
        case let (a?, nil): return slot(anchor: a, insertAfter: true, depth: depth)
        case let (nil, b?): return slot(anchor: b, insertAfter: false, depth: depth)
        // Unreachable: `candidates` is non-empty, so the pointer has a row on one side of it.
        case (nil, nil): return nil
        }
    }

    /// The indicator sits against the edge of the row the slot is anchored on — the anchor's bottom
    /// for an insert-after, its top for an insert-before. Anything else (a single "gap Y" shared by
    /// both sides) draws the line in one place and performs the move in another wherever the two rows
    /// aren't flush, which is every session boundary.
    private static func slot(anchor: RowFrame, insertAfter: Bool, depth: Int) -> DropTarget {
        DropTarget(gapY: insertAfter ? anchor.maxY : anchor.minY,
                   depth: depth,
                   destination: .beside(session: anchor.session, line: anchor.line, after: insertAfter))
    }

    private static func clamp(_ value: Int, _ low: Int, _ high: Int) -> Int {
        min(max(value, low), max(low, high))
    }
}

// MARK: Drop delegate

/// The single list-level drop target. Resolves the pointer (in the task-list coordinate space) into a
/// slot via the parent's `onCompute`, reports it so the list can paint the one insertion line, and
/// commits the move on drop. All row/store access lives in the parent-supplied closures, so this
/// stays a plain value type.
struct ListDropDelegate: DropDelegate {
    /// Whether one of our own rows started this drag. A closure, not a `Bool`: the delegate value is
    /// built while the list's body runs, and the drag begins *after* that — a snapshot taken then says
    /// "no drag in flight" and turns away the very session it was built for, which read as a drag that
    /// sometimes did nothing at all.
    let isActive: () -> Bool
    /// Resolve a pointer location into the drop slot (nil when there's nowhere to land).
    let onCompute: (CGPoint) -> DropTarget?
    /// Publish the current slot (nil clears the indicator).
    let onUpdate: (DropTarget?) -> Void
    /// Commit the resolved move; returns whether it was accepted.
    let onPerform: (DropTarget) -> Bool

    func validateDrop(info: DropInfo) -> Bool { isActive() }

    /// The drag starts inside the list, so entry is the first thing that happens to it. Without this
    /// the indicator waited for the pointer to move again, and a short drag onto the neighbouring row
    /// could be released before one ever appeared.
    func dropEntered(info: DropInfo) { onUpdate(onCompute(info.location)) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let target = onCompute(info.location)
        onUpdate(target)
        return DropProposal(operation: target == nil ? .forbidden : .move)
    }

    func dropExited(info: DropInfo) { onUpdate(nil) }

    func performDrop(info: DropInfo) -> Bool {
        guard let target = onCompute(info.location) else { onUpdate(nil); return false }
        return onPerform(target)
    }
}
