import SwiftUI
import PmLib

/// When a task is due, drawn.
///
/// Its own file because two surfaces draw it now: the task row in the project window, where it is a
/// menu you click to change the date, and a task on a canvas card, where it is a badge and nothing
/// more. The severity scale — what counts as overdue, what a soon date looks like, whose date a dashed
/// border means — is the part that must not differ between them, so it lives in one place and both read
/// it. A canvas that disagreed with the window about which deadlines are red would be worse than a
/// canvas with no dates on it.
enum DueBadge {
    /// The badge itself, at the size and weight its state calls for.
    static func chip(_ text: String, style: DueChipStyle) -> some View {
        Text(text)
            .font(.caption2.weight(style.weight))
            // A relative badge rewrites itself as the days tick down, and "in 2d" → "in 3d" shouldn't
            // shift the row's layout to do it.
            .monospacedDigit()
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(style.fill))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(style.stroke,
                                  style: StrokeStyle(lineWidth: 1, dash: style.dashed ? [3] : []))
            )
            .foregroundStyle(style.text)
    }

    /// The read-only form: a task's date as it stands, or nothing at all.
    ///
    /// No "＋date" affordance and no menu — a card is a clipping, and an empty control offering to set
    /// something the card cannot set is worse than a quiet row. A task with no date simply has no badge.
    @ViewBuilder static func reading(_ todo: Todo) -> some View {
        if let shown = todo.dueDate.map({ (raw: $0, own: true) })
            ?? todo.effectiveDueDate.map({ (raw: $0, own: false) }) {
            chip(RelativeDue.short(shown.raw),
                 style: DueChipStyle(due: shown.raw, own: shown.own, done: todo.checked))
                .help("Due " + RelativeDue.full(shown.raw))
        }
    }
}

struct DueChipStyle {
    var text: Color
    var stroke: Color
    var fill: Color
    var weight: Font.Weight
    var dashed: Bool

    init(due: String, own: Bool, done: Bool) {
        // A completed task's date is a record rather than a deadline, so it reads at the quietest step
        // of the scale — no tint, no fill, no extra weight — while keeping the dashed border that says
        // whose date it is.
        let state: DueState = done ? .later : DueState(due: due, own: own)
        let tint: Color
        switch state {
        case .overdue: tint = Color(nsColor: .systemRed)
        case .soon: tint = Color(nsColor: .systemOrange)
        case .later, .inherited: tint = .secondary
        }
        text = tint
        stroke = tint
        dashed = !own
        if own, state == .overdue {
            fill = tint.opacity(0.16)
            weight = .semibold
        } else if own, state == .soon {
            fill = tint.opacity(0.10)
            weight = .medium
        } else {
            fill = .clear
            weight = .regular
        }
    }

    private init(text: Color, stroke: Color, fill: Color, weight: Font.Weight, dashed: Bool) {
        self.text = text; self.stroke = stroke; self.fill = fill
        self.weight = weight; self.dashed = dashed
    }

    /// The "＋date" affordance on a task with no date at all — a control, so it stays quiet.
    static let empty = DueChipStyle(text: .secondary, stroke: .secondary, fill: .clear,
                                    weight: .regular, dashed: true)
}


/// The chip as a control: click it and pick a date.
///
/// Shared by the project window's task rows and a canvas project card, so the two offer the same dates
/// in the same words. A card is otherwise read-only, and this is one of the two exceptions — a deadline
/// is the thing you most often want to change from a board, and the second-most is ticking the task off.
struct DueChip: View {
    let todo: Todo
    let isEditing: Bool
    /// Reveal the empty-state "＋date" affordance (true while hovering the row). A real own/inherited
    /// date is content, not a control, so it stays visible regardless.
    let reveal: Bool
    /// Apply a due date — nil clears it. Whatever the row's date commands apply to, this applies to.
    let onPick: (String?) -> Void
    /// Open the precise picker, for a date the presets haven't got.
    let onPickCustom: () -> Void

    /// The date this chip is showing, and whether the task owns it or inherited it from an ancestor.
    private var shown: (raw: String, own: Bool)? {
        if let own = todo.dueDate { return (own, true) }
        if let inherited = todo.effectiveDueDate { return (inherited, false) }
        return nil
    }

    private var hasDate: Bool { shown != nil }
    private var showing: Bool { hasDate || reveal || isEditing }

    var body: some View {
        // Always laid out so hovering only toggles opacity, never the row's height. A real own/
        // inherited date is content (always visible); the empty-state "＋date" is a control that
        // fades in on hover/edit but keeps reserving its space.
        Menu {
            menuItems
        } label: {
            if let shown {
                DueBadge.chip(RelativeDue.short(shown.raw),
                     style: DueChipStyle(due: shown.raw, own: shown.own, done: todo.checked))
            } else {
                DueBadge.chip("＋date", style: .empty)
            }
        }
        // `.button` + `.plain`, not `.borderlessButton`. The borderless style presents the label
        // through a pop-up-button control, which paints it in the control's own label colour — so the
        // chip's whole severity scale collapsed to plain text the moment it stopped being a `Button`.
        // The button style routes the label through `PlainButtonStyle` instead, which renders it as
        // written, exactly as the row's other plain buttons are rendered.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(helpText)
        .opacity(showing ? 1 : 0)
        .allowsHitTesting(showing)
    }

    /// The relative answers first, a calendar for anything else, and a way out.
    ///
    /// A menu, because that's what a chip is on this platform — you click the date pill in Reminders
    /// and get choices, not a stepper. It also puts the editor in the same language as the badge that
    /// opens it: the badge says "in 2w", so the menu says "Next Week", not 09/03/2026.
    ///
    /// Every item routes through `onPick`, which is the row's `onSetDue` — so a date chosen on a row
    /// inside a multi-selection lands on the whole selection, exactly as the context menu's version
    /// does. There's no separate single-row path to fall out of step.
    @ViewBuilder private var menuItems: some View {
        ForEach(DueSuggestion.options()) { option in
            Button { onPick(DueFormat.string(option.date)) } label: {
                Text(option.title) + Text("   \(option.hint)").foregroundStyle(.secondary)
            }
        }
        Divider()
        Button("Pick a Date…", action: onPickCustom)
        if todo.dueDate != nil {
            Divider()
            Button("Clear Due Date") { onPick(nil) }
        }
    }

    /// The tooltip: the exact date the badge is a summary of, plus what clicking does.
    ///
    /// The badge says "in 2w" now, which is faster to read and useless for deciding whether that
    /// clears a deadline — so the date it stands for has to be one hover away. See `RelativeDue.full`.
    private var helpText: String {
        if let own = todo.dueDate {
            return "Due \(RelativeDue.full(own))  ·  click to edit"
        }
        if let eff = todo.effectiveDueDate {
            return "Inherited due \(RelativeDue.full(eff))  ·  click to set this task's own"
        }
        return "Set due date"
    }

}
