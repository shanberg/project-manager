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
    var body: some View {
        RowSelectionFill(isSelected: isSelected, isEmphasized: isEmphasized, isHovering: isHovering)
            .clipShape(RoundedRectangle(cornerRadius: ReadableWidth.bandCornerRadius, style: .continuous))
    }
}

/// The band's tint without its shape, for something drawn on the band that has to match it.
struct RowSelectionFill: View {
    let isSelected: Bool
    let isEmphasized: Bool
    let isHovering: Bool
    /// Whether the row's window is the key window — a selection in an inactive window is muted, as in
    /// every native list.
    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
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

/// Turns off the highlight of the `NSTableView` a SwiftUI `List` row sits in, so the row can draw
/// `RowSelectionBand` instead.
///
/// The sidebar keeps its `List` for what a list does — click and ⇧/⌘-click, arrow keys, type-select,
/// scroll-into-view, the selection-aware context menu — and gives up only the table's own solid fill.
/// That fill is why every coloured thing on a sidebar row had to stand down when it was selected: a
/// project's ring, a red due date, an Up Next card's wash all went grey on the accent. On the band they
/// keep their colours, as the task rows' due chips always have, and the two panes select alike.
///
/// SwiftUI owns the table and builds it lazily, so the table is found from inside a row — the one place
/// that is certainly in it — and set on every attach. Setting it is idempotent and cheap.
struct NativeHighlightSuppressor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ nsView: NSView, context: Context) { (nsView as? Probe)?.suppress() }

    final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            suppress()
        }

        func suppress() {
            var view = superview
            while let current = view, !(current is NSTableView) { view = current.superview }
            guard let table = view as? NSTableView, table.selectionHighlightStyle != .none else { return }
            table.selectionHighlightStyle = .none
        }

        // A probe, not a target: clicks go through to the row.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
