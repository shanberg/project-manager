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
    /// outgoing content leaves toward the opposite corner.
    ///
    /// **A nudge, not a crossing.** The task arrives from `travel` points away and the old one leaves by
    /// less than half that, quicker, crossfading the whole time. It used to be built from `.move(edge:)`
    /// — each card travelling its whole size, the leaving one as far as the arriving one — on a change
    /// that happens many times an hour; the direction reads just as well from a short offset, and the
    /// leaving task is no longer what the eye follows.
    static func cornerPush(horizontal: Edge?, vertical: Edge?, travel: CGFloat) -> AnyTransition {
        func sign(_ edge: Edge?) -> CGFloat {
            switch edge {
            case .leading?, .top?: return -1
            case .trailing?, .bottom?: return 1
            case nil: return 0
            }
        }
        let dx = sign(horizontal), dy = sign(vertical)
        let leaving = travel * 0.4
        return .asymmetric(
            insertion: .opacity.combined(with: .offset(x: dx * travel, y: dy * travel)),
            removal: .opacity.combined(with: .offset(x: -dx * leaving, y: -dy * leaving))
                .animation(.easeIn(duration: Motion.Tempo.exit)))
    }
}

extension FocusMove {
    /// How the focused task changes on screen — one definition for every place that shows it (the focus
    /// panel's card, the menubar title), so they can't drift apart.
    ///
    /// `travel` is the arriving task's offset, sized to its surface. Under Reduce Motion every move,
    /// the wipe included, becomes a plain crossfade: the task still visibly changes, nothing travels.
    func transition(travel: CGFloat) -> AnyTransition {
        let moving: AnyTransition
        switch self {
        case .right: moving = .cornerPush(horizontal: .trailing, vertical: .bottom, travel: travel)  // dove into a subtask → down-right
        case .left:  moving = .cornerPush(horizontal: .leading,  vertical: .top,    travel: travel)  // bubbled up to an ancestor → up-left
        case .down:  moving = .cornerPush(horizontal: nil,       vertical: .bottom, travel: travel)  // next → rises from below
        case .up:    moving = .cornerPush(horizontal: nil,       vertical: .top,    travel: travel)  // previous → drops from above
        case .wipe:  moving = .wipe
        case .none:  return .identity
        }
        return Motion.moving(moving)
    }

    /// The curve for the change: a quick snappy arrival for a spatial move, a gentle ease for a wipe.
    /// Not routed through `Motion.animation` — under Reduce Motion the crossfade still runs.
    var animation: Animation {
        self == .wipe ? .easeInOut(duration: 0.24) : .snappy(duration: Motion.Tempo.standard)
    }
}
