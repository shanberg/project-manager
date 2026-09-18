import SwiftUI
import PmLib

/// When a task is due, drawn.
///
/// Its own file because two surfaces draw it now: the task row in the project window, where it is a
/// menu you click to change the date, and a task on a canvas card, where it is a badge and nothing
/// more. The severity scale — what counts as overdue, what a soon date looks like, whose date a slant
/// means — is the part that must not differ between them, so it lives in one place and both read
/// it. A canvas that disagreed with the window about which deadlines are red would be worse than a
/// canvas with no dates on it.
enum DueBadge {
    /// The badge itself, at the size and weight its state calls for.
    ///
    /// **Mostly just words.** A date is a fact beside the task, and a box around every one of them made
    /// a column of little buttons down the right of the list. So only the dates that are asking for
    /// something get a shape — an overdue one its tinted fill — and the rest are text in the colour of
    /// their urgency, the way Things writes "Tomorrow" beside a to-do. The padding is kept whether or
    /// not anything is drawn in it, so a date that falls overdue doesn't shift its row's text.
    static func chip(_ text: String, style: DueChipStyle) -> some View {
        Text(text)
            .font(.caption2.weight(style.weight))
            // A relative badge rewrites itself as the days tick down, and "in 2d" → "in 3d" shouldn't
            // shift the row's layout to do it.
            .monospacedDigit()
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(style.fill))
            .overlay {
                // Only the empty "＋date" control keeps an outline: it is a control with nothing in
                // it, and the dashed edge is what says there is somewhere to click.
                if let stroke = style.stroke {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(stroke, style: StrokeStyle(lineWidth: 1, dash: [3]))
                }
            }
            .foregroundStyle(style.text)
    }

    /// How wide the empty "＋date" chip draws: what a task's words clear for it on hover.
    static let emptyChipWidth: CGFloat = {
        let font = NSFont.systemFont(ofSize: NSFont.preferredFont(forTextStyle: .caption2).pointSize)
        return ceil(("＋date" as NSString).size(withAttributes: [.font: font]).width) + 10
    }()
}

struct DueChipStyle {
    var text: Color
    /// An outline, drawn dashed — only the empty "＋date" control has one.
    var stroke: Color?
    var fill: Color
    var weight: Font.Weight

    /// A task's own date. An inherited one isn't drawn as a chip: the parent's chip is right above,
    /// and repeating it down every subtask was most of what crowded a tree's words.
    init(due: String, done: Bool) {
        // A completed task's date is a record rather than a deadline, so it reads at the quietest step
        // of the scale — no tint, no fill, no extra weight.
        let state: DueState = done ? .later : DueState(due: due, own: true)
        let tint: Color
        switch state {
        case .overdue: tint = Color(nsColor: .systemRed)
        case .soon: tint = Color(nsColor: .systemOrange)
        case .later, .inherited: tint = .secondary
        }
        text = tint
        stroke = nil
        if state == .overdue {
            fill = tint.opacity(0.14)
            weight = .semibold
        } else if state == .soon {
            fill = .clear
            weight = .medium
        } else {
            fill = .clear
            weight = .regular
        }
    }

    private init(text: Color, stroke: Color?, fill: Color, weight: Font.Weight) {
        self.text = text; self.stroke = stroke; self.fill = fill; self.weight = weight
    }

    /// The "＋date" affordance on a task with no date at all — a control, so it stays quiet.
    static let empty = DueChipStyle(text: .secondary, stroke: .secondary, fill: .clear, weight: .regular)
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

    /// The task's own date. An inherited one is the parent's to show (see `DueChipStyle.init`).
    private var shown: String? { todo.dueDate }

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
                DueBadge.chip(RelativeDue.short(shown), style: DueChipStyle(due: shown, done: todo.checked))
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
            return "Inherits due \(RelativeDue.full(eff))  ·  click to set this task's own"
        }
        return "Set due date"
    }

}

/// A subtask whose parent is overdue says so with a dot, not the parent's date again: the date is on the
/// parent's line, and the dot is what keeps the branch from looking fine further down.
struct InheritedOverdueDot: View {
    let due: String

    /// The dot for `todo`, when a date it inherits has passed and it isn't finished.
    static func due(for todo: Todo) -> String? {
        guard todo.dueDate == nil, todo.state == .open, let inherited = todo.effectiveDueDate,
              RelativeDue.isOverdue(inherited) else { return nil }
        return inherited
    }

    var body: some View {
        Circle()
            .fill(Color(nsColor: .systemRed))
            .frame(width: 6, height: 6)
            // Centred on the words' x-height rather than sat on their baseline.
            .alignmentGuide(.firstTextBaseline) { dimensions in dimensions.height / 2 + 3.5 }
            .padding(.horizontal, 2)
            .contentShape(Rectangle())
            .help("Parent overdue · due \(RelativeDue.full(due))")
    }
}

