import SwiftUI

/// The transitions a task uses when it changes identity under the user: the directional slides the
/// focus panel's card uses when the focused task moves, and the in-place wipe it uses when the same
/// task's text is edited.

/// A soft, feathered mask reveal used when a task's text is edited in place. Editing isn't a spatial
/// event, so this deliberately avoids the directional slide of a navigation: a gently feathered edge
/// sweeps the new text in while it also crossfades (see `AnyTransition.wipe`), reading as the text
/// refreshing/shimmering in place rather than moving. Alpha-only, so it's correct in light and dark.
struct WipeModifier: ViewModifier, Animatable {
    /// 0 = fully masked (hidden), 1 = fully revealed.
    var animatableData: CGFloat

    /// Width of the soft reveal edge, as a fraction of the content — wide enough to read as a shimmer
    /// rather than a hard wipe line.
    private let feather: CGFloat = 0.35

    func body(content: Content) -> some View {
        let p = animatableData
        content.mask(
            GeometryReader { geo in
                LinearGradient(
                    stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black, location: p),
                        .init(color: .clear, location: min(1, p + feather)),
                        .init(color: .clear, location: 1),
                    ],
                    startPoint: .leading, endPoint: .trailing
                )
                .frame(width: geo.size.width, height: geo.size.height)
            }
        )
    }
}

extension AnyTransition {
    /// The in-place edit transition: a feathered mask wipe crossfaded with opacity, so an edit dissolves
    /// and shimmers in place instead of sliding like a move.
    static var wipe: AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .modifier(
                active: WipeModifier(animatableData: 0),
                identity: WipeModifier(animatableData: 1))),
            removal: .opacity
        )
    }

    /// A `push`-style slide that can travel diagonally. The built-in `.push(from:)` only moves along a
    /// single edge, but task-focus moves are usually diagonal: diving into a subtask travels
    /// down-and-right (the child is both deeper and further down the outline), and a completion bubbling
    /// up to a sibling-less ancestor travels up-and-left. `horizontal` and `vertical` name the edges the
    /// *incoming* content enters from (either may be nil for a purely vertical or horizontal move); the
    /// outgoing content leaves toward the opposite corner. Crossfaded so it reads like `.push`, and
    /// size-proportional (built from `.move`), so it scales to whatever it animates.
    static func cornerPush(horizontal: Edge?, vertical: Edge?) -> AnyTransition {
        func opposite(_ e: Edge) -> Edge {
            switch e {
            case .leading:  return .trailing
            case .trailing: return .leading
            case .top:      return .bottom
            case .bottom:   return .top
            }
        }
        var insertion: AnyTransition = .opacity
        var removal: AnyTransition = .opacity
        for edge in [horizontal, vertical].compactMap({ $0 }) {
            insertion = insertion.combined(with: .move(edge: edge))
            removal = removal.combined(with: .move(edge: opposite(edge)))
        }
        return .asymmetric(insertion: insertion, removal: removal)
    }
}
