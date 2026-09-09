import SwiftUI

/// The fill behind a selectable row in the task list — a task's or a session header's: the selection
/// band, or a whisper of one on hover.
///
/// Three states, as in every native list — selected in the focused pane of the key window (accent),
/// selected but not (grey), and not selected. It's a tint rather than a solid accent fill so the row's
/// own colours — the orange due chip, the secondary strikethrough of a completed task, a session's
/// prose — stay themselves instead of needing a second, inverted palette.
struct RowSelectionBand: View {
    let isSelected: Bool
    let isEmphasized: Bool
    let isHovering: Bool
    /// Whether the row's window is the key window — a selection in an inactive window is muted, as in
    /// every native list.
    @Environment(\.controlActiveState) private var controlActiveState
    var body: some View {
        fill.clipShape(RoundedRectangle(cornerRadius: ReadableWidth.bandCornerRadius,
                                        style: .continuous))
    }

    @ViewBuilder private var fill: some View {
        if isSelected {
            isEmphasized && controlActiveState != .inactive
                ? Color.accentColor.opacity(0.28)
                : Color.primary.opacity(0.10)
        } else if isHovering {
            Color.primary.opacity(0.05)
        } else {
            Color.clear
        }
    }
}
