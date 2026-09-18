import AppKit
import PmLib
import SwiftUI

/// One task on a view card — a Day's sitting, a Waiting group, a search's list. The one way a view draws
/// a task (docs/views.md rule 3): the box, the text or its editor, and something quiet after it, on the
/// project card's selection band.
///
/// What a click, a drag and the menu *do* is the card's: this only puts them on the row, with the hit
/// area the band shows.
struct CanvasViewRow<Trailing: View, Menu: View>: View {
    let row: CanvasDayRow
    /// The state to draw, which is the row's own until an act on it has been read back.
    let state: TaskState
    let isSelected: Bool
    /// Whether the card is stepped into — a selection there is the one you're working in.
    let isEngaged: Bool
    var zoom: Double = 1
    /// What the box does, or nil where it's only a picture: a line that's gone, a card drawn read-only.
    let toggle: CanvasDayAction?
    var onToggle: () -> Void = {}
    /// Retyping, when this is the row being retyped.
    let isEditing: Bool
    @Binding var draft: String
    var onSubmitEdit: () -> Void = {}
    var onCancelEdit: () -> Void = {}
    var onOpenProject: (String) -> Void = { _ in }
    var onHover: (Bool) -> Void = { _ in }
    /// A click on the row, not its box. The card reads the event for ⇧, ⌘ and the click count.
    var onClick: () -> Void = {}
    var drag: () -> NSItemProvider
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder var menu: () -> Menu

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            checkbox
            if isEditing {
                // The field every inline task editor uses, with its `[[…]]` completion and a typing
                // history of its own for ⌘Z (`TokenClickField.typingUndo`).
                CompletingTextField(text: $draft, placeholder: "Task",
                                    onSubmit: onSubmitEdit,
                                    onCancel: onCancelEdit,
                                    onOpenProject: onOpenProject)
                    .frame(height: 21)
            } else {
                Text(row.text)
                    .font(.system(size: 12.5 * zoom))
                    .foregroundStyle(state == .open ? .primary : .secondary)
                    .strikethrough(state == .dropped, color: .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
            }
            Spacer(minLength: 4)
            trailing()
        }
        .padding(.leading, Double(row.depth) * 11 * zoom)
        .padding(.vertical, 1)
        .padding(.horizontal, 4)
        .background(RowSelectionBand(isSelected: isSelected, isEmphasized: isEngaged, isHovering: false))
        // The band reaches into the margin; the row's text stays lined up with what's above it.
        .padding(.horizontal, -4)
        .contentShape(Rectangle())
        .onHover(perform: onHover)
        .onTapGesture(perform: onClick)
        .onDrag(drag)
        .contextMenu { menu() }
    }

    @ViewBuilder private var checkbox: some View {
        if let toggle {
            Button(action: onToggle) {
                TaskStatusIcon(state: state, size: 12 * zoom).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(toggle.title)
        } else {
            TaskStatusIcon(state: state, size: 12 * zoom)
        }
    }
}

/// A project as a view draws it beside a row or a sitting: its icon where it has one that can be drawn,
/// else its colour as a dot — what the sidebar shows for it, so a project looks like itself here too.
struct CanvasProjectMark: View {
    let color: String?
    let icon: String?
    var zoom: Double = 1

    var body: some View {
        let tint = color.flatMap(ProjectColor.init(value:)).map { Color(nsColor: $0.nsColor) }
        if let icon = icon.flatMap(ProjectIcon.init(value:)), ProjectIconMark.canDraw(icon) {
            ProjectIconMark(icon: icon, size: 11 * zoom, tint: tint)
        } else {
            Circle()
                .fill(tint ?? Color.secondary.opacity(0.5))
                .frame(width: 7 * zoom, height: 7 * zoom)
        }
    }
}
