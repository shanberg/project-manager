import SwiftUI

/// Small view and string helpers shared by every surface that draws tasks — the project window's list,
/// the focus panel's card, and the editors both of them open.
///
/// These began as `private extension`s inside the one file that drew tasks. Once the focus panel became
/// its own surface they had two callers in two files, and a `private` extension is scoped to its file —
/// so they moved here and became internal rather than being copied.

extension View {
    /// Apply a modifier only when `condition` holds, leaving the view untouched otherwise. Used for the
    /// handful of places a modifier is conditional on chrome or state rather than on content.
    @ViewBuilder func ifCondition<Transformed: View>(
        _ condition: Bool, transform: (Self) -> Transformed
    ) -> some View {
        if condition { transform(self) } else { self }
    }

    /// Drop the system focus ring from a focusable container. These surfaces show which pane has
    /// keyboard focus through the selection itself (emphasized vs muted) rather than a ring around the
    /// whole list, so the ring would be noise. `focusEffectDisabled` arrived in macOS 14; below it the
    /// ring stays.
    @ViewBuilder func focusRingOff() -> some View {
        if #available(macOS 14.0, *) { focusEffectDisabled() } else { self }
    }

    /// SF Symbol swap animation, applied only where available (macOS 14+); a no-op below.
    @ViewBuilder func symbolReplaceIfAvailable() -> some View {
        if #available(macOS 14.0, *) { contentTransition(.symbolEffect(.replace)) } else { self }
    }

    /// SF Symbol bounce on a value change, applied only where available (macOS 14+); a no-op below.
    @ViewBuilder func bounceIfAvailable<V: Equatable>(_ value: V) -> some View {
        if #available(macOS 14.0, *) { symbolEffect(.bounce, value: value) } else { self }
    }
}

extension String {
    /// The trimmed string, or nil when it holds nothing but whitespace — so an empty title falls
    /// through to the next candidate rather than rendering as a blank line.
    var trimmed: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    var isBlank: Bool { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Shortened to `n` characters with an ellipsis, for the single-line contexts (menu items, the
    /// panel's Next line) that can't wrap.
    func truncated(_ n: Int) -> String { count <= n ? self : String(prefix(n - 1)) + "…" }
}

/// The sentence a refused write leaves behind.
///
/// A write that didn't happen is the one thing these surfaces can't show by redrawing. The list simply
/// looks the way it looked, which reads as "nothing happened" rather than "nothing was allowed to
/// happen" — and the reload that follows a refusal makes it worse, because the rows twitch as the
/// current document lands under an unchanged selection. So the refusal says so in words.
///
/// It takes itself down. This describes a moment, not a state: the document has already moved on, and a
/// message still sitting there a minute later would be about a situation that no longer exists.
///
/// No chrome of its own — the surfaces that show it back their own strips (the project window's sticky
/// header, the panel's foot), the same way the find bar and the delete confirmation are backed rather
/// than backing themselves.
struct WriteFailureBanner: View {
    let failure: PMStore.WriteFailure?

    /// Long enough to read twice, short enough to be gone before you look back.
    private static let dwell = Duration.seconds(6)

    @State private var showing: PMStore.WriteFailure?

    var body: some View {
        Group {
            if let showing {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(showing.message)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .font(.caption)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: showing)
        .onChange(of: failure) { _, new in
            showing = new
            guard let new else { return }
            // Keyed on the token rather than on a single shared timer: a second refusal arriving while
            // this one is up replaces the sentence and gets its own six seconds, and the older timer,
            // finding someone else's message in place, leaves it alone.
            Task {
                try? await Task.sleep(for: Self.dwell)
                if showing?.token == new.token { showing = nil }
            }
        }
    }
}
